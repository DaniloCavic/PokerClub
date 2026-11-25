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
        Upozorenja se prave sama: kad za isti sto sedne igrač sa iste IP adrese ili uređaja kao neko ko već sedi; svakog sata iz ruku
        poslednjih 7 dana: <b>prebacivanje žetona</b> (jedan igrač stalno gubi novac baš jednom igraču), <b>meka igra</b> (igrač skoro
        uvek odustaje kad baš određeni igrač beti, a protiv ostalih ne) i <b>više naloga</b> sa iste IP adrese ili uređaja. To nije
        dokaz varanja (isti stan, isti kafić, slučajnost), ali vredi pogledati ruke tih igrača.
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
                  <span className={`badge ${a.kind === 'SAME_IP' ? 'blue' : 'red'}`}>
                    {(
                      {
                        SAME_DEVICE: 'Isti uređaj',
                        SAME_IP: 'Ista IP adresa',
                        STAFF_NEW_IP: 'Admin: nova IP',
                        STAFF_LOCKED: 'Admin: zaključan',
                        CHIP_DUMP: 'Prebacivanje žetona',
                        SOFT_PLAY: 'Meka igra',
                        SHARED_IP: 'Više naloga, ista IP',
                        SHARED_DEVICE: 'Više naloga, isti uređaj',
                      } as Record<string, string>
                    )[a.kind] ?? a.kind}
                  </span>
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
      <h3>Prijave super agenta i agenata</h3>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Vreme</th>
              <th>Nalog</th>
              <th>Uspeh</th>
              <th>IP adresa</th>
              <th>Uređaj</th>
            </tr>
          </thead>
          <tbody>
            {data?.staffLogins?.map((l: any) => (
              <tr key={l.id}>
                <td>{fmtDate(l.createdAt)}</td>
                <td>{l.user?.displayName ?? l.login}</td>
                <td>{l.ok ? <span className="badge green">da</span> : <span className="badge red">{l.reason ?? 'ne'}</span>}</td>
                <td>{l.ip}</td>
                <td className="small muted">{(l.agent ?? '').slice(0, 60)}</td>
              </tr>
            ))}
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
