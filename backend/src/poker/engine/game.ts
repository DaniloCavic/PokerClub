import { Card, cardToString, shuffledDeck } from './cards';
import { bestHoldem, bestOmaha, HandValue } from './evaluator';

export type Variant = 'HOLDEM' | 'OMAHA';
export type Street = 'preflop' | 'flop' | 'turn' | 'river' | 'showdown';
export type ActionType = 'fold' | 'check' | 'call' | 'raise';

export interface GameConfig {
  variant: Variant;
  smallBlind: number;
  bigBlind: number;
  maxSeats: number;
  /** Rake u baznim poenima: 500 = 5 %. 0 = bez rake-a. */
  rakeBps: number;
  /** Najviše rake-a po ruci; 0 = bez ograničenja. */
  rakeCap: number;
  /** Ante koji pre deljenja plaća svaki igrač koji dobija karte (0 = bez ante-a). */
  ante?: number;
  /** Dozvoljen straddle: igrač posle velikog blajnda može unapred da stavi dva velika blajnda. */
  straddle?: boolean;
}

export interface StartOptions {
  /** Bomb pot: svaki igrač stavlja ovaj iznos u pot, nema blajndova, odmah se deli flop. 0 = obična ruka. */
  bombPot?: number;
}

export interface Seat {
  userId: string;
  name: string;
  stack: number;
  sittingOut: boolean;
  /** Igrač napušta sto: ne dobija nove ruke, ustaje kad se ruka završi. */
  leaving: boolean;
  // Stanje u ruci koja je u toku:
  inHand: boolean;
  hole: Card[];
  folded: boolean;
  allIn: boolean;
  /** Uloženo u ovoj rundi ulaganja. */
  bet: number;
  /** Ukupno uloženo u ovoj ruci. */
  committed: number;
  /** Nivo punog ulaganja kada je igrač poslednji put odigrao (-1 = nije još igrao u ovoj rundi). */
  actedLevel: number;
  lastAction: string | null;
  /** Poslednji potez u ovoj rundi za prikaz (iznos = ukupan ulog igrača u rundi posle poteza). */
  lastAct: SeatAct | null;
  /** Igrač želi straddle kad je prvi posle velikog blajnda. */
  straddle?: boolean;
  /** Igrač pristaje da se kod all-in-a karte dele dva puta (run it twice). */
  runTwice?: boolean;
}

export type ActKind = 'ante' | 'bomb' | 'straddle' | 'sb' | 'bb' | 'fold' | 'check' | 'call' | 'bet' | 'raise' | 'allin';
export interface SeatAct {
  type: ActKind;
  amount: number;
}

/** Jedan potez u ruci (za spisak poteza na stolu). */
export interface ActionEntry extends SeatAct {
  seat: number;
  name: string;
  street: Street;
}

export interface Pot {
  amount: number;
  eligible: number[];
}

export interface PotResult {
  amount: number;
  winners: { seat: number; amount: number }[];
  handName: string | null;
  /** Run it twice: kojem deljenju pripada ova polovina pota (1 ili 2). */
  run?: 1 | 2;
}

export interface HandResult {
  handNo: number;
  board: Card[];
  /** Run it twice: drugi sto (karte podeljene drugi put). */
  board2?: Card[];
  pots: PotResult[];
  rake: number;
  /** Ukupno dobijeno po sedištu (bez vraćenog nepokrivenog uloga). */
  won: Record<number, number>;
  /** Ruke otkrivene na kraju (samo ako je bilo otvaranja karata). */
  shown: { seat: number; hole: Card[]; handName: string; best: Card[]; handName2?: string; best2?: Card[] }[];
  log: string[];
}

export interface LegalActions {
  fold: boolean;
  check: boolean;
  /** Iznos za dorovnjavanje (0 = nema). */
  call: number;
  /** Najmanji i najveći iznos "povisi na" (ukupni ulog u rundi). null = povišenje nije dozvoljeno. */
  minRaiseTo: number | null;
  maxRaiseTo: number | null;
}

