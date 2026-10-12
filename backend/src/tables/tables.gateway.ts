import { Logger } from '@nestjs/common';
import {
  ConnectedSocket,
  MessageBody,
  OnGatewayConnection,
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

type AuthedSocket = Socket & { data: { userId: string } };

interface TableMsg {
  tableId: string;
}

/**
 * Socket.IO kanal za stolove. Klijent se povezuje sa { auth: { token } }.
 * Svaki događaj odgovara sa { ok: true, ... } ili { ok: false, error }.
 */
@WebSocketGateway({ cors: { origin: '*' }, path: '/socket.io' })
export class TablesGateway implements OnGatewayInit, OnGatewayConnection {
  private readonly log = new Logger(TablesGateway.name);
  @WebSocketServer() server: Server;

  constructor(
    private readonly tables: TablesService,
    private readonly auth: AuthGuard,
    private readonly prisma: PrismaService,
  ) {}

  afterInit(server: Server) {
    this.tables.attachServer(server);
  }

  async handleConnection(socket: AuthedSocket) {
    try {
      const token = socket.handshake.auth?.token || socket.handshake.query?.token;
      const user = await this.auth.userFromToken(String(token || ''));
      socket.data.userId = user.id;
      await socket.join(`user:${user.id}`);
      await this.prisma.user.update({ where: { id: user.id }, data: { lastSeenAt: new Date() } });
      socket.emit('session', { user: publicUser(user), seatedAt: this.tables.seatsOf(user.id) });
    } catch (e) {
      socket.emit('auth:error', { error: (e as Error).message });
      socket.disconnect(true);
    }
  }

  /** Pre svake radnje: nalog mora i dalje biti aktivan (blokada važi odmah). */
  private async assertActive(socket: AuthedSocket) {
    const u = await this.prisma.user.findUnique({ where: { id: socket.data.userId } });
    if (!u || u.isBlocked) {
      socket.emit('auth:error', { error: u ? blockedMessage(u) : 'Nalog ne postoji.' });
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
      if (e instanceof GameError) return { ok: false, error: e.message };
      this.log.error(e);
      return { ok: false, error: 'Greška na serveru. Pokušajte ponovo.' };
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
      const state = this.tables.view(String(msg?.tableId), socket.data.userId);
      await socket.join(`table:${state.id}`);
      return { state };
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

  @SubscribeMessage('table:leave')
  leave(@ConnectedSocket() socket: AuthedSocket, @MessageBody() msg: TableMsg) {
    return this.handle(socket, () => this.tables.leave(socket.data.userId, String(msg?.tableId)));
  }

  /** Prekida sve veze korisnika (posle blokade). */
  async disconnectUser(userId: string, reason: string) {
    this.server.to(`user:${userId}`).emit('auth:error', { error: reason });
    this.server.in(`user:${userId}`).disconnectSockets(true);
  }
}
