import 'reflect-metadata';
import { BadRequestException, Logger, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import * as path from 'path';
import * as fs from 'fs';
import type { NextFunction, Request, Response } from 'express';
import { AppModule } from './app.module';
import { allowedOrigins } from './common/origins';
import { LangExceptionFilter } from './common/lang.filter';
import { ensureAdmin } from './seed-admin';
import { ensureAgentCodes } from './common/agent-code';
import { PrismaService } from './prisma/prisma.service';

/** Servira izgrađenu web aplikaciju na `prefix`; rute bez ekstenzije vraćaju index.html. */
function serveSpa(app: NestExpressApplication, dir: string, prefix: string) {
  if (!fs.existsSync(dir)) return;
  const re = new RegExp(`^${prefix}(/|$)`);
  app.use((req: Request, res: Response, next: NextFunction) => {
    if (req.method === 'GET' && req.path === prefix) return res.redirect(`${prefix}/`);
    if (req.method === 'GET' && re.test(req.path) && !path.extname(req.path)) {
      return res.sendFile(path.join(dir, 'index.html'));
    }
    next();
  });
  app.useStaticAssets(dir, { prefix });
}

async function bootstrap() {
  if (!process.env.JWT_SECRET) throw new Error('JWT_SECRET nije podešen.');
  if (process.env.JWT_SECRET.length < 32) Logger.warn('JWT_SECRET je kratak: postavite nasumičan niz od bar 32 znaka.', 'Bezbednost');
  const app = await NestFactory.create<NestExpressApplication>(AppModule);
  // Zahtevi samo sa adrese aplikacije (ALLOWED_ORIGINS ili javna adresa na Railway-u).
  app.enableCors({ origin: allowedOrigins() ?? true });
  app.getHttpAdapter().getInstance().disable('x-powered-by');
  // Sigurnosna zaglavlja: zabrana ugrađivanja u tuđe sajtove, samo HTTPS, bez otkrivanja tipa.
  app.use((_req: Request, res: Response, next: NextFunction) => {
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    res.setHeader('Permissions-Policy', 'geolocation=(), microphone=(), camera=(self)');
    if (process.env.RAILWAY_PUBLIC_DOMAIN || process.env.PUBLIC_DOMAIN) res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    next();
  });
  app.enableShutdownHooks();
  app.useBodyParser('json', { limit: '1mb' });
  app.setGlobalPrefix('api');
  app.useGlobalFilters(new LangExceptionFilter(app.getHttpAdapter()));
  app.useGlobalPipes(
    new ValidationPipe({
      whitelist: true,
      transform: true,
      // Prva poruka greške na srpskom, da je aplikacija može prikazati direktno.
      exceptionFactory: (errors) => {
        const first = errors[0];
        const msg = first?.constraints ? Object.values(first.constraints)[0] : 'Neispravni podaci.';
        return new BadRequestException(msg);
      },
    }),
  );

  // Admin panel za agente (React) na /admin i aplikacija za igrače (Flutter web) na /igra.
  serveSpa(app, path.resolve(process.env.ADMIN_DIST || path.join(__dirname, '..', '..', 'admin', 'dist')), '/admin');
  const webDist = path.resolve(process.env.WEB_DIST || path.join(__dirname, '..', '..', 'web'));
  if (fs.existsSync(webDist)) {
    app.use((req: Request, res: Response, next: NextFunction) => {
      if (req.method === 'GET' && req.path === '/') return res.redirect('/igra/');
      next();
    });
    serveSpa(app, webDist, '/igra');
  }

  await ensureAdmin(app.get(PrismaService));
  await ensureAgentCodes(app.get(PrismaService));
  const port = Number(process.env.PORT || 3000);
  await app.listen(port, '0.0.0.0');
  Logger.log(`Poker server radi na portu ${port}`, 'Bootstrap');
}
void bootstrap();