export class GameError extends Error {}

const HOLE_CARDS: Record<Variant, number> = { HOLDEM: 2, OMAHA: 4 };

/**
 * Jedan sto za cash igru: sedišta, dugme i ruka u toku.
 * Čista logika bez tajmera i baze — server poziva metode i čita stanje.
 * Hold'em je no-limit, Omaha je pot-limit.
 */
export class PokerGame {
  readonly seats: (Seat | null)[];
  button = -1;
  handNo = 0;
  // Ruka u toku:
  inProgress = false;
  street: Street = 'preflop';
  board: Card[] = [];
  private deck: Card[] = [];
  /** Žetoni iz prethodnih rundi ulaganja. */
  collected = 0;
  currentBet = 0;
  /** Veličina poslednjeg punog povišenja (najmanje povišenje). */
  lastRaise = 0;
  /** Ulog posle poslednjeg punog uloga/povišenja; nepotpun all-in ga ne menja. */
  fullBetLevel = 0;
  toAct = -1;
  sbSeat = -1;
  bbSeat = -1;
  /** Igrač koji je stavio straddle u ovoj ruci (-1 = nema). */
  straddleSeat = -1;
  /** Iznos bomb pota u ovoj ruci (0 = obična ruka). */
  bombPot = 0;
  log: string[] = [];
  /** Potezi u ruci koja je u toku. */
  actions: ActionEntry[] = [];

  constructor(readonly config: GameConfig) {
    this.seats = Array.from({ length: config.maxSeats }, () => null);
  }

  // ---------- Sedišta ----------

  sit(index: number, userId: string, name: string, stack: number) {
    if (index < 0 || index >= this.seats.length) throw new GameError('Ne postoji to mesto.');
    if (this.seats[index]) throw new GameError('Mesto je zauzeto.');
    if (this.seatOf(userId) >= 0) throw new GameError('Već sedite za ovim stolom.');
    this.seats[index] = {
      userId, name, stack,
      sittingOut: false, leaving: false,
      inHand: false, hole: [], folded: false, allIn: false,
      bet: 0, committed: 0, actedLevel: -1, lastAction: null, lastAct: null,
      straddle: false, runTwice: false,
    };
  }

  /** Uklanja igrača i vraća njegov stek. Tokom ruke samo ako nije u njoj. */
  stand(index: number): number {
    const s = this.seats[index];
    if (!s) throw new GameError('Mesto je prazno.');
    if (this.inProgress && s.inHand) throw new GameError('Igrač je u ruci.');
    this.seats[index] = null;
    return s.stack;
  }

  seatOf(userId: string): number {
    return this.seats.findIndex((s) => s?.userId === userId);
  }

  /** Igrači koji mogu dobiti sledeću ruku. */
  readySeats(): number[] {
    return this.indices().filter((i) => {
      const s = this.seats[i]!;
      return s.stack > 0 && !s.sittingOut && !s.leaving;
    });
  }

  canStart() {
    return !this.inProgress && this.readySeats().length >= 2;
  }

  private indices(): number[] {
    return this.seats.map((s, i) => (s ? i : -1)).filter((i) => i >= 0);
  }

  /** Sledeće sedište posle `from` (u krug) koje zadovoljava uslov. */
  private next(from: number, pred: (s: Seat, i: number) => boolean): number {
    const n = this.seats.length;
    for (let k = 1; k <= n; k++) {
      const i = (from + k + n) % n;
      const s = this.seats[i];
      if (s && pred(s, i)) return i;
    }
    return -1;
  }

  // ---------- Početak ruke ----------

