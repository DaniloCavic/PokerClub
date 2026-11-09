import { agentCut, splitRake } from './rake';

describe('raspodela rake-a', () => {
  it('deli srazmerno ulogu i zbir je tačan', () => {
    const r = splitRake(10, [
      { key: 'a', amount: 100 },
      { key: 'b', amount: 100 },
      { key: 'c', amount: 100 },
    ]);
    expect(r.reduce((s, x) => s + x.amount, 0)).toBe(10);
    expect(r.map((x) => x.amount).sort()).toEqual([3, 3, 4]);
  });

  it('veći ulog plaća veći deo, odustali sa malim ulogom plaćaju manje', () => {
    const r = splitRake(20, [
      { key: 'veliki', amount: 900 },
      { key: 'mali', amount: 100 },
      { key: 'nula', amount: 0 },
    ]);
    expect(r).toEqual([
      { key: 'veliki', amount: 18 },
      { key: 'mali', amount: 2 },
    ]);
  });

  it('bez rake-a nema delova', () => {
    expect(splitRake(0, [{ key: 'a', amount: 50 }])).toEqual([]);
  });

  it('nasumično: zbir je uvek jednak rake-u', () => {
    for (let i = 0; i < 2000; i++) {
      const n = 2 + Math.floor(Math.random() * 8);
      const c = Array.from({ length: n }, (_, k) => ({ key: k, amount: Math.floor(Math.random() * 5000) }));
      const rake = Math.floor(Math.random() * 300);
      const total = c.reduce((s, x) => s + x.amount, 0);
      const r = splitRake(rake, c);
      expect(r.reduce((s, x) => s + x.amount, 0)).toBe(total > 0 ? rake : 0);
    }
  });

  it('deo agenta po procentu', () => {
    expect(agentCut(100, 3000)).toBe(30);
    expect(agentCut(7, 5000)).toBe(4);
    expect(agentCut(3, 3000)).toBe(1);
    expect(agentCut(50, 0)).toBe(0);
    expect(agentCut(50, 20_000)).toBe(50);
  });
});
