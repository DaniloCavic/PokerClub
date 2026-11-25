import { cardToString, parseCards } from '../poker/engine/cards';
import { bestHoldem, bestOmaha } from '../poker/engine/evaluator';

/** Sačuvana ruka (iz baze): sto i detalji koje upisuje TablesService.handFinished. */
export interface StoredHand {
  board: string;
  details: unknown;
  /** Igra ove ruke (za "sve igre", gde su ruke sa raznih stolova). */
  variant?: 'HOLDEM' | 'OMAHA';
  /** Ruka sa keš stola (samo one ulaze u ukupan dobitak). */
  cash?: boolean;
}

interface Details {
  button?: number;
  players?: { seat: number; userId: string; startStack?: number; endStack?: number }[];
  actions?: { seat: number; street: string; type: string; amount: number }[];
  pots?: { amount: number; winners: { seat: number; amount: number }[] }[];
  shown?: { seat: number; cards: string[] }[];
}

/** Ulozi koji podižu nivo uloga pre flopa (iznos je ukupan ulog igrača u rundi). */
const BET_TYPES = new Set(['sb', 'bb', 'straddle', 'call', 'bet', 'raise', 'allin']);

const pct = (part: number, whole: number) => (whole ? Math.round((part / whole) * 1000) / 10 : 0);
/** Kao pct, ali null kad igrač još nije imao nijednu priliku (prikazuje se „–”, ne 0 %). */
const pctOrNull = (part: number, whole: number) => (whole ? pct(part, whole) : null);

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
  // Krađa blajndova (ATS), kontinuacioni bet (CB), odustajanje na CB (FCB), otvaranja (WTSD/WSD), agresija (AF).
  let atsChances = 0, ats = 0;
  let cbChances = 0, cb = 0;
  let fcbChances = 0, fcb = 0;
  let sawFlop = 0, wtsd = 0, wsd = 0;
  let aggr = 0, calls = 0;
  let profit = 0;

  for (const h of hands) {
    const d = (h.details ?? {}) as Details;
    const me = d.players?.find((p) => p.userId === userId);
    if (!me) continue;
    played++;
    const actions = d.actions ?? [];
    if (h.cash !== false && me.startStack != null && me.endStack != null) profit += me.endStack - me.startStack;

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

    // ---------- ATS: prvi ulazi povišenjem sa CO, BTN ili SB (pre njega su svi odustali) ----------
    const seats = (d.players ?? []).map((p) => p.seat).sort((a, b) => a - b);
    if (d.button != null && seats.length >= 3 && !actions.some((a) => a.type === 'bomb')) {
      const bi = seats.indexOf(d.button);
      if (bi >= 0) {
        const at = (k: number) => seats[(bi + k + seats.length) % seats.length];
        const steal = new Set([at(0), at(1), ...(seats.length >= 4 ? [at(-1)] : [])]);
        if (steal.has(me.seat)) {
          for (const a of actions) {
            if (a.street !== 'preflop' || ['ante', 'sb', 'bb', 'straddle'].includes(a.type)) continue;
            if (a.seat === me.seat) {
              atsChances++;
              if (a.type === 'raise' || a.type === 'bet' || a.type === 'allin') ats++;
              break;
            }
            if (a.type !== 'fold') break; // neko je već ušao: nije prilika za krađu
          }
        }
      }
    }

    // ---------- Posle flopa ----------
    const folded = actions.some((a) => a.seat === me.seat && a.type === 'fold' && a.street === 'preflop');
    const flopActs = actions.filter((a) => a.street === 'flop');
    const reachedFlop = flopActs.length > 0 || parseCards(h.board ?? '').length >= 3;
    if (reachedFlop && !folded) {
      sawFlop++;
      // Poslednji koji je povisio pre flopa (agresor) ima priliku za CB.
      let aggressor = -1;
      for (const a of actions) if (a.street === 'preflop' && (a.type === 'raise' || a.type === 'bet')) aggressor = a.seat;
      if (aggressor >= 0) {
        const firstBet = flopActs.findIndex((a) => a.type === 'bet' || a.type === 'raise' || a.type === 'allin');
        if (aggressor === me.seat) {
          const myFirst = flopActs.findIndex((a) => a.seat === me.seat);
          if (myFirst >= 0 && (firstBet < 0 || firstBet >= myFirst)) {
            cbChances++;
            if (firstBet === myFirst) cb++;
          }
        } else if (firstBet >= 0 && flopActs[firstBet].seat === aggressor) {
          const reply = flopActs.slice(firstBet + 1).find((a) => a.seat === me.seat);
          if (reply) {
            fcbChances++;
            if (reply.type === 'fold') fcb++;
          }
        }
      }
      for (const a of actions) {
        if (a.seat !== me.seat || a.street === 'preflop') continue;
        if (a.type === 'bet' || a.type === 'raise' || a.type === 'allin') aggr++;
        else if (a.type === 'call') calls++;
      }
      const foldedLater = actions.some((a) => a.seat === me.seat && a.type === 'fold');
      const stayed = (d.players ?? []).filter((p) => !actions.some((a) => a.seat === p.seat && a.type === 'fold')).length;
      if (!foldedLater && stayed >= 2) {
        wtsd++;
        const got = (d.pots ?? []).flatMap((p) => p.winners).some((w) => w.seat === me.seat && w.amount > 0);
        if (got) wsd++;
      }
    }

    const mine = (d.pots ?? []).flatMap((p) => p.winners).filter((w) => w.seat === me.seat).reduce((s, w) => s + w.amount, 0);
    if (mine > 0) won++;
    biggestPot = Math.max(biggestPot, mine);

    const shown = d.shown?.find((s) => s.seat === me.seat);
    const board = parseCards(h.board ?? '');
    if (shown && board.length === 5) {
      showdowns++;
      const v = ((h.variant ?? variant) === 'OMAHA' ? bestOmaha : bestHoldem)(parseCards(shown.cards.join(' ')), board);
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
    ats: pctOrNull(ats, atsChances),
    cb: pctOrNull(cb, cbChances),
    fcb: pctOrNull(fcb, fcbChances),
    wtsd: pctOrNull(wtsd, sawFlop),
    wsd: pctOrNull(wsd, wtsd),
    af: calls ? Math.round((aggr / calls) * 10) / 10 : aggr ? aggr : null,
    profit,
  };
}
