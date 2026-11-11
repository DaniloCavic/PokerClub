import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/brand.dart';
import '../widgets/hand_history.dart';
import 'account_screen.dart';
import 'table_screen.dart';
import 'transactions_screen.dart';

/// Široki ekran (računar, tablet): meni gore. Uzak (telefon): meni dole.
bool isWide(BuildContext context) => MediaQuery.of(context).size.width >= 900;

class NavItem {
  final String label;
  final IconData icon;
  const NavItem(this.label, this.icon);
}

const navItems = [
  NavItem('Poker', Icons.style),
  NavItem('Istorija', Icons.history),
  NavItem('Blagajna', Icons.account_balance_wallet),
  NavItem('Moj profil', Icons.person),
];

/// Glavni okvir aplikacije posle prijave.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final pages = [
      const LobbyView(),
      const _HistoryView(),
      const TransactionsScreen(embedded: true),
      const AccountScreen(embedded: true),
    ];
    final body = LuxBackground(child: IndexedStack(index: _tab, children: pages));
    if (wide) {
      return Scaffold(
        body: Column(children: [
          LuxTopBar(selected: _tab, onSelect: (i) => setState(() => _tab = i)),
          Expanded(child: body),
        ]),
      );
    }
    // Telefon: naslov kluba gore, odmah ispod njega meni (ne dole na dnu ekrana).
    return Scaffold(
      body: Column(children: [
        _PhoneTopBar(onWallet: () => setState(() => _tab = 2)),
        _PhoneTabs(selected: _tab, onSelect: (i) => setState(() => _tab = i)),
        Expanded(child: body),
      ]),
    );
  }
}

/// Meni na telefonu, odmah ispod naslova kluba.
class _PhoneTabs extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  const _PhoneTabs({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: const Color(0xFF0E0B08),
        border: Border(bottom: BorderSide(color: gold.withOpacity(0.35))),
      ),
      child: Row(children: [
        for (var i = 0; i < navItems.length; i++)
          Expanded(
            child: InkWell(
              onTap: () => onSelect(i),
              child: Container(
                decoration: BoxDecoration(
                  gradient: i == selected
                      ? const LinearGradient(
                          colors: [Color(0xFF8E1426), Color(0xFF4A0911)], begin: Alignment.topCenter, end: Alignment.bottomCenter)
                      : null,
                  border: i == selected ? const Border(bottom: BorderSide(color: gold, width: 2)) : null,
                ),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(navItems[i].icon, size: 20, color: i == selected ? goldLight : gold.withOpacity(0.8)),
                  const SizedBox(height: 3),
                  Text(navItems[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w600, color: i == selected ? Colors.white : Colors.white70)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Gornja traka na širokom ekranu: logo, meni, igrač i stanje (kao u dizajnu).
class LuxTopBar extends StatelessWidget {
  final int selected;
  final ValueChanged<int>? onSelect;
  final Widget? leading;
  const LuxTopBar({super.key, required this.selected, this.onSelect, this.leading});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 76,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF15100C), Color(0xFF0B0907)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        border: Border(bottom: BorderSide(color: gold.withOpacity(0.35))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Row(children: [
        if (leading != null) leading!,
        const TrilingLogo(size: 30),
        const SizedBox(width: 24),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (var i = 0; i < navItems.length; i++)
                _TopNavButton(item: navItems[i], selected: i == selected, onTap: onSelect == null ? null : () => onSelect!(i)),
            ]),
          ),
        ),
        const UserChip(),
      ]),
    );
  }
}

class _TopNavButton extends StatelessWidget {
  final NavItem item;
  final bool selected;
  final VoidCallback? onTap;
  const _TopNavButton({required this.item, required this.selected, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 76,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFF8E1426), Color(0xFF4A0911)], begin: Alignment.topCenter, end: Alignment.bottomCenter)
              : null,
          border: selected ? const Border(bottom: BorderSide(color: gold, width: 2)) : null,
        ),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(item.icon, color: selected ? goldLight : gold.withOpacity(0.8), size: 24),
          const SizedBox(height: 4),
          Text(item.label,
              style: TextStyle(color: selected ? Colors.white : Colors.white70, fontWeight: FontWeight.w600, fontSize: 13)),
        ]),
      ),
    );
  }
}

