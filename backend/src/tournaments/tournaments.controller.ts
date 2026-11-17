import { BadRequestException, Body, Controller, Get, NotFoundException, Param, Post, Query } from '@nestjs/common';
import { Prisma, User } from '@prisma/client';
import { CurrentUser, Roles, Staff } from '../common/auth.guard';
import { PrismaService } from '../prisma/prisma.service';
import { GameError } from '../poker/engine/game';
import { defaultLevels, estimateMinutes, Level, validateLevels } from './structure';
import { TournamentsService, tourRule } from './tournaments.service';

const int = (v: unknown, name: string, min: number, max = 1_000_000_000) => {
  const n = Number(v ?? 0);
  if (!Number.isInteger(n) || n < min || n > max) throw new BadRequestException(`${name}: unesite ceo broj od ${min} do ${max}.`);
  return n;
};

/** Turniri u admin panelu: pravi ih i otkazuje super agent, pregled vide i agenti. */
@Staff()
@Controller('admin/tournaments')
export class TournamentsAdminController {
  constructor(
    private readonly prisma: PrismaService,
    private readonly tours: TournamentsService,
  ) {}

  @Get()
  async list(@Query('status') status?: string) {
    const where: Prisma.TournamentWhereInput =
      status === 'active' ? { status: { in: ['REGISTERING', 'RUNNING'] } } : status === 'done' ? { status: { in: ['FINISHED', 'CANCELLED'] } } : {};
    const items = await this.prisma.tournament.findMany({
      where,
      orderBy: { startAt: 'desc' },
      take: 100,
      include: { entries: { select: { paid: true, feePaid: true, prize: true } }, createdBy: { select: { displayName: true } } },
    });
    // Otkazan turnir: sve je vraćeno igračima (nema fonda ni fee-a).
    return items.map(({ entries, ...t }) => ({
      ...t,
      entries: entries.length,
      collected: t.status === 'CANCELLED' ? 0 : entries.reduce((a, e) => a + e.paid, 0),
      fees: t.status === 'CANCELLED' ? 0 : entries.reduce((a, e) => a + e.feePaid, 0),
      prizesPaid: entries.reduce((a, e) => a + e.prize, 0),
    }));
  }

  /** Podrazumevana struktura i procena trajanja (za formu). */
  @Get('defaults')
  defaults(@Query('bb') bb?: string, @Query('minutes') minutes?: string, @Query('count') count?: string) {
    return { levels: defaultLevels(Number(bb) || 20, Number(minutes) || 10, Number(count) || 20) };
  }

  @Post('estimate')
  estimate(@Body() b: { levels: Level[]; breakMode: string; breakEvery: number; breakMinutes: number; players: number; startingStack: number }) {
    const err = validateLevels(b.levels);
    if (err) return { minutes: null, error: err };
    return {
      minutes: estimateMinutes(b.levels, tourRule({ breakMode: b.breakMode, breakEvery: Number(b.breakEvery), breakMinutes: Number(b.breakMinutes) }), Number(b.players) || 20, Number(b.startingStack) || 10_000),
    };
  }

  @Get(':id')
  async detail(@Param('id') id: string) {
    try {
      return await this.tours.adminDetail(id);
    } catch (e) {
      if (e instanceof GameError) throw new NotFoundException(e.message);
      throw e;
    }
  }

