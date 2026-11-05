import { Controller, Get } from '@nestjs/common';
import { Public } from './common/auth.guard';

@Controller()
export class HealthController {
  @Public()
  @Get('health')
  health() {
    // Railway upisuje commit koji je postavljen — da se vidi koja verzija radi.
    const version = process.env.RAILWAY_GIT_COMMIT_SHA?.slice(0, 7) ?? 'lokalno';
    return { ok: true, version, time: new Date().toISOString() };
  }
}
