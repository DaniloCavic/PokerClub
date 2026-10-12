import { ExecutionContext, Injectable, Module } from '@nestjs/common';
import { APP_GUARD } from '@nestjs/core';
import { JwtModule } from '@nestjs/jwt';
import { ThrottlerGuard, ThrottlerModule } from '@nestjs/throttler';
import { PrismaModule } from './prisma/prisma.service';
import { AuthGuard } from './common/auth.guard';
import { AuthController, MeController } from './auth/auth.controller';
import { AdminController } from './admin/admin.controller';
import { WalletService } from './wallet/wallet.service';
import { TablesService } from './tables/tables.service';
import { TablesGateway } from './tables/tables.gateway';
import { HealthController } from './health.controller';

/** Ograničenje broja zahteva važi samo za HTTP (ne za Socket.IO). */
@Injectable()
class HttpThrottlerGuard extends ThrottlerGuard {
  canActivate(ctx: ExecutionContext) {
    return ctx.getType() === 'http' ? super.canActivate(ctx) : Promise.resolve(true);
  }
}

@Module({
  imports: [
    PrismaModule,
    ThrottlerModule.forRoot([{ ttl: 60_000, limit: 300 }]),
    JwtModule.register({
      global: true,
      secret: process.env.JWT_SECRET,
      signOptions: { expiresIn: (process.env.JWT_EXPIRES_IN || '30d') as never },
    }),
  ],
  controllers: [HealthController, AuthController, MeController, AdminController],
  providers: [
    AuthGuard,
    { provide: APP_GUARD, useClass: HttpThrottlerGuard },
    { provide: APP_GUARD, useExisting: AuthGuard },
    WalletService,
    TablesService,
    TablesGateway,
  ],
})
export class AppModule {}