  startHand(deck: Card[] = shuffledDeck(), opts: StartOptions = {}) {
    if (!this.canStart()) throw new GameError('Nema dovoljno igrača za ruku.');
    const ready = new Set(this.readySeats());
    for (const i of this.indices()) {
      const s = this.seats[i]!;
      Object.assign(s, {
        inHand: ready.has(i), hole: [], folded: false, allIn: false,
        bet: 0, committed: 0, actedLevel: -1, lastAction: null, lastAct: null,
      });
    }
    this.handNo++;
    this.inProgress = true;
    this.street = 'preflop';
    this.board = [];
    this.deck = [...deck];
    this.collected = 0;
    this.log = [];
    this.actions = [];
    this.straddleSeat = -1;
    this.bombPot = Math.max(0, Math.floor(opts.bombPot ?? 0));

    const inHand = (s: Seat) => s.inHand;
    this.button = this.next(this.button < 0 ? this.seats.length - 1 : this.button, inHand);
    const headsUp = ready.size === 2;
    // U igri jedan na jedan dugme je mali blajnd.
    this.sbSeat = headsUp ? this.button : this.next(this.button, inHand);
    this.bbSeat = this.next(this.sbSeat, inHand);

    this.log.push(
      `Ruka #${this.handNo} (${this.config.variant === 'HOLDEM' ? "Hold'em" : 'Omaha'})${this.bombPot ? ', BOMB POT' : ''}, dugme: ${this.seats[this.button]!.name}`,
    );

    const holeCount = HOLE_CARDS[this.config.variant];
    for (let k = 0; k < holeCount; k++) {
      let i = this.sbSeat;
      for (let n = 0; n < ready.size; n++) {
        this.seats[i]!.hole.push(this.draw());
        i = this.next(i, inHand);
      }
    }

    // Bomb pot: svi stavljaju isti iznos u pot, nema blajndova ni runde pre flopa.
    if (this.bombPot > 0) {
      let i = this.sbSeat;
      for (let n = 0; n < ready.size; n++) {
        const s = this.seats[i]!;
        const paid = Math.min(this.bombPot, s.stack);
        s.stack -= paid;
        s.committed += paid;
        this.collected += paid;
        if (s.stack === 0) s.allIn = true;
        this.actions.push({ seat: i, name: s.name, street: 'preflop', type: 'bomb', amount: paid });
        this.log.push(`${s.name}: bomb pot ${paid}${s.allIn ? ' (all-in)' : ''}`);
        i = this.next(i, inHand);
      }
      this.sbSeat = -1;
      this.bbSeat = -1;
      this.currentBet = 0;
      this.lastRaise = this.config.bigBlind;
      this.fullBetLevel = 0;
      this.dealStreet();
      return this.advanceIfDone();
    }

    // Ante: svaki igrač u ruci stavlja ga direktno u pot (ne računa se kao ulog u rundi).
    const ante = this.config.ante ?? 0;
    if (ante > 0) {
      let i = this.sbSeat;
      for (let n = 0; n < ready.size; n++) {
        const s = this.seats[i]!;
        const paid = Math.min(ante, s.stack);
        s.stack -= paid;
        s.committed += paid;
        this.collected += paid;
        if (s.stack === 0) s.allIn = true;
        this.actions.push({ seat: i, name: s.name, street: 'preflop', type: 'ante', amount: paid });
        this.log.push(`${s.name}: ante ${paid}${s.allIn ? ' (all-in)' : ''}`);
        i = this.next(i, inHand);
      }
    }

    this.post(this.sbSeat, this.config.smallBlind, 'mali blajnd', 'sb');
    this.post(this.bbSeat, this.config.bigBlind, 'veliki blajnd', 'bb');
    this.currentBet = this.config.bigBlind;
    this.lastRaise = this.config.bigBlind;
    this.fullBetLevel = this.config.bigBlind;
    this.toAct = this.next(this.bbSeat, (s) => this.canAct(s));

    // Straddle: prvi posle velikog blajnda (samo za stolom sa 3+ igrača) stavlja dva velika blajnda
    // pre nego što vidi karte i igra poslednji pre flopa.
    const utg = this.next(this.bbSeat, inHand);
    const st = this.seats[utg];
    if (this.config.straddle && ready.size >= 3 && st && st.straddle && this.canAct(st) && st.stack > 2 * this.config.bigBlind) {
      const amount = 2 * this.config.bigBlind;
      this.post(utg, amount, 'straddle', 'straddle');
      this.straddleSeat = utg;
      this.currentBet = amount;
      this.lastRaise = amount;
      this.fullBetLevel = amount;
      this.toAct = this.next(utg, (s) => this.canAct(s));
    }
    return this.advanceIfDone();
  }

