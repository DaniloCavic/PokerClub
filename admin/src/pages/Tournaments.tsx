import { useEffect, useMemo, useState } from 'react';
import { api, fmt, Me } from '../api';
import { Drawer, useLoad } from './common';

interface Level {
  sb: number;
  bb: number;
  ante: number;
  minutes: number;
}

interface TourForm {
  name: string;
  variant: 'HOLDEM' | 'OMAHA';
  startAt: string;
  buyIn: number;
  fee: number;
  startingStack: number;
  guarantee: number;
  bounty: number;
  repeat: 'NONE' | 'DAILY' | 'WEEKLY';
  minPlayers: number;
  maxPlayers: number;
  tableSize: number;
  actionSeconds: number;
  levels: Level[];
  breakMode: 'HOURLY' | 'LEVELS' | 'NONE';
  breakEvery: number;
  breakMinutes: number;
  lateRegLevels: number;
  reentryMax: number;
  rebuyLevels: number;
  rebuyMax: number;
  rebuyPrice: number;
  rebuyFee: number;
  rebuyChips: number;
  rebuyBelow: number;
  addonLevel: number;
  addonPrice: number;
  addonFee: number;
  addonChips: number;
  payoutMode: 'PERCENT' | 'FIXED';
  payPercent: number;
  payouts: string;
  estimatedMinutes: number;
}

const pad = (n: number) => String(n).padStart(2, '0');
const localInput = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;

const STATUS: Record<string, { label: string; cls: string }> = {
  REGISTERING: { label: 'Prijave', cls: 'blue' },
  RUNNING: { label: 'U toku', cls: 'green' },
  FINISHED: { label: 'Završen', cls: '' },
  CANCELLED: { label: 'Otkazan', cls: 'red' },
};

const fmtWhen = (iso: string) =>
  new Date(iso).toLocaleString('sr-Latn-RS', { weekday: 'short', day: 'numeric', month: 'numeric', hour: '2-digit', minute: '2-digit' });

const fmtDuration = (m: number) => (m >= 60 ? `${Math.floor(m / 60)} h ${m % 60 ? `${m % 60} min` : ''}` : `${m} min`);

/** Isto kao na serveru: procenti nagrada po mestima. */
function payoutPercents(mode: string, payPercent: number, fixed: number[], entries: number) {
  if (entries <= 0) return [];
  let w: number[];
  if (mode === 'FIXED') {
    w = fixed.filter((x) => x > 0).slice(0, entries);
    if (!w.length) w = [100];
  } else {
    const places = Math.max(1, Math.min(entries, Math.round((entries * payPercent) / 100)));
    w = Array.from({ length: places }, (_, k) => 1 / Math.pow(k + 1, 0.9));
  }
  const sum = w.reduce((a, b) => a + b, 0);
  return w.map((x) => (x / sum) * 100);
}

const parsePayouts = (s: string) =>
  s
    .split(/[,;\s]+/)
    .map((x) => Number(x.replace(',', '.')))
    .filter((x) => x > 0);

