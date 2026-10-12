import { Logger } from '@nestjs/common';
import * as bcrypt from 'bcryptjs';
import { PrismaService } from './prisma/prisma.service';

/** Pri pokretanju napravi prvog administratora iz ADMIN_USERNAME / ADMIN_PASSWORD (ako ne postoji). */
export async function ensureAdmin(prisma: PrismaService) {
  const username = process.env.ADMIN_USERNAME;
  const password = process.env.ADMIN_PASSWORD;
  if (!username || !password) return;
  const existing = await prisma.user.findUnique({ where: { usernameLower: username.toLowerCase() } });
  if (existing) {
    if (existing.role !== 'ADMIN') await prisma.user.update({ where: { id: existing.id }, data: { role: 'ADMIN' } });
    return;
  }
  await prisma.user.create({
    data: {
      username,
      usernameLower: username.toLowerCase(),
      displayName: 'Administrator',
      role: 'ADMIN',
      passwordHash: await bcrypt.hash(password, 12),
    },
  });
  Logger.log(`Kreiran administrator "${username}".`, 'Bootstrap');
}
