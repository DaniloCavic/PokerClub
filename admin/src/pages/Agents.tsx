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
        Agent pravi svoje igrače, uplaćuje i isplaćuje im novac. Od rake-a svojih igrača dobija svoj procenat, a ostatak pripada vama. Agent može da napravi i svoje podagente: njima daje procenat od svog dela (npr. vi agentu 70 %, on podagentu 50 % → podagent ima 35 % rake-a svojih igrača, agent 35 %, vi 30 %). Blokada agenta privremeno blokira i njegove podagente i sve njihove igrače.
      </p>
      {error && <div className="error">{error}</div>}
      {msg && <div className="muted">{msg}</div>}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Korisničko ime</th>
              <th>Ime</th>
              <th>Nadređeni</th>
              <th>Kod za igrače</th>
              <th>Procenat</th>
              <th>Igrača</th>
              <th>Na nalozima igrača</th>
              <th>Rake njegovih igrača</th>
              <th>Zarada agenta</th>
              <th>Vama (od njegovih igrača)</th>
              <th>Poslednji put</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {data?.map((a) => (
              <tr key={a.id}>
                <td data-label="Korisničko ime">
                  <b>{a.username}</b>
                </td>
                <td data-label="Ime">{a.displayName}</td>
                <td data-label="Nadređeni">{a.parentName ?? <span className="muted">vi (super agent)</span>}</td>
                <td data-label="Kod">
                  <code style={{ fontSize: 15, fontWeight: 700, letterSpacing: 1 }}>{a.agentCode ?? '—'}</code>{' '}
                  {a.totpEnabled ? <span className="badge green">2FA</span> : <span className="badge red">bez 2FA</span>}
                </td>
                <td data-label="Procenat">
                  <b>{a.rakePercent}%</b>
                  {a.parentId && (
                    <div className="muted small">
                      od dela nadređenog · stvarno {a.effectivePercent}%
                    </div>
                  )}
                  {a.subAgents > 0 && <div className="muted small">podagenata: {a.subAgents}</div>}
                </td>
                <td data-label="Igrača">{a.players}</td>
                <td data-label="Na nalozima igrača">{fmt(a.playersBalance)}</td>
                <td data-label="Rake njegovih igrača">{fmt(a.playersRake)}</td>
                <td data-label="Zarada agenta">{fmt(a.agentCut)}</td>
                <td data-label="Vama" className="plus">{fmt(a.superShare)}</td>
                <td data-label="Poslednji put">{fmtDate(a.lastSeenAt)}</td>
                <td data-label="" className="row">
                  <button
                    className="secondary"
                    onClick={() => {
                      const v = prompt(`Novi kod za agenta ${a.displayName} (slova i brojevi, npr. LIVERPOOL123). Stari kod prestaje da važi za nove igrače:`, a.agentCode ?? '');
                      if (v === null) return;
                      void run(() => api('PATCH', `/admin/agents/${a.id}`, { agentCode: v }), 'Kod je promenjen.');
                    }}
                  >
                    Kod
                  </button>
                  {a.totpEnabled && (
                    <button
                      className="secondary"
                      onClick={() => {
                        if (!window.confirm(`Isključiti 2FA agentu ${a.displayName} (npr. izgubio telefon)? Biće odjavljen sa svih uređaja.`)) return;
                        void run(() => api('POST', `/admin/agents/${a.id}/reset-2fa`), '2FA je isključena za agenta.');
                      }}
                    >
                      Reset 2FA
                    </button>
                  )}
                  <button
                    className="secondary"
                    onClick={() => {
                      const v = prompt(
                        a.parentId
                          ? `Procenat za podagenta ${a.displayName} od dela agenta ${a.parentName} (0–100). Važi za ruke od sada:`
                          : `Procenat rake-a za agenta ${a.displayName} (0–100). Važi za ruke od sada:`,
                        String(a.rakePercent),
                      );
                      if (v === null) return;
                      const n = Number(v.replace(',', '.'));
                      void run(() => api('PATCH', `/admin/agents/${a.id}`, { rakePercent: n }), 'Procenat je promenjen.');
                    }}
                  >
                    Procenat
                  </button>
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
                <td colSpan={12} className="muted">
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

/**
 * Agent: njegovi podagenti. Daje im procenat od SVOG dela rake-a (svoj procenat kod nadređenog ne vidi).
 * Primer: ako dobija 70 % i podagentu da 50 %, podagent ima 35 % rake-a svojih igrača, a on zadržava 35 %.
 */
export function SubAgents() {
  const { data, error, reload } = useLoad<any[]>(() => api('GET', '/admin/subagents'));
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
        <h2 className="grow">Moji agenti</h2>
        <button onClick={() => setCreating(true)}>+ Novi agent</button>
      </div>
      <p className="muted small">
        Vaši agenti prave svoje igrače i mogu da prave svoje agente. Od rake-a i turnirskog fee-a njihovih igrača dobijaju procenat <b>od vašeg dela</b>: ako im
        date 50 %, polovinu onoga što biste vi zaradili od njihovih igrača dobijaju oni, a drugu polovinu vi. Blokada agenta blokira i njegove agente i sve njihove
        igrače.
      </p>
      {error && <div className="error">{error}</div>}
      {msg && <div className="muted">{msg}</div>}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Korisničko ime</th>
              <th>Ime</th>
              <th>Kod za igrače</th>
              <th>Procenat od vašeg dela</th>
              <th>Igrača</th>
              <th>Njegovih agenata</th>
              <th>Njegova zarada</th>
              <th>Vaša zarada od njegove mreže</th>
              <th>Poslednji put</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {data?.map((a) => (
              <tr key={a.id}>
                <td data-label="Korisničko ime">
                  <b>{a.username}</b> {a.isBlocked && <span className="badge red">blokiran</span>}
                </td>
                <td data-label="Ime">{a.displayName}</td>
                <td data-label="Kod">
                  <code style={{ fontSize: 15, fontWeight: 700, letterSpacing: 1 }}>{a.agentCode ?? '—'}</code>
                </td>
                <td data-label="Procenat od vašeg dela">
                  <b>{a.rakePercent}%</b>
                </td>
                <td data-label="Igrača">{a.players}</td>
                <td data-label="Njegovih agenata">{a.subAgents}</td>
                <td data-label="Njegova zarada">{fmt(a.theirEarning)}</td>
                <td data-label="Vaša zarada od njegove mreže" className="plus">
                  {fmt(a.myEarningFromThem)}
                </td>
                <td data-label="Poslednji put">{fmtDate(a.lastSeenAt)}</td>
                <td data-label="" className="row">
                  <button
                    className="secondary"
                    onClick={() => {
                      const v = prompt(`Procenat od vašeg dela za agenta ${a.displayName} (0–100). Važi za ruke od sada:`, String(a.rakePercent));
                      if (v === null) return;
                      const n = Number(v.replace(',', '.'));
                      void run(() => api('PATCH', `/admin/subagents/${a.id}`, { rakePercent: n }), 'Procenat je promenjen.');
                    }}
                  >
                    Procenat
                  </button>
                  <button
                    className="secondary"
                    onClick={() => {
                      const v = prompt(`Novi kod za agenta ${a.displayName} (slova i brojevi). Stari kod prestaje da važi za nove igrače:`, a.agentCode ?? '');
                      if (v === null) return;
                      void run(() => api('PATCH', `/admin/subagents/${a.id}`, { agentCode: v }), 'Kod je promenjen.');
                    }}
                  >
                    Kod
                  </button>
                  <button
                    className="secondary"
                    onClick={() => {
                      const password = prompt(`Nova lozinka za ${a.username} (bar 6 znakova):`);
                      if (password) void run(() => api('PATCH', `/admin/subagents/${a.id}`, { password }), 'Lozinka je promenjena.');
                    }}
                  >
                    Lozinka
                  </button>
                  {a.isBlocked ? (
                    <button className="ok" onClick={() => run(() => api('POST', `/admin/subagents/${a.id}/unblock`), 'Agent je odblokiran.')}>
                      Odblokiraj
                    </button>
                  ) : (
                    <button
                      className="danger"
                      onClick={() =>
                        confirm(`Blokirati agenta ${a.displayName}? On, njegovi agenti i svi njihovi igrači ne mogu da se prijave.`) &&
                        run(() => api('POST', `/admin/subagents/${a.id}/block`, {}), 'Agent je blokiran.')
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
                <td colSpan={10} className="muted">
                  Još nemate svoje agente. Napravite prvog dugmetom „+ Novi agent”.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
      {creating && (
        <CreateAccount
          me={{ role: 'AGENT' } as Me}
          title="Novi agent"
          path="/admin/subagents"
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
