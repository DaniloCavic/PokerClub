/**
 * Deli rake jedne ruke na igrače srazmerno onome što je ko uložio u pot.
 * Zaokruživanje metodom najvećeg ostatka: zbir delova je uvek tačno jednak rake-u.
 */
export function splitRake<K>(rake: number, contributions: { key: K; amount: number }[]): { key: K; amount: number }[] {
  const paying = contributions.filter((c) => c.amount > 0);
  const total = paying.reduce((s, c) => s + c.amount, 0);
  if (rake <= 0 || total <= 0) return [];
  const parts = paying.map((c) => {
    const exact = (rake * c.amount) / total;
    return { key: c.key, amount: Math.floor(exact), rest: exact - Math.floor(exact) };
  });
  let left = rake - parts.reduce((s, p) => s + p.amount, 0);
  for (const p of [...parts].sort((a, b) => b.rest - a.rest)) {
    if (left <= 0) break;
    p.amount++;
    left--;
  }
  return parts.filter((p) => p.amount > 0).map(({ key, amount }) => ({ key, amount }));
}

/** Deo agenta: procenat (u baznim poenima) od rake-a njegovog igrača, zaokruženo na ceo dinar (bez stalnog gubitka na zaokruživanju). */
export const agentCut = (amount: number, shareBps: number) => Math.round((amount * Math.max(0, Math.min(10_000, shareBps))) / 10_000);

/**
 * Podela dela rake-a po lancu agenata (podagenti). [chain] ide od direktnog agenta igrača naviše:
 * svaki procenat (bps) je deo od onoga što dobija agent iznad njega; za najvišeg agenta je deo od celog rake-a.
 * Primer: super agent daje agentu A 70 %, A daje podagentu B 50 % od svog dela → od rake-a 100 B dobija 35, A 35, klub 30.
 * Vraća zaradu svakog agenta (istim redom) i ukupno agentima; ostatak (amount − total) pripada super agentu.
 */
export function chainCuts(amount: number, chain: number[]): { cuts: number[]; total: number } {
  if (!chain.length || amount <= 0) return { cuts: chain.map(() => 0), total: 0 };
  // Koliko ukupno pripada svakom nivou zajedno sa svim nivoima ispod njega.
  const reach: number[] = new Array(chain.length);
  let eff = 1;
  for (let k = chain.length - 1; k >= 0; k--) {
    eff *= Math.max(0, Math.min(10_000, chain[k])) / 10_000;
    reach[k] = Math.round(amount * eff + 1e-9);
    if (k < chain.length - 1) reach[k] = Math.min(reach[k], reach[k + 1]);
  }
  const cuts = chain.map((_, k) => reach[k] - (k > 0 ? reach[k - 1] : 0));
  return { cuts, total: reach[chain.length - 1] };
}
