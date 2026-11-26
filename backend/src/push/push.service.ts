import { subtreeAgentIds } from '../common/agent-chain';
import { Injectable, Logger, OnModuleInit } from '@nestjs/common';
import * as webpush from 'web-push';
import { PrismaService } from '../prisma/prisma.service';
import { tr } from '../common/i18n';

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
      webpush.setVapidDetails(PushService.subject(), pub, priv);
      this.publicKey = pub;
      this.ready = true;
    } catch (e) {
      this.log.error(`Obaveštenja nisu dostupna: ${(e as Error).message}`);
    }
  }

  /**
   * Pošiljalac u potpisu obaveštenja. Apple (iPhone) odbija obaveštenja ako ovo nije prava
   * adresa sajta (https://…) ili e-pošte, pa se koristi adresa sajta na Railway-u.
   */
  static subject() {
    if (process.env.VAPID_SUBJECT) return process.env.VAPID_SUBJECT;
    const domain = process.env.PUBLIC_DOMAIN || process.env.RAILWAY_PUBLIC_DOMAIN;
    return domain ? `https://${domain.replace(/^https?:\/\//, '')}` : 'mailto:poker.klub.triling@gmail.com';
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

  /** Obaveštenje jednom igraču (na sve njegove uređaje), na jeziku koji je izabrao. */
  async toUser(userId: string, msg: PushMessage) {
    const subs = await this.prisma.pushSubscription.findMany({ where: { userId }, include: { user: { select: { lang: true } } } });
    await this.sendLocalized(subs, msg);
  }

  /** Obaveštenje svim aktivnim igračima (npr. novi sto). */
  /** Svim igračima; za privatni sto agenta [ownerAgentId] samo igračima njega i njegovih podagenata. */
  async toAllPlayers(msg: PushMessage, ownerAgentId?: string | null) {
    const agents = ownerAgentId ? [ownerAgentId, ...(await subtreeAgentIds(this.prisma, ownerAgentId))] : null;
    const subs = await this.prisma.pushSubscription.findMany({
      where: { user: { role: 'PLAYER', isBlocked: false, ...(agents ? { agentId: { in: agents } } : {}) } },
      include: { user: { select: { lang: true } } },
    });
    await this.sendLocalized(subs, msg);
  }

  /** Svaki uređaj dobija obaveštenje na jeziku svog igrača. */
  private async sendLocalized(subs: { id: string; endpoint: string; p256dh: string; auth: string; user: { lang: string } }[], msg: PushMessage) {
    for (const lang of ['en', 'sr']) {
      const group = subs.filter((s) => (s.user.lang === 'sr' ? 'sr' : 'en') === lang);
      if (group.length) await this.send(group, { ...msg, title: tr(msg.title, lang), body: tr(msg.body, lang) });
    }
  }

  private async send(subs: { id: string; endpoint: string; p256dh: string; auth: string }[], msg: PushMessage) {
    if (!this.ready || !subs.length) return [];
    const payload = JSON.stringify(msg);
    return Promise.all(
      subs.map(async (s) => {
        const service = new URL(s.endpoint).host;
        try {
          await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, {
            TTL: 600,
            urgency: 'high',
          });
          return { ok: true, service };
        } catch (e) {
          const err = e as { statusCode?: number; body?: string; message: string };
          // Uređaj se odjavio ili pretplata više ne važi: briše se.
          if (err.statusCode === 404 || err.statusCode === 410) {
            await this.prisma.pushSubscription.delete({ where: { id: s.id } }).catch(() => undefined);
          }
          const reason = (err.body || err.message || '').toString().slice(0, 200);
          this.log.warn(`Obaveštenje nije poslato na ${service}: ${err.statusCode ?? ''} ${reason}`);
          return { ok: false, service, status: err.statusCode, error: reason };
        }
      }),
    );
  }
}
