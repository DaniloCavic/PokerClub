import { Card, parseCard, parseCards } from './cards';
import { bestHoldem, bestOmaha, evaluate5, HandCategory, categoryOf } from './evaluator';
import { GameConfig, HandResult, PokerGame } from './game';

const holdem: GameConfig = { variant: 'HOLDEM', smallBlind: 5, bigBlind: 10, maxSeats: 6, rakeBps: 0, rakeCap: 0 };
const omaha: GameConfig = { ...holdem, variant: 'OMAHA' };

/**
 * Pravi špil tako da igrači dobiju zadate karte (deli se od malog blajnda, karta po karta u krug),
 * a sto dobije zadati flop/turn/river (sa spaljenom kartom pre svake ulice).
 */
function deckFor(holeBySeatOrder: string[], board: string): Card[] {
  const hands = holeBySeatOrder.map(parseCards);
  const per = hands[0].length;
  const deck: Card[] = [];
  for (let k = 0; k < per; k++) for (const h of hands) deck.push(h[k]);
  const b = parseCards(board);
  const used = new Set([...deck, ...b]);
  const filler = Array.from({ length: 52 }, (_, i) => i).filter((c) => !used.has(c));
  const burn = () => filler.shift()!;
  deck.push(burn(), b[0], b[1], b[2], burn(), b[3], burn(), b[4]);
  return [...deck, ...filler];
}

const cat = (s: string) => categoryOf(evaluate5(parseCards(s)));
const stacks = (g: PokerGame) => g.seats.map((s) => s?.stack ?? null);
const chipsTotal = (g: PokerGame) => g.seats.reduce((sum, s) => sum + (s?.stack ?? 0), 0) + g.potTotal();

describe('ocena ruku', () => {
  it('prepoznaje kategorije', () => {
    expect(cat('As Ks Qs Js Ts')).toBe(HandCategory.StraightFlush);
    expect(cat('9c 9d 9h 9s 2c')).toBe(HandCategory.Quads);
    expect(cat('9c 9d 9h 2s 2c')).toBe(HandCategory.FullHouse);
    expect(cat('2h 7h 9h Jh Ah')).toBe(HandCategory.Flush);
    expect(cat('Ac 2d 3h 4s 5c')).toBe(HandCategory.Straight);
    expect(cat('9c 9d 9h 3s 2c')).toBe(HandCategory.Trips);
    expect(cat('9c 9d 3h 3s 2c')).toBe(HandCategory.TwoPair);
    expect(cat('9c 9d 4h 3s 2c')).toBe(HandCategory.Pair);
    expect(cat('Kc 9d 4h 3s 2c')).toBe(HandCategory.HighCard);
  });

  it('poredi ruke ispravno', () => {
    const v = (s: string) => evaluate5(parseCards(s));
    expect(v('Ac 2d 3h 4s 5c')).toBeLessThan(v('2c 3d 4h 5s 6c')); // točak je najslabija kenta
    expect(v('Ac Ad Kh Ks 2c')).toBeGreaterThan(v('Ac Ad Qh Qs Kc'));
    expect(v('Ac Ad Kh Ks 3c')).toBeGreaterThan(v('Ac Ad Kh Ks 2c')); // kiker
    expect(v('Ac Kd Qh Js 9c')).toBe(v('As Kh Qd Jc 9s')); // podela
    expect(v('2c 2d 2h 3s 3c')).toBeGreaterThan(v('Ah Kh Qh Jh 9h')); // ful > boja
  });

  it("Hold'em koristi najboljih pet od sedam", () => {
    const r = bestHoldem(parseCards('Ah Kh'), parseCards('Qh Jh Th 2c 3d'));
    expect(r.name).toBe('Rojal flaš');
    const board = bestHoldem(parseCards('2c 3d'), parseCards('As Ks Qs Js Ts'));
    expect(board.category).toBe(HandCategory.StraightFlush);
  });

  it('Omaha mora koristiti tačno dve karte iz ruke', () => {
    // Četiri herca na stolu + jedan u ruci NIJE boja u Omahi.
    const r = bestOmaha(parseCards('Ah 2c 3d 4s'), parseCards('Kh Qh Jh 9h 5c'));
    expect(r.category).not.toBe(HandCategory.Flush);
    // Kenta sa stola ne važi bez dve karte iz ruke.
    const s = bestOmaha(parseCards('2c 2d 7s 7h'), parseCards('Ts Jd Qc Kh Ac'));
    expect(s.category).toBe(HandCategory.Pair);
    const f = bestOmaha(parseCards('Ah Kh 2c 3d'), parseCards('Qh Jh 9h 5c 4s'));
    expect(f.category).toBe(HandCategory.Flush);
  });

  it('opisuje ruku sa odlučujućim kartama', () => {
    const d = (h: string, b: string) => bestHoldem(parseCards(h), parseCards(b)).name;
    expect(d('Qc 7d', '2s 5h 9c Jd 3s')).toBe('Visoka karta Q');
    expect(d('Kc Kd', '2s 5h 9c Jd 3s')).toBe('Par K');
    expect(d('Ac 9d', 'As 9h 2c Jd 3s')).toBe('Dva para A i 9');
    expect(d('Tc Td', 'Ts 9h 2c Jd 3s')).toBe('Triling 10');
    expect(d('Ac 2d', '3s 4h 5c Jd Ks')).toBe('Kenta do 5');
    expect(d('Ah 2h', '7h 9h Kh Jd 3s')).toBe('Boja do A');
    expect(d('7c 7d', '7s Ah Ac Jd 3s')).toBe('Ful 7 preko A');
    expect(d('8c 8d', '8s 8h Ac Jd 3s')).toBe('Poker 8');
    expect(d('5h 6h', '7h 8h 9h Jd 3s')).toBe('Kenta u boji do 9');
  });

  it('parsira karte', () => {
    expect(parseCard('As')).toBe((12 << 2) | 3);
    expect(() => parseCard('Xx')).toThrow();
  });
});

