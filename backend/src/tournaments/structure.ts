/**
 * Čista logika turnira (bez baze i mreže): sat (nivoi blajndova i pauze),
 * nagradni fond, raspodela nagrada i procena trajanja.
 */

export interface Level {
  sb: number;
  bb: number;
  ante: number;
  /** Trajanje nivoa u minutima (vreme igre, pauze se ne računaju). */
  minutes: number;
}

export type BreakMode = 'HOURLY' | 'LEVELS' | 'NONE';

export interface BreakRule {
  /** HOURLY: pauza u poslednjih `minutes` minuta svakog sata igre (npr. :55–:00). LEVELS: posle svakih `every` nivoa. */
  mode: BreakMode;
  every: number;
  minutes: number;
  /** Add-on pauza: pre nivoa sa ovim indeksom (= kraj kasne prijave), traje addonMinutes. */
  addonAt?: number;
  addonMinutes?: number;
}

export interface ClockState {
  /** Indeks nivoa (0 = prvi). Tokom pauze: nivo koji počinje (ili se nastavlja) posle pauze. */
  level: number;
  onBreak: boolean;
  breakEndsAt: number | null;
  /** Kada se završava trenutni nivo (pauza u međuvremenu je uračunata); null na poslednjem nivou. */
  levelEndsAt: number | null;
  /** Početak sledeće pauze (null ako pauza nema). */
  nextBreakAt: number | null;
}

const MIN = 60_000;
const HOUR = 60 * MIN;

/** Nivo i (posle poslednjeg nivoa važi poslednji). */
export function levelAt(levels: Level[], i: number): Level {
  return levels[Math.min(Math.max(0, i), levels.length - 1)];
}

/**
 * Stanje sata turnira u trenutku `now`: vreme nivoa teče samo dok se igra, a pauze ga zaustavljaju.
 * Sve se računa iz vremena početka, pa se sat posle ponovnog pokretanja servera nastavlja tačno.
 */
export function clockAt(startedAt: number, levels: Level[], rule: BreakRule, now: number): ClockState {
  const bm = Math.max(0, rule.minutes) * MIN;
  let t = startedAt;
  let i = 0;
  let rem = levelAt(levels, 0).minutes * MIN;
  const hourly = rule.mode === 'HOURLY' && bm > 0 && bm < HOUR;
  const byLevels = rule.mode === 'LEVELS' && rule.every > 0 && bm > 0;
  const addonMs = Math.max(0, rule.addonMinutes ?? 0) * MIN;
  const addonAt = addonMs > 0 && (rule.addonAt ?? 0) > 0 ? rule.addonAt! : -1;
  // Početak add-on pauze (ako je još ispred), računato samo po trajanju nivoa.
  const addonStart = (t0: number, i0: number, rem0: number) => {
    if (addonAt <= i0) return null;
    let at = t0 + rem0;
    for (let j = i0 + 1; j < addonAt; j++) at += levelAt(levels, j).minutes * MIN;
    return at;
  };
  const minBreak = (a: number | null, b: number | null) => (a === null ? b : b === null ? a : Math.min(a, b));
  // Add-on pauza na prelazu u nivo addonAt (u njoj je nivo već sledeći, kao kod pauza posle N nivoa).
  const addonBreak = (t0: number, i0: number, rem0: number): ClockState | number => {
    if (i0 !== addonAt) return t0;
    const bEnd = t0 + addonMs;
    if (now < bEnd) return { level: i0, onBreak: true, breakEndsAt: bEnd, levelEndsAt: bEnd + rem0, nextBreakAt: t0 };
    return bEnd;
  };

  // Sledeća pauza kad se pauze daju posle svakih N nivoa (od trenutka t, na nivou i sa preostalih rem ms).
  const nextLevelsBreak = (t0: number, i0: number, rem0: number) => {
    if (!byLevels) return null;
    let at = t0 + rem0;
    for (let j = i0 + 1; j % rule.every !== 0; j++) at += levelAt(levels, j).minutes * MIN;
    return at;
  };

  for (let guard = 0; guard < 100_000; guard++) {
    if (hourly) {
      const k = Math.floor((t - startedAt) / HOUR);
      const bStart = startedAt + k * HOUR + HOUR - bm;
      const bEnd = startedAt + (k + 1) * HOUR;
      if (t >= bStart) {
        if (now < bEnd) return { level: i, onBreak: true, breakEndsAt: bEnd, levelEndsAt: bEnd + rem, nextBreakAt: bStart };
        t = bEnd;
        continue;
      }
      const end = Math.min(bStart, t + rem);
      if (now < end) {
        // Kraj nivoa: ako nivo prelazi preko pauze, pauza se dodaje.
        const levelEndsAt = t + rem <= bStart ? t + rem : bEnd + (t + rem - bStart);
        return { level: i, onBreak: false, breakEndsAt: null, levelEndsAt, nextBreakAt: minBreak(bStart, addonStart(t, i, rem)) };
      }
      rem -= end - t;
      t = end;
      if (rem <= 0) {
        i++;
        rem = levelAt(levels, i).minutes * MIN;
        const ab = addonBreak(t, i, rem);
        if (typeof ab !== 'number') return ab;
        t = ab;
      }
      continue;
    }
    const end = t + rem;
    if (now < end) return { level: i, onBreak: false, breakEndsAt: null, levelEndsAt: end, nextBreakAt: minBreak(nextLevelsBreak(t, i, rem), addonStart(t, i, rem)) };
    t = end;
    i++;
    rem = levelAt(levels, i).minutes * MIN;
    {
      const ab = addonBreak(t, i, rem);
      if (typeof ab !== 'number') return ab;
      t = ab;
    }
    if (byLevels && i % rule.every === 0) {
      const bEnd = t + bm;
      if (now < bEnd) return { level: i, onBreak: true, breakEndsAt: bEnd, levelEndsAt: bEnd + rem, nextBreakAt: t };
      t = bEnd;
    }
  }
  throw new Error('Sat turnira: previše koraka.');
}

