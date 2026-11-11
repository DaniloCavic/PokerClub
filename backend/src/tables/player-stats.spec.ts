import { playerStats, StoredHand } from './player-stats';

const players = [
  { seat: 0, userId: 'ana' },
  { seat: 1, userId: 'bojan' },
  { seat: 2, userId: 'ceca' },
];
const act = (seat: number, type: string, amount = 0, street = 'preflop') => ({ seat, type, amount, street });

const hands: StoredHand[] = [
  // 1) Ana povisuje, Bojan (SB) dorovnava, Ceca (BB) odustaje; Ana dobija bez otvaranja.
  {
    board: '',
    details: {
      players,
      actions: [act(1, 'sb', 5), act(2, 'bb', 10), act(0, 'raise', 30), act(1, 'call', 30), act(2, 'fold')],
      pots: [{ amount: 70, winners: [{ seat: 0, amount: 70 }] }],
      shown: [],
    },
  },
  // 2) Svi samo dorovnaju, BB čekira; otvaranje karata: Bojan dobija sa trilingom.
  {
    board: 'Ks 7h 2c 9d 3s',
    details: {
      players,
      actions: [act(1, 'sb', 5), act(2, 'bb', 10), act(0, 'call', 10), act(1, 'call', 10), act(2, 'check')],
      pots: [{ amount: 30, winners: [{ seat: 1, amount: 30 }] }],
      shown: [
        { seat: 0, cards: ['Ah', 'Qd'] },
        { seat: 1, cards: ['Kd', 'Kh'] },
      ],
    },
  },
  // 3) Bomb pot: nema runde pre flopa (ne ulazi u VPIP/PFR), Ana dobija veliki pot.
  {
    board: '',
    details: {
      players,
      actions: [act(0, 'bomb', 20), act(1, 'bomb', 20), act(2, 'bomb', 20), act(0, 'bet', 100, 'flop'), act(1, 'fold', 0, 'flop'), act(2, 'fold', 0, 'flop')],
      pots: [{ amount: 160, winners: [{ seat: 0, amount: 160 }] }],
      shown: [],
    },
  },
  // 5) Ana povisuje, Bojan uradi 3-bet, Ceca odustaje, Ana dorovnava.
  {
    board: '',
    details: {
      players,
      actions: [act(1, 'sb', 5), act(2, 'bb', 10), act(0, 'raise', 30), act(1, 'raise', 90), act(2, 'fold'), act(0, 'call', 90)],
      pots: [{ amount: 190, winners: [{ seat: 1, amount: 190 }] }],
      shown: [],
    },
  },
  // 4) Ana je all-in preko uloga (povišenje); Ceca (BB) dorovnava all-in (nije povišenje).
  {
    board: '',
    details: {
      players,
      actions: [act(1, 'sb', 5), act(2, 'bb', 10), act(0, 'allin', 500), act(1, 'fold'), act(2, 'allin', 400)],
      pots: [{ amount: 805, winners: [{ seat: 2, amount: 805 }] }],
      shown: [],
    },
  },
];

describe('statistika igrača za stolom', () => {
  it('VPIP, PFR, 3-bet, dobijene ruke i najveći pot', () => {
    const ana = playerStats('ana', hands, 'HOLDEM');
    expect(ana.hands).toBe(5);
    expect(ana.vpip).toBe(100); // 4 od 4 ruke sa rundom pre flopa
    expect(ana.pfr).toBe(75); // raise, raise i all-in povišenje, ne i call
    expect(ana.threeBets).toBe(0); // nikad nije imala priliku (ona je prva povisivala)
    expect(ana.won).toBe(2);
    expect(ana.winRate).toBe(40);
    expect(ana.biggestPot).toBe(160);
    expect(ana.bestHand?.name).toBe('Visoka karta A');

    const ceca = playerStats('ceca', hands, 'HOLDEM');
    expect(ceca.vpip).toBe(25); // samo all-in dorovnavanje; BB check se ne računa
    expect(ceca.pfr).toBe(0);
    // Prilike za 3-bet: ruka 1 (fold), ruka 4 (dorovnala all-in); ruka 5 je posle 3-beta.
    expect(ceca.threeBets).toBe(0);
    expect(ceca.threeBet).toBe(0);
    expect(ceca.biggestPot).toBe(805);
    expect(ceca.bestHand).toBeNull();

    const bojan = playerStats('bojan', hands, 'HOLDEM');
    expect(bojan.vpip).toBe(75);
    // Prilike: ruka 1 (call), ruka 5 (3-bet), ruka 4 (fold) → 1 od 3
    expect(bojan.threeBets).toBe(1);
    expect(bojan.threeBet).toBe(33.3);
    expect(bojan.bestHand?.name).toBe('Triling K');
    expect(bojan.showdowns).toBe(1);
  });

  it('igrač bez ruku za stolom', () => {
    expect(playerStats('niko', hands, 'HOLDEM')).toMatchObject({ hands: 0, vpip: 0, pfr: 0, winRate: 0, bestHand: null });
  });
});
