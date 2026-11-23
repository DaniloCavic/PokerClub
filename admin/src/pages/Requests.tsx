import { useEffect, useState } from 'react';
import { api, fmt, fmtDate, Me } from '../api';
import { useLoad } from './common';

const STATUS: Record<string, { label: string; cls: string }> = {
  PENDING: { label: 'čeka', cls: 'blue' },
  APPROVED: { label: 'odobreno', cls: 'green' },
  REJECTED: { label: 'odbijeno', cls: 'red' },
  CANCELLED: { label: 'otkazao igrač', cls: '' },
};

/** Zahtevi igrača za uplatu i isplatu: agent odobrava ili odbija jednim dodirom. */
export function Requests({ me, onChanged }: { me: Me; onChanged: () => void }) {
  const [all, setAll] = useState(false);
  const { data, error, reload } = useLoad<any[]>(() => api('GET', `/admin/cash-requests${all ? '' : '?status=PENDING'}`), [all]);
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState('');

  useEffect(() => {
    const t = setInterval(reload, 15000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [all]);

  async function act(r: any, what: 'approve' | 'reject') {
    const q =
      what === 'approve'
        ? `${r.type === 'DEPOSIT' ? 'Uplatiti' : 'Isplatiti'} ${fmt(r.amount)} RSD igraču ${r.player.name}?`
        : `Odbiti zahtev igrača ${r.player.name} (${fmt(r.amount)} RSD)?`;
    if (!window.confirm(q)) return;
    setBusy(r.id);
    setMsg('');
    try {
      await api('POST', `/admin/cash-requests/${r.id}/${what}`);
      setMsg(what === 'approve' ? 'Odobreno — stanje igrača je promenjeno.' : 'Zahtev je odbijen.');
      reload();
      onChanged();
    } catch (e) {
      setMsg((e as Error).message);
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <h2>Zahtevi za uplatu i isplatu</h2>
        <label className="row small" style={{ gap: 6 }}>
          <input type="checkbox" checked={all} onChange={(e) => setAll(e.target.checked)} /> Prikaži i rešene
        </label>
      </div>
      {error && <div className="error">{error}</div>}
      {msg && <div className="success">{msg}</div>}
      <div className="card">
        {data && data.length === 0 ? (
          <p className="muted">{all ? 'Nema zahteva.' : 'Nema zahteva koji čekaju.'}</p>
        ) : (
          <table>
            <thead>
              <tr>
                <th>Igrač</th>
                <th>Zahtev</th>
                <th>Iznos</th>
                <th>Na nalogu</th>
                {me.role === 'ADMIN' && <th>Agent</th>}
                <th>Vreme</th>
                <th>Stanje</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {data?.map((r) => (
                <tr key={r.id}>
                  <td>
                    <b>{r.player.name}</b> <span className="muted small">@{r.player.username}</span>
                    {r.note && <div className="muted small">„{r.note}“</div>}
                  </td>
                  <td>{r.type === 'DEPOSIT' ? <span className="badge green">uplata</span> : <span className="badge red">isplata</span>}</td>
                  <td>
                    <b>{fmt(r.amount)}</b>
                  </td>
                  <td>{fmt(r.player.balance)}</td>
                  {me.role === 'ADMIN' && <td>{r.agent ?? 'bez agenta'}</td>}
                  <td>{fmtDate(r.createdAt)}</td>
                  <td>
                    <span className={`badge ${STATUS[r.status]?.cls ?? ''}`}>{STATUS[r.status]?.label ?? r.status}</span>
                    {r.decidedBy && <div className="muted small">{r.decidedBy}</div>}
                  </td>
                  <td className="row">
                    {r.status === 'PENDING' && (
                      <>
                        <button className="ok" disabled={busy === r.id} onClick={() => act(r, 'approve')}>
                          Odobri
                        </button>
                        <button className="danger" disabled={busy === r.id} onClick={() => act(r, 'reject')}>
                          Odbij
                        </button>
                      </>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}
