/**
 * Proba celog sistema na pokrenutom serveru:
 *   API_URL=http://localhost:3000 ADMIN_USERNAME=admin ADMIN_PASSWORD=... npx ts-node scripts/smoke.ts
 * Pravi agenta, igrače i stolove, odigra ruke preko Socket.IO i proveri da se nijedan žeton ne izgubi.
 */
import { io, Socket } from 'socket.io-client';

const API = process.env.API_URL || 'http://localhost:3000';
const suffix = Date.now().toString(36).slice(-5);

async function call(method: string, path: string, token?: string, body?: unknown) {
  const res = await fetch(`${API}/api${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${data?.message}`);
  return data;
}

const login = async (username: string, password: string) => (await call('POST', '/auth/login', undefined, { username, password })).accessToken as string;

function assert(cond: unknown, msg: string) {
  if (!cond) throw new Error(`NEUSPEH: ${msg}`);
  console.log(`  ✓ ${msg}`);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface Bot {
  name: string;
  id: string;
  token: string;
  socket: Socket;
  state: Record<string, any>;
}

function emit(s: Socket, ev: string, data?: unknown): Promise<any> {
  return new Promise((resolve) => s.emit(ev, data, resolve));
}

async function connect(name: string, id: string, token: string): Promise<Bot> {
  const socket = io(API, { auth: { token }, transports: ['websocket'] });
  const bot: Bot = { name, id, token, socket, state: {} };
  await new Promise<void>((resolve, reject) => {
    socket.on('session', () => resolve());
    socket.on('auth:error', (e) => reject(new Error(e.error)));
  });
  socket.on('table:state', (st) => {
    bot.state[st.id] = st;
    const legal = st.legal;
    if (!legal || st.toAct !== st.mySeat) return;
    // Nasumičan, ali ispravan potez.
    const r = Math.random();
    let msg: any;
    if (r < 0.12) msg = { action: 'fold' };
    else if (r < 0.35 && legal.minRaiseTo !== null) {
      const span = legal.maxRaiseTo - legal.minRaiseTo;
      msg = { action: 'raise', amount: legal.minRaiseTo + Math.floor(Math.random() * Math.min(span + 1, 200)) };
    } else msg = { action: legal.check ? 'check' : 'call' };
    void emit(socket, 'table:act', { tableId: st.id, ...msg }).then((res) => {
      if (!res.ok && !/na potezu/.test(res.error)) console.log(`  ! ${name}: ${res.error}`);
    });
  });
  return bot;
}

async function main() {
  console.log(`Server: ${API}`);
  const admin = await login(process.env.ADMIN_USERNAME || 'admin', process.env.ADMIN_PASSWORD || 'admin12345');

  console.log('Agent i igrači');
  const agentName = `agent_${suffix}`;
  await call('POST', '/admin/agents', admin, { username: agentName, displayName: 'Agent Proba', password: 'lozinka1' });
  const agent = await login(agentName, 'lozinka1');
  const players: { id: string; username: string }[] = [];
  for (let i = 0; i < 4; i++) {
    const u = await call('POST', '/admin/players', agent, { username: `igrac${i}_${suffix}`, displayName: `Igrač ${i}`, password: 'lozinka1' });
    await call('POST', `/admin/players/${u.id}/deposit`, agent, { amount: 5000, note: 'početna uplata' });
    players.push(u);
  }
  const list = await call('GET', '/admin/players', agent);
  assert(list.total === 4, 'agent vidi samo svoja 4 igrača');
  await call('POST', `/admin/players/${players[0].id}/withdraw`, agent, { amount: 1000 }).then((r) => assert(r.balance === 4000, 'isplata smanjuje balans'));
  await call('POST', `/admin/players/${players[0].id}/withdraw`, agent, { amount: 999999 }).then(
    () => assert(false, 'isplata veća od balansa mora biti odbijena'),
    (e) => assert(/dovoljno/.test(e.message), 'isplata veća od balansa je odbijena'),
  );
  const deposited = 4 * 5000 - 1000;

  console.log('Stolovi');
  const holdem = await call('POST', '/admin/tables', agent, {
    name: `NL ${suffix}`, variant: 'HOLDEM', smallBlind: 5, bigBlind: 10, minBuyIn: 200, maxBuyIn: 1000,
    maxSeats: 6, rakePercent: 5, rakeCap: 20, actionSeconds: 10,
  });
  const omaha = await call('POST', '/admin/tables', agent, {
    name: `PLO ${suffix}`, variant: 'OMAHA', smallBlind: 10, bigBlind: 20, minBuyIn: 400, maxBuyIn: 2000,
    maxSeats: 9, rakePercent: 2.5, rakeCap: 0, actionSeconds: 10,
  });
  assert(holdem.rakePercent === 5 && omaha.rakePercent === 2.5, 'rake po stolu se čuva');

  console.log('Igra');
  const bots: Bot[] = [];
  for (const p of players) bots.push(await connect(p.username, p.id, await login(p.username, 'lozinka1')));
  const lobby = await emit(bots[0].socket, 'lobby:join');
  assert(lobby.tables.some((t: any) => t.id === holdem.id), 'sto je u lobiju');

  for (let i = 0; i < bots.length; i++) {
    const r = await emit(bots[i].socket, 'table:sit', { tableId: holdem.id, seat: i, buyIn: 500 + i * 100 });
    assert(r.ok, `${bots[i].name} seo za Hold'em sto`);
  }
  for (let i = 0; i < 3; i++) {
    const r = await emit(bots[i].socket, 'table:sit', { tableId: omaha.id, seat: i * 2, buyIn: 800 });
    assert(r.ok, `${bots[i].name} seo za Omaha sto`);
  }
  const bad = await emit(bots[3].socket, 'table:sit', { tableId: omaha.id, seat: 0, buyIn: 800 });
  assert(!bad.ok && /zauzeto/.test(bad.error), 'zauzeto mesto se odbija');
  const peek = bots[0].state[holdem.id];
  if (peek?.inProgress) {
    const others = peek.seats.filter((s: any) => s && s.index !== peek.mySeat);
    assert(others.every((s: any) => s.cards === null), 'tuđe karte se ne vide');
  }

  await sleep(Number(process.env.PLAY_MS || 25000));
  const hands = (await call('GET', `/admin/tables/${holdem.id}`, agent)).hands.total;
  const omahaHands = (await call('GET', `/admin/tables/${omaha.id}`, agent)).hands.total;
  assert(hands >= 3, `odigrano ${hands} ruku Hold'ema`);
  assert(omahaHands >= 3, `odigrano ${omahaHands} ruku Omahe`);

  console.log('Blokada usred igre');
  await call('POST', `/admin/players/${players[1].id}/block`, agent, { reason: 'proba' });
  await sleep(2000);
  const detail = await call('GET', `/admin/players/${players[1].id}`, agent);
  // Ako je bio u ruci, ustaje kad se ruka završi.
  for (let k = 0; k < 20 && detail.seats.length; k++) {
    await sleep(1000);
    detail.seats = (await call('GET', `/admin/players/${players[1].id}`, agent)).seats;
  }
  assert(detail.seats.length === 0, 'blokiran igrač je podignut sa stolova');
  await login(players[1].username, 'lozinka1').then(
    () => assert(false, 'blokiran igrač ne sme da se prijavi'),
    (e) => assert(/blokiran/.test(e.message), 'blokiran igrač ne može da se prijavi'),
  );

  console.log('Zatvaranje stolova');
  await call('POST', `/admin/tables/${holdem.id}/close`, agent);
  await call('POST', `/admin/tables/${omaha.id}/close`, agent);
  for (let k = 0; k < 30; k++) {
    const t = await call('GET', '/admin/tables', agent);
    if (t.filter((x: any) => x.live).length === 0) break;
    await sleep(1000);
  }
  const stats = await call('GET', '/admin/stats', agent);
  assert(stats.chipsOnTables === 0, 'posle zatvaranja nema žetona na stolovima');
  const totalRake = (await call('GET', '/admin/tables', agent)).reduce((s: number, t: any) => s + t.rakeTotal, 0);
  assert(stats.rakeTotal === totalRake && totalRake > 0, `rake ukupno ${totalRake}`);
  assert(
    stats.balanceOnAccounts + totalRake === deposited,
    `žetoni očuvani: na nalozima ${stats.balanceOnAccounts} + rake ${totalRake} = uplaćeno ${deposited}`,
  );

  const tx = await call('GET', `/admin/transactions?type=BUY_IN`, agent);
  assert(tx.total >= 7, 'ulazi za sto su u knjizi transakcija');

  for (const b of bots) b.socket.disconnect();
  console.log('\nSve provere su prošle.');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
