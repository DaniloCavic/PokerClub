import { useEffect, useState } from 'react';
import { api, fmt, fmtDate, Me, VARIANT_LABELS } from '../api';
import { Cards, Drawer, Pager, useLoad } from './common';

interface TableForm {
  name: string;
  variant: 'HOLDEM' | 'OMAHA';
  smallBlind: number;
  bigBlind: number;
  minBuyIn: number;
  maxBuyIn: number;
  maxSeats: number;
  rakePercent: number;
  rakeCap: number;
  actionSeconds: number;
}

const EMPTY: TableForm = {
  name: '',
  variant: 'HOLDEM',
  smallBlind: 5,
  bigBlind: 10,
  minBuyIn: 400,
  maxBuyIn: 2000,
  maxSeats: 6,
  rakePercent: 5,
  rakeCap: 50,
  actionSeconds: 20,
};

export function Tables({ me }: { me: Me }) {
  const { data, error, reload } = useLoad<any[]>(() => api('GET', '/admin/tables'));
  const [editing, setEditing] = useState<{ id?: string; form: TableForm } | null>(null);
  const [openId, setOpenId] = useState<string | null>(null);

  useEffect(() => {
    const t = setInterval(reload, 5000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  return (
    <>
      <div className="row">
        <h2 className="grow">Stolovi</h2>
        <button onClick={() => setEditing({ form: { ...EMPTY } })}>+ Novi sto</button>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Naziv</th>
              <th>Igra</th>
              <th>Blajndovi</th>
              <th>Ulaz</th>
              <th>Rake</th>
              <th>Igrači</th>
              <th>Rake ukupno</th>
              {me.role === 'ADMIN' && <th>Agent</th>}
              <th>Stanje</th>
            </tr>
          </thead>
          <tbody>
            {data?.map((t) => (
              <tr key={t.id} className="clickable" onClick={() => setOpenId(t.id)}>
                <td>
                  <b>{t.name}</b>
                </td>
                <td>{t.variant === 'HOLDEM' ? "Hold'em" : 'Omaha'}</td>
                <td>
                  {fmt(t.smallBlind)}/{fmt(t.bigBlind)}
                </td>
                <td>
                  {fmt(t.minBuyIn)}–{fmt(t.maxBuyIn)}
                </td>
                <td>
                  {t.rakePercent}%{t.rakeCap ? ` (max ${fmt(t.rakeCap)})` : ''}
                </td>
                <td>
                  {t.live ? t.live.seats.length : 0}/{t.maxSeats}
                </td>
                <td>{fmt(t.rakeTotal)}</td>
                {me.role === 'ADMIN' && <td>{t.createdBy}</td>}
                <td>
                  {t.live?.closing ? (
                    <span className="badge">Zatvara se</span>
                  ) : t.isOpen ? (
                    <span className="badge green">Otvoren</span>
                  ) : (
                    <span className="badge red">Zatvoren</span>
                  )}
                </td>
              </tr>
            ))}
            {data?.length === 0 && (
              <tr>
                <td colSpan={9} className="muted">
                  Još nema stolova. Napravite prvi sto.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>

      {editing && (
        <TableEditor
          id={editing.id}
          initial={editing.form}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            reload();
          }}
        />
      )}
      {openId && (
        <TableDetails
          id={openId}
          onClose={() => {
            setOpenId(null);
            reload();
          }}
          onEdit={(t) => {
            setOpenId(null);
            setEditing({
              id: t.id,
              form: Object.fromEntries(Object.keys(EMPTY).map((k) => [k, t[k]])) as unknown as TableForm,
            });
          }}
        />
      )}
    </>
  );
}

function TableEditor({ id, initial, onClose, onSaved }: { id?: string; initial: TableForm; onClose: () => void; onSaved: () => void }) {
  const [f, setF] = useState<TableForm>(initial);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const num = (k: keyof TableForm) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: Number(e.target.value) });

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      await api(id ? 'PATCH' : 'POST', id ? `/admin/tables/${id}` : '/admin/tables', f);
      onSaved();
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Drawer onClose={onClose}>
      <h2>{id ? 'Izmena stola' : 'Novi sto'}</h2>
      <form className="card" onSubmit={save}>
        <div className="form-grid">
          <label>
            Naziv
            <input value={f.name} onChange={(e) => setF({ ...f, name: e.target.value })} placeholder="npr. NL 5/10" autoFocus />
          </label>
          <label>
            Igra
            <select value={f.variant} onChange={(e) => setF({ ...f, variant: e.target.value as TableForm['variant'] })}>
              <option value="HOLDEM">{VARIANT_LABELS.HOLDEM}</option>
              <option value="OMAHA">{VARIANT_LABELS.OMAHA}</option>
            </select>
          </label>
          <label>
            Mali blajnd
            <input type="number" min={1} value={f.smallBlind} onChange={num('smallBlind')} />
          </label>
          <label>
            Veliki blajnd
            <input type="number" min={2} value={f.bigBlind} onChange={num('bigBlind')} />
          </label>
          <label>
            Najmanji ulaz
            <input type="number" min={1} value={f.minBuyIn} onChange={num('minBuyIn')} />
          </label>
          <label>
            Najveći ulaz
            <input type="number" min={1} value={f.maxBuyIn} onChange={num('maxBuyIn')} />
          </label>
          <label>
            Broj mesta (2–9)
            <input type="number" min={2} max={9} value={f.maxSeats} onChange={num('maxSeats')} />
          </label>
          <label>
            Vreme za potez (sekunde)
            <input type="number" min={10} max={120} value={f.actionSeconds} onChange={num('actionSeconds')} />
          </label>
          <label>
            Rake (%)
            <input type="number" min={0} max={10} step={0.5} value={f.rakePercent} onChange={num('rakePercent')} />
          </label>
          <label>
            Najviše rake-a po ruci (0 = bez ograničenja)
            <input type="number" min={0} value={f.rakeCap} onChange={num('rakeCap')} />
          </label>
        </div>
        <p className="muted small">
          Rake se uzima samo kad se podeli flop. {f.rakePercent > 0 && `Primer: pot od 1.000 → rake ${Math.min(Math.floor(1000 * f.rakePercent / 100), f.rakeCap || Infinity)}.`}
        </p>
        {error && <div className="error">{error}</div>}
        <div className="row">
          <button disabled={busy || f.name.trim().length < 2}>{id ? 'Sačuvaj' : 'Napravi sto'}</button>
          <button type="button" className="secondary" onClick={onClose}>
            Otkaži
          </button>
        </div>
      </form>
    </Drawer>
  );
}

