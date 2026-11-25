import { scanHands, ScanHand } from './collusion';

const p = (seat: number, userId: string, startStack: number, endStack: number) => ({ seat, userId, startStack, endStack });
const act = (seat: number, type: string, street = 'flop') => ({ seat, type, street });

describe('sumnjiva saradnja', () => {
  it('jedan stalno gubi drugom (chip dumping)', () => {
    const hands: ScanHand[] = Array.from({ length: 22 }, () => ({
      bigBlind: 20,
      details: { players: [p(0, 'ana', 2000, 1750), p(1, 'boki', 2000, 2250), p(2, 'ceca', 2000, 2000)], actions: [] },
    }));
    const f = scanHands(hands);
    const dump = f.find((x) => x.kind === 'CHIP_DUMP');
    expect(dump?.userIds).toEqual(['ana', 'boki']); // 22 × 250 / 20 = 275 BB
    expect(f.filter((x) => x.kind === 'CHIP_DUMP')).toHaveLength(1);
  });

  it('loš igrač koji gubi svima nije sumnjiv', () => {
    const hands: ScanHand[] = Array.from({ length: 60 }, (_, i) => ({
      bigBlind: 20,
      details: { players: [p(0, 'ana', 2000, 1700), p(1, ['boki', 'ceca', 'dule'][i % 3], 2000, 2300)], actions: [] },
    }));
    // Svakome izgubi po 300 BB za 20 ruku, ali to je samo trećina njegovih gubitaka.
    expect(scanHands(hands.map((h) => h)).filter((x) => x.kind === 'CHIP_DUMP')).toEqual([]);
  });

  it('normalna igra (novac ide u oba smera) nije sumnjiva', () => {
    const hands: ScanHand[] = Array.from({ length: 20 }, (_, i) => ({
      bigBlind: 20,
      details: { players: i % 2 ? [p(0, 'ana', 2000, 1500), p(1, 'boki', 2000, 2500)] : [p(0, 'ana', 2000, 2450), p(1, 'boki', 2000, 1550)], actions: [] },
    }));
    expect(scanHands(hands)).toEqual([]);
  });

  it('soft play: uvek odustaje baš njemu', () => {
    const hands: ScanHand[] = [];
    for (let i = 0; i < 16; i++)
      hands.push({ bigBlind: 20, details: { players: [p(0, 'ana', 1000, 1000), p(1, 'boki', 1000, 1000)], actions: [act(1, 'bet'), act(0, 'fold')] } });
    for (let i = 0; i < 10; i++)
      hands.push({ bigBlind: 20, details: { players: [p(0, 'ana', 1000, 1000), p(2, 'ceca', 1000, 1000)], actions: [act(2, 'bet'), act(0, 'call')] } });
    const f = scanHands(hands).filter((x) => x.kind === 'SOFT_PLAY');
    expect(f).toHaveLength(1);
    expect(f[0].userIds).toEqual(['ana', 'boki']);
  });
});
