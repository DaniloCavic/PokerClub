import { useState } from 'react';
import { api, fmt, Me } from '../api';
import { useLoad } from './common';

const iso = (d: Date) => d.toISOString().slice(0, 10);

/** Izveštaj zarade: rake sa keš stolova i fee sa turnira po danima i po agentima. */
export function Reports({ me }: { me: Me }) {
  const isSuper = me.role === 'ADMIN';
  const [from, setFrom] = useState(iso(new Date(Date.now() - 29 * 86_400_000)));
  const [to, setTo] = useState(iso(new Date()));
  const { data, error } = useLoad<any>(() => api('GET', `/admin/reports?from=${from}&to=${to}`), [from, to]);
  const preset = (days: number) => {
    setFrom(iso(new Date(Date.now() - (days - 1) * 86_400_000)));
    setTo(iso(new Date()));
  };
  const series: any[] = data?.series ?? [];
  const value = (x: any) => (isSuper ? x.rake + x.fees : x.myCut);
  const maxV = Math.max(1, ...series.map(value));

  return (
    <>
      <h2>Izveštaj zarade</h2>
      <div className="row" style={{ marginBottom: 12 }}>
        <label className="row small">
          Od <input type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
        </label>
        <label className="row small">
          Do <input type="date" value={to} onChange={(e) => setTo(e.target.value)} />
        </label>
        <button className="secondary" onClick={() => preset(7)}>7 dana</button>
        <button className="secondary" onClick={() => preset(30)}>30 dana</button>
        <button className="secondary" onClick={() => preset(90)}>90 dana</button>
      </div>
      {error && <div className="error">{error}</div>}
      {data && (
        <>
          <div className="stats">
            {isSuper ? (
              <>
                <div className="stat"><span className="muted">Rake (keš)</span><b>{fmt(data.total.rake)}</b></div>
                <div className="stat"><span className="muted">Fee (turniri)</span><b>{fmt(data.total.fees)}</b></div>
                <div className="stat"><span className="muted">Agentima</span><b>{fmt(data.total.agentsCut)}</b></div>
                <div className="stat gold"><span className="muted">Vaš deo</span><b>{fmt(data.total.superShare)}</b></div>
              </>
            ) : (
              <div className="stat gold"><span className="muted">Vaša zarada</span><b>{fmt(data.total.myCut)}</b></div>
            )}
          </div>

          <h3>Po danima</h3>
          <div className="card">
            <div className="chart" role="img" aria-label="Zarada po danima">
              {series.map((x) => {
                const v = value(x);
                const rakeH = isSuper ? (x.rake / maxV) * 100 : 0;
                const feeH = isSuper ? (x.fees / maxV) * 100 : (v / maxV) * 100;
                return (
                  <div key={x.day} className="bar" title={`${x.day}: ${fmt(v)}${isSuper ? ` (rake ${fmt(x.rake)}, fee ${fmt(x.fees)})` : ''}`}>
                    <div className="stack">
                      {isSuper && <div className="seg rake" style={{ height: `${rakeH}%` }} />}
                      <div className={`seg ${isSuper ? 'fee' : 'rake'}`} style={{ height: `${feeH}%` }} />
                    </div>
                    <small>{x.day.slice(8)}.{x.day.slice(5, 7)}.</small>
                  </div>
                );
              })}
            </div>
            {isSuper && (
              <div className="row small muted" style={{ marginTop: 8 }}>
                <span className="legend rake" /> rake (keš stolovi) <span className="legend fee" /> fee (turniri)
              </div>
            )}
          </div>

          {isSuper && (
            <>
              <h3>Po agentima</h3>
              <div className="card">
                <table>
                  <thead>
                    <tr>
                      <th>Agent</th>
                      <th>Rake</th>
                      <th>Fee</th>
                      <th>Agentu</th>
                      <th>Vama</th>
                    </tr>
                  </thead>
                  <tbody>
                    {data.byAgent.map((a: any) => (
                      <tr key={a.agentId ?? 'none'}>
                        <td>{a.name}</td>
                        <td>{fmt(a.rake)}</td>
                        <td>{fmt(a.fees)}</td>
                        <td>{fmt(a.agentCut)}</td>
                        <td className="plus">{fmt(a.superShare)}</td>
                      </tr>
                    ))}
                    {!data.byAgent.length && (
                      <tr>
                        <td colSpan={5} className="muted">Nema zarade u ovom periodu.</td>
                      </tr>
                    )}
                  </tbody>
                </table>
              </div>
            </>
          )}

          <h3>Tabela</h3>
          <div className="card">
            <table>
              <thead>
                <tr>
                  <th>Dan</th>
                  {isSuper ? (
                    <>
                      <th>Rake</th>
                      <th>Fee</th>
                      <th>Agentima</th>
                      <th>Vama</th>
                    </>
                  ) : (
                    <th>Vaša zarada</th>
                  )}
                </tr>
              </thead>
              <tbody>
                {[...series].reverse().map((x) => (
                  <tr key={x.day}>
                    <td>{x.day.split('-').reverse().join('.')}.</td>
                    {isSuper ? (
                      <>
                        <td>{fmt(x.rake)}</td>
                        <td>{fmt(x.fees)}</td>
                        <td>{fmt(x.agentsCut)}</td>
                        <td className="plus">{fmt(x.superShare)}</td>
                      </>
                    ) : (
                      <td className="plus">{fmt(x.myCut)}</td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}
