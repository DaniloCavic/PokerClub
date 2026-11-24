import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../push/push.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/brand.dart';
import '../widgets/hand_history.dart';
import 'account_screen.dart';
import 'table_screen.dart';
import 'tournaments.dart';
import 'transactions_screen.dart';
import '../i18n.dart';
import 'leaderboard_screen.dart';

/// Široki ekran (računar, tablet): meni gore. Uzak (telefon): meni dole.
bool isWide(BuildContext context) => MediaQuery.of(context).size.width >= 900;

class NavItem {
  final String label;
  final IconData icon;
  const NavItem(this.label, this.icon);
}

List<NavItem> get navItems => [
      NavItem(tr('Cash Game', 'Keš igra'), Icons.style),
      NavItem(tr('Tournaments', 'Turniri'), Icons.emoji_events),
      NavItem(tr('Ranking', 'Rang lista'), Icons.leaderboard),
      NavItem(tr('History', 'Istorija'), Icons.history),
      NavItem(tr('Cashier', 'Blagajna'), Icons.account_balance_wallet),
      NavItem(tr('Profile', 'Profil'), Icons.person),
    ];

/// Redni brojevi stranica glavnog menija.
const tabCash = 0, tabTournaments = 1, tabRanking = 2, tabHistory = 3, tabCashier = 4, tabProfile = 5;

/// Glavni okvir aplikacije posle prijave.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    // Obaveštenja (sto se otvorio, mesto sa liste čekanja) otvaraju sto jednim dodirom.
    final app = context.read<AppState>();
    app.openTable = (tableId) {
      app.navigatorKey.currentState?.popUntil((r) => r.isFirst);
      app.showTable(tableId);
    };
    // Poruka dobrodošlice i pravila kluba (jednom, i posle svake izmene).
    void showWelcome() {
      final text = app.welcome.value;
      final ctx = app.navigatorKey.currentContext;
      if (text == null || text.trim().isEmpty || ctx == null) return;
      showDialog(
        context: ctx,
        barrierDismissible: false,
        builder: (c) => AlertDialog(
          backgroundColor: panel,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: gold.withOpacity(0.6))),
          title: GoldText(tr('Welcome to Triling!', 'Dobro došli u Triling!'), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20)),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460, maxHeight: 420),
            child: SingleChildScrollView(child: Text(text, style: const TextStyle(height: 1.45))),
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(c);
                app.welcomeSeen();
              },
              child: Text(tr('I understand', 'Razumem')),
            ),
          ],
        ),
      );
    }
    app.welcome.addListener(showWelcome);
    WidgetsBinding.instance.addPostFrameCallback((_) => showWelcome());
    // Kraj turnira (ispadanje ili pobeda): prozor sa mestom i nagradom.
    app.tourResult.addListener(() {
      final r = app.tourResult.value;
      final ctx = app.navigatorKey.currentContext;
      if (r == null || ctx == null) return;
      app.tourResult.value = null;
      // Prvo se odigra kraj ruke (karte, ko je dobio, žetoni), pa tek onda prozor (bar 5 s).
      () async {
        await Future.delayed(const Duration(seconds: 5));
        for (var k = 0; k < 30; k++) {
          final busy = app.openTables.any((id) {
            final st = app.tableNotifier(id).value;
            final t = st?['tournament'] as Map?;
            return t != null && t['id'] == r['tournamentId'] && st!['result'] != null;
          });
          if (!busy) break;
          await Future.delayed(const Duration(milliseconds: 500));
        }
        final c2 = app.navigatorKey.currentContext;
        if (c2 == null || !c2.mounted) return;
        await showDialog(context: c2, builder: (_) => TourResultDialog(r: r));
      }().then((_) {
        // Sto turnira na kome više ne sedite se zatvara.
        for (final id in [...app.openTables]) {
          final st = app.tableNotifier(id).value;
          final t = st?['tournament'] as Map?;
          if (t != null && t['id'] == r['tournamentId'] && (st!['mySeat'] as int) < 0) app.closeTable(id);
        }
      });
      app.refreshMe();
    });
    app.goHome = (i) {
      setState(() => _tab = i);
      app.showLobby();
    };
    // Dodir na obaveštenje dok je aplikacija otvorena.
    WebPush.onOpenTable((id) => app.openTable?.call(id));
    // Posle ponovnog otvaranja (telefon je ugasio stranicu dok je igrač bio u drugoj aplikaciji)
    // igrač se vraća za sto za kojim sedi, ili za sto iz obaveštenja.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Stolovi za kojima igrač sedi otvaraju se sami (vidi AppState._openSeated); obaveštenje otvara svoj sto.
      final fromPush = WebPush.startTable();
      if (fromPush != null) app.openTable?.call(fromPush);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final tables = app.openTables;
    final active = app.activeTable;
    // Ista struktura sa tabovima i bez njih, da se lobi (i stolovi) ne prave iznova.
    // Otvoreni stolovi ostaju živi (IndexedStack): igra teče i dok je igrač na drugom stolu ili u lobiju.
    final content = IndexedStack(
      index: active == null || !tables.contains(active) ? 0 : 1 + tables.indexOf(active),
      children: [
        KeyedSubtree(key: _homeKey, child: _home(context)),
        for (final id in tables) TableScreen(key: ValueKey('table-$id'), tableId: id, active: id == active),
      ],
    );
    return PopScope(
      canPop: active == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) app.showLobby();
      },
      child: ColoredBox(
        color: bg,
        child: Column(children: [
          if (tables.isNotEmpty) TableTabs(key: const ValueKey('tabs'), app: app),
          Expanded(
            key: const ValueKey('content'),
            child: MediaQuery.removePadding(context: context, removeTop: tables.isNotEmpty, child: content),
          ),
        ]),
      ),
    );
  }

  final _homeKey = GlobalKey();

  Widget _home(BuildContext context) {
    final wide = isWide(context);
    final pages = [
      const LobbyView(key: ValueKey('cash')),
      const LobbyView(key: ValueKey('tournaments'), tournaments: true),
      const LeaderboardScreen(embedded: true),
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
        _PhoneTopBar(onWallet: () => setState(() => _tab = tabCashier)),
        _PhoneTabs(selected: _tab, onSelect: (i) => setState(() => _tab = i)),
        Expanded(child: body),
      ]),
    );
  }
}

