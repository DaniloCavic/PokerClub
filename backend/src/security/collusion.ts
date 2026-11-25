/**
 * Otkrivanje sumnjive saradnje igrača iz odigranih ruku (keš stolovi):
 * - CHIP_DUMP: novac stalno teče od jednog igrača ka drugom (jedan namerno gubi drugom),
 * - SOFT_PLAY: igrač skoro uvek odustaje kad baš određeni igrač beti, a protiv drugih ne.
 * Ovo su samo upozorenja za super agenta, ne dokaz: on pogleda ruke i odluči.
 */
export interface ScanHand {
  bigBlind: number;
  details: unknown;
}

interface Details {
  players?: { seat: number; userId: string; startStack?: number; endStack?: number }[];
  actions?: { seat: number; street: string; type: string }[];
}

export interface Finding {
  kind: 'CHIP_DUMP' | 'SOFT_PLAY';
  /** Kod CHIP_DUMP: [ko gubi, ko dobija]; kod SOFT_PLAY: [ko odustaje, protiv koga]. */
  userIds: [string, string];
  detail: string;
}

export const LIMITS = {
  /** Najmanje zajedničkih ruku da bi se par uopšte gledao. */
  minHands: 20,
  /** Neto prebačeno (u velikim blajndovima) od jednog ka drugom. */
  dumpBB: 100,
  /** Koliko jednostrano: od ukupnog novca između njih dvojice, koliki deo ide u jednom smeru. */
  dumpRatio: 0.85,
  /** …i bar ovoliki deo svega što je gubitnik izgubio otišao je baš tom igraču (ne samo loš igrač koji gubi svima). */
  dumpShare: 0.5,
  /** Soft play: najmanje situacija (on beti, drugi treba da odgovori) i procenat odustajanja. */
  softMin: 15,
  softFold: 0.9,
  /** …a protiv ostalih igrača odustaje najviše ovoliko. */
  softElse: 0.6,
};

const AGGR = new Set(['bet', 'raise', 'allin']);

export function scanHands(hands: ScanHand[], limits = LIMITS): Finding[] {
  const key = (a: string, b: string) => `${a}|${b}`;
  const flow = new Map<string, number>(); // a|b → koliko je (u BB) a izgubio igraču b
  const together = new Map<string, number>(); // a|b (a<b) → zajedničke ruke
  const faced = new Map<string, { n: number; folds: number }>(); // a|b → a je odgovarao na bet igrača b
  const facedAll = new Map<string, { n: number; folds: number }>(); // a → protiv svih

  for (const h of hands) {
    const d = (h.details ?? {}) as Details;
    const ps = (d.players ?? []).filter((p) => p.startStack != null && p.endStack != null);
    const bb = Math.max(1, h.bigBlind);
    for (let i = 0; i < ps.length; i++)
      for (let j = i + 1; j < ps.length; j++) {
        const [a, b] = [ps[i].userId, ps[j].userId].sort();
        together.set(key(a, b), (together.get(key(a, b)) ?? 0) + 1);
      }
    // Novac: svaki gubitnik "plaća" dobitnicima srazmerno njihovom dobitku.
    const delta = ps.map((p) => ({ id: p.userId, d: p.endStack! - p.startStack! }));
    const won = delta.filter((x) => x.d > 0);
    const totalWon = won.reduce((s, x) => s + x.d, 0);
    if (totalWon > 0)
      for (const l of delta.filter((x) => x.d < 0))
        for (const w of won) flow.set(key(l.id, w.id), (flow.get(key(l.id, w.id)) ?? 0) + (-l.d * w.d) / totalWon / bb);

    // Odgovori na bet/raise: sledeći potez igrača u istoj ulici posle tuđe agresije.
    const seatUser = new Map((d.players ?? []).map((p) => [p.seat, p.userId]));
    const acts = d.actions ?? [];
    for (let k = 0; k < acts.length; k++) {
      const a = acts[k];
      if (!AGGR.has(a.type) || a.street === 'preflop') continue;
      const bettor = seatUser.get(a.seat);
      const answered = new Set<number>();
      for (let m = k + 1; m < acts.length; m++) {
        const r = acts[m];
        if (r.street !== a.street) break;
        if (r.seat === a.seat) break;
        if (answered.has(r.seat)) continue;
        answered.add(r.seat);
        const resp = seatUser.get(r.seat);
        if (!bettor || !resp) continue;
        const fold = r.type === 'fold' ? 1 : 0;
        const f = faced.get(key(resp, bettor)) ?? { n: 0, folds: 0 };
        faced.set(key(resp, bettor), { n: f.n + 1, folds: f.folds + fold });
        const g = facedAll.get(resp) ?? { n: 0, folds: 0 };
        facedAll.set(resp, { n: g.n + 1, folds: g.folds + fold });
        if (AGGR.has(r.type)) break; // novi bet: dalje se odgovara njemu
      }
    }
  }

  // Ukupno izgubljeno po igraču (svima), da se vidi da li gubi baš jednom igraču.
  const lostAll = new Map<string, number>();
  for (const [k, v] of flow) {
    const a = k.split('|')[0];
    lostAll.set(a, (lostAll.get(a) ?? 0) + v);
  }
  const out: Finding[] = [];
  for (const [k, n] of together) {
    if (n < limits.minHands) continue;
    const [a, b] = k.split('|');
    const ab = flow.get(key(a, b)) ?? 0;
    const ba = flow.get(key(b, a)) ?? 0;
    const [loser, winner, net, one] = ab >= ba ? [a, b, ab - ba, ab] : [b, a, ba - ab, ba];
    const share = one / Math.max(1e-9, lostAll.get(loser) ?? 0);
    if (net >= limits.dumpBB && one / Math.max(1e-9, ab + ba) >= limits.dumpRatio && share >= limits.dumpShare)
      out.push({
        kind: 'CHIP_DUMP',
        userIds: [loser, winner],
        detail: `Za ${n} zajedničkih ruku izgubio mu je neto ${Math.round(net)} BB (${Math.round((one / (ab + ba)) * 100)} % novca između njih išlo je u jednom smeru; to je ${Math.round(share * 100)} % svega što je izgubio).`,
      });
  }
  for (const [k, f] of faced) {
    if (f.n < limits.softMin) continue;
    const [resp, bettor] = k.split('|');
    const rate = f.folds / f.n;
    const all = facedAll.get(resp)!;
    const others = all.n - f.n > 0 ? (all.folds - f.folds) / (all.n - f.n) : null;
    if (rate >= limits.softFold && others !== null && others <= limits.softElse)
      out.push({
        kind: 'SOFT_PLAY',
        userIds: [resp, bettor],
        detail: `Na njegov bet posle flopa odustaje ${Math.round(rate * 100)} % (${f.folds} od ${f.n}), a protiv ostalih ${Math.round(others * 100)} %.`,
      });
  }
  return out;
}
