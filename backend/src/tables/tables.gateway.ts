import { Logger } from '@nestjs/common';
import {
  ConnectedSocket,
  MessageBody,
  OnGatewayConnection,
  OnGatewayDisconnect,
  OnGatewayInit,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import type { Server, Socket } from 'socket.io';
import { AuthGuard, blockedMessage } from '../common/auth.guard';
import { publicUser } from '../common/public-user';
import { PrismaService } from '../prisma/prisma.service';
import { ActionType, GameError } from '../poker/engine/game';
import { TablesService } from './tables.service';
import { allowedOrigins } from '../common/origins';
import { normLang, tr, trUser, userLang } from '../common/i18n';
import { TournamentsService } from '../tournaments/tournaments.service';

type AuthedSocket = Socket & { data: { userId: string; lang?: string } };

interface TableMsg {
  tableId: string;
}

/**
 * Socket.IO kanal za stolove. Klijent se povezuje sa { auth: { token } }.
 * Svaki događaj odgovara sa { ok: true, ... } ili { ok: false, error }.
 */
@WebSocketGateway({ cors: { origin: allowedOrigins() ?? '*' }, path: '/socket.io' })
export class TablesGateway implements OnGatewayInit, OnGatewayConnection, OnGatewayDisconnect {
  private readonly log = new Logger(TablesGateway.name);
  @WebSocketServer() server: Server;

  constructor(
    private readonly tables: TablesService,
    private readonly tours: TournamentsService,
    private readonly auth: AuthGuard,
    private readonly prisma: PrismaService,
  ) {}

  afterInit(server: Server) {
    this.tables.attachServer(server);
    this.tours.attachServer(server);
  }

  async handleConnection(socket: AuthedSocket) {
    try {
      const token = socket.handshake.auth?.token || socket.handshake.query?.token;
      const user = await this.auth.userFromToken(String(token || ''));
      socket.data.userId = user.id;
      // Jezik aplikacije (en/sr): poruke i obaveštenja ovom igraču stižu na tom jeziku.
      const lang = normLang(socket.handshake.auth?.lang ?? user.lang);
      socket.data.lang = lang;
      userLang.set(user.id, lang);
      await socket.join(`user:${user.id}`);
      // IP adresa i uređaj (zaštita: više naloga sa iste mreže/uređaja za istim stolom).
      const fwd = String(socket.handshake.headers['x-forwarded-for'] ?? '').split(',')[0].trim();
      const ip = fwd || socket.handshake.address || '';
      const device = String(socket.handshake.auth?.device ?? '').slice(0, 64) || null;
      this.tables.setNet(user.id, ip, device);
      await this.prisma.user.update({ where: { id: user.id }, data: { lastSeenAt: new Date(), lastIp: ip || null, lastDevice: device } });
      // Dok klijent ne javi drugačije, smatra se da je aplikacija otvorena.
      this.tables.setPresence(user.id, socket.id, true);
      socket.emit('session', { user: publicUser(user), seatedAt: this.tables.seatsOf(user.id) });
    } catch (e) {
      socket.emit('auth:error', { error: tr((e as Error).message, socket.handshake.auth?.lang) });
      socket.disconnect(true);
    }
  }

  handleDisconnect(socket: AuthedSocket) {
    if (socket.data?.userId) this.tables.setPresence(socket.data.userId, socket.id, null);
  }

  /** Igrač je promenio jezik aplikacije. */
  @SubscribeMessage('lang')
  setLang(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: { lang: string }) {
    const lang = normLang(msg?.lang);
    socket.data.lang = lang;
    if (socket.data?.userId) userLang.set(socket.data.userId, lang);
    return { ok: true };
  }

  /** Aplikacija je u pozadini (igrač je otišao u drugu aplikaciju) ili ponovo vidljiva. */
  @SubscribeMessage('presence')
  presence(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: { visible: boolean }) {
    if (socket.data?.userId) this.tables.setPresence(socket.data.userId, socket.id, !!msg?.visible);
    return { ok: true };
  }

  /** Pre svake radnje: nalog mora i dalje biti aktivan (blokada važi odmah). */
  private async assertActive(socket: AuthedSocket) {
    const u = await this.prisma.user.findUnique({ where: { id: socket.data.userId } });
    if (!u || u.isBlocked) {
      socket.emit('auth:error', { error: tr(u ? blockedMessage(u) : 'Nalog ne postoji.', socket.data.lang) });
      socket.disconnect(true);
      throw new GameError('Nalog nije aktivan.');
    }
    return u;
  }

  private async handle<T>(socket: AuthedSocket, fn: () => Promise<T> | T) {
    try {
      if (!socket.data.userId) throw new GameError('Niste prijavljeni.');
      await this.assertActive(socket);
      const res = await fn();
      return { ok: true, ...(res && typeof res === 'object' ? res : {}) };
    } catch (e) {
      const lang = (socket.data as { lang?: string }).lang;
      if (e instanceof GameError) return { ok: false, error: tr(e.message, lang) };
      this.log.error(e);
      return { ok: false, error: tr('Greška na serveru. Pokušajte ponovo.', lang) };
    }
  }

  @SubscribeMessage('lobby:join')
  lobbyJoin(@ConnectedSocket() socket: AuthedSocket) {
    return this.handle(socket, async () => {
      await socket.join('lobby');
      return { tables: this.tables.lobby() };
    });
  }

  @SubscribeMessage('lobby:leave')
  lobbyLeave(@ConnectedSocket() socket: AuthedSocket) {
    return this.handle(socket, async () => {
      await socket.leave('lobby');
    });
  }

  @SubscribeMessage('table:watch')
  watch(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg) {
    return this.handle(socket, async () => {
      this.tables.assertUnlocked(String(msg?.tableId));
      const state = this.tables.view(String(msg?.tableId), socket.data.userId);
      await socket.join(`table:${state.id}`);
      return { state, chat: this.tables.chatHistory(state.id) };
    });
  }

  @SubscribeMessage('table:unwatch')
  unwatch(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg) {
    return this.handle(socket, async () => {
      await socket.leave(`table:${String(msg?.tableId)}`);
    });
  }

  @SubscribeMessage('table:sit')
  sit(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { seat: number; buyIn: number }) {
    return this.handle(socket, async () => {
      await socket.join(`table:${String(msg?.tableId)}`);
      return this.tables.sit(socket.data.userId, String(msg?.tableId), Number(msg?.seat), Number(msg?.buyIn));
    });
  }

  @SubscribeMessage('table:topup')
  topUp(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { amount: number }) {
    return this.handle(socket, () => this.tables.topUp(socket.data.userId, String(msg?.tableId), Number(msg?.amount)));
  }

  @SubscribeMessage('table:act')
  act(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { action: ActionType; amount?: number }) {
    return this.handle(socket, () =>
      this.tables.act(socket.data.userId, String(msg?.tableId), msg?.action, msg?.amount === undefined ? undefined : Number(msg.amount)),
    );
  }

  @SubscribeMessage('table:sitout')
  sitOut(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { value: boolean }) {
    return this.handle(socket, () => this.tables.setSitOut(socket.data.userId, String(msg?.tableId), !!msg?.value));
  }

  @SubscribeMessage('table:chat')
  chat(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { text: string }) {
    return this.handle(socket, () => this.tables.chat(socket.data.userId, String(msg?.tableId), msg?.text));
  }

  @SubscribeMessage('table:prefs')
  prefs(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { straddle?: boolean }) {
    return this.handle(socket, () =>
      this.tables.setPrefs(socket.data.userId, String(msg?.tableId), {
        straddle: msg?.straddle === undefined ? undefined : !!msg.straddle,
      }),
    );
  }

  @SubscribeMessage('table:show')
  show(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { cards: number[] }) {
    return this.handle(socket, () =>
      this.tables.showCards(socket.data.userId, String(msg?.tableId), Array.isArray(msg?.cards) ? msg.cards.slice(0, 4) : []),
    );
  }

  @SubscribeMessage('table:rit')
  rit(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { yes: boolean }) {
    return this.handle(socket, () => this.tables.answerRunTwice(socket.data.userId, String(msg?.tableId), !!msg?.yes));
  }

  @SubscribeMessage('table:waitlist')
  waitlist(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg & { join: boolean }) {
    return this.handle(socket, () => this.tables.setWaitlist(socket.data.userId, String(msg?.tableId), !!msg?.join));
  }

  @SubscribeMessage('table:leave')
  leave(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg) {
    return this.handle(socket, () => this.tables.leave(socket.data.userId, String(msg?.tableId)));
  }

  // ---------- Turniri ----------

  @SubscribeMessage('tour:list')
  tourList(@ConnectedSocket() socket: AuthedSocket) {
    return this.handle(socket, async () => {
      await socket.join('tours');
      return { tournaments: await this.tours.list() };
    });
  }

  @SubscribeMessage('tour:get')
  tourGet(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: { id: string; watch?: boolean }) {
    return this.handle(socket, async () => {
      const id = String(msg?.id);
      const tournament = await this.tours.detail(id, socket.data.userId);
      if (msg?.watch) await socket.join(`tour:${id}`);
      return { tournament };
    });
  }

  @SubscribeMessage('tour:unwatch')
  tourUnwatch(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: { id: string }) {
    return this.handle(socket, async () => {
      await socket.leave(`tour:${String(msg?.id)}`);
    });
  }

  @SubscribeMessage('tour:register')
  tourRegister(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: { id: string }) {
    return this.handle(socket, () => this.tours.register(socket.data.userId, String(msg?.id)));
  }

  @SubscribeMessage('tour:unregister')
  tourUnregister(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: { id: string }) {
    return this.handle(socket, () => this.tours.unregister(socket.data.userId, String(msg?.id)));
  }

  @SubscribeMessage('tour:rebuy')
  tourRebuy(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: { id: string }) {
    return this.handle(socket, () => this.tours.rebuy(socket.data.userId, String(msg?.id)));
  }

  @SubscribeMessage('tour:addon')
  tourAddon(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: { id: string }) {
    return this.handle(socket, () => this.tours.addon(socket.data.userId, String(msg?.id)));
  }

  /** Prekida sve veze korisnika (posle blokade). */
  async disconnectUser(userId: string, reason: string) {
    this.server.to(`user:${userId}`).emit('auth:error', { error: trUser(reason, userId) });
    this.server.in(`user:${userId}`).disconnectSockets(true);
  }
}
