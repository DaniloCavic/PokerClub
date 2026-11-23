import { Controller, Get, Query } from '@nestjs/common';
import { User } from '@prisma/client';
import { CurrentUser } from '../common/auth.guard';
import { PrismaService } from '../prisma/prisma.service';
import { avatarUrl } from '../common/public-user';

/** Poeni za mesto na turniru: 10 × √(broj ulaza / mesto). Pobednik velikog turnira dobija najviše. */
export const tourPoints = (entries: number, position: number) => Math.round(10 * Math.sqrt(Math.max(1, entries) / Math.max(1, position)));

type Row = { userId: string; name: string; avatarUrl: string | null };

/** Mesečna rang lista: turniri (poeni) i keš igra (dobitak). */
@Controller('leaderboard')
export class LeaderboardController {
  constructor(private readonly prisma: PrismaService) {}

  private cache = new Map<string, { at: number; data: unknown }>();

  @Get()
  async get(@CurrentUser() me: User, @Query('month') month?: string) {
    const now = new Date();
    const m = month && /^\d{4}-\d{2}$/.test(month) ? month : `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}`;
    const hit = this.cache.get(m);
    const data = hit && Date.now() - hit.at < 60_000 ? (hit.data as Awaited<ReturnType<typeof this.compute>>) : await this.compute(m);
    if (!hit || Date.now() - hit.at >= 60_000) this.cache.set(m, { at: Date.now(), data });
    const mine = (list: { userId: string }[]) => {
      const k = list.findIndex((x) => x.userId === me.id);
      return k < 0 ? null : { rank: k + 1, ...list[k] };
    };
    return {
      month: m,
      tournaments: data.tournaments.slice(0, 50),
      cash: data.cash.slice(0, 50),
      me: { tournaments: mine(data.tournaments), cash: mine(data.cash) },
    };
  }

  private async compute(month: string) {
    const from = new Date(`${month}-01T00:00:00`);
    const to = new Date(from.getFullYear(), from.getMonth() + 1, 1);
    // ---------- Turniri ----------
    const entries = await this.prisma.tournamentEntry.findMany({
      where: { position: { not: null }, tournament: { status: 'FINISHED', finishedAt: { gte: from, lt: to } } },
      select: { userId: true, tournamentId: true, position: true, prize: true, bountyWon: true, tournament: { select: { _count: { select: { entries: true } } } } },
    });
    // Najbolji plasman igrača po turniru (re-entry se ne sabira).
    const best = new Map<string, (typeof entries)[number]>();
    for (const e of entries) {
      const k = `${e.userId}:${e.tournamentId}`;
      const cur = best.get(k);
      if (!cur || e.position! < cur.position!) best.set(k, e);
    }
    const money = new Map<string, number>();
    for (const e of entries) money.set(e.userId, (money.get(e.userId) ?? 0) + e.prize + e.bountyWon);
    const tours = new Map<string, { points: number; played: number; wins: number; cashes: number }>();
    for (const e of best.values()) {
      const t = tours.get(e.userId) ?? { points: 0, played: 0, wins: 0, cashes: 0 };
      t.points += tourPoints(e.tournament._count.entries, e.position!);
      t.played++;
      if (e.position === 1) t.wins++;
      if (e.prize > 0) t.cashes++;
      tours.set(e.userId, t);
    }
    // ---------- Keš igra ----------
    const hands = await this.prisma.hand.findMany({
      where: { createdAt: { gte: from, lt: to }, table: { tournamentId: null } },
      select: { details: true },
    });
    const cash = new Map<string, { profit: number; hands: number }>();
    for (const h of hands) {
      const d = h.details as { players?: { userId: string; startStack: number; endStack: number }[] };
      for (const p of d.players ?? []) {
        const c = cash.get(p.userId) ?? { profit: 0, hands: 0 };
        c.profit += p.endStack - p.startStack;
        c.hands++;
        cash.set(p.userId, c);
      }
    }
    const ids = [...new Set([...tours.keys(), ...cash.keys()])];
    const users = await this.prisma.user.findMany({ where: { id: { in: ids }, role: 'PLAYER' }, select: { id: true, displayName: true, avatarAt: true } });
    const who = (id: string): Row | null => {
      const u = users.find((x) => x.id === id);
      return u ? { userId: u.id, name: u.displayName, avatarUrl: avatarUrl(u) } : null;
    };
    const tournaments = [...tours.entries()]
      .map(([id, t]) => ({ ...who(id)!, ...t, won: money.get(id) ?? 0 }))
      .filter((x) => x.userId)
      .sort((a, b) => b.points - a.points || b.won - a.won);
    const cashList = [...cash.entries()]
      .map(([id, c]) => ({ ...who(id)!, ...c }))
      .filter((x) => x.userId && x.hands > 0)
      .sort((a, b) => b.profit - a.profit);
    return { tournaments, cash: cashList };
  }
}