/// Tabovi otvorenih stolova (iznad svega): Lobby i stolovi; sto na kome ste na potezu svetli.
class TableTabs extends StatelessWidget {
  final AppState app;
  const TableTabs({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final h = wide ? 40.0 : 36.0;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0706),
        border: Border(bottom: BorderSide(color: gold.withOpacity(0.3))),
      ),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: h,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            children: [
              _TabChip(
                selected: app.activeTable == null,
                onTap: app.showLobby,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.home_rounded, size: wide ? 18 : 16, color: app.activeTable == null ? Colors.black : goldLight),
                  const SizedBox(width: 5),
                  Text('Lobby',
                      style: TextStyle(
                          fontSize: wide ? 13 : 12,
                          fontWeight: FontWeight.w800,
                          color: app.activeTable == null ? Colors.black : Colors.white)),
                ]),
              ),
              for (final id in app.openTables)
                ValueListenableBuilder<Map<String, dynamic>?>(
                  valueListenable: app.tableNotifier(id),
                  builder: (context, st, _) => _TableTab(app: app, id: id, st: st, wide: wide),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TableTab extends StatelessWidget {
  final AppState app;
  final String id;
  final Map<String, dynamic>? st;
  final bool wide;
  const _TableTab({required this.app, required this.id, required this.st, required this.wide});

  @override
  Widget build(BuildContext context) {
    final s = st;
    final selected = app.activeTable == id;
    final myTurn = s != null && s['legal'] != null;
    final seated = s != null && (s['mySeat'] as int) >= 0;
    final omaha = s?['variant'] == 'OMAHA';
    final tour = s?['tournament'] as Map<String, dynamic>?;
    // Turnir: naziv turnira i trenutni blajndovi.
    final title = s == null
        ? '…'
        : tour != null
            ? '🏆 ${tour['name']}'
            : '${omaha ? 'PLO' : 'NLH'} ${chips(s['smallBlind'])}/${chips(s['bigBlind'])}';
    final name = tour != null ? '${chips(s?['smallBlind'])}/${chips(s?['bigBlind'])}' : (s?['name'] as String?) ?? '';
    final fg = selected ? Colors.black : Colors.white;
    return _TabChip(
      selected: selected,
      alert: myTurn && !selected,
      onTap: () => app.showTable(id),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (myTurn)
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: selected ? Colors.black : const Color(0xFFE0263F), borderRadius: BorderRadius.circular(6)),
            child: Text(tr('YOUR TURN', 'NA POTEZU'), style: TextStyle(fontSize: wide ? 9.5 : 8.5, fontWeight: FontWeight.w900, color: selected ? goldLight : Colors.white)),
          )
        else if (seated)
          Container(
            width: 7,
            height: 7,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: selected ? Colors.black54 : const Color(0xFF4CD07A), shape: BoxShape.circle),
          ),
        Text(title, style: TextStyle(fontSize: wide ? 13 : 12, fontWeight: FontWeight.w800, color: fg)),
        if (wide && name.isNotEmpty) ...[
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? Colors.black87 : gold)),
          ),
        ],
        const SizedBox(width: 4),
        InkResponse(
          radius: 14,
          onTap: () => leaveTable(context, app, id),
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Icon(Icons.close, size: wide ? 16 : 15, color: selected ? Colors.black87 : Colors.white60),
          ),
        ),
      ]),
    );
  }
}

