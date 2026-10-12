import { BadRequestException, Injectable, Logger, NotFoundException, OnModuleInit } from '@nestjs/common';
import { PokerTable, Prisma } from '@prisma/client';
import type { Server } from 'socket.io';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { cardToString } from '../poker/engine/cards';
import { ActionType, GameError, HandResult, PokerGame } from '../poker/engine/game';

/** Pauza između dve ruke (da se vidi ko je dobio). */
const BETWEEN_HANDS_MS = Number(process.env.BETWEEN_HANDS_MS || 5000);
/** Igrač koji ne igra (sit out) duže od ovoga automatski ustaje sa stola. */
const SIT_OUT_LIMIT_MS = Number(process.env.SIT_OUT_LIMIT_MS || 10 * 60_000);

interface Runtime {
  table: PokerTable;
  game: PokerGame;
  queue: Promise<unknown>;
  turnTimer?: NodeJS.Timeout;
  turnKey?: string;
  deadline: number | null;
  nextHandTimer?: NodeJS.Timeout;
  /** Stekovi na početku ruke (za istoriju). */
  startStacks: Record<number, number>;
  lastResult: ReturnType<TablesService['resultView']> | null;
  sitOutSince: Map<string, number>;
  /** Sto se zatvara posle ruke koja je u toku. */
  closing: boolean;
}

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

  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
  ) {}

  attachServer(server: Server) {
    this.server = server;
  }

  async onModuleInit() {
    // Posle ponovnog pokretanja ruke u toku su poništene: žetoni sa stola se vraćaju na nalog
    // u iznosu sa početka te ruke (stanje posle poslednje završene ruke).
    const seats = await this.prisma.tableSeat.findMany();
    for (const s of seats) await this.cashOutRow(s.tableId, s.userId, 'Povratak žetona posle ponovnog pokretanja servera');
    if (seats.length) this.log.log(`Vraćeni žetoni za ${seats.length} sedišta.`);
    const open = await this.prisma.pokerTable.findMany({ where: { isOpen: true } });
    for (const t of open) this.createRuntime(t);
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
      }),
      queue: Promise.resolve(),
      deadline: null,
      startStacks: {},
      lastResult: null,
      sitOutSince: new Map(),
      closing: false,
    };
    this.runtimes.set(table.id, rt);
    return rt;
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
      rakePercent: rakePercent(t),
      rakeCap: t.rakeCap,
      actionSeconds: t.actionSeconds,
      players: rt.game.seats.filter(Boolean).length,
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
      serverTime: Date.now(),
      seats: g.seats.map((s, i) => {
        if (!s) return null;
        const own = i === mySeat;
        const visible = own ? s.hole.map(cardToString) : (shown.get(i) ?? null);
        return {
          index: i,
          userId: s.userId,
          name: s.name,
          stack: s.stack,
          bet: s.bet,
          inHand: s.inHand,
          folded: s.folded,
          allIn: s.allIn,
          sittingOut: s.sittingOut,
          leaving: s.leaving,
          lastAction: s.lastAction,
          cards: visible && visible.length ? visible : null,
          cardCount: s.inHand && !s.folded ? s.hole.length : 0,
        };
      }),
      mySeat,
      legal: mySeat >= 0 ? g.legalActions(mySeat) : null,
      result: rt.lastResult,
    };
  }

  private resultView(rt: Runtime, r: HandResult) {
    const name = (seat: number) => rt.game.seats[seat]?.name ?? '?';
    return {
      handNo: r.handNo,
      rake: r.rake,
      pots: r.pots.map((p) => ({
        amount: p.amount,
        handName: p.handName,
        winners: p.winners.map((w) => ({ seat: w.seat, name: name(w.seat), amount: w.amount })),
      })),
      shown: r.shown.map((s) => ({
        seat: s.seat,
        cards: s.hole.map(cardToString),
        best: s.best.map(cardToString),
        handName: s.handName,
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

  // ---------- Radnje igrača ----------

  async sit(userId: string, tableId: string, seat: number, buyIn: number) {
    const rt = this.rt(tableId);
    return this.exclusive(rt, async () => {
      const t = rt.table;
      if (rt.closing) throw new GameError('Sto se zatvara.');
      const user = await this.prisma.user.findUniqueOrThrow({ where: { id: userId } });
      if (user.role !== 'PLAYER') throw new GameError('Samo igrači mogu da sednu za sto.');
      if (rt.game.seatOf(userId) >= 0) throw new GameError('Već sedite za ovim stolom.');
      if (!Number.isInteger(seat) || seat < 0 || seat >= t.maxSeats) throw new GameError('Ne postoji to mesto.');
      if (rt.game.seats[seat]) throw new GameError('Mesto je zauzeto.');
      if (!Number.isInteger(buyIn) || buyIn < t.minBuyIn || buyIn > t.maxBuyIn) {
        throw new GameError(`Ulaz mora biti između ${t.minBuyIn} i ${t.maxBuyIn}.`);
      }
      if (user.balance < buyIn) throw new GameError('Nemate dovoljno žetona na nalogu.');
      await this.wallet.run(async (db) => {
        await this.wallet.change(db, userId, 'BUY_IN', -buyIn, { tableId, note: t.name });
        await db.tableSeat.create({ data: { tableId, userId, seat, stack: buyIn } });
      });
      rt.game.sit(seat, userId, user.displayName, buyIn);
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
          await this.wallet.change(db, userId, 'BUY_IN', -amount, { tableId, note: `${rt.table.name} (dopuna)` });
          await db.tableSeat.update({ where: { tableId_userId: { tableId, userId } }, data: { stack: { increment: amount } } });
        });
      } catch (e) {
        if (e instanceof BadRequestException) throw new GameError(e.message);
        throw e;
      }
      s.stack += amount;
      if (!s.sittingOut) rt.sitOutSince.delete(userId);
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
    if (!this.runtimes.has(table.id)) this.createRuntime(table);
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

  private armTurnTimer(rt: Runtime) {
    const g = rt.game;
    if (!g.inProgress || g.toAct < 0) {
      clearTimeout(rt.turnTimer);
      rt.turnKey = undefined;
      rt.deadline = null;
      return;
    }
    const key = `${g.handNo}:${g.street}:${g.toAct}:${g.currentBet}:${g.seats[g.toAct]!.bet}`;
    if (key === rt.turnKey) return;
    clearTimeout(rt.turnTimer);
    rt.turnKey = key;
    const ms = rt.table.actionSeconds * 1000;
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
        rt.startStacks = {};
        rt.game.seats.forEach((s, i) => {
          if (s) rt.startStacks[i] = s.stack;
        });
        const result = rt.game.startHand();
        await this.afterChange(rt, result);
      }).catch((e) => this.log.error(e));
    }, rt.lastResult ? BETWEEN_HANDS_MS : 1000);
  }

  private async handFinished(rt: Runtime, r: HandResult) {
    const g = rt.game;
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

    await this.prisma.$transaction([
      this.prisma.hand.create({
        data: {
          tableId: rt.table.id,
          handNo: r.handNo,
          board: r.board.map(cardToString).join(' '),
          pot,
          rake: r.rake,
          details: { players, pots: rt.lastResult.pots, shown: rt.lastResult.shown, log: r.log } as unknown as Prisma.InputJsonValue,
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
      else if (s && s.stack === 0 && !rt.sitOutSince.has(s.userId)) rt.sitOutSince.set(s.userId, Date.now());
    }
    if (rt.closing) await this.shutdown(rt);
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
    await this.cashOutRow(rt.table.id, s.userId, rt.table.name, s.stack);
    await this.balanceChanged(s.userId);
    this.lobbyChanged();
  }

  /** Briše sedište iz baze i vraća žetone na nalog (iz memorije ako je poznato, inače iz baze). */
  private async cashOutRow(tableId: string, userId: string, note: string, stack?: number) {
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
