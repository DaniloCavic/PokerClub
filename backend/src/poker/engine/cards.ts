import { randomInt } from 'crypto';

/**
 * Karta je broj 0–51: rang = c >> 2 (0 = dvojka … 12 = as), boja = c & 3.
 * Tekstualni zapis je standardni: "As", "Td", "7h", "2c".
 */
export type Card = number;

export const RANKS = '23456789TJQKA';
export const SUITS = 'cdhs'; // tref, karo, herc, pik

export const rankOf = (c: Card) => c >> 2;
export const suitOf = (c: Card) => c & 3;

export function cardToString(c: Card): string {
  return RANKS[rankOf(c)] + SUITS[suitOf(c)];
}

export function parseCard(s: string): Card {
  const r = RANKS.indexOf(s[0]?.toUpperCase());
  const su = SUITS.indexOf(s[1]?.toLowerCase());
  if (r < 0 || su < 0 || s.length !== 2) throw new Error(`Neispravna karta: ${s}`);
  return (r << 2) | su;
}

export const parseCards = (s: string): Card[] => (s.trim() ? s.trim().split(/\s+/).map(parseCard) : []);

/** Promešan špil (Fisher–Yates sa kriptografski sigurnim generatorom). */
export function shuffledDeck(): Card[] {
  const deck = Array.from({ length: 52 }, (_, i) => i);
  for (let i = deck.length - 1; i > 0; i--) {
    const j = randomInt(0, i + 1);
    [deck[i], deck[j]] = [deck[j], deck[i]];
  }
  return deck;
}