  private draw(): Card {
    const c = this.deck.shift();
    if (c === undefined) throw new Error('Špil je prazan.');
    return c;
  }

  private post(i: number, amount: number, label: string, type: ActKind) {
    const s = this.seats[i]!;
    const paid = Math.min(amount, s.stack);
    this.putIn(s, paid);
    this.record(i, type, paid);
    this.log.push(`${s.name}: ${label} ${paid}${s.allIn ? ' (all-in)' : ''}`);
  }

  private putIn(s: Seat, amount: number) {
    s.stack -= amount;
    s.bet += amount;
    s.committed += amount;
    if (s.stack === 0) s.allIn = true;
  }

  private record(seat: number, type: ActKind, amount: number) {
    const s = this.seats[seat]!;
    s.lastAct = { type, amount };
    this.actions.push({ seat, name: s.name, street: this.street, type, amount });
  }

  private canAct(s: Seat) {
    return s.inHand && !s.folded && !s.allIn;
  }

  private live(): number[] {
    return this.indices().filter((i) => this.seats[i]!.inHand && !this.seats[i]!.folded);
  }

  // ---------- Potezi ----------

  /** Ukupno u potu, uključujući uloge u tekućoj rundi. */
  potTotal(): number {
    return this.collected + this.indices().reduce((sum, i) => sum + this.seats[i]!.bet, 0);
  }

  legalActions(index: number): LegalActions | null {
    if (!this.inProgress || index !== this.toAct) return null;
    const s = this.seats[index]!;
    const toCall = Math.min(this.currentBet - s.bet, s.stack);
    const myMax = s.bet + s.stack;

    // Povišenje nema smisla ako niko drugi ne može da odgovori.
    const othersMax = Math.max(
      0,
      ...this.live().filter((i) => i !== index).map((i) => this.seats[i]!).filter((o) => !o.allIn)
        .map((o) => o.bet + o.stack),
    );
    let maxTo = Math.min(myMax, Math.max(othersMax, this.currentBet));
    if (this.config.variant === 'OMAHA') {
      // Pot-limit: najviše = ulog + (pot + dorovnjavanje).
      const potAfterCall = this.potTotal() + (this.currentBet - s.bet);
      maxTo = Math.min(maxTo, this.currentBet + potAfterCall);
    }
    let minTo = this.currentBet + this.lastRaise;
    const reopened = s.actedLevel < this.fullBetLevel;
    let canRaise = reopened && maxTo > this.currentBet;
    if (canRaise && minTo > maxTo) {
      // Manje od punog povišenja je dozvoljeno samo kao all-in.
      if (maxTo === myMax) minTo = maxTo;
      else canRaise = false;
    }
    return {
      fold: true,
      check: toCall === 0,
      call: toCall,
      minRaiseTo: canRaise ? minTo : null,
      maxRaiseTo: canRaise ? maxTo : null,
    };
  }

