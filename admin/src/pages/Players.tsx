import { useState } from 'react';
import { api, fmt, fmtDate, Me, TX_LABELS } from '../api';
import { Amount, Drawer, Pager, useLoad } from './common';

export function Players({ me }: { me: Me }) {
  const [q, setQ] = useState('');
  const [search, setSearch] = useState('');
  const [page, setPage] = useState(1);
  const { data, error, reload } = useLoad<any>(
    () => api('GET', `/admin/players?page=${page}&q=${encodeURIComponent(search)}`),
    [page, search],
  );
  const [creating, setCreating] = useState(false);
  const [openId, setOpenId] = useState<string | null>(null);

  return (
    <>
      <div className="row">
        <h2 className="grow">Igrači</h2>
        <button onClick={() => setCreating(true)}>+ Novi igrač</button>
      </div>
      <form
        className="row"
        style={{ marginBottom: 12 }}
        onSubmit={(e) => {
          e.preventDefault();
          setPage(1);
          setSearch(q);
        }}
      >
        <input className="grow" placeholder="Pretraga po korisničkom imenu ili imenu" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="secondary">Traži</button>
      </form>
      {error && <div className="error">{error}</div>}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Korisničko ime</th>
              <th>Ime</th>
              <th>Na nalogu</th>
              <th>Na stolovima</th>
              {me.role === 'ADMIN' && <th>Agent</th>}
              <th>Poslednji put</th>
              <th>Stanje</th>
            </tr>
          </thead>
          <tbody>
            {data?.items.map((u: any) => (
              <tr key={u.id} className="clickable" onClick={() => setOpenId(u.id)}>
                <td>
                  <b>{u.username}</b>
                </td>
                <td>{u.displayName}</td>
                <td>{fmt(u.balance)}</td>
                <td>{u.onTables ? fmt(u.onTables) : '—'}</td>
                {me.role === 'ADMIN' && <td>{u.agentName ?? '—'}</td>}
                <td>{fmtDate(u.lastSeenAt)}</td>
                <td>{u.isBlocked ? <span className="badge red">Blokiran</span> : <span className="badge green">Aktivan</span>}</td>
              </tr>
            ))}
            {data?.items.length === 0 && (
              <tr>
                <td colSpan={7} className="muted">
                  Nema igrača.
                </td>
              </tr>
            )}
          </tbody>
        </table>
        {data && <Pager page={page} total={data.total} pageSize={data.pageSize} onPage={setPage} />}
      </div>

      {creating && (
        <CreateAccount
          me={me}
          title="Novi igrač"
          path="/admin/players"
          onClose={() => setCreating(false)}
          onSaved={(u) => {
            setCreating(false);
            reload();
            setOpenId(u.id);
          }}
        />
      )}
      {openId && (
        <PlayerDetails
          me={me}
          id={openId}
          onClose={() => {
            setOpenId(null);
            reload();
          }}
        />
      )}
    </>
  );
}

export function CreateAccount({
  me,
  title,
  path,
  onClose,
  onSaved,
}: {
  me: Me;
  title: string;
  path: string;
  onClose: () => void;
  onSaved: (u: any) => void;
}) {
  const [f, setF] = useState({ username: '', displayName: '', password: '', note: '', agentId: '' });
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const isPlayer = path === '/admin/players';
  const agents = useLoad<any[]>(() => (me.role === 'ADMIN' && isPlayer ? api('GET', '/admin/agents') : Promise.resolve([])));

  async function save(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      onSaved(await api('POST', path, { ...f, agentId: f.agentId || undefined }));
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <Drawer onClose={onClose}>
      <h2>{title}</h2>
      <form className="card" onSubmit={save}>
        <div className="form-grid">
          <label>
            Korisničko ime (za prijavu)
            <input value={f.username} onChange={(e) => setF({ ...f, username: e.target.value })} autoFocus />
          </label>
          <label>
            Ime za prikaz za stolom
            <input value={f.displayName} onChange={(e) => setF({ ...f, displayName: e.target.value })} />
          </label>
          <label>
            Lozinka (bar 6 znakova)
            <input value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} />
          </label>
          {me.role === 'ADMIN' && isPlayer && (
            <label>
              Agent
              <select value={f.agentId} onChange={(e) => setF({ ...f, agentId: e.target.value })}>
                <option value="">— bez agenta —</option>
                {agents.data?.map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.displayName} ({a.username})
                  </option>
                ))}
              </select>
            </label>
          )}
        </div>
        <label className="block">
          Beleška (vidi samo agent)
          <textarea value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} rows={2} />
        </label>
        <p className="muted small">Lozinku zapišite i predajte korisniku — kasnije je možete samo promeniti, ne i videti.</p>
        {error && <div className="error">{error}</div>}
        <div className="row">
          <button disabled={busy}>Napravi nalog</button>
          <button type="button" className="secondary" onClick={onClose}>
            Otkaži
          </button>
        </div>
      </form>
    </Drawer>
  );
}

