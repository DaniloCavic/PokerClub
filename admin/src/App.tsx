import { useEffect, useState } from 'react';
import { api, getToken, Me, setToken } from './api';
import { Dashboard } from './pages/Dashboard';
import { Tables } from './pages/Tables';
import { Players } from './pages/Players';
import { Transactions } from './pages/Transactions';
import { Agents } from './pages/Agents';

type Page = 'dashboard' | 'tables' | 'players' | 'transactions' | 'agents';

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

  if (loading) return <div className="muted center">Učitavanje…</div>;
  if (!me) return <Login onDone={setMe} />;

  const pages: { id: Page; label: string }[] = [
    { id: 'dashboard', label: 'Pregled' },
    { id: 'tables', label: 'Stolovi' },
    { id: 'players', label: 'Igrači' },
    { id: 'transactions', label: 'Transakcije' },
    ...(me.role === 'ADMIN' ? [{ id: 'agents' as Page, label: 'Agenti' }] : []),
  ];
  const current = pages.some((p) => p.id === page) ? page : 'dashboard';

  return (
    <div className="layout">
      <nav className="sidebar">
        <h1>
          ♠ Poker <span>klub</span>
        </h1>
        <div className="who">
          {me.displayName}
          <small>{me.role === 'ADMIN' ? 'Administrator' : 'Agent'}</small>
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
        {current === 'dashboard' && <Dashboard />}
        {current === 'tables' && <Tables me={me} />}
        {current === 'players' && <Players me={me} />}
        {current === 'transactions' && <Transactions />}
        {current === 'agents' && <Agents />}
      </main>
    </div>
  );
}

function Login({ onDone }: { onDone: (me: Me) => void }) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError('');
    try {
      const res = await api('POST', '/auth/login', { username, password });
      if (res.user.role === 'PLAYER') throw new Error('Ovo je nalog igrača. Igrači igraju u aplikaciji.');
      setToken(res.accessToken);
      onDone(res.user);
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <form className="card login" onSubmit={submit}>
      <h2>♠ Poker klub — agenti</h2>
      <input placeholder="Korisničko ime" value={username} onChange={(e) => setUsername(e.target.value)} autoFocus />
      <input placeholder="Lozinka" type="password" value={password} onChange={(e) => setPassword(e.target.value)} />
      {error && <div className="error">{error}</div>}
      <button disabled={busy || !username || !password}>Prijava</button>
    </form>
  );
}
