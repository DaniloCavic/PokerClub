import { Card } from './cards';
import { bestHoldem, bestOmaha } from './evaluator';
import { Variant } from './game';

/**
 * Šanse za pobedu (equity) igrača kad su karte otvorene, a sto nije ceo podeljen — kao na GG
 * tokom all-in-a. Podela pota se računa kao deo pobede (npr. dva igrača sa istom rukom po 50 %).
 * Računaju se samo karte koje svi vide (karte igrača u ruci i sto); odbačene karte se ne znaju.
 *
 * Kad nedostaju 1–2 karte stola, prolazi se kroz sve mogućnosti (tačno); kad nedostaje više
 * (pre flopa), uzima se `samples` nasumičnih nastavaka.
 */
class EquityCounter {
  readonly seats: number[];
  readonly deck: Card[];
  readonly missing: number;
  private readonly share: Record<number, number>;
  private total = 0;
  private readonly evalFn: typeof bestHoldem;

  constructor(
    variant: Variant,
    private readonly holes: Record<number, Card[]>,
    private readonly board: Card[],
  ) {
    this.seats = Object.keys(holes).map(Number);
    const known = new Set<Card>([...board, ...this.seats.flatMap((s) => holes[s])]);
    this.deck = Array.from({ length: 52 }, (_, i) => i).filter((c) => !known.has(c));
    this.missing = 5 - board.length;
    this.evalFn = variant === 'OMAHA' ? bestOmaha : bestHoldem;
    this.share = Object.fromEntries(this.seats.map((s) => [s, 0]));
  }

  score(full: Card[]) {
    let top = -1;
    let winners: number[] = [];
    for (const s of this.seats) {
      const v = this.evalFn(this.holes[s], full).score;
      if (v > top) {
        top = v;
        winners = [s];
      } else if (v === top) winners.push(s);
    }
    for (const w of winners) this.share[w] += 1 / winners.length;
    this.total++;
  }

  /** Tačno: svi nastavci stola (kad nedostaju 0–2 karte). */
  exact() {
    if (this.missing <= 0) return this.score(this.board);
    const d = this.deck;
    for (let i = 0; i < d.length; i++) {
      if (this.missing === 1) {
        this.score([...this.board, d[i]]);
        continue;
      }
      for (let j = i + 1; j < d.length; j++) this.score([...this.board, d[i], d[j]]);
    }
  }

  /** `n` nasumičnih nastavaka stola (delimično mešanje špila). */
  sample(n: number, rand: () => number) {
    const d = [...this.deck];
    for (let k = 0; k < n; k++) {
      for (let m = 0; m < this.missing; m++) {
        const j = m + Math.floor(rand() * (d.length - m));
        [d[m], d[j]] = [d[j], d[m]];
      }
      this.score([...this.board, ...d.slice(0, this.missing)]);
    }
  }

  result(): Record<number, number> {
    return Object.fromEntries(this.seats.map((s) => [s, this.total ? Math.round((this.share[s] / this.total) * 1000) / 10 : 0]));
  }
}

const sampleCount = (variant: Variant, samples: number) => (variant === 'OMAHA' ? Math.min(samples, 3_000) : samples);

export function equity(
  variant: Variant,
  holes: Record<number, Card[]>,
  board: Card[],
  samples = 5_000,
  rand: () => number = Math.random,
): Record<number, number> {
  const c = new EquityCounter(variant, holes, board);
  if (c.missing <= 2) c.exact();
  else c.sample(sampleCount(variant, samples), rand);
  return c.result();
}

/**
 * Isto kao `equity`, ali računa u malim delovima i između njih pušta server da radi
 * (da all-in ne zaustavi ostale stolove).
 */
export async function equityAsync(
  variant: Variant,
  holes: Record<number, Card[]>,
  board: Card[],
  samples = 5_000,
): Promise<Record<number, number>> {
  const c = new EquityCounter(variant, holes, board);
  if (c.missing <= 2) {
    c.exact();
    return c.result();
  }
  let left = sampleCount(variant, samples);
  while (left > 0) {
    const n = Math.min(250, left);
    c.sample(n, Math.random);
    left -= n;
    await new Promise((r) => setImmediate(r));
  }
  return c.result();
}
