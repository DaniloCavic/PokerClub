import { PrismaService } from '../prisma/prisma.service';
import { chainCuts } from '../poker/engine/rake';

export type ChainLink = { id: string; bps: number };

/**
 * Lanac agenata od datog agenta naviše (agent, njegov nadređeni, …, agent direktno pod super agentom).
 * Kod agenta je nadređeni zapisan u agentId; najviše 10 nivoa (zaštita od petlje).
 */
export async function agentChains(prisma: PrismaService, agentIds: (string | null | undefined)[]) {
  const out = new Map<string, ChainLink[]>();
  const known = new Map<string, { id: string; parent: string | null; bps: number }>();
  let todo = [...new Set(agentIds.filter((x): x is string => !!x))];
  for (let depth = 0; depth < 10 && todo.length; depth++) {
    const rows = await prisma.user.findMany({
      where: { id: { in: todo }, role: 'AGENT' },
      select: { id: true, agentId: true, rakeShareBps: true },
    });
    for (const r of rows) known.set(r.id, { id: r.id, parent: r.agentId, bps: r.rakeShareBps });
    todo = [...new Set(rows.map((r) => r.agentId).filter((x): x is string => !!x && !known.has(x)))];
  }
  for (const start of new Set(agentIds.filter((x): x is string => !!x))) {
    const chain: ChainLink[] = [];
    const seen = new Set<string>();
    let cur = known.get(start);
    while (cur && !seen.has(cur.id) && chain.length < 10) {
      seen.add(cur.id);
      chain.push({ id: cur.id, bps: cur.bps });
      cur = cur.parent ? known.get(cur.parent) : undefined;
    }
    out.set(start, chain);
  }
  return out;
}

/** Podela iznosa (rake ili fee jednog igrača) po lancu: zarada svakog agenta i ukupno agentima. */
export function splitByChain(amount: number, chain: ChainLink[] | undefined) {
  if (!chain?.length) return { total: 0, earnings: [] as { agentId: string; amount: number }[] };
  const { cuts, total } = chainCuts(amount, chain.map((c) => c.bps));
  return { total, earnings: chain.map((c, k) => ({ agentId: c.id, amount: cuts[k] })).filter((e) => e.amount > 0) };
}

/** Da li je blokiran agent ili bilo koji agent iznad njega (blokada agenta važi i za njegove podagente i igrače). */
export async function chainBlocked(prisma: PrismaService, agentId: string | null | undefined) {
  let id = agentId ?? null;
  for (let depth = 0; id && depth < 10; depth++) {
    const a = await prisma.user.findUnique({ where: { id }, select: { isBlocked: true, agentId: true } });
    if (!a) return false;
    if (a.isBlocked) return true;
    id = a.agentId;
  }
  return false;
}

/** Svi podagenti ispod datog agenta (deca, unuci, …). */
export async function subtreeAgentIds(prisma: PrismaService, agentId: string) {
  const all: string[] = [];
  let level = [agentId];
  for (let depth = 0; depth < 10 && level.length; depth++) {
    const rows = await prisma.user.findMany({ where: { role: 'AGENT', agentId: { in: level } }, select: { id: true } });
    level = rows.map((r) => r.id).filter((x) => !all.includes(x) && x !== agentId);
    all.push(...level);
  }
  return all;
}