function TableDetails({ id, onClose, onEdit }: { id: string; onClose: () => void; onEdit: (t: any) => void }) {
  const [page, setPage] = useState(1);
  const { data, error, reload } = useLoad<any>(() => api('GET', `/admin/tables/${id}?page=${page}`), [id, page]);
  const [msg, setMsg] = useState('');
  const [handId, setHandId] = useState<string | null>(null);

  useEffect(() => {
    const t = setInterval(reload, 4000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  async function run(fn: () => Promise<unknown>, ok: string) {
    setMsg('');
    try {
      await fn();
      setMsg(ok);
      reload();
    } catch (e) {
      setMsg((e as Error).message);
    }
  }

  if (error) return <Drawer onClose={onClose}><div className="error">{error}</div></Drawer>;
  if (!data) return <Drawer onClose={onClose}><div className="muted">Učitavanje…</div></Drawer>;
  const t = data.table;

  return (
    <Drawer onClose={onClose}>
      <h2>{t.name}</h2>
      <div className="card">
        <div className="kv">
          <span>Igra</span>
          <b>{VARIANT_LABELS[t.variant]}</b>
          <span>Blajndovi</span>
          <b>
            {fmt(t.smallBlind)}/{fmt(t.bigBlind)}
          </b>
          <span>Ulaz</span>
          <b>
            {fmt(t.minBuyIn)} – {fmt(t.maxBuyIn)}
          </b>
          <span>Mesta</span>
          <b>{t.maxSeats}</b>
          <span>Rake</span>
          <b>
            {t.rakePercent}% {t.rakeCap ? `(najviše ${fmt(t.rakeCap)} po ruci)` : '(bez ograničenja)'}
          </b>
          <span>Vreme za potez</span>
          <b>{t.actionSeconds} s</b>
          <span>Rake ukupno</span>
          <b>{fmt(t.rakeTotal)}</b>
          <span>Napravio</span>
          <b>
            {t.createdBy}, {fmtDate(t.createdAt)}
          </b>
        </div>
        <div className="row" style={{ marginTop: 12 }}>
          {t.isOpen ? (
            <button
              className="danger"
              onClick={() =>
                confirm('Zatvoriti sto? Igrači ustaju posle ruke u toku i žetoni im se vraćaju na nalog.') &&
                run(() => api('POST', `/admin/tables/${id}/close`), 'Sto je zatvoren.')
              }
            >
              Zatvori sto
            </button>
          ) : (
            <>
              <button className="ok" onClick={() => run(() => api('POST', `/admin/tables/${id}/open`), 'Sto je otvoren.')}>
                Otvori sto
              </button>
              {!t.live && (
                <button className="secondary" onClick={() => onEdit(t)}>
                  Izmeni podešavanja
                </button>
              )}
            </>
          )}
        </div>
        {t.isOpen && <p className="muted small">Podešavanja se menjaju kad je sto zatvoren.</p>}
        {msg && <div className="muted">{msg}</div>}
      </div>

      <h3>Za stolom {t.live && `· ruka #${t.live.handNo}${t.live.inProgress ? ' u toku' : ''}`}</h3>
      <div className="card">
        {!t.live || t.live.seats.length === 0 ? (
          <div className="muted">Niko ne sedi za stolom.</div>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Mesto</th>
                <th>Igrač</th>
                <th>Žetoni</th>
                <th>Stanje</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {t.live.seats.map((s: any) => (
                <tr key={s.userId}>
                  <td>{s.seat + 1}</td>
                  <td>{s.name}</td>
                  <td>{fmt(s.stack)}</td>
                  <td>{s.leaving ? 'Ustaje posle ruke' : s.sittingOut ? 'Ne igra (sit out)' : s.stack === 0 ? 'Bez žetona' : 'Igra'}</td>
                  <td>
                    <button
                      className="secondary"
                      disabled={s.leaving}
                      onClick={() =>
                        run(() => api('POST', `/admin/players/${s.userId}/kick`, { tableId: id }), `${s.name} ustaje sa stola.`)
                      }
                    >
                      Podigni sa stola
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <h3>Odigrane ruke ({fmt(data.hands.total)})</h3>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>#</th>
              <th>Vreme</th>
              <th>Sto</th>
              <th>Pot</th>
              <th>Rake</th>
            </tr>
          </thead>
          <tbody>
            {data.hands.items.map((h: any) => (
              <tr key={h.id} className="clickable" onClick={() => setHandId(h.id)}>
                <td>{h.handNo}</td>
                <td>{fmtDate(h.createdAt)}</td>
                <td>
                  <Cards cards={h.board} />
                </td>
                <td>{fmt(h.pot)}</td>
                <td>{fmt(h.rake)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <Pager page={page} total={data.hands.total} pageSize={data.hands.pageSize} onPage={setPage} />
      </div>
      {handId && <HandView id={handId} onClose={() => setHandId(null)} />}
    </Drawer>
  );
}

function HandView({ id, onClose }: { id: string; onClose: () => void }) {
  const { data, error } = useLoad<any>(() => api('GET', `/admin/hands/${id}`), [id]);
  return (
    <Drawer onClose={onClose}>
      {error && <div className="error">{error}</div>}
      {data && (
        <>
          <h2>
            {data.table.name} · ruka #{data.handNo}
          </h2>
          <div className="card">
            <div className="kv">
              <span>Vreme</span>
              <b>{fmtDate(data.createdAt)}</b>
              <span>Sto</span>
              <b>
                <Cards cards={data.board} />
              </b>
              <span>Pot</span>
              <b>{fmt(data.pot)}</b>
              <span>Rake</span>
              <b>{fmt(data.rake)}</b>
            </div>
          </div>
          <div className="card">
            <table>
              <thead>
                <tr>
                  <th>Igrač</th>
                  <th>Karte</th>
                  <th>Pre</th>
                  <th>Posle</th>
                  <th>Razlika</th>
                </tr>
              </thead>
              <tbody>
                {data.details.players.map((p: any) => (
                  <tr key={p.seat}>
                    <td>{p.name}</td>
                    <td>
                      <Cards cards={p.cards} />
                    </td>
                    <td>{fmt(p.startStack)}</td>
                    <td>{fmt(p.endStack)}</td>
                    <td className={p.endStack - p.startStack > 0 ? 'plus' : p.endStack < p.startStack ? 'minus' : ''}>
                      {p.endStack - p.startStack > 0 ? '+' : ''}
                      {fmt(p.endStack - p.startStack)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <h3>Tok ruke</h3>
          <div className="card log">
            {data.details.log.map((l: string, i: number) => (
              <div key={i}>{l}</div>
            ))}
          </div>
        </>
      )}
    </Drawer>
  );
}
