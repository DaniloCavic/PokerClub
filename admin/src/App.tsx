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
import { Requests } from './pages/Requests';

type Page = 'requests' | 'account' | 'dashboard' | 'tables' | 'tournaments' | 'players' | 'transactions' | 'reports' | 'agents' | 'security' | 'welcome';

export function App() {
  const [me, setMe] = useState<Me | null>(null);
  const [loading, setLoading] = useState(!!getToken());
  const [page, setPage] = useState<Page>(() => (location.hash.slice(1) as Page) || 'dashboard');
  const [more, setMore] = useState(false);
  // Broj zahteva za uplatu/isplatu koji čekaju (osvežava se svakih 30 s).
  const [pending, setPending] = useState(0);
  const loadPending = () => {
    if (getToken()) api<{ pending: number }>('GET', '/admin/cash-requests/count').then((r) => setPending(r.pending)).catch(() => undefined);
  };
  useEffect(() => {
    if (!me) return;
    loadPending();
    const t = setInterval(loadPending, 30000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [me]);

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
    window.scrollTo(0, 0);
  }, [page]);

  useResponsiveTables();

  if (loading) return <div className="muted center">Učitavanje…</div>;
  if (!me) return <Login onDone={setMe} />;

  const pages: { id: Page; label: string }[] = [
    { id: 'dashboard', label: 'Pregled' },
    { id: 'requests', label: 'Zahtevi' },
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
  // Telefon: najvažnije stranice u donjem meniju, ostalo pod "Više".
  const tabIds: Page[] = me.role === 'ADMIN' ? ['dashboard', 'requests', 'tournaments', 'players'] : ['dashboard', 'requests', 'players', 'transactions'];
  const tabs = pages.filter((p) => tabIds.includes(p.id));
  const rest = pages.filter((p) => !tabIds.includes(p.id));
  const title = pages.find((p) => p.id === current)?.label ?? '';
  const logout = () => {
    setToken(null);
    setMe(null);
  };
  const go = (p: Page) => {
    setMore(false);
    setPage(p);
  };

  return (
    <div className="layout">
      {/* Telefon: gornja traka sa nazivom stranice */}
      <header className="appbar">
        <div className="brand">
          Triling <span>{me.role === 'ADMIN' ? 'super agent' : 'agent'}</span>
        </div>
        <div className="title">{title}</div>
      </header>
      {/* Telefon: donji meni kao u aplikaciji */}
      <nav className="tabbar">
        {tabs.map((p) => (
          <a key={p.id} className={current === p.id && !more ? 'active' : ''} onClick={() => go(p.id)}>
            <span className="tab-icon">
              <Icon name={p.id} />
              {p.id === 'requests' && pending > 0 && <span className="dot">{pending}</span>}
            </span>
            <span>{p.id === 'dashboard' ? 'Pregled' : p.label}</span>
          </a>
        ))}
        <a className={more || rest.some((p) => p.id === current) ? 'active' : ''} onClick={() => setMore(!more)}>
          <Icon name="more" />
          <span>Više</span>
        </a>
      </nav>
      {more && (
        <div className="sheet-bg" onClick={() => setMore(false)}>
          <div className="sheet" onClick={(e) => e.stopPropagation()}>
            <div className="sheet-who">
              <b>{me.displayName}</b>
              <small>{me.role === 'ADMIN' ? 'Super agent' : 'Agent'}</small>
            </div>
            {rest.map((p) => (
              <a key={p.id} className={current === p.id ? 'active' : ''} onClick={() => go(p.id)}>
                <Icon name={p.id} />
                {p.label}
              </a>
            ))}
            <a className="danger" onClick={logout}>
              <Icon name="logout" />
              Odjava
            </a>
          </div>
        </div>
      )}
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
            {p.id === 'requests' && pending > 0 && <span className="dot inline">{pending}</span>}
          </a>
        ))}
        <a className="logout" onClick={logout}>
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
        {current === 'requests' && <Requests me={me} onChanged={loadPending} />}
        {current === 'security' && <Security />}
        {current === 'welcome' && <Welcome />}
      </main>
    </div>
  );
}