  act(index: number, type: ActionType, raiseTo?: number): HandResult | null {
    const legal = this.legalActions(index);
    if (!legal) throw new GameError('Niste na potezu.');
    const s = this.seats[index]!;

    switch (type) {
      case 'fold':
        s.folded = true;
        s.lastAction = 'Fold';
        this.record(index, 'fold', 0);
        break;
      case 'check':
        if (!legal.check) throw new GameError('Ne možete da čekirate — morate da dorovnate ili odustanete.');
        s.lastAction = 'Check';
        this.record(index, 'check', 0);
        break;
      case 'call':
        if (legal.call === 0) throw new GameError('Nema šta da se dorovna.');
        this.putIn(s, legal.call);
        s.lastAction = s.allIn ? 'All-in' : `Call ${legal.call}`;
        this.record(index, s.allIn ? 'allin' : 'call', s.bet);
        break;
      case 'raise': {
        if (legal.minRaiseTo === null || legal.maxRaiseTo === null) throw new GameError('Povišenje nije dozvoljeno.');
        const to = Math.floor(Number(raiseTo));
        if (!Number.isFinite(to) || to < legal.minRaiseTo || to > legal.maxRaiseTo) {
          throw new GameError(`Ulog mora biti između ${legal.minRaiseTo} i ${legal.maxRaiseTo}.`);
        }
        const increase = to - this.currentBet;
        const wasBet = this.currentBet === 0;
        this.putIn(s, to - s.bet);
        if (increase >= this.lastRaise || wasBet) {
          // Puno povišenje (ili prvi ulog u rundi) ponovo otvara akciju svima.
          this.lastRaise = Math.max(increase, this.lastRaise);
          this.fullBetLevel = to;
        }
        this.currentBet = to;
        s.lastAction = s.allIn ? `All-in ${to}` : `${wasBet ? 'Bet' : 'Raise'} ${to}`;
        this.record(index, s.allIn ? 'allin' : wasBet ? 'bet' : 'raise', to);
        break;
      }
      default:
        throw new GameError('Nepoznat potez.');
    }
    s.actedLevel = this.fullBetLevel;
    this.log.push(`${s.name}: ${s.lastAction}`);
    this.toAct = this.next(index, (o) => this.canAct(o));
    return this.advanceIfDone();
  }

  /** Odustajanje van reda (igrač napušta sto ili je blokiran). */
  forceFold(index: number): HandResult | null {
    const s = this.seats[index];
    if (!this.inProgress || !s?.inHand || s.folded) return null;
    if (index === this.toAct) return this.act(index, 'fold');
    s.folded = true;
    s.lastAction = 'Fold';
    this.record(index, 'fold', 0);
    this.log.push(`${s.name}: Fold`);
    return this.advanceIfDone();
  }

  /** Podrazumevani potez kad istekne vreme: check ako može, inače fold. */
  timeoutAction(): HandResult | null {
    const legal = this.legalActions(this.toAct);
    if (!legal) return null;
    return this.act(this.toAct, legal.check ? 'check' : 'fold');
  }

  private needsAction(i: number, activeCount: number): boolean {
    const s = this.seats[i]!;
    if (!this.canAct(s)) return false;
    if (s.bet < this.currentBet) return true;
    // Poslednji igrač koji može da igra, a već je pokrio ulog — nema kome da odgovara.
    if (activeCount <= 1) return false;
    return s.actedLevel === -1;
  }

  private advanceIfDone(): HandResult | null {
    for (;;) {
      if (this.live().length === 1) return this.finish();
      const active = this.indices().filter((i) => this.canAct(this.seats[i]!));
      const pending = active.filter((i) => this.needsAction(i, active.length));
      if (pending.length > 0) {
        if (!pending.includes(this.toAct)) this.toAct = this.next(this.toAct, (_, i) => pending.includes(i));
        return null;
      }
      this.endRound();
      if (this.street === 'river') return this.finish();
      // Kad niko ili samo jedan igrač može da igra, ostatak stola se deli na kraju ruke
      // (tada je moguć i run it twice).
      if (this.indices().filter((i) => this.canAct(this.seats[i]!)).length <= 1) return this.finish();
      this.dealStreet();
    }
  }

