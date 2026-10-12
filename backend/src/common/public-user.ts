import { User } from '@prisma/client';

/** Podaci o korisniku koji se šalju klijentu (bez lozinke). */
export function publicUser(u: User) {
  return {
    id: u.id,
    username: u.username,
    displayName: u.displayName,
    role: u.role,
    balance: u.balance,
    isBlocked: u.isBlocked,
    blockedReason: u.blockedReason,
    note: u.note,
    agentId: u.agentId,
    createdAt: u.createdAt,
    lastSeenAt: u.lastSeenAt,
  };
}