function PlayerDetails({ me, id, onClose }: { me: Me; id: string; onClose: () => void }) {
  const [page, setPage] = useState(1);
  const { data, error, reload } = useLoad<any>(() => api('GET', `/admin/players/${id}?page=${page}`), [id, page]);
  const agents = useLoad<any[]>(() => (me.role === 'ADMIN' ? api('GET', '/admin/agents') : Promise.resolve([])));
  const [amount, setAmount] = useState('');
  const [note, setNote] = useState('');
  const [msg, setMsg] = useState<{ text: string; ok: boolean } | null>(null);
  const [edit, setEdit] = useState<{ displayName: string; password: string; note: string } | null>(null);

  async function run(fn: () => Promise<unknown>, ok: string) {
    setMsg(null);
    try {
      await fn();
      setMsg({ text: ok, ok: true });
      reload();
    } catch (e) {
      setMsg({ text: (e as Error).message, ok: false });
    }
  }

  if (error) return <Drawer onClose={onClose}><div className="error">{error}</div></Drawer>;
  if (!data) return <Drawer onClose={onClose}><div className="muted">Učitavanje…</div></Drawer>;
  const u = data.user;
  const value = Math.floor(Number(amount));
  const validAmount = Number.isFinite(value) && value > 0;

  return (
    <Drawer onClose={onClose}>
      <h2>
        {u.displayName} <span className="muted">@{u.username}</span>{' '}
        {u.isBlocked && <span className="badge red">Blokiran{u.blockedReason ? `: ${u.blockedReason}` : ''}</span>}
      </h2>

      <div className="stats">
        <div className="stat">
          <span className="muted">Na nalogu</span>
          <b>{fmt(u.balance)}</b>
        </div>
        <div className="stat">
          <span className="muted">Na stolovima</span>
          <b>{fmt(data.seats.reduce((s: number, x: any) => s + x.stack, 0))}</b>
        </div>
      </div>

      <h3>Uplata / isplata</h3>
      <div className="card">
        <div className="row">
          <input type="number" min={1} placeholder="Iznos" value={amount} onChange={(e) => setAmount(e.target.value)} />
          <input className="grow" placeholder="Beleška (nije obavezno)" value={note} onChange={(e) => setNote(e.target.value)} />
        </div>
        <div className="row" style={{ marginTop: 8 }}>
          <button
            className="ok"
            disabled={!validAmount}
            onClick={() =>
              run(async () => {
                await api('POST', `/admin/players/${id}/deposit`, { amount: value, note: note || undefined });
                setAmount('');
                setNote('');
              }, `Uplaćeno ${fmt(value)}.`)
            }
          >
            Uplati
          </button>
          <button
            className="danger"
            disabled={!validAmount}
            onClick={() =>
              run(async () => {
                await api('POST', `/admin/players/${id}/withdraw`, { amount: value, note: note || undefined });
                setAmount('');
                setNote('');
              }, `Isplaćeno ${fmt(value)}.`)
            }
          >
            Isplati
          </button>
        </div>
        <p className="muted small">Isplata je moguća samo sa naloga — žetoni na stolu se vraćaju na nalog kad igrač ustane.</p>
        {msg && <div className={msg.ok ? 'success' : 'error'}>{msg.text}</div>}
      </div>

      {data.seats.length > 0 && (
        <>
          <h3>Za stolovima</h3>
          <div className="card">
            <table>
              <tbody>
                {data.seats.map((s: any) => (
                  <tr key={s.tableId}>
                    <td>{s.tableName}</td>
                    <td>mesto {s.seat + 1}</td>
                    <td>{fmt(s.stack)}</td>
                    <td>
                      <button
                        className="secondary"
                        onClick={() => run(() => api('POST', `/admin/players/${id}/kick`, { tableId: s.tableId }), 'Igrač ustaje sa stola.')}
                      >
                        Podigni sa stola
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      <h3>Nalog</h3>
      <div className="card">
        {edit ? (
          <>
            <div className="form-grid">
              <label>
                Ime za prikaz
                <input value={edit.displayName} onChange={(e) => setEdit({ ...edit, displayName: e.target.value })} />
              </label>
              <label>
                Nova lozinka (prazno = bez promene)
                <input value={edit.password} onChange={(e) => setEdit({ ...edit, password: e.target.value })} />
              </label>
            </div>
            <label className="block">
              Beleška
              <textarea rows={2} value={edit.note} onChange={(e) => setEdit({ ...edit, note: e.target.value })} />
            </label>
            <div className="row">
              <button
                onClick={() =>
                  run(async () => {
                    await api('PATCH', `/admin/players/${id}`, {
                      displayName: edit.displayName,
                      note: edit.note,
                      ...(edit.password ? { password: edit.password } : {}),
                    });
                    setEdit(null);
                  }, 'Sačuvano.')
                }
              >
                Sačuvaj
              </button>
              <button className="secondary" onClick={() => setEdit(null)}>
                Otkaži
              </button>
            </div>
          </>
        ) : (
          <>
            <div className="kv">
              <span>Napravljen</span>
              <b>{fmtDate(u.createdAt)}</b>
              <span>Poslednji put</span>
              <b>{fmtDate(u.lastSeenAt)}</b>
              <span>Agent</span>
              <b>{u.agentName ?? '—'}</b>
              <span>Beleška</span>
              <b>{u.note || '—'}</b>
            </div>
            <div className="row" style={{ marginTop: 12 }}>
              <button className="secondary" onClick={() => setEdit({ displayName: u.displayName, password: '', note: u.note ?? '' })}>
                Izmeni / nova lozinka
              </button>
              {u.isBlocked ? (
                <button className="ok" onClick={() => run(() => api('POST', `/admin/players/${id}/unblock`), 'Igrač je odblokiran.')}>
                  Odblokiraj
                </button>
              ) : (
                <button
                  className="danger"
                  onClick={() => {
                    const reason = prompt('Razlog blokade (igrač će ga videti, nije obavezno):');
                    if (reason === null) return;
                    void run(() => api('POST', `/admin/players/${id}/block`, { reason: reason || undefined }), 'Igrač je blokiran i podignut sa stolova.');
                  }}
                >
                  Blokiraj
                </button>
              )}
              {me.role === 'ADMIN' && (
                <select
                  value={u.agentId ?? ''}
                  onChange={(e) => run(() => api('PATCH', `/admin/players/${id}`, { agentId: e.target.value }), 'Agent je promenjen.')}
                >
                  <option value="">— bez agenta —</option>
                  {agents.data?.map((a) => (
                    <option key={a.id} value={a.id}>
                      Agent: {a.displayName}
                    </option>
                  ))}
                </select>
              )}
            </div>
          </>
        )}
      </div>

      <h3>Istorija ({fmt(data.transactions.total)})</h3>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Vreme</th>
              <th>Vrsta</th>
              <th>Iznos</th>
              <th>Stanje posle</th>
              <th>Detalji</th>
            </tr>
          </thead>
          <tbody>
            {data.transactions.items.map((t: any) => (
              <tr key={t.id}>
                <td>{fmtDate(t.createdAt)}</td>
                <td>{TX_LABELS[t.type]}</td>
                <td>
                  <Amount value={t.amount} />
                </td>
                <td>{fmt(t.balanceAfter)}</td>
                <td className="muted">{[t.table, t.actor && `agent: ${t.actor}`, t.note].filter(Boolean).join(' · ')}</td>
              </tr>
            ))}
          </tbody>
        </table>
        <Pager page={page} total={data.transactions.total} pageSize={data.transactions.pageSize} onPage={setPage} />
      </div>
    </Drawer>
  );
}
