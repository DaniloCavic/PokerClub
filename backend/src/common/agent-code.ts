import { PrismaService } from '../prisma/prisma.service';

/** Kod agenta: 6 znakova bez slova i brojeva koji se lako pomešaju (0/O, 1/I). */
const ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

export function randomCode(len = 6) {
  let s = '';
  for (let i = 0; i < len; i++) s += ALPHABET[Math.floor(Math.random() * ALPHABET.length)];
  return s;
}

/** Novi jedinstveni kod agenta. */
export async function newAgentCode(prisma: PrismaService) {
  for (;;) {
    const code = randomCode();
    if (!(await prisma.user.findUnique({ where: { agentCode: code } }))) return code;
  }
}

/** Agenti napravljeni pre uvođenja kodova dobijaju kod pri pokretanju servera. */
export async function ensureAgentCodes(prisma: PrismaService) {
  const agents = await prisma.user.findMany({ where: { role: 'AGENT', agentCode: null }, select: { id: true } });
  for (const a of agents) await prisma.user.update({ where: { id: a.id }, data: { agentCode: await newAgentCode(prisma) } });
}