/// Igrač gore desno: slika, ime i stanje u RSD.
class UserChip extends StatelessWidget {
  final bool compact;
  const UserChip({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final u = app.user ?? {};
    final name = u['displayName']?.toString() ?? '';
    final balance = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: gold.withOpacity(0.45)),
      ),
      child: GoldText(rsd(app.balance), style: TextStyle(fontWeight: FontWeight.w800, fontSize: compact ? 14 : 16)),
    );
    if (compact) return balance;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Avatar(name: name, url: u['avatarUrl'] as String?, size: 46, borderColor: gold, borderWidth: 2),
      const SizedBox(width: 10),
      Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        const SizedBox(height: 3),
        balance,
      ]),
    ]);
  }
}

class _PhoneTopBar extends StatelessWidget {
  final VoidCallback onWallet;
  const _PhoneTopBar({required this.onWallet});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final u = app.user ?? {};
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0E0B09),
        border: Border(bottom: BorderSide(color: gold.withOpacity(0.3))),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            const TrilingLogo(size: 20),
            const Spacer(),
            GestureDetector(onTap: onWallet, child: const UserChip(compact: true)),
            const SizedBox(width: 8),
            Avatar(name: u['displayName']?.toString() ?? '', url: u['avatarUrl'] as String?, size: 34, borderColor: gold),
          ]),
        ),
      ),
    );
  }
}

/// Lobi: cash stolovi.
class LobbyView extends StatefulWidget {
  const LobbyView({super.key});

  @override
  State<LobbyView> createState() => _LobbyViewState();
}

