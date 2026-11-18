import { useEffect, useState } from 'react';
import { api, getToken, Me, setToken } from './api';
import { Dashboard } from './pages/Dashboard';
import { Tables } from './pages/Tables';
import { Players } from './pages/Players';
import { Transactions } from './pages/Transactions';
import { Agents } from './pages/Agents';
import { Tournaments } from './pages/Tournaments';
import { Reports } from './pages/Reports';
import { Security } from './pages/Security';
import { Welcome } from './pages/Welcome';
import { Account } from './pages/Account';

type Page = 'account' | 'dashboard' | 'tables' | 'tournaments' | 'players' | 'transactions' | 'reports' | 'agents' | 'security' | 'welcome';

export function App() {
  const [me, setMe] = useState<Me | null>(null);
  const [loading, setLoading] = useState(!!getToken());
  const [page, setPage] = useState<Page>(() => (location.hash.slice(1) as Page) || 'dashboard');

  useEffect(() => {
    const out = () => setMe(null);
    window.addEventListener('poker-logout', out);
    if (getToken()) {
      api<Me>('GET', '/admin/me')
        .then(setMe)
        .catch(() => setToken(null))
        .finally(() => setLoading(false));
    }
    return () => window.removeEventListener('poker-logout', out);
  }, []);

  useEffect(() => {
    location.hash = page;
  }, [page]);

  useResponsiveTables();

  if (loading) return <div className="muted center">Učitavanje…</div>;
  if (!me) return <Login onDone={setMe} />;

  const pages: { id: Page; label: string }[] = [
    { id: 'dashboard', label: 'Pregled' },
    { id: 'tables', label: 'Stolovi' },
    { id: 'tournaments', label: 'Turniri' },
    { id: 'players', label: 'Igrači' },
    { id: 'transactions', label: 'Transakcije' },
    { id: 'reports', label: 'Izveštaji' },
    { id: 'account', label: 'Moj nalog i 2FA' },
    ...(me.role === 'ADMIN'
      ? [
          { id: 'agents' as Page, label: 'Agenti' },
          { id: 'security' as Page, label: 'Bezbednost' },
          { id: 'welcome' as Page, label: 'Poruka i pravila' },
        ]
      : []),
  ];
  const current = pages.some((p) => p.id === page) ? page : 'dashboard';

  return (
    <div className="layout">
      <nav className="sidebar">
        <h1>
          Poker klub <span>Triling</span>
        </h1>
        <div className="who">
          {me.displayName}
          <small>{me.role === 'ADMIN' ? 'Super agent' : 'Agent'}</small>
        </div>
        {pages.map((p) => (
          <a key={p.id} className={current === p.id ? 'active' : ''} onClick={() => setPage(p.id)}>
            {p.label}
          </a>
        ))}
        <a
          className="logout"
          onClick={() => {
            setToken(null);
            setMe(null);
          }}
        >
          Odjava
        </a>
      </nav>
      <main>
        {current === 'dashboard' && <Dashboard me={me} />}
        {current === 'tables' && <Tables me={me} />}
        {current === 'tournaments' && <Tournaments me={me} />}
        {current === 'players' && <Players me={me} />}
        {current === 'transactions' && <Transactions />}
        {current === 'agents' && <Agents />}
        {current === 'reports' && <Reports me={me} />}
        {current === 'account' && <Account me={me} />}
        {current === 'security' && <Security />}
        {current === 'welcome' && <Welcome />}
      </main>
    </div>
  );
}

function Login({ onDone }: { onDone: (me: Me) => void }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [totp, setTotp] = useState('');
  const [needTotp, setNeedTotp] = useState(false);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      const res = await api('POST', '/auth/login', { username, password, ...(needTotp ? { totp } : {}) });
      if (res.user.role === 'PLAYER') throw new Error('Ovo je nalog igrača. Igrači igraju u aplikaciji.');
      setToken(res.accessToken);
      onDone(res.user);
    } catch (err) {
      const m = (err as Error).message;
      if (m === 'TOTP_REQUIRED') {
        setNeedTotp(true);
        setError('');
      } else setError(m);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="card login" onSubmit={submit}>
      <h2>Poker klub Triling — agenti</h2>
      <input placeholder="Korisničko ime" value={username} onChange={(e) => setUsername(e.target.value)} autoFocus />
      <input placeholder="Lozinka" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      {needTotp && (
        <input
          placeholder="Kod iz aplikacije (6 cifara)"
          inputMode="numeric"
          autoComplete="one-time-code"
          value={totp}
          onChange={(e) => setTotp(e.target.value.replace(/\D/g, '').slice(0, 6))}
          autoFocus
        />
      )}
      {error && <div className="error">{error}</div>}
      <button disabled={busy || !username || !password}>Prijava</button>
    </form>
  );
}

/**
 * Na telefonu se tabele prikazuju kao kartice: svaka ćelija dobija natpis iz zaglavlja
 * (data-label), a CSS ga prikazuje levo od vrednosti.
 */
function useResponsiveTables() {
  useEffect(() => {
    const label = () => {
      document.querySelectorAll('table').forEach((table) => {
        const heads = Array.from(table.querySelectorAll('thead th')).map((th) => th.textContent?.trim() ?? '');
        table.querySelectorAll('tbody tr').forEach((tr) => {
          Array.from(tr.children).forEach((td, i) => {
            const l = heads[i] ?? '';
            if (td.getAttribute('data-label') !== l) td.setAttribute('data-label', l);
          });
        });
      });
    };
    label();
    const obs = new MutationObserver(label);
    obs.observe(document.body, { childList: true, subtree: true });
    return () => obs.disconnect();
  }, []);
}
