import { ReactNode, useEffect, useState } from 'react';
import { cardLabel, fmt } from '../api';

export function Drawer({ onClose, children }: { onClose: () => void; children: ReactNode }) {
  useEffect(() => {
    const esc = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', esc);
    return () => window.removeEventListener('keydown', esc);
  }, [onClose]);
  return (
    <div className="modal-bg" onClick={onClose}>
      <div className="drawer" onClick={(e) => e.stopPropagation()}>
        <button className="secondary close" onClick={onClose}>
          ✕
        </button>
        {children}
      </div>
    </div>
  );
}

export function Pager({ page, total, pageSize, onPage }: { page: number; total: number; pageSize: number; onPage: (p: number) => void }) {
  const pages = Math.max(1, Math.ceil(total / pageSize));
  if (pages <= 1) return null;
  return (
    <div className="pager">
      <button className="secondary" disabled={page <= 1} onClick={() => onPage(page - 1)}>
        ‹
      </button>
      <span className="muted">
        {page} / {pages}
      </span>
      <button className="secondary" disabled={page >= pages} onClick={() => onPage(page + 1)}>
        ›
      </button>
    </div>
  );
}

export function Amount({ value }: { value: number }) {
  return <span className={value > 0 ? 'plus' : value < 0 ? 'minus' : ''}>{value > 0 ? `+${fmt(value)}` : fmt(value)}</span>;
}

export function Cards({ cards }: { cards: string }) {
  if (!cards) return <span className="muted">—</span>;
  return (
    <span className="cards">
      {cards.split(' ').map((c, i) => {
        const l = cardLabel(c);
        return (
          <span key={i} className={`card-chip ${l.red ? 'red' : ''}`}>
            {l.text}
          </span>
        );
      })}
    </span>
  );
}

/** Mali hook: učitaj podatke i omogući ponovno učitavanje. */
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[] = []) {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState('');
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let alive = true;
    fn()
      .then((d) => alive && (setData(d), setError('')))
      .catch((e) => alive && setError(e.message));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  return { data, error, reload: () => setTick((t) => t + 1) };
}
