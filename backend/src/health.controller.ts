import { Controller, Get } from '@nestjs/common';
import { Public } from './common/auth.guard';

@Controller()
export class HealthController {
  @Public()
  @Get('health')
  health() {
    return { ok: true, time: new Date().toISOString() };
  }
}
