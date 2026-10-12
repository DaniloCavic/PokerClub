import { BadRequestException, Injectable } from '@nestjs/common';
import { Prisma, TxType } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

type Db = Prisma.TransactionClient;

/**
 * Sve promene balansa idu kroz ovaj servis: balans i stavka u knjizi
 * menjaju se u istoj transakciji baze, pa ne mogu da se raziđu.
 */
@Injectable()
export class WalletService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * Menja balans za `amount` (može biti negativan) i upisuje stavku.
   * Negativna promena uspeva samo ako ima dovoljno žetona.
   */
  async change(
    db: Db,
    userId: string,
    type: TxType,
    amount: number,
    extra: { actorId?: string; tableId?: string; note?: string } = {},
  ) {
    if (!Number.isInteger(amount) || amount === 0) throw new BadRequestException('Iznos mora biti ceo broj veći od nule.');
    if (amount < 0) {
      const res = await db.user.updateMany({
        where: { id: userId, balance: { gte: -amount } },
        data: { balance: { increment: amount } },
      });
      if (res.count === 0) throw new BadRequestException('Nema dovoljno žetona na nalogu.');
    } else {
      await db.user.update({ where: { id: userId }, data: { balance: { increment: amount } } });
    }
    const { balance } = await db.user.findUniqueOrThrow({ where: { id: userId }, select: { balance: true } });
    return db.transaction.create({
      data: { userId, type, amount, balanceAfter: balance, ...extra },
    });
  }

  run<T>(fn: (db: Db) => Promise<T>) {
    return this.prisma.$transaction(fn);
  }
}
