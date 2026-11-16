/**
 * Botovi za probu stola (da se ne igra sam):
 *   API_URL=http://localhost:3000 ADMIN_USERNAME=admin ADMIN_PASSWORD=... TABLE_ID=<id stola> BOTS=3 npx ts-node scripts/bots.ts
 * Pravi naloge bot1, bot2… (ako ne postoje), uplati im žetone, sedne ih za sto i igra nasumično dok se ne prekine (Ctrl+C).
 * Turnir: umesto TABLE_ID zadajte TOUR_ID — botovi se prijave i igraju za stolom koji im turnir dodeli
 * (BOT_REBUY=1: rebuy kad ostanu bez žetona; BOT_REENTRY=1: re-entry posle ispadanja).
 */
import { io } from 'socket.io-client';

const API = process.env.API_URL || 'http://localhost:3000';
const TABLE_ID = process.env.TABLE_ID;
const TOUR_ID = process.env.TOUR_ID;
const BOTS = Number(process.env.BOTS || 3);

async function call(method: string, path: string, token?: string, body?: unknown): Promise<any> {
  const res = await fetch(`${API}/api${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  // Previše prijava za kratko vreme: sačekaj i pokušaj ponovo.
  if (res.status === 429) {
    await new Promise((r) => setTimeout(r, 5000));
    return call(method, path, token, body);
  }
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${data?.message}`);
  return data;
}

const ack = (s: ReturnType<typeof io>, ev: string, data?: unknown): Promise<any> => new Promise((r) => s.emit(ev, data, r));

async function main() {
  if (!TABLE_ID && !TOUR_ID) throw new Error('Zadajte TABLE_ID ili TOUR_ID.');
  const admin = (await call('POST', '/auth/login', undefined, { username: process.env.ADMIN_USERNAME, password: process.env.ADMIN_PASSWORD })).accessToken;
  for (let i = 1; i <= BOTS; i++) {
    const username = `bot${i}`;
    const found = (await call('GET', `/admin/players?q=${username}`, admin)).items.find((u: any) => u.username === username);
    const user = found ?? (await call('POST', '/admin/players', admin, { username, displayName: `Bot ${i}`, password: 'bot12345' }));
    if (user.balance < 5000) await call('POST', `/admin/players/${user.id}/deposit`, admin, { amount: 10000, note: 'botovi' });
    const token = (await call('POST', '/auth/login', undefined, { username, password: 'bot12345' })).accessToken;
    const s = io(API, { auth: { token }, transports: ['websocket'] });
    await new Promise((r) => s.once('session', r));
    if (TOUR_ID) {
      tourBot(s, username);
      continue;
    }
    const st = (await ack(s, 'table:watch', { tableId: TABLE_ID })).state;
    const free = st.seats.findIndex((x: any) => x === null);
    if (st.mySeat < 0) {
      if (free < 0) throw new Error('Sto je pun.');
      const r = await ack(s, 'table:sit', { tableId: TABLE_ID, seat: free, buyIn: process.env.BOT_RANDOM_BUYIN ? st.minBuyIn + Math.floor(Math.random() * (st.maxBuyIn - st.minBuyIn)) : Math.min(st.maxBuyIn, Math.max(st.minBuyIn, st.bigBlind * 100)) });
      if (!r.ok) throw new Error(r.error);
    }
    let lastKey = '';
    s.on('table:state', (t: any) => {
      const me = t.mySeat >= 0 ? t.seats[t.mySeat] : null;
      if (me && me.stack === 0 && !me.inHand) void ack(s, 'table:topup', { tableId: TABLE_ID, amount: process.env.BOT_RANDOM_BUYIN ? t.minBuyIn + Math.floor(Math.random() * (t.maxBuyIn - t.minBuyIn)) : t.maxBuyIn });
      if (me?.sittingOut) void ack(s, 'table:sitout', { tableId: TABLE_ID, value: false });
      // Run it twice: bot pristaje u 70 % slučajeva.
      if (t.ritPending && t.ritAsk.includes(t.mySeat) && !t.ritYes.includes(t.mySeat)) {
        void ack(s, 'table:rit', { tableId: TABLE_ID, yes: Math.random() < Number(process.env.BOT_RIT ?? 0.7) });
        return;
      }
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
        // Za proveru izgleda all-in-a: BOT_ALLIN=0.3 → bot često ide all-in.
        if (Math.random() < Number(process.env.BOT_ALLIN || 0) && legal.maxRaiseTo !== null) msg = { action: 'raise', amount: legal.maxRaiseTo };
        void ack(s, 'table:act', { tableId: TABLE_ID, ...msg });
      }, 700 + Math.random() * 1500);
    });
    console.log(`${username} sedi za stolom.`);
  }
}

/** Potez bota (nasumično, uglavnom check/call). */
function decide(legal: any) {
  const r = Math.random();
  let msg: any = { action: legal.check ? 'check' : 'call' };
  if (r < 0.15 && !legal.check) msg = { action: 'fold' };
  else if (r > 0.8 && legal.minRaiseTo !== null) msg = { action: 'raise', amount: legal.minRaiseTo };
  if (Math.random() < Number(process.env.BOT_ALLIN || 0) && legal.maxRaiseTo !== null) msg = { action: 'raise', amount: legal.maxRaiseTo };
  return msg;
}

/** Bot na turniru: prijava, igra za dodeljenim stolom, prelazi kad ga premeste. */
function tourBot(s: ReturnType<typeof io>, username: string) {
  let tableId: string | null = null;
  let lastKey = '';
  const register = async () => {
    const r = await ack(s, 'tour:register', { id: TOUR_ID });
    console.log(`${username}: prijava ${r.ok ? 'OK' : r.error}`);
  };
  s.on('tournament:seat', async (m: any) => {
    if (m.tournamentId !== TOUR_ID) return;
    if (tableId && tableId !== m.tableId) await ack(s, 'table:unwatch', { tableId });
    tableId = m.tableId;
    await ack(s, 'table:watch', { tableId });
  });
  s.on('tournament:busted', (m: any) => {
    if (m.tournamentId !== TOUR_ID) return;
    console.log(`${username}: ${m.position}. mesto${m.prize ? `, nagrada ${m.prize}` : ''}`);
    if (m.canReenter && process.env.BOT_REENTRY) setTimeout(register, 500);
  });
  s.on('tournament:rebuy', (m: any) => {
    if (m.tournamentId === TOUR_ID && process.env.BOT_REBUY) void ack(s, 'tour:rebuy', { id: TOUR_ID }).then((r) => console.log(`${username}: rebuy ${r.ok ? 'OK' : r.error}`));
  });
  s.on('table:state', (t: any) => {
    if (t.id !== tableId || !t.legal) return;
    const me = t.seats[t.mySeat];
    if (me?.sittingOut) void ack(s, 'table:sitout', { tableId, value: false });
    const key = `${t.handNo}:${t.street}:${t.pot}`;
    if (key === lastKey) return;
    lastKey = key;
    const legal = t.legal;
    setTimeout(() => void ack(s, 'table:act', { tableId: t.id, ...decide(legal) }), 300 + Math.random() * 700);
  });
  void register();
}

main().catch((e) => {
  console.error(e.message);
  process.exit(1);
});
