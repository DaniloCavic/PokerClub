/**
 * Poruke igračima na engleskom ili srpskom. Poruke u kodu su napisane na srpskom;
 * ovde je njihov prevod na engleski (podrazumevani jezik aplikacije).
 * Admin panel ostaje na srpskom.
 */

export type Lang = 'en' | 'sr';

export const normLang = (v: unknown): Lang => (v === 'sr' ? 'sr' : 'en');

const DAYS: [RegExp, string][] = [
  [/(?<!\p{L})ponedeljak(?!\p{L})/gu, 'Monday'],
  [/(?<!\p{L})utorak(?!\p{L})/gu, 'Tuesday'],
  [/(?<!\p{L})sreda(?!\p{L})/gu, 'Wednesday'],
  [/(?<!\p{L})četvrtak(?!\p{L})/gu, 'Thursday'],
  [/(?<!\p{L})petak(?!\p{L})/gu, 'Friday'],
  [/(?<!\p{L})subota(?!\p{L})/gu, 'Saturday'],
  [/(?<!\p{L})nedelja(?!\p{L})/gu, 'Sunday'],
];

/** [srpski obrazac, engleski] — $1, $2… su delovi iz obrasca (imena, iznosi). */
const EN: [RegExp, string][] = [
  // ---------- Stolovi ----------
  [/^Sto „(.+)“ je počeo!$/, 'Table “$1” has started!'],
  [/^(PLO|NLH) (\S+) — uđite i igrajte\.$/, '$1 $2 — join and play.'],
  [/^Sto se otvara (.+)\.$/, 'The table opens $1.'],
  [/^Sto nije otvoren\.$/, 'The table is not open.'],
  [/^Poruka je prazna\.$/, 'The message is empty.'],
  [/^Sačekajte trenutak pre sledeće poruke\.$/, 'Wait a moment before the next message.'],
  [/^Samo igrači mogu da pišu u chat\.$/, 'Only players can write in the chat.'],
  [/^Sto se zatvara\.$/, 'The table is closing.'],
  [/^Za turnirski sto se ulazi prijavom na turnir\.$/, 'Register for the tournament to play at this table.'],
  [/^Samo igrači mogu da sednu za sto\.$/, 'Only players can sit at a table.'],
  [/^Već sedite za ovim stolom\.$/, 'You are already seated at this table.'],
  [/^Ne postoji to mesto\.$/, 'That seat does not exist.'],
  [/^Mesto je zauzeto\.$/, 'That seat is taken.'],
  [/^Mesto je rezervisano za igrača sa liste čekanja\.$/, 'The seat is reserved for a player from the waiting list.'],
  [/^Ulaz mora biti između (\S+) i (\S+)\.$/, 'The buy-in must be between $1 and $2.'],
  [/^Nemate dovoljno žetona na nalogu\.$/, 'You do not have enough chips in your account.'],
  [/^Nema dovoljno žetona na nalogu\.$/, 'Not enough chips in your account.'],
  [/^Ne sedite za ovim stolom\.$/, 'You are not seated at this table.'],
  [/^Na turniru se žetoni kupuju kroz rebuy ili add-on\.$/, 'In a tournament, chips are bought with a rebuy or add-on.'],
  [/^Dopuna je moguća tek kad se ruka završi\.$/, 'You can top up when the hand is over.'],
  [/^Neispravan iznos\.$/, 'Invalid amount.'],
  [/^Na stolu možete imati najviše (\S+) \(sada imate (\S+)\)\.$/, 'You can have at most $1 at the table (you have $2).'],
  [/^Sto je pun\.$/, 'The table is full.'],
  [/^Sto je zatvoren\.$/, 'The table is closed.'],
  [/^Sto „(.+)“ — odlučite za (\d+) s\.$/, 'Table “$1” — decide within $2 s.'],
  [/^Na potezu ste!$/, 'Your turn!'],
  [/^Sto „(.+)“ — imate (\d+) s \(\+(\d+) s TIME\)\.$/, 'Table “$1” — you have $2 s (+$3 s time bank).'],
  [/^Predugo niste igrali, žetoni su vraćeni na nalog\.$/, 'You were away too long; your chips went back to your account.'],
  [/^Vreme za rebuy je isteklo, mesto je oslobođeno\.$/, 'Rebuy time is over; your seat was released.'],
  [/^Ostali ste bez žetona$/, 'You are out of chips'],
  [/^Sto „(.+)“ — dopunite ili ustanite u roku od (\d+) min\.$/, 'Table “$1” — rebuy or leave within $2 min.'],
  [/^Nemate karte za pokazivanje\.$/, 'You have no cards to show.'],
  [/^Karte možete pokazati posle fold-a ili kad se ruka završi\.$/, 'You can show your cards after you fold or when the hand is over.'],
  [/^Izaberite kartu\.$/, 'Choose a card.'],
  [/^Nema pitanja za run it twice\.$/, 'There is no run it twice question.'],
  [/^Za ovim stolom nema straddle-a\.$/, 'This table has no straddle.'],
  [/^Samo igrači mogu da igraju\.$/, 'Only players can play.'],
  [/^Mesto je slobodno!$/, 'A seat is free!'],
  [/^Sto „(.+)“ — imate (\d+) s da sednete\.$/, 'Table “$1” — you have $2 s to sit down.'],
  [/^Nalog nije aktivan\.$/, 'The account is not active.'],
  [/^Niste prijavljeni\.$/, 'You are not signed in.'],
  [/^Greška na serveru\. Pokušajte ponovo\.$/, 'Server error. Please try again.'],
  // ---------- Igra ----------
  [/^Mesto je prazno\.$/, 'The seat is empty.'],
  [/^Igrač je u ruci\.$/, 'The player is in a hand.'],
  [/^Nema dovoljno igrača za ruku\.$/, 'Not enough players for a hand.'],
  [/^Niste na potezu\.$/, 'It is not your turn.'],
  [/^Ne možete da čekirate — morate da dorovnate ili odustanete\.$/, 'You cannot check — call or fold.'],
  [/^Nema šta da se dorovna\.$/, 'There is nothing to call.'],
  [/^Povišenje nije dozvoljeno\.$/, 'Raising is not allowed.'],
  [/^Ulog mora biti između (\S+) i (\S+)\.$/, 'The bet must be between $1 and $2.'],
  [/^Nepoznat potez\.$/, 'Unknown action.'],
  // ---------- Turniri ----------
  [/^Turnir ne postoji\.$/, 'The tournament does not exist.'],
  [/^Novi turnir: (.+)$/, 'New tournament: $1'],
  [/^(PLO|NLH) turnir — počinje (.+)\. Ulaz (\d+)(, garantovano (\d+))?\.$/, '$1 tournament — starts $2. Buy-in $3$4.'],
  [/^Turnir nije aktivan\.$/, 'The tournament is not active.'],
  [/^Turnir „(.+)“ je otkazan, ulaz je vraćen\.$/, 'Tournament “$1” was cancelled; your buy-in was refunded.'],
  [/^Turnir „(.+)“ je otkazan \(premalo igrača\), ulaz je vraćen\.$/, 'Tournament “$1” was cancelled (not enough players); your buy-in was refunded.'],
  [/^Prijave za ovaj turnir nisu otvorene\.$/, 'Registration for this tournament is not open.'],
  [/^Samo igrači mogu da igraju turnire\.$/, 'Only players can play tournaments.'],
  [/^Prijave su zatvorene\.$/, 'Registration is closed.'],
  [/^Već ste prijavljeni\.$/, 'You are already registered.'],
  [/^Nemate više pravo na re-entry\.$/, 'You have no re-entries left.'],
  [/^Turnir je popunjen\.$/, 'The tournament is full.'],
  [/^Turnir je već počeo, odjava nije moguća\.$/, 'The tournament has started; you cannot unregister.'],
  [/^Ne igrate na ovom turniru\.$/, 'You are not playing in this tournament.'],
  [/^Rebuy trenutno nije moguć\.$/, 'Rebuy is not available now.'],
  [/^Add-on trenutno nije moguć\.$/, 'Add-on is not available now.'],
  [/^Turnir „(.+)“ počinje za 5 minuta$/, 'Tournament “$1” starts in 5 minutes'],
  [/^Otvorite aplikaciju da ne propustite početak\.$/, 'Open the app so you do not miss the start.'],
  // ---------- Nalog ----------
  [/^Unesite korisničko ime\.$/, 'Enter your username.'],
  [/^Unesite lozinku\.$/, 'Enter your password.'],
  [/^Nova lozinka mora imati bar 6 znakova\.$/, 'The new password must have at least 6 characters.'],
  [/^Lozinka mora imati bar 6 znakova\.$/, 'The password must have at least 6 characters.'],
  [/^Beleška može imati najviše 500 znakova\.$/, 'A note can have at most 500 characters.'],
  [/^Nedostaje slika\.$/, 'The picture is missing.'],
  [/^Slika je prevelika \(najviše 300 KB\)\.$/, 'The picture is too big (max 300 KB).'],
  [/^Pogrešno korisničko ime ili lozinka\.$/, 'Wrong username or password.'],
  [/^Nalog trenutno nije aktivan\. Javite se svom agentu\.$/, 'The account is not active right now. Contact your agent.'],
  [/^Stara lozinka nije tačna\.$/, 'The old password is not correct.'],
  [/^Podržane su samo JPG, PNG i WebP slike\.$/, 'Only JPG, PNG and WebP pictures are supported.'],
  [/^Nedostaje sto ili igrač\.$/, 'Table or player is missing.'],
  [/^Sto nije pronađen\.$/, 'Table not found.'],
  [/^Ne možete pisati belešku o sebi\.$/, 'You cannot write a note about yourself.'],
  [/^Igrač nije pronađen\.$/, 'Player not found.'],
  [/^Nemate prava za ovu radnju\.$/, 'You are not allowed to do this.'],
  [/^Sesija je istekla\. Prijavite se ponovo\.$/, 'Your session has expired. Please sign in again.'],
  [/^Nalog ne postoji\.$/, 'The account does not exist.'],
  [/^Nalog je blokiran: (.+)$/, 'The account is blocked: $1'],
  [/^Nalog je blokiran\.$/, 'The account is blocked.'],
  [/^Iznos mora biti ceo broj veći od nule\.$/, 'The amount must be a whole number greater than zero.'],
  [/^Neispravna pretplata\.$/, 'Invalid subscription.'],
  [/^Neispravni podaci\.$/, 'Invalid data.'],
  [/^Korisničko ime je zauzeto\.$/, 'That username is taken.'],
  [/^Korisničko ime: 3–20 znakova, samo slova bez kvačica, brojevi, tačka i donja crta\.$/, 'Username: 3–20 characters, letters without accents, digits, dot and underscore.'],
  [/^Ime za prikaz mora imati bar 2 znaka\.$/, 'The display name must have at least 2 characters.'],
  [/^Ime za prikaz može imati najviše 30 znakova\.$/, 'The display name can have at most 30 characters.'],
  [/^Kod agenta ne postoji\.$/, 'That agent code does not exist.'],
  [/^Agent sa ovim kodom trenutno nije aktivan\.$/, 'The agent with this code is not active right now.'],
  [/^Unesite ispravnu e-poštu\.$/, 'Enter a valid email.'],
  [/^Nalog sa ovom e-poštom već postoji\.$/, 'An account with this email already exists.'],
  [/^Kod ima 6 cifara\.$/, 'The code has 6 digits.'],
  [/^Kod nije tačan ili je istekao\.$/, 'The code is wrong or has expired.'],
  [/^Previše pogrešnih pokušaja\. Pokušajte ponovo za (\d+) min\.$/, 'Too many wrong attempts. Try again in $1 min.'],
  [/^Kod za dvostepenu prijavu nije tačan\.$/, 'The two-step verification code is not correct.'],
  // ---------- Beleške uz transakcije ----------
  [/^dopuna$/, 'top-up'],
  [/^Server je ponovo pokrenut$/, 'Server restarted'],
  [/^Ulaz: (.+)$/, 'Buy-in: $1'],
  [/^Re-entry: (.+)$/, 'Re-entry: $1'],
  [/^Odjava: (.+)$/, 'Unregistered: $1'],
  [/^(\d+)\. mesto: (.+)$/, 'Place #$1: $2'],
  [/^Turnir je otkazan: (.+)$/, 'Tournament cancelled: $1'],
  [/^Nedovoljno igrača: (.+)$/, 'Not enough players: $1'],
  [/^ThrottlerException: Too Many Requests$/, 'Too many attempts. Wait a minute and try again.'],
];

/** Prevod poruke na jezik igrača (srpski ostaje kakav jeste). */
export function tr(msg: string, lang: Lang | string | null | undefined): string {
  if (!msg || normLang(lang) === 'sr') return msg;
  for (const [re, en] of EN) {
    if (re.test(msg)) {
      re.lastIndex = 0;
      let out = msg.replace(re, en).replace(/, garantovano (\d+)/, ', guaranteed $1');
      for (const [d, e] of DAYS) out = out.replace(d, e);
      return out;
    }
  }
  return msg;
}

/** Jezik igrača (po korisniku), da poruke i obaveštenja stižu na izabranom jeziku. */
export const userLang = new Map<string, Lang>();
export const trUser = (msg: string, userId: string) => tr(msg, userLang.get(userId) ?? 'en');
