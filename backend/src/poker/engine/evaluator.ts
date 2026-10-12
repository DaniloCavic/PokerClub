import { Card, rankOf, suitOf } from './cards';

export enum HandCategory {
  HighCard = 0,
  Pair,
  TwoPair,
  Trips,
  Straight,
  Flush,
  FullHouse,
  Quads,
  StraightFlush,
}

export const CATEGORY_NAMES: Record<HandCategory, string> = {
  [HandCategory.HighCard]: 'Visoka karta',
  [HandCategory.Pair]: 'Par',
  [HandCategory.TwoPair]: 'Dva para',
  [HandCategory.Trips]: 'Triling',
  [HandCategory.Straight]: 'Kenta',
  [HandCategory.Flush]: 'Boja',
  [HandCategory.FullHouse]: 'Ful',
  [HandCategory.Quads]: 'Poker',
  [HandCategory.StraightFlush]: 'Kenta u boji',
};

export interface HandValue {
  /** Veći broj = jača ruka; jednake vrednosti su podela. */
  score: number;
  category: HandCategory;
  name: string;
  /** Pet karata koje čine ruku. */
  cards: Card[];
}

/** Vrednost tačno pet karata. */
export function evaluate5(cards: Card[]): number {
  const ranks = cards.map(rankOf).sort((a, b) => b - a);
  const flush = cards.every((c) => suitOf(c) === suitOf(cards[0]));

  const unique = [...new Set(ranks)];
  let straightHigh = -1;
  if (unique.length === 5) {
    if (ranks[0] - ranks[4] === 4) straightHigh = ranks[0];
    // Točak: A-2-3-4-5, najviša karta je petica.
    else if (ranks[0] === 12 && ranks[1] === 3) straightHigh = 3;
  }

  // Grupe po rangu: najpre po broju karata, pa po rangu.
  const counts = new Map<number, number>();
  for (const r of ranks) counts.set(r, (counts.get(r) ?? 0) + 1);
  const groups = [...counts.entries()].sort((a, b) => b[1] - a[1] || b[0] - a[0]);
  const ordered = groups.map((g) => g[0]);

  let category: HandCategory;
  let kickers: number[];
  if (straightHigh >= 0 && flush) {
    category = HandCategory.StraightFlush;
    kickers = [straightHigh];
  } else if (groups[0][1] === 4) {
    category = HandCategory.Quads;
    kickers = ordered;
  } else if (groups[0][1] === 3 && groups[1][1] === 2) {
    category = HandCategory.FullHouse;
    kickers = ordered;
  } else if (flush) {
    category = HandCategory.Flush;
    kickers = ranks;
  } else if (straightHigh >= 0) {
    category = HandCategory.Straight;
    kickers = [straightHigh];
  } else if (groups[0][1] === 3) {
    category = HandCategory.Trips;
    kickers = ordered;
  } else if (groups[0][1] === 2 && groups[1][1] === 2) {
    category = HandCategory.TwoPair;
    kickers = ordered;
  } else if (groups[0][1] === 2) {
    category = HandCategory.Pair;
    kickers = ordered;
  } else {
    category = HandCategory.HighCard;
    kickers = ranks;
  }

  let score = category;
  for (let i = 0; i < 5; i++) score = score * 16 + (kickers[i] ?? 0);
  return score;
}

export const categoryOf = (score: number): HandCategory => Math.floor(score / 16 ** 5);

function combinations<T>(items: T[], k: number): T[][] {
  const out: T[][] = [];
  const pick = (start: number, acc: T[]) => {
    if (acc.length === k) return void out.push([...acc]);
    for (let i = start; i <= items.length - (k - acc.length); i++) {
      acc.push(items[i]);
      pick(i + 1, acc);
      acc.pop();
    }
  };
  pick(0, []);
  return out;
}

function best(candidates: Card[][]): HandValue {
  let top: { score: number; cards: Card[] } | null = null;
  for (const five of candidates) {
    const score = evaluate5(five);
    if (!top || score > top.score) top = { score, cards: five };
  }
  const category = categoryOf(top!.score);
  const isRoyal = category === HandCategory.StraightFlush && Math.floor(top!.score / 16 ** 4) % 16 === 12;
  return {
    score: top!.score,
    category,
    name: isRoyal ? 'Rojal flaš' : CATEGORY_NAMES[category],
    cards: top!.cards,
  };
}

/** Texas Hold'em: najboljih pet od bilo kojih sedam karata (2 u ruci + 5 na stolu). */
export function bestHoldem(hole: Card[], board: Card[]): HandValue {
  return best(combinations([...hole, ...board], 5));
}

/** Omaha: tačno dve karte iz ruke i tačno tri sa stola. */
export function bestOmaha(hole: Card[], board: Card[]): HandValue {
  const out: Card[][] = [];
  for (const h of combinations(hole, 2)) for (const b of combinations(board, 3)) out.push([...h, ...b]);
  return best(out);
}