export function Tournaments({ me }: { me: Me }) {
  const { data, error, reload } = useLoad<any[]>(() => api('GET', '/admin/tournaments'));
  const [creating, setCreating] = useState(false);
  const [openId, setOpenId] = useState<string | null>(null);
  const isSuper = me.role === 'ADMIN';

  useEffect(() => {
    const t = setInterval(reload, 5000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <>
      <div className="row">
        <h2 className="grow">Turniri</h2>
        {isSuper && <button onClick={() => setCreating(true)}>+ Novi turnir</button>}
      </div>
      {error && <div className="error">{error}</div>}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Naziv</th>
              <th>Igra</th>
              <th>Početak</th>
              <th>Ulaz</th>
              <th>Garancija</th>
              <th>Ulazi</th>
              <th>Nagradni fond</th>
              {isSuper && <th>Fee (klub)</th>}
              <th>Stanje</th>
            </tr>
          </thead>
          <tbody>
            {data?.map((t) => (
              <tr key={t.id} className="clickable" onClick={() => setOpenId(t.id)}>
                <td>
                  <b>{t.name}</b> {t.repeat && t.repeat !== 'NONE' ? <span className="badge blue">{t.repeat === 'DAILY' ? 'svaki dan' : 'svake nedelje'}</span> : null}
                  {t.bounty ? <span className="badge">bounty</span> : null}
                </td>
                <td>{t.variant === 'HOLDEM' ? "Hold'em" : 'Omaha'}</td>
                <td>{fmtWhen(t.startAt)}</td>
                <td>
                  {fmt(t.buyIn)}
                  {t.bounty ? ` + ${fmt(t.bounty)} KO` : ''} + {fmt(t.fee)}
                </td>
                <td>{t.guarantee ? fmt(t.guarantee) : '—'}</td>
                <td>{t.entries}</td>
                <td>{t.status === 'CANCELLED' ? '—' : fmt(t.status === 'FINISHED' ? t.prizePool : Math.max(t.guarantee, t.collected))}</td>
                {isSuper && <td>{fmt(t.fees)}</td>}
                <td>
                  <span className={`badge ${STATUS[t.status]?.cls ?? ''}`}>{STATUS[t.status]?.label ?? t.status}</span>
                </td>
              </tr>
            ))}
            {data?.length === 0 && (
              <tr>
                <td colSpan={9} className="muted">
                  {isSuper ? 'Još nema turnira. Napravite prvi turnir.' : 'Još nema turnira.'}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {creating && (
        <TournamentEditor
          onClose={() => setCreating(false)}
          onSaved={() => {
            setCreating(false);
            reload();
          }}
        />
      )}
      {openId && <TournamentDetail id={openId} isSuper={isSuper} onClose={() => setOpenId(null)} onChanged={reload} />}
    </>
  );
}

function num(v: string) {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function TournamentEditor({ onClose, onSaved }: { onClose: () => void; onSaved: () => void }) {
  const start = new Date(Date.now() + 60 * 60_000);
  start.setMinutes(0, 0, 0);
  const [f, setF] = useState<TourForm>({
    name: '',
    variant: 'HOLDEM',
    startAt: localInput(start),
    buyIn: 1000,
    fee: 100,
    startingStack: 10_000,
    guarantee: 0,
    bounty: 0,
    repeat: 'NONE',
    minPlayers: 2,
    maxPlayers: 0,
    tableSize: 9,
    actionSeconds: 20,
    levels: [],
    breakMode: 'HOURLY',
    breakEvery: 4,
    breakMinutes: 5,
    lateRegLevels: 6,
    reentryMax: 0,
    rebuyLevels: 6,
    rebuyMax: 0,
    rebuyPrice: 1000,
    rebuyFee: 100,
    rebuyChips: 10_000,
    rebuyBelow: 0,
    addonLevel: 6,
    addonPrice: 1000,
    addonFee: 100,
    addonChips: 10_000,
    payoutMode: 'PERCENT',
    payPercent: 15,
    payouts: '50, 30, 20',
    estimatedMinutes: 0,
  });
  const [gen, setGen] = useState({ bb: 100, minutes: 15, count: 20 });
  const [rebuyOn, setRebuyOn] = useState(false);
  const [addonOn, setAddonOn] = useState(false);
  const [preview, setPreview] = useState(30);
  const [estimate, setEstimate] = useState<number | null>(null);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const set = <K extends keyof TourForm>(k: K, v: TourForm[K]) => setF((x) => ({ ...x, [k]: v }));

  async function generate() {
    const r = await api<{ levels: Level[] }>('GET', `/admin/tournaments/defaults?bb=${gen.bb}&minutes=${gen.minutes}&count=${gen.count}`);
    set('levels', r.levels);
  }

  useEffect(() => {
    void generate();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Procena trajanja sa servera (posle svake izmene strukture).
  useEffect(() => {
    if (!f.levels.length) return;
    const t = setTimeout(() => {
      api<{ minutes: number | null }>('POST', '/admin/tournaments/estimate', {
        levels: f.levels,
        breakMode: f.breakMode,
        breakEvery: f.breakEvery,
        breakMinutes: f.breakMinutes,
        players: f.maxPlayers > 0 ? Math.min(f.maxPlayers, preview) : preview,
        startingStack: f.startingStack,
      })
        .then((r) => setEstimate(r.minutes))
        .catch(() => setEstimate(null));
    }, 300);
    return () => clearTimeout(t);
  }, [f.levels, f.breakMode, f.breakEvery, f.breakMinutes, f.startingStack, f.maxPlayers, preview]);

  const pay = useMemo(() => {
    const percents = payoutPercents(f.payoutMode, f.payPercent, parsePayouts(f.payouts), preview);
    const rebuys = rebuyOn ? Math.round(preview * 0.5) : 0;
    const addons = addonOn ? Math.round(preview * 0.6) : 0;
    const pool = Math.max(f.guarantee, f.buyIn * preview + (rebuyOn ? f.rebuyPrice * rebuys : 0) + (addonOn ? f.addonPrice * addons : 0));
    return { percents, pool, rebuys, addons };
  }, [f, preview, rebuyOn, addonOn]);

  const fixedSum = parsePayouts(f.payouts).reduce((a, b) => a + b, 0);

  function setLevel(i: number, k: keyof Level, v: number) {
    set(
      'levels',
      f.levels.map((l, j) => (j === i ? { ...l, [k]: v } : l)),
    );
  }

  async function save() {
    setBusy(true);
    setError('');
    try {
      await api('POST', '/admin/tournaments', {
        ...f,
        startAt: new Date(f.startAt).toISOString(),
        payouts: parsePayouts(f.payouts),
        rebuyLevels: rebuyOn ? f.rebuyLevels : 0,
        addonLevel: addonOn ? f.addonLevel : 0,
      });
      onSaved();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  const n = (k: keyof TourForm, label: string, hint?: string, min = 0) => (
    <label>
      {label}
      <input type="number" min={min} value={f[k] as number} onChange={(e) => set(k, num(e.target.value) as never)} />
      {hint && <small className="muted">{hint}</small>}
    </label>
  );

  return (
    <Drawer onClose={onClose}>
      <h2>Novi turnir</h2>

      <h3>Osnovno</h3>
      <div className="form-grid">
        <label>
          Naziv
          <input value={f.name} onChange={(e) => set('name', e.target.value)} placeholder="npr. Nedeljni turnir" />
        </label>
        <label>
          Igra
          <select value={f.variant} onChange={(e) => set('variant', e.target.value as TourForm['variant'])}>
            <option value="HOLDEM">Texas Hold'em (no-limit)</option>
            <option value="OMAHA">Omaha (pot-limit)</option>
          </select>
        </label>
        <label>
          Početak
          <input type="datetime-local" value={f.startAt} onChange={(e) => set('startAt', e.target.value)} />
        </label>
        <label>
          Ponavljanje
          <select value={f.repeat} onChange={(e) => set('repeat', e.target.value as TourForm['repeat'])}>
            <option value="NONE">Jednom</option>
            <option value="DAILY">Svaki dan u isto vreme</option>
            <option value="WEEKLY">Svake nedelje u isto vreme</option>
          </select>
          <small className="muted">kad turnir počne, sledeći se sam zakaže</small>
        </label>
        {n('tableSize', 'Igrača za stolom', '2–9', 2)}
        {n('actionSeconds', 'Vreme za potez (s)', '10–120', 10)}
        {n('minPlayers', 'Najmanje igrača', 'ako ih je manje, turnir se otkazuje i ulaz vraća', 2)}
        {n('maxPlayers', 'Najviše ulaza', '0 = bez ograničenja')}
      </div>

      <h3>Ulaz i nagradni fond</h3>
      <div className="form-grid">
        {n('buyIn', 'Ulaz — deo za nagrade', 'ide u nagradni fond')}
        {n('fee', 'Fee (rake)', 'zadržava klub')}
        {n('startingStack', 'Početni stek (žetoni)', undefined, 100)}
        {n('guarantee', 'Garantovan fond', '0 = bez garancije; razliku doplaćuje klub')}
        {n('bounty', 'Bounty (knockout)', 'deo ulaza koji dobija ko izbaci igrača; 0 = običan turnir. Igrač plaća ulaz + bounty + fee')}
      </div>

      <h3>Blajndovi</h3>
      <div className="row small">
        <span className="muted">Napravi strukturu: početni BB</span>
        <input style={{ width: 90 }} type="number" value={gen.bb} onChange={(e) => setGen({ ...gen, bb: num(e.target.value) })} />
        <span className="muted">minuta po nivou</span>
        <input style={{ width: 70 }} type="number" value={gen.minutes} onChange={(e) => setGen({ ...gen, minutes: num(e.target.value) })} />
        <span className="muted">nivoa</span>
        <input style={{ width: 70 }} type="number" value={gen.count} onChange={(e) => setGen({ ...gen, count: num(e.target.value) })} />
        <button className="secondary" onClick={generate}>
          Napravi
        </button>
      </div>
      <div className="card" style={{ padding: 8, marginTop: 8, maxHeight: 320, overflow: 'auto' }}>
        <table>
          <thead>
            <tr>
              <th>Nivo</th>
              <th>Mali blajnd</th>
              <th>Veliki blajnd</th>
              <th>Ante</th>
              <th>Minuta</th>
              <th />
            </tr>
          </thead>
          <tbody>
            {f.levels.map((l, i) => (
              <tr key={i}>
                <td>{i + 1}</td>
                {(['sb', 'bb', 'ante', 'minutes'] as const).map((k) => (
                  <td key={k}>
                    <input style={{ width: 90 }} type="number" min={0} value={l[k]} onChange={(e) => setLevel(i, k, num(e.target.value))} />
                  </td>
                ))}
                <td>
                  <button className="secondary" title="Obriši nivo" onClick={() => set('levels', f.levels.filter((_, j) => j !== i))}>
                    ✕
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <button
          className="secondary"
          style={{ marginTop: 8 }}
          onClick={() => {
            const last = f.levels[f.levels.length - 1] ?? { sb: 50, bb: 100, ante: 0, minutes: 15 };
            set('levels', [...f.levels, { sb: last.sb * 2, bb: last.bb * 2, ante: last.ante * 2, minutes: last.minutes }]);
          }}
        >
          + Nivo
        </button>
      </div>

      <h3>Pauze</h3>
      <div className="form-grid">
        <label>
          Kada
          <select value={f.breakMode} onChange={(e) => set('breakMode', e.target.value as TourForm['breakMode'])}>
            <option value="HOURLY">Svakog sata (pred kraj sata)</option>
            <option value="LEVELS">Posle svakih N nivoa</option>
            <option value="NONE">Bez pauza</option>
          </select>
        </label>
        {f.breakMode !== 'NONE' && n('breakMinutes', 'Trajanje pauze (min)', f.breakMode === 'HOURLY' ? `pauza od ${60 - f.breakMinutes}. do 60. minuta svakog sata` : undefined, 1)}
        {f.breakMode === 'LEVELS' && n('breakEvery', 'Posle koliko nivoa', undefined, 1)}
      </div>

      <h3>Kasna prijava i re-entry</h3>
      <div className="form-grid">
        {n('lateRegLevels', 'Kasna prijava do kraja nivoa', '0 = samo pre početka')}
        {n('reentryMax', 'Re-entry (koliko puta)', 'novi ulaz posle ispadanja, tokom kasne prijave; 0 = nema')}
      </div>

      <h3>
        <label className="row" style={{ gap: 8 }}>
          <input type="checkbox" checked={rebuyOn} onChange={(e) => setRebuyOn(e.target.checked)} /> Rebuy
        </label>
      </h3>
      {rebuyOn && (
        <div className="form-grid">
          {n('rebuyLevels', 'Rebuy do kraja nivoa', undefined, 1)}
          {n('rebuyMax', 'Najviše rebuy-eva po ulazu', '0 = bez ograničenja')}
          {n('rebuyPrice', 'Cena (deo za nagrade)')}
          {n('rebuyFee', 'Fee rebuy-a')}
          {n('rebuyChips', 'Žetoni', undefined, 1)}
          {n('rebuyBelow', 'Dozvoljen kad je stek najviše', '0 = tek kad igrač ostane bez žetona')}
        </div>
      )}

      <h3>
        <label className="row" style={{ gap: 8 }}>
          <input type="checkbox" checked={addonOn} onChange={(e) => setAddonOn(e.target.checked)} /> Add-on
        </label>
      </h3>
      {addonOn && (
        <div className="form-grid">
          {n('addonLevel', 'Add-on do kraja nivoa', 'jednom po ulazu, i tokom pauze posle tog nivoa', 1)}
          {n('addonPrice', 'Cena (deo za nagrade)')}
          {n('addonFee', 'Fee add-on-a')}
          {n('addonChips', 'Žetoni', undefined, 1)}
        </div>
      )}

      <h3>Nagrade</h3>
      <div className="form-grid">
        <label>
          Raspodela
          <select value={f.payoutMode} onChange={(e) => set('payoutMode', e.target.value as TourForm['payoutMode'])}>
            <option value="PERCENT">Procenat igrača u nagradama</option>
            <option value="FIXED">Ručno: procenti po mestima</option>
          </select>
        </label>
        {f.payoutMode === 'PERCENT' ? (
          n('payPercent', 'Plaćeno % ulaza', 'npr. 15 = svaki sedmi ulaz je u nagradama', 1)
        ) : (
          <label>
            Procenti po mestima
            <input value={f.payouts} onChange={(e) => set('payouts', e.target.value)} placeholder="50, 30, 20" />
            <small className={Math.abs(fixedSum - 100) > 0.01 ? 'error' : 'muted'}>Zbir: {Math.round(fixedSum * 100) / 100} % (mora biti 100 %)</small>
          </label>
        )}
        <label>
          Pregled za broj ulaza
          <input type="number" min={2} value={preview} onChange={(e) => setPreview(Math.max(2, num(e.target.value)))} />
        </label>
      </div>
      <div className="card" style={{ padding: 10, marginTop: 8 }}>
        <div className="small muted">
          Za {preview} ulaza{pay.rebuys ? `, ~${pay.rebuys} rebuy-eva` : ''}
          {pay.addons ? `, ~${pay.addons} add-on-a` : ''}: fond <b>{fmt(pay.pool)}</b>, klub zadržava ~{fmt(f.fee * preview + (rebuyOn ? f.rebuyFee * pay.rebuys : 0) + (addonOn ? f.addonFee * pay.addons : 0))}.
        </div>
        <table>
          <thead>
            <tr>
              <th>Mesto</th>
              <th>%</th>
              <th>Nagrada</th>
            </tr>
          </thead>
          <tbody>
            {pay.percents.map((p, k) => (
              <tr key={k}>
                <td>{k + 1}.</td>
                <td>{Math.round(p * 10) / 10} %</td>
                <td>{fmt(Math.floor((pay.pool * p) / 100))}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <h3>Trajanje</h3>
      <div className="form-grid">
        <label>
          Procena (iz strukture)
          <input disabled value={estimate ? `oko ${fmtDuration(estimate)}` : '—'} />
          <small className="muted">za {preview} igrača, sa pauzama</small>
        </label>
        {n('estimatedMinutes', 'Vaša procena (min)', '0 = koristi se procena iz strukture')}
      </div>

      {error && <div className="error">{error}</div>}
      <div className="row" style={{ marginTop: 16 }}>
        <button disabled={busy || f.name.trim().length < 2 || !f.levels.length} onClick={save}>
          Napravi turnir
        </button>
        <button className="secondary" onClick={onClose}>
          Otkaži
        </button>
      </div>
    </Drawer>
  );
}

function TournamentDetail({ id, isSuper, onClose, onChanged }: { id: string; isSuper: boolean; onClose: () => void; onChanged: () => void }) {
  const { data: t, error, reload } = useLoad<any>(() => api('GET', `/admin/tournaments/${id}`), [id]);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');

  useEffect(() => {
    const x = setInterval(reload, 4000);
    return () => clearInterval(x);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function cancel() {
    if (!window.confirm('Otkazati turnir? Svim igračima se vraća ceo ulaz (i rebuy/add-on).')) return;
    setBusy(true);
    try {
      await api('POST', `/admin/tournaments/${id}/cancel`);
      setMsg('Turnir je otkazan, svim igračima je vraćen ulaz.');
      reload();
      onChanged();
    } catch (e) {
      setMsg((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Drawer onClose={onClose}>
      {error && <div className="error">{error}</div>}
      {t && (
        <>
          <h2>
            {t.name} <span className={`badge ${STATUS[t.status]?.cls ?? ''}`}>{STATUS[t.status]?.label}</span>
          </h2>
          <div className="kv">
            <span>Igra</span>
            <b>{t.variant === 'HOLDEM' ? "Texas Hold'em" : 'Omaha'}</b>
            <span>Početak</span>
            <b>{fmtWhen(t.startAt)}</b>
            <span>Ulaz</span>
            <b>
              {fmt(t.buyIn)}
              {t.bounty ? ` + ${fmt(t.bounty)} bounty` : ''} + {fmt(t.fee)} fee
            </b>
            <span>Početni stek</span>
            <b>{fmt(t.startingStack)}</b>
            <span>Ulazi / u igri</span>
            <b>
              {t.entries} / {t.playersLeft}
            </b>
            <span>Nagradni fond</span>
            <b>
              {fmt(t.prizePool)}
              {t.guarantee ? ` (garancija ${fmt(t.guarantee)})` : ''}
            </b>
            {t.level && (
              <>
                <span>Nivo</span>
                <b>
                  {t.level} — {fmt(t.smallBlind)}/{fmt(t.bigBlind)}
                  {t.onBreak ? ' (pauza)' : ''}
                </b>
              </>
            )}
            {t.estimatedMinutes ? (
              <>
                <span>Procena trajanja</span>
                <b>oko {fmtDuration(t.estimatedMinutes)}</b>
              </>
            ) : null}
          </div>
          {msg && <div className="success">{msg}</div>}
          {isSuper && (t.status === 'REGISTERING' || t.status === 'RUNNING') && (
            <div className="row" style={{ marginTop: 12 }}>
              <button className="danger" disabled={busy} onClick={cancel}>
                Otkaži turnir i vrati ulaze
              </button>
              {t.repeat && t.repeat !== 'NONE' && t.status === 'REGISTERING' && (
                <button
                  className="secondary"
                  disabled={busy}
                  onClick={async () => {
                    await api('POST', `/admin/tournaments/${id}/stop-repeat`);
                    setMsg('Ponavljanje je zaustavljeno: posle ovog turnira se neće zakazati sledeći.');
                    reload();
                  }}
                >
                  Zaustavi ponavljanje
                </button>
              )}
            </div>
          )}

          <h3>Rang lista</h3>
          <div className="card" style={{ padding: 8 }}>
            <table>
              <thead>
                <tr>
                  <th>Mesto</th>
                  <th>Igrač</th>
                  <th>Žetoni</th>
                  {t.bounty ? <th>KO / bounty</th> : null}
                  <th>Nagrada</th>
                </tr>
              </thead>
              <tbody>
                {(t.standings ?? []).map((s: any) => (
                  <tr key={s.entryId}>
                    <td>{s.position}.</td>
                    <td>
                      {s.name} {s.status === 'BUSTED' && t.status === 'RUNNING' ? <span className="badge red">ispao</span> : null}
                    </td>
                    <td>{s.status === 'PLAYING' ? fmt(s.chips) : '—'}</td>
                    {t.bounty ? <td>{s.knockouts ?? 0} / {fmt(s.bountyWon ?? 0)}</td> : null}
                    <td>{s.prize ? fmt(s.prize) : '—'}</td>
                  </tr>
                ))}
                {!t.standings?.length && (
                  <tr>
                    <td colSpan={4} className="muted">
                      Još nema prijavljenih igrača.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          <h3>Nagrade</h3>
          <div className="card" style={{ padding: 8 }}>
            <table>
              <thead>
                <tr>
                  <th>Mesto</th>
                  <th>%</th>
                  <th>Nagrada</th>
                </tr>
              </thead>
              <tbody>
                {(t.payouts ?? []).map((p: any) => (
                  <tr key={p.place}>
                    <td>{p.place}.</td>
                    <td>{p.percent} %</td>
                    <td>{fmt(p.amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <h3>Struktura blajndova</h3>
          <div className="card" style={{ padding: 8 }}>
            <table>
              <thead>
                <tr>
                  <th>Nivo</th>
                  <th>Blajndovi</th>
                  <th>Ante</th>
                  <th>Minuta</th>
                </tr>
              </thead>
              <tbody>
                {(t.levels ?? []).map((l: Level, i: number) => (
                  <tr key={i} style={t.level === i + 1 ? { background: '#fff7dd' } : undefined}>
                    <td>{i + 1}</td>
                    <td>
                      {fmt(l.sb)}/{fmt(l.bb)}
                    </td>
                    <td>{l.ante ? fmt(l.ante) : '—'}</td>
                    <td>{l.minutes}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </Drawer>
  );
}
