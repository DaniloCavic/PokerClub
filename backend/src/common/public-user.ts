import { User } from '@prisma/client';

/** Podaci o korisniku koji se šalju klijentu (bez lozinke). */
export const avatarUrl = (u: Pick<User, 'id' | 'avatarAt'>) =>
  u.avatarAt ? `/api/avatars/${u.id}?v=${u.avatarAt.getTime()}` : null;

export function publicUser(u: User) {
  return {
    avatarUrl: avatarUrl(u),
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
