import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import { Prisma, Tournament, User } from '@prisma/client';
import type { Server } from 'socket.io';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { PushService } from '../push/push.service';
import { avatarUrl } from '../common/public-user';
import { trUser } from '../common/i18n';
import { GameError } from '../poker/engine/game';
import { agentCut } from '../poker/engine/rake';
import { TablesService, TourTableCtx } from '../tables/tables.service';
import {
  BreakRule,
  clockAt,
  ClockState,
  estimateMinutes,
  Level,
  levelAt,
  payoutAmounts,
  payoutPercents,
  prizePool,
  levelReachedAt,
} from './structure';

/** Koliko vremena igrač koji je ostao bez žetona ima za rebuy (ako je rebuy dozvoljen). */
const REBUY_WINDOW_MS = Number(process.env.TOUR_REBUY_MS || 30_000);

interface Player {
  entryId: string;
  userId: string;
  name: string;
  avatar: string | null;
  entryNo: number;
  chips: number;
  rebuys: number;
  addons: number;
  status: 'PLAYING' | 'BUSTED';
  position: number | null;
  prize: number;
  paid: boolean;
  tableId: string | null;
  /** Bounty: ko je ovog igrača ostavio bez žetona (dobitnici glavnog pota te ruke). */
  knockedBy: string[];
  knockouts: number;
  bountyWon: number;
  /** Redosled ispadanja (veći = kasnije ispao = bolje mesto). */
  bustSeq: number;
  /** Ostao bez žetona, čeka se rebuy (do ovog trenutka). */
  rebuyUntil: number | null;
  rebuyTimer?: NodeJS.Timeout;
}

interface TourRt {
  t: Tournament;
  levels: Level[];
  rule: BreakRule;
  players: Map<string, Player>; // entryId → igrač
  tables: string[];
  ticker?: NodeJS.Timeout;
  startTimer?: NodeJS.Timeout;
  clockKey: string;
  finishing: boolean;
  /** Bounty igrača za koje se ne zna ko ih je izbacio (dobija ih pobednik). */
  unclaimedBounty?: number;
}

export const tourRule = (t: Pick<Tournament, 'breakMode' | 'breakEvery' | 'breakMinutes'>): BreakRule => ({
  mode: (['HOURLY', 'LEVELS', 'NONE'].includes(t.breakMode) ? t.breakMode : 'NONE') as BreakRule['mode'],
  every: t.breakEvery,
  minutes: t.breakMinutes,
});

/**
 * Turniri: prijave, početak, raspored po stolovima, nivoi blajndova i pauze, rebuy, re-entry i add-on,
 * ispadanja i konačni plasman, nagrade. Ruke igraju obični stolovi (TablesService) u turnirskom režimu.
 */