describe("Hold'em ruka", () => {
  function threeHanded(config = holdem, st = [1000, 1000, 1000]) {
    const g = new PokerGame(config);
    g.sit(0, 'a', 'Ana', st[0]);
    g.sit(1, 'b', 'Bojan', st[1]);
    g.sit(2, 'c', 'Ceca', st[2]);
    return g;
  }

  it('postavlja dugme, blajndove i redosled', () => {
    const g = threeHanded();
    g.startHand();
    expect(g.button).toBe(0);
    expect(g.sbSeat).toBe(1);
    expect(g.bbSeat).toBe(2);
    expect(g.toAct).toBe(0); // posle velikog blajnda
    expect(g.seats[1]!.bet).toBe(5);
    expect(g.seats[2]!.bet).toBe(10);
    expect(g.seats[0]!.hole).toHaveLength(2);
    expect(g.legalActions(0)).toEqual({ fold: true, check: false, call: 10, minRaiseTo: 20, maxRaiseTo: 1000 });
    expect(g.legalActions(1)).toBeNull();
  });

  it('svi odustaju — veliki blajnd dobija bez rake-a', () => {
    const g = threeHanded({ ...holdem, rakeBps: 500 });
    g.startHand();
    g.act(0, 'fold');
    const r = g.act(1, 'fold')!;
    expect(r).not.toBeNull();
    expect(r.rake).toBe(0);
    expect(stacks(g)).toEqual([1000, 995, 1005, null, null, null]);
    expect(r.shown).toEqual([]);
  });

  it('beleži poteze za prikaz', () => {
    const g = threeHanded();
    g.startHand();
    g.act(0, 'raise', 30);
    g.act(1, 'call');
    expect(g.seats[0]!.lastAct).toEqual({ type: 'raise', amount: 30 });
    expect(g.seats[1]!.lastAct).toEqual({ type: 'call', amount: 30 });
    expect(g.seats[2]!.lastAct).toEqual({ type: 'bb', amount: 10 });
    expect(g.actions.map((a) => a.type)).toEqual(['sb', 'bb', 'raise', 'call']);
  });

  it('veliki blajnd ima opciju kad svi samo dorovnaju', () => {
    const g = threeHanded();
    g.startHand();
    g.act(0, 'call');
    g.act(1, 'call');
    expect(g.toAct).toBe(2);
    expect(g.legalActions(2)).toMatchObject({ check: true, minRaiseTo: 20 });
    g.act(2, 'check');
    expect(g.street).toBe('flop');
    expect(g.board).toHaveLength(3);
    expect(g.toAct).toBe(1); // prvi posle dugmeta
  });

  it('otvaranje karata: bolji dobija, rake se uzima i ograničava', () => {
    const g = threeHanded({ ...holdem, rakeBps: 500, rakeCap: 3 });
    // Redosled deljenja: mali blajnd (1), veliki (2), dugme (0).
    g.startHand(deckFor(['Kc Kd', '7c 2d', 'Ac Ad'], 'As 9h 4c 8s 3h'));
    g.act(0, 'raise', 30);
    g.act(1, 'call');
    g.act(2, 'fold');
    // flop: 1 pa 0
    g.act(1, 'check');
    g.act(0, 'check');
    g.act(1, 'check');
    g.act(0, 'check');
    g.act(1, 'check');
    const r = g.act(0, 'check')!;
    expect(r.rake).toBe(3); // 5 % od 70 = 3
    expect(r.shown.map((s) => s.handName)).toEqual(['Triling A', 'Par K']);
    expect(r.won).toEqual({ 0: 67 });
    expect(stacks(g)).toEqual([1037, 970, 990, null, null, null]);
  });

  it('podela pota i neparni žeton levo od dugmeta', () => {
    const g = threeHanded();
    g.startHand(deckFor(['Kc 2d', 'Kd 3c', '7h 6h'], 'As Qs Js Ts 9d'));
    g.act(0, 'fold');
    g.act(1, 'call');
    g.act(2, 'check');
    for (let i = 0; i < 6; i++) g.act(g.toAct, 'check');
    expect(g.inProgress).toBe(false);
    expect(stacks(g)).toEqual([1000, 1000, 1000, null, null, null]);

    // Pot 25 dele dugme (0) i veliki blajnd (2) — oba imaju kentu do asa; neparni žeton ide igraču 2.
    const g2 = threeHanded();
    g2.startHand(deckFor(['Kc 2d', 'Kd 3c', 'Kh 6h'], 'As Qs Js Ts 9d'));
    g2.act(0, 'call');
    g2.act(1, 'fold'); // mali blajnd ostavlja 5 u potu
    g2.act(2, 'check');
    for (let i = 0; i < 6; i++) g2.act(g2.toAct, 'check');
    expect(stacks(g2)).toEqual([1002, 995, 1003, null, null, null]);
  });

  it('sporedni pot kad je kraći igrač all-in', () => {
    const g = threeHanded(holdem, [1000, 100, 1000]);
    // 1 (kratak) ima najbolju ruku, 0 je drugi, 2 najslabiji. Deli se redom: 1, 2, 0.
    g.startHand(deckFor(['Ac Ad', '2c 7d', 'Kc Kd'], 'As 9h 4c 8s 3h'));
    g.act(0, 'raise', 300);
    g.act(1, 'call'); // all-in 100
    expect(g.seats[1]!.allIn).toBe(true);
    g.act(2, 'call');
    // Flop: 1 je all-in, igraju 2 i 0.
    expect(g.toAct).toBe(2);
    g.act(2, 'raise', 200);
    g.act(0, 'call');
    g.act(2, 'check');
    g.act(0, 'check');
    g.act(2, 'check');
    const r = g.act(0, 'check')!;
    expect(r.pots.map((p) => p.amount)).toEqual([300, 800]);
    expect(r.pots[0].winners).toEqual([{ seat: 1, amount: 300 }]);
    expect(r.pots[1].winners).toEqual([{ seat: 0, amount: 800 }]);
    expect(stacks(g)).toEqual([1300, 300, 500, null, null, null]);
    expect(chipsTotal(g)).toBe(2100);
  });

  it('nepokriveni ulog se vraća', () => {
    const g = threeHanded(holdem, [1000, 1000, 50]);
    g.startHand(deckFor(['Ac Ad', '2c 7d', 'Kc Kd'], 'As 9h 4c 8s 3h'));
    g.act(0, 'raise', 500);
    g.act(1, 'fold');
    const r = g.act(2, 'call')!; // all-in 50, karte se otvaraju do kraja
    expect(r).not.toBeNull();
    expect(r.board).toHaveLength(5);
    expect(r.pots.map((p) => p.amount)).toEqual([105]);
    expect(stacks(g)).toEqual([1055, 995, 0, null, null, null]);
  });

  it('nepotpun all-in ne otvara ponovo povišenje', () => {
    const g = threeHanded(holdem, [1000, 1000, 35]);
    g.startHand();
    g.act(0, 'raise', 20);
    g.act(1, 'call');
    // Veliki blajnd all-in na 35: povišenje za 15 je puno (prethodno je bilo za 10) — dugme sme ponovo da povisi.
    g.act(2, 'raise', 35);
    expect(g.legalActions(0)!.minRaiseTo).toBe(50);

    const h = threeHanded(holdem, [1000, 1000, 45]);
    h.startHand();
    h.act(0, 'raise', 40); // povišenje za 30
    h.act(1, 'call');
    h.act(2, 'raise', 45); // all-in, samo +5 — nepotpuno
    const legal = h.legalActions(0)!;
    expect(legal.call).toBe(5);
    expect(legal.minRaiseTo).toBeNull();
  });

  it('igra jedan na jedan: dugme je mali blajnd i prvi igra pre flopa', () => {
    const g = new PokerGame(holdem);
    g.sit(2, 'a', 'Ana', 500);
    g.sit(4, 'b', 'Bojan', 500);
    g.startHand();
    expect(g.button).toBe(2);
    expect(g.sbSeat).toBe(2);
    expect(g.bbSeat).toBe(4);
    expect(g.toAct).toBe(2);
    g.act(2, 'call');
    g.act(4, 'check');
    expect(g.toAct).toBe(4); // posle flopa prvi je veliki blajnd
    g.act(4, 'fold');
    g.startHand();
    expect(g.button).toBe(4);
  });

  it('kratak veliki blajnd i all-in pre flopa', () => {
    const g = new PokerGame(holdem);
    g.sit(0, 'a', 'Ana', 500);
    g.sit(1, 'b', 'Bojan', 4);
    g.startHand(deckFor(['Ac Ad', 'Kc Kd'], 'As 9h 4c 8s 3h'));
    // 0 je dugme/mali blajnd (5), 1 je veliki blajnd all-in sa 4.
    expect(g.seats[1]!.allIn).toBe(true);
    const r = g.act(0, 'call')!;
    expect(r).not.toBeNull();
    expect(stacks(g)).toEqual([504, 0, null, null, null, null]);
  });

  it('istek vremena: check ako može, inače fold', () => {
    const g = threeHanded();
    g.startHand();
    g.timeoutAction();
    expect(g.seats[0]!.folded).toBe(true);
    g.act(1, 'call');
    g.timeoutAction();
    expect(g.seats[2]!.folded).toBe(false);
    expect(g.street).toBe('flop');
  });

  it('odustajanje van reda završava ruku ako ostane jedan igrač', () => {
    const g = threeHanded();
    g.startHand();
    g.forceFold(1);
    expect(g.toAct).toBe(0);
    g.forceFold(2);
    expect(g.inProgress).toBe(false);
    expect(stacks(g)).toEqual([1015, 995, 990, null, null, null]);
  });

  it('igrači koji ne igraju (sit out, bez žetona) ne dobijaju karte', () => {
    const g = threeHanded(holdem, [1000, 0, 1000]);
    g.seats[2]!.sittingOut = true;
    expect(g.canStart()).toBe(false);
    g.seats[2]!.sittingOut = false;
    g.startHand();
    expect(g.seats[1]!.inHand).toBe(false);
    expect(g.seats[1]!.hole).toEqual([]);
  });

  it('neispravni potezi se odbijaju', () => {
    const g = threeHanded();
    g.startHand();
    expect(() => g.act(1, 'call')).toThrow('Niste na potezu.');
    expect(() => g.act(0, 'check')).toThrow();
    expect(() => g.act(0, 'raise', 15)).toThrow();
    expect(() => g.act(0, 'raise', 5000)).toThrow();
  });
});