const ICONS: Record<string, string> = {
  dashboard: 'M10 20v-6h4v6h5v-8h3L12 3 2 12h3v8z',
  tables:
    'M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zM7.5 18c-.83 0-1.5-.67-1.5-1.5S6.67 15 7.5 15s1.5.67 1.5 1.5S8.33 18 7.5 18zm0-9C6.67 9 6 8.33 6 7.5S6.67 6 7.5 6 9 6.67 9 7.5 8.33 9 7.5 9zm4.5 4.5c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm4.5 4.5c-.83 0-1.5-.67-1.5-1.5s.67-1.5 1.5-1.5 1.5.67 1.5 1.5-.67 1.5-1.5 1.5zm0-9c-.83 0-1.5-.67-1.5-1.5S15.67 6 16.5 6s1.5.67 1.5 1.5S17.33 9 16.5 9z',
  tournaments:
    'M19 5h-2V3H7v2H5c-1.1 0-2 .9-2 2v1c0 2.55 1.92 4.63 4.39 4.94.63 1.5 1.98 2.63 3.61 2.96V19H7v2h10v-2h-4v-3.1c1.63-.33 2.98-1.46 3.61-2.96C19.08 12.63 21 10.55 21 8V7c0-1.1-.9-2-2-2zM5 8V7h2v3.82C5.84 10.4 5 9.3 5 8zm14 0c0 1.3-.84 2.4-2 2.82V7h2v1z',
  players:
    'M16 11c1.66 0 2.99-1.34 2.99-3S17.66 5 16 5c-1.66 0-3 1.34-3 3s1.34 3 3 3zm-8 0c1.66 0 2.99-1.34 2.99-3S9.66 5 8 5C6.34 5 5 6.34 5 8s1.34 3 3 3zm0 2c-2.33 0-7 1.17-7 3.5V19h14v-2.5c0-2.33-4.67-3.5-7-3.5zm8 0c-.29 0-.62.02-.97.05 1.16.84 1.97 1.97 1.97 3.45V19h6v-2.5c0-2.33-4.67-3.5-7-3.5z',
  transactions: 'M6.99 11L3 15l3.99 4v-3H14v-2H6.99v-3zM21 9l-3.99-4v3H10v2h7.01v3L21 9z',
  reports: 'M5 9.2h3V19H5zM10.6 5h2.8v14h-2.8zm5.6 8H19v6h-2.8z',
  account: 'M12 12c2.21 0 4-1.79 4-4s-1.79-4-4-4-4 1.79-4 4 1.79 4 4 4zm0 2c-2.67 0-8 1.34-8 4v2h16v-2c0-2.66-5.33-4-8-4z',
  agents:
    'M20 6h-4V4c0-1.11-.89-2-2-2h-4c-1.11 0-2 .89-2 2v2H4c-1.11 0-1.99.89-1.99 2L2 19c0 1.11.89 2 2 2h16c1.11 0 2-.89 2-2V8c0-1.11-.89-2-2-2zm-6 0h-4V4h4v2z',
  security: 'M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4z',
  welcome: 'M20 2H4c-1.1 0-2 .9-2 2v18l4-4h14c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2z',
  requests: 'M19 3H5c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h14c1.1 0 2-.9 2-2V5c0-1.1-.9-2-2-2zm-7 14l-5-5h3V8h4v4h3l-5 5z',
  more: 'M6 10c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm12 0c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2zm-6 0c-1.1 0-2 .9-2 2s.9 2 2 2 2-.9 2-2-.9-2-2-2z',
  logout: 'M17 7l-1.41 1.41L18.17 11H8v2h10.17l-2.58 2.58L17 17l5-5zM4 5h8V3H4c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h8v-2H4V5z',
};

function Icon({ name }: { name: string }) {
  return (
    <svg className="icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d={ICONS[name] ?? ICONS.more} />
    </svg>
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
      <img className="login-logo" src="/admin/icon-192.png" alt="" />
      <h2>
        Poker klub <span>Triling</span>
      </h2>
      <p className="muted small" style={{ marginTop: -8 }}>
        Panel za agente i super agenta
      </p>
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
