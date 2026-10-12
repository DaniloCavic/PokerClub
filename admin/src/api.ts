const TOKEN_KEY = 'poker_admin_token';

export function getToken() {
  return localStorage.getItem(TOKEN_KEY);
}
export function setToken(t: string | null) {
  if (t) localStorage.setItem(TOKEN_KEY, t);
  else localStorage.removeItem(TOKEN_KEY);
}

export class ApiError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

export async function api<T = any>(method: string, path: string, body?: unknown): Promise<T> {
  const token = getToken();
  const res = await fetch(`/api${path}`, {
    method,
    headers: {
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await res.json().catch(() => null);
  if (!res.ok) {
    if (res.status === 401) {
      setToken(null);
      window.dispatchEvent(new Event('poker-logout'));
    }
    throw new ApiError(data?.message || `Greška ${res.status}`, res.status);
  }
  return data as T;
}

export interface Me {
  id: string;
  username: string;
  displayName: string;
  role: 'PLAYER' | 'AGENT' | 'ADMIN';
}

export const fmtDate = (s?: string | null) => (s ? new Date(s).toLocaleString('sr-RS') : '—');
export const fmt = (n?: number | null) => (n ?? 0).toLocaleString('sr-RS');

export const TX_LABELS: Record<string, string> = {
  DEPOSIT: 'Uplata',
  WITHDRAWAL: 'Isplata',
  BUY_IN: 'Ulaz za sto',
  CASH_OUT: 'Povratak sa stola',
};

export const VARIANT_LABELS: Record<string, string> = { HOLDEM: "Hold'em (no-limit)", OMAHA: 'Omaha (pot-limit)' };

/** Karta "As" → "A♠" sa bojom. */
export function cardLabel(c: string) {
  const suit = { s: '♠', h: '♥', d: '♦', c: '♣' }[c[1]] ?? '?';
  return { text: `${c[0] === 'T' ? '10' : c[0]}${suit}`, red: c[1] === 'h' || c[1] === 'd' };
}
