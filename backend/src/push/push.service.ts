import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as webpush from 'web-push';
import { PrismaService } from '../prisma/prisma.service';

/** Sadržaj obaveštenja na telefonu. */
export interface PushMessage {
  title: string;
  body: string;
  /** Sto koji se otvara na dodir obaveštenja. */
  tableId?: string;
  /** Isti tag zamenjuje prethodno obaveštenje (npr. jedno "na potezu ste" po stolu). */
  tag?: string;
}

/**
 * Obaveštenja na telefonu (Web Push): rade u pregledaču na Androidu i na iPhone-u
 * kad je sajt dodat na početni ekran. Ključevi (VAPID) se prave sami i čuvaju u bazi,
 * ili se zadaju kroz VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY.
 */
@Injectable()
export class PushService implements OnModuleInit {
  private readonly log = new Logger(PushService.name);
  private publicKey = '';
  private ready = false;

  constructor(private readonly prisma: PrismaService) {}

  async onModuleInit() {
    try {
      let pub = process.env.VAPID_PUBLIC_KEY;
      let priv = process.env.VAPID_PRIVATE_KEY;
      if (!pub || !priv) {
        const rows = await this.prisma.appSetting.findMany({ where: { key: { in: ['vapidPublic', 'vapidPrivate'] } } });
        pub = rows.find((r) => r.key === 'vapidPublic')?.value;
        priv = rows.find((r) => r.key === 'vapidPrivate')?.value;
        if (!pub || !priv) {
          const keys = webpush.generateVAPIDKeys();
          pub = keys.publicKey;
          priv = keys.privateKey;
          await this.prisma.appSetting.createMany({
            data: [
              { key: 'vapidPublic', value: pub },
              { key: 'vapidPrivate', value: priv },
            ],
            skipDuplicates: true,
          });
          this.log.log('Napravljeni novi ključevi za obaveštenja.');
        }
      }
      webpush.setVapidDetails(process.env.VAPID_SUBJECT || 'mailto:obavestenja@triling.local', pub, priv);
      this.publicKey = pub;
      this.ready = true;
    } catch (e) {
      this.log.error(`Obaveštenja nisu dostupna: ${(e as Error).message}`);
    }
  }

  key() {
    return this.publicKey;
  }

  async subscribe(userId: string, sub: { endpoint: string; keys: { p256dh: string; auth: string } }) {
    await this.prisma.pushSubscription.upsert({
      where: { endpoint: sub.endpoint },
      create: { userId, endpoint: sub.endpoint, p256dh: sub.keys.p256dh, auth: sub.keys.auth },
      update: { userId, p256dh: sub.keys.p256dh, auth: sub.keys.auth },
    });
  }

  async unsubscribe(userId: string, endpoint: string) {
    await this.prisma.pushSubscription.deleteMany({ where: { userId, endpoint } });
  }

  /** Obaveštenje jednom igraču (na sve njegove uređaje). */
  async toUser(userId: string, msg: PushMessage) {
    const subs = await this.prisma.pushSubscription.findMany({ where: { userId } });
    await this.send(subs, msg);
  }

  /** Obaveštenje svim aktivnim igračima (npr. novi sto). */
  async toAllPlayers(msg: PushMessage) {
    const subs = await this.prisma.pushSubscription.findMany({ where: { user: { role: 'PLAYER', isBlocked: false } } });
    await this.send(subs, msg);
  }

  private async send(subs: { id: string; endpoint: string; p256dh: string; auth: string }[], msg: PushMessage) {
    if (!this.ready || !subs.length) return;
    const payload = JSON.stringify(msg);
    await Promise.all(
      subs.map(async (s) => {
        try {
          await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, {
            TTL: 600,
            urgency: 'high',
            ...(msg.tag ? { topic: msg.tag.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 32) } : {}),
          });
        } catch (e) {
          const code = (e as { statusCode?: number }).statusCode;
          // Uređaj se odjavio ili pretplata više ne važi: briše se.
          if (code === 404 || code === 410) await this.prisma.pushSubscription.delete({ where: { id: s.id } }).catch(() => undefined);
          else this.log.warn(`Obaveštenje nije poslato (${code ?? (e as Error).message}).`);
        }
      }),
    );
  }
}
