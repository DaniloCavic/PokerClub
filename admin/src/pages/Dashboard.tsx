import { useEffect } from 'react';
import { api, fmt } from '../api';
import { useLoad } from './common';

export function Dashboard() {
  const { data, error, reload } = useLoad(() => api('GET', '/admin/stats'));
  useEffect(() => {
    const t = setInterval(reload, 10_000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  if (error) return <div className="error">{error}</div>;
  if (!data) return <div className="muted">Učitavanje…</div>;
  const items: [string, number][] = [
    ['Igrača', data.players],
    ['Blokiranih', data.blockedPlayers],
    ['Žetoni na nalozima', data.balanceOnAccounts],
    ['Žetoni na stolovima', data.chipsOnTables],
    ['Igrača za stolovima', data.seatedPlayers],
    ['Otvorenih stolova', data.openTables],
    ['Uplate danas', data.depositsToday],
    ['Isplate danas', data.withdrawalsToday],
    ['Rake danas', data.rakeToday],
    ['Rake ukupno', data.rakeTotal],
    ['Ruku danas', data.handsToday],
  ];
  return (
    <>
      <h2>Pregled</h2>
      <div className="stats">
        {items.map(([label, value]) => (
          <div key={label} className="stat">
            <span className="muted">{label}</span>
            <b>{fmt(value)}</b>
          </div>
        ))}
      </div>
    </>
  );
}
