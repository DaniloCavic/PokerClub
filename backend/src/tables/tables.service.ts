import { BadRequestException, Injectable, Logger, NotFoundException, OnModuleInit } from '@nestjs/common';
import { PokerTable, Prisma } from '@prisma/client';
import type { Server } from 'socket.io';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { PushService } from '../push/push.service';
import { avatarUrl } from '../common/public-user';
import { Card, cardToString } from '../poker/engine/cards';
import { equityAsync } from '../poker/engine/equity';
import { ActionType, GameError, HandResult, PokerGame } from '../poker/engine/game';
import { bestHoldem, bestOmaha } from '../poker/engine/evaluator';
import { agentCut, splitRake } from '../poker/engine/rake';

/** Pauza između dve ruke (da se vidi ko je dobio). */
const BETWEEN_HANDS_MS = Number(process.env.BETWEEN_HANDS_MS || 5000);
/** Igrač koji ne igra (sit out) duže od ovoga automatski ustaje sa stola. */
/** Dodatno vreme (TIME) posle isteka osnovnog vremena za potez. */
const TIME_BANK_MS = Number(process.env.TIME_BANK_MS || 30_000);
/** Igrač koji ne igra (sit out) duže od ovoga automatski ustaje sa stola. */
const SIT_OUT_LIMIT_MS = Number(process.env.SIT_OUT_LIMIT_MS || 10 * 60_000);

interface Runtime {
  table: PokerTable;
  game: PokerGame;
  queue: Promise<unknown>;
  turnTimer?: NodeJS.Timeout;
  turnKey?: string;
  deadline: number | null;
  /** Kad počinje dodatno vreme (TIME) za igrača na potezu. */
  timeBankAt: number | null;
  nextHandTimer?: NodeJS.Timeout;
  /** Stekovi na početku ruke (za istoriju). */
  startStacks: Record<number, number>;
  lastResult: ReturnType<TablesService['resultView']> | null;
  sitOutSince: Map<string, number>;
  /** Igrač je ostao bez žetona: rok za rebuy (posle toga ustaje i oslobađa mesto). */
  rebuy: Map<string, { until: number; timer: NodeJS.Timeout }>;
  /** Kad je sto počeo (otvaranje ili zakazano vreme). */
  startedAt: number;
  /** Karte koje je igrač sam pokazao (posle fold-a ili kraja ruke): sedište → indeksi karata. */
  voluntaryShow: Map<number, number[]>;
  /** Kad je zakazana sledeća ruka (za produženje pauze kad neko pokaže karte). */
  nextHandAt?: number;
  /** Sto se zatvara posle ruke koja je u toku. */
  closing: boolean;
  /** Poslednje poruke u chatu stola (samo u memoriji). */
  chat: ChatMessage[];
  /** Lista čekanja kad je sto pun (redom prijave). */
  waitlist: { userId: string; name: string }[];
  /** Slobodno mesto čuva se kratko za prvog sa liste čekanja. */
  reservation: { userId: string; until: number; timer: NodeJS.Timeout } | null;
  /** Obaveštenje kad se zakazani sto otvori. */
  openTimer?: NodeJS.Timeout;
  /** Dodatna pauza pre sledeće ruke dok aplikacija prikazuje all-in (flop, turn, river jedan po jedan). */
  runoutMs?: number;
  /** Run it twice: rok za odgovore igrača. */
  ritTimer?: NodeJS.Timeout;
  ritDeadline: number | null;
}

/** All-in: pauza pre otvaranja prve ulice i između ulica (mora odgovarati aplikaciji). */
const RUNOUT_START_MS = 1200;
const RUNOUT_STREET_MS = 2000;

/** Koliko igrači imaju vremena da odluče o run it twice. */
const RIT_MS = Number(process.env.RIT_MS || 10_000);

/** Kad igrač pokaže karte posle kraja ruke, sledeća ruka čeka bar ovoliko. */
const SHOW_MS = Number(process.env.SHOW_MS || 4000);

/** Koliko vremena igrač bez žetona ima za rebuy pre nego što ustane. */
const REBUY_MS = Number(process.env.REBUY_MS || 120_000);

/** Koliko dugo se mesto čuva za igrača sa liste čekanja. */
const RESERVE_MS = Number(process.env.WAITLIST_RESERVE_MS || 45_000);

export interface ChatMessage {
  id: number;
  userId: string;
  name: string;
  text: string;
  at: number;
}

const CHAT_KEEP = 50;
let chatSeq = 0;

export const rakePercent = (t: Pick<PokerTable, 'rakeBps'>) => t.rakeBps / 100;

/**
 * Stolovi uživo: drži igru u memoriji, meri vreme za potez, čuva ruke u bazi
 * i šalje stanje igračima. Sve radnje na jednom stolu idu redom (jedna po jedna).
 */