class _TabChip extends StatefulWidget {
  final bool selected;
  final bool alert;
  final VoidCallback onTap;
  final Widget child;
  const _TabChip({required this.selected, required this.onTap, required this.child, this.alert = false});

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));

  @override
  void initState() {
    super.initState();
    if (widget.alert) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _TabChip old) {
    super.didUpdateWidget(old);
    if (widget.alert && !_pulse.isAnimating) _pulse.repeat(reverse: true);
    if (!widget.alert && _pulse.isAnimating) {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, child) => Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: widget.selected ? goldGradient : null,
                color: widget.selected ? null : Color.lerp(const Color(0xFF1D1513), const Color(0xFF5A0B16), _pulse.value),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    color: widget.alert ? Color.lerp(gold, const Color(0xFFFF5A6E), _pulse.value)! : gold.withOpacity(widget.selected ? 0.9 : 0.35),
                    width: widget.alert ? 1.6 : 1),
              ),
              child: child,
            ),
          ),
        ),
        child: widget.child,
      ),
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
                  // Pet stavki u redu: duži naziv (Tournaments) se malo smanji umesto da se odseče.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(navItems[i].label,
                          maxLines: 1,
                          style: TextStyle(
                              fontSize: 11.5, fontWeight: FontWeight.w600, color: i == selected ? Colors.white : Colors.white70)),
                    ),
                  ),
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
      // Meni je na sredini trake; naziv kluba levo, igrač i stanje desno.
      child: Stack(alignment: Alignment.center, children: [
        Row(children: [
          if (leading != null) leading!,
          const TrilingLogo(size: 30),
          const Spacer(),
          const UserChip(),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          for (var i = 0; i < navItems.length; i++)
            _TopNavButton(item: navItems[i], selected: i == selected, onTap: onSelect == null ? null : () => onSelect!(i)),
        ]),
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
  /// Stranica Tournaments (inače Cash Game).
  final bool tournaments;
  const LobbyView({super.key, this.tournaments = false});

  @override
  State<LobbyView> createState() => _LobbyViewState();
}

class _LobbyViewState extends State<LobbyView> {
  String _filter = 'ALL';
  bool get _tours => widget.tournaments;
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
              child: Text(tr('Connecting to the server…', 'Povezivanje sa serverom…'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
            ),
          const _PushBanner(),
          Builder(builder: (context) {
            final title = GoldText(_tours ? tr('Tournaments', 'Turniri') : tr('Cash Game', 'Keš igra'),
                style: const TextStyle(fontFamily: 'Cinzel', fontSize: 22, fontWeight: FontWeight.w800));
            final chips = [
              for (final f in [('ALL', tr('All', 'Svi')), ('HOLDEM', 'NLH'), ('OMAHA', 'PLO')])
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
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
              child: Column(children: [
                title,
                const SizedBox(height: 10),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: chips),
              ]),
            );
          }),
          if (_tours) Expanded(child: TournamentList(filter: _filter)),
          if (!_tours) Expanded(
            child: RefreshIndicator(
              color: gold,
              onRefresh: () async {
                await app.joinLobby();
                await app.refreshMe();
              },
              child: tables.isEmpty
                  ? ListView(children: [
                      const SizedBox(height: 120),
                      Center(child: Text(tr('No open tables right now.', 'Trenutno nema otvorenih stolova.'), style: const TextStyle(color: Colors.white60))),
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

/// Poziv da igrač uključi obaveštenja na telefonu (novi stolovi, na potezu ste…).
/// Na iPhone-u obaveštenja rade tek kad se sajt doda na početni ekran.
class _PushBanner extends StatefulWidget {
  const _PushBanner();

  @override
  State<_PushBanner> createState() => _PushBannerState();
}

class _PushBannerState extends State<_PushBanner> {
  bool _busy = false;
  bool _hidden = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final status = app.pushStatus;
    if (_hidden || (status != 'default' && status != 'ios-install')) return const SizedBox.shrink();
    final ios = status == 'ios-install';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1712),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: gold.withOpacity(0.5)),
      ),
      child: Row(children: [
        const Icon(Icons.notifications_active, color: goldLight),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            ios
                ? tr('For notifications on iPhone: tap Share (□↑) → “Add to Home Screen”, then open Triling from the home screen.',
                    'Za obaveštenja na iPhone-u: dodirnite Deli (□↑) → „Dodaj na početni ekran“, pa otvorite Triling sa početnog ekrana.')
                : tr('Turn on notifications: new and scheduled tables and tournaments, and your turn while you are in another app.',
                    'Uključite obaveštenja: novi i zakazani stolovi i turniri, i kad ste na potezu dok ste u drugoj aplikaciji.'),
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        if (!ios)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    final ok = await app.enablePush();
                    if (!mounted) return;
                    setState(() => _busy = false);
                    app.toast(ok ? tr('Notifications are on.', 'Obaveštenja su uključena.') : (app.pushError ?? tr('Notifications are not on.', 'Obaveštenja nisu uključena.')));
                  },
            child: Text(tr('TURN ON', 'UKLJUČI'), style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
        IconButton(
          tooltip: tr('Hide', 'Sakrij'),
          onPressed: () => setState(() => _hidden = true),
          icon: const Icon(Icons.close, size: 18, color: Colors.white54),
        ),
      ]),
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
        context.read<AppState>().toast(tr('The table opens ${opensLabel(opensAt)}.', 'Sto se otvara ${opensLabel(opensAt)}.'));
        return;
      }
      context.read<AppState>().showTable(t['id'] as String);
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
                          Text(tr('SEATED', 'SEDITE'), style: const TextStyle(color: Colors.black, fontSize: 9.5, fontWeight: FontWeight.w900)),
                    ),
                  ],
                ]),
                Text(
                  '${omaha ? 'Omaha · pot-limit' : "Texas Hold'em · no-limit"} · Blinds ${chips(t['smallBlind'])}/${chips(t['bigBlind'])}',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 3),
                Text('${tr('Buy-in', 'Ulaz')} ${chips(t['minBuyIn'])} – ${rsd(t['maxBuyIn'])}',
                    style: const TextStyle(fontSize: 12.5, color: goldLight)),
                if (tableExtras(t) != null)
                  Text(tableExtras(t)!, style: const TextStyle(fontSize: 11.5, color: Colors.white54, fontWeight: FontWeight.w600)),
                if (locked)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Row(children: [
                      const Icon(Icons.lock_clock, size: 14, color: gold),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text('${tr('Opens', 'Otvara se')} ${opensLabel(opensAt)} (${countdown(opensAt)})',
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
                  if (((t['waiting'] as int?) ?? 0) > 0)
                    Text(' · ${t['waiting']} ${tr('waiting', 'čeka')}', style: const TextStyle(fontSize: 12, color: gold, fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: narrow ? 80 : 92,
              child: LuxButton(
                title: locked ? tr('SOON', 'USKORO') : (seated ? tr('RESUME', 'NASTAVI') : tr('PLAY', 'IGRAJ')),
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
        child: Column(children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: GoldText(tr('Hand history', 'Istorija ruku'), style: const TextStyle(fontFamily: 'Cinzel', fontSize: 22, fontWeight: FontWeight.w800)),
            ),
          ),
          Expanded(child: PreviousHands(bigBlind: 0)),
        ]),
      ),
    );
  }
}