describe('ante', () => {
  const withAnte: GameConfig = { ...holdem, ante: 2 };

  it('svaki igrač u ruci plaća ante, igrač na pauzi ne', () => {
    const g = new PokerGame(withAnte);
    g.sit(0, 'a', 'Ana', 1000);
    g.sit(1, 'b', 'Bojan', 1000);
    g.sit(2, 'c', 'Ceca', 1000);
    g.sit(3, 'd', 'Dule', 1000);
    g.seats[3]!.sittingOut = true;
    g.startHand();
    expect(g.collected).toBe(6);
    expect(g.potTotal()).toBe(6 + 5 + 10);
    expect(g.seats[3]!.stack).toBe(1000);
    expect(g.seats[0]!.stack).toBe(998);
    expect(g.actions.filter((a) => a.type === 'ante')).toHaveLength(3);
    // Ante se ne računa u ulog: dugme i dalje dorovnjava 10.
    expect(g.legalActions(0)!.call).toBe(10);
  });

  it('dobitnik dobija i ante-e, žetoni su očuvani', () => {
    const g = new PokerGame(withAnte);
    g.sit(0, 'a', 'Ana', 1000);
    g.sit(1, 'b', 'Bojan', 1000);
    g.sit(2, 'c', 'Ceca', 1000);
    g.startHand();
    g.act(0, 'fold');
    g.act(1, 'fold');
    expect(stacks(g)).toEqual([998, 993, 1009, null, null, null]);
  });

  it('igrač sa manje od ante-a je odmah all-in', () => {
    const g = new PokerGame(withAnte);
    g.sit(0, 'a', 'Ana', 1000);
    g.sit(1, 'b', 'Bojan', 1000);
    g.sit(2, 'c', 'Ceca', 1);
    g.startHand();
    expect(g.seats[2]!.allIn).toBe(true);
    let guard = 0;
    while (g.inProgress && guard++ < 50) {
      const l = g.legalActions(g.toAct)!;
      g.act(g.toAct, l.check ? 'check' : 'call');
    }
    expect(g.seats.reduce((s, x) => s + (x?.stack ?? 0), 0)).toBe(2001);
  });
});

