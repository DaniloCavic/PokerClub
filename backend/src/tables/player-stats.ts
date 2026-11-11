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
 * - dobijene ruke, najveći osvojen pot i najbolja ruka koju je pokazao na otvaranju karata.
 * Bomb pot ruke nemaju rundu pre flopa, pa ne ulaze u VPIP i PFR.
 */
export function playerStats(userId: string, hands: StoredHand[], variant: 'HOLDEM' | 'OMAHA') {
  let played = 0;
  let preflopHands = 0;
  let vpip = 0;
  let pfr = 0;
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
      let voluntary = false;
      let raised = false;
      for (const a of actions) {
        if (a.street !== 'preflop') continue;
        if (a.seat === me.seat) {
          if (a.type === 'call') voluntary = true;
          if (a.type === 'bet' || a.type === 'raise') voluntary = raised = true;
          if (a.type === 'allin') {
            voluntary = true;
            if (a.amount > level) raised = true;
          }
        }
        if (BET_TYPES.has(a.type)) level = Math.max(level, a.amount);
      }
      if (voluntary) vpip++;
      if (raised) pfr++;
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
    won,
    winRate: pct(won, played),
    showdowns,
    biggestPot,
    bestHand: best ? { name: best.name, cards: best.cards } : null,
  };
}
