/**
 * Botovi za probu stola (da se ne igra sam):
 *   API_URL=http://localhost:3000 ADMIN_USERNAME=admin ADMIN_PASSWORD=... TABLE_ID=<id stola> BOTS=3 npx ts-node scripts/bots.ts
 * Pravi naloge bot1, bot2… (ako ne postoje), uplati im žetone, sedne ih za sto i igra nasumično dok se ne prekine (Ctrl+C).
 */
import { io } from 'socket.io-client';

const API = process.env.API_URL || 'http://localhost:3000';
const TABLE_ID = process.env.TABLE_ID;
const BOTS = Number(process.env.BOTS || 3);

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

const ack = (s: ReturnType<typeof io>, ev: string, data?: unknown): Promise<any> => new Promise((r) => s.emit(ev, data, r));

async function main() {
  if (!TABLE_ID) throw new Error('Zadajte TABLE_ID.');
  const admin = (await call('POST', '/auth/login', undefined, { username: process.env.ADMIN_USERNAME, password: process.env.ADMIN_PASSWORD })).accessToken;
  for (let i = 1; i <= BOTS; i++) {
    const username = `bot${i}`;
    const found = (await call('GET', `/admin/players?q=${username}`, admin)).items.find((u: any) => u.username === username);
    const user = found ?? (await call('POST', '/admin/players', admin, { username, displayName: `Bot ${i}`, password: 'bot12345' }));
    if (user.balance < 5000) await call('POST', `/admin/players/${user.id}/deposit`, admin, { amount: 10000, note: 'botovi' });
    const token = (await call('POST', '/auth/login', undefined, { username, password: 'bot12345' })).accessToken;
    const s = io(API, { auth: { token }, transports: ['websocket'] });
    await new Promise((r) => s.once('session', r));
    const st = (await ack(s, 'table:watch', { tableId: TABLE_ID })).state;
    const free = st.seats.findIndex((x: any) => x === null);
    if (st.mySeat < 0) {
      if (free < 0) throw new Error('Sto je pun.');
      const r = await ack(s, 'table:sit', { tableId: TABLE_ID, seat: free, buyIn: Math.min(st.maxBuyIn, Math.max(st.minBuyIn, st.bigBlind * 100)) });
      if (!r.ok) throw new Error(r.error);
    }
    let lastKey = '';
    s.on('table:state', (t: any) => {
      const me = t.mySeat >= 0 ? t.seats[t.mySeat] : null;
      if (me && me.stack === 0 && !me.inHand) void ack(s, 'table:topup', { tableId: TABLE_ID, amount: t.maxBuyIn });
      if (me?.sittingOut) void ack(s, 'table:sitout', { tableId: TABLE_ID, value: false });
      if (!t.legal) return;
      const key = `${t.handNo}:${t.street}:${t.pot}`;
      if (key === lastKey) return;
      lastKey = key;
      const legal = t.legal;
      setTimeout(() => {
        const r = Math.random();
        let msg: any = { action: legal.check ? 'check' : 'call' };
        if (r < 0.15 && !legal.check) msg = { action: 'fold' };
        else if (r > 0.8 && legal.minRaiseTo !== null) msg = { action: 'raise', amount: legal.minRaiseTo };
        void ack(s, 'table:act', { tableId: TABLE_ID, ...msg });
      }, 700 + Math.random() * 1500);
    });
    console.log(`${username} sedi za stolom.`);
  }
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