describe('Omaha (pot-limit)', () => {
  it('deli četiri karte i ograničava povišenje na pot', () => {
    const g = new PokerGame(omaha);
    g.sit(0, 'a', 'Ana', 1000);
    g.sit(1, 'b', 'Bojan', 1000);
    g.sit(2, 'c', 'Ceca', 1000);
    g.startHand();
    expect(g.seats[0]!.hole).toHaveLength(4);
    // Pot 15 + dorovnjavanje 10 = 25, najviše povisi na 10 + 25 = 35.
    expect(g.legalActions(0)).toMatchObject({ call: 10, minRaiseTo: 20, maxRaiseTo: 35 });
    g.act(0, 'raise', 35);
    // Pot 50, mali blajnd dorovnjava 30 → 80, najviše 35 + 80 = 115.
    expect(g.legalActions(1)!.maxRaiseTo).toBe(115);
    g.act(1, 'call');
    g.act(2, 'call');
    // Flop: pot 105, ulog najviše 105.
    expect(g.legalActions(1)).toMatchObject({ check: true, minRaiseTo: 10, maxRaiseTo: 105 });
  });

  it('pobednik se određuje po pravilima Omahe', () => {
    const g = new PokerGame(omaha);
    g.sit(0, 'a', 'Ana', 1000);
    g.sit(1, 'b', 'Bojan', 1000);
    // 0 je dugme/mali blajnd. Ana ima jedan herc (nema boju), Bojan par kraljeva iz ruke + K na stolu.
    g.startHand(deckFor(['Ah 2c 3d 4s', 'Kc Kd 7s 8c'], 'Kh Qh Jh 9h 5c'));
    g.act(0, 'call');
    g.act(1, 'check');
    for (let i = 0; i < 6; i++) g.act(g.toAct, 'check');
    expect(stacks(g)).toEqual([990, 1010, null, null, null, null]);
  });
});


