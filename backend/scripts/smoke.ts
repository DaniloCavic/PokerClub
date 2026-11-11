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
  /** Stolovi za kojima bot ne igra sam (test ih vodi ručno). */
  manual: Set<string>;
}

function emit(s: Socket, ev: string, data?: unknown): Promise<any> {
  return new Promise((resolve) => s.emit(ev, data, resolve));
}

async function connect(name: string, id: string, token: string): Promise<Bot> {
  const socket = io(API, { auth: { token }, transports: ['websocket'] });
  const bot: Bot = { name, id, token, socket, state: {}, manual: new Set() };
  await new Promise<void>((resolve, reject) => {
    socket.on('session', () => resolve());
    socket.on('auth:error', (e) => reject(new Error(e.error)));
  });
  socket.on('table:state', (st) => {
    bot.state[st.id] = st;
    if (bot.manual.has(st.id)) return;
    // Run it twice: nasumičan odgovor.
    if (st.ritPending && st.ritAsk.includes(st.mySeat) && !st.ritYes.includes(st.mySeat)) {
      void emit(socket, 'table:rit', { tableId: st.id, yes: Math.random() < 0.7 });
      return;
    }
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
  await call('POST', '/admin/agents', admin, { username: agentName, displayName: 'Agent Proba', password: 'lozinka1', rakePercent: 30 });
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
  await call('POST', '/admin/tables', agent, {
    name: 'zabranjen', variant: 'HOLDEM', smallBlind: 5, bigBlind: 10, minBuyIn: 200, maxBuyIn: 1000,
    maxSeats: 6, rakePercent: 5, rakeCap: 20, actionSeconds: 10,
  }).then(
    () => assert(false, 'agent ne sme da pravi stolove'),
    (e) => assert(/403/.test(e.message), 'samo super agent pravi stolove'),
  );
  const scheduled = await call('POST', '/admin/tables', admin, {
    name: `Zakazan ${suffix}`, variant: 'HOLDEM', smallBlind: 5, bigBlind: 10, minBuyIn: 200, maxBuyIn: 1000,
    maxSeats: 9, rakePercent: 5, rakeCap: 20, actionSeconds: 10, opensAt: new Date(Date.now() + 86_400_000).toISOString(),
  });
  const holdem = await call('POST', '/admin/tables', admin, {
    name: `NL ${suffix}`, variant: 'HOLDEM', smallBlind: 5, bigBlind: 10, minBuyIn: 200, maxBuyIn: 1000,
    maxSeats: 6, rakePercent: 5, rakeCap: 20, actionSeconds: 10, straddle: true,
  });
  // Mali sto za dva igrača: svaka ruka je bomb pot, bez rake-a (za proveru liste čekanja).
  const mini = await call('POST', '/admin/tables', admin, {
    name: `Mini ${suffix}`, variant: 'HOLDEM', smallBlind: 5, bigBlind: 10, minBuyIn: 200, maxBuyIn: 1000,
    maxSeats: 2, rakePercent: 0, rakeCap: 0, actionSeconds: 10, bombPotEvery: 1, bombPotBB: 3,
  });
  assert(holdem.straddle === true && mini.bombPotEvery === 1 && mini.bombPotBB === 3, 'straddle i bomb pot se čuvaju uz sto');
  const omaha = await call('POST', '/admin/tables', admin, {
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
  const early = await emit(bots[3].socket, 'table:sit', { tableId: scheduled.id, seat: 0, buyIn: 500 });
  assert(!early.ok && /otvara/.test(early.error), `zakazan sto se ne može koristiti pre vremena (${early.error})`);
  const bad = await emit(bots[3].socket, 'table:sit', { tableId: omaha.id, seat: 0, buyIn: 800 });
  assert(!bad.ok && /zauzeto/.test(bad.error), 'zauzeto mesto se odbija');
  console.log('Chat');
  const heard = new Promise<any>((r) => bots[1].socket.once('table:chat', r));
  const sent = await emit(bots[0].socket, 'table:chat', { tableId: holdem.id, text: '  Srećno   svima! ' });
  const heardMsg = await heard;
  assert(sent.ok && heardMsg.message.text === 'Srećno svima!', 'poruka u chatu stiže drugim igračima za stolom');
  const tooFast = await emit(bots[0].socket, 'table:chat', { tableId: holdem.id, text: 'opet' });
  assert(!tooFast.ok, 'prebrze poruke se odbijaju');
  const rewatch = await emit(bots[2].socket, 'table:watch', { tableId: holdem.id });
  assert(rewatch.chat.some((m: any) => m.text === 'Srećno svima!'), 'ko otvori sto vidi skorašnje poruke');

  const peek = bots[0].state[holdem.id];
  if (peek?.inProgress) {
    const others = peek.seats.filter((s: any) => s && s.index !== peek.mySeat);
    assert(others.every((s: any) => s.cards === null), 'tuđe karte se ne vide');
  }

  console.log('Live igra (super agent)');
  await call('GET', `/admin/tables/${holdem.id}/live`, agent).then(
    () => assert(false, 'agent ne sme da vidi karte uživo'),
    (e) => assert(/403/.test(e.message), 'samo super agent vidi karte uživo'),
  );
  let liveOk = false;
  // Botovi igraju trenutno, pa ruku hvatamo čestim proveravanjem.
  for (let k = 0; k < 800 && !liveOk; k++) {
    const live = await call('GET', `/admin/tables/${holdem.id}/live`, admin);
    const inHand = (live.state?.seats ?? []).filter((s: any) => s && s.inHand);
    if (live.live && live.state.inProgress && inHand.length >= 2) {
      assert(inHand.every((s: any) => s.cards?.length === 2), `super agent vidi karte svih ${inHand.length} igrača u ruci`);
      liveOk = true;
    } else await sleep(20); // botovi u testu odigraju ruku za delić sekunde
  }
  assert(liveOk, 'karte uživo su dostupne tokom ruke');
  const mine = bots[0].state[holdem.id];
  assert(
    !mine || mine.seats.filter((s: any) => s && s.index !== mine.mySeat && mine.inProgress).every((s: any) => s.cards === null),
    'igrači i dalje ne vide tuđe karte',
  );
  const liveLog = await call('GET', '/admin/live-log', admin);
  assert(liveLog.length > 0, 'otvaranje karata uživo je zabeleženo (samo za super agenta)');

  console.log('Straddle, run it twice, lista čekanja, beleške');
  for (const b of bots) {
    const r = await emit(b.socket, 'table:prefs', { tableId: holdem.id, straddle: true });
    assert(r.ok, `${b.name} uključuje straddle`);
  }
  const noStraddle = await emit(bots[0].socket, 'table:sit', { tableId: mini.id, seat: 0, buyIn: 300 });
  assert(noStraddle.ok, 'sedanje za mali sto');
  const refused = await emit(bots[0].socket, 'table:prefs', { tableId: mini.id, straddle: true });
  assert(!refused.ok, 'straddle se odbija za stolom koji ga ne dozvoljava');
  assert((await emit(bots[1].socket, 'table:sit', { tableId: mini.id, seat: 1, buyIn: 300 })).ok, 'drugi igrač seda, sto je pun');
  const joined = await emit(bots[2].socket, 'table:waitlist', { tableId: mini.id, join: true });
  assert(joined.ok && joined.position === 1, 'igrač je prvi na listi čekanja');
  const w3 = await emit(bots[3].socket, 'table:waitlist', { tableId: mini.id, join: true });
  assert(w3.ok && w3.position === 2, 'drugi igrač je drugi na listi čekanja');
  const lobbyNow = await emit(bots[0].socket, 'lobby:join');
  assert(lobbyNow.tables.find((t: any) => t.id === mini.id).waiting === 2, 'lobi pokazuje koliko igrača čeka');
  const offer = new Promise<any>((r) => bots[2].socket.once('waitlist:offer', r));
  await emit(bots[1].socket, 'table:leave', { tableId: mini.id });
  const offered = await Promise.race([offer, sleep(15000).then(() => null)]);
  assert(offered?.tableId === mini.id, 'prvi sa liste dobija ponudu kad se mesto oslobodi');
  // Igrač 3 je odjavljen sa liste kad sedne igrač 2; pre toga mesto je rezervisano.
  await emit(bots[3].socket, 'table:waitlist', { tableId: mini.id, join: false });
  const stolen = await emit(bots[3].socket, 'table:sit', { tableId: mini.id, seat: 1, buyIn: 300 });
  assert(!stolen.ok && /rezervisano/.test(stolen.error), 'rezervisano mesto ne može da zauzme neko drugi');
  assert((await emit(bots[2].socket, 'table:sit', { tableId: mini.id, seat: 1, buyIn: 300 })).ok, 'igrač sa liste seda na rezervisano mesto');

  const note = await call('POST', `/me/notes/${players[1].id}`, bots[0].token, { text: 'Bluffuje mnogo' });
  assert(note.text === 'Bluffuje mnogo', 'beleška o igraču je sačuvana');
  const myNotes = await call('GET', '/me/notes', bots[0].token);
  const otherNotes = await call('GET', '/me/notes', bots[1].token);
  assert(myNotes[players[1].id] === 'Bluffuje mnogo' && Object.keys(otherNotes).length === 0, 'belešku vidi samo onaj ko ju je napisao');
  await call('POST', `/me/notes/${players[1].id}`, bots[0].token, { text: '  ' });
  assert(!(await call('GET', '/me/notes', bots[0].token))[players[1].id], 'prazna beleška se briše');

  // Run it twice: dva igrača idu all-in, oba pristaju → karte se dele dva puta.
  const ritTable = await call('POST', '/admin/tables', admin, {
    name: `RIT ${suffix}`, variant: 'HOLDEM', smallBlind: 5, bigBlind: 10, minBuyIn: 200, maxBuyIn: 1000,
    maxSeats: 2, rakePercent: 0, rakeCap: 0, actionSeconds: 10,
  });
  const [ra, rb] = [bots[2], bots[3]];
  ra.manual.add(ritTable.id);
  rb.manual.add(ritTable.id);
  assert((await emit(ra.socket, 'table:sit', { tableId: ritTable.id, seat: 0, buyIn: 300 })).ok, 'prvi igrač seda za sto za run it twice');
  assert((await emit(rb.socket, 'table:sit', { tableId: ritTable.id, seat: 1, buyIn: 300 })).ok, 'drugi igrač seda za sto za run it twice');
  const waitFor = async (pred: () => boolean, ms = 15000) => {
    for (let t = 0; t < ms && !pred(); t += 100) await sleep(100);
    return pred();
  };
  const rs = () => ra.state[ritTable.id];
  assert(await waitFor(() => rs()?.inProgress && rs()?.toAct >= 0), 'ruka za run it twice je počela');
  const first = rs().toAct === rs().mySeat ? ra : rb;
  const second = first === ra ? rb : ra;
  const legalFirst = first.state[ritTable.id].legal;
  assert((await emit(first.socket, 'table:act', { tableId: ritTable.id, action: 'raise', amount: legalFirst.maxRaiseTo })).ok, 'all-in');
  assert(await waitFor(() => second.state[ritTable.id]?.legal?.call > 0), 'drugi igrač je na potezu');
  assert((await emit(second.socket, 'table:act', { tableId: ritTable.id, action: 'call' })).ok, 'call all-in');
  assert(await waitFor(() => rs()?.ritPending === true), 'posle all-in-a ruka staje i pita za run it twice');
  assert(rs().ritAsk.length === 2 && rs().ritDeadline > Date.now(), 'pitaju se oba igrača, sa rokom za odluku');
  assert((await emit(ra.socket, 'table:rit', { tableId: ritTable.id, yes: true })).ok, 'prvi igrač pristaje');
  assert((await emit(rb.socket, 'table:rit', { tableId: ritTable.id, yes: true })).ok, 'drugi igrač pristaje');
  assert(await waitFor(() => !!rs()?.result), 'ruka je završena');
  assert(rs().result.board2?.length === 5 && rs().result.pots.some((p: any) => p.run === 2), 'karte su podeljene dva puta, pot na pola');
  ra.manual.delete(ritTable.id);
  rb.manual.delete(ritTable.id);

  await sleep(Number(process.env.PLAY_MS || 25000));

  const handTypes = async (tableId: string) => {
    const list = (await call('GET', `/admin/tables/${tableId}`, admin)).hands.items.slice(0, 15);
    const out: string[] = [];
    for (const h of list) out.push(...((await call('GET', `/admin/hands/${h.id}`, admin)).details.actions ?? []).map((a: any) => a.type));
    return out;
  };
  assert((await handTypes(mini.id)).includes('bomb'), 'bomb pot je odigran za malim stolom');
  assert((await handTypes(holdem.id)).includes('straddle'), 'straddle je odigran');
  const st = await call('GET', '/me/stats', bots[0].token);
  assert(st.hands > 0 && st.won <= st.hands && st.winRate >= 0 && st.winRate <= 100, `statistika igrača: ${st.hands} ruku, ${st.won} dobijenih`);
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
  await call('POST', `/admin/tables/${holdem.id}/close`, admin);
  await call('POST', `/admin/tables/${omaha.id}/close`, admin);
  await call('POST', `/admin/tables/${scheduled.id}/close`, admin);
  await call('POST', `/admin/tables/${mini.id}/close`, admin);
  await call('POST', `/admin/tables/${ritTable.id}/close`, admin);
  for (let k = 0; k < 30; k++) {
    const t = await call('GET', '/admin/tables', agent);
    if (t.filter((x: any) => x.live).length === 0) break;
    await sleep(1000);
  }
  const stats = await call('GET', '/admin/stats', agent);
  assert(stats.chipsOnTables === 0, 'posle zatvaranja nema žetona na stolovima');
  const ourTables = (await call('GET', '/admin/tables', admin)).filter((t: any) => [holdem.id, omaha.id].includes(t.id));
  const totalRake = ourTables.reduce((s: number, t: any) => s + t.rakeTotal, 0);
  assert(totalRake > 0, `odigrano je ruku sa rake-om: ${totalRake}`);
  assert(
    stats.rakeSharePercent === undefined && stats.playersRakeTotal === undefined && stats.rakeTotal === undefined,
    'agent ne vidi svoj procenat ni ukupan rake',
  );
  const agentPlayers = (await call('GET', '/admin/players', agent)).items;
  assert(
    agentPlayers.every((p: any) => p.rakePaid === undefined && typeof p.myEarning === 'number'),
    'agent po igraču vidi samo svoju zaradu',
  );
  assert(
    agentPlayers.reduce((s: number, p: any) => s + p.myEarning, 0) === stats.myCutTotal,
    'zbir zarade po igračima = ukupna zarada agenta',
  );
  // Deo agenta se zaokružuje na ceo dinar po igraču i ruci, pa zbir može malo da odstupa od tačnih 30 %.
  assert(
    Math.abs(stats.myCutTotal - totalRake * 0.3) <= Math.max(3, totalRake * 0.08),
    `agent dobija 30 % rake-a svojih igrača: ${stats.myCutTotal} od ${totalRake}`,
  );
  const agentsList = await call('GET', '/admin/agents', admin);
  const me = agentsList.find((a: any) => a.username === agentName);
  assert(me.agentCut + me.superShare === me.playersRake, `super agentu ostaje ostatak: ${me.superShare}`);
  assert(me.playersRake === totalRake && me.agentCut === stats.myCutTotal, 'super agent vidi rake i deo agenta');
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
