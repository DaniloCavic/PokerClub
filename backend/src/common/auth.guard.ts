import {
  CanActivate,
  createParamDecorator,
  ExecutionContext,
  ForbiddenException,
  Injectable,
  SetMetadata,
  UnauthorizedException,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { JwtService } from '@nestjs/jwt';
import { Role, User } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

export const IS_PUBLIC = 'isPublic';
export const Public = () => SetMetadata(IS_PUBLIC, true);
export const ROLES = 'roles';
/** Ko sme da pozove rutu. Bez ove oznake — svaki prijavljen korisnik. */
export const Roles = (...roles: Role[]) => SetMetadata(ROLES, roles);
/** Agent ili administrator (admin panel). */
export const Staff = () => Roles('AGENT', 'ADMIN');

export interface JwtPayload {
  sub: string;
  role: Role;
}

export const CurrentUser = createParamDecorator((_: unknown, ctx: ExecutionContext): User => {
  return ctx.switchToHttp().getRequest().user;
});

export function blockedMessage(user: Pick<User, 'blockedReason'>) {
  return user.blockedReason ? `Nalog je blokiran: ${user.blockedReason}` : 'Nalog je blokiran.';
}

/**
 * Globalni guard: svaki zahtev mora imati važeći token osim onih označenih sa @Public().
 * Korisnik se učitava iz baze pri svakom zahtevu, pa blokada važi odmah.
 */
@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly jwt: JwtService,
    private readonly prisma: PrismaService,
  ) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    // Socket.IO konekcije proverava TablesGateway pri povezivanju.
    if (ctx.getType() !== 'http') return true;
    const targets = [ctx.getHandler(), ctx.getClass()];
    if (this.reflector.getAllAndOverride<boolean>(IS_PUBLIC, targets)) return true;

    const req = ctx.switchToHttp().getRequest();
    const header: string | undefined = req.headers['authorization'];
    const token = header?.startsWith('Bearer ') ? header.slice(7) : undefined;
    if (!token) throw new UnauthorizedException('Niste prijavljeni.');
    const user = await this.userFromToken(token);
    req.user = user;

    const roles = this.reflector.getAllAndOverride<Role[] | undefined>(ROLES, targets);
    if (roles && !roles.includes(user.role)) throw new ForbiddenException('Nemate prava za ovu radnju.');
    return true;
  }

  async userFromToken(token: string): Promise<User> {
    let payload: JwtPayload;
    try {
      payload = await this.jwt.verifyAsync<JwtPayload>(token);
    } catch {
      throw new UnauthorizedException('Sesija je istekla. Prijavite se ponovo.');
    }
    const user = await this.prisma.user.findUnique({ where: { id: payload.sub } });
    if (!user) throw new UnauthorizedException('Nalog ne postoji.');
    if (user.isBlocked) throw new ForbiddenException(blockedMessage(user));
    // Blokiran agent blokira i pristup njegovim igračima.
    if (user.agentId) {
      const agent = await this.prisma.user.findUnique({ where: { id: user.agentId }, select: { isBlocked: true } });
      if (agent?.isBlocked) throw new ForbiddenException('Nalog trenutno nije aktivan. Javite se svom agentu.');
    }
    return user;
  }
}