@Injectable()
export class TournamentsService implements OnModuleInit {
  private readonly log = new Logger(TournamentsService.name);
  private readonly tours = new Map<string, TourRt>();
  private server: Server | null = null;
  /** Sve izmene jednog turnira idu redom. */
  private readonly queues = new Map<string, Promise<unknown>>();

  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly tables: TablesService,
    private readonly push: PushService,
  ) {}

  attachServer(server: Server) {
    this.server = server;
  }

  private exclusive<T>(id: string, fn: () => Promise<T> | T): Promise<T> {
    const prev = this.queues.get(id) ?? Promise.resolve();
    const run = prev.then(fn);
    this.queues.set(id, run.catch(() => undefined));
    return run;
  }

  async onModuleInit() {
    const list = await this.prisma.tournament.findMany({ where: { status: { in: ['REGISTERING', 'RUNNING'] } } });
    for (const t of list) {
      const tr = await this.load(t);
      if (t.status === 'REGISTERING') this.scheduleStart(tr);
      else await this.resume(tr).catch((e) => this.log.error(e));
    }
  }

  private async load(t: Tournament): Promise<TourRt> {
    const entries = await this.prisma.tournamentEntry.findMany({ where: { tournamentId: t.id }, include: { user: true } });
    const tr: TourRt = {
      t,
      levels: t.levels as unknown as Level[],
      rule: tourRule(t),
      players: new Map(),
      tables: [],
      clockKey: '',
      finishing: false,
    };
    for (const e of entries) {
      tr.players.set(e.id, {
        entryId: e.id,
        userId: e.userId,
        name: e.user.displayName,
        avatar: avatarUrl(e.user),
        entryNo: e.entryNo,
        chips: e.chips,
        rebuys: e.rebuys,
        addons: e.addons,
        status: e.status,
        position: e.position,
        prize: e.prize,
        paid: e.prize > 0,
        tableId: null,
        rebuyUntil: null,
        bustSeq: e.bustedAt ? e.bustedAt.getTime() * 1000 : 0,
        knockedBy: [],
        knockouts: e.knockouts,
        bountyWon: e.bountyWon,
      });
    }
    this.tours.set(t.id, tr);
    return tr;
  }

  // ---------- Sat ----------

  private clock(tr: TourRt, now = Date.now()): ClockState | null {
    if (!tr.t.startedAt) return null;
    const c = clockAt(tr.t.startedAt.getTime(), tr.levels, tr.rule, now);
    // Posle poslednjeg nivoa blajndovi se više ne menjaju: ostaje poslednji nivo, bez odbrojavanja.
    const last = tr.levels.length - 1;
    if (c.level >= last) return { ...c, level: last, levelEndsAt: null };
    return c;
  }

  /** Igrači mogu da se prijave (pre početka, ili tokom kasne prijave). */
  private regOpen(tr: TourRt) {
    if (tr.t.status === 'REGISTERING') return true;
    if (tr.t.status !== 'RUNNING' || tr.finishing) return false;
    const c = this.clock(tr)!;
    return c.level < tr.t.lateRegLevels;
  }

  private rebuyOpen(tr: TourRt) {
    if (tr.t.status !== 'RUNNING' || tr.t.rebuyLevels <= 0 || tr.t.rebuyChips <= 0) return false;
    return this.clock(tr)!.level < tr.t.rebuyLevels;
  }

  private addonOpen(tr: TourRt) {
    if (tr.t.status !== 'RUNNING' || tr.t.addonLevel <= 0 || tr.t.addonChips <= 0) return false;
    const c = this.clock(tr)!;
    // Do kraja zadatog nivoa, uključujući pauzu odmah posle njega.
    return c.level < tr.t.addonLevel || (c.onBreak && c.level <= tr.t.addonLevel);
  }

  /** Nagradni fond je konačan kad se završe prijave, rebuy i add-on. */
  private poolFinal(tr: TourRt) {
    return !this.regOpen(tr) && !this.rebuyOpen(tr) && !this.addonOpen(tr);
  }

  private counts(tr: TourRt) {
    const ps = [...tr.players.values()];
    return {
      entries: ps.length,
      rebuys: ps.reduce((a, p) => a + p.rebuys, 0),
      addons: ps.reduce((a, p) => a + p.addons, 0),
    };
  }

  private payouts(tr: TourRt) {
    const c = this.counts(tr);
    const pool = prizePool(tr.t, c);
    const percents = payoutPercents(tr.t.payoutMode, tr.t.payPercent, tr.t.payouts as unknown as number[], Math.max(c.entries, 1));
    return { pool, percents, amounts: payoutAmounts(pool, percents) };
  }

  private canRebuy(tr: TourRt, p: Player) {
    if (p.status !== 'PLAYING' || !this.rebuyOpen(tr)) return false;
    if (tr.t.rebuyMax > 0 && p.rebuys >= tr.t.rebuyMax) return false;
    const stack = this.liveChips(tr, p);
    return tr.t.rebuyBelow > 0 ? stack <= tr.t.rebuyBelow : stack === 0;
  }

  private canAddon(tr: TourRt, p: Player) {
    return p.status === 'PLAYING' && p.addons === 0 && this.addonOpen(tr);
  }

  private liveChips(tr: TourRt, p: Player) {
    if (!p.tableId) return p.chips;
    const s = this.tables.tournamentStacks(p.tableId).find((x) => x.userId === p.userId);
    return s ? s.stack : p.chips;
  }

  // ---------- Pregled ----------

  /** Prosečan, najveći i najmanji stek igrača koji su još u igri. */
  private stackStats(tr: TourRt) {
    const stacks = [...tr.players.values()].filter((p) => p.status === 'PLAYING').map((p) => this.liveChips(tr, p));
    if (!stacks.length) return { avgStack: 0, maxStack: 0, minStack: 0 };
    return {
      avgStack: Math.round(stacks.reduce((a, b) => a + b, 0) / stacks.length),
      maxStack: Math.max(...stacks),
      // Igrač na 0 koji čeka odluku o rebuy-u ne računa se kao najmanji stek.
      minStack: Math.min(...(stacks.some((x) => x > 0) ? stacks.filter((x) => x > 0) : stacks)),
    };
  }

  /** Kada se završava nivo `levels` (kasna prijava, rebuy): od stvarnog početka, a pre početka od zakazanog. */
  private levelEndTime(tr: TourRt, levels: number) {
    if (levels <= 0 || tr.t.status === 'FINISHED' || tr.t.status === 'CANCELLED') return null;
    const start = (tr.t.startedAt ?? tr.t.startAt).getTime();
    return levelReachedAt(start, tr.levels, tr.rule, levels);
  }

  private summary(tr: TourRt) {
    const t = tr.t;
    const c = this.counts(tr);
    const clock = this.clock(tr);
    const lvl = levelAt(tr.levels, clock?.level ?? 0);
    const playing = [...tr.players.values()].filter((p) => p.status === 'PLAYING').length;
    const rebuyOn = t.rebuyLevels > 0 && t.rebuyChips > 0;
    return {
      id: t.id,
      name: t.name,
      variant: t.variant,
      status: t.status,
      startAt: t.startAt,
      startedAt: t.startedAt,
      finishedAt: t.finishedAt,
      buyIn: t.buyIn,
      fee: t.fee,
      bounty: t.bounty,
      repeat: t.repeat,
      startingStack: t.startingStack,
      guarantee: t.guarantee,
      prizePool: t.status === 'FINISHED' ? t.prizePool : prizePool(t, c),
      entries: c.entries,
      playersLeft: playing,
      maxPlayers: t.maxPlayers,
      tableSize: t.tableSize,
      lateRegLevels: t.lateRegLevels,
      regOpen: this.regOpen(tr),
      rebuy: t.rebuyLevels > 0 && t.rebuyChips > 0,
      reentry: t.reentryMax > 0,
      addon: t.addonLevel > 0 && t.addonChips > 0,
      level: clock ? clock.level + 1 : null,
      smallBlind: lvl.sb,
      bigBlind: lvl.bb,
      ante: lvl.ante,
      onBreak: clock?.onBreak ?? false,
      lateRegEndsAt: this.levelEndTime(tr, t.lateRegLevels),
      rebuyEndsAt: rebuyOn ? this.levelEndTime(tr, t.rebuyLevels) : null,
      ...this.stackStats(tr),
      estimatedMinutes: this.estimate(tr),
    };
  }

  private estimate(tr: TourRt) {
    const t = tr.t;
    if (t.estimatedMinutes > 0) return t.estimatedMinutes;
    const players = Math.max(this.counts(tr).entries, t.maxPlayers > 0 ? Math.min(t.maxPlayers, 30) : 20);
    return estimateMinutes(tr.levels, tr.rule, players, t.startingStack);
  }

  /** Spisak turnira za lobi (aktuelni i završeni u poslednja 2 dana). */
  async list() {
    const since = new Date(Date.now() - 2 * 24 * 3600_000);
    const done = await this.prisma.tournament.findMany({
      where: { hidden: false, status: { in: ['FINISHED', 'CANCELLED'] }, OR: [{ finishedAt: { gte: since } }, { startAt: { gte: since } }] },
      orderBy: { startAt: 'desc' },
      take: 20,
      include: { _count: { select: { entries: true } } },
    });
    const live = [...this.tours.values()].map((tr) => this.summary(tr));
    const old = done.map((t) => ({
      id: t.id,
      name: t.name,
      variant: t.variant,
      status: t.status,
      startAt: t.startAt,
      startedAt: t.startedAt,
      finishedAt: t.finishedAt,
      buyIn: t.buyIn,
      fee: t.fee,
      bounty: t.bounty,
      startingStack: t.startingStack,
      guarantee: t.guarantee,
      prizePool: t.status === 'CANCELLED' ? 0 : t.prizePool,
      entries: t._count.entries,
      playersLeft: 0,
      maxPlayers: t.maxPlayers,
      regOpen: false,
    }));
    return [...live.sort((a, b) => +new Date(a.startAt) - +new Date(b.startAt)), ...old];
  }

  /** Detalji turnira: struktura, nagrade, rang lista, stolovi i šta igrač može da uradi. */
  async detail(id: string, userId?: string) {
    const tr = this.tours.get(id);
    if (!tr) return this.archived(id, userId);
    const t = tr.t;
    const pay = this.payouts(tr);
    const standings = this.standings(tr);
    const mine = userId ? [...tr.players.values()].filter((p) => p.userId === userId) : [];
    const current = mine.find((p) => p.status === 'PLAYING') ?? null;
    const busted = mine.filter((p) => p.status === 'BUSTED').length;
    const reentryLeft = t.reentryMax - Math.max(0, mine.length - 1);
    const clock = this.clock(tr);
    return {
      ...this.summary(tr),
      actionSeconds: t.actionSeconds,
      levels: tr.levels,
      breakMode: tr.rule.mode,
      breakEvery: tr.rule.every,
      breakMinutes: tr.rule.minutes,
      clock,
      rebuyRules: { levels: t.rebuyLevels, max: t.rebuyMax, price: t.rebuyPrice, fee: t.rebuyFee, chips: t.rebuyChips, below: t.rebuyBelow },
      addonRules: { level: t.addonLevel, price: t.addonPrice, fee: t.addonFee, chips: t.addonChips },
      reentryMax: t.reentryMax,
      minPlayers: t.minPlayers,
      payoutMode: t.payoutMode,
      payPercent: t.payPercent,
      payouts: pay.amounts.map((amount, k) => ({ place: k + 1, percent: Math.round(pay.percents[k] * 10) / 10, amount })),
      poolFinal: this.poolFinal(tr),
      standings,
      tables: tr.tables.map((id, k) => ({ id, name: `${t.name} #${k + 1}`, players: this.tables.tournamentTableInfo(id)?.players ?? 0 })),
      me: userId
        ? {
            registered: !!current,
            tableId: current?.tableId ?? null,
            position: current ? standings.find((s) => s.entryId === current.entryId)?.position ?? null : null,
            finished:
              !current && busted > 0
                ? (({ position, prize }) => ({ position, prize }))(mine.sort((a, b) => b.entryNo - a.entryNo)[0])
                : null,
            canRegister: !current && this.regOpen(tr) && (busted === 0 || (t.status === 'RUNNING' && reentryLeft > 0)),
            isReentry: !current && busted > 0,
            canUnregister: !!current && t.status === 'REGISTERING',
            canRebuy: !!current && this.canRebuy(tr, current),
            canAddon: !!current && this.canAddon(tr, current),
          }
        : null,
    };
  }

  private async archived(id: string, userId?: string) {
    const t = await this.prisma.tournament.findUnique({ where: { id }, include: { entries: { include: { user: true } } } });
    if (!t) throw new GameError('Turnir ne postoji.');
    const standings = t.entries
      .filter((e) => e.position !== null)
      .sort((a, b) => a.position! - b.position!)
      .map((e) => ({ entryId: e.id, position: e.position!, name: e.user.displayName, userId: e.userId, chips: 0, knockouts: e.knockouts, bountyWon: e.bountyWon, prize: e.prize, status: e.status, tableId: null }));
    const percents = payoutPercents(t.payoutMode, t.payPercent, t.payouts as unknown as number[], Math.max(1, t.entries.length));
    const amounts = payoutAmounts(t.prizePool, percents);
    const mine = userId ? t.entries.filter((e) => e.userId === userId).sort((a, b) => b.entryNo - a.entryNo)[0] : undefined;
    return {
      id: t.id,
      name: t.name,
      variant: t.variant,
      status: t.status,
      startAt: t.startAt,
      startedAt: t.startedAt,
      finishedAt: t.finishedAt,
      buyIn: t.buyIn,
      fee: t.fee,
      bounty: t.bounty,
      startingStack: t.startingStack,
      guarantee: t.guarantee,
      prizePool: t.prizePool,
      entries: t.entries.length,
      playersLeft: 0,
      maxPlayers: t.maxPlayers,
      levels: t.levels,
      breakMode: t.breakMode,
      breakEvery: t.breakEvery,
      breakMinutes: t.breakMinutes,
      payouts: amounts.map((amount, k) => ({ place: k + 1, percent: Math.round(percents[k] * 10) / 10, amount })),
      standings,
      tables: [],
      regOpen: false,
      me: mine ? { registered: false, finished: { position: mine.position, prize: mine.prize }, canRegister: false } : null,
    };
  }

  /** Rang lista: igrači u igri po žetonima, pa ispali po plasmanu. */
  private standings(tr: TourRt) {
    const stacks = new Map<string, number>();
    for (const id of tr.tables) for (const s of this.tables.tournamentStacks(id)) stacks.set(s.userId, s.stack);
    const playing = [...tr.players.values()]
      .filter((p) => p.status === 'PLAYING')
      .map((p) => ({ p, chips: stacks.get(p.userId) ?? p.chips }))
      .sort((a, b) => b.chips - a.chips);
    const out = playing.map(({ p, chips }, k) => ({
      entryId: p.entryId,
      position: k + 1,
      name: p.name,
      userId: p.userId,
      chips,
      knockouts: p.knockouts,
      bountyWon: p.bountyWon,
      prize: 0,
      status: 'PLAYING',
      tableId: p.tableId,
    }));
    // Ispali: kasnije ispao = bolje mesto (jedinstvena mesta i kad ima re-entry-ja i kasne prijave).
    const busted = [...tr.players.values()].filter((p) => p.status === 'BUSTED').sort((a, b) => (a.position === 1 ? -1 : b.position === 1 ? 1 : b.bustSeq - a.bustSeq));
    for (const p of busted) {
      out.push({ entryId: p.entryId, position: out.length + 1, name: p.name, userId: p.userId, chips: 0, knockouts: p.knockouts, bountyWon: p.bountyWon, prize: p.prize, status: 'BUSTED', tableId: null });
    }
    return out;
  }

  /** Podaci o turniru za igrača za stolom (gore na stolu). */
  private tableView(tr: TourRt, userId?: string) {
    const clock = this.clock(tr);
    const lvl = levelAt(tr.levels, clock?.level ?? 0);
    const next = levelAt(tr.levels, (clock?.level ?? 0) + 1);
    const playing = [...tr.players.values()].filter((p) => p.status === 'PLAYING');
    const me = userId ? playing.find((p) => p.userId === userId) : undefined;
    let position: number | null = null;
    if (me) {
      const mine = this.liveChips(tr, me);
      position = 1 + playing.filter((p) => p !== me && this.liveChips(tr, p) > mine).length;
    }
    const pay = this.payouts(tr);
    return {
      id: tr.t.id,
      name: tr.t.name,
      level: (clock?.level ?? 0) + 1,
      sb: lvl.sb,
      bb: lvl.bb,
      ante: lvl.ante,
      nextSb: next.sb,
      nextBb: next.bb,
      levelEndsAt: clock?.levelEndsAt ?? null,
      onBreak: clock?.onBreak ?? false,
      breakEndsAt: clock?.breakEndsAt ?? null,
      nextBreakAt: clock?.nextBreakAt ?? null,
      playersLeft: playing.length,
      entries: tr.players.size,
      ...this.stackStats(tr),
      startingStack: tr.t.startingStack,
      lateRegEndsAt: this.regOpen(tr) ? this.levelEndTime(tr, tr.t.lateRegLevels) : null,
      rebuyEndsAt: this.rebuyOpen(tr) ? this.levelEndTime(tr, tr.t.rebuyLevels) : null,
      position,
      prizePool: pay.pool,
      paidPlaces: pay.amounts.length,
      rebuyUntil: me?.rebuyUntil ?? null,
      canRebuy: !!me && this.canRebuy(tr, me),
      canAddon: !!me && this.canAddon(tr, me),
      rebuy: { price: tr.t.rebuyPrice + tr.t.rebuyFee, chips: tr.t.rebuyChips },
      bounty: tr.t.bounty,
      myBountyWon: me?.bountyWon ?? 0,
      myKnockouts: me?.knockouts ?? 0,
      addon: { price: tr.t.addonPrice + tr.t.addonFee, chips: tr.t.addonChips },
    };
  }

  private changed(tr: TourRt) {
    this.server?.to('tours').emit('tours', null);
    this.server?.to(`tour:${tr.t.id}`).emit('tour:changed', { id: tr.t.id });
  }

  private emitUser(userId: string, event: string, data: unknown) {
    this.server?.to(`user:${userId}`).emit(event, data);
  }

  // ---------- Administracija ----------

  async create(data: Prisma.TournamentUncheckedCreateInput) {
    const t = await this.prisma.tournament.create({ data });
    const tr = await this.load(t);
    this.scheduleStart(tr);
    this.changed(tr);
    const game = `${t.variant === 'OMAHA' ? 'PLO' : 'NLH'} turnir`;
    void this.push
      .toAllPlayers({
        title: `Novi turnir: ${t.name}`,
        body: `${game} — počinje ${TablesService.when(t.startAt)}. Ulaz ${t.buyIn + t.bounty + t.fee}${t.guarantee ? `, garantovano ${t.guarantee}` : ''}.`,
        tag: `tour-${t.id}`,
      })
      .catch(() => undefined);
    return t;
  }

  /** Ponavljajući turnir: kad počne, isti turnir se zakaže za sledeći dan ili nedelju. */
  private async scheduleNext(t: Tournament) {
    const days = t.repeat === 'DAILY' ? 1 : t.repeat === 'WEEKLY' ? 7 : 0;
    if (!days) return;
    const {
      id: _id, status: _s, createdAt: _c, startedAt: _st, finishedAt: _f, prizePool: _p, startAt, levels, payouts, ...rest
    } = t;
    try {
      await this.create({
        ...rest,
        levels: levels as Prisma.InputJsonValue,
        payouts: payouts as Prisma.InputJsonValue,
        startAt: new Date(startAt.getTime() + days * 24 * 3600_000),
      });
    } catch (e) {
      this.log.error(`Sledeći turnir u seriji nije napravljen: ${(e as Error).message}`);
    }
  }

  /** Prekida ponavljanje (turnir koji čeka početak više neće praviti sledeći). */
  async stopRepeat(id: string) {
    const tr = this.tours.get(id);
    await this.prisma.tournament.update({ where: { id }, data: { repeat: 'NONE' } });
    if (tr) tr.t.repeat = 'NONE';
  }

  /** Otkazivanje: svi ulazi (i rebuy/add-on) se vraćaju igračima. */
  async cancel(id: string) {
    const tr = this.tours.get(id);
    if (!tr) throw new GameError('Turnir nije aktivan.');
    return this.exclusive(id, async () => {
      await this.refundAll(tr, 'Turnir je otkazan');
      await this.prisma.tournament.update({ where: { id }, data: { status: 'CANCELLED', finishedAt: new Date() } });
      tr.t.status = 'CANCELLED';
      await this.teardown(tr);
      for (const p of tr.players.values()) this.emitUser(p.userId, 'tournament:closed', { tournamentId: id, message: trUser(`Turnir „${tr.t.name}“ je otkazan, ulaz je vraćen.`, p.userId) });
      this.server?.to('tours').emit('tours', null);
      return {};
    });
  }

  private async refundAll(tr: TourRt, note: string) {
    const rows = await this.prisma.tournamentEntry.findMany({ where: { tournamentId: tr.t.id } });
    for (const e of rows) {
      const back = e.paid + e.feePaid;
      if (back > 0) {
        await this.wallet.run((db) => this.wallet.change(db, e.userId, 'TOURNAMENT_REFUND', back, { note: `${note}: ${tr.t.name}` }));
        await this.balance(e.userId);
      }
    }
  }

  private async teardown(tr: TourRt) {
    clearInterval(tr.ticker);
    clearTimeout(tr.startTimer);
    for (const p of tr.players.values()) clearTimeout(p.rebuyTimer);
    // Ne čeka se: zatvaranje može biti pozvano i iz samog stola (kraj turnira posle ruke).
    for (const id of tr.tables) void this.tables.closeTournamentTable(id);
    tr.tables = [];
    this.tours.delete(tr.t.id);
  }

  /** Za admin panel: igrači i stanje. */
  async adminDetail(id: string) {
    return this.detail(id);
  }

  // ---------- Prijava ----------

  private async balance(userId: string) {
    const u = await this.prisma.user.findUnique({ where: { id: userId }, select: { balance: true } });
    if (u) this.emitUser(userId, 'balance', { balance: u.balance });
  }

  async register(userId: string, id: string) {
    const tr = this.tours.get(id);
    if (!tr) throw new GameError('Prijave za ovaj turnir nisu otvorene.');
    return this.exclusive(id, async () => {
      const t = tr.t;
      const user = await this.prisma.user.findUniqueOrThrow({ where: { id: userId } });
      if (user.role !== 'PLAYER') throw new GameError('Samo igrači mogu da igraju turnire.');
      if (!this.regOpen(tr)) throw new GameError('Prijave su zatvorene.');
      const mine = [...tr.players.values()].filter((p) => p.userId === userId);
      if (mine.some((p) => p.status === 'PLAYING')) throw new GameError('Već ste prijavljeni.');
      if (mine.length > 0 && (t.status !== 'RUNNING' || mine.length - 1 >= t.reentryMax)) throw new GameError('Nemate više pravo na re-entry.');
      if (t.maxPlayers > 0 && tr.players.size >= t.maxPlayers) throw new GameError('Turnir je popunjen.');
      const entryNo = mine.length + 1;
      const e = await this.wallet.run(async (db) => {
        await this.wallet.change(db, userId, 'TOURNAMENT_BUY_IN', -(t.buyIn + t.bounty + t.fee), { note: `${entryNo > 1 ? 'Re-entry' : 'Ulaz'}: ${t.name}` });
        return db.tournamentEntry.create({
          data: { tournamentId: id, userId, entryNo, chips: t.startingStack, paid: t.buyIn + t.bounty, feePaid: t.fee },
        });
      });
      const p = this.addPlayer(tr, e.id, user, entryNo, t.startingStack);
      await this.balance(userId);
      if (t.status === 'RUNNING') await this.seatLate(tr, p);
      this.changed(tr);
      return { entryId: e.id };
    });
  }

  private addPlayer(tr: TourRt, entryId: string, user: User, entryNo: number, chips: number): Player {
    const p: Player = {
      entryId,
      userId: user.id,
      name: user.displayName,
      avatar: avatarUrl(user),
      entryNo,
      chips,
      rebuys: 0,
      addons: 0,
      status: 'PLAYING',
      position: null,
      prize: 0,
      paid: false,
      tableId: null,
      rebuyUntil: null,
      bustSeq: 0,
      knockedBy: [],
      knockouts: 0,
      bountyWon: 0,
    };
    tr.players.set(entryId, p);
    return p;
  }

  async unregister(userId: string, id: string) {
    const tr = this.tours.get(id);
    if (!tr) throw new GameError('Turnir nije aktivan.');
    return this.exclusive(id, async () => {
      if (tr.t.status !== 'REGISTERING') throw new GameError('Turnir je već počeo, odjava nije moguća.');
      const p = [...tr.players.values()].find((x) => x.userId === userId && x.status === 'PLAYING');
      if (!p) throw new GameError('Niste prijavljeni.');
      const e = await this.prisma.tournamentEntry.findUniqueOrThrow({ where: { id: p.entryId } });
      await this.wallet.run(async (db) => {
        await this.wallet.change(db, userId, 'TOURNAMENT_REFUND', e.paid + e.feePaid, { note: `Odjava: ${tr.t.name}` });
        await db.tournamentEntry.delete({ where: { id: e.id } });
      });
      tr.players.delete(p.entryId);
      await this.balance(userId);
      this.changed(tr);
      return {};
    });
  }

  /** Rebuy: igrač kupuje žetone (kad mu stek padne na granicu ili ostane bez žetona). */
  async rebuy(userId: string, id: string) {
    const tr = this.tours.get(id);
    if (!tr) throw new GameError('Turnir nije aktivan.');
    return this.exclusive(id, async () => {
      const p = [...tr.players.values()].find((x) => x.userId === userId && x.status === 'PLAYING');
      if (!p || !p.tableId) throw new GameError('Ne igrate na ovom turniru.');
      if (!this.canRebuy(tr, p)) throw new GameError('Rebuy trenutno nije moguć.');
      const t = tr.t;
      await this.wallet.run(async (db) => {
        await this.wallet.change(db, userId, 'TOURNAMENT_BUY_IN', -(t.rebuyPrice + t.rebuyFee), { note: `Rebuy: ${t.name}` });
        await db.tournamentEntry.update({
          where: { id: p.entryId },
          data: { rebuys: { increment: 1 }, paid: { increment: t.rebuyPrice }, feePaid: { increment: t.rebuyFee } },
        });
      });
      p.rebuys++;
      p.knockedBy = [];
      clearTimeout(p.rebuyTimer);
      p.rebuyUntil = null;
      await this.tables.addTournamentChips(p.tableId, userId, t.rebuyChips);
      await this.balance(userId);
      this.changed(tr);
      return {};
    });
  }

  async addon(userId: string, id: string) {
    const tr = this.tours.get(id);
    if (!tr) throw new GameError('Turnir nije aktivan.');
    return this.exclusive(id, async () => {
      const p = [...tr.players.values()].find((x) => x.userId === userId && x.status === 'PLAYING');
      if (!p || !p.tableId) throw new GameError('Ne igrate na ovom turniru.');
      if (!this.canAddon(tr, p)) throw new GameError('Add-on trenutno nije moguć.');
      const t = tr.t;
      await this.wallet.run(async (db) => {
        await this.wallet.change(db, userId, 'TOURNAMENT_BUY_IN', -(t.addonPrice + t.addonFee), { note: `Add-on: ${t.name}` });
        await db.tournamentEntry.update({
          where: { id: p.entryId },
          data: { addons: { increment: 1 }, paid: { increment: t.addonPrice }, feePaid: { increment: t.addonFee } },
        });
      });
      p.addons++;
      await this.tables.addTournamentChips(p.tableId, userId, t.addonChips);
      await this.balance(userId);
      this.changed(tr);
      return {};
    });
  }

  // ---------- Početak ----------

  private scheduleStart(tr: TourRt) {
    clearTimeout(tr.startTimer);
    const ms = Math.max(0, tr.t.startAt.getTime() - Date.now());
    if (ms > 2_000_000_000) return; // daleko u budućnosti: proverava se pri sledećem pokretanju servera
    tr.startTimer = setTimeout(() => void this.exclusive(tr.t.id, () => this.start(tr)).catch((e) => this.log.error(e)), ms);
    // Podsetnik prijavljenima 5 minuta pre početka.
    if (ms > 6 * 60_000) {
      setTimeout(() => {
        if (tr.t.status !== 'REGISTERING') return;
        for (const p of tr.players.values()) {
          void this.push.toUser(p.userId, { title: `Turnir „${tr.t.name}“ počinje za 5 minuta`, body: 'Otvorite aplikaciju da ne propustite početak.', tag: `tour-${tr.t.id}` }).catch(() => undefined);
        }
      }, ms - 5 * 60_000);
    }
  }

  private async start(tr: TourRt) {
    if (tr.t.status !== 'REGISTERING' || !this.tours.has(tr.t.id)) return;
    await this.scheduleNext(tr.t);
    const players = [...tr.players.values()];
    if (players.length < Math.max(2, tr.t.minPlayers)) {
      await this.refundAll(tr, 'Nedovoljno igrača');
      await this.prisma.tournament.update({ where: { id: tr.t.id }, data: { status: 'CANCELLED', finishedAt: new Date() } });
      tr.t.status = 'CANCELLED';
      for (const p of players) this.emitUser(p.userId, 'tournament:closed', { tournamentId: tr.t.id, message: trUser(`Turnir „${tr.t.name}“ je otkazan (premalo igrača), ulaz je vraćen.`, p.userId) });
      await this.teardown(tr);
      this.server?.to('tours').emit('tours', null);
      return;
    }
    const startedAt = new Date();
    tr.t = await this.prisma.tournament.update({ where: { id: tr.t.id }, data: { status: 'RUNNING', startedAt } });
    await this.seatAll(tr, players);
    this.startTicker(tr);
    this.changed(tr);
  }

  /** Raspored igrača po stolovima (ravnomerno, nasumično). */
  private async seatAll(tr: TourRt, players: Player[]) {
    const size = tr.t.tableSize;
    const n = Math.max(1, Math.ceil(players.length / size));
    const ids: string[] = [];
    for (let k = 0; k < n; k++) ids.push(await this.newTable(tr));
    const shuffled = [...players].sort(() => Math.random() - 0.5);
    for (let k = 0; k < shuffled.length; k++) await this.seat(tr, shuffled[k], ids[k % n]);
  }

  private async newTable(tr: TourRt) {
    const lvl = levelAt(tr.levels, this.clock(tr)?.level ?? 0);
    const table = await this.prisma.pokerTable.create({
      data: {
        name: `${tr.t.name} #${tr.tables.length + 1}`,
        variant: tr.t.variant,
        smallBlind: lvl.sb,
        bigBlind: lvl.bb,
        minBuyIn: 0,
        maxBuyIn: 0,
        maxSeats: tr.t.tableSize,
        actionSeconds: tr.t.actionSeconds,
        isOpen: false,
        tournamentId: tr.t.id,
        createdById: tr.t.createdById,
      },
    });
    this.tables.openTournamentTable(table, {
      tournamentId: tr.t.id,
      blinds: () => {
        const l = levelAt(tr.levels, this.clock(tr)?.level ?? 0);
        return { sb: l.sb, bb: l.bb, ante: l.ante };
      },
      pausedUntil: () => {
        const c = this.clock(tr);
        return c?.onBreak ? c.breakEndsAt : null;
      },
      handDone: (ctx) => this.handDone(tr, ctx),
      view: (userId) => this.tableView(tr, userId),
    });
    tr.tables.push(table.id);
    return table.id;
  }

  private async seat(tr: TourRt, p: Player, tableId: string, moved = false) {
    const from = p.tableId;
    p.tableId = tableId;
    await this.tables.seatTournamentPlayer(tableId, p.userId, p.name, p.chips, p.avatar);
    this.emitUser(p.userId, 'tournament:seat', { tournamentId: tr.t.id, tableId, fromTableId: from, moved, name: tr.t.name });
  }

  /** Kasna prijava ili re-entry: za sto sa najmanje igrača (ili novi sto ako su svi puni). */
  private async seatLate(tr: TourRt, p: Player) {
    const best = this.tablesBySize(tr).find((x) => x.players < tr.t.tableSize);
    await this.seat(tr, p, best ? best.id : await this.newTable(tr));
  }

  private tablesBySize(tr: TourRt) {
    return tr.tables
      .map((id) => ({ id, players: this.tables.tournamentTableInfo(id)?.players ?? 0 }))
      .sort((a, b) => a.players - b.players);
  }

  /** Nastavak posle ponovnog pokretanja servera: igrači sa žetonima ponovo za stolove. */
  private async resume(tr: TourRt) {
    const alive = [...tr.players.values()].filter((p) => p.status === 'PLAYING' && p.chips > 0);
    const broke = [...tr.players.values()].filter((p) => p.status === 'PLAYING' && p.chips <= 0);
    if (broke.length) await this.bust(tr, broke.map((p) => ({ p, startStack: 0 })));
    if (alive.length <= 1) {
      await this.finish(tr);
      return;
    }
    await this.seatAll(tr, alive);
    this.startTicker(tr);
    this.log.log(`Turnir „${tr.t.name}“ nastavljen (${alive.length} igrača).`);
  }

  /** Promena nivoa ili pauze: osvežavaju se svi stolovi turnira. */
  private startTicker(tr: TourRt) {
    clearInterval(tr.ticker);
    tr.ticker = setInterval(() => {
      const c = this.clock(tr);
      if (!c) return;
      const key = `${c.level}:${c.onBreak}`;
      if (key === tr.clockKey) return;
      const first = tr.clockKey === '';
      tr.clockKey = key;
      if (first) return;
      for (const id of tr.tables) this.tables.refreshTable(id);
      this.changed(tr);
    }, 1000);
  }

  // ---------- Posle svake ruke ----------

  private async handDone(tr: TourRt, ctx: TourTableCtx) {
    if (tr.finishing) return;
    const seats = ctx.seats();
    const byUser = new Map([...tr.players.values()].filter((p) => p.status === 'PLAYING').map((p) => [p.userId, p]));
    // Žetoni posle ruke (za rang listu i nastavak posle restarta).
    const updates: Promise<unknown>[] = [];
    for (const s of seats) {
      const p = byUser.get(s.userId);
      if (!p) continue;
      if (p.chips !== s.stack) {
        p.chips = s.stack;
        updates.push(this.prisma.tournamentEntry.update({ where: { id: p.entryId }, data: { chips: s.stack } }));
      }
    }
    await Promise.all(updates);

    // Bounty: ko je igrača ostavio bez žetona (pamti se i dok traje vreme za rebuy).
    for (const s of seats) {
      const p = byUser.get(s.userId);
      if (p && s.stack === 0 && !p.knockedBy.length) p.knockedBy = ctx.winners().filter((u) => u !== p.userId);
    }
    // Bez žetona: rebuy (ako je dozvoljen) ili ispadanje.
    const out: { p: Player; startStack: number }[] = [];
    for (const s of seats) {
      const p = byUser.get(s.userId);
      if (!p || s.stack > 0 || p.rebuyUntil) continue;
      if (this.canRebuy(tr, p)) {
        p.rebuyUntil = Date.now() + REBUY_WINDOW_MS;
        this.emitUser(p.userId, 'tournament:rebuy', { tournamentId: tr.t.id, tableId: ctx.tableId, until: p.rebuyUntil });
        p.rebuyTimer = setTimeout(() => {
          p.rebuyUntil = null;
          if (p.status !== 'PLAYING' || !p.tableId) return;
          const tableId = p.tableId;
          // Isteklo vreme za rebuy: ispadanje (kad je sto između ruku).
          void this.tables.withIdleTournamentTable(tableId, (c) =>
            this.exclusive(`${tr.t.id}:bust`, async () => {
              const s2 = c.seats().find((x) => x.userId === p.userId);
              if (!s2 || s2.stack > 0 || p.status !== 'PLAYING') return;
              c.remove(p.userId);
              await this.bust(tr, [{ p, startStack: s2.startStack }]);
              await this.afterBust(tr, c);
            }),
          );
        }, REBUY_WINDOW_MS);
        continue;
      }
      ctx.remove(p.userId);
      out.push({ p, startStack: s.startStack });
    }
    // Ispadanja idu redom i za više stolova (zaseban red koji nikad ne čeka sto, da nema zastoja).
    await this.exclusive(`${tr.t.id}:bust`, async () => {
      if (out.length) await this.bust(tr, out);
      await this.afterBust(tr, ctx);
    });
  }

  private async afterBust(tr: TourRt, ctx: TourTableCtx) {
    const left = [...tr.players.values()].filter((p) => p.status === 'PLAYING');
    if (left.length <= 1 && !left.some((p) => p.rebuyUntil)) {
      await this.finish(tr);
      return;
    }
    this.balance_(tr, ctx);
    this.changed(tr);
  }

  /** Ispadanje: mesto je broj igrača koji su još u igri (više žetona na početku ruke = bolje mesto). */
  private async bust(tr: TourRt, out: { p: Player; startStack: number }[]) {
    const remaining = [...tr.players.values()].filter((p) => p.status === 'PLAYING').length;
    const order = [...out].sort((a, b) => a.startStack - b.startStack);
    const pay = this.payouts(tr);
    const final = this.poolFinal(tr);
    let pos = remaining;
    let seq = Date.now() * 1000;
    for (const { p } of order) {
      p.bustSeq = seq++;
      await this.payBounty(tr, p);
      p.status = 'BUSTED';
      p.position = pos--;
      p.tableId = null;
      p.chips = 0;
      clearTimeout(p.rebuyTimer);
      p.rebuyUntil = null;
      // Nagrada se isplaćuje odmah ako je fond konačan (inače na kraju turnira).
      const prize = pay.amounts[p.position - 1] ?? 0;
      if (final && prize > 0) await this.payPrize(tr, p, prize);
      await this.prisma.tournamentEntry.update({
        where: { id: p.entryId },
        data: { status: 'BUSTED', position: p.position, chips: 0, bustedAt: new Date(), prize: p.prize },
      });
      const reentry = this.regOpen(tr) && [...tr.players.values()].filter((x) => x.userId === p.userId).length - 1 < tr.t.reentryMax;
      this.emitUser(p.userId, 'tournament:busted', {
        tournamentId: tr.t.id,
        name: tr.t.name,
        position: p.position,
        entries: tr.players.size,
        prize: final ? prize : 0,
        pendingPrize: !final && prize > 0,
        canReenter: reentry,
        reentryPrice: tr.t.buyIn + tr.t.bounty + tr.t.fee,
      });
    }
  }

  /**
   * Fee (rake) turnira: koliko je svaki igrač platio i koliko od toga pripada njegovom agentu
   * (procenat agenta važeći na kraju turnira, kao kod rake-a sa keš stolova).
   */
  private async recordFees(tournamentId: string) {
    const rows = await this.prisma.tournamentEntry.groupBy({ by: ['userId'], where: { tournamentId }, _sum: { feePaid: true } });
    const users = await this.prisma.user.findMany({
      where: { id: { in: rows.map((r) => r.userId) } },
      select: { id: true, agentId: true, agent: { select: { rakeShareBps: true } } },
    });
    const data = rows
      .filter((r) => (r._sum.feePaid ?? 0) > 0)
      .map((r) => {
        const u = users.find((x) => x.id === r.userId);
        const amount = r._sum.feePaid ?? 0;
        return {
          tournamentId,
          userId: r.userId,
          agentId: u?.agentId ?? null,
          amount,
          agentCut: u?.agentId ? agentCut(amount, u.agent?.rakeShareBps ?? 0) : 0,
        };
      });
    if (data.length) await this.prisma.feeShare.createMany({ data });
  }

  /** Bounty izbačenog igrača dobija onaj ko ga je izbacio (deli se ako ih je više). */
  private async payBounty(tr: TourRt, out: Player) {
    const b = tr.t.bounty;
    const knockers = out.knockedBy
      .map((u) => [...tr.players.values()].find((x) => x.userId === u && x.status === 'PLAYING'))
      .filter((x): x is Player => !!x);
    out.knockedBy = [];
    if (b <= 0) return;
    if (!knockers.length) {
      // Nije poznato ko je izbacio (npr. posle ponovnog pokretanja servera): bounty ide pobedniku.
      tr.unclaimedBounty = (tr.unclaimedBounty ?? 0) + b;
      return;
    }
    const share = Math.floor(b / knockers.length);
    for (const [k, w] of knockers.entries()) {
      const amount = share + (k === 0 ? b - share * knockers.length : 0);
      await this.creditBounty(tr, w, amount, out.name);
    }
  }

  private async creditBounty(tr: TourRt, w: Player, amount: number, victim: string | null) {
    if (amount <= 0) return;
    if (victim) w.knockouts++;
    w.bountyWon += amount;
    await this.wallet.run(async (db) => {
      await this.wallet.change(db, w.userId, 'TOURNAMENT_BOUNTY', amount, { note: `Bounty: ${tr.t.name}` });
      await db.tournamentEntry.update({
        where: { id: w.entryId },
        data: { bountyWon: { increment: amount }, ...(victim ? { knockouts: { increment: 1 } } : {}) },
      });
    });
    await this.balance(w.userId);
    if (victim) this.emitUser(w.userId, 'tournament:bounty', { tournamentId: tr.t.id, name: tr.t.name, victim, amount });
  }

  private async payPrize(tr: TourRt, p: Player, prize: number) {
    if (p.paid || prize <= 0) return;
    p.paid = true;
    p.prize = prize;
    await this.wallet.run((db) => this.wallet.change(db, p.userId, 'TOURNAMENT_PRIZE', prize, { note: `${p.position}. mesto: ${tr.t.name}` }));
    await this.balance(p.userId);
  }

  /**
   * Raspoređivanje po stolovima (posle ruke na stolu `ctx`):
   * ako igrači mogu da stanu za manje stolova, najmanji sto se rasformira;
   * inače, ako ovaj sto ima bar 2 igrača više od najmanjeg, jedan igrač prelazi.
   */
  private balance_(tr: TourRt, ctx: TourTableCtx) {
    const size = tr.t.tableSize;
    const info = this.tablesBySize(tr);
    const total = info.reduce((a, x) => a + x.players, 0);
    const needed = Math.max(1, Math.ceil(total / size));
    const here = info.find((x) => x.id === ctx.tableId);
    if (!here) return;
    const smallest = info[0];
    if (info.length > needed) {
      if (smallest.id === ctx.tableId || here.players === smallest.players) {
        this.breakTable(tr, ctx);
      } else {
        // Najmanji sto se rasformira kad bude između ruku.
        void this.tables.withIdleTournamentTable(smallest.id, (c) => this.breakTable(tr, c));
      }
      return;
    }
    if (here.players - smallest.players >= 2) {
      const seats = ctx.seats().filter((s) => s.stack > 0);
      const s = seats[Math.floor(Math.random() * seats.length)];
      if (s) this.move(tr, ctx, s.userId, smallest.id);
    }
  }

  private breakTable(tr: TourRt, ctx: TourTableCtx) {
    if (!tr.tables.includes(ctx.tableId) || tr.tables.length <= 1) return;
    const others = tr.tables.filter((id) => id !== ctx.tableId);
    const counts = new Map(others.map((id) => [id, this.tables.tournamentTableInfo(id)?.players ?? 0]));
    for (const s of ctx.seats()) {
      const dest = [...counts.entries()].filter(([, n]) => n < tr.t.tableSize).sort((a, b) => a[1] - b[1])[0];
      if (!dest) break;
      counts.set(dest[0], dest[1] + 1);
      this.move(tr, ctx, s.userId, dest[0]);
    }
    if (ctx.seats().length === 0) {
      tr.tables = others;
      ctx.close();
    }
  }

  /** Premeštanje igrača za drugi sto (sa svim žetonima). */
  private move(tr: TourRt, ctx: TourTableCtx, userId: string, toTableId: string) {
    const p = [...tr.players.values()].find((x) => x.userId === userId && x.status === 'PLAYING');
    if (!p) return;
    const chips = ctx.remove(userId);
    p.chips = chips;
    void this.seat(tr, p, toTableId, true).catch((e) => this.log.error(e));
  }

  // ---------- Kraj ----------

  private async finish(tr: TourRt) {
    if (tr.finishing) return;
    tr.finishing = true;
    const winner = [...tr.players.values()].find((p) => p.status === 'PLAYING');
    const pay = this.payouts(tr);
    if (winner) {
      // Pobednik dobija i svoj bounty (i one za koje se ne zna ko ih je osvojio).
      await this.creditBounty(tr, winner, tr.t.bounty + (tr.unclaimedBounty ?? 0), null);
      tr.unclaimedBounty = 0;
      winner.status = 'BUSTED';
      winner.position = 1;
      await this.payPrize(tr, winner, pay.amounts[0] ?? 0);
      await this.prisma.tournamentEntry.update({
        where: { id: winner.entryId },
        data: { status: 'BUSTED', position: 1, prize: winner.prize, chips: 0, bustedAt: new Date() },
      });
    }
    // Konačna mesta po redosledu ispadanja među svim ulazima (re-entry i kasna prijava su uračunati).
    const total = tr.players.size;
    const order = [...tr.players.values()].filter((p) => p !== winner && p.status === 'BUSTED').sort((a, b) => a.bustSeq - b.bustSeq);
    for (const [k, p] of order.entries()) {
      const pos = total - k;
      if (p.position !== pos) {
        p.position = pos;
        await this.prisma.tournamentEntry.update({ where: { id: p.entryId }, data: { position: pos } });
      }
    }
    // Nagrade koje nisu isplaćene tokom igre (fond tada još nije bio konačan).
    for (const p of tr.players.values()) {
      if (p.position && !p.paid) {
        const prize = pay.amounts[p.position - 1] ?? 0;
        if (prize > 0) {
          await this.payPrize(tr, p, prize);
          await this.prisma.tournamentEntry.update({ where: { id: p.entryId }, data: { prize } });
          this.emitUser(p.userId, 'tournament:prize', { tournamentId: tr.t.id, name: tr.t.name, position: p.position, prize });
        }
      }
    }
    tr.t = await this.prisma.tournament.update({
      where: { id: tr.t.id },
      data: { status: 'FINISHED', finishedAt: new Date(), prizePool: pay.pool },
    });
    await this.recordFees(tr.t.id);
    if (winner) {
      this.emitUser(winner.userId, 'tournament:busted', {
        tournamentId: tr.t.id,
        name: tr.t.name,
        position: 1,
        entries: tr.players.size,
        prize: winner.prize,
        winner: true,
      });
    }
    const id = tr.t.id;
    // Sto se zatvara malo kasnije, da se vidi poslednja ruka.
    setTimeout(() => void this.teardown(tr).then(() => this.server?.to('tours').emit('tours', null)), 8000);
    this.server?.to('tours').emit('tours', null);
    this.server?.to(`tour:${id}`).emit('tour:changed', { id });
  }
}
