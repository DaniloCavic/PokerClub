import { api, fmtDate } from '../api';
import { useLoad } from './common';

/** Bezbednost: isti uređaj ili IP za istim stolom, i parovi koji često igraju zajedno. */
export function Security() {
  const { data, error, reload } = useLoad<any>(() => api('GET', '/admin/security'));
  return (
    <>
      <div className="row">
        <h2 className="grow">Bezbednost</h2>
        <button
          className="secondary"
          onClick={async () => {
            await api('POST', '/admin/security/seen');
            reload();
          }}
        >
          Označi sve kao pregledano
        </button>
      </div>
      <p className="muted small">
        Upozorenje se pravi kad za isti sto sedne igrač sa iste IP adrese ili sa istog uređaja kao neko ko već sedi. Ista IP adresa
        ne mora da znači varanje (isti stan, isti kafić), ali vredi pogledati.
      </p>
      {error && <div className="error">{error}</div>}
      <h3>Upozorenja</h3>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Vreme</th>
              <th>Vrsta</th>
              <th>Igrači</th>
              <th>Sto</th>
              <th>Detalj</th>
            </tr>
          </thead>
          <tbody>
            {data?.alerts.map((a: any) => (
              <tr key={a.id} style={a.seen ? undefined : { background: '#fff4e5' }}>
                <td>{fmtDate(a.createdAt)}</td>
                <td>
                  <span className={`badge ${a.kind === 'SAME_DEVICE' ? 'red' : 'blue'}`}>{a.kind === 'SAME_DEVICE' ? 'Isti uređaj' : 'Ista IP adresa'}</span>
                </td>
                <td>
                  <b>{a.names}</b>
                </td>
                <td>{a.tableName ?? '—'}</td>
                <td className="small">{a.detail}</td>
              </tr>
            ))}
            {data?.alerts.length === 0 && (
              <tr>
                <td colSpan={5} className="muted">Nema upozorenja.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      <h3>Najčešće zajedno u rukama (poslednjih 7 dana)</h3>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Igrači</th>
              <th>Zajedničkih ruku</th>
              <th>Ista IP</th>
            </tr>
          </thead>
          <tbody>
            {data?.pairs.map((p: any) => (
              <tr key={p.a + p.b}>
                <td>
                  {p.nameA} — {p.nameB}
                </td>
                <td>{p.hands}</td>
                <td>{p.sameIp ? <span className="badge red">da</span> : '—'}</td>
              </tr>
            ))}
            {data?.pairs.length === 0 && (
              <tr>
                <td colSpan={3} className="muted">Nema odigranih ruku.</td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </>
  );
}