  /** Kraj runde ulaganja: vraća nepokriveni ulog i skuplja uloge u pot. */
  private endRound() {
    const inHand = this.indices().filter((i) => this.seats[i]!.inHand);
    const bets = inHand.map((i) => this.seats[i]!.bet).sort((a, b) => b - a);
    const top = inHand.find((i) => this.seats[i]!.bet === bets[0]);
    // Nepokriveni ulog se vraća samo igraču koji je još u ruci; odustali gube uloženo.
    if (bets.length >= 2 && bets[0] > bets[1] && top !== undefined && !this.seats[top]!.folded) {
      const s = this.seats[top]!;
      const back = bets[0] - bets[1];
      s.bet -= back;
      s.committed -= back;
      s.stack += back;
      if (s.stack > 0) s.allIn = false;
      this.log.push(`${s.name}: vraćeno nepokriveno ${back}`);
    }
    for (const i of inHand) {
      this.collected += this.seats[i]!.bet;
      this.seats[i]!.bet = 0;
    }
    this.currentBet = 0;
  }

  private dealStreet() {
    const order: Street[] = ['preflop', 'flop', 'turn', 'river'];
    this.street = order[order.indexOf(this.street) + 1];
    this.draw(); // spaljena karta
    const count = this.street === 'flop' ? 3 : 1;
    for (let k = 0; k < count; k++) this.board.push(this.draw());
    this.log.push(`${this.street.toUpperCase()}: ${this.board.map(cardToString).join(' ')}`);
    this.lastRaise = this.config.bigBlind;
    this.fullBetLevel = 0;
    for (const i of this.indices()) {
      const s = this.seats[i]!;
      s.actedLevel = -1;
      if (s.inHand && !s.folded) {
        s.lastAction = null;
        s.lastAct = null;
      }
    }
    this.toAct = this.next(this.button, (s) => this.canAct(s));
  }

  /** Glavni i sporedni potovi iz ukupnih uloga. */
  pots(): Pot[] {
    const inHand = this.indices().filter((i) => this.seats[i]!.inHand);
    const live = new Set(this.live());
    const levels = [...new Set(inHand.filter((i) => live.has(i)).map((i) => this.seats[i]!.committed))].sort((a, b) => a - b);
    const pots: Pot[] = [];
    let prev = 0;
    for (const level of levels) {
      let amount = 0;
      for (const i of inHand) {
        const c = this.seats[i]!.committed;
        amount += Math.max(0, Math.min(c, level) - prev);
      }
      const eligible = [...live].filter((i) => this.seats[i]!.committed >= level);
      if (amount > 0) pots.push({ amount, eligible });
      prev = level;
    }
    // Ulozi odustalih iznad najvišeg nivoa (ne bi trebalo da postoje) idu u poslednji pot.
    const leftover = inHand.reduce((sum, i) => sum + Math.max(0, this.seats[i]!.committed - prev), 0);
    if (leftover > 0) {
      if (pots.length) pots[pots.length - 1].amount += leftover;
      else pots.push({ amount: leftover, eligible: [...live] });
    }
    return pots;
  }

