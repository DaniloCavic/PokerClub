import { BadRequestException, Body, ConflictException, Req, Controller, Delete, ForbiddenException, Get, Headers, NotFoundException, Param, Post, Query, Res, UnauthorizedException } from '@nestjs/common';
import type { Request, Response } from 'express';
import { JwtService } from '@nestjs/jwt';
import { Throttle } from '@nestjs/throttler';
import { TxType, User } from '@prisma/client';
import * as bcrypt from 'bcryptjs';
import { blockedMessage, CurrentUser, Public } from '../common/auth.guard';
import { avatarUrl, publicUser } from '../common/public-user';
import { PrismaService } from '../prisma/prisma.service';
import { normLang, tr, userLang } from '../common/i18n';
import { playerStats } from '../tables/player-stats';
import { TablesService } from '../tables/tables.service';
import { AvatarDto, ChangePasswordDto, EmailDto, ForgotDto, LoginDto, NoteDto, RegisterDto, ResetDto } from './dto';
import { sendMail } from '../common/mail';
import { verifyTotp } from '../common/totp';
import { clientIp, signToken } from '../common/auth.guard';

@Controller('auth')
export class AuthController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
  ) {}

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('login')
  async login(@Body() dto: LoginDto, @Req() req: Request) {
    const ip = clientIp(req);
    const agent = String(req.headers['user-agent'] ?? '').slice(0, 200);
    // Prijava korisničkim imenom ili e-poštom.
    const login = dto.username.toLowerCase();
    const user = login.includes('@')
      ? await this.prisma.user.findUnique({ where: { email: login } })
      : await this.prisma.user.findUnique({ where: { usernameLower: login } });
    const staff = !!user && user.role !== 'PLAYER';
    const log = (ok: boolean, reason?: string) =>
      this.prisma.loginLog.create({ data: { userId: user?.id ?? null, login: login.slice(0, 120), ok, reason, ip, agent, staff } }).catch(() => undefined);
    // Zaključan nalog posle više pogrešnih lozinki.
    if (user?.lockedUntil && user.lockedUntil > new Date()) {
      await log(false, 'zaključan');
      const min = Math.ceil((user.lockedUntil.getTime() - Date.now()) / 60_000);
      throw new ForbiddenException(`Previše pogrešnih pokušaja. Pokušajte ponovo za ${min} min.`);
    }
    // Ista poruka za nepostojeći nalog i pogrešnu lozinku.
    if (!user || !(await bcrypt.compare(dto.password, user.passwordHash))) {
      if (user) {
        const failed = user.failedLogins + 1;
        // Posle 5 pogrešnih: 15 min zaključano (super agent i agenti: posle 5, isto, ali se upisuje upozorenje).
        await this.prisma.user.update({
          where: { id: user.id },
          data: failed >= 5 ? { failedLogins: 0, lockedUntil: new Date(Date.now() + 15 * 60_000) } : { failedLogins: failed },
        });
        if (failed >= 5 && staff) {
          await this.prisma.securityAlert.create({
            data: { kind: 'STAFF_LOCKED', userIds: [user.id], names: user.displayName, detail: `5 pogrešnih lozinki, IP ${ip}. Nalog zaključan 15 min.` },
          });
        }
      }
      await log(false, 'pogrešna lozinka');
      throw new UnauthorizedException('Pogrešno korisničko ime ili lozinka.');
    }
    // Dvostepena prijava: posle lozinke i kod iz aplikacije za autentifikaciju.
    if (user.totpEnabled && user.totpSecret) {
      if (!dto.totp) throw new UnauthorizedException('TOTP_REQUIRED');
      if (!verifyTotp(user.totpSecret, dto.totp)) {
        await this.prisma.user.update({ where: { id: user.id }, data: { failedLogins: { increment: 1 } } });
        await log(false, 'pogrešan 2FA kod');
        throw new UnauthorizedException('Kod za dvostepenu prijavu nije tačan.');
      }
    }
    if (user.isBlocked) throw new ForbiddenException(blockedMessage(user));
    if (user.agentId) {
      const ag = await this.prisma.user.findUnique({ where: { id: user.agentId }, select: { isBlocked: true } });
      if (ag?.isBlocked) throw new ForbiddenException('Nalog trenutno nije aktivan. Javite se svom agentu.');
    }
    // Super agent / agent sa nove IP adrese: upozorenje u Bezbednosti.
    if (staff) {
      const seen = await this.prisma.loginLog.findFirst({ where: { userId: user.id, ok: true, ip } });
      const any = await this.prisma.loginLog.findFirst({ where: { userId: user.id, ok: true } });
      if (any && !seen) {
        await this.prisma.securityAlert.create({
          data: { kind: 'STAFF_NEW_IP', userIds: [user.id], names: user.displayName, detail: `Prijava sa nove IP adrese ${ip} (${agent.slice(0, 80)})` },
        });
      }
    }
    await log(true);
    const fresh = await this.prisma.user.update({ where: { id: user.id }, data: { lastSeenAt: new Date(), failedLogins: 0, lockedUntil: null } });
    return { accessToken: await signToken(this.jwt, fresh), user: publicUser(fresh) };
  }

  /**
   * Igrač sam pravi nalog: e-pošta, korisničko ime (ono je i ime za stolom) i lozinka.
   * Sa kodom agenta pripada tom agentu; bez koda ostaje bez agenta, a super agent ga kasnije dodeljuje.
   */
  @Public()
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('register')
  async register(@Body() dto: RegisterDto) {
    const email = dto.email.toLowerCase();
    if (await this.prisma.user.findUnique({ where: { usernameLower: dto.username.toLowerCase() } })) {
      throw new ConflictException('Korisničko ime je zauzeto.');
    }
    if (await this.prisma.user.findUnique({ where: { email } })) throw new ConflictException('Nalog sa ovom e-poštom već postoji.');
    let agentId: string | null = null;
    const code = dto.agentCode?.trim().toUpperCase();
    if (code) {
      const agent = await this.prisma.user.findUnique({ where: { agentCode: code } });
      if (!agent || agent.role !== 'AGENT') throw new BadRequestException('Kod agenta ne postoji.');
      if (agent.isBlocked) throw new BadRequestException('Agent sa ovim kodom trenutno nije aktivan.');
      agentId = agent.id;
    }
    const user = await this.prisma.user.create({
      data: {
        username: dto.username,
        usernameLower: dto.username.toLowerCase(),
        displayName: dto.username,
        email,
        passwordHash: await bcrypt.hash(dto.password, 12),
        role: 'PLAYER',
        agentId,
        lastSeenAt: new Date(),
      },
    });
    return { accessToken: await signToken(this.jwt, user), user: publicUser(user) };
  }

  /** Zaboravljena lozinka: na e-poštu stiže kod od 6 cifara (važi 15 minuta). */
  @Public()
  @Throttle({ default: { limit: 5, ttl: 60_000 } })
  @Post('forgot')
  async forgot(@Body() dto: ForgotDto, @Headers('x-lang') lang?: string) {
    const user = await this.prisma.user.findUnique({ where: { email: dto.email.toLowerCase() } });
    // Isti odgovor i kad nalog ne postoji (da se ne otkriva čija je e-pošta).
    if (user && !user.isBlocked) {
      const code = String(Math.floor(100000 + Math.random() * 900000));
      await this.prisma.user.update({
        where: { id: user.id },
        data: { resetCodeHash: await bcrypt.hash(code, 10), resetExpires: new Date(Date.now() + 15 * 60_000), resetTries: 0 },
      });
      const sr = (lang ?? user.lang) === 'sr';
      // Šalje se u pozadini (igrač ne čeka); greška se upisuje u log servera.
      void sendMail(
        user.email!,
        sr ? 'Poker klub Triling — nova lozinka' : 'Poker klub Triling — reset your password',
        sr
          ? `Zdravo ${user.displayName},\n\nVaš kod za novu lozinku je: ${code}\n\nKod važi 15 minuta. Ako niste tražili novu lozinku, zanemarite ovu poruku.`
          : `Hi ${user.displayName},\n\nYour password reset code is: ${code}\n\nThe code is valid for 15 minutes. If you did not ask for a new password, ignore this email.`,
      ).catch(() => undefined);
    }
    return { ok: true };
  }

  /** Nova lozinka uz kod iz e-pošte (najviše 5 pokušaja po kodu). */
  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('reset')
  async reset(@Body() dto: ResetDto) {
    const user = await this.prisma.user.findUnique({ where: { email: dto.email.toLowerCase() } });
    const bad = () => new BadRequestException('Kod nije tačan ili je istekao.');
    if (!user?.resetCodeHash || !user.resetExpires || user.resetExpires < new Date() || user.resetTries >= 5) throw bad();
    if (!(await bcrypt.compare(dto.code, user.resetCodeHash))) {
      await this.prisma.user.update({ where: { id: user.id }, data: { resetTries: { increment: 1 } } });
      throw bad();
    }
    if (user.isBlocked) throw new ForbiddenException(blockedMessage(user));
    const fresh = await this.prisma.user.update({
      where: { id: user.id },
      data: { passwordHash: await bcrypt.hash(dto.password, 12), resetCodeHash: null, resetExpires: null, resetTries: 0, lastSeenAt: new Date(), failedLogins: 0, lockedUntil: null, tokenVersion: { increment: 1 } },
    });
    return { accessToken: await signToken(this.jwt, fresh), user: publicUser(fresh) };
  }
}