  @Roles('ADMIN')
  @Post()
  async create(@CurrentUser() actor: User, @Body() b: Record<string, unknown>) {
    const name = String(b.name ?? '').trim();
    if (name.length < 2 || name.length > 40) throw new BadRequestException('Naziv turnira: 2–40 znakova.');
    const variant: 'OMAHA' | 'HOLDEM' | null = b.variant === 'OMAHA' ? 'OMAHA' : b.variant === 'HOLDEM' ? 'HOLDEM' : null;
    if (!variant) throw new BadRequestException("Igra mora biti Hold'em ili Omaha.");
    const startAt = new Date(String(b.startAt ?? ''));
    if (isNaN(startAt.getTime())) throw new BadRequestException('Unesite vreme početka.');
    if (startAt.getTime() < Date.now() - 60_000) throw new BadRequestException('Vreme početka je u prošlosti.');
    const levels = b.levels as Level[];
    const lerr = validateLevels(levels);
    if (lerr) throw new BadRequestException(lerr);
    const breakMode = ['HOURLY', 'LEVELS', 'NONE'].includes(String(b.breakMode)) ? String(b.breakMode) : 'NONE';
    const payoutMode = b.payoutMode === 'FIXED' ? 'FIXED' : 'PERCENT';
    const payouts = Array.isArray(b.payouts) ? (b.payouts as unknown[]).map(Number).filter((x) => x > 0) : [];
    if (payoutMode === 'FIXED') {
      const sum = payouts.reduce((a, x) => a + x, 0);
      if (!payouts.length || Math.abs(sum - 100) > 0.01) throw new BadRequestException('Procenti nagrada moraju u zbiru dati 100 %.');
    }
    const data = {
      name,
      variant,
      startAt,
      buyIn: int(b.buyIn, 'Ulaz (nagradni deo)', 0),
      fee: int(b.fee, 'Fee (rake)', 0),
      startingStack: int(b.startingStack, 'Početni stek', 100),
      maxPlayers: int(b.maxPlayers, 'Najviše igrača', 0, 10_000),
      minPlayers: int(b.minPlayers ?? 2, 'Najmanje igrača', 2, 10_000),
      tableSize: int(b.tableSize ?? 9, 'Igrača za stolom', 2, 9),
      actionSeconds: int(b.actionSeconds ?? 20, 'Vreme za potez', 10, 120),
      levels: levels as unknown as Prisma.InputJsonValue,
      breakMode,
      breakEvery: int(b.breakEvery ?? 0, 'Pauza posle nivoa', 0, 100),
      breakMinutes: int(b.breakMinutes ?? 0, 'Trajanje pauze', 0, 59),
      lateRegLevels: int(b.lateRegLevels ?? 0, 'Kasna prijava', 0, 100),
      rebuyLevels: int(b.rebuyLevels ?? 0, 'Rebuy do nivoa', 0, 100),
      rebuyMax: int(b.rebuyMax ?? 0, 'Najviše rebuy-eva', 0, 100),
      rebuyPrice: int(b.rebuyPrice ?? 0, 'Cena rebuy-a', 0),
      rebuyFee: int(b.rebuyFee ?? 0, 'Fee rebuy-a', 0),
      rebuyChips: int(b.rebuyChips ?? 0, 'Žetoni za rebuy', 0),
      rebuyBelow: int(b.rebuyBelow ?? 0, 'Rebuy kad je stek najviše', 0),
      reentryMax: int(b.reentryMax ?? 0, 'Re-entry', 0, 100),
      addonLevel: int(b.addonLevel ?? 0, 'Add-on do nivoa', 0, 100),
      addonPrice: int(b.addonPrice ?? 0, 'Cena add-on-a', 0),
      addonFee: int(b.addonFee ?? 0, 'Fee add-on-a', 0),
      addonChips: int(b.addonChips ?? 0, 'Žetoni za add-on', 0),
      guarantee: int(b.guarantee ?? 0, 'Garancija', 0),
      payoutMode,
      payPercent: int(b.payPercent ?? 15, 'Procenat plaćenih', 1, 100),
      payouts: payouts as unknown as Prisma.InputJsonValue,
      estimatedMinutes: int(b.estimatedMinutes ?? 0, 'Procena trajanja', 0, 100_000),
      createdById: actor.id,
    };
    if (data.breakMode === 'LEVELS' && data.breakEvery < 1) throw new BadRequestException('Unesite posle koliko nivoa je pauza.');
    if (data.breakMode !== 'NONE' && data.breakMinutes < 1) throw new BadRequestException('Unesite trajanje pauze.');
    if (data.rebuyLevels > 0 && data.rebuyChips < 1) throw new BadRequestException('Unesite broj žetona za rebuy.');
    if (data.addonLevel > 0 && data.addonChips < 1) throw new BadRequestException('Unesite broj žetona za add-on.');
    if (data.reentryMax > 0 && data.lateRegLevels < 1) throw new BadRequestException('Re-entry je moguć samo tokom kasne prijave (unesite do kog nivoa).');
    for (const [v, label] of [
      [data.lateRegLevels, 'Kasna prijava'],
      [data.rebuyLevels, 'Rebuy'],
      [data.addonLevel, 'Add-on'],
    ] as const) {
      if (v > levels.length) throw new BadRequestException(`${label}: nivo ne može biti veći od broja nivoa (${levels.length}).`);
    }
    if (data.maxPlayers > 0 && data.maxPlayers < data.minPlayers) throw new BadRequestException('Najviše igrača je manje od najmanje.');
    return this.tours.create(data);
  }

  @Roles('ADMIN')
  @Post(':id/cancel')
  async cancel(@Param('id') id: string) {
    try {
      await this.tours.cancel(id);
    } catch (e) {
      if (e instanceof GameError) throw new BadRequestException(e.message);
      throw e;
    }
    return { ok: true };
  }
}
