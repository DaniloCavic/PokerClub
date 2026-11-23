import { BadRequestException, Body, Controller, Get, NotFoundException, Param, Post, Query } from '@nestjs/common';
import { Prisma, User } from '@prisma/client';
import { IsIn, IsInt, IsOptional, IsString, Max, MaxLength, Min } from 'class-validator';
import { CurrentUser, Staff } from '../common/auth.guard';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { PushService } from '../push/push.service';
import { TablesService } from '../tables/tables.service';
import { trUser } from '../common/i18n';

class CashRequestDto {
  @IsIn(['DEPOSIT', 'WITHDRAWAL'], { message: 'Izaberite uplatu ili isplatu.' })
  type: 'DEPOSIT' | 'WITHDRAWAL';

  @IsInt({ message: 'Iznos mora biti ceo broj.' })
  @Min(1, { message: 'Iznos mora biti veći od nule.' })
  @Max(100_000_000, { message: 'Iznos je prevelik.' })
  amount: number;

  @IsOptional()
  @IsString()
  @MaxLength(200)
  note?: string;
}

const view = (r: { id: string; type: string; amount: number; note: string | null; status: string; createdAt: Date; decidedAt: Date | null }) => ({
  id: r.id,
  type: r.type,
  amount: r.amount,
  note: r.note,
  status: r.status,
  createdAt: r.createdAt,
  decidedAt: r.decidedAt,
});

/** Igrač: zahtevi za uplatu i isplatu (agent ih odobrava u admin panelu). */
@Controller('me/cash-requests')
export class MeCashController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly push: PushService,
  ) {}

  @Get()
  async list(@CurrentUser() user: User) {
    const items = await this.prisma.cashRequest.findMany({ where: { userId: user.id }, orderBy: { createdAt: 'desc' }, take: 20 });
    return items.map(view);
  }

  @Post()
  async create(@CurrentUser() user: User, @Body() dto: CashRequestDto) {
    if (user.role !== 'PLAYER') throw new BadRequestException('Samo igrači šalju zahteve.');
    const pending = await this.prisma.cashRequest.count({ where: { userId: user.id, status: 'PENDING' } });
    if (pending >= 3) throw new BadRequestException('Već imate zahteve koji čekaju odobrenje.');
    if (dto.type === 'WITHDRAWAL' && dto.amount > user.balance) throw new BadRequestException('Nemate toliko na nalogu.');
    const r = await this.prisma.cashRequest.create({
      data: { userId: user.id, agentId: user.agentId, type: dto.type, amount: dto.amount, note: dto.note?.trim() || null },
    });
    // Obaveštenje agentu (ili super agentu ako igrač nema agenta).
    const to = user.agentId ? [user.agentId] : (await this.prisma.user.findMany({ where: { role: 'ADMIN' }, select: { id: true } })).map((a) => a.id);
    const what = dto.type === 'DEPOSIT' ? 'uplatu' : 'isplatu';
    for (const id of to) {
      void this.push.toUser(id, { title: `Zahtev za ${what}`, body: `${user.displayName}: ${dto.amount} RSD`, tag: `cash-${r.id}` }).catch(() => undefined);
    }
    return view(r);
  }

  @Post(':id/cancel')
  async cancel(@CurrentUser() user: User, @Param('id') id: string) {
    const r = await this.prisma.cashRequest.updateMany({ where: { id, userId: user.id, status: 'PENDING' }, data: { status: 'CANCELLED', decidedAt: new Date() } });
    if (!r.count) throw new NotFoundException('Zahtev nije pronađen.');
    return { ok: true };
  }
}

/** Agent i super agent: zahtevi igrača za uplatu i isplatu. */
@Staff()
@Controller('admin/cash-requests')
export class AdminCashController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly push: PushService,
    private readonly tables: TablesService,
  ) {}

  /** Agent vidi zahteve svojih igrača; super agent sve (i igrača bez agenta). */
  private scope(actor: User): Prisma.CashRequestWhereInput {
    return actor.role === 'ADMIN' ? {} : { agentId: actor.id };
  }

  @Get()
  async list(@CurrentUser() actor: User, @Query('status') status?: string) {
    const where: Prisma.CashRequestWhereInput = { ...this.scope(actor), ...(status === 'PENDING' ? { status: 'PENDING' } : {}) };
    const items = await this.prisma.cashRequest.findMany({ where, orderBy: { createdAt: 'desc' }, take: 100 });
    const ids = [...new Set(items.flatMap((r) => [r.userId, r.decidedById, r.agentId]).filter((x): x is string => !!x))];
    const users = await this.prisma.user.findMany({ where: { id: { in: ids } }, select: { id: true, displayName: true, username: true, balance: true } });
    const u = (id: string | null) => users.find((x) => x.id === id);
    return items.map((r) => ({
      ...view(r),
      player: { id: r.userId, name: u(r.userId)?.displayName ?? '?', username: u(r.userId)?.username, balance: u(r.userId)?.balance ?? 0 },
      agent: r.agentId ? (u(r.agentId)?.displayName ?? '?') : null,
      decidedBy: r.decidedById ? (u(r.decidedById)?.displayName ?? '?') : null,
    }));
  }

  @Get('count')
  async count(@CurrentUser() actor: User) {
    return { pending: await this.prisma.cashRequest.count({ where: { ...this.scope(actor), status: 'PENDING' } }) };
  }

  private async pendingOf(actor: User, id: string) {
    const r = await this.prisma.cashRequest.findFirst({ where: { id, ...this.scope(actor) } });
    if (!r) throw new NotFoundException('Zahtev nije pronađen.');
    if (r.status !== 'PENDING') throw new BadRequestException('Zahtev je već rešen.');
    return r;
  }

  @Post(':id/approve')
  async approve(@CurrentUser() actor: User, @Param('id') id: string) {
    const r = await this.pendingOf(actor, id);
    await this.wallet.run(async (db) => {
      // Zahtev se rešava samo jednom (i kad dva agenta kliknu istovremeno).
      const claimed = await db.cashRequest.updateMany({ where: { id, status: 'PENDING' }, data: { status: 'APPROVED', decidedById: actor.id, decidedAt: new Date() } });
      if (!claimed.count) throw new BadRequestException('Zahtev je već rešen.');
      await this.wallet.change(db, r.userId, r.type === 'DEPOSIT' ? 'DEPOSIT' : 'WITHDRAWAL', r.type === 'DEPOSIT' ? r.amount : -r.amount, {
        actorId: actor.id,
        note: `Zahtev igrača${r.note ? `: ${r.note}` : ''}`,
      });
    });
    await this.tables.balanceChangedPublic(r.userId);
    void this.push
      .toUser(r.userId, {
        title: trUser(r.type === 'DEPOSIT' ? 'Uplata je odobrena' : 'Isplata je odobrena', r.userId),
        body: `${r.amount} RSD`,
        tag: `cash-${r.id}`,
      })
      .catch(() => undefined);
    return { ok: true };
  }

  @Post(':id/reject')
  async reject(@CurrentUser() actor: User, @Param('id') id: string) {
    const r = await this.pendingOf(actor, id);
    await this.prisma.cashRequest.updateMany({ where: { id, status: 'PENDING' }, data: { status: 'REJECTED', decidedById: actor.id, decidedAt: new Date() } });
    void this.push
      .toUser(r.userId, { title: trUser(r.type === 'DEPOSIT' ? 'Zahtev za uplatu je odbijen' : 'Zahtev za isplatu je odbijen', r.userId), body: `${r.amount} RSD`, tag: `cash-${r.id}` })
      .catch(() => undefined);
    return { ok: true };
  }
}