/** Špil za all-in pre flopa: karte igrača, pa za svaki sto spaljena + flop, spaljena + turn, spaljena + river. */
function deckRuns(holeBySeatOrder: string[], ...boards: string[]): Card[] {
  const hands = holeBySeatOrder.map(parseCards);
  const deck: Card[] = [];
  for (let k = 0; k < hands[0].length; k++) for (const h of hands) deck.push(h[k]);
  const bs = boards.map(parseCards);
  const used = new Set([...deck, ...bs.flat()]);
  const filler = Array.from({ length: 52 }, (_, i) => i).filter((c) => !used.has(c));
  for (const b of bs) deck.push(filler.shift()!, b[0], b[1], b[2], filler.shift()!, b[3], filler.shift()!, b[4]);
  return [...deck, ...filler];
}

describe('straddle', () => {
  const cfg: GameConfig = { ...holdem, straddle: true };
  function four(config = cfg) {
    const g = new PokerGame(config);
    ['a', 'b', 'c', 'd'].forEach((id, i) => g.sit(i, id, id.toUpperCase(), 1000));
    return g;
  }

  it('prvi posle velikog blajnda stavlja dva velika blajnda i igra poslednji', () => {
    const g = four();
    g.seats[3]!.straddle = true; // dugme 0, SB 1, BB 2, UTG 3
    g.startHand();
    expect(g.straddleSeat).toBe(3);
    expect(g.seats[3]!.bet).toBe(20);
    expect(g.seats[3]!.lastAct).toEqual({ type: 'straddle', amount: 20 });
    expect(g.toAct).toBe(0);
    expect(g.legalActions(0)).toEqual({ fold: true, check: false, call: 20, minRaiseTo: 40, maxRaiseTo: 1000 });
    g.act(0, 'call');
    g.act(1, 'call');
    g.act(2, 'call');
    // Straddle ima opciju kao veliki blajnd.
    expect(g.toAct).toBe(3);
    expect(g.legalActions(3)!.check).toBe(true);
    g.act(3, 'check');
    expect(g.street).toBe('flop');
    expect(g.potTotal()).toBe(80);
  });

  it('nema straddle-a ako sto ne dozvoljava, ako igrač nije izabrao ili u igri jedan na jedan', () => {
    const off = four(holdem);
    off.seats[3]!.straddle = true;
    off.startHand();
    expect(off.straddleSeat).toBe(-1);
    expect(off.currentBet).toBe(10);

    const notChosen = four();
    notChosen.startHand();
    expect(notChosen.straddleSeat).toBe(-1);

    const hu = new PokerGame(cfg);
    hu.sit(0, 'a', 'A', 1000);
    hu.sit(1, 'b', 'B', 1000);
    hu.seats[0]!.straddle = true;
    hu.seats[1]!.straddle = true;
    hu.startHand();
    expect(hu.straddleSeat).toBe(-1);
  });
});

