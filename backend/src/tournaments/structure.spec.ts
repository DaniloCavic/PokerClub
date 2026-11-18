import { clockAt, defaultLevels, estimateMinutes, payoutAmounts, payoutPercents, prizePool, validateLevels } from './structure';
import { levelReachedAt } from './structure';

const MIN = 60_000;
const lv = (minutes: number, n = 10) => Array.from({ length: n }, (_, i) => ({ sb: 10 * (i + 1), bb: 20 * (i + 1), ante: 0, minutes }));

describe('sat turnira', () => {
  it('pauza svakog sata u :55 (5 min), vreme nivoa staje tokom pauze', () => {
    const levels = lv(20);
    const start = 0;
    const r = { mode: 'HOURLY' as const, every: 0, minutes: 5 };
    expect(clockAt(start, levels, r, 10 * MIN)).toMatchObject({ level: 0, onBreak: false, levelEndsAt: 20 * MIN, nextBreakAt: 55 * MIN });
    expect(clockAt(start, levels, r, 45 * MIN)).toMatchObject({ level: 2, onBreak: false });
    // Treći nivo (40–60 igre) prelazi preko pauze: kraj je 65. minut.
    expect(clockAt(start, levels, r, 45 * MIN).levelEndsAt).toBe(65 * MIN);
    expect(clockAt(start, levels, r, 57 * MIN)).toMatchObject({ level: 2, onBreak: true, breakEndsAt: 60 * MIN });
    expect(clockAt(start, levels, r, 64 * MIN)).toMatchObject({ level: 2, onBreak: false });
    expect(clockAt(start, levels, r, 66 * MIN)).toMatchObject({ level: 3, onBreak: false, levelEndsAt: 85 * MIN });
    // Drugi sat: pauza 115–120.
    expect(clockAt(start, levels, r, 116 * MIN)).toMatchObject({ onBreak: true, breakEndsAt: 120 * MIN });
  });

  it('pauza posle svakih N nivoa', () => {
    const levels = lv(10);
    const r = { mode: 'LEVELS' as const, every: 3, minutes: 5 };
    expect(clockAt(0, levels, r, 5 * MIN)).toMatchObject({ level: 0, nextBreakAt: 30 * MIN });
    expect(clockAt(0, levels, r, 31 * MIN)).toMatchObject({ level: 3, onBreak: true, breakEndsAt: 35 * MIN });
    expect(clockAt(0, levels, r, 36 * MIN)).toMatchObject({ level: 3, onBreak: false, levelEndsAt: 45 * MIN, nextBreakAt: 65 * MIN });
  });

  it('bez pauza i posle poslednjeg nivoa ostaje poslednji', () => {
    const levels = lv(10, 3);
    const r = { mode: 'NONE' as const, every: 0, minutes: 0 };
    expect(clockAt(0, levels, r, 25 * MIN)).toMatchObject({ level: 2, nextBreakAt: null });
    expect(clockAt(0, levels, r, 500 * MIN).level).toBeGreaterThan(2);
  });
});

describe('nagrade', () => {
  it('fond i garancija', () => {
    const t = { buyIn: 1000, rebuyPrice: 1000, addonPrice: 500, guarantee: 20_000 };
    expect(prizePool(t, { entries: 10, rebuys: 2, addons: 4 })).toBe(20_000);
    expect(prizePool(t, { entries: 30, rebuys: 2, addons: 4 })).toBe(34_000);
  });

  it('procenat polja: 15 % od 40 = 6 mesta, opadajuće, zbir 100', () => {
    const p = payoutPercents('PERCENT', 15, [], 40);
    expect(p).toHaveLength(6);
    expect(p.reduce((a, b) => a + b, 0)).toBeCloseTo(100);
    for (let k = 1; k < p.length; k++) expect(p[k]).toBeLessThan(p[k - 1]);
    expect(payoutPercents('PERCENT', 15, [], 3)).toHaveLength(1);
  });

  it('fiksni procenti i manje ulaza nego mesta', () => {
    expect(payoutPercents('FIXED', 0, [50, 30, 20], 10)).toEqual([50, 30, 20]);
    const two = payoutPercents('FIXED', 0, [50, 30, 20], 2);
    expect(two[0]).toBeCloseTo(62.5);
    expect(two[1]).toBeCloseTo(37.5);
  });

  it('iznosi su celi brojevi i zbir je tačno fond', () => {
    const a = payoutAmounts(10_001, payoutPercents('PERCENT', 20, [], 33));
    expect(a.reduce((x, y) => x + y, 0)).toBe(10_001);
    expect(a.every(Number.isInteger)).toBe(true);
  });
});

describe('struktura', () => {
  it('podrazumevani nivoi rastu i prolaze proveru', () => {
    const l = defaultLevels(20, 10, 15);
    expect(validateLevels(l)).toBeNull();
    for (let k = 1; k < l.length; k++) expect(l[k].bb).toBeGreaterThan(l[k - 1].bb);
    expect(validateLevels([{ sb: 30, bb: 20, ante: 0, minutes: 10 }])).not.toBeNull();
  });

  it('procena trajanja', () => {
    const l = defaultLevels(20, 10, 30);
    const m = estimateMinutes(l, { mode: 'HOURLY', every: 0, minutes: 5 }, 50, 10_000);
    expect(m).toBeGreaterThan(60);
    expect(m).toBeLessThan(600);
  });
});

describe('levelReachedAt', () => {
  const lv = [1, 2, 3, 4, 5, 6].map((k) => ({ sb: k, bb: 2 * k, ante: 0, minutes: 10 }));
  const MIN = 60_000;
  it('bez pauza: kraj 3. nivoa posle 30 min', () => {
    expect(levelReachedAt(0, lv, { mode: 'NONE', every: 0, minutes: 0 }, 3)).toBe(30 * MIN);
    expect(levelReachedAt(0, lv, { mode: 'NONE', every: 0, minutes: 0 }, 3)).toBeGreaterThanOrEqual(30 * MIN);
  });
  it('pauza svakog sata (5 min) pomera kraj 6. nivoa', () => {
    const t = levelReachedAt(0, lv, { mode: 'HOURLY', every: 0, minutes: 5 }, 6);
    expect(Math.round(t / MIN)).toBe(65);
  });
});
