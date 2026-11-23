import { useEffect, useState } from 'react';
import QRCode from 'qrcode';
import { api, fmtDate, getToken, Me, setToken } from '../api';
import { useLoad } from './common';

/** Moj nalog: dvostepena prijava (2FA), promena lozinke, odjava sa svih uređaja, moje prijave. */
export function Account({ me }: { me: Me }) {
  const { data, reload } = useLoad<any>(() => api('GET', '/admin/account'));
  const [setup, setSetup] = useState<{ secret: string; url: string } | null>(null);
  const [qr, setQr] = useState('');
  const [code, setCode] = useState('');
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const [pw, setPw] = useState({ old: '', next: '', again: '' });
  const [off, setOff] = useState({ password: '', code: '' });

  useEffect(() => {
    if (setup) QRCode.toDataURL(setup.url, { width: 220, margin: 1 }).then(setQr);
  }, [setup]);

  async function run(fn: () => Promise<unknown>, ok: string) {
    setErr('');
    setMsg('');
    try {
      await fn();
      setMsg(ok);
      reload();
    } catch (e) {
      setErr((e as Error).message);
    }
  }

  return (
    <>
      <h2>Moj nalog i bezbednost</h2>
      {msg && <div className="success">{msg}</div>}
      {err && <div className="error">{err}</div>}

      <h3>Dvostepena prijava (2FA)</h3>
      <div className="card">
        {data?.totpEnabled ? (
          <>
            <p>
              <span className="badge green">Uključena</span> Pri prijavi se, posle lozinke, traži kod iz aplikacije na vašem telefonu. Čak i ako
              neko sazna lozinku, ne može da uđe bez vašeg telefona.
            </p>
            <div className="row">
              <input type="password" placeholder="Lozinka" value={off.password} onChange={(e) => setOff({ ...off, password: e.target.value })} />
              <input placeholder="Kod (6 cifara)" value={off.code} onChange={(e) => setOff({ ...off, code: e.target.value.replace(/\D/g, '').slice(0, 6) })} />
              <button
                className="danger"
                onClick={() => run(() => api('POST', '/admin/2fa/disable', off), 'Dvostepena prijava je isključena.')}
              >
                Isključi 2FA
              </button>
            </div>
          </>
        ) : !setup ? (
          <>
            <p>
              <span className="badge red">Isključena</span>{' '}
              {me.role === 'ADMIN' ? 'Za nalog super agenta toplo preporučujemo da je uključite.' : 'Preporučujemo da je uključite.'} Potrebna je
              aplikacija Google Authenticator, Microsoft Authenticator ili Authy na telefonu.
            </p>
            <button onClick={() => run(async () => setSetup(await api('POST', '/admin/2fa/setup')), '')}>Uključi dvostepenu prijavu</button>
          </>
        ) : (
          <>
            <p>
              1. Otvorite aplikaciju za autentifikaciju i skenirajte ovaj QR kod (ili ručno unesite ključ).
              <br />
              2. Upišite kod od 6 cifara koji aplikacija prikazuje.
            </p>
            <div className="row" style={{ alignItems: 'flex-start', gap: 20 }}>
              {qr && <img src={qr} width={220} height={220} alt="QR kod za aplikaciju za autentifikaciju" />}
              <div>
                <div className="muted small">Ključ:</div>
                <code style={{ fontSize: 15, wordBreak: 'break-all' }}>{setup.secret}</code>
                <div className="row" style={{ marginTop: 14 }}>
                  <input placeholder="Kod (6 cifara)" value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, '').slice(0, 6))} />
                  <button
                    disabled={code.length !== 6}
                    onClick={() =>
                      run(async () => {
                        await api('POST', '/admin/2fa/enable', { code });
                        setSetup(null);
                      }, 'Dvostepena prijava je uključena.')
                    }
                  >
                    Potvrdi
                  </button>
                </div>
              </div>
            </div>
          </>
        )}
      </div>

      <h3>Promena lozinke</h3>
      <div className="card">
        <div className="row">
          <input type="password" placeholder="Stara lozinka" value={pw.old} onChange={(e) => setPw({ ...pw, old: e.target.value })} />
          <input type="password" placeholder="Nova lozinka (bar 10 znakova)" value={pw.next} onChange={(e) => setPw({ ...pw, next: e.target.value })} />
          <input type="password" placeholder="Ponovite novu" value={pw.again} onChange={(e) => setPw({ ...pw, again: e.target.value })} />
          <button
            disabled={!pw.old || pw.next.length < 10 || pw.next !== pw.again}
            onClick={() =>
              run(async () => {
                const r = await api('POST', '/me/password', { oldPassword: pw.old, newPassword: pw.next });
                if (r.accessToken) setToken(r.accessToken);
                setPw({ old: '', next: '', again: '' });
              }, 'Lozinka je promenjena. Svi ostali uređaji su odjavljeni.')
            }
          >
            Promeni
          </button>
        </div>
        <p className="muted small">Za nalog super agenta koristite dugačku lozinku koju ne koristite nigde drugde.</p>
      </div>

      <h3>Odjava sa svih uređaja</h3>
      <div className="card">
        <p className="muted small">Ako sumnjate da je neko video vašu lozinku ili ste se prijavili na tuđem računaru.</p>
        <button
          className="secondary"
          onClick={() =>
            run(async () => {
              const r = await api('POST', '/me/logout-all', {});
              if (r.accessToken) setToken(r.accessToken);
            }, 'Svi ostali uređaji su odjavljeni.')
          }
        >
          Odjavi sve ostale uređaje
        </button>
      </div>

      {me.role === 'ADMIN' && (
        <>
          <h3>Rezervna kopija i dnevni izveštaj</h3>
          <div className="card">
            <p className="muted small" style={{ marginTop: 0 }}>
              Svakog dana oko 04:00 rezervna kopija baze stiže na mejl kluba, a svakog ponedeljka u 10:00 nedeljni izveštaj za prethodnu
              nedelju (rake, fee, uplate i isplate po agentima, upozorenja).
            </p>
            <div className="row">
              <button
                className="secondary"
                onClick={() =>
                  run(async () => {
                    const res = await fetch('/api/admin/backup', { headers: { authorization: `Bearer ${getToken()}` } });
                    if (!res.ok) throw new Error('Preuzimanje nije uspelo.');
                    const blob = await res.blob();
                    const a = document.createElement('a');
                    a.href = URL.createObjectURL(blob);
                    a.download = `triling-baza-${new Date().toISOString().slice(0, 10)}.json.gz`;
                    a.click();
                    URL.revokeObjectURL(a.href);
                  }, 'Rezervna kopija je preuzeta.')
                }
              >
                Preuzmi rezervnu kopiju baze
              </button>
              <button
                className="secondary"
                onClick={() => run(async () => api('POST', '/admin/daily/send'), 'Izveštaj i rezervna kopija su poslati na mejl kluba.')}
              >
                Pošalji izveštaj (poslednjih 7 dana) sada
              </button>
            </div>
          </div>
        </>
      )}

      <h3>Moje poslednje prijave</h3>
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Vreme</th>
              <th>Uspeh</th>
              <th>IP adresa</th>
              <th>Uređaj</th>
            </tr>
          </thead>
          <tbody>
            {data?.logins.map((l: any) => (
              <tr key={l.id}>
                <td>{fmtDate(l.createdAt)}</td>
                <td>{l.ok ? <span className="badge green">da</span> : <span className="badge red">{l.reason ?? 'ne'}</span>}</td>
                <td>{l.ip}</td>
                <td className="small muted">{(l.agent ?? '').slice(0, 70)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
