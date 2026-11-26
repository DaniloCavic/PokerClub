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
  Res,
} from '@nestjs/common';
import { Prisma, Role, TxType, User } from '@prisma/client';
import * as bcrypt from 'bcryptjs';
import { BlockDto, CreateUserDto, MoneyDto, TableDto, UpdateUserDto } from '../auth/dto';
import { CurrentUser, Roles, Staff } from '../common/auth.guard';
import { publicUser } from '../common/public-user';
import { agentChains, subtreeAgentIds } from '../common/agent-chain';
import { PrismaService } from '../prisma/prisma.service';
import { rakePercent, TablesService } from '../tables/tables.service';
import { TablesGateway } from '../tables/tables.gateway';
import { WalletService } from '../wallet/wallet.service';
import { PushService } from '../push/push.service';
import { newTotpSecret, totpUrl, verifyTotp } from '../common/totp';
import { addDays, DailyService, localNow } from '../daily/daily.service';
import { ownerEmail } from '../common/mail';
import type { Response } from 'express';

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
    private readonly daily: DailyService,
  ) {}

  /** Super agent: preuzimanje cele baze (sa slikama igrača) kao rezervne kopije. */
  @Roles('ADMIN')
  @Get('backup')
  async backupFile(@Res() res: Response) {
    const file = await this.daily.backup(true);
    const { date } = localNow();
    res.setHeader('content-type', 'application/gzip');
    res.setHeader('content-disposition', `attachment; filename="triling-baza-${date}.json.gz"`);
    res.send(file);
  }

  /** Super agent: današnji izveštaj odmah na mejl (i rezervna kopija), za proveru da slanje radi. */
  @Roles('ADMIN')
  @Post('daily/send')
  async sendDaily() {
    const { date } = localNow();
    const to = ownerEmail();
    if (!to) throw new BadRequestException('Nije podešena adresa (MAIL_FROM ili REPORT_EMAIL).');
    // Izveštaj za poslednjih 7 dana (do danas), kao provera kako izgleda nedeljni.
    await this.daily.mailReport(addDays(date, -6), date);
    await this.daily.mailBackup(date);
    return { ok: true, to };
  }

  /** Obaveštenje svim igračima na telefon: novi sto je otvoren, ili je zakazan za kasnije. */
  private announceTable(t: { id: string; name: string; variant: string; smallBlind: number; bigBlind: number; opensAt: Date | null; ownerAgentId?: string | null }) {
    const game = `${t.variant === 'OMAHA' ? 'PLO' : 'NLH'} ${t.smallBlind}/${t.bigBlind}`;
    const later = t.opensAt && t.opensAt.getTime() > Date.now();
    void this.push
      .toAllPlayers(
        later
          ? { title: `Zakazan novi sto: ${t.name}`, body: `${game} — počinje ${TablesService.when(t.opensAt!)}.`, tableId: t.id, tag: `new-${t.id}` }
          : { title: `Novi sto je otvoren: ${t.name}`, body: `${game} — uđite i igrajte.`, tableId: t.id, tag: `new-${t.id}` },
        t.ownerAgentId,
      )
      .catch(() => undefined);
  }

  // ---------- Pomoćne ----------

  private playerScope(actor: User): Prisma.UserWhereInput {
    return actor.role === 'ADMIN' ? { role: 'PLAYER' } : { role: 'PLAYER', agentId: actor.id };
  }

  /**
   * Stolovi: super agent vidi sve. Agent vidi stolove za sve, svoje privatne stolove i privatne stolove agenata iznad sebe
   * (tamo igraju i njegovi igrači); menja samo svoje. Stolovi turnira se vode na stranici Turniri.
   */
  private tableScope(actor: User, owners: string[] = [actor.id]): Prisma.PokerTableWhereInput {
    if (actor.role === 'ADMIN') return { tournamentId: null };
    return { tournamentId: null, OR: [{ ownerAgentId: null }, { ownerAgentId: { in: owners } }] };
  }

  /** Agent i svi agenti iznad njega (čije privatne stolove vidi). */
  private async ownersFor(actor: User) {
    if (actor.role === 'ADMIN') return [];
    const chain = (await agentChains(this.prisma, [actor.id])).get(actor.id) ?? [];
    return [actor.id, ...chain.map((c) => c.id)];
  }

  /** Sto koji ovaj korisnik sme da menja: super agent bilo koji, agent samo svoj privatni sto. */
  private async ownTable(actor: User, id: string) {
    const t = await this.table(actor, id);
    if (actor.role !== 'ADMIN' && t.ownerAgentId !== actor.id) throw new ForbiddenException('Možete menjati samo svoje stolove.');
    return t;
  }

  private isSuper(actor: User) {
    return actor.role === 'ADMIN';
  }

  /** Zarada agenta (rake i turnirski fee, od svojih igrača i igrača podagenata). */
  private async myEarning(agentId: string, since?: Date, playerIds?: string[]) {
    const r = await this.prisma.agentEarning.aggregate({
      where: { agentId, ...(since ? { createdAt: { gte: since } } : {}), ...(playerIds ? { playerId: { in: playerIds } } : {}) },
      _sum: { amount: true },
    });
    return r._sum.amount ?? 0;
  }

  private async player(actor: User, id: string) {
    const p = await this.prisma.user.findFirst({ where: { id, ...this.playerScope(actor) } });
    if (!p) throw new NotFoundException('Igrač nije pronađen.');
    return p;
  }

  private async table(actor: User, id: string) {
    const t = await this.prisma.pokerTable.findFirst({ where: { id, ...this.tableScope(actor, await this.ownersFor(actor)) } });
    if (!t) throw new NotFoundException('Sto nije pronađen.');
    return t;
  }

  private async createAccount(dto: CreateUserDto, role: Role, agentId: string | null) {
    const exists = await this.prisma.user.findUnique({ where: { usernameLower: dto.username.toLowerCase() } });
    if (exists) throw new ConflictException('Korisničko ime je zauzeto.');
    await this.checkEmail(dto.email);
    return this.prisma.user.create({
      data: {
        username: dto.username,
        usernameLower: dto.username.toLowerCase(),
        displayName: dto.displayName,
        passwordHash: await bcrypt.hash(dto.password, 12),
        role,
        agentId,
        note: dto.note || null,
        email: dto.email || null,
      },
    });
  }

  /** E-pošta mora biti jedinstvena (njome se igrač prijavljuje i vraća lozinku). */
  private async checkEmail(email: string | undefined, exceptId?: string) {
    if (!email) return;
    const other = await this.prisma.user.findUnique({ where: { email } });
    if (other && other.id !== exceptId) throw new ConflictException('Nalog sa ovom e-poštom već postoji.');
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
    const feeWhere = (since?: Date): Prisma.FeeShareWhereInput => ({
      ...(this.isSuper(actor) ? {} : { agentId: actor.id }),
      ...(since ? { createdAt: { gte: since } } : {}),
    });
    const [sharesToday, sharesTotal, feesToday, feesTotal] = await Promise.all([
      this.prisma.rakeShare.aggregate({ where: shareWhere(today), _sum: { amount: true, agentCut: true } }),
      this.prisma.rakeShare.aggregate({ where: shareWhere(), _sum: { amount: true, agentCut: true } }),
      this.prisma.feeShare.aggregate({ where: feeWhere(today), _sum: { amount: true, agentCut: true } }),
      this.prisma.feeShare.aggregate({ where: feeWhere(), _sum: { amount: true, agentCut: true } }),
    ]);
    const fT = { amount: feesToday._sum.amount ?? 0, cut: feesToday._sum.agentCut ?? 0 };
    const fA = { amount: feesTotal._sum.amount ?? 0, cut: feesTotal._sum.agentCut ?? 0 };
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
            feesToday: fT.amount,
            feesTotal: fA.amount,
            agentsCutToday: (sharesToday._sum.agentCut ?? 0) + fT.cut,
            agentsCutTotal: (sharesTotal._sum.agentCut ?? 0) + fA.cut,
            superShareToday: (rakeToday._sum.rake ?? 0) - (sharesToday._sum.agentCut ?? 0) + fT.amount - fT.cut,
            superShareTotal: (rakeTotal._sum.rake ?? 0) - (sharesTotal._sum.agentCut ?? 0) + fA.amount - fA.cut,
          }
        : {
            // Agent vidi samo svoju zaradu (i od igrača svojih podagenata): ni procenat ni ukupan rake.
            myCutToday: await this.myEarning(actor.id, today),
            myCutTotal: await this.myEarning(actor.id),
          }),
      openTables,
      handsToday,
    };
  }

  // ---------- Moj nalog: dvostepena prijava (2FA) i prijave ----------

  @Get('account')
  async account(@CurrentUser() actor: User) {
    const logins = await this.prisma.loginLog.findMany({ where: { userId: actor.id }, orderBy: { createdAt: 'desc' }, take: 20 });
    return { totpEnabled: actor.totpEnabled, logins };
  }

  /** Novi tajni ključ za aplikaciju za autentifikaciju (važi tek kad se potvrdi kodom). */
  @Post('2fa/setup')
  async setup2fa(@CurrentUser() actor: User) {
    if (actor.totpEnabled) throw new BadRequestException('Dvostepena prijava je već uključena.');
    const secret = newTotpSecret();
    await this.prisma.user.update({ where: { id: actor.id }, data: { totpSecret: secret } });
    return { secret, url: totpUrl(secret, actor.username) };
  }

  @Post('2fa/enable')
  async enable2fa(@CurrentUser() actor: User, @Body() b: { code?: string }) {
    if (!actor.totpSecret || !verifyTotp(actor.totpSecret, String(b?.code ?? ''))) throw new BadRequestException('Kod nije tačan. Proverite vreme na telefonu i pokušajte ponovo.');
    await this.prisma.user.update({ where: { id: actor.id }, data: { totpEnabled: true } });
    return { ok: true };
  }

  @Post('2fa/disable')
  async disable2fa(@CurrentUser() actor: User, @Body() b: { code?: string; password?: string }) {
    if (!actor.totpEnabled || !actor.totpSecret) return { ok: true };
    if (!(await bcrypt.compare(String(b?.password ?? ''), actor.passwordHash)) || !verifyTotp(actor.totpSecret, String(b?.code ?? ''))) {
      throw new BadRequestException('Lozinka ili kod nisu tačni.');
    }
    await this.prisma.user.update({ where: { id: actor.id }, data: { totpEnabled: false, totpSecret: null } });
    return { ok: true };
  }

  /** Super agent isključuje 2FA agentu koji je izgubio telefon (agent ga posle ponovo uključuje). */
  @Roles('ADMIN')
  @Post('agents/:id/reset-2fa')
  async reset2fa(@Param('id') id: string) {
    await this.prisma.user.updateMany({ where: { id, role: 'AGENT' }, data: { totpEnabled: false, totpSecret: null, tokenVersion: { increment: 1 } } });
    return { ok: true };
  }

  // ---------- Bezbednost ----------

  /**
   * Upozorenja (ista IP adresa ili uređaj za istim stolom) i parovi igrača koji su
   * u poslednjih 7 dana najčešće igrali iste ruke (mogući dogovor).
   */
  @Roles('ADMIN')
  @Get('security')
  async security() {
    const alerts = await this.prisma.securityAlert.findMany({ orderBy: { createdAt: 'desc' }, take: 100 });
    const since = new Date(Date.now() - 7 * 86_400_000);
    const pairs = await this.prisma.$queryRaw<{ a: string; b: string; hands: number }[]>`
      SELECT p1 AS a, p2 AS b, COUNT(*)::int AS hands
      FROM (
        SELECT x.p AS p1, y.p AS p2
        FROM "Hand" h, unnest(h."playerIds") AS x(p), unnest(h."playerIds") AS y(p)
        WHERE h."createdAt" >= ${since} AND x.p < y.p
      ) t
      GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 15`;
    const ids = [...new Set(pairs.flatMap((p) => [p.a, p.b]))];
    const users = await this.prisma.user.findMany({ where: { id: { in: ids } }, select: { id: true, displayName: true, lastIp: true } });
    const u = (id: string) => users.find((x) => x.id === id);
    // Prijave super agenta i agenata (i neuspešne) — da se vidi ko je i odakle ulazio.
    const staffLogins = await this.prisma.loginLog.findMany({
      where: { staff: true },
      orderBy: { createdAt: 'desc' },
      take: 50,
      include: { user: { select: { displayName: true, role: true } } },
    });
    return {
      alerts,
      staffLogins,
      pairs: pairs.map((p) => ({
        ...p,
        nameA: u(p.a)?.displayName ?? '?',
        nameB: u(p.b)?.displayName ?? '?',
        sameIp: !!u(p.a)?.lastIp && u(p.a)?.lastIp === u(p.b)?.lastIp,
      })),
    };
  }

  @Roles('ADMIN')
  @Post('security/seen')
  async securitySeen() {
    await this.prisma.securityAlert.updateMany({ where: { seen: false }, data: { seen: true } });
    return { ok: true };
  }

  // ---------- Poruka dobrodošlice i pravila kluba ----------

  @Get('welcome')
  async getWelcome() {
    const rows = await this.prisma.appSetting.findMany({ where: { key: { in: ['welcomeEn', 'welcomeSr', 'welcomeAt'] } } });
    const v = (k: string) => rows.find((r) => r.key === k)?.value ?? '';
    return { en: v('welcomeEn'), sr: v('welcomeSr'), updatedAt: v('welcomeAt') || null };
  }

  /** Nova poruka: svaki igrač je vidi jednom (i posle svake izmene ponovo). */
  @Roles('ADMIN')
  @Post('welcome')
  async setWelcome(@Body() b: { en?: string; sr?: string }) {
    const en = String(b?.en ?? '').slice(0, 4000);
    const sr = String(b?.sr ?? '').slice(0, 4000);
    const at = new Date().toISOString();
    for (const [key, value] of [['welcomeEn', en], ['welcomeSr', sr], ['welcomeAt', at]]) {
      await this.prisma.appSetting.upsert({ where: { key }, create: { key, value }, update: { value } });
    }
    return { ok: true, updatedAt: at };
  }

  // ---------- Izveštaj zarade ----------

  /**
   * Zarada po danima: rake sa keš stolova i fee sa turnira, deo agenata i deo super agenta.
   * Super agent vidi i podelu po agentima; agent vidi samo svoju zaradu.
   */
  @Get('reports')
  async report(@CurrentUser() actor: User, @Query('from') from?: string, @Query('to') to?: string) {
    const tz = process.env.APP_TIMEZONE || 'Europe/Belgrade';
    const day = (s: string | undefined, fallback: Date) => (s && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : fallback.toISOString().slice(0, 10));
    const toDay = day(to, new Date());
    const fromDay = day(from, new Date(Date.now() - 29 * 86_400_000));
    const agentFilter = this.isSuper(actor) ? Prisma.empty : Prisma.sql`AND "agentId" = ${actor.id}`;
    const q = (table: 'RakeShare' | 'FeeShare') => Prisma.sql`
      SELECT to_char(("createdAt" AT TIME ZONE 'UTC') AT TIME ZONE ${tz}, 'YYYY-MM-DD') AS day,
             "agentId", SUM(amount)::int AS amount, SUM("agentCut")::int AS cut
      FROM ${Prisma.raw(`"${table}"`)}
      WHERE (("createdAt" AT TIME ZONE 'UTC') AT TIME ZONE ${tz})::date BETWEEN ${fromDay}::date AND ${toDay}::date ${agentFilter}
      GROUP BY 1, 2`;
    type Row = { day: string; agentId: string | null; amount: number; cut: number };
    const [rake, fees] = await Promise.all([this.prisma.$queryRaw<Row[]>(q('RakeShare')), this.prisma.$queryRaw<Row[]>(q('FeeShare'))]);
    const days: string[] = [];
    for (let d = new Date(`${fromDay}T12:00:00Z`); d.toISOString().slice(0, 10) <= toDay; d = new Date(d.getTime() + 86_400_000)) {
      days.push(d.toISOString().slice(0, 10));
      if (days.length > 400) break;
    }
    const sum = (rows: Row[], k: 'amount' | 'cut', dayKey?: string, agentId?: string | null) =>
      rows.filter((r) => (dayKey === undefined || r.day === dayKey) && (agentId === undefined || r.agentId === agentId)).reduce((a, r) => a + (r[k] ?? 0), 0);
    const series = days.map((d) => ({
      day: d,
      rake: sum(rake, 'amount', d),
      fees: sum(fees, 'amount', d),
      agentsCut: sum(rake, 'cut', d) + sum(fees, 'cut', d),
    }));
    if (!this.isSuper(actor)) {
      // Agent: samo svoja zarada (bez ukupnog rake-a iz kog bi se video procenat).
      return { from: fromDay, to: toDay, series: series.map((x) => ({ day: x.day, myCut: x.agentsCut })), total: { myCut: series.reduce((a, x) => a + x.agentsCut, 0) } };
    }
    const agentIds = [...new Set([...rake, ...fees].map((r) => r.agentId))];
    const names = await this.prisma.user.findMany({ where: { id: { in: agentIds.filter((x): x is string => !!x) } }, select: { id: true, displayName: true } });
    const byAgent = agentIds
      .map((id) => ({
        agentId: id,
        name: id ? (names.find((n) => n.id === id)?.displayName ?? '?') : 'Bez agenta',
        rake: sum(rake, 'amount', undefined, id),
        fees: sum(fees, 'amount', undefined, id),
        agentCut: sum(rake, 'cut', undefined, id) + sum(fees, 'cut', undefined, id),
      }))
      .map((a) => ({ ...a, superShare: a.rake + a.fees - a.agentCut }))
      .sort((a, b) => b.rake + b.fees - (a.rake + a.fees));
    const total = series.reduce(
      (a, x) => ({ rake: a.rake + x.rake, fees: a.fees + x.fees, agentsCut: a.agentsCut + x.agentsCut }),
      { rake: 0, fees: 0, agentsCut: 0 },
    );
    return {
      from: fromDay,
      to: toDay,
      series: series.map((x) => ({ ...x, superShare: x.rake + x.fees - x.agentsCut })),
      byAgent,
      total: { ...total, superShare: total.rake + total.fees - total.agentsCut },
    };
  }

  // ---------- Igrači ----------

  @Get('players')
  async players(@CurrentUser() actor: User, @Query('q') q?: string, @Query('page') p?: string, @Query('noAgent') noAgent?: string) {
    const where: Prisma.UserWhereInput = {
      ...this.playerScope(actor),
      // Super agent: igrači koji su se registrovali bez koda agenta (da ih dodeli agentu).
      ...(noAgent && this.isSuper(actor) ? { agentId: null } : {}),
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
    const fees = await this.prisma.feeShare.groupBy({
      by: ['userId'],
      where: { userId: { in: ids }, ...(sup ? {} : { agentId: actor.id }) },
      _sum: { amount: true, agentCut: true },
    });
    // Agent: njegov deo od svakog igrača (sa podagentima je to manje od agentCut, koji je zbir celog lanca).
    const mine = sup
      ? []
      : await this.prisma.agentEarning.groupBy({ by: ['playerId'], where: { agentId: actor.id, playerId: { in: ids } }, _sum: { amount: true } });
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
      const f = fees.find((x) => x.userId === id)?._sum;
      const amount = (r?.amount ?? 0) + (f?.amount ?? 0);
      const cut = (r?.agentCut ?? 0) + (f?.agentCut ?? 0);
      out.set(
        id,
        sup
          ? { hands: handCount.get(id) ?? 0, rakePaid: amount, agentCut: cut, superShare: amount - cut }
          : { hands: handCount.get(id) ?? 0, myEarning: mine.find((m) => m.playerId === id)?._sum.amount ?? 0 },
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
    if (dto.email !== undefined) {
      await this.checkEmail(dto.email, id);
      data.email = dto.email || null;
    }
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
    // Svi agenti i podagenti; super agent vidi nadređenog, procenat od nadređenog i stvarni procenat rake-a.
    const agents = await this.prisma.user.findMany({
      where: { role: 'AGENT' },
      orderBy: { createdAt: 'desc' },
    });
    const players = await this.prisma.user.groupBy({ by: ['agentId'], where: { role: 'PLAYER' }, _count: true, _sum: { balance: true } });
    const rake = await this.prisma.rakeShare.groupBy({ by: ['agentId'], _sum: { amount: true, agentCut: true } });
    const fees = await this.prisma.feeShare.groupBy({ by: ['agentId'], _sum: { amount: true, agentCut: true } });
    const earned = await this.prisma.agentEarning.groupBy({ by: ['agentId'], _sum: { amount: true } });
    const byId = new Map(agents.map((a) => [a.id, a]));
    const effective = (a: (typeof agents)[number]) => {
      let eff = a.rakeShareBps / 10_000;
      let cur = a.agentId ? byId.get(a.agentId) : undefined;
      for (let d = 0; cur && d < 10; d++) {
        eff *= cur.rakeShareBps / 10_000;
        cur = cur.agentId ? byId.get(cur.agentId) : undefined;
      }
      return Math.round(eff * 10_000) / 100;
    };
    return agents.map((a) => {
      const r0 = rake.find((x) => x.agentId === a.id)?._sum;
      const f = fees.find((x) => x.agentId === a.id)?._sum;
      // Rake sa keš stolova i fee sa turnira njegovih (direktnih) igrača.
      const amount = (r0?.amount ?? 0) + (f?.amount ?? 0);
      const allAgents = (r0?.agentCut ?? 0) + (f?.agentCut ?? 0);
      const p = players.find((x) => x.agentId === a.id);
      return {
        ...publicUser(a),
        parentId: a.agentId,
        parentName: a.agentId ? (byId.get(a.agentId)?.displayName ?? null) : null,
        rakePercent: a.rakeShareBps / 100,
        effectivePercent: effective(a),
        subAgents: agents.filter((x) => x.agentId === a.id).length,
        totpEnabled: a.totpEnabled,
        players: p?._count ?? 0,
        playersBalance: p?._sum.balance ?? 0,
        playersRake: amount,
        agentCut: earned.find((x) => x.agentId === a.id)?._sum.amount ?? 0,
        superShare: amount - allAgents,
      };
    });
  }

  @Roles('ADMIN')
  @Post('agents')
  async createAgent(@Body() dto: CreateUserDto) {
    const agentCode = await this.checkAgentCode(dto.agentCode);
    const a = await this.createAccount(dto, 'AGENT', null);
    const u = await this.prisma.user.update({
      where: { id: a.id },
      data: { rakeShareBps: this.shareBps(dto.rakePercent), agentCode },
    });
    return publicUser(u);
  }

  /** Kod agenta koji upisuje super agent (npr. LIVERPOOL123): slova i brojevi, 3–20 znakova, jedinstven. */
  private async checkAgentCode(raw?: string, agentId?: string) {
    const code = (raw ?? '').trim().toUpperCase();
    if (!/^[A-Z0-9]{3,20}$/.test(code)) throw new BadRequestException('Kod agenta: 3–20 slova (bez kvačica) i brojeva, npr. LIVERPOOL123.');
    const other = await this.prisma.user.findUnique({ where: { agentCode: code } });
    if (other && other.id !== agentId) throw new ConflictException('Taj kod već koristi drugi agent.');
    return code;
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
    if (dto.agentCode !== undefined) data.agentCode = await this.checkAgentCode(dto.agentCode, id);
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
    await this.kickSubtree(id);
    return publicUser(u);
  }

  /** Blokada agenta važi i za njegove podagente i sve njihove igrače: izbacuju se sa stolova. */
  private async kickSubtree(id: string) {
    const subs = await subtreeAgentIds(this.prisma, id);
    for (const s of subs) await this.gateway.disconnectUser(s, 'Nalog trenutno nije aktivan.');
    const players = await this.prisma.user.findMany({ where: { role: 'PLAYER', agentId: { in: [id, ...subs] } }, select: { id: true } });
    for (const p of players) {
      await this.tables.removeEverywhere(p.id, 'Nalog trenutno nije aktivan.');
      await this.gateway.disconnectUser(p.id, 'Nalog trenutno nije aktivan. Javite se svom agentu.');
    }
  }

  @Roles('ADMIN')
  @Post('agents/:id/unblock')
  async unblockAgent(@Param('id') id: string) {
    const a = await this.prisma.user.findFirst({ where: { id, role: 'AGENT' } });
    if (!a) throw new NotFoundException('Agent nije pronađen.');
    return publicUser(await this.prisma.user.update({ where: { id }, data: { isBlocked: false, blockedReason: null } }));
  }

  // ---------- Podagenti (agent pravi svoje agente) ----------
  // Agent podagentu daje procenat od SVOG dela (super agent 70 % → agent daje podagentu 50 % → podagent 35 % rake-a).
  // Agent vidi samo procente koje on daje; procenat koji on ima kod svog nadređenog ne vidi nigde.

  private async mySub(actor: User, id: string) {
    const a = await this.prisma.user.findFirst({ where: { id, role: 'AGENT', agentId: actor.id } });
    if (!a) throw new NotFoundException('Agent nije pronađen.');
    return a;
  }

  @Roles('AGENT')
  @Get('subagents')
  async subAgents(@CurrentUser() actor: User) {
    const subs = await this.prisma.user.findMany({ where: { role: 'AGENT', agentId: actor.id }, orderBy: { createdAt: 'desc' } });
    const out = [];
    for (const a of subs) {
      const below = await subtreeAgentIds(this.prisma, a.id);
      const playerIds = (await this.prisma.user.findMany({ where: { role: 'PLAYER', agentId: { in: [a.id, ...below] } }, select: { id: true } })).map((x) => x.id);
      out.push({
        ...publicUser(a),
        rakePercent: a.rakeShareBps / 100,
        players: await this.prisma.user.count({ where: { role: 'PLAYER', agentId: a.id } }),
        subAgents: await this.prisma.user.count({ where: { role: 'AGENT', agentId: a.id } }),
        // Zarada podagenta (njegov deo) i moja zarada od igrača njegove mreže.
        theirEarning: await this.myEarning(a.id),
        myEarningFromThem: playerIds.length ? await this.myEarning(actor.id, undefined, playerIds) : 0,
      });
    }
    return out;
  }

  @Roles('AGENT')
  @Post('subagents')
  async createSubAgent(@CurrentUser() actor: User, @Body() dto: CreateUserDto) {
    // Najviše 10 nivoa ispod super agenta.
    let depth = 1;
    for (let cur = actor.agentId; cur && depth < 12; depth++) {
      cur = (await this.prisma.user.findUnique({ where: { id: cur }, select: { agentId: true } }))?.agentId ?? null;
    }
    if (depth >= 10) throw new BadRequestException('Dostignut je najveći broj nivoa agenata.');
    const agentCode = await this.checkAgentCode(dto.agentCode);
    const a = await this.createAccount(dto, 'AGENT', actor.id);
    const u = await this.prisma.user.update({ where: { id: a.id }, data: { rakeShareBps: this.shareBps(dto.rakePercent), agentCode } });
    return { ...publicUser(u), rakePercent: u.rakeShareBps / 100 };
  }

  @Roles('AGENT')
  @Patch('subagents/:id')
  async updateSubAgent(@CurrentUser() actor: User, @Param('id') id: string, @Body() dto: UpdateUserDto) {
    await this.mySub(actor, id);
    const data: Prisma.UserUpdateInput = {};
    if (dto.displayName !== undefined) data.displayName = dto.displayName;
    if (dto.note !== undefined) data.note = dto.note || null;
    if (dto.password) data.passwordHash = await bcrypt.hash(dto.password, 12);
    if (dto.rakePercent !== undefined) data.rakeShareBps = this.shareBps(dto.rakePercent);
    if (dto.agentCode !== undefined) data.agentCode = await this.checkAgentCode(dto.agentCode, id);
    const u = await this.prisma.user.update({ where: { id }, data });
    return { ...publicUser(u), rakePercent: u.rakeShareBps / 100 };
  }

  @Roles('AGENT')
  @Post('subagents/:id/block')
  async blockSubAgent(@CurrentUser() actor: User, @Param('id') id: string, @Body() dto: BlockDto) {
    await this.mySub(actor, id);
    const u = await this.prisma.user.update({ where: { id }, data: { isBlocked: true, blockedReason: dto.reason || null } });
    await this.gateway.disconnectUser(id, 'Nalog je blokiran.');
    await this.kickSubtree(id);
    return publicUser(u);
  }

  @Roles('AGENT')
  @Post('subagents/:id/unblock')
  async unblockSubAgent(@CurrentUser() actor: User, @Param('id') id: string) {
    await this.mySub(actor, id);
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
      ownerAgentId: t.ownerAgentId,
      private: !!t.ownerAgentId,
      createdAt: t.createdAt,
      live: this.tables.liveInfo(t.id),
    };
  }

  @Get('tables')
  async listTables(@CurrentUser() actor: User) {
    const items = await this.prisma.pokerTable.findMany({
      where: this.tableScope(actor, await this.ownersFor(actor)),
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
      return {
        ...this.tableView(t),
        rakeTotal: this.isSuper(actor) ? (r?._sum.rake ?? 0) : null,
        hands: r?._count ?? 0,
        canEdit: this.isSuper(actor) || t.ownerAgentId === actor.id,
      };
    });
  }

  @Post('tables')
  async createTable(@CurrentUser() actor: User, @Body() dto: TableDto) {
    // Agent pravi privatni sto: vide ga i igraju samo njegovi igrači i igrači njegovih podagenata.
    const t = await this.prisma.pokerTable.create({
      data: { ...this.validateTable(dto), createdById: actor.id, ownerAgentId: actor.role === 'ADMIN' ? null : actor.id },
      include: { createdBy: { select: { displayName: true } } },
    });
    await this.tables.open(t);
    this.announceTable(t);
    return this.tableView(t);
  }

  @Patch('tables/:id')
  async updateTable(@CurrentUser() actor: User, @Param('id') id: string, @Body() dto: TableDto) {
    await this.ownTable(actor, id);
    this.tables.assertClosed(id);
    const t = await this.prisma.pokerTable.update({
      where: { id },
      data: this.validateTable(dto),
      include: { createdBy: { select: { displayName: true } } },
    });
    return this.tableView(t);
  }

  @Post('tables/:id/close')
  async closeTable(@CurrentUser() actor: User, @Param('id') id: string) {
    await this.ownTable(actor, id);
    await this.prisma.pokerTable.update({ where: { id }, data: { isOpen: false, closedAt: new Date() } });
    await this.tables.close(id);
    return { ok: true };
  }

  @Post('tables/:id/open')
  async openTable(@CurrentUser() actor: User, @Param('id') id: string) {
    await this.ownTable(actor, id);
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
    // Super agent gleda i stolove turnira (oni se ne vide na stranici Stolovi).
    const t = await this.prisma.pokerTable.findUnique({ where: { id }, include: { createdBy: { select: { displayName: true } } } });
    if (!t) throw new NotFoundException('Sto nije pronađen.');
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