describe('bomb pot', () => {
  it('svi stavljaju iznos u pot, nema blajndova, odmah se deli flop', () => {
    const g = new PokerGame({ ...holdem, ante: 2 });
    ['a', 'b', 'c'].forEach((id, i) => g.sit(i, id, id.toUpperCase(), 1000));
    g.startHand(undefined, { bombPot: 20 });
    expect(g.bombPot).toBe(20);
    expect(g.street).toBe('flop');
    expect(g.board).toHaveLength(3);
    expect(g.potTotal()).toBe(60); // bez ante-a i blajndova
    expect(g.seats.filter(Boolean).map((s) => s!.stack)).toEqual([980, 980, 980]);
    expect(g.sbSeat).toBe(-1);
    expect(g.toAct).toBe(1); // prvi levo od dugmeta
    expect(g.actions.map((a) => a.type)).toEqual(['bomb', 'bomb', 'bomb']);
    g.act(1, 'check');
    g.act(2, 'check');
    g.act(0, 'check');
    expect(g.street).toBe('turn');
  });

  it('kratak igrač je all-in iz bomb pota, žetoni su očuvani', () => {
    const g = new PokerGame(holdem);
    g.sit(0, 'a', 'A', 1000);
    g.sit(1, 'b', 'B', 15);
    g.sit(2, 'c', 'C', 1000);
    g.startHand(undefined, { bombPot: 20 });
    expect(g.seats[1]!.allIn).toBe(true);
    let r: HandResult | null = null;
    while (g.inProgress) r = g.act(g.toAct, 'check');
    expect(r).not.toBeNull();
    expect(chipsTotal(g)).toBe(2015);
  });
});