class _LobbyViewState extends State<LobbyView> {
  String _filter = 'ALL';
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().joinLobby());
    // Zakazani stolovi se sami otključaju kad dođe vreme.
    _clock = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final seatedAt = ((app.user?['seatedAt'] as List?) ?? []).cast<String>();
    final tables = app.lobby.where((t) => _filter == 'ALL' || t['variant'] == _filter).toList();
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: Column(children: [
          if (!app.connected)
            Container(
              width: double.infinity,
              color: accentDark,
              padding: const EdgeInsets.all(6),
              child: const Text('Povezivanje sa serverom…', textAlign: TextAlign.center, style: TextStyle(fontSize: 13)),
            ),
          Builder(builder: (context) {
            const title =
                GoldText('Cash stolovi', style: TextStyle(fontFamily: 'Cinzel', fontSize: 22, fontWeight: FontWeight.w800));
            final chips = [
              for (final f in const [('ALL', 'Svi'), ('HOLDEM', 'NLH'), ('OMAHA', 'PLO')])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(f.$2),
                    selected: _filter == f.$1,
                    showCheckmark: false,
                    selectedColor: accent,
                    side: BorderSide(color: gold.withOpacity(0.4)),
                    onSelected: (_) => setState(() => _filter = f.$1),
                  ),
                ),
            ];
            // Računar: naslov i izbor u istom redu; telefon: naslov, pa izbor u redu ispod.
            if (isWide(context)) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 10, 8),
                child: Row(children: [title, const Spacer(), ...chips]),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                title,
                const SizedBox(height: 10),
                Row(children: chips),
              ]),
            );
          }),
          Expanded(
            child: RefreshIndicator(
              color: gold,
              onRefresh: () async {
                await app.joinLobby();
                await app.refreshMe();
              },
              child: tables.isEmpty
                  ? ListView(children: const [
                      SizedBox(height: 120),
                      Center(child: Text('Trenutno nema otvorenih stolova.', style: TextStyle(color: Colors.white60))),
                    ])
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                      itemCount: tables.length,
                      itemBuilder: (_, i) => _TableTile(table: tables[i], seated: seatedAt.contains(tables[i]['id'])),
                    ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _TableTile extends StatelessWidget {
  final Map<String, dynamic> table;
  final bool seated;
  const _TableTile({required this.table, required this.seated});

  @override
  Widget build(BuildContext context) {
    final t = table;
    final players = t['players'] as int;
    final max = t['maxSeats'] as int;
    final omaha = t['variant'] == 'OMAHA';
    final opensAt = t['opensAt'] == null ? null : DateTime.parse(t['opensAt'] as String).toLocal();
    final locked = opensAt != null && opensAt.isAfter(DateTime.now());
    void open() {
      if (locked) {
        context.read<AppState>().toast('Sto se otvara ${opensLabel(opensAt)}.');
        return;
      }
      Navigator.push(context, MaterialPageRoute(builder: (_) => TableScreen(tableId: t['id'])));
    }

    final narrow = MediaQuery.of(context).size.width < 500;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: open,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(
                colors: [Color(0xFF2A0D10), Color(0xFF141110)], begin: Alignment.centerLeft, end: Alignment.centerRight),
            border: Border.all(color: seated ? goldLight : gold.withOpacity(0.3), width: seated ? 1.6 : 1),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
          ),
          child: Row(children: [
            // Mini sto sa ulozima
            Container(
              width: narrow ? 64 : 82,
              height: narrow ? 54 : 66,
              decoration: BoxDecoration(
                gradient: const RadialGradient(colors: [feltLight, felt, feltDark]),
                borderRadius: BorderRadius.circular(40),
                border: Border.all(color: gold.withOpacity(0.8), width: 2),
              ),
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(omaha ? 'PLO' : 'NLH', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: goldLight)),
                FittedBox(
                  child: Text('${chips(t['smallBlind'])}/${chips(t['bigBlind'])}',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.white)),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(t['name'],
                        style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
                  ),
                  if (seated) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(gradient: goldGradient, borderRadius: BorderRadius.circular(6)),
                      child:
                          const Text('SEDITE', style: TextStyle(color: Colors.black, fontSize: 9.5, fontWeight: FontWeight.w900)),
                    ),
                  ],
                ]),
                Text(
                  '${omaha ? 'Omaha · pot-limit' : "Texas Hold'em · no-limit"} · Blind ${chips(t['smallBlind'])}/${chips(t['bigBlind'])} RSD',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 3),
                Text('Ulaz ${chips(t['minBuyIn'])} – ${rsd(t['maxBuyIn'])}',
                    style: const TextStyle(fontSize: 12.5, color: goldLight)),
                if (locked)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(children: [
                      const Icon(Icons.lock_clock, size: 14, color: gold),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text('Otvara se ${opensLabel(opensAt)}',
                            style: const TextStyle(fontSize: 12, color: gold, fontWeight: FontWeight.w700)),
                      ),
                    ]),
                  ),
                const SizedBox(height: 5),
                Row(children: [
                  for (var k = 0; k < max; k++)
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 3),
                      decoration: BoxDecoration(shape: BoxShape.circle, color: k < players ? online : Colors.white12),
                    ),
                  const SizedBox(width: 4),
                  Text('$players/$max', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: narrow ? 80 : 92,
              child: LuxButton(
                title: locked ? 'USKORO' : (seated ? 'NASTAVI' : 'IGRAJ'),
                icon: locked ? Icons.lock : null,
                height: 42,
                gradient: locked ? const LinearGradient(colors: [Color(0xFF3A332B), Color(0xFF221D18)]) : buttonGoldGradient,
                textColor: locked ? Colors.white60 : const Color(0xFF2A1A05),
                onTap: open,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Istorija ruku sa svih stolova.
class _HistoryView extends StatelessWidget {
  const _HistoryView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: const Column(children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: GoldText('Istorija ruku', style: TextStyle(fontFamily: 'Cinzel', fontSize: 22, fontWeight: FontWeight.w800)),
            ),
          ),
          Expanded(child: PreviousHands(bigBlind: 0)),
        ]),
      ),
    );
  }
}
