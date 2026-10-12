import 'reflect-metadata';
import { BadRequestException, Logger, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { NestExpressApplication } from '@nestjs/platform-express';
import * as path from 'path';
import * as fs from 'fs';
import type { NextFunction, Request, Response } from 'express';
import { AppModule } from './app.module';
import { ensureAdmin } from './seed-admin';
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
  const app = await NestFactory.create<NestExpressApplication>(AppModule);
  app.enableCors();
  app.enableShutdownHooks();
  app.setGlobalPrefix('api');
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
  const port = Number(process.env.PORT || 3000);
  await app.listen(port, '0.0.0.0');
  Logger.log(`Poker server radi na portu ${port}`, 'Bootstrap');
}
void bootstrap();
