import { parseCards } from './cards';
import { equity } from './equity';

const h = (s: string) => parseCards(s);

describe('šanse za pobedu (equity)', () => {
  it('AA protiv KK pre flopa je oko 82 : 18', () => {
    const e = equity('HOLDEM', { 0: h('Ah Ad'), 1: h('Kc Kd') }, []);
    expect(e[0]).toBeGreaterThan(79);
    expect(e[0]).toBeLessThan(85);
    expect(e[0] + e[1]).toBeCloseTo(100, 0);
  });

  it('na turnu tačno: KK protiv AA, ostaje samo jedan kralj za pobedu', () => {
    // Sto 2s 7h 9c 3d: KK pobeđuje samo sa K na riveru (2 od 44 karte)
    const e = equity('HOLDEM', { 0: h('Ah Ad'), 1: h('Kc Kd') }, h('2s 7h 9c 3d'));
    expect(e[1]).toBe(4.5);
    expect(e[0]).toBe(95.5);
  });

  it('podela: iste ruke dele pot (po 50 %)', () => {
    const e = equity('HOLDEM', { 0: h('Ah Kd'), 1: h('As Kc') }, h('2s 7h 9c 3d'));
    expect(e[0]).toBeCloseTo(e[1], 0);
    expect(e[0]).toBeGreaterThan(45);
  });

  it('kad je sto ceo podeljen, pobednik ima 100 %', () => {
    const e = equity('HOLDEM', { 0: h('Ah Ad'), 1: h('Kc Kd') }, h('2s 7h 9c 3d 4s'));
    expect(e).toEqual({ 0: 100, 1: 0 });
  });

  it('Omaha i tri igrača: zbir je 100 %', () => {
    const e = equity('OMAHA', { 0: h('Ah Ad Kh Kd'), 1: h('Qc Qs Jc Js'), 3: h('9h 8h 7c 6c') }, h('2s 7h 9c'));
    const sum = e[0] + e[1] + e[3];
    expect(sum).toBeGreaterThan(99.5);
    expect(sum).toBeLessThan(100.5);
  });
});
