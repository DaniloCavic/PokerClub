import { useEffect, useState } from 'react';
import { api } from '../api';

/** Poruka dobrodošlice i pravila kluba: igrač je vidi jednom (i ponovo posle svake izmene). */
export function Welcome() {
  const [en, setEn] = useState('');
  const [sr, setSr] = useState('');
  const [msg, setMsg] = useState('');
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    api('GET', '/admin/welcome').then((d) => {
      setEn(d.en);
      setSr(d.sr);
    });
  }, []);
  async function save() {
    setBusy(true);
    try {
      await api('POST', '/admin/welcome', { en, sr });
      setMsg('Sačuvano. Svaki igrač će poruku videti pri sledećem otvaranju aplikacije.');
    } catch (e) {
      setMsg((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <>
      <h2>Poruka dobrodošlice i pravila</h2>
      <p className="muted small">
        Igrač je vidi u prozoru kad prvi put otvori aplikaciju. Kad je izmenite, svi je vide ponovo. Ako je prazna, ne prikazuje se.
      </p>
      <div className="card">
        <label className="block">
          Engleski (podrazumevani jezik aplikacije)
          <textarea rows={10} value={en} onChange={(e) => setEn(e.target.value)} placeholder={'Welcome to Poker klub Triling!\n\nRules:\n1. ...'} />
        </label>
        <label className="block">
          Srpski (za igrače koji izaberu srpski)
          <textarea rows={10} value={sr} onChange={(e) => setSr(e.target.value)} placeholder={'Dobro došli u Poker klub Triling!\n\nPravila:\n1. ...'} />
        </label>
        {msg && <div className="success">{msg}</div>}
        <button disabled={busy} onClick={save}>
          Sačuvaj i prikaži igračima
        </button>
      </div>
    </>
  );
}
