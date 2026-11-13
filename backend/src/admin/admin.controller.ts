import {
  BadRequestException,
  Body,
  ConflictException,
  Controller,
  ForbiddenException,
  Get,
  NotFoundException,
  Param,
  Patch,
  Post,
  Query,
} from '@nestjs/common';
import { Prisma, Role, TxType, User } from '@prisma/client';
import * as bcrypt from 'bcryptjs';
import { BlockDto, CreateUserDto, MoneyDto, TableDto, UpdateUserDto } from '../auth/dto';
import { CurrentUser, Roles, Staff } from '../common/auth.guard';
import { publicUser } from '../common/public-user';
import { PrismaService } from '../prisma/prisma.service';
import { rakePercent, TablesService } from '../tables/tables.service';
import { TablesGateway } from '../tables/tables.gateway';
import { WalletService } from '../wallet/wallet.service';
import { PushService } from '../push/push.service';

const PAGE = 30;
const page = (p?: string) => Math.max(1, Number(p) || 1);

function startOfToday() {
  const d = new Date();
  d.setHours(0, 0, 0, 0);
  return d;
}

/**
 * Admin panel. Agent vidi i menja samo svoje igrače i svoje stolove;
 * administrator vidi sve i upravlja agentima.
 */
@Staff()
@Controller('admin')
export class AdminController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly tables: TablesService,
    private readonly gateway: TablesGateway,
    private readonly push: PushService,
  ) {}

  /** Obaveštenje svim igračima na telefon: novi sto je otvoren, ili je zakazan za kasnije. */
  private announceTable(t: { id: string; name: string; variant: string; smallBlind: number; bigBlind: number; opensAt: Date | null }) {
    const game = `${t.variant === 'OMAHA' ? 'PLO' : 'NLH'} ${t.smallBlind}/${t.bigBlind}`;
    const later = t.opensAt && t.opensAt.getTime() > Date.now();
    void this.push
      .toAllPlayers(
        later
          ? { title: `Zakazan novi sto: ${t.name}`, body: `${game} — počinje ${TablesService.when(t.opensAt!)}.`, tableId: t.id, tag: `new-${t.id}` }
          : { title: `Novi sto je otvoren: ${t.name}`, body: `${game} — uđite i igrajte.`, tableId: t.id, tag: `new-${t.id}` },
      )
      .catch(() => undefined);
  }

  // ---------- Pomoćne ----------

  private playerScope(actor: User): Prisma.UserWhereInput {
    return actor.role === 'ADMIN' ? { role: 'PLAYER' } : { role: 'PLAYER', agentId: actor.id };
  }

  /** Stolove vide i agenti (samo pregled); pravi ih i menja samo super agent. */
  private tableScope(_actor: User): Prisma.PokerTableWhereInput {
    return {};
  }

  private isSuper(actor: User) {
    return actor.role === 'ADMIN';
  }

  private async player(actor: User, id: string) {
    const p = await this.prisma.user.findFirst({ where: { id, ...this.playerScope(actor) } });
    if (!p) throw new NotFoundException('Igrač nije pronađen.');
    return p;
  }

  private async table(actor: User, id: string) {
    const t = await this.prisma.pokerTable.findFirst({ where: { id, ...this.tableScope(actor) } });
    if (!t) throw new NotFoundException('Sto nije pronađen.');
    return t;
  }

  private async createAccount(dto: CreateUserDto, role: Role, agentId: string | null) {
    const exists = await this.prisma.user.findUnique({ where: { usernameLower: dto.username.toLowerCase() } });
    if (exists) throw new ConflictException('Korisničko ime je zauzeto.');
    return this.prisma.user.create({
      data: {
        username: dto.username,
        usernameLower: dto.username.toLowerCase(),
        displayName: dto.displayName,
        passwordHash: await bcrypt.hash(dto.password, 12),
        role,
        agentId,
        note: dto.note || null,
      },
    });
  }

  private async resolveAgentId(actor: User, agentId?: string) {
    if (actor.role !== 'ADMIN') return actor.id;
    if (!agentId) return null;
    const agent = await this.prisma.user.findFirst({ where: { id: agentId, role: 'AGENT' } });
    if (!agent) throw new BadRequestException('Agent nije pronađen.');
    return agent.id;
  }

  // ---------- Pregled ----------

  @Get('me')
  me(@CurrentUser() actor: User) {
    return publicUser(actor);
  }

  @Get('stats')
  async stats(@CurrentUser() actor: User) {
    const players = this.playerScope(actor);
    const tables = this.tableScope(actor);
    const today = startOfToday();
    const txToday = (type: TxType) =>
      this.prisma.transaction.aggregate({
        where: { type, createdAt: { gte: today }, user: players },
        _sum: { amount: true },
      });
    // Rake: super agent vidi ukupan rake i podelu sa agentima; agent vidi samo svoj deo.
    const shareWhere = (since?: Date): Prisma.RakeShareWhereInput => ({
      ...(this.isSuper(actor) ? {} : { agentId: actor.id }),
      ...(since ? { createdAt: { gte: since } } : {}),
    });
    const [sharesToday, sharesTotal] = await Promise.all([
      this.prisma.rakeShare.aggregate({ where: shareWhere(today), _sum: { amount: true, agentCut: true } }),
      this.prisma.rakeShare.aggregate({ where: shareWhere(), _sum: { amount: true, agentCut: true } }),
    ]);
    const [playerCount, blocked, balances, atTables, dep, wd, rakeToday, rakeTotal, openTables, handsToday] = await Promise.all([
      this.prisma.user.count({ where: players }),
      this.prisma.user.count({ where: { ...players, isBlocked: true } }),
      this.prisma.user.aggregate({ where: players, _sum: { balance: true } }),
      this.prisma.tableSeat.aggregate({ where: { user: players }, _sum: { stack: true }, _count: true }),
      txToday('DEPOSIT'),
      txToday('WITHDRAWAL'),
      this.prisma.hand.aggregate({ where: { table: tables, createdAt: { gte: today } }, _sum: { rake: true } }),
      this.prisma.hand.aggregate({ where: { table: tables }, _sum: { rake: true } }),
      this.prisma.pokerTable.count({ where: { ...tables, isOpen: true } }),
      this.prisma.hand.count({ where: { table: tables, createdAt: { gte: today } } }),
    ]);
    return {
      players: playerCount,
      blockedPlayers: blocked,
      balanceOnAccounts: balances._sum.balance ?? 0,
      chipsOnTables: atTables._sum.stack ?? 0,
      seatedPlayers: atTables._count,
      depositsToday: dep._sum.amount ?? 0,
      withdrawalsToday: -(wd._sum.amount ?? 0),
      ...(this.isSuper(actor)
        ? {
            rakeToday: rakeToday._sum.rake ?? 0,
            rakeTotal: rakeTotal._sum.rake ?? 0,
            agentsCutToday: sharesToday._sum.agentCut ?? 0,
            agentsCutTotal: sharesTotal._sum.agentCut ?? 0,
            superShareToday: (rakeToday._sum.rake ?? 0) - (sharesToday._sum.agentCut ?? 0),
            superShareTotal: (rakeTotal._sum.rake ?? 0) - (sharesTotal._sum.agentCut ?? 0),
          }
        : {
            // Agent vidi samo svoju zaradu: ni procenat ni ukupan rake (iz kog bi se procenat izračunao).
            myCutToday: sharesToday._sum.agentCut ?? 0,
            myCutTotal: sharesTotal._sum.agentCut ?? 0,
          }),
      openTables,
      handsToday,
    };
  }

  // ---------- Igrači ----------

  @Get('players')
  async players(@CurrentUser() actor: User, @Query('q') q?: string, @Query('page') p?: string) {
    const where: Prisma.UserWhereInput = {
      ...this.playerScope(actor),
      ...(q?.trim()
        ? {
            OR: [
              { usernameLower: { contains: q.trim().toLowerCase() } },
              { displayName: { contains: q.trim(), mode: 'insensitive' } },
            ],
          }
        : {}),
    };
    const pg = page(p);
    const [items, total] = await Promise.all([
      this.prisma.user.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: (pg - 1) * PAGE,
        take: PAGE,
        include: { agent: { select: { displayName: true } }, seats: { select: { stack: true } } },
      }),
      this.prisma.user.count({ where }),
    ]);
    const earned = await this.earningsByPlayer(actor, items.map((u) => u.id));
    return {
      items: items.map((u) => ({
        ...publicUser(u),
        agentName: u.agent?.displayName ?? null,
        onTables: u.seats.reduce((s, x) => s + x.stack, 0),
        ...earned.get(u.id),
      })),
      total,
      page: pg,
      pageSize: PAGE,
    };
  }

  /**
   * Zarada od igrača (rake koji je on platio): agent vidi samo svoj deo i broj ruku,
   * super agent vidi ceo rake igrača, deo agenta i svoj deo.
   */
  private async earningsByPlayer(actor: User, ids: string[]) {
    const out = new Map<string, Record<string, number>>();
    if (!ids.length) return out;
    const sup = this.isSuper(actor);
    const [shares, hands] = await Promise.all([
      this.prisma.rakeShare.groupBy({
        by: ['userId'],
        // Agent: samo ruke u kojima je igrač bio njegov (ako je igrač premeštan između agenata).
        where: { userId: { in: ids }, ...(sup ? {} : { agentId: actor.id }) },
        _sum: { amount: true, agentCut: true },
      }),
      Promise.all(ids.map((id) => this.prisma.hand.count({ where: { playerIds: { has: id } } }).then((n) => [id, n] as const))),
    ]);
    const handCount = new Map(hands);
    for (const id of ids) {
      const r = shares.find((x) => x.userId === id)?._sum;
      const amount = r?.amount ?? 0;
      const cut = r?.agentCut ?? 0;
      out.set(
        id,
        sup
          ? { hands: handCount.get(id) ?? 0, rakePaid: amount, agentCut: cut, superShare: amount - cut }
          : { hands: handCount.get(id) ?? 0, myEarning: cut },
      );
    }
    return out;
  }

  @Post('players')
  async createPlayer(@CurrentUser() actor: User, @Body() dto: CreateUserDto) {
    const agentId = await this.resolveAgentId(actor, dto.agentId);
    return publicUser(await this.createAccount(dto, 'PLAYER', agentId));
  }

  @Get('players/:id')
  async playerDetails(@CurrentUser() actor: User, @Param('id') id: string, @Query('page') p?: string) {
    const u = await this.player(actor, id);
    const pg = page(p);
    const [transactions, total, seats, agent] = await Promise.all([
      this.prisma.transaction.findMany({
        where: { userId: id },
        orderBy: { createdAt: 'desc' },
        skip: (pg - 1) * PAGE,
        take: PAGE,
        include: { actor: { select: { displayName: true } }, table: { select: { name: true } } },
      }),
      this.prisma.transaction.count({ where: { userId: id } }),
      this.prisma.tableSeat.findMany({ where: { userId: id }, include: { table: { select: { name: true } } } }),
      u.agentId ? this.prisma.user.findUnique({ where: { id: u.agentId }, select: { displayName: true } }) : null,
    ]);
    const earned = (await this.earningsByPlayer(actor, [id])).get(id);
    return {
      user: { ...publicUser(u), agentName: agent?.displayName ?? null, ...earned },
      seats: seats.map((s) => ({ tableId: s.tableId, tableName: s.table.name, seat: s.seat, stack: s.stack })),
      transactions: {
        items: transactions.map((t) => ({
          id: t.id,
          type: t.type,
          amount: t.amount,
          balanceAfter: t.balanceAfter,
          note: t.note,
          actor: t.actor?.displayName ?? null,
          table: t.table?.name ?? null,
          createdAt: t.createdAt,
        })),
        total,
        page: pg,
        pageSize: PAGE,
      },
    };
  }

  @Patch('players/:id')
  async updatePlayer(@CurrentUser() actor: User, @Param('id') id: string, @Body() dto: UpdateUserDto) {
    await this.player(actor, id);
    const data: Prisma.UserUpdateInput = {};
    if (dto.displayName !== undefined) data.displayName = dto.displayName;
    if (dto.note !== undefined) data.note = dto.note || null;
    if (dto.password) data.passwordHash = await bcrypt.hash(dto.password, 12);
    if (dto.agentId !== undefined) {
      if (actor.role !== 'ADMIN') throw new ForbiddenException('Samo administrator premešta igrače.');
      const agentId = await this.resolveAgentId(actor, dto.agentId || undefined);
      data.agent = agentId ? { connect: { id: agentId } } : { disconnect: true };
    }
    return publicUser(await this.prisma.user.update({ where: { id }, data }));
  }

  @Post('players/:id/block')
  async blockPlayer(@CurrentUser() actor: User, @Param('id') id: string, @Body() dto: BlockDto) {
    await this.player(actor, id);
    const u = await this.prisma.user.update({ where: { id }, data: { isBlocked: true, blockedReason: dto.reason || null } });
    await this.tables.removeEverywhere(id, 'Nalog je blokiran.');
    await this.gateway.disconnectUser(id, dto.reason ? `Nalog je blokiran: ${dto.reason}` : 'Nalog je blokiran.');
    return publicUser(u);
  }

  @Post('players/:id/unblock')
  async unblockPlayer(@CurrentUser() actor: User, @Param('id') id: string) {
    await this.player(actor, id);
    return publicUser(await this.prisma.user.update({ where: { id }, data: { isBlocked: false, blockedReason: null } }));
  }

  @Post('players/:id/kick')
  async kickPlayer(@CurrentUser() actor: User, @Param('id') id: string, @Body() body: { tableId?: string }) {
    await this.player(actor, id);
    if (body?.tableId) await this.tables.leave(id, body.tableId, 'Agent vas je podigao sa stola.');
    else await this.tables.removeEverywhere(id, 'Agent vas je podigao sa stola.');
    return { ok: true };
  }

  @Post('players/:id/deposit')
  async deposit(@CurrentUser() actor: User, @Param('id') id: string, @Body() dto: MoneyDto) {
    await this.player(actor, id);
    const tx = await this.wallet.run((db) => this.wallet.change(db, id, 'DEPOSIT', dto.amount, { actorId: actor.id, note: dto.note }));
    return { ok: true, balance: tx.balanceAfter };
  }

  @Post('players/:id/withdraw')
  async withdraw(@CurrentUser() actor: User, @Param('id') id: string, @Body() dto: MoneyDto) {
    await this.player(actor, id);
    const tx = await this.wallet.run((db) =>
      this.wallet.change(db, id, 'WITHDRAWAL', -dto.amount, { actorId: actor.id, note: dto.note }),
    );
    return { ok: true, balance: tx.balanceAfter };
  }

  // ---------- Agenti (samo administrator) ----------

  @Roles('ADMIN')
  @Get('agents')
  async agents() {
    const agents = await this.prisma.user.findMany({
      where: { role: 'AGENT' },
      orderBy: { createdAt: 'desc' },
      include: { _count: { select: { players: true, tables: true } } },
    });
    const balances = await this.prisma.user.groupBy({ by: ['agentId'], where: { role: 'PLAYER' }, _sum: { balance: true } });
    const rake = await this.prisma.rakeShare.groupBy({ by: ['agentId'], _sum: { amount: true, agentCut: true } });
    return agents.map((a) => {
      const r = rake.find((x) => x.agentId === a.id)?._sum;
      return {
        ...publicUser(a),
        rakePercent: a.rakeShareBps / 100,
        players: a._count.players,
        playersBalance: balances.find((b) => b.agentId === a.id)?._sum.balance ?? 0,
        playersRake: r?.amount ?? 0,
        agentCut: r?.agentCut ?? 0,
        superShare: (r?.amount ?? 0) - (r?.agentCut ?? 0),
      };
    });
  }

  @Roles('ADMIN')
  @Post('agents')
  async createAgent(@Body() dto: CreateUserDto) {
    const a = await this.createAccount(dto, 'AGENT', null);
    const u = await this.prisma.user.update({ where: { id: a.id }, data: { rakeShareBps: this.shareBps(dto.rakePercent) } });
    return publicUser(u);
  }

  private shareBps(percent?: number) {
    if (percent === undefined || percent === null) return 0;
    const bps = Math.round(Number(percent) * 100);
    if (!Number.isFinite(bps) || bps < 0 || bps > 10_000) throw new BadRequestException('Procenat mora biti između 0 i 100.');
    return bps;
  }

  @Roles('ADMIN')
  @Patch('agents/:id')
  async updateAgent(@Param('id') id: string, @Body() dto: UpdateUserDto) {
    const a = await this.prisma.user.findFirst({ where: { id, role: 'AGENT' } });
    if (!a) throw new NotFoundException('Agent nije pronađen.');
    const data: Prisma.UserUpdateInput = {};
    if (dto.displayName !== undefined) data.displayName = dto.displayName;
    if (dto.note !== undefined) data.note = dto.note || null;
    if (dto.password) data.passwordHash = await bcrypt.hash(dto.password, 12);
    if (dto.rakePercent !== undefined) data.rakeShareBps = this.shareBps(dto.rakePercent);
    return publicUser(await this.prisma.user.update({ where: { id }, data }));
  }

  /** Blokada agenta: ni on ni njegovi igrači ne mogu da se prijave; igrači ustaju sa stolova. */
  @Roles('ADMIN')
  @Post('agents/:id/block')
  async blockAgent(@Param('id') id: string, @Body() dto: BlockDto) {
    const a = await this.prisma.user.findFirst({ where: { id, role: 'AGENT' } });
    if (!a) throw new NotFoundException('Agent nije pronađen.');
    const u = await this.prisma.user.update({ where: { id }, data: { isBlocked: true, blockedReason: dto.reason || null } });
    await this.gateway.disconnectUser(id, 'Nalog je blokiran.');
    const players = await this.prisma.user.findMany({ where: { agentId: id }, select: { id: true } });
    for (const p of players) {
      await this.tables.removeEverywhere(p.id, 'Nalog trenutno nije aktivan.');
      await this.gateway.disconnectUser(p.id, 'Nalog trenutno nije aktivan. Javite se svom agentu.');
    }
    return publicUser(u);
  }

  @Roles('ADMIN')
  @Post('agents/:id/unblock')
  async unblockAgent(@Param('id') id: string) {
    const a = await this.prisma.user.findFirst({ where: { id, role: 'AGENT' } });
    if (!a) throw new NotFoundException('Agent nije pronađen.');
    return publicUser(await this.prisma.user.update({ where: { id }, data: { isBlocked: false, blockedReason: null } }));
  }

  // ---------- Stolovi ----------

  private validateTable(dto: TableDto) {
    if (dto.bigBlind < dto.smallBlind) throw new BadRequestException('Veliki blajnd ne može biti manji od malog.');
    if (dto.minBuyIn < dto.bigBlind) throw new BadRequestException('Najmanji ulaz mora biti bar jedan veliki blajnd.');
    if (dto.maxBuyIn < dto.minBuyIn) throw new BadRequestException('Najveći ulaz ne može biti manji od najmanjeg.');
    const rakeBps = Math.round(Number(dto.rakePercent) * 100);
    if (!Number.isFinite(rakeBps)) throw new BadRequestException('Neispravan rake.');
    const { rakePercent: _ignored, opensAt, ...rest } = dto;
    let opens: Date | null = null;
    if (opensAt) {
      opens = new Date(opensAt);
      if (Number.isNaN(opens.getTime())) throw new BadRequestException('Neispravno vreme otvaranja.');
    }
    return { ...rest, rakeBps, opensAt: opens };
  }

  private tableView(t: Prisma.PokerTableGetPayload<{ include: { createdBy: { select: { displayName: true } } } }>) {
    return {
      id: t.id,
      name: t.name,
      variant: t.variant,
      smallBlind: t.smallBlind,
      bigBlind: t.bigBlind,
      minBuyIn: t.minBuyIn,
      maxBuyIn: t.maxBuyIn,
      maxSeats: t.maxSeats,
      rakePercent: rakePercent(t),
      rakeCap: t.rakeCap,
      actionSeconds: t.actionSeconds,
      straddle: t.straddle,
      bombPotEvery: t.bombPotEvery,
      bombPotBB: t.bombPotBB,
      isOpen: t.isOpen,
      opensAt: t.opensAt,
      createdBy: t.createdBy.displayName,
      createdById: t.createdById,
      createdAt: t.createdAt,
      live: this.tables.liveInfo(t.id),
    };
  }

  @Get('tables')
  async listTables(@CurrentUser() actor: User) {
    const items = await this.prisma.pokerTable.findMany({
      where: this.tableScope(actor),
      orderBy: [{ isOpen: 'desc' }, { createdAt: 'desc' }],
      include: { createdBy: { select: { displayName: true } } },
    });
    const rake = await this.prisma.hand.groupBy({
      by: ['tableId'],
      where: { tableId: { in: items.map((t) => t.id) } },
      _sum: { rake: true },
      _count: true,
    });
    return items.map((t) => {
      const r = rake.find((x) => x.tableId === t.id);
      return { ...this.tableView(t), rakeTotal: this.isSuper(actor) ? (r?._sum.rake ?? 0) : null, hands: r?._count ?? 0 };
    });
  }

  @Roles('ADMIN')
  @Post('tables')
  async createTable(@CurrentUser() actor: User, @Body() dto: TableDto) {
    const t = await this.prisma.pokerTable.create({
      data: { ...this.validateTable(dto), createdById: actor.id },
      include: { createdBy: { select: { displayName: true } } },
    });
    await this.tables.open(t);
    this.announceTable(t);
    return this.tableView(t);
  }

  @Roles('ADMIN')
  @Patch('tables/:id')
  async updateTable(@CurrentUser() actor: User, @Param('id') id: string, @Body() dto: TableDto) {
    await this.table(actor, id);
    this.tables.assertClosed(id);
    const t = await this.prisma.pokerTable.update({
      where: { id },
      data: this.validateTable(dto),
      include: { createdBy: { select: { displayName: true } } },
    });
    return this.tableView(t);
  }

  @Roles('ADMIN')
  @Post('tables/:id/close')
  async closeTable(@CurrentUser() actor: User, @Param('id') id: string) {
    await this.table(actor, id);
    await this.prisma.pokerTable.update({ where: { id }, data: { isOpen: false, closedAt: new Date() } });
    await this.tables.close(id);
    return { ok: true };
  }

  @Roles('ADMIN')
  @Post('tables/:id/open')
  async openTable(@CurrentUser() actor: User, @Param('id') id: string) {
    await this.table(actor, id);
    if (this.tables.liveInfo(id)?.closing) throw new BadRequestException('Sto se još zatvara, sačekajte kraj ruke.');
    const t = await this.prisma.pokerTable.update({ where: { id }, data: { isOpen: true, closedAt: null } });
    await this.tables.open(t);
    this.announceTable(t);
    return { ok: true };
  }

  @Get('tables/:id')
  async tableDetails(@CurrentUser() actor: User, @Param('id') id: string, @Query('page') p?: string) {
    await this.table(actor, id);
    const t = await this.prisma.pokerTable.findUniqueOrThrow({ where: { id }, include: { createdBy: { select: { displayName: true } } } });
    const pg = page(p);
    const [hands, total, rake] = await Promise.all([
      this.prisma.hand.findMany({
        where: { tableId: id },
        orderBy: { createdAt: 'desc' },
        skip: (pg - 1) * PAGE,
        take: PAGE,
        select: { id: true, handNo: true, board: true, pot: true, rake: true, createdAt: true },
      }),
      this.prisma.hand.count({ where: { tableId: id } }),
      this.prisma.hand.aggregate({ where: { tableId: id }, _sum: { rake: true } }),
    ]);
    const sup = this.isSuper(actor);
    return {
      table: { ...this.tableView(t), rakeTotal: sup ? (rake._sum.rake ?? 0) : null },
      hands: { items: sup ? hands : hands.map(({ rake: _r, ...h }) => h), total, page: pg, pageSize: PAGE },
    };
  }

  /**
   * "Karte uživo": super agent vidi karte svih igrača u ruci koja je u toku.
   * Igrači ne dobijaju nikakvo obaveštenje; otvaranje se samo beleži (jednom po ruci).
   */
  @Roles('ADMIN')
  @Get('tables/:id/live')
  async live(@CurrentUser() actor: User, @Param('id') id: string) {
    await this.table(actor, id);
    const t = await this.prisma.pokerTable.findUniqueOrThrow({ where: { id }, include: { createdBy: { select: { displayName: true } } } });
    const view = this.tables.liveView(id);
    if (!view) return { live: false, table: this.tableView(t) };
    const key = `${actor.id}:${id}`;
    if (view.inProgress && this.liveLogged.get(key) !== view.handNo) {
      this.liveLogged.set(key, view.handNo);
      await this.prisma.liveViewLog.create({ data: { actorId: actor.id, tableId: id, tableName: t.name, handNo: view.handNo } });
    }
    return { live: true, table: this.tableView(t), state: view };
  }

  /** Spisak otvaranja "karata uživo" (samo super agent). */
  @Roles('ADMIN')
  @Get('live-log')
  async liveLog() {
    const items = await this.prisma.liveViewLog.findMany({
      orderBy: { createdAt: 'desc' },
      take: 100,
      include: { actor: { select: { displayName: true } } },
    });
    return items.map((l) => ({ id: l.id, actor: l.actor.displayName, tableName: l.tableName, handNo: l.handNo, createdAt: l.createdAt }));
  }

  /** Poslednja ruka po (super agent, sto) koja je već zabeležena. */
  private readonly liveLogged = new Map<string, number>();

  @Get('hands/:id')
  async hand(@CurrentUser() actor: User, @Param('id') id: string) {
    const h = await this.prisma.hand.findUnique({ where: { id }, include: { table: { select: { name: true, createdById: true, variant: true } } } });
    if (!h) throw new NotFoundException('Ruka nije pronađena.');
    if (this.isSuper(actor)) return h;
    // Agent vidi tok ruke, ali ne i ukupan rake stola.
    const d = h.details as { log?: string[] };
    const { rake: _r, ...rest } = h;
    return { ...rest, details: { ...d, log: (d.log ?? []).filter((l) => !l.startsWith('Rake')) } };
  }

  // ---------- Transakcije ----------

  @Get('transactions')
  async transactions(@CurrentUser() actor: User, @Query('type') type?: string, @Query('page') p?: string) {
    const types: TxType[] = ['DEPOSIT', 'WITHDRAWAL', 'BUY_IN', 'CASH_OUT'];
    const where: Prisma.TransactionWhereInput = {
      user: this.playerScope(actor),
      ...(type && types.includes(type as TxType) ? { type: type as TxType } : {}),
    };
    const pg = page(p);
    const [items, total] = await Promise.all([
      this.prisma.transaction.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: (pg - 1) * PAGE,
        take: PAGE,
        include: {
          user: { select: { id: true, username: true, displayName: true } },
          actor: { select: { displayName: true } },
          table: { select: { name: true } },
        },
      }),
      this.prisma.transaction.count({ where }),
    ]);
    return {
      items: items.map((t) => ({
        id: t.id,
        type: t.type,
        amount: t.amount,
        balanceAfter: t.balanceAfter,
        note: t.note,
        user: t.user,
        actor: t.actor?.displayName ?? null,
        table: t.table?.name ?? null,
        createdAt: t.createdAt,
      })),
      total,
      page: pg,
      pageSize: PAGE,
    };
  }
}
