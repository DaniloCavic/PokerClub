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
