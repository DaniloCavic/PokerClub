import { useState } from 'react';
import { api, fmt, fmtDate, Me } from '../api';
import { useLoad } from './common';
import { CreateAccount } from './Players';

export function Agents() {
  const { data, error, reload } = useLoad<any[]>(() => api('GET', '/admin/agents'));
  const [creating, setCreating] = useState(false);
  const [msg, setMsg] = useState('');

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

  return (
    <>
      <div className="row">
        <h2 className="grow">Agenti</h2>
        <button onClick={() => setCreating(true)}>+ Novi agent</button>
      </div>
      <p className="muted small">
        Agent pravi svoje igrače i stolove, uplaćuje i isplaćuje žetone. Blokada agenta privremeno blokira i sve njegove igrače.
      </p>
      {error && <div className="error">{error}</div>}
      {msg && <div className="muted">{msg}</div>}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Korisničko ime</th>
              <th>Ime</th>
              <th>Igrača</th>
              <th>Stolova</th>
              <th>Žetoni igrača</th>
              <th>Rake ukupno</th>
              <th>Poslednji put</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {data?.map((a) => (
              <tr key={a.id}>
                <td>
                  <b>{a.username}</b>
                </td>
                <td>{a.displayName}</td>
                <td>{a.players}</td>
                <td>{a.tables}</td>
                <td>{fmt(a.playersBalance)}</td>
                <td>{fmt(a.rakeTotal)}</td>
                <td>{fmtDate(a.lastSeenAt)}</td>
                <td className="row">
                  <button
                    className="secondary"
                    onClick={() => {
                      const password = prompt(`Nova lozinka za ${a.username} (bar 6 znakova):`);
                      if (password) void run(() => api('PATCH', `/admin/agents/${a.id}`, { password }), 'Lozinka je promenjena.');
                    }}
                  >
                    Lozinka
                  </button>
                  {a.isBlocked ? (
                    <button className="ok" onClick={() => run(() => api('POST', `/admin/agents/${a.id}/unblock`), 'Agent je odblokiran.')}>
                      Odblokiraj
                    </button>
                  ) : (
                    <button
                      className="danger"
                      onClick={() =>
                        confirm(`Blokirati agenta ${a.displayName}? Njegovi igrači ustaju sa stolova i ne mogu da se prijave.`) &&
                        run(() => api('POST', `/admin/agents/${a.id}/block`, {}), 'Agent je blokiran.')
                      }
                    >
                      Blokiraj
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {data?.length === 0 && (
              <tr>
                <td colSpan={8} className="muted">
                  Još nema agenata.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {creating && (
        <CreateAccount
          me={{ role: 'ADMIN' } as Me}
          title="Novi agent"
          path="/admin/agents"
          onClose={() => setCreating(false)}
          onSaved={() => {
            setCreating(false);
            reload();
          }}
        />
      )}
    </>
  );
}