@Controller('me')
export class MeController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly tables: TablesService,
    private readonly jwt: JwtService,
  ) {}

  /** Odjava sa svih uređaja: sve postojeće prijave prestaju da važe; ovaj uređaj dobija novu. */
  @Post('logout-all')
  async logoutAll(@CurrentUser() user: User) {
    const fresh = await this.prisma.user.update({ where: { id: user.id }, data: { tokenVersion: { increment: 1 } } });
    return { ok: true, accessToken: await signToken(this.jwt, fresh) };
  }

  @Get()
  async me(@CurrentUser() user: User) {
    const agent = user.agentId
      ? await this.prisma.user.findUnique({ where: { id: user.agentId }, select: { displayName: true } })
      : null;
    return { ...publicUser(user), agentName: agent?.displayName ?? null, seatedAt: this.tables.seatsOf(user.id) };
  }

  /** Poruka dobrodošlice i pravila kluba, ako ih igrač još nije video (ili su promenjena posle toga). */
  @Get('welcome')
  async welcome(@CurrentUser() user: User) {
    const rows = await this.prisma.appSetting.findMany({ where: { key: { in: ['welcomeEn', 'welcomeSr', 'welcomeAt'] } } });
    const v = (k: string) => rows.find((r) => r.key === k)?.value ?? '';
    const at = v('welcomeAt') ? new Date(v('welcomeAt')) : null;
    if (!at || (!v('welcomeEn') && !v('welcomeSr'))) return { show: false };
    const show = !user.welcomeSeenAt || user.welcomeSeenAt < at;
    return { show, en: v('welcomeEn') || v('welcomeSr'), sr: v('welcomeSr') || v('welcomeEn') };
  }

  @Post('welcome/seen')
  async welcomeSeen(@CurrentUser() user: User) {
    await this.prisma.user.update({ where: { id: user.id }, data: { welcomeSeenAt: new Date() } });
    return { ok: true };
  }

  /** E-pošta za prijavu i povraćaj lozinke (igrači koje je napravio agent mogu je dodati). */
  @Post('email')
  async setEmail(@CurrentUser() user: User, @Body() dto: EmailDto) {
    const email = dto.email.toLowerCase();
    const other = await this.prisma.user.findUnique({ where: { email } });
    if (other && other.id !== user.id) throw new ConflictException('Nalog sa ovom e-poštom već postoji.');
    return publicUser(await this.prisma.user.update({ where: { id: user.id }, data: { email } }));
  }

  /** Jezik aplikacije (en / sr): poruke i obaveštenja na telefonu stižu na tom jeziku. */
  @Post('lang')
  async setLang(@CurrentUser() user: User, @Body() body: { lang?: string }) {
    const lang = normLang(body?.lang);
    await this.prisma.user.update({ where: { id: user.id }, data: { lang } });
    userLang.set(user.id, lang);
    return { lang };
  }

  @Post('password')
  async changePassword(@CurrentUser() user: User, @Body() dto: ChangePasswordDto) {
    if (!(await bcrypt.compare(dto.oldPassword, user.passwordHash))) throw new BadRequestException('Stara lozinka nije tačna.');
    // Nova lozinka: sve ostale prijave (drugi uređaji) prestaju da važe; ovaj uređaj dobija novu prijavu.
    const fresh = await this.prisma.user.update({
      where: { id: user.id },
      data: { passwordHash: await bcrypt.hash(dto.newPassword, 12), tokenVersion: { increment: 1 } },
    });
    return { ok: true, accessToken: await signToken(this.jwt, fresh) };
  }

  /** Nova slika profila (base64). Aplikacija je pre slanja smanji na ~256 px. */
  @Post('avatar')
  async setAvatar(@CurrentUser() user: User, @Body() dto: AvatarDto) {
    const data = Buffer.from(dto.data, 'base64');
    if (data.length < 100 || data.length > 300_000) throw new BadRequestException('Slika je prevelika (najviše 300 KB).');
    const isJpeg = data[0] === 0xff && data[1] === 0xd8;
    const isPng = data.subarray(1, 4).toString() === 'PNG';
    const isWebp = data.subarray(8, 12).toString() === 'WEBP';
    if (!isJpeg && !isPng && !isWebp) throw new BadRequestException('Podržane su samo JPG, PNG i WebP slike.');
    const fresh = await this.prisma.user.update({
      where: { id: user.id },
      data: { avatar: data, avatarType: isJpeg ? 'image/jpeg' : isPng ? 'image/png' : 'image/webp', avatarAt: new Date() },
    });
    this.tables.avatarChanged(user.id, avatarUrl(fresh));
    return publicUser(fresh);
  }

  @Delete('avatar')
  async removeAvatar(@CurrentUser() user: User) {
    const fresh = await this.prisma.user.update({ where: { id: user.id }, data: { avatar: null, avatarType: null, avatarAt: null } });
    this.tables.avatarChanged(user.id, null);
    return publicUser(fresh);
  }

  @Get('transactions')
  async transactions(@CurrentUser() user: User, @Query('page') page = '1', @Query('type') type?: string, @Headers('x-lang') lang?: string) {
    const p = Math.max(1, Number(page) || 1);
    // Filter: uplate/isplate kod agenta ili ulazi/izlazi sa stolova.
    const types: Record<string, TxType[]> = {
      money: ['DEPOSIT', 'WITHDRAWAL'],
      tables: ['BUY_IN', 'CASH_OUT', 'TOURNAMENT_BUY_IN', 'TOURNAMENT_PRIZE', 'TOURNAMENT_REFUND'],
    };
    const where = { userId: user.id, ...(type && types[type] ? { type: { in: types[type] } } : {}) };
    const [items, total] = await Promise.all([
      this.prisma.transaction.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: (p - 1) * 30,
        take: 30,
        select: { id: true, type: true, amount: true, balanceAfter: true, note: true, createdAt: true },
      }),
      this.prisma.transaction.count({ where }),
    ]);
    // Beleške (npr. „Ulaz: Nedeljni turnir“) na jeziku aplikacije.
    return { items: items.map((t) => ({ ...t, note: t.note ? tr(t.note, lang ?? 'sr') : t.note })), total, page: p, pageSize: 30 };
  }

  /**
   * Istorija ruku koje je igrač odigrao (najnovije prve).
   * Tuđe karte se vide samo ako su otvorene na kraju ruke.
   */
  @Get('hands')
  async hands(@CurrentUser() user: User, @Query('tableId') tableId?: string, @Query('page') page = '1', @Query('id') id?: string) {
    const p = Math.max(1, Number(page) || 1);
    // id: jedna ruka (npr. najbolja ruka iz sažetka turnira).
    const where = { playerIds: { has: user.id }, ...(tableId ? { tableId } : {}), ...(id ? { id } : {}) };
    const [hands, total] = await Promise.all([
      this.prisma.hand.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: (p - 1) * 20,
        take: 20,
        include: { table: { select: { name: true, variant: true, smallBlind: true, bigBlind: true, maxSeats: true } } },
      }),
      this.prisma.hand.count({ where }),
    ]);
    return {
      total,
      page: p,
      pageSize: 20,
      items: hands.map((h) => {
        const d = h.details as {
          players: { seat: number; userId: string; name: string; startStack: number; endStack: number; cards: string }[];
          pots: unknown[];
          shown: { seat: number; cards: string[]; best: string[]; handName: string }[];
          actions?: unknown[];
        };
        const shown = new Set((d.shown ?? []).map((x) => x.seat));
        return {
          id: h.id,
          handNo: h.handNo,
          createdAt: h.createdAt,
          table: h.table,
          board: h.board ? h.board.split(' ') : [],
          pot: h.pot,
          pots: d.pots,
          // Karte otvorene na kraju ruke (za replay).
          shown: d.shown ?? [],
          actions: d.actions ?? [],
          players: d.players.map((pl) => ({
            seat: pl.seat,
            name: pl.name,
            isMe: pl.userId === user.id,
            startStack: pl.startStack,
            endStack: pl.endStack,
            cards: pl.userId === user.id || shown.has(pl.seat) ? pl.cards.split(' ') : null,
          })),
        };
      }),
    };
  }

  @Get('tables')
  lobby() {
    return this.tables.lobby();
  }

  /**
   * Statistika igrača za jednim stolom (prozor kad se za stolom dodirne igrač):
   * VPIP, PFR, dobijene ruke, najveći osvojen pot i najbolja pokazana ruka.
   */
  @Get('table-stats')
  async tableStats(@Query('tableId') tableId: string, @Query('userId') userId: string, @Query('scope') scope?: string) {
    if (!userId) throw new BadRequestException('Nedostaje igrač.');
    // Sve igre: poslednjih 2000 ruku igrača sa svih stolova (kao profil na GG).
    if (scope === 'all') {
      const rows = await this.prisma.hand.findMany({
        where: { playerIds: { has: userId } },
        orderBy: { createdAt: 'desc' },
        take: 2000,
        select: { board: true, details: true, table: { select: { variant: true, tournamentId: true } } },
      });
      const hands = rows.map((h) => ({ board: h.board, details: h.details, variant: h.table.variant, cash: !h.table.tournamentId }));
      return playerStats(userId, hands, 'HOLDEM');
    }
    if (!tableId) throw new BadRequestException('Nedostaje sto.');
    const table = await this.prisma.pokerTable.findUnique({ where: { id: tableId }, select: { variant: true, tournamentId: true } });
    if (!table) throw new NotFoundException('Sto nije pronađen.');
    const hands = await this.prisma.hand.findMany({
      where: { tableId, playerIds: { has: userId } },
      orderBy: { createdAt: 'desc' },
      take: 1000,
      select: { board: true, details: true },
    });
    return playerStats(userId, hands.map((h) => ({ ...h, cash: !table.tournamentId })), table.variant);
  }

  /** Beleške o drugim igračima (vidi ih samo onaj ko ih je napisao). */
  @Get('notes')
  async notes(@CurrentUser() user: User) {
    const rows = await this.prisma.playerNote.findMany({ where: { ownerId: user.id } });
    return Object.fromEntries(rows.filter((r) => r.text).map((r) => [r.targetId, r.text]));
  }

  /** Oznake u boji za igrače (kao na GG): igrač → boja (#RRGGBB). */
  @Get('note-colors')
  async noteColors(@CurrentUser() user: User) {
    const rows = await this.prisma.playerNote.findMany({ where: { ownerId: user.id, color: { not: null } } });
    return Object.fromEntries(rows.map((r) => [r.targetId, r.color]));
  }

  @Post('notes/:targetId')
  async setNote(@CurrentUser() user: User, @Param('targetId') targetId: string, @Body() dto: NoteDto) {
    if (targetId === user.id) throw new BadRequestException('Ne možete pisati belešku o sebi.');
    const target = await this.prisma.user.findUnique({ where: { id: targetId }, select: { id: true } });
    if (!target) throw new NotFoundException('Igrač nije pronađen.');
    const text = dto.text.trim();
    const key = { ownerId_targetId: { ownerId: user.id, targetId } };
    // Boja: ako nije poslata, ostaje stara; prazna boja briše oznaku.
    const old = await this.prisma.playerNote.findUnique({ where: key });
    const color = dto.color === undefined ? (old?.color ?? null) : dto.color || null;
    if (!text && !color) {
      await this.prisma.playerNote.deleteMany({ where: { ownerId: user.id, targetId } });
    } else {
      await this.prisma.playerNote.upsert({ where: key, create: { ownerId: user.id, targetId, text, color }, update: { text, color } });
    }
    return { text, color };
  }
}

@Controller('avatars')
export class AvatarsController {
  constructor(private readonly prisma: PrismaService) {}

  @Public()
  @Get(':id')
  async avatar(@Param('id') id: string, @Res() res: Response) {
    const u = await this.prisma.user.findUnique({ where: { id }, select: { avatar: true, avatarType: true } });
    if (!u?.avatar) throw new NotFoundException();
    res.set('Content-Type', u.avatarType ?? 'image/jpeg');
    res.set('Cache-Control', 'public, max-age=31536000, immutable');
    res.send(Buffer.from(u.avatar));
  }
}
