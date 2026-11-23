import { Injectable, Logger, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { gzipSync } from 'zlib';
import { PrismaService } from '../prisma/prisma.service';
import { ownerEmail, sendMail } from '../common/mail';

const TZ = () => process.env.APP_TIMEZONE || 'Europe/Belgrade';

/** Lokalni datum i vreme (npr. "2026-11-23", "23:41") u vremenskoj zoni kluba. */
export function localNow(d = new Date()) {
  const s = new Intl.DateTimeFormat('sv-SE', { timeZone: TZ(), year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }).format(d);
  const [date, time] = s.split(' ');
  return { date, time };
}

const fmt = (n: number) => Math.round(n).toLocaleString('de-DE');

/**
 * Svakog dana, sam od sebe:
 *  - oko 04:00 rezervna kopija cele baze (gzip JSON) na mejl vlasnika,
 *  - oko 23:30 dnevni izveštaj (rake, fee, uplate i isplate po agentima, upozorenja).
 * Šta je poslato pamti se u bazi, pa se posle ponovnog pokretanja servera ništa ne šalje dvaput.
 */
@Injectable()
export class DailyService implements OnModuleInit, OnModuleDestroy {
  private readonly log = new Logger('Dnevno');
  private timer?: NodeJS.Timeout;
  private running = false;

  constructor(private readonly prisma: PrismaService) {}

  onModuleInit() {
    if (process.env.DAILY_JOBS === 'off') return;
    this.timer = setInterval(() => void this.tick(), 5 * 60_000);
    setTimeout(() => void this.tick(), 60_000);
  }

  onModuleDestroy() {
    clearInterval(this.timer);
  }

  private async once(key: string, date: string, job: () => Promise<void>) {
    const row = await this.prisma.appSetting.findUnique({ where: { key } });
    if (row?.value === date) return;
    await this.prisma.appSetting.upsert({ where: { key }, create: { key, value: date }, update: { value: date } });
    try {
      await job();
    } catch (e) {
      this.log.error(`${key}: ${(e as Error).message}`);
    }
  }

  private async tick() {
    if (this.running) return;
    this.running = true;
    try {
      const { date, time } = localNow();
      if (time >= '04:00') await this.once('daily:backup', date, () => this.mailBackup(date));
      if (time >= '23:30') await this.once('daily:report', date, () => this.mailReport(date));
    } finally {
      this.running = false;
    }
  }

  // ---------- Rezervna kopija ----------

  /** Cela baza kao JSON (svaka tabela posebno); bez slika igrača ako je `withAvatars` false. */
  async backup(withAvatars: boolean): Promise<Buffer> {
    const out: Record<string, unknown[]> = {};
    for (const m of Prisma.dmmf.datamodel.models) {
      const key = m.name.charAt(0).toLowerCase() + m.name.slice(1);
      const delegate = (this.prisma as unknown as Record<string, { findMany: (a: unknown) => Promise<Record<string, unknown>[]> }>)[key];
      if (!delegate) continue;
      const rows: Record<string, unknown>[] = [];
      const idField = m.fields.find((f) => f.isId)?.name;
      // Po delovima, da velike tabele (ruke) ne zauzmu svu memoriju odjednom.
      let skip = 0;
      for (;;) {
        const part = await delegate.findMany({ take: 2000, skip, ...(idField ? { orderBy: { [idField]: 'asc' } } : {}) });
        for (const r of part) {
          if (m.name === 'User' && !withAvatars) r.avatar = null;
          for (const [k, v] of Object.entries(r)) if (Buffer.isBuffer(v) || v instanceof Uint8Array) r[k] = { base64: Buffer.from(v).toString('base64') };
        }
        rows.push(...part);
        if (part.length < 2000) break;
        skip += part.length;
      }
      out[m.name] = rows;
    }
    const json = JSON.stringify({ createdAt: new Date(), tables: out }, (_k, v) => (typeof v === 'bigint' ? v.toString() : v));
    return gzipSync(Buffer.from(json));
  }

  async mailBackup(date: string) {
    const to = ownerEmail();
    if (!to) return;
    let file = await this.backup(false);
    let note = 'Rezervna kopija cele baze (bez slika igrača). Sačuvajte ovaj mejl.';
    // Prilog do ~9 MB (ograničenje slanja); veća baza se preuzima iz admin panela.
    if (file.length > 9 * 1024 * 1024) {
      await sendMail(
        to,
        `Triling — rezervna kopija ${date} (prevelika za mejl)`,
        `Baza je veća od 9 MB (${(file.length / 1048576).toFixed(1)} MB), pa nije poslata kao prilog.\nPreuzmite je u admin panelu: Moj nalog i 2FA → Rezervna kopija baze.\nNa Railway-u uključite i Backups u Postgres servisu.`,
      );
      return;
    }
    await sendMail(to, `Triling — rezervna kopija baze ${date}`, `${note}\nVeličina: ${(file.length / 1024).toFixed(0)} KB.`, [
      { name: `triling-baza-${date}.json.gz`, content: file },
    ]);
    file = Buffer.alloc(0);
    this.log.log(`Rezervna kopija za ${date} poslata.`);
  }

  // ---------- Dnevni izveštaj ----------

  async report(date: string) {
    const tz = TZ();
    const day = (col = '"createdAt"') => Prisma.sql`((${Prisma.raw(col)} AT TIME ZONE 'UTC') AT TIME ZONE ${tz})::date = ${date}::date`;
    type Share = { agentId: string | null; amount: number; cut: number };
    const shares = (t: 'RakeShare' | 'FeeShare') =>
      this.prisma.$queryRaw<Share[]>(Prisma.sql`SELECT "agentId", SUM(amount)::int AS amount, SUM("agentCut")::int AS cut FROM ${Prisma.raw(`"${t}"`)} WHERE ${day()} GROUP BY 1`);
    type Money = { actorId: string | null; type: string; amount: number; n: number };
    const [rake, fees, money, hands, tours, newPlayers, alerts, pending] = await Promise.all([
      shares('RakeShare'),
      shares('FeeShare'),
      this.prisma.$queryRaw<Money[]>(
        Prisma.sql`SELECT "actorId", type::text AS type, SUM(amount)::int AS amount, COUNT(*)::int AS n FROM "Transaction" WHERE type IN ('DEPOSIT','WITHDRAWAL') AND ${day()} GROUP BY 1, 2`,
      ),
      this.prisma.$queryRaw<{ n: number }[]>(Prisma.sql`SELECT COUNT(*)::int AS n FROM "Hand" WHERE ${day()}`),
      this.prisma.$queryRaw<{ n: number }[]>(Prisma.sql`SELECT COUNT(*)::int AS n FROM "Tournament" WHERE status = 'FINISHED' AND ${day('"finishedAt"')}`),
      this.prisma.$queryRaw<{ n: number }[]>(Prisma.sql`SELECT COUNT(*)::int AS n FROM "User" WHERE role = 'PLAYER' AND ${day()}`),
      this.prisma.$queryRaw<{ kind: string; names: string; detail: string }[]>(Prisma.sql`SELECT kind, names, detail FROM "SecurityAlert" WHERE ${day()} ORDER BY "createdAt" DESC LIMIT 20`),
      this.prisma.cashRequest.count({ where: { status: 'PENDING' } }),
    ]);
    const ids = [...new Set([...rake, ...fees].map((r) => r.agentId).concat(money.map((m) => m.actorId)).filter((x): x is string => !!x))];
    const users = await this.prisma.user.findMany({ where: { id: { in: ids } }, select: { id: true, displayName: true, role: true } });
    const name = (id: string | null) => (id ? (users.find((u) => u.id === id)?.displayName ?? '?') : 'Bez agenta');
    const agents = [...new Set([...rake, ...fees].map((r) => r.agentId))].map((id) => {
      const r = rake.filter((x) => x.agentId === id);
      const f = fees.filter((x) => x.agentId === id);
      const sum = (a: Share[], k: 'amount' | 'cut') => a.reduce((s, x) => s + (x[k] ?? 0), 0);
      return { name: name(id), rake: sum(r, 'amount'), fees: sum(f, 'amount'), agentCut: sum(r, 'cut') + sum(f, 'cut') };
    });
    const cashiers = [...new Set(money.map((m) => m.actorId))].map((id) => ({
      name: name(id),
      deposits: money.filter((m) => m.actorId === id && m.type === 'DEPOSIT').reduce((s, m) => s + m.amount, 0),
      withdrawals: Math.abs(money.filter((m) => m.actorId === id && m.type === 'WITHDRAWAL').reduce((s, m) => s + m.amount, 0)),
    }));
    const tot = {
      rake: agents.reduce((s, a) => s + a.rake, 0),
      fees: agents.reduce((s, a) => s + a.fees, 0),
      agentCut: agents.reduce((s, a) => s + a.agentCut, 0),
      deposits: cashiers.reduce((s, a) => s + a.deposits, 0),
      withdrawals: cashiers.reduce((s, a) => s + a.withdrawals, 0),
    };
    return { date, tot, agents, cashiers, hands: hands[0]?.n ?? 0, tours: tours[0]?.n ?? 0, newPlayers: newPlayers[0]?.n ?? 0, alerts, pending };
  }

  async mailReport(date: string) {
    const to = ownerEmail();
    if (!to) return;
    const r = await this.report(date);
    const club = r.tot.rake + r.tot.fees - r.tot.agentCut;
    const lines = [
      `Dnevni izveštaj — ${date}`,
      '',
      `Rake: ${fmt(r.tot.rake)} RSD · Fee turnira: ${fmt(r.tot.fees)} RSD`,
      `Agentima: ${fmt(r.tot.agentCut)} RSD · Klubu (super agent): ${fmt(club)} RSD`,
      `Uplate: ${fmt(r.tot.deposits)} RSD · Isplate: ${fmt(r.tot.withdrawals)} RSD`,
      `Odigrano ruku: ${r.hands} · Završenih turnira: ${r.tours} · Novih igrača: ${r.newPlayers}`,
      `Zahteva za uplatu/isplatu koji čekaju: ${r.pending}`,
      '',
      'Po agentima (rake / fee / agentu):',
      ...(r.agents.length ? r.agents.map((a) => `  ${a.name}: ${fmt(a.rake)} / ${fmt(a.fees)} / ${fmt(a.agentCut)}`) : ['  —']),
      '',
      'Uplate i isplate (ko je uneo):',
      ...(r.cashiers.length ? r.cashiers.map((c) => `  ${c.name}: +${fmt(c.deposits)} / −${fmt(c.withdrawals)}`) : ['  —']),
      '',
      `Bezbednosna upozorenja: ${r.alerts.length}`,
      ...r.alerts.map((a) => `  [${a.kind}] ${a.names} — ${a.detail}`),
    ];
    const td = (s: string | number, b = false) => `<td style="padding:4px 10px;border-bottom:1px solid #eee;${b ? 'font-weight:700' : ''}">${s}</td>`;
    const html = `<div style="font-family:Arial,sans-serif;color:#17211c">
<h2 style="color:#0b3d26;margin:0 0 4px">Poker klub Triling</h2><div style="color:#666;margin-bottom:12px">Dnevni izveštaj — ${date}</div>
<table style="border-collapse:collapse;margin-bottom:14px">
<tr>${td('Rake')}${td(fmt(r.tot.rake) + ' RSD', true)}</tr><tr>${td('Fee turnira')}${td(fmt(r.tot.fees) + ' RSD', true)}</tr>
<tr>${td('Agentima')}${td(fmt(r.tot.agentCut) + ' RSD')}</tr><tr>${td('Klubu')}${td(fmt(club) + ' RSD', true)}</tr>
<tr>${td('Uplate')}${td(fmt(r.tot.deposits) + ' RSD')}</tr><tr>${td('Isplate')}${td(fmt(r.tot.withdrawals) + ' RSD')}</tr>
<tr>${td('Odigrano ruku')}${td(r.hands)}</tr><tr>${td('Završenih turnira')}${td(r.tours)}</tr><tr>${td('Novih igrača')}${td(r.newPlayers)}</tr>
<tr>${td('Zahtevi koji čekaju')}${td(r.pending, r.pending > 0)}</tr></table>
<h3 style="margin:10px 0 4px">Po agentima</h3><table style="border-collapse:collapse"><tr>${td('Agent', true)}${td('Rake', true)}${td('Fee', true)}${td('Agentu', true)}</tr>
${r.agents.map((a) => `<tr>${td(a.name)}${td(fmt(a.rake))}${td(fmt(a.fees))}${td(fmt(a.agentCut))}</tr>`).join('') || `<tr>${td('—')}</tr>`}</table>
<h3 style="margin:14px 0 4px">Uplate i isplate</h3><table style="border-collapse:collapse"><tr>${td('Uneo', true)}${td('Uplate', true)}${td('Isplate', true)}</tr>
${r.cashiers.map((c) => `<tr>${td(c.name)}${td(fmt(c.deposits))}${td(fmt(c.withdrawals))}</tr>`).join('') || `<tr>${td('—')}</tr>`}</table>
<h3 style="margin:14px 0 4px">Bezbednosna upozorenja (${r.alerts.length})</h3>
${r.alerts.map((a) => `<div style="font-size:13px">[${a.kind}] ${a.names} — ${a.detail}</div>`).join('') || '<div style="color:#666">Nema.</div>'}
</div>`;
    await sendMail(to, `Triling — dnevni izveštaj ${date}`, lines.join('\n'), [], html);
    this.log.log(`Dnevni izveštaj za ${date} poslat.`);
  }
}