describe('run it twice', () => {
  const rit: GameConfig = { ...holdem, runItTwice: true };
  function allInHeadsUp() {
    const g = new PokerGame(rit);
    g.sit(0, 'a', 'Ana', 1000);
    g.sit(1, 'b', 'Bojan', 1000);
    // Jedan na jedan: dugme (0) je mali blajnd i karte se dele od njega.
    g.startHand(deckRuns(['Ah Ad', 'Kc Kd'], '2s 7h 9c Jd 3s', 'Ks 4h 8c Td 5s'));
    g.act(0, 'raise', 1000);
    expect(g.act(1, 'call')).toBeNull();
    return g;
  }

  it('kad su igrači all-in, ruka staje i pitaju se svi u ruci', () => {
    const g = allInHeadsUp();
    expect(g.ritPending).toBe(true);
    expect(g.ritAsk).toEqual([0, 1]);
    expect(g.toAct).toBe(-1);
    expect(g.inProgress).toBe(true);
    expect(g.board).toEqual([]);
  });

  it('kad oba igrača pristanu, pot se deli na dva stola', () => {
    const g = allInHeadsUp();
    expect(g.answerRunTwice(0, true)).toBeNull();
    const r = g.answerRunTwice(1, true)!;
    expect(r.board2).toBeDefined();
    expect(r.board2!).toHaveLength(5);
    expect(r.pots.map((p) => [p.run, p.amount, p.winners])).toEqual([
      [1, 1000, [{ seat: 0, amount: 1000 }]],
      [2, 1000, [{ seat: 1, amount: 1000 }]],
    ]);
    expect(r.shown.find((s) => s.seat === 1)!.handName2).toBe('Triling K');
    expect(g.ritPending).toBe(false);
  });

  it('ako jedan kaže ne, karte se dele jednom', () => {
    const g = allInHeadsUp();
    g.answerRunTwice(0, true);
    const r = g.answerRunTwice(1, false)!;
    expect(r.board2).toBeUndefined();
    expect(r.pots).toEqual([{ amount: 2000, winners: [{ seat: 0, amount: 2000 }], handName: expect.any(String) }]);
  });

  it('kad istekne vreme za odluku, karte se dele jednom', () => {
    const g = allInHeadsUp();
    g.answerRunTwice(0, true);
    const r = g.resolveRunTwice()!;
    expect(r.board2).toBeUndefined();
    expect(chipsTotal(g)).toBe(2000);
  });

  it('bez pitanja ako sto ne dozvoljava run it twice', () => {
    const g = new PokerGame(holdem);
    g.sit(0, 'a', 'Ana', 1000);
    g.sit(1, 'b', 'Bojan', 1000);
    g.startHand();
    g.act(0, 'raise', 1000);
    const r = g.act(1, 'call');
    expect(r).not.toBeNull();
    expect(g.ritPending).toBe(false);
  });

  it('neparan pot: prvi sto dobija žeton više', () => {
    const g = new PokerGame({ ...rit, ante: 1 });
    g.sit(0, 'a', 'A', 1000);
    g.sit(1, 'b', 'B', 1000);
    g.sit(2, 'c', 'C', 1000);
    g.startHand();
    g.act(0, 'raise', 999);
    g.act(1, 'fold');
    g.act(2, 'call');
    expect(g.ritAsk).toEqual([0, 2]);
    g.answerRunTwice(2, true);
    const r = g.answerRunTwice(0, true)!;
    // Pot: ante 3 + mali blajnd 5 + 999 + 999 = 2006 → 1003 + 1003
    expect(r.pots.map((p) => p.amount)).toEqual([1003, 1003]);
  });

  it('igrač koji napusti sto dok se čeka odluka odustaje, ruka se završava jednom', () => {
    const g = new PokerGame(rit);
    g.sit(0, 'a', 'A', 1000);
    g.sit(1, 'b', 'B', 500);
    g.sit(2, 'c', 'C', 1000);
    g.startHand();
    g.act(0, 'raise', 1000);
    g.act(1, 'call'); // all-in 500
    g.act(2, 'call');
    expect(g.ritPending).toBe(true);
    const r = g.forceFold(2)!;
    expect(r.board2).toBeUndefined();
    expect(chipsTotal(g)).toBe(2500);
  });
});