@Injectable()
export class TablesService implements OnModuleInit {
  private readonly log = new Logger(TablesService.name);
  private readonly runtimes = new Map<string, Runtime>();
  private server: Server | null = null;
  /** Adrese slika profila igrača koji sede za stolovima. */
  private readonly avatars = new Map<string, string | null>();

  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly push: PushService,
  ) {}

  // ---------- Prisutnost (da li je igrač trenutno u aplikaciji) ----------

  /** userId → (socketId → da li je aplikacija vidljiva). */
  private readonly presence = new Map<string, Map<string, boolean>>();

  setPresence(userId: string, socketId: string, visible: boolean | null) {
    const m = this.presence.get(userId) ?? new Map<string, boolean>();
    if (visible === null) m.delete(socketId);
    else m.set(socketId, visible);
    if (m.size) this.presence.set(userId, m);
    else this.presence.delete(userId);
  }

  /** Igrač gleda aplikaciju (bar jedan uređaj je otvoren i vidljiv). */
  isPresent(userId: string) {
    return [...(this.presence.get(userId)?.values() ?? [])].some(Boolean);
  }

  /** Obaveštenje na telefon samo ako igrač trenutno nije u aplikaciji. */
  private nudge(userId: string, msg: { title: string; body: string; tableId?: string; tag?: string }) {
    if (this.isPresent(userId)) return;
    void this.push.toUser(userId, msg).catch((e) => this.log.warn((e as Error).message));
  }

  /** "četvrtak, 12. 11. 18:00" (vreme Beograda). */
  static when(d: Date) {
    return d.toLocaleString('sr-Latn-RS', {
      timeZone: process.env.APP_TIMEZONE || 'Europe/Belgrade',
      weekday: 'long',
      day: 'numeric',
      month: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    });
  }

  attachServer(server: Server) {
    this.server = server;
  }

  async onModuleInit() {
    // Posle ponovnog pokretanja ruke u toku su poništene: žetoni sa stola se vraćaju na nalog
    // u iznosu sa početka te ruke (stanje posle poslednje završene ruke).
    const seats = await this.prisma.tableSeat.findMany();
    for (const s of seats) await this.cashOutRow(s.tableId, s.userId, 'Server je ponovo pokrenut');
    if (seats.length) this.log.log(`Vraćeni žetoni za ${seats.length} sedišta.`);
    const open = await this.prisma.pokerTable.findMany({ where: { isOpen: true } });
    for (const t of open) await this.continueNumbering(this.createRuntime(t));
  }

  private createRuntime(table: PokerTable) {
    const rt: Runtime = {
      table,
      game: new PokerGame({
        variant: table.variant,
        smallBlind: table.smallBlind,
        bigBlind: table.bigBlind,
        maxSeats: table.maxSeats,
        rakeBps: table.rakeBps,
        rakeCap: table.rakeCap,
        // Ante je petina velikog blajnda.
        ante: Math.floor(table.bigBlind / 5),
        straddle: table.straddle,
        runItTwice: true,
      }),
      queue: Promise.resolve(),
      deadline: null,
      timeBankAt: null,
      startStacks: {},
      lastResult: null,
      sitOutSince: new Map(),
      rebuy: new Map(),
      startedAt: Math.max(Date.now(), table.opensAt?.getTime() ?? 0),
      voluntaryShow: new Map(),
      closing: false,
      chat: [],
      waitlist: [],
      reservation: null,
      ritDeadline: null,
    };
    this.runtimes.set(table.id, rt);
    this.scheduleOpenNotice(rt);
    return rt;
  }

  /** Zakazani sto: kad dođe vreme otvaranja, svi prijavljeni igrači dobijaju obaveštenje. */
  private scheduleOpenNotice(rt: Runtime) {
    const at = rt.table.opensAt?.getTime();
    if (!at || at <= Date.now()) return;
    const ms = at - Date.now();
    if (ms > 2_000_000_000) return; // setTimeout ne može toliko daleko (više od ~23 dana)
    rt.openTimer = setTimeout(() => {
      if (!this.runtimes.has(rt.table.id) || rt.closing) return;
      const t = rt.table;
      this.server?.emit('table:opened', {
        tableId: t.id,
        name: t.name,
        variant: t.variant,
        smallBlind: t.smallBlind,
        bigBlind: t.bigBlind,
      });
      this.lobbyChanged();
      void this.push
        .toAllPlayers({
          title: `Sto „${t.name}“ je počeo!`,
          body: `${t.variant === 'OMAHA' ? 'PLO' : 'NLH'} ${t.smallBlind}/${t.bigBlind} — uđite i igrajte.`,
          tableId: t.id,
          tag: `open-${t.id}`,
        })
        .catch((e) => this.log.warn((e as Error).message));
    }, ms + 500);
  }

  /** Brojevi ruku se nastavljaju i posle ponovnog pokretanja servera. */
  private async continueNumbering(rt: Runtime) {
    const last = await this.prisma.hand.aggregate({ where: { tableId: rt.table.id }, _max: { handNo: true } });
    rt.game.handNo = last._max.handNo ?? 0;
  }

  /** Zakazan sto: pre vremena otvaranja igrači ne mogu da uđu. */
  assertUnlocked(tableId: string) {
    const opensAt = this.rt(tableId).table.opensAt;
    if (opensAt && opensAt.getTime() > Date.now()) {
      throw new GameError(`Sto se otvara ${TablesService.when(opensAt)}.`);
    }
  }

  private rt(tableId: string): Runtime {
    const rt = this.runtimes.get(tableId);
    if (!rt) throw new GameError('Sto nije otvoren.');
    return rt;
  }

  /** Izvršava radnju kad se završe prethodne na istom stolu. */
  private exclusive<T>(rt: Runtime, fn: () => Promise<T> | T): Promise<T> {
    const run = rt.queue.then(fn);
    rt.queue = run.catch(() => undefined);
    return run;
  }

  // ---------- Pregled ----------

  lobby() {
    return [...this.runtimes.values()]
      .filter((rt) => !rt.closing)
      .map((rt) => this.summary(rt))
      .sort((a, b) => a.variant.localeCompare(b.variant) || a.bigBlind - b.bigBlind || a.name.localeCompare(b.name));
  }

  private summary(rt: Runtime) {
    const t = rt.table;
    return {
      id: t.id,
      name: t.name,
      variant: t.variant,
      smallBlind: t.smallBlind,
      bigBlind: t.bigBlind,
      minBuyIn: t.minBuyIn,
      maxBuyIn: t.maxBuyIn,
      maxSeats: t.maxSeats,
      // Rake se igračima ne prikazuje (vidi ga samo agent u admin panelu).
      actionSeconds: t.actionSeconds,
      opensAt: t.opensAt,
      straddle: t.straddle,
      bombPotEvery: t.bombPotEvery,
      bombPotBB: t.bombPotBB,
      players: rt.game.seats.filter(Boolean).length,
      waiting: rt.waitlist.length,
      startedAt: rt.startedAt,
    };
  }

  /** Za admin panel: ko sedi i sa koliko žetona. */
  liveInfo(tableId: string) {
    const rt = this.runtimes.get(tableId);
    if (!rt) return null;
    return {
      handNo: rt.game.handNo,
      inProgress: rt.game.inProgress,
      closing: rt.closing,
      seats: rt.game.seats
        .map((s, i) => (s ? { seat: i, userId: s.userId, name: s.name, stack: s.stack, sittingOut: s.sittingOut, leaving: s.leaving } : null))
        .filter(Boolean),
    };
  }

  /** Stolovi za kojima korisnik sedi. */
  seatsOf(userId: string) {
    return [...this.runtimes.values()].filter((rt) => rt.game.seatOf(userId) >= 0).map((rt) => rt.table.id);
  }

  /** Stanje stola iz ugla jednog korisnika (tuđe karte se ne vide). */
  view(tableId: string, userId?: string) {
    return this.viewOf(this.rt(tableId), userId);
  }

  /**
   * Super agent: stanje stola uživo sa kartama svih igrača u ruci i trenutnom jačinom ruke.
   * Šalje se samo u admin panel (nikad preko socketa igračima), pa igrači ništa ne vide.
   */
  liveView(tableId: string) {
    const rt = this.runtimes.get(tableId);
    if (!rt) return null;
    const base = this.viewOf(rt);
    const g = rt.game;
    const fn = rt.table.variant === 'OMAHA' ? bestOmaha : bestHoldem;
    return {
      ...base,
      seats: base.seats.map((v, i) => {
        const s = g.seats[i];
        if (!v || !s) return v;
        const has = g.inProgress && s.inHand && s.hole.length > 0;
        return {
          ...v,
          cards: has ? s.hole.map(cardToString) : v.cards,
          hand: has && !s.folded && g.board.length >= 3 ? fn(s.hole, g.board).name : null,
        };
      }),
    };
  }

  private viewOf(rt: Runtime, userId?: string) {
    const g = rt.game;
    const mySeat = userId ? g.seatOf(userId) : -1;
    const shown = new Map<number, string[]>();
    for (const s of rt.lastResult?.shown ?? []) shown.set(s.seat, s.cards);
    return {
      ...this.summary(rt),
      closing: rt.closing,
      handNo: g.handNo,
      inProgress: g.inProgress,
      street: g.inProgress ? g.street : null,
      board: g.board.map(cardToString),
      pot: g.potTotal(),
      button: g.button,
      sbSeat: g.inProgress ? g.sbSeat : -1,
      bbSeat: g.inProgress ? g.bbSeat : -1,
      toAct: g.toAct,
      deadline: rt.deadline,
      timeBankAt: rt.timeBankAt,
      timeBankSeconds: TIME_BANK_MS / 1000,
      // Pot iz prethodnih rundi (gomila žetona na sredini stola), bez uloga u tekućoj rundi.
      collected: g.inProgress ? g.collected : 0,
      ante: Math.floor(rt.table.bigBlind / 5),
      serverTime: Date.now(),
      seats: g.seats.map((s, i) => {
        if (!s) return null;
        const own = i === mySeat;
        // Tuđe karte: otvorene na kraju ruke, ili one koje je igrač sam pokazao (ostale su poleđine).
        const vol = rt.voluntaryShow.get(i);
        const visible = own
          ? s.hole.map(cardToString)
          : (shown.get(i) ?? (vol && s.hole.length ? s.hole.map((c, k) => (vol.includes(k) ? cardToString(c) : null)) : null));
        return {
          index: i,
          userId: s.userId,
          name: s.name,
          avatarUrl: this.avatars.get(s.userId) ?? null,
          stack: s.stack,
          bet: s.bet,
          inHand: s.inHand,
          folded: s.folded,
          allIn: s.allIn,
          sittingOut: s.sittingOut,
          leaving: s.leaving,
          lastAction: s.lastAction,
          lastAct: s.lastAct,
          cards: visible && visible.length ? visible : null,
          // Svoje karte koje sam pokazao ostalima (za oznaku i dugmad)
          myShown: own ? (vol ?? []) : undefined,
          cardCount: s.inHand && !s.folded ? s.hole.length : 0,
        };
      }),
      mySeat,
      myHand: this.currentHand(rt, mySeat),
      // Straddle i bomb pot
      bombPot: g.inProgress && g.bombPot > 0,
      straddleSeat: g.inProgress ? g.straddleSeat : -1,
      nextBombIn: this.handsToBomb(rt),
      // Izbor igrača (samo za sopstveno mesto)
      myPrefs: mySeat >= 0 ? { straddle: !!g.seats[mySeat]!.straddle } : null,
      // Run it twice: pitanje posle all-in-a (ko se pita, ko je već rekao da, do kada).
      ritPending: g.ritPending,
      ritAsk: g.ritPending ? g.ritAsk : [],
      ritYes: g.ritPending ? g.ritYes : [],
      ritDeadline: g.ritPending ? rt.ritDeadline : null,
      // Lista čekanja
      waitlist: rt.waitlist.map((w) => w.name),
      onWaitlist: !!userId && rt.waitlist.some((w) => w.userId === userId),
      waitPosition: userId ? rt.waitlist.findIndex((w) => w.userId === userId) + 1 : 0,
      rebuyUntil: userId ? (rt.rebuy.get(userId)?.until ?? null) : null,
      reservedForMe: rt.reservation && rt.reservation.userId === userId ? rt.reservation.until : null,
      // Svi potezi u ruci koja je u toku (spisak na stolu i istorija ruke).
      actions: g.actions,
      legal: mySeat >= 0 ? g.legalActions(mySeat) : null,
      result: rt.lastResult,
    };
  }

  /** Za koliko ruku je sledeći bomb pot (1 = sledeća ruka); null ako sto nema bomb pot. */
  private handsToBomb(rt: Runtime): number | null {
    const every = rt.table.bombPotEvery;
    if (!every) return null;
    const next = rt.game.handNo + (rt.game.inProgress ? 1 : 1);
    const left = (every - (next % every)) % every;
    return left + 1;
  }

  /** Trenutna jačina ruke igrača (od flopa), da se prikaže samo njemu. */
  private currentHand(rt: Runtime, seat: number): string | null {
    const s = rt.game.seats[seat];
    const board = rt.game.board;
    if (!s || !rt.game.inProgress || !s.inHand || s.folded || board.length < 3) return null;
    const fn = rt.table.variant === 'OMAHA' ? bestOmaha : bestHoldem;
    return fn(s.hole, board).name;
  }

  private resultView(rt: Runtime, r: HandResult) {
    const name = (seat: number) => rt.game.seats[seat]?.name ?? '?';
    return {
      handNo: r.handNo,
      board2: r.board2 ? r.board2.map(cardToString) : null,
      runoutFrom: r.runoutFrom ?? null,
      // Šanse za pobedu tokom all-in-a, po broju karata na stolu (dopunjava se posle, vidi computeEquity).
      equity: null as { board: number; odds: Record<number, number> }[] | null,
      pots: r.pots.map((p) => ({
        amount: p.amount,
        handName: p.handName,
        run: p.run ?? null,
        winners: p.winners.map((w) => ({ seat: w.seat, name: name(w.seat), amount: w.amount })),
      })),
      shown: r.shown.map((s) => ({
        seat: s.seat,
        cards: s.hole.map(cardToString),
        best: s.best.map(cardToString),
        handName: s.handName,
        ...(s.handName2 ? { handName2: s.handName2, best2: (s.best2 ?? []).map(cardToString) } : {}),
      })),
    };
  }

  // ---------- Slanje stanja ----------

  private async broadcast(rt: Runtime) {
    if (!this.server) return;
    const sockets = await this.server.in(`table:${rt.table.id}`).fetchSockets();
    for (const s of sockets) {
      s.emit('table:state', this.viewOf(rt, (s.data as { userId?: string }).userId));
    }
  }

  private lobbyChanged() {
    this.server?.to('lobby').emit('lobby', this.lobby());
  }

  private async balanceChanged(userId: string) {
    const u = await this.prisma.user.findUnique({ where: { id: userId }, select: { balance: true } });
    if (u) this.server?.to(`user:${userId}`).emit('balance', { balance: u.balance });
  }

  /** Poruke u chatu stola (za igrača koji tek otvara sto). */
  chatHistory(tableId: string) {
    return this.rt(tableId).chat;
  }

  /** Nova poruka u chatu stola; šalje se svima koji gledaju sto. */
  private readonly lastChat = new Map<string, number>();
  async chat(userId: string, tableId: string, raw: string) {
    const rt = this.rt(tableId);
    const text = String(raw ?? '').replace(/\s+/g, ' ').trim().slice(0, 200);
    if (!text) throw new GameError('Poruka je prazna.');
    const now = Date.now();
    if (now - (this.lastChat.get(userId) ?? 0) < 1000) throw new GameError('Sačekajte trenutak pre sledeće poruke.');
    this.lastChat.set(userId, now);
    const user = await this.prisma.user.findUniqueOrThrow({ where: { id: userId }, select: { displayName: true, role: true } });
    if (user.role !== 'PLAYER') throw new GameError('Samo igrači mogu da pišu u chat.');
    const msg: ChatMessage = { id: ++chatSeq, userId, name: user.displayName, text, at: now };
    rt.chat.push(msg);
    if (rt.chat.length > CHAT_KEEP) rt.chat.splice(0, rt.chat.length - CHAT_KEEP);
    this.server?.to(`table:${tableId}`).emit('table:chat', { tableId, message: msg });
    return {};
  }

  /** Igrač je promenio sliku: osveži stolove za kojima sedi. */
  avatarChanged(userId: string, url: string | null) {
    this.avatars.set(userId, url);
    for (const rt of this.runtimes.values()) if (rt.game.seatOf(userId) >= 0) void this.broadcast(rt);
  }

  // ---------- Radnje igrača ----------

  async sit(userId: string, tableId: string, seat: number, buyIn: number) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      const t = rt.table;
      if (rt.closing) throw new GameError('Sto se zatvara.');
      this.assertUnlocked(tableId);
      const user = await this.prisma.user.findUniqueOrThrow({ where: { id: userId } });
      if (user.role !== 'PLAYER') throw new GameError('Samo igrači mogu da sednu za sto.');
      if (rt.game.seatOf(userId) >= 0) throw new GameError('Već sedite za ovim stolom.');
      if (!Number.isInteger(seat) || seat < 0 || seat >= t.maxSeats) throw new GameError('Ne postoji to mesto.');
      if (rt.game.seats[seat]) throw new GameError('Mesto je zauzeto.');
      const res = rt.reservation;
      if (res && res.until > Date.now() && res.userId !== userId) {
        const free = rt.game.seats.filter((x) => !x).length;
        if (free <= 1) throw new GameError('Mesto je rezervisano za igrača sa liste čekanja.');
      }
      if (!Number.isInteger(buyIn) || buyIn < t.minBuyIn || buyIn > t.maxBuyIn) {
        throw new GameError(`Ulaz mora biti između ${t.minBuyIn} i ${t.maxBuyIn}.`);
      }
      if (user.balance < buyIn) throw new GameError('Nemate dovoljno žetona na nalogu.');
      await this.wallet.run(async (db) => {
        await this.wallet.change(db, userId, 'BUY_IN', -buyIn, { tableId });
        await db.tableSeat.create({ data: { tableId, userId, seat, stack: buyIn } });
      });
      rt.game.sit(seat, userId, user.displayName, buyIn);
      this.avatars.set(userId, avatarUrl(user));
      rt.waitlist = rt.waitlist.filter((w) => w.userId !== userId);
      if (rt.reservation?.userId === userId) {
        clearTimeout(rt.reservation.timer);
        rt.reservation = null;
      }
      await this.balanceChanged(userId);
      await this.afterChange(rt);
      this.lobbyChanged();
      return { seat };
    });
  }

  /** Dopuna žetona na stolu (između ruku), do najvećeg ulaza. */
  async topUp(userId: string, tableId: string, amount: number) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      const i = rt.game.seatOf(userId);
      if (i < 0) throw new GameError('Ne sedite za ovim stolom.');
      const s = rt.game.seats[i]!;
      if (s.inHand && rt.game.inProgress) throw new GameError('Dopuna je moguća tek kad se ruka završi.');
      if (!Number.isInteger(amount) || amount <= 0) throw new GameError('Neispravan iznos.');
      if (s.stack + amount > rt.table.maxBuyIn) {
        throw new GameError(`Na stolu možete imati najviše ${rt.table.maxBuyIn} (sada imate ${s.stack}).`);
      }
      try {
        await this.wallet.run(async (db) => {
          await this.wallet.change(db, userId, 'BUY_IN', -amount, { tableId, note: 'dopuna' });
          await db.tableSeat.update({ where: { tableId_userId: { tableId, userId } }, data: { stack: { increment: amount } } });
        });
      } catch (e) {
        if (e instanceof BadRequestException) throw new GameError(e.message);
        throw e;
      }
      s.stack += amount;
      if (!s.sittingOut) rt.sitOutSince.delete(userId);
      this.clearRebuy(rt, userId);
      await this.balanceChanged(userId);
      await this.afterChange(rt);
      return {};
    });
  }

  async act(userId: string, tableId: string, action: ActionType, amount?: number) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      const i = rt.game.seatOf(userId);
      if (i < 0) throw new GameError('Ne sedite za ovim stolom.');
      const result = rt.game.act(i, action, amount);
      rt.sitOutSince.delete(userId);
      await this.afterChange(rt, result);
      return {};
    });
  }

  async setSitOut(userId: string, tableId: string, value: boolean) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      const i = rt.game.seatOf(userId);
      if (i < 0) throw new GameError('Ne sedite za ovim stolom.');
      const s = rt.game.seats[i]!;
      s.sittingOut = value;
      if (value) rt.sitOutSince.set(userId, Date.now());
      else rt.sitOutSince.delete(userId);
      await this.afterChange(rt);
      return {};
    });
  }

  /** Igrač ustaje (ili ga agent izbacuje). Ako je u ruci, odustaje i ustaje kad se ruka završi. */
  async leave(userId: string, tableId: string, reason?: string) {
    const rt = this.runtimes.get(tableId);
    if (!rt) return {};
    return this.exclusive(rt, async () => {
      const i = rt.game.seatOf(userId);
      if (i < 0) return {};
      const s = rt.game.seats[i]!;
      if (reason) this.server?.to(`user:${userId}`).emit('kicked', { tableId, reason });
      if (rt.game.inProgress && s.inHand) {
        s.leaving = true;
        const result = rt.game.forceFold(i);
        await this.afterChange(rt, result);
        return { pending: true };
      }
      await this.standUp(rt, i);
      await this.afterChange(rt);
      return {};
    });
  }

  /** Izbacuje korisnika sa svih stolova (blokada). */
  async removeEverywhere(userId: string, reason: string) {
    for (const tableId of this.seatsOf(userId)) await this.leave(userId, tableId, reason);
  }

  // ---------- Upravljanje stolovima ----------

  async open(table: PokerTable) {
    if (!this.runtimes.has(table.id)) await this.continueNumbering(this.createRuntime(table));
    this.lobbyChanged();
  }

  /** Zatvara sto: novih ruku nema, igrači ustaju kad se završi ruka u toku. */
  async close(tableId: string) {
    const rt = this.runtimes.get(tableId);
    if (!rt) return;
    await this.exclusive(rt, async () => {
      rt.closing = true;
      if (!rt.game.inProgress) await this.shutdown(rt);
      else await this.broadcast(rt);
    });
    this.lobbyChanged();
  }

  private async shutdown(rt: Runtime) {
    clearTimeout(rt.nextHandTimer);
    clearTimeout(rt.turnTimer);
    clearTimeout(rt.openTimer);
    clearTimeout(rt.ritTimer);
    for (const r of rt.rebuy.values()) clearTimeout(r.timer);
    rt.rebuy.clear();
    if (rt.reservation) clearTimeout(rt.reservation.timer);
    rt.reservation = null;
    rt.waitlist = [];
    for (let i = 0; i < rt.game.seats.length; i++) {
      if (rt.game.seats[i]) {
        this.server?.to(`user:${rt.game.seats[i]!.userId}`).emit('kicked', { tableId: rt.table.id, reason: 'Sto je zatvoren.' });
        await this.standUp(rt, i);
      }
    }
    await this.broadcast(rt);
    this.server?.in(`table:${rt.table.id}`).socketsLeave(`table:${rt.table.id}`);
    this.runtimes.delete(rt.table.id);
  }

  // ---------- Tok igre ----------

  /** Posle svake promene: obrada kraja ruke, tajmer, slanje stanja, sledeća ruka. */
  private async afterChange(rt: Runtime, result: HandResult | null = null) {
    if (result) await this.handFinished(rt, result);
    this.armTurnTimer(rt);
    await this.broadcast(rt);
    if (!rt.game.inProgress) this.scheduleNextHand(rt);
  }

  /** Run it twice: ko ne odgovori na vreme, karte se dele jednom. */
  private armRitTimer(rt: Runtime) {
    const g = rt.game;
    if (!g.inProgress || !g.ritPending) {
      clearTimeout(rt.ritTimer);
      rt.ritTimer = undefined;
      rt.ritDeadline = null;
      return;
    }
    if (rt.ritTimer) return;
    const hand = g.handNo;
    for (const i of g.ritAsk) {
      this.nudge(g.seats[i]!.userId, {
        title: 'All-in: run it twice?',
        body: `Sto „${rt.table.name}“ — odlučite za ${Math.round(RIT_MS / 1000)} s.`,
        tableId: rt.table.id,
        tag: `turn-${rt.table.id}`,
      });
    }
    rt.ritDeadline = Date.now() + RIT_MS;
    rt.ritTimer = setTimeout(() => {
      void this.exclusive(rt, async () => {
        rt.ritTimer = undefined;
        if (!rt.game.ritPending || rt.game.handNo !== hand) return;
        const result = rt.game.resolveRunTwice();
        await this.afterChange(rt, result);
      }).catch((e) => this.log.error(e));
    }, RIT_MS);
  }

  private armTurnTimer(rt: Runtime) {
    this.armRitTimer(rt);
    const g = rt.game;
    if (!g.inProgress || g.toAct < 0) {
      clearTimeout(rt.turnTimer);
      rt.turnKey = undefined;
      rt.deadline = null;
      rt.timeBankAt = null;
      return;
    }
    const key = `${g.handNo}:${g.street}:${g.toAct}:${g.currentBet}:${g.seats[g.toAct]!.bet}`;
    if (key === rt.turnKey) return;
    clearTimeout(rt.turnTimer);
    rt.turnKey = key;
    const turnUser = g.seats[g.toAct]!.userId;
    this.nudge(turnUser, {
      title: 'Na potezu ste!',
      body: `Sto „${rt.table.name}“ — imate ${rt.table.actionSeconds} s (+${Math.round(TIME_BANK_MS / 1000)} s TIME).`,
      tableId: rt.table.id,
      tag: `turn-${rt.table.id}`,
    });
    // Osnovno vreme za potez, pa dodatno vreme (TIME); tek kad istekne i ono, igra se check ili fold.
    const ms = rt.table.actionSeconds * 1000 + TIME_BANK_MS;
    rt.timeBankAt = Date.now() + rt.table.actionSeconds * 1000;
    rt.deadline = Date.now() + ms;
    rt.turnTimer = setTimeout(() => {
      void this.exclusive(rt, async () => {
        if (rt.turnKey !== key || !rt.game.inProgress) return;
        const s = rt.game.seats[rt.game.toAct]!;
        // Igrač koji ne odigra na vreme prestaje da dobija karte dok se ne vrati.
        s.sittingOut = true;
        rt.sitOutSince.set(s.userId, Date.now());
        const result = rt.game.timeoutAction();
        await this.afterChange(rt, result);
      }).catch((e) => this.log.error(e));
    }, ms);
  }

  private scheduleNextHand(rt: Runtime) {
    if (rt.nextHandTimer || rt.closing) return;
    this.scheduleNextHandIn(rt, rt.lastResult ? BETWEEN_HANDS_MS + (rt.runoutMs ?? 0) : 1000);
  }

  private scheduleNextHandIn(rt: Runtime, ms: number) {
    rt.nextHandAt = Date.now() + ms;
    rt.nextHandTimer = setTimeout(() => {
      rt.nextHandTimer = undefined;
      void this.exclusive(rt, async () => {
        if (rt.game.inProgress || rt.closing || !this.runtimes.has(rt.table.id)) return;
        await this.standUpIdle(rt);
        if (!rt.game.canStart()) {
          if (rt.lastResult) {
            rt.lastResult = null;
            await this.broadcast(rt);
          }
          return;
        }
        rt.lastResult = null;
        rt.voluntaryShow.clear();
        rt.startStacks = {};
        rt.game.seats.forEach((s, i) => {
          if (s) rt.startStacks[i] = s.stack;
        });
        const every = rt.table.bombPotEvery;
        const bomb = every > 0 && (rt.game.handNo + 1) % every === 0 ? rt.table.bombPotBB * rt.table.bigBlind : 0;
        const result = rt.game.startHand(undefined, { bombPot: bomb });
        await this.afterChange(rt, result);
      }).catch((e) => this.log.error(e));
    }, ms);
  }

  private async handFinished(rt: Runtime, r: HandResult) {
    const g = rt.game;
    // All-in pre kraja stola: aplikacija otkriva ulice jednu po jednu, pa sledeća ruka čeka duže.
    if (r.runoutFrom !== undefined) {
      const streets = r.runoutFrom === 0 ? 3 : r.runoutFrom === 3 ? 2 : 1;
      rt.runoutMs = RUNOUT_START_MS + streets * RUNOUT_STREET_MS * (r.board2 ? 2 : 1);
      void this.computeEquity(rt, r).catch((e) => this.log.warn((e as Error).message));
    } else rt.runoutMs = 0;
    rt.lastResult = this.resultView(rt, r);
    const pot = r.pots.reduce((s, p) => s + p.amount, 0) + r.rake;
    const players = Object.keys(rt.startStacks).map(Number).filter((i) => g.seats[i]).map((i) => ({
      seat: i,
      userId: g.seats[i]!.userId,
      name: g.seats[i]!.name,
      startStack: rt.startStacks[i],
      endStack: g.seats[i]!.stack,
      cards: g.seats[i]!.hole.map(cardToString).join(' '),
    })).filter((p) => p.cards);

    // Rake se deli na igrače srazmerno ulogu; od dela svakog igrača njegov agent dobija svoj procenat.
    let rakeShares: Prisma.RakeShareCreateWithoutHandInput[] = [];
    if (r.rake > 0) {
      const contributors = Object.keys(rt.startStacks)
        .map(Number)
        .filter((i) => g.seats[i])
        .map((i) => ({ key: g.seats[i]!.userId, amount: g.seats[i]!.committed }));
      const parts = splitRake(r.rake, contributors);
      const users = await this.prisma.user.findMany({
        where: { id: { in: parts.map((p) => p.key) } },
        select: { id: true, agentId: true, agent: { select: { rakeShareBps: true } } },
      });
      rakeShares = parts.map((p) => {
        const u = users.find((x) => x.id === p.key);
        return {
          table: { connect: { id: rt.table.id } },
          user: { connect: { id: p.key } },
          ...(u?.agentId ? { agent: { connect: { id: u.agentId } } } : {}),
          amount: p.amount,
          agentCut: u?.agentId ? agentCut(p.amount, u.agent?.rakeShareBps ?? 0) : 0,
        };
      });
    }

    await this.prisma.$transaction([
      this.prisma.hand.create({
        data: {
          rakeShares: { create: rakeShares },
          tableId: rt.table.id,
          handNo: r.handNo,
          board: r.board.map(cardToString).join(' '),
          pot,
          rake: r.rake,
          details: {
            board2: rt.lastResult.board2,
            players,
            pots: rt.lastResult.pots,
            shown: rt.lastResult.shown,
            actions: g.actions,
            log: r.log,
          } as unknown as Prisma.InputJsonValue,
          playerIds: players.map((p) => p.userId),
        },
      }),
      ...g.seats.flatMap((s) =>
        s ? [this.prisma.tableSeat.update({ where: { tableId_userId: { tableId: rt.table.id, userId: s.userId } }, data: { stack: s.stack } })] : [],
      ),
    ]);

    for (let i = 0; i < g.seats.length; i++) {
      const s = g.seats[i];
      if (s?.leaving) await this.standUp(rt, i);
      // Igrač bez žetona ima vremena da dopuni; posle toga ustaje kao i onaj koji ne igra.
      else if (s && s.stack === 0) {
        if (!rt.sitOutSince.has(s.userId)) rt.sitOutSince.set(s.userId, Date.now());
        this.startRebuy(rt, s.userId);
      }
    }
    if (rt.closing) await this.shutdown(rt);
  }

  /**
   * All-in: šanse za pobedu svakog igrača pre flopa, na flopu i na turnu (kao na GG).
   * Računa se u pozadini (u delovima) i šalje igračima čim je gotovo.
   */
  private async computeEquity(rt: Runtime, r: HandResult) {
    const from = r.runoutFrom ?? 5;
    const holes: Record<number, Card[]> = Object.fromEntries(r.shown.map((s) => [s.seat, s.hole]));
    if (Object.keys(holes).length < 2) return;
    const stages = [...new Set([from, 3, 4])].filter((l) => l >= from && l < 5).sort((a, b) => a - b);
    const out: { board: number; odds: Record<number, number> }[] = [];
    for (const l of stages) out.push({ board: l, odds: await equityAsync(rt.table.variant, holes, r.board.slice(0, l)) });
    if (rt.lastResult && rt.lastResult.handNo === r.handNo) {
      rt.lastResult.equity = out;
      await this.broadcast(rt);
    }
  }

  /** Igrači koji predugo ne igraju ustaju sa stola. */
  private async standUpIdle(rt: Runtime) {
    const now = Date.now();
    let changed = false;
    for (let i = 0; i < rt.game.seats.length; i++) {
      const s = rt.game.seats[i];
      if (!s) continue;
      const since = rt.sitOutSince.get(s.userId);
      if ((s.sittingOut || s.stack === 0) && since && now - since > SIT_OUT_LIMIT_MS) {
        this.server?.to(`user:${s.userId}`).emit('kicked', { tableId: rt.table.id, reason: 'Predugo niste igrali, žetoni su vraćeni na nalog.' });
        await this.standUp(rt, i);
        changed = true;
      }
    }
    if (changed) await this.broadcast(rt);
  }

  /** Igrač ustaje: žetoni sa stola se vraćaju na nalog. */
  private async standUp(rt: Runtime, index: number) {
    const s = rt.game.seats[index]!;
    rt.game.stand(index);
    rt.sitOutSince.delete(s.userId);
    this.clearRebuy(rt, s.userId);
    await this.cashOutRow(rt.table.id, s.userId, undefined, s.stack);
    await this.balanceChanged(s.userId);
    if (!rt.closing) this.offerSeat(rt);
    this.lobbyChanged();
  }

  // ---------- Rebuy posle gubitka svih žetona ----------

  /** Igrač bez žetona ima REBUY_MS da dopuni; ako ne dopuni, ustaje i oslobađa mesto. */
  private startRebuy(rt: Runtime, userId: string) {
    if (rt.rebuy.has(userId)) return;
    const until = Date.now() + REBUY_MS;
    const timer = setTimeout(() => {
      void this.exclusive(rt, async () => {
        rt.rebuy.delete(userId);
        const i = rt.game.seatOf(userId);
        const s = i >= 0 ? rt.game.seats[i] : null;
        if (!s || s.stack > 0 || (rt.game.inProgress && s.inHand)) return;
        this.server?.to(`user:${userId}`).emit('kicked', { tableId: rt.table.id, reason: 'Vreme za rebuy je isteklo, mesto je oslobođeno.' });
        await this.standUp(rt, i);
        await this.broadcast(rt);
      }).catch((e) => this.log.error(e));
    }, REBUY_MS);
    rt.rebuy.set(userId, { until, timer });
    this.nudge(userId, {
      title: 'Ostali ste bez žetona',
      body: `Sto „${rt.table.name}“ — dopunite ili ustanite u roku od ${Math.round(REBUY_MS / 60000)} min.`,
      tableId: rt.table.id,
      tag: `turn-${rt.table.id}`,
    });
  }

  private clearRebuy(rt: Runtime, userId: string) {
    const r = rt.rebuy.get(userId);
    if (r) clearTimeout(r.timer);
    rt.rebuy.delete(userId);
  }

  // ---------- Izbor igrača i lista čekanja ----------

  /**
   * Igrač pokazuje svoje karte ostalima (jednu ili sve): posle fold-a ili kad je ruka gotova.
   * Ako je ruka gotova, sledeća ruka čeka bar SHOW_MS da svi vide.
   */
  async showCards(userId: string, tableId: string, cards: number[]) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      const g = rt.game;
      const i = g.seatOf(userId);
      if (i < 0) throw new GameError('Ne sedite za ovim stolom.');
      const s = g.seats[i]!;
      if (!s.hole.length) throw new GameError('Nemate karte za pokazivanje.');
      const handOver = !g.inProgress && !!rt.lastResult;
      if (!handOver && !(g.inProgress && s.inHand && s.folded)) {
        throw new GameError('Karte možete pokazati posle fold-a ili kad se ruka završi.');
      }
      const idx = [...new Set(cards.map(Number))].filter((k) => Number.isInteger(k) && k >= 0 && k < s.hole.length);
      if (!idx.length) throw new GameError('Izaberite kartu.');
      const prev = rt.voluntaryShow.get(i) ?? [];
      rt.voluntaryShow.set(i, [...new Set([...prev, ...idx])].sort());
      if (handOver && rt.nextHandTimer && (rt.nextHandAt ?? 0) - Date.now() < SHOW_MS) {
        clearTimeout(rt.nextHandTimer);
        rt.nextHandTimer = undefined;
        this.scheduleNextHandIn(rt, SHOW_MS);
      }
      await this.broadcast(rt);
      return {};
    });
  }

  /** Odgovor na pitanje za run it twice (posle all-in-a). */
  async answerRunTwice(userId: string, tableId: string, yes: boolean) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      const i = rt.game.seatOf(userId);
      if (i < 0) throw new GameError('Ne sedite za ovim stolom.');
      const result = rt.game.answerRunTwice(i, yes);
      await this.afterChange(rt, result);
      return {};
    });
  }

  /** Straddle: važi od sledeće ruke. */
  async setPrefs(userId: string, tableId: string, prefs: { straddle?: boolean }) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      const i = rt.game.seatOf(userId);
      if (i < 0) throw new GameError('Ne sedite za ovim stolom.');
      const s = rt.game.seats[i]!;
      if (prefs.straddle !== undefined) {
        if (prefs.straddle && !rt.table.straddle) throw new GameError('Za ovim stolom nema straddle-a.');
        s.straddle = !!prefs.straddle;
      }
      await this.broadcast(rt);
      return {};
    });
  }

  /** Prijava na listu čekanja (ili odjava). */
  async setWaitlist(userId: string, tableId: string, join: boolean) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      rt.waitlist = rt.waitlist.filter((w) => w.userId !== userId);
      if (join) {
        this.assertUnlocked(tableId);
        if (rt.game.seatOf(userId) >= 0) throw new GameError('Već sedite za ovim stolom.');
        const user = await this.prisma.user.findUniqueOrThrow({ where: { id: userId } });
        if (user.role !== 'PLAYER') throw new GameError('Samo igrači mogu da igraju.');
        rt.waitlist.push({ userId, name: user.displayName });
        this.offerSeat(rt);
      } else if (rt.reservation?.userId === userId) {
        clearTimeout(rt.reservation.timer);
        rt.reservation = null;
        this.offerSeat(rt);
      }
      await this.broadcast(rt);
      this.lobbyChanged();
      return { position: join ? rt.waitlist.findIndex((w) => w.userId === userId) + 1 : 0 };
    });
  }

  /** Ako ima slobodnog mesta, prvi sa liste čekanja dobija ga na kratko (ostali ne mogu da ga zauzmu). */
  private offerSeat(rt: Runtime) {
    if (rt.reservation && rt.reservation.until > Date.now()) return;
    rt.reservation = null;
    if (!rt.game.seats.some((x) => !x)) return;
    const next = rt.waitlist.shift();
    if (!next) return;
    const until = Date.now() + RESERVE_MS;
    const timer = setTimeout(() => {
      void this.exclusive(rt, async () => {
        if (rt.reservation?.userId !== next.userId) return;
        rt.reservation = null;
        this.offerSeat(rt);
        await this.broadcast(rt);
        this.lobbyChanged();
      }).catch((e) => this.log.error(e));
    }, RESERVE_MS);
    rt.reservation = { userId: next.userId, until, timer };
    this.nudge(next.userId, {
      title: 'Mesto je slobodno!',
      body: `Sto „${rt.table.name}“ — imate ${Math.round(RESERVE_MS / 1000)} s da sednete.`,
      tableId: rt.table.id,
      tag: `wait-${rt.table.id}`,
    });
    this.server?.to(`user:${next.userId}`).emit('waitlist:offer', {
      tableId: rt.table.id,
      name: rt.table.name,
      seconds: Math.round(RESERVE_MS / 1000),
    });
  }

  /** Briše sedište iz baze i vraća žetone na nalog (iz memorije ako je poznato, inače iz baze). */
  private async cashOutRow(tableId: string, userId: string, note?: string, stack?: number) {
    await this.wallet.run(async (db) => {
      const row = await db.tableSeat.findUnique({ where: { tableId_userId: { tableId, userId } } });
      if (!row) return;
      await db.tableSeat.delete({ where: { tableId_userId: { tableId, userId } } });
      const amount = stack ?? row.stack;
      if (amount > 0) await this.wallet.change(db, userId, 'CASH_OUT', amount, { tableId, note });
    });
  }

  /** Za izmene podešavanja stola: sto mora biti zatvoren. */
  assertClosed(tableId: string) {
    if (this.runtimes.has(tableId)) throw new BadRequestException('Zatvorite sto pre izmene podešavanja.');
  }

  assertExists(tableId: string) {
    if (!this.runtimes.has(tableId)) throw new NotFoundException('Sto nije otvoren.');
  }
}