/**
 * Trenutak kada sat prvi put dođe do nivoa `L` (indeks od 0), tj. kada se završava nivo L
 * (računajući od 1) — tada se zatvaraju kasna prijava i rebuy. Pauze su uračunate.
 */
export function levelReachedAt(startedAt: number, levels: Level[], rule: BreakRule, L: number): number {
  if (L <= 0) return startedAt;
  let lo = startedAt;
  let hi = startedAt + HOUR;
  while (clockAt(startedAt, levels, rule, hi).level < L) hi = startedAt + (hi - startedAt) * 2;
  // Do na milisekundu tačno (isto kao kraj nivoa na satu).
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if (clockAt(startedAt, levels, rule, mid).level >= L) hi = mid;
    else lo = mid;
  }
  return hi;
}

// ---------- Nagrade ----------

export interface PrizeInput {
  buyIn: number;
  rebuyPrice: number;
  addonPrice: number;
  guarantee: number;
}

/** Nagradni fond: zbir nagradnih delova svih ulaza, rebuy-eva i add-on-a, a najmanje garancija. */
export function prizePool(t: PrizeInput, c: { entries: number; rebuys: number; addons: number }) {
  return Math.max(t.guarantee, t.buyIn * c.entries + t.rebuyPrice * c.rebuys + t.addonPrice * c.addons);
}

/**
 * Procenti nagrada po mestima (zbir 100).
 * PERCENT: plaćeno je payPercent % ulaza (najmanje 1 mesto), raspodela po opadajućoj krivoj.
 * FIXED: procenti koje je zadao administrator; ako ima manje ulaza nego mesta, procenti se srazmerno uvećaju.
 */
export function payoutPercents(mode: string, payPercent: number, fixed: number[], entries: number): number[] {
  if (entries <= 0) return [];
  let weights: number[];
  if (mode === 'FIXED') {
    weights = fixed.filter((x) => x > 0).slice(0, entries);
    if (!weights.length) weights = [100];
  } else {
    const places = Math.max(1, Math.min(entries, Math.round((entries * payPercent) / 100)));
    weights = Array.from({ length: places }, (_, k) => 1 / Math.pow(k + 1, 0.9));
  }
  const sum = weights.reduce((a, b) => a + b, 0);
  return weights.map((w) => (w / sum) * 100);
}

/** Iznosi nagrada (celi brojevi, zbir je tačno fond; ostatak od zaokruživanja ide prvom mestu). */
export function payoutAmounts(pool: number, percents: number[]): number[] {
  const out = percents.map((p) => Math.floor((pool * p) / 100));
  if (out.length) out[0] += pool - out.reduce((a, b) => a + b, 0);
  return out;
}

// ---------- Procena trajanja ----------

/**
 * Procena trajanja (minuti): turnir se obično završi kad je veliki blajnd oko 1/30 svih žetona
 * (poslednja dva igrača imaju po ~15 velikih blajndova). Pauze su uračunate.
 */
export function estimateMinutes(levels: Level[], rule: BreakRule, players: number, startingStack: number) {
  const total = Math.max(2, players) * startingStack;
  const target = total / 30;
  let play = 0;
  let count = 0;
  // Posle poslednjeg nivoa blajndovi se ne povećavaju: tada je procena do kraja strukture.
  for (let i = 0; i < levels.length; i++) {
    play += levels[i].minutes;
    count++;
    if (levels[i].bb >= target) break;
  }
  let breaks = 0;
  if (rule.mode === 'HOURLY' && rule.minutes > 0 && rule.minutes < 60) breaks = Math.floor(play / (60 - rule.minutes)) * rule.minutes;
  if (rule.mode === 'LEVELS' && rule.every > 0) breaks = Math.floor((count - 1) / rule.every) * rule.minutes;
  if ((rule.addonAt ?? 0) > 0 && (rule.addonAt ?? 0) < count) breaks += rule.addonMinutes ?? 0;
  return Math.round(play + breaks);
}

/** Podrazumevana struktura blajndova (oko 25 % rasta po nivou), za formu u admin panelu. */
export function defaultLevels(startBB = 20, minutes = 10, count = 20): Level[] {
  const nice = (x: number) => {
    const p = Math.pow(10, Math.floor(Math.log10(x)));
    const steps = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10];
    return Math.round(steps.find((s) => s * p >= x * 0.97)! * p);
  };
  const out: Level[] = [];
  let bb = startBB;
  for (let i = 0; i < count; i++) {
    const b = nice(bb);
    out.push({ sb: Math.floor(b / 2), bb: b, ante: i >= 3 ? Math.floor(b / 8) : 0, minutes });
    bb = b * 1.3;
  }
  return out;
}

/** Provera strukture iz forme (greška na srpskom ili null). */
export function validateLevels(levels: unknown): string | null {
  if (!Array.isArray(levels) || levels.length === 0) return 'Unesite bar jedan nivo blajndova.';
  for (const [k, l] of levels.entries()) {
    const v = l as Partial<Level>;
    const ok = [v.sb, v.bb, v.ante, v.minutes].every((x) => Number.isInteger(x) && (x as number) >= 0);
    if (!ok || !v.bb || !v.minutes || (v.sb as number) > (v.bb as number)) return `Nivo ${k + 1}: proverite blajndove i trajanje.`;
  }
  return null;
}
