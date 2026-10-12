# Poker klub

Aplikacija za cash poker za **virtuelne žetone** (bez novčane vrednosti): Texas Hold'em (no-limit) i Omaha (pot-limit).
Agenti otvaraju stolove, prave i blokiraju igrače, uplaćuju i isplaćuju žetone. Igrači igraju u mobilnoj aplikaciji.

| Folder | Šta je | Tehnologija |
|---|---|---|
| `backend/` | Server: nalozi, žetoni, stolovi uživo, pravila pokera, API za agente | NestJS (TypeScript), PostgreSQL (Prisma), Socket.IO |
| `admin/` | Admin panel za agente i administratora (server ga servira na `/admin`) | React + Vite |
| `mobile/` | Aplikacija za igrače: Android, iPhone i web (server je servira na `/igra`) | Flutter |

Server deli karte, meri vreme i računa dobitke. Telefon samo prikazuje stanje i šalje poteze,
pa igrač ne može da vidi tuđe karte niti da prevari izmenom aplikacije.

## Uloge

- **Administrator** (pravi se automatski pri prvom pokretanju iz `ADMIN_USERNAME` / `ADMIN_PASSWORD`):
  pravi i blokira agente, vidi sve igrače, stolove i transakcije, može da premesti igrača drugom agentu.
- **Agent** (prijava u admin panel na `/admin`): pravi svoje igrače, uplaćuje i isplaćuje im žetone,
  blokira ih, podiže ih sa stola, otvara i zatvara svoje stolove i bira rake. Vidi samo svoje igrače i stolove.
  Blokada agenta privremeno blokira i sve njegove igrače.
- **Igrač** (prijava u aplikaciji): bira sto, seda sa delom žetona sa naloga, igra, dopunjuje žetone i ustaje.

## Šta je urađeno

**Igra**
- Texas Hold'em no-limit (2 karte) i Omaha pot-limit (4 karte, tačno 2 iz ruke + 3 sa stola).
- Stolovi za 2–9 igrača, dugme i blajndovi (i pravila za igru jedan na jedan), uloge, povišenja sa ispravnim
  najmanjim povišenjem, nepotpun all-in ne otvara ponovo povišenje, glavni i sporedni potovi, vraćanje nepokrivenog uloga,
  podela pota, neparni žeton levo od dugmeta.
- Mešanje karata kriptografski sigurnim generatorom slučajnih brojeva.
- Vreme za potez (podešava se po stolu). Kad istekne: check ako može, inače fold, i igrač ide na pauzu dok se ne vrati.
- Igrač na pauzi ili bez žetona duže od 10 minuta automatski ustaje i žetoni se vraćaju na nalog.
- Rake po stolu: procenat (0–10 %) i najveći iznos po ruci. Uzima se samo kad se podeli flop („no flop, no drop").
- Istorija svake ruke: karte svih igrača, sto, tok ruke, dobici i rake (vidi je agent u admin panelu).

**Žetoni**
- Svaka promena stanja (uplata, isplata, ulaz za sto, povratak sa stola) je stavka u knjizi transakcija sa stanjem posle promene.
  Stavke se ne brišu.
- Isplata je moguća samo do iznosa na nalogu. Žetoni sa stola se vraćaju na nalog kad igrač ustane.
- Ako se server ponovo pokrene usred ruke, ta ruka se poništava, a svaki igrač dobija nazad žetone koje je imao na početku ruke.

**Admin panel**: pregled (igrači, žetoni na nalozima i stolovima, uplate i isplate danas, rake), stolovi (pravljenje,
zatvaranje, ko sedi, podizanje sa stola, istorija ruku), igrači (pravljenje, uplata, isplata, blokada, nova lozinka,
istorija), transakcije, agenti (samo administrator).

**Aplikacija za igrače**: prijava, lobi sa filterom Hold'em/Omaha, sto sa sedištima oko stola, karte u četiri boje,
tajmer, Fold / Check / Call / Bet / Raise sa brzim izborom (½ pota, ¾ pota, pot, all-in), ulaz i dopuna žetona,
pauza, nalog sa istorijom i promenom lozinke.

## Pokretanje na računaru

Potrebno: Node.js 22, PostgreSQL 16, Flutter 3.24 (samo za aplikaciju).

```bash
# 1. Server
cd backend
cp .env.example .env          # upišite DATABASE_URL, JWT_SECRET, ADMIN_USERNAME, ADMIN_PASSWORD
npm install
npx prisma migrate deploy     # pravi tabele u bazi
npm run dev                   # http://localhost:3000

# 2. Admin panel (u drugom prozoru)
cd admin
npm install
npm run dev                   # http://localhost:5173/admin/

# 3. Aplikacija (Android emulator, iPhone simulator ili pregledač)
cd mobile
flutter pub get
flutter run                   # ili: flutter run -d chrome
```

Za probu stola bez drugih ljudi pokrenite botove koji sednu i igraju:

```bash
cd backend
API_URL=http://localhost:3000 ADMIN_USERNAME=admin ADMIN_PASSWORD=... TABLE_ID=<id stola> BOTS=3 npm run bots
```

ID stola piše u admin panelu kad otvorite sto.

## Postavljanje na internet (Railway)

1. Na [railway.com](https://railway.com) napravite projekat iz ovog GitHub repozitorijuma i dodajte **PostgreSQL** bazu.
2. U servisu aplikacije podesite promenljive:
   - `DATABASE_URL` = `${{Postgres.DATABASE_URL}}`
   - `JWT_SECRET` = dug nasumičan tekst
   - `ADMIN_USERNAME`, `ADMIN_PASSWORD` = prvi administrator
3. Railway sam gradi sve iz `Dockerfile`-a. Posle objave:
   - `https://<adresa>/admin` — admin panel za agente
   - `https://<adresa>/igra` — aplikacija za igrače u pregledaču (na iPhone-u: Deli → Dodaj na početni ekran)

Na sopstvenom serveru isto radi `docker compose up -d --build` (vidi `docker-compose.yml`).

## Android aplikacija

GitHub → Settings → Secrets and variables → Actions → **Variables** → dodajte `API_URL` sa adresom servera
(npr. `https://poker-klub.up.railway.app`). Zatim GitHub → Actions → **Android APK** → Run workflow.
Gotov APK je u Artifacts (`poker-klub-apk`).

Ručno: `cd mobile && flutter build apk --release --dart-define=API_URL=https://vasa-adresa`.

## Testovi

```bash
cd backend && npm test        # pravila pokera: ocena ruku, potovi, rake, Omaha, 300 nasumičnih partija
cd mobile && flutter test
```

`backend/scripts/smoke.ts` proverava ceo sistem na pokrenutom serveru: agent, igrači, uplate i isplate, dva stola,
igru preko Socket.IO, blokadu usred igre, zatvaranje stolova i da je zbir žetona na nalozima + rake jednak uplaćenom.

```bash
API_URL=http://localhost:3000 ADMIN_USERNAME=admin ADMIN_PASSWORD=... npm run smoke
```

## Važno

Igra je napravljena za virtuelne žetone bez novčane vrednosti. Organizovanje igara na sreću za pravi novac
zahteva dozvolu (u Srbiji je izdaje Uprava za igre na sreću).