  private finish(): HandResult {
    // Ruka završena odustajanjem može doći usred runde.
    if (this.indices().some((i) => this.seats[i]!.bet > 0)) this.endRound();
    const live = this.live();
    const showdown = live.length > 1;
    // Run it twice: svi igrači u all-in situaciji su pristali, a sto još nije ceo podeljen.
    const runTwice = showdown && this.board.length < 5 && live.every((i) => this.seats[i]!.runTwice);
    const base = [...this.board];
    let board2: Card[] | undefined;
    if (showdown) {
      if (this.board.length < 5) {
        this.runOut(this.board);
        this.log.push(`Sto: ${this.board.map(cardToString).join(' ')}`);
      }
      if (runTwice) {
        board2 = [...base];
        this.runOut(board2);
        this.log.push(`RUN IT TWICE — drugi sto: ${board2.map(cardToString).join(' ')}`);
      }
      this.street = 'showdown';
    }

    const pots = this.pots();
    // Rake: samo ako je podeljen flop ("no flop, no drop").
    let rake = 0;
    const total = pots.reduce((s, p) => s + p.amount, 0);
    if (this.config.rakeBps > 0 && this.board.length >= 3) {
      rake = Math.floor((total * this.config.rakeBps) / 10_000);
      if (this.config.rakeCap > 0) rake = Math.min(rake, this.config.rakeCap);
      let left = rake;
      for (const p of pots) {
        const take = Math.min(left, p.amount);
        p.amount -= take;
        left -= take;
      }
    }

    const evalFn = this.config.variant === 'OMAHA' ? bestOmaha : bestHoldem;
    const valuesFor = (board: Card[]) => {
      const m = new Map<number, HandValue>();
      if (showdown) for (const i of live) m.set(i, evalFn(this.seats[i]!.hole, board));
      return m;
    };
    const values = valuesFor(this.board);
    const values2 = board2 ? valuesFor(board2) : null;

    const won: Record<number, number> = {};
    const potResults: PotResult[] = [];
    const award = (pot: Pot, amount: number, vals: Map<number, HandValue>, run?: 1 | 2) => {
      if (amount <= 0) return;
      let winners = pot.eligible;
      if (showdown && winners.length > 1) {
        const top = Math.max(...winners.map((i) => vals.get(i)!.score));
        winners = winners.filter((i) => vals.get(i)!.score === top);
      }
      // Neparni žeton ide prvom dobitniku levo od dugmeta.
      const ordered = [...winners].sort((a, b) => this.distFromButton(a) - this.distFromButton(b));
      const share = Math.floor(amount / ordered.length);
      let odd = amount - share * ordered.length;
      const res: PotResult = { amount, winners: [], handName: showdown ? vals.get(ordered[0])!.name : null, ...(run ? { run } : {}) };
      for (const i of ordered) {
        const a = share + (odd-- > 0 ? 1 : 0);
        this.seats[i]!.stack += a;
        won[i] = (won[i] ?? 0) + a;
        res.winners.push({ seat: i, amount: a });
      }
      potResults.push(res);
    };
    for (const pot of pots) {
      if (values2) {
        // Svaki pot se deli na pola: prva polovina (sa neparnim žetonom) za prvi sto, druga za drugi.
        const first = Math.ceil(pot.amount / 2);
        award(pot, first, values, 1);
        award(pot, pot.amount - first, values2, 2);
      } else {
        award(pot, pot.amount, values);
      }
    }

    if (rake > 0) this.log.push(`Rake: ${rake}`);
    for (const p of potResults) {
      for (const w of p.winners) {
        this.log.push(
          `${this.seats[w.seat]!.name} dobija ${w.amount}${p.handName ? ` (${p.handName})` : ''}${p.run ? ` — ${p.run}. sto` : ''}`,
        );
      }
    }

    const result: HandResult = {
      handNo: this.handNo,
      board: [...this.board],
      ...(board2 ? { board2 } : {}),
      pots: potResults,
      rake,
      won,
      shown: showdown
        ? live.map((i) => ({
            seat: i,
            hole: [...this.seats[i]!.hole],
            handName: values.get(i)!.name,
            best: values.get(i)!.cards,
            ...(values2 ? { handName2: values2.get(i)!.name, best2: values2.get(i)!.cards } : {}),
          }))
        : [],
      log: [...this.log],
    };
    this.inProgress = false;
    this.collected = 0;
    this.toAct = -1;
    for (const i of this.indices()) this.seats[i]!.inHand = false;
    return result;
  }

  /** Dodeli ostatak stola po ulicama (spaljena karta pre flopa, turna i rivera). */
  private runOut(board: Card[]) {
    while (board.length < 5) {
      this.draw();
      const count = board.length === 0 ? 3 : 1;
      for (let k = 0; k < count; k++) board.push(this.draw());
    }
  }

  private distFromButton(i: number) {
    const n = this.seats.length;
    return (i - this.button + n - 1) % n;
  }
}
