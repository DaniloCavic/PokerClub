import { useState } from 'react';
import { api, fmt, fmtDate, TX_LABELS } from '../api';
import { Amount, Pager, useLoad } from './common';

export function Transactions() {
  const [type, setType] = useState('');
  const [page, setPage] = useState(1);
  const { data, error } = useLoad<any>(() => api('GET', `/admin/transactions?page=${page}&type=${type}`), [page, type]);

  return (
    <>
      <div className="row">
        <h2 className="grow">Transakcije</h2>
        <select
          value={type}
          onChange={(e) => {
            setPage(1);
            setType(e.target.value);
          }}
        >
          <option value="">Sve vrste</option>
          {Object.entries(TX_LABELS).map(([k, v]) => (
            <option key={k} value={k}>
              {v}
            </option>
          ))}
        </select>
      </div>
      {error && <div className="error">{error}</div>}
      <div className="card">
        <table>
          <thead>
            <tr>
              <th>Vreme</th>
              <th>Igrač</th>
              <th>Vrsta</th>
              <th>Iznos</th>
              <th>Stanje posle</th>
              <th>Detalji</th>
            </tr>
          </thead>
          <tbody>
            {data?.items.map((t: any) => (
              <tr key={t.id}>
                <td>{fmtDate(t.createdAt)}</td>
                <td>
                  {t.user.displayName} <span className="muted">@{t.user.username}</span>
                </td>
                <td>{TX_LABELS[t.type]}</td>
                <td>
                  <Amount value={t.amount} />
                </td>
                <td>{fmt(t.balanceAfter)}</td>
                <td className="muted">{[t.table, t.actor && `agent: ${t.actor}`, t.note].filter(Boolean).join(' · ')}</td>
              </tr>
            ))}
            {data?.items.length === 0 && (
              <tr>
                <td colSpan={6} className="muted">
                  Nema transakcija.
                </td>
              </tr>
            )}
          </tbody>
        </table>
        {data && <Pager page={page} total={data.total} pageSize={data.pageSize} onPage={setPage} />}
      </div>
    </>
  );
}
