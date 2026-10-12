import { BadRequestException, Body, Controller, ForbiddenException, Get, Post, Query, UnauthorizedException } from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';
import { Throttle } from '@nestjs/throttler';
import { User } from '@prisma/client';
import * as bcrypt from 'bcryptjs';
import { blockedMessage, CurrentUser, Public } from '../common/auth.guard';
import { publicUser } from '../common/public-user';
import { PrismaService } from '../prisma/prisma.service';
import { TablesService } from '../tables/tables.service';
import { ChangePasswordDto, LoginDto } from './dto';

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

  @Get('transactions')
  async transactions(@CurrentUser() user: User, @Query('page') page = '1') {
    const p = Math.max(1, Number(page) || 1);
    const [items, total] = await Promise.all([
      this.prisma.transaction.findMany({
        where: { userId: user.id },
        orderBy: { createdAt: 'desc' },
        skip: (p - 1) * 30,
        take: 30,
        select: { id: true, type: true, amount: true, balanceAfter: true, note: true, createdAt: true },
      }),
      this.prisma.transaction.count({ where: { userId: user.id } }),
    ]);
    return { items, total, page: p, pageSize: 30 };
  }

  @Get('tables')
  lobby() {
    return this.tables.lobby();
  }
}
