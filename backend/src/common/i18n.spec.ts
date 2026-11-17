import { tr } from './i18n';

describe('prevod poruka igračima', () => {
  it('engleski je podrazumevan, srpski ostaje kakav jeste', () => {
    expect(tr('Nemate dovoljno žetona na nalogu.', 'en')).toBe('You do not have enough chips in your account.');
    expect(tr('Nemate dovoljno žetona na nalogu.', undefined)).toBe('You do not have enough chips in your account.');
    expect(tr('Nemate dovoljno žetona na nalogu.', 'sr')).toBe('Nemate dovoljno žetona na nalogu.');
  });

  it('poruke sa iznosima, imenima i danima', () => {
    expect(tr('Ulaz mora biti između 400 i 4000.', 'en')).toBe('The buy-in must be between 400 and 4000.');
    expect(tr('Sto „NL 10/20“ — imate 15 s (+30 s TIME).', 'en')).toBe('Table “NL 10/20” — you have 15 s (+30 s time bank).');
    expect(tr('Sto se otvara četvrtak, 12. 11. 18:00.', 'en')).toBe('The table opens Thursday, 12. 11. 18:00.');
    expect(tr('NLH turnir — počinje petak, 13. 11. 20:00. Ulaz 1100, garantovano 20000.', 'en')).toBe(
      'NLH tournament — starts Friday, 13. 11. 20:00. Buy-in 1100, guaranteed 20000.',
    );
    expect(tr('Nalog je blokiran: dug', 'en')).toBe('The account is blocked: dug');
  });

  it('nepoznata poruka ostaje ista', () => {
    expect(tr('Nešto sasvim novo', 'en')).toBe('Nešto sasvim novo');
  });
});
