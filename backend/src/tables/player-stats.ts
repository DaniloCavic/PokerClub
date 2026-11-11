import { cardToString, parseCards } from '../poker/engine/cards';
import { bestHoldem, bestOmaha } from '../poker/engine/evaluator';

/** Sačuvana ruka (iz baze): sto i detalji koje upisuje TablesService.handFinished. */
export interface StoredHand {
  board: string;
  details: unknown;
}

interface Details {
  players?: { seat: number; userId: string }[];
  actions?: { seat: number; street: string; type: string; amount: number }[];
  pots?: { amount: number; winners: { seat: number; amount: number }[] }[];
  shown?: { seat: number; cards: string[] }[];
}

/** Ulozi koji podižu nivo uloga pre flopa (iznos je ukupan ulog igrača u rundi). */
const BET_TYPES = new Set(['sb', 'bb', 'straddle', 'call', 'bet', 'raise', 'allin']);

const pct = (part: number, whole: number) => (whole ? Math.round((part / whole) * 1000) / 10 : 0);

/**
 * Statistika igrača za jednim stolom (kao na GG / ClubGG):
 * - VPIP: procenat ruku u kojima je dobrovoljno uložio pre flopa (call, bet, raise; blajndovi se ne računaju),
 * - PFR: procenat ruku u kojima je povisio pre flopa,
 * - 3-bet: koliko puta je ponovo povisio na nečije povišenje pre flopa, i procenat od prilika za to
 *   (prilika = bio je na potezu kad je pre flopa bilo tačno jedno povišenje),
 * - dobijene ruke, najveći osvojen pot i najbolja ruka koju je pokazao na otvaranju karata.
 * Bomb pot ruke nemaju rundu pre flopa, pa ne ulaze u VPIP i PFR.
 */
export function playerStats(userId: string, hands: StoredHand[], variant: 'HOLDEM' | 'OMAHA') {
  let played = 0;
  let preflopHands = 0;
  let vpip = 0;
  let pfr = 0;
  let threeBets = 0;
  let threeBetChances = 0;
  let won = 0;
  let showdowns = 0;
  let biggestPot = 0;
  let best: { score: number; name: string; cards: string[] } | null = null;
  const evalFn = variant === 'OMAHA' ? bestOmaha : bestHoldem;

  for (const h of hands) {
    const d = (h.details ?? {}) as Details;
    const me = d.players?.find((p) => p.userId === userId);
    if (!me) continue;
    played++;
    const actions = d.actions ?? [];

    if (!actions.some((a) => a.type === 'bomb')) {
      preflopHands++;
      let level = 0;
      let raises = 0;
      let voluntary = false;
      let raised = false;
      let chance = false;
      let threeBet = false;
      for (const a of actions) {
        if (a.street !== 'preflop') continue;
        // Povišenje: raise/bet, ili all-in iznad dosadašnjeg uloga (blajndovi i straddle se ne računaju).
        const isRaise = a.type === 'bet' || a.type === 'raise' || (a.type === 'allin' && a.amount > level);
        if (a.seat === me.seat) {
          if (a.type === 'call' || a.type === 'allin') voluntary = true;
          if (isRaise) voluntary = raised = true;
          // Prvi put na potezu posle tačno jednog povišenja: prilika za 3-bet.
          if (!chance && raises === 1 && a.type !== 'ante' && a.type !== 'sb' && a.type !== 'bb' && a.type !== 'straddle') {
            chance = true;
            if (isRaise) threeBet = true;
          }
        }
        if (isRaise) raises++;
        if (BET_TYPES.has(a.type)) level = Math.max(level, a.amount);
      }
      if (voluntary) vpip++;
      if (raised) pfr++;
      if (chance) threeBetChances++;
      if (threeBet) threeBets++;
    }

    const mine = (d.pots ?? []).flatMap((p) => p.winners).filter((w) => w.seat === me.seat).reduce((s, w) => s + w.amount, 0);
    if (mine > 0) won++;
    biggestPot = Math.max(biggestPot, mine);

    const shown = d.shown?.find((s) => s.seat === me.seat);
    const board = parseCards(h.board ?? '');
    if (shown && board.length === 5) {
      showdowns++;
      const v = evalFn(parseCards(shown.cards.join(' ')), board);
      if (!best || v.score > best.score) best = { score: v.score, name: v.name, cards: v.cards.map(cardToString) };
    }
  }

  return {
    hands: played,
    vpip: pct(vpip, preflopHands),
    pfr: pct(pfr, preflopHands),
    threeBets,
    threeBet: pct(threeBets, threeBetChances),
    won,
    winRate: pct(won, played),
    showdowns,
    biggestPot,
    bestHand: best ? { name: best.name, cards: best.cards } : null,
  };
}
