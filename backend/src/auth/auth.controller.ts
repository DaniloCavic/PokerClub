import { BadRequestException, Body, Controller, Delete, ForbiddenException, Get, NotFoundException, Param, Post, Query, Res, UnauthorizedException } from '@nestjs/common';
import type { Response } from 'express';
import { JwtService } from '@nestjs/jwt';
import { Throttle } from '@nestjs/throttler';
import { TxType, User } from '@prisma/client';
import * as bcrypt from 'bcryptjs';
import { blockedMessage, CurrentUser, Public } from '../common/auth.guard';
import { avatarUrl, publicUser } from '../common/public-user';
import { PrismaService } from '../prisma/prisma.service';
import { TablesService } from '../tables/tables.service';
import { AvatarDto, ChangePasswordDto, LoginDto } from './dto';

@Controller('auth')
export class AuthController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly jwt: JwtService,
  ) {}

  @Public()
  @Throttle({ default: { limit: 10, ttl: 60_000 } })
  @Post('login')
  async login(@Body() dto: LoginDto) {
    const user = await this.prisma.user.findUnique({ where: { usernameLower: dto.username.toLowerCase() } });
    // Ista poruka za nepostojeći nalog i pogrešnu lozinku.
    if (!user || !(await bcrypt.compare(dto.password, user.passwordHash))) {
      throw new UnauthorizedException('Pogrešno korisničko ime ili lozinka.');
    }
    if (user.isBlocked) throw new ForbiddenException(blockedMessage(user));
    if (user.agentId) {
      const agent = await this.prisma.user.findUnique({ where: { id: user.agentId }, select: { isBlocked: true } });
      if (agent?.isBlocked) throw new ForbiddenException('Nalog trenutno nije aktivan. Javite se svom agentu.');
    }
    const fresh = await this.prisma.user.update({ where: { id: user.id }, data: { lastSeenAt: new Date() } });
    const accessToken = await this.jwt.signAsync({ sub: user.id, role: user.role });
    return { accessToken, user: publicUser(fresh) };
  }
}

@Controller('me')
export class MeController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly tables: TablesService,
  ) {}

  @Get()
  async me(@CurrentUser() user: User) {
    const agent = user.agentId
      ? await this.prisma.user.findUnique({ where: { id: user.agentId }, select: { displayName: true } })
      : null;
    return { ...publicUser(user), agentName: agent?.displayName ?? null, seatedAt: this.tables.seatsOf(user.id) };
  }

  @Post('password')
  async changePassword(@CurrentUser() user: User, @Body() dto: ChangePasswordDto) {
    if (!(await bcrypt.compare(dto.oldPassword, user.passwordHash))) throw new BadRequestException('Stara lozinka nije tačna.');
    await this.prisma.user.update({ where: { id: user.id }, data: { passwordHash: await bcrypt.hash(dto.newPassword, 12) } });
    return { ok: true };
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
  async transactions(@CurrentUser() user: User, @Query('page') page = '1', @Query('type') type?: string) {
    const p = Math.max(1, Number(page) || 1);
    // Filter: uplate/isplate kod agenta ili ulazi/izlazi sa stolova.
    const types: Record<string, TxType[]> = { money: ['DEPOSIT', 'WITHDRAWAL'], tables: ['BUY_IN', 'CASH_OUT'] };
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
    return { items, total, page: p, pageSize: 30 };
  }

  /**
   * Istorija ruku koje je igrač odigrao (najnovije prve).
   * Tuđe karte se vide samo ako su otvorene na kraju ruke.
   */
  @Get('hands')
  async hands(@CurrentUser() user: User, @Query('tableId') tableId?: string, @Query('page') page = '1') {
    const p = Math.max(1, Number(page) || 1);
    const where = { playerIds: { has: user.id }, ...(tableId ? { tableId } : {}) };
    const [hands, total] = await Promise.all([
      this.prisma.hand.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: (p - 1) * 20,
        take: 20,
        include: { table: { select: { name: true, variant: true, smallBlind: true, bigBlind: true } } },
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
          shown: { seat: number }[];
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
