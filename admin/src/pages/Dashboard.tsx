import { useEffect } from 'react';
import { api, fmt, Me } from '../api';
import { useLoad } from './common';

export function Dashboard({ me }: { me: Me }) {
  const { data, error, reload } = useLoad(() => api('GET', '/admin/stats'));
  useEffect(() => {
    const t = setInterval(reload, 10_000);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  if (error) return <div className="error">{error}</div>;
  if (!data) return <div className="muted">Učitavanje…</div>;
  const isSuper = me.role === 'ADMIN';
  const items: [string, number][] = [
    ['Igrača', data.players],
    ['Blokiranih', data.blockedPlayers],
    ['Na nalozima (RSD)', data.balanceOnAccounts],
    ['Na stolovima (RSD)', data.chipsOnTables],
    ['Igrača za stolovima', data.seatedPlayers],
    ['Otvorenih stolova', data.openTables],
    ['Uplate danas', data.depositsToday],
    ['Isplate danas', data.withdrawalsToday],
    ['Ruku danas', data.handsToday],
  ];
  // Rake: super agent vidi ukupno i podelu; agent vidi rake svojih igrača i svoj deo.
  const rake: [string, number, string?][] = isSuper
    ? [
        ['Rake danas', data.rakeToday],
        ['Agentima danas', data.agentsCutToday],
        ['Vaš deo danas', data.superShareToday, 'gold'],
        ['Rake ukupno', data.rakeTotal],
        ['Agentima ukupno', data.agentsCutTotal],
        ['Vaš deo ukupno', data.superShareTotal, 'gold'],
      ]
    : [
        ['Rake vaših igrača danas', data.playersRakeToday],
        [`Vaša zarada danas (${data.rakeSharePercent}%)`, data.myCutToday, 'gold'],
        ['Rake vaših igrača ukupno', data.playersRakeTotal],
        [`Vaša zarada ukupno (${data.rakeSharePercent}%)`, data.myCutTotal, 'gold'],
      ];
  return (
    <>
      <h2>Pregled</h2>
      <h3>Rake</h3>
      <div className="stats">
        {rake.map(([label, value, cls]) => (
          <div key={label} className={`stat ${cls ?? ''}`}>
            <span className="muted">{label}</span>
            <b>{fmt(value)}</b>
          </div>
        ))}
      </div>
      <h3>Igrači i novac</h3>
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
