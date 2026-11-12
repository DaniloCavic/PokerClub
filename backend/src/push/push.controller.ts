import { BadRequestException, Body, Controller, Get, Post } from '@nestjs/common';
import { User } from '@prisma/client';
import { CurrentUser, Public } from '../common/auth.guard';
import { PushService } from './push.service';

@Controller('push')
export class PushController {
  constructor(private readonly push: PushService) {}

  /** Javni ključ za pretplatu u pregledaču. */
  @Public()
  @Get('key')
  key() {
    return { key: this.push.key() };
  }

  /** Uređaj prijavljenog igrača se pretplaćuje na obaveštenja. */
  @Post('subscribe')
  async subscribe(@CurrentUser() user: User, @Body() body: { endpoint?: string; keys?: { p256dh?: string; auth?: string } }) {
    const endpoint = String(body?.endpoint ?? '');
    const p256dh = String(body?.keys?.p256dh ?? '');
    const auth = String(body?.keys?.auth ?? '');
    if (!/^https:\/\//.test(endpoint) || endpoint.length > 1000 || !p256dh || !auth || p256dh.length > 200 || auth.length > 100) {
      throw new BadRequestException('Neispravna pretplata.');
    }
    await this.push.subscribe(user.id, { endpoint, keys: { p256dh, auth } });
    return { ok: true };
  }

  @Post('unsubscribe')
  async unsubscribe(@CurrentUser() user: User, @Body() body: { endpoint?: string }) {
    await this.push.unsubscribe(user.id, String(body?.endpoint ?? ''));
    return { ok: true };
  }
}