describe('nasumične ruke', () => {
  it('broj žetona je uvek očuvan (žetoni + rake) i ruke se uvek završe', () => {
    for (let round = 0; round < 300; round++) {
      const variant = round % 2 ? 'HOLDEM' : 'OMAHA';
      const rake = round % 3 === 0 ? { rakeBps: 500, rakeCap: round % 2 ? 0 : 7 } : {};
      const g = new PokerGame({ ...holdem, variant, maxSeats: 9, ...rake, ante: round % 2 ? 2 : 0, straddle: round % 4 < 2, runItTwice: round % 3 !== 1 });
      const n = 2 + (round % 8);
      let total = 0;
      for (let i = 0; i < n; i++) {
        const st = 20 + Math.floor(Math.random() * 2000);
        total += st;
        g.sit(i, `u${i}`, `Igrač ${i}`, st);
        g.seats[i]!.straddle = Math.random() < 0.5;
      }
      for (let hand = 0; hand < 20 && g.canStart(); hand++) {
        const results: (HandResult | null)[] = [g.startHand(undefined, { bombPot: hand % 5 === 4 ? 30 : 0 })];
        let guard = 0;
        while (g.inProgress) {
          if (g.ritPending) {
            // Run it twice: svako odgovara nasumično, ponekad istekne vreme.
            const r = Math.random();
            if (r < 0.1) results.push(g.resolveRunTwice());
            else if (r < 0.15) results.push(g.forceFold(g.ritAsk[0]));
            else {
              const seat = g.ritAsk.find((i) => !g.ritYes.includes(i))!;
              results.push(g.answerRunTwice(seat, Math.random() < 0.8));
            }
            expect(++guard).toBeLessThan(500);
            continue;
          }
          const legal = g.legalActions(g.toAct)!;
          expect(legal).not.toBeNull();
          const r = Math.random();
          if (r < 0.04) {
            // Neko napušta sto van reda.
            const others = g.seats.map((s, i) => (s?.inHand && !s.folded && i !== g.toAct ? i : -1)).filter((i) => i >= 0);
            if (others.length) results.push(g.forceFold(others[Math.floor(Math.random() * others.length)]));
          } else if (r < 0.15) results.push(g.act(g.toAct, 'fold'));
          else if (r < 0.35 && legal.minRaiseTo !== null) {
            const to = legal.minRaiseTo + Math.floor(Math.random() * (legal.maxRaiseTo! - legal.minRaiseTo + 1));
            results.push(g.act(g.toAct, 'raise', to));
          } else results.push(g.act(g.toAct, legal.check ? 'check' : 'call'));
          expect(++guard).toBeLessThan(500);
        }
        const done = results.filter((x): x is HandResult => !!x);
        expect(done).toHaveLength(1);
        total -= done[0].rake;
        const sum = g.seats.reduce((s, x) => s + (x?.stack ?? 0), 0);
        expect(sum).toBe(total);
        expect(g.potTotal()).toBe(0);
        for (const s of g.seats) if (s) expect(s.stack).toBeGreaterThanOrEqual(0);
      }
    }
  });
});
