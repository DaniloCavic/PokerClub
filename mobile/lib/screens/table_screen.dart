import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/action_bar.dart';
import '../widgets/avatar.dart';
import '../widgets/hand_history.dart';
import '../widgets/playing_card.dart';
import '../widgets/table_chat.dart';
import '../widgets/brand.dart';
import '../widgets/chips.dart';
import 'home_shell.dart';

typedef Json = Map<String, dynamic>;

/// Potez izabran unapred, dok igrač još nije na redu.
enum PreAction { checkFold, callAny }

class TableScreen extends StatefulWidget {
  final String tableId;
  const TableScreen({super.key, required this.tableId});

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> {
  late final AppState app;
  Timer? _ticker;
  PreAction? _pre;
  int _preHand = -1;
  bool _sending = false;

  /// Sakrivene karte su privremeno otkrivene (dodir na svoje karte).
  bool _peek = false;
  int _rebuyHand = -1;
  final _scaffold = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    app = context.read<AppState>();
    app.watch(widget.tableId).then((ok) {
      // Sto nije dostupan (npr. zakazan za kasnije): vrati se u lobi.
      if (!ok && mounted) Navigator.of(context).maybePop();
    });
    app.tableNotifier(widget.tableId).addListener(_onState);
    // Osvežavanje tajmera za potez.
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final st = app.tableNotifier(widget.tableId).value;
      if (mounted && st?['deadline'] != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    app.tableNotifier(widget.tableId).removeListener(_onState);
    app.unwatch(widget.tableId);
    app.refreshMe();
    super.dispose();
  }

  /// Kad igrač dođe na red, a ima izabran potez unapred — odigraj ga odmah.
  void _onState() {
    final st = app.tableNotifier(widget.tableId).value;
    if (st != null) _autoRebuy(st);
    if (st == null || _pre == null || _sending) return;
    if (st['handNo'] != _preHand) {
      setState(() => _pre = null);
      return;
    }
    final legal = st['legal'] as Json?;
    if (legal == null) return;
    final pre = _pre!;
    _pre = null;
    final canCheck = legal['check'] == true;
    final action = canCheck ? 'check' : (pre == PreAction.callAny ? 'call' : 'fold');
    _sending = true;
    app.run('table:act', {'tableId': widget.tableId, 'action': action}).whenComplete(() => _sending = false);
  }

  /// Automatski re-buy: kad igrač ostane bez novca na stolu, dopuni do najvećeg ulaza.
  void _autoRebuy(Json st) {
    final mySeat = st['mySeat'] as int;
    if (!app.autoRebuy || mySeat < 0) return;
    final me = (st['seats'] as List)[mySeat] as Json;
    if (me['stack'] != 0 || me['inHand'] == true || _rebuyHand == st['handNo']) return;
    final amount = min(st['maxBuyIn'] as int, app.balance);
    if (amount <= 0) return;
    _rebuyHand = st['handNo'] as int;
    app.run('table:topup', {'tableId': widget.tableId, 'amount': amount});
  }

  void _setPre(Json st, PreAction? p) {
    setState(() {
      _pre = _pre == p ? null : p;
      _preHand = st['handNo'] as int;
    });
  }

  Future<bool> _confirmLeave(Json? st) async {
    final seated = st != null && (st['mySeat'] as int) >= 0;
    if (!seated) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Napustiti sto?'),
        content: Text(st['inProgress'] == true
            ? 'Ako ste u ruci, odustajete od nje. Novac sa stola se vraća na vaš nalog.'
            : 'Novac sa stola se vraća na vaš nalog.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Ostani')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ustani')),
        ],
      ),
    );
    if (ok != true) return false;
    await app.run('table:leave', {'tableId': widget.tableId});
    return true;
  }

  Future<void> _back(Json? st) async {
    final nav = Navigator.of(context);
    if (await _confirmLeave(st)) nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final showBB = context.select<AppState, bool>((a) => a.showBB);
    context.select<AppState, bool>((a) => a.hideCards);
    context.select<AppState, bool>((a) => a.fourColor);
    return ValueListenableBuilder<Json?>(
      valueListenable: app.tableNotifier(widget.tableId),
      builder: (context, st, _) {
        final money = Money((st?['bigBlind'] as int?) ?? 0, showBB);
        final wide = MediaQuery.of(context).size.width >= 900;
        return PopScope(
          canPop: st == null || (st['mySeat'] as int) < 0,
          onPopInvokedWithResult: (didPop, _) async {
            if (!didPop) await _back(st);
          },
          child: Scaffold(
            key: _scaffold,
            backgroundColor: bg,
            // Telefon: igrači, ruke i chat u panelu koji se izvlači sa desne strane.
            endDrawer: st == null || wide
                ? null
                : Drawer(
                    width: min(380, MediaQuery.of(context).size.width * 0.88),
                    backgroundColor: const Color(0xFF0E0B09),
                    child: SafeArea(child: TableSidePanel(st: st, table: app.tableNotifier(widget.tableId), money: money)),
                  ),
            onEndDrawerChanged: (open) {
              app.openChat = open ? widget.tableId : null;
              if (open) app.unreadOf(widget.tableId).value = 0;
            },
            body: LuxBackground(
              child: st == null ? const Center(child: CircularProgressIndicator(color: gold)) : _body(st, money, wide),
            ),
          ),
        );
      },
    );
  }

  Widget _tableArea(Json st, Money money, bool wide) {
    return LayoutBuilder(builder: (_, c) {
      // Sto zadržava dobru srazmeru i stoji u sredini.
      final w = min(c.maxWidth, c.maxHeight * 1.6);
      final h = min(c.maxHeight, w * 2.0);
      return Center(
        child: SizedBox(
          width: w,
          height: h,
          child: ValueListenableBuilder<List<Json>>(
            valueListenable: app.chatOf(widget.tableId),
            builder: (_, chat, __) => _TableView(
              st: st,
              size: Size(w, h),
              money: money,
              chat: chat,
              wide: wide,
              hideMine: app.hideCards && !_peek,
              onTapMine: () => setState(() => _peek = !_peek),
              onSit: (i) => _sit(st, i),
            ),
          ),
        ),
      );
    });
  }

  Widget _panel(Json st, Money money, bool wide) {
    final mySeat = st['mySeat'] as int;
    if (mySeat < 0) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('Dodirnite slobodno mesto da sednete za sto.', style: TextStyle(color: Colors.white60, fontSize: 13)),
      );
    }
    return _MyPanel(
      st: st,
      app: app,
      money: money,
      wide: wide,
      pre: _pre,
      onPre: (p) => _setPre(st, p),
      onTopUp: () => _topUp(st, (st['seats'] as List)[mySeat] as Json),
    );
  }

  Widget _body(Json st, Money money, bool wide) {
    final mySeat = st['mySeat'] as int;
    if (wide) {
      // Računar: gornji meni, sto u sredini, igrači/ruke/chat desno, potezi dole (kao u dizajnu).
      app.openChat = widget.tableId;
      return Column(children: [
        LuxTopBar(
          selected: 0,
          onSelect: (_) => _back(st),
          leading: IconButton(
            tooltip: 'Nazad u lobi',
            onPressed: () => _back(st),
            icon: const Icon(Icons.arrow_back_ios_new, color: gold, size: 20),
          ),
        ),
        Expanded(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(children: [
                Positioned.fill(
                    child: Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 0), child: _tableArea(st, money, true))),
                Positioned(left: 14, top: 12, child: _TableInfoCard(st: st)),
                Positioned(
                  right: 14,
                  top: 12,
                  child: Row(children: [
                    _UnitToggle(showBB: money.inBB, onToggle: app.setShowBB),
                    if (mySeat >= 0) ...[
                      const SizedBox(width: 8),
                      _RoundIcon(icon: Icons.menu, tip: 'Meni', onTap: () => _menu(st)),
                    ],
                  ]),
                ),
              ]),
            ),
            SizedBox(
              width: 340,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 12, 12, 12),
                child: TableSidePanel(st: st, table: app.tableNotifier(widget.tableId), money: money, wide: true),
              ),
            ),
          ]),
        ),
        _panel(st, money, true),
      ]);
    }
    return SafeArea(
      child: Column(children: [
        _TopBar(
          st: st,
          showBB: money.inBB,
          onBack: () => _back(st),
          onToggle: app.setShowBB,
          onPanel: () => _scaffold.currentState?.openEndDrawer(),
          unread: app.unreadOf(widget.tableId),
          onMenu: mySeat >= 0 ? () => _menu(st) : null,
        ),
        Expanded(child: _tableArea(st, money, false)),
        _panel(st, money, false),
      ]),
    );
  }

  void _menu(Json st) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final sittingOut = me['sittingOut'] == true;
    showModalBottomSheet(
      context: context,
      backgroundColor: panel,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.add_circle),
            title: const Text('Dopuni'),
            onTap: () {
              Navigator.pop(ctx);
              _topUp(st, me);
            },
          ),
          ListTile(
            leading: Icon(sittingOut ? Icons.play_arrow : Icons.pause),
            title: Text(sittingOut ? 'Vrati se u igru' : 'Pauza (preskoči ruke)'),
            onTap: () {
              Navigator.pop(ctx);
              app.run('table:sitout', {'tableId': widget.tableId, 'value': !sittingOut});
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout, color: accent),
            title: const Text('Ustani sa stola'),
            onTap: () async {
              Navigator.pop(ctx);
              await _back(st);
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _sit(Json st, int seat) async {
    final min = st['minBuyIn'] as int;
    final max = st['maxBuyIn'] as int;
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => ChipsDialog(
        title: 'Ulaz za sto',
        min: min,
        max: max,
        balance: app.balance,
        confirm: 'Sedi',
        info: 'Blind ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} RSD · ulaz ${rsd(min)} – ${rsd(max)}',
      ),
    );
    if (amount == null) return;
    await app.run('table:sit', {'tableId': widget.tableId, 'seat': seat, 'buyIn': amount});
  }

  Future<void> _topUp(Json st, Json me) async {
    final room = (st['maxBuyIn'] as int) - (me['stack'] as int);
    if (room <= 0) {
      app.toast('Već imate najviše koliko sme na ovom stolu.');
      return;
    }
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => ChipsDialog(
        title: 'Dopuna',
        min: 1,
        max: room,
        balance: app.balance,
        confirm: 'Dopuni',
        info: 'Na stolu imate ${rsd(me['stack'])}, najviše ${rsd(st['maxBuyIn'])}. Dopuna važi od sledeće ruke.',
      ),
    );
    if (amount == null) return;
    await app.run('table:topup', {'tableId': widget.tableId, 'amount': amount});
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final String tip;
  final VoidCallback? onTap;
  const _RoundIcon({required this.icon, required this.tip, this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tip,
        child: InkResponse(
          onTap: onTap,
          radius: 22,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Colors.black45,
              shape: BoxShape.circle,
              border: Border.all(color: gold.withOpacity(0.45)),
            ),
            child: Icon(icon, size: 18, color: goldLight),
          ),
        ),
      );
}

/// Prekidač prikaza iznosa: dinari ili veliki blajndovi.
class _UnitToggle extends StatelessWidget {
  final bool showBB;
  final ValueChanged<bool> onToggle;
  const _UnitToggle({required this.showBB, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: Colors.black45, borderRadius: BorderRadius.circular(18), border: Border.all(color: gold.withOpacity(0.45))),
      padding: const EdgeInsets.all(3),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final opt in const [(false, 'RSD'), (true, 'BB')])
          GestureDetector(
            onTap: () => onToggle(opt.$1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration:
                  BoxDecoration(gradient: showBB == opt.$1 ? goldGradient : null, borderRadius: BorderRadius.circular(14)),
              child: Text(opt.$2,
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w800, color: showBB == opt.$1 ? Colors.black : Colors.white70)),
            ),
          ),
      ]),
    );
  }
}

/// Kartica gore levo: igra, blajndovi i naziv stola.
class _TableInfoCard extends StatelessWidget {
  final Json st;
  const _TableInfoCard({required this.st});

  @override
  Widget build(BuildContext context) {
    final omaha = st['variant'] == 'OMAHA';
    return LuxPanel(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      radius: 12,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Row(mainAxisSize: MainAxisSize.min, children: [
          PlayingCard(width: 22),
          SizedBox(width: 2),
          PlayingCard(width: 22),
        ]),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(omaha ? 'Omaha' : "Texas Hold'em", style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          Text('${omaha ? 'PLO' : 'NLH'} ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} RSD',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          Text(st['name'] as String, style: const TextStyle(color: gold, fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
      ]),
    );
  }
}

/// Telefon: sitne kontrole na vrhu (nazad, meni, sto, RSD/BB, panel sa igračima i chatom).
class _TopBar extends StatelessWidget {
  final Json st;
  final bool showBB;
  final VoidCallback onBack;
  final VoidCallback onPanel;
  final VoidCallback? onMenu;
  final ValueNotifier<int> unread;
  final ValueChanged<bool> onToggle;
  const _TopBar({
    required this.st,
    required this.showBB,
    required this.onBack,
    required this.onPanel,
    required this.onToggle,
    required this.unread,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    final omaha = st['variant'] == 'OMAHA';
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(children: [
        _RoundIcon(icon: Icons.arrow_back_ios_new, tip: 'Nazad', onTap: onBack),
        const SizedBox(width: 6),
        if (onMenu != null) _RoundIcon(icon: Icons.menu, tip: 'Meni', onTap: onMenu),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${omaha ? 'PLO' : 'NLH'} ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} RSD',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
            Text(st['name'] as String,
                overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: gold, fontWeight: FontWeight.w600)),
          ]),
        ),
        _UnitToggle(showBB: showBB, onToggle: onToggle),
        const SizedBox(width: 6),
        // Panel: igrači, ruke i chat (sa brojem nepročitanih poruka)
        ValueListenableBuilder<int>(
          valueListenable: unread,
          builder: (_, n, __) => Stack(clipBehavior: Clip.none, children: [
            _RoundIcon(icon: Icons.forum_outlined, tip: 'Igrači, ruke i chat', onTap: onPanel),
            if (n > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(8)),
                  child: Text(n > 9 ? '9+' : '$n', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Bočni panel: igrači za stolom, ruke i chat (desno na računaru, izvlači se na telefonu).
class TableSidePanel extends StatelessWidget {
  final Json st;
  final ValueNotifier<Json?> table;
  final Money money;
  final bool wide;
  const TableSidePanel({super.key, required this.st, required this.table, required this.money, this.wide = false});

  @override
  Widget build(BuildContext context) {
    final players = (st['seats'] as List).cast<Json?>().whereType<Json>().toList();
    final playersList = ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        for (final p in players)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p['sittingOut'] == true ? Colors.white24 : online),
              ),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(p['name'] as String,
                      overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
              Text(money(p['stack']), style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
          ),
        if (players.isEmpty)
          const Padding(
              padding: EdgeInsets.all(16), child: Text('Niko ne sedi za stolom.', style: TextStyle(color: Colors.white54))),
      ],
    );
    Widget tabs(List<String> labels) => Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(10)),
          child: TabBar(
            dividerHeight: 0,
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(gradient: redGradient, borderRadius: BorderRadius.circular(8)),
            tabs: [for (final l in labels) Tab(height: 34, text: l)],
          ),
        );
    if (wide) {
      // Kao u dizajnu: gore igrači / ruke, dole chat.
      return Column(children: [
        Expanded(
          flex: 5,
          child: LuxPanel(
            padding: EdgeInsets.zero,
            child: DefaultTabController(
              length: 2,
              child: Column(children: [
                tabs(['Igrači (${players.length})', 'Ruke']),
                Expanded(
                  child: TabBarView(children: [playersList, HandHistoryTabs(tableId: st['id'] as String, table: table)]),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          flex: 4,
          child: LuxPanel(
            padding: EdgeInsets.zero,
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(gradient: redGradient, borderRadius: BorderRadius.circular(8)),
                    child: const Text('Chat', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ]),
              ),
              Expanded(child: TableChatView(tableId: st['id'] as String, compact: true)),
            ]),
          ),
        ),
      ]);
    }
    return DefaultTabController(
      length: 3,
      child: Column(children: [
        const Padding(padding: EdgeInsets.only(top: 12), child: TrilingLogo(size: 22)),
        tabs(['Igrači (${players.length})', 'Ruke', 'Chat']),
        Expanded(
          child: TabBarView(children: [
            playersList,
            HandHistoryTabs(tableId: st['id'] as String, table: table),
            TableChatView(tableId: st['id'] as String, compact: true),
          ]),
        ),
      ]),
    );
  }
}

/// Naziv i boja poteza za prikaz kod igrača.
({String label, Color color}) actLabel(Json act, Money money) {
  final amount = act['amount'] as int? ?? 0;
  return switch (act['type'] as String) {
    'ante' => (label: 'ANTE', color: const Color(0xFF4A4F5C)),
    'sb' => (label: 'SB', color: const Color(0xFF4A4F5C)),
    'bb' => (label: 'BB', color: const Color(0xFF4A4F5C)),
    'fold' => (label: 'FOLD', color: const Color(0xFF2B2F38)),
    'check' => (label: 'CHECK', color: const Color(0xFF2E7D5B)),
    'call' => (label: 'CALL', color: const Color(0xFF1B6FD8)),
    'bet' => (label: 'BET', color: const Color(0xFFE07A18)),
    'raise' => (label: 'RAISE', color: accent),
    'allin' => (label: 'ALL-IN ${money(amount)}', color: const Color(0xFF9B1BD8)),
    _ => (label: '', color: Colors.black),
  };
}

/// Raspored stola: gde su sedišta, ulozi i pot (isti proračun za crtanje i za animacije).
class _Layout {
  final Size size;
  final int n;
  final int base;
  final int mySeat;
  final bool wide;
  _Layout(this.size, this.n, this.base, this.mySeat, {this.wide = false});

  double get w => size.width;
  double get h => size.height;
  Offset get center => Offset(w / 2, h * 0.5);
  double get cardW => min(min(w, h) > 600 ? 46.0 : 38.0, (w * 0.56) / 5 - 4);
  double get boardTop => center.dy - cardW * 1.4 / 2 - 6;
  double get potTop => boardTop - (min(w, h) > 600 ? 48 : 38);

  /// Gomila žetona sakupljenog pota (ispod karata, kao u velikim aplikacijama).
  /// Žetoni glavnog pota: iznad karata, odmah iznad natpisa POT.
  Offset get pile => Offset(center.dx, potTop - 10);

  Offset seat(int i) {
    final k = (i - base + n) % n;
    final angle = pi / 2 + 2 * pi * k / n;
    return center + Offset(w * 0.40 * cos(angle), h * 0.41 * sin(angle));
  }

  Offset dir(int i) {
    final d = center - seat(i);
    return d / max(1.0, d.distance);
  }

  /// Prostor koji zauzima sedište: avatar sa kartama i pločica sa oznakom ispod.
  List<Rect> seatRects(int i) {
    final p = seat(i);
    final a = wide ? 64.0 : 48.0;
    final half = wide ? 64.0 : 52.0;
    return [
      Rect.fromLTRB(p.dx - a / 2 - 6, p.dy - a / 2 - 16, p.dx + (a + 50) / 2 + 2, p.dy + a / 2),
      Rect.fromLTRB(p.dx - half, p.dy + a / 2 - 6, p.dx + half, p.dy + a / 2 + (wide ? 70 : 53)),
    ];
  }

  /// Prostor koji zauzima gomila uloga (žetoni i iznos) postavljena u tački b.
  Rect betBox(Offset b) => Rect.fromLTRB(b.dx - 31, b.dy - 24, b.dx + 31, b.dy + (wide ? 22 : 18));

  /// Sredina stola: žetoni pota, natpis POT i zajedničke karte.
  List<Rect> get middleRects {
    final boardW = 5 * (cardW + 4);
    final pileHalf = wide ? 36.0 : 28.0;
    return [
      Rect.fromLTRB(center.dx - pileHalf, potTop - (wide ? 40 : 34), center.dx + pileHalf, potTop),
      Rect.fromLTRB(center.dx - 74, potTop - 2, center.dx + 74, boardTop),
      Rect.fromLTRB(center.dx - boardW / 2 - 4, boardTop, center.dx + boardW / 2 + 4, boardTop + cardW * 1.4 + 4),
    ];
  }

  /// Gde stoji ulog igrača u tekućoj rundi (odvojeno od svih avatara, pločica,
  /// pota i karata): gornjim igračima pravo ispod oznake, igračima sa strane
  /// pored pločice u visini steka, donjim igračima i meni iznad karata.
  Offset bet(int i) {
    final p = seat(i);
    if (i == mySeat) {
      final a = wide ? 76.0 : 58.0;
      final top = min(p.dy - a / 2, h - a - 56);
      return Offset(p.dx, top - (wide ? 26 : 22));
    }
    final d = dir(i);
    final a = wide ? 64.0 : 48.0;
    final blocked = [for (var k = 0; k < n; k++) ...seatRects(k).map((r) => r.inflate(3)), ...middleRects];
    bool free(Offset b) {
      final r = betBox(b);
      return r.left > 4 && r.right < w - 4 && !blocked.any(r.overlaps);
    }

    final vertical = d.dy.abs() > 0.75;
    final start = vertical ? p : Offset(p.dx, p.dy + a / 2 + (wide ? 20 : 14));
    final v = vertical ? Offset(0, d.dy.sign) : Offset(d.dx.sign, 0);
    // Ako ne staje u visini steka, probaj malo više (ka avataru).
    for (var lift = 0.0; lift <= (vertical ? 0 : 40); lift += 8) {
      for (var dist = 0.0; dist < 220; dist += 2) {
        final b = start + v * dist - Offset(0, lift);
        if (free(b)) return b;
      }
    }
    // Rezerva: pravo ka sredini, samo da ne bude preko svoje pločice.
    final own = seatRects(i).map((r) => r.inflate(3)).toList();
    for (var dist = 20.0; dist < 260; dist += 3) {
      final b = p + d * dist;
      if (!own.any(betBox(b).overlaps)) return b;
    }
    return p + d * 60;
  }

  Offset dealer(int i) {
    final p = seat(i);
    if (i == mySeat) return Offset(p.dx - 62, min(p.dy, h - 104) - 30);
    final d = dir(i);
    return p + d * 48 + Offset(-d.dy, d.dx) * 40;
  }
}

/// Žetoni u letu: od uloga ka potu, ili od pota ka pobedniku.
class _Flight {
  final Key key;
  final Offset from;
  final Offset to;
  final String label;
  final int delayMs;
  final int amount;
  _Flight(this.from, this.to, this.label, this.amount, {this.delayMs = 0}) : key = UniqueKey();
}

/// Veliki ovalni sto preko celog ekrana. Igrač je uvek dole u sredini.
class _TableView extends StatefulWidget {
  final Json st;
  final Size size;
  final Money money;
  final List<Json> chat;
  final bool wide;

  /// Svoje karte prikaži poleđinom (podešavanje "Sakrij karte").
  final bool hideMine;
  final VoidCallback onTapMine;
  final void Function(int seat) onSit;
  const _TableView({
    required this.st,
    required this.size,
    required this.money,
    required this.chat,
    required this.onSit,
    required this.onTapMine,
    this.wide = false,
    this.hideMine = false,
  });

  @override
  State<_TableView> createState() => _TableViewState();
}

class _TableViewState extends State<_TableView> {
  final List<_Flight> _flights = [];
  static const _flyMs = 450;

  _Layout _layoutFor(Json st) {
    final n = (st['seats'] as List).length;
    final my = st['mySeat'] as int;
    return _Layout(widget.size, n, my >= 0 ? my : 0, my, wide: widget.wide);
  }

  @override
  void didUpdateWidget(covariant _TableView old) {
    super.didUpdateWidget(old);
    final a = old.st, b = widget.st;
    if (a['handNo'] != b['handNo'] && b['inProgress'] == true) return; // nova ruka: ništa ne leti
    final lay = _layoutFor(b);
    final oldSeats = (a['seats'] as List).cast<Json?>();
    final newSeats = (b['seats'] as List).cast<Json?>();
    final streetEnded = a['inProgress'] == true && (a['street'] != b['street'] || b['inProgress'] != true);
    final added = <_Flight>[];
    var delay = 0;
    if (streetEnded) {
      // Kraj runde: ulozi svih igrača klize na sredinu stola.
      for (var i = 0; i < oldSeats.length; i++) {
        final bet = (oldSeats[i]?['bet'] as int?) ?? 0;
        if (bet > 0) added.add(_Flight(lay.bet(i), lay.pile, widget.money(bet), bet));
      }
      if (added.isNotEmpty) delay = _flyMs + 100;
    }
    final result = b['result'] as Json?;
    if (result != null && a['result'] == null) {
      // Kraj ruke: pot putuje do pobednika.
      final won = <int, int>{};
      for (final p in (result['pots'] as List)) {
        for (final win in (p['winners'] as List)) {
          won[win['seat'] as int] = (won[win['seat'] as int] ?? 0) + (win['amount'] as int);
        }
      }
      won.forEach((seat, amount) {
        if (seat < newSeats.length && newSeats[seat] != null) {
          added.add(_Flight(lay.pile, lay.seat(seat), widget.money(amount), amount, delayMs: delay));
        }
      });
    }
    if (added.isEmpty) return;
    setState(() => _flights.addAll(added));
    final keys = added.map((f) => f.key).toSet();
    Future.delayed(Duration(milliseconds: delay + _flyMs + 200), () {
      if (mounted) setState(() => _flights.removeWhere((f) => keys.contains(f.key)));
    });
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.st;
    final money = widget.money;
    final seats = (st['seats'] as List).cast<Json?>();
    final n = seats.length;
    final mySeat = st['mySeat'] as int;
    final lay = _layoutFor(st);
    final w = lay.w, h = lay.h;
    final app = context.read<AppState>();
    final seatW = widget.wide ? 124.0 : 88.0;

    final result = st['result'] as Json?;
    final won = <int, int>{};
    for (final p in (result?['pots'] as List? ?? [])) {
      for (final win in (p['winners'] as List)) {
        won[win['seat'] as int] = (won[win['seat'] as int] ?? 0) + (win['amount'] as int);
      }
    }
    final best = <String>{};
    for (final s in (result?['shown'] as List? ?? [])) {
      if (won.containsKey(s['seat'])) best.addAll((s['best'] as List).cast<String>());
    }
    final board = (st['board'] as List).cast<String>();
    final cardW = lay.cardW;
    final boardTop = lay.boardTop;
    final collected = (st['collected'] as int?) ?? 0;
    // Dok žetoni lete ka sredini, gomila pota još pokazuje stari iznos.
    final flyingIn = _flights.any((f) => f.to == lay.pile);

    final children = <Widget>[
      // Sto: zlatna linija, kožna ivica, zlatna linija i bordo čoja
      Positioned(
        left: w * 0.08,
        top: h * 0.05,
        width: w * 0.84,
        height: h * 0.90,
        child: Container(
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(w),
            gradient: goldGradient,
            boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 30, spreadRadius: 4)],
          ),
          child: Container(
            padding: EdgeInsets.all(min(w, h) * 0.028),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(w),
              gradient: const LinearGradient(
                  colors: [Color(0xFF3A2A1E), Color(0xFF140D09)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
            ),
            child: Container(
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(w), gradient: goldGradient),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(w),
                  gradient: const RadialGradient(colors: [feltLight, felt, feltDark], stops: [0, 0.65, 1], radius: 0.9),
                ),
              ),
            ),
          ),
        ),
      ),
      // Znak kluba i podaci o igri na čoji (ispod pota)
      Positioned(
        left: 0,
        right: 0,
        top: lay.pile.dy + 28,
        child: IgnorePointer(child: _FeltInfo(st: st, w: min(w, h * 0.75), logoOnly: true)),
      ),
      // POT iznad karata
      Positioned(
        left: 0,
        right: 0,
        top: lay.potTop,
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: (st['pot'] as int) > 0 ? 1 : 0,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: widget.wide ? 22 : 14, vertical: widget.wide ? 6 : 4),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                    colors: [Color(0xFF1C130D), Color(0xFF0A0706)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: gold, width: 1.5),
                boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 8)],
              ),
              child: GoldText('POT: ${money(st['pot'])}',
                  style: TextStyle(fontSize: widget.wide ? 19 : 14, fontWeight: FontWeight.w800)),
            ),
          ),
        ),
      ),
      // Karte na stolu: svaka nova karta "padne" na sto
      Positioned(
        left: 0,
        right: 0,
        top: boardTop,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var k = 0; k < board.length; k++)
              Padding(
                key: ValueKey('board-${st['handNo']}-${board[k]}'),
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: 1),
                  duration: Duration(milliseconds: 300 + (k < 3 ? k * 120 : 0)),
                  curve: Curves.easeOutBack,
                  builder: (_, t, child) => Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Transform.translate(
                        offset: Offset(0, (1 - t) * -24), child: Transform.scale(scale: 0.7 + 0.3 * t, child: child)),
                  ),
                  child: PlayingCard(
                      code: board[k],
                      width: cardW,
                      highlight: best.contains(board[k]),
                      dim: best.isNotEmpty && !best.contains(board[k])),
                ),
              ),
          ],
        ),
      ),
      // Sakupljeni pot: gomila žetona i iznos ispod karata
      // Žetoni glavnog pota iznad natpisa POT (iznos piše na natpisu)
      if (collected > 0 && !flyingIn)
        Positioned(
          left: lay.pile.dx - 50,
          top: lay.pile.dy - 22,
          width: 100,
          child: Center(child: ChipStacks(amount: collected, bigBlind: st['bigBlind'] as int, chipSize: widget.wide ? 25 : 19)),
        ),
      if (result != null || st['closing'] == true)
        Positioned(
          left: 0,
          right: 0,
          top: boardTop + cardW * 1.4 + 6,
          child: Center(
            child: result != null
                ? _ResultText(result: result, money: money)
                : const Text('Sto se zatvara posle ove ruke.', style: TextStyle(color: gold, fontSize: 12)),
          ),
        ),
    ];

    // Ulozi, dugme i poruke crtaju se posle igrača, da ih pločice ne prekriju.
    final overlays = <Widget>[];
    for (var i = 0; i < n; i++) {
      final s = seats[i];
      final p = lay.seat(i);
      if (s == null) {
        if (mySeat >= 0) continue;
        children.add(Positioned(
          left: p.dx - 27,
          top: p.dy - 27,
          child: GestureDetector(
            onTap: () => widget.onSit(i),
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFF1B1D21),
                border: Border.all(color: Colors.white24, width: 1.5),
              ),
              child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.keyboard_double_arrow_down, size: 16, color: Colors.white70),
                Text('Sedi', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        ));
        continue;
      }
      final isMe = i == mySeat;
      final bet = s['bet'] as int;
      if (bet > 0) {
        // Ulog "doklizi" od igrača do svog mesta ispred njega.
        final target = lay.bet(i);
        overlays.add(TweenAnimationBuilder<Offset>(
          key: ValueKey('bet-${st['handNo']}-${st['street']}-$i'),
          tween: Tween(begin: p, end: target),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
          builder: (_, o, child) => Positioned(left: o.dx - 50, top: o.dy - 22, width: 100, child: child!),
          child: _ChipPile(text: money(bet), amount: bet, bigBlind: st['bigBlind'] as int, big: widget.wide),
        ));
      }
      // Poslednja poruka igrača iz chata (do 6 sekundi) iznad njegovog avatara.
      final recent = widget.chat.lastWhere(
        (m) => m['userId'] == s['userId'] && app.serverNow - (m['at'] as int) < 6000,
        orElse: () => const {},
      );
      if (recent.isNotEmpty) {
        overlays.add(Positioned(
          left: p.dx - 70,
          top: p.dy - 62,
          width: 140,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: Text(recent['text'] as String,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black, fontSize: 11)),
            ),
          ),
        ));
      }
      // Vreme za potez: prvo osnovno vreme, pa TIME (dodatno vreme).
      double? timeLeft;
      int? bankLeft;
      final deadline = st['deadline'] as int?;
      final bankAt = st['timeBankAt'] as int?;
      if (st['toAct'] == i && deadline != null) {
        final now = app.serverNow;
        if (bankAt != null && now < bankAt) {
          timeLeft = ((bankAt - now) / ((st['actionSeconds'] as int) * 1000)).clamp(0.0, 1.0);
        } else {
          final bankMs = ((st['timeBankSeconds'] as num?) ?? 30) * 1000;
          timeLeft = ((deadline - now) / bankMs).clamp(0.0, 1.0);
          bankLeft = ((deadline - now) / 1000).ceil().clamp(0, 999);
        }
      }
      // Sedište je centrirano na avatar; svoje malo podignuto da stane cela pločica.
      final avatarSize = widget.wide ? (isMe ? 76.0 : 64.0) : (isMe ? 58.0 : 48.0);
      final topY = isMe ? min(p.dy - avatarSize / 2, h - avatarSize - 56) : p.dy - avatarSize / 2;
      children.add(Positioned(
        left: p.dx - seatW / 2,
        top: topY,
        width: seatW,
        child: _SeatView(
          seat: s,
          isMe: isMe,
          hideCards: isMe && widget.hideMine,
          onTap: isMe ? widget.onTapMine : null,
          avatarSize: avatarSize,
          won: won[i],
          timeLeft: timeLeft,
          timeBankLeft: bankLeft,
          best: best,
          money: money,
          handName: (result?['shown'] as List?)
              ?.cast<Json>()
              .where((x) => x['seat'] == i)
              .map((x) => x['handName'] as String)
              .firstOrNull,
        ),
      ));
    }

    // Dugme dilera klizi do sledećeg dilera.
    final button = st['button'] as int? ?? -1;
    if (button >= 0 && button < n && seats[button] != null) {
      final d = lay.dealer(button);
      overlays.add(AnimatedPositioned(
        key: const ValueKey('dealer-button'),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
        left: d.dx - 10,
        top: d.dy - 10,
        child: Container(
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: gold, width: 2),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 3)],
          ),
          alignment: Alignment.center,
          child: const Text('D', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 10)),
        ),
      ));
    }

    // Žetoni u letu
    for (final f in _flights) {
      overlays.add(TweenAnimationBuilder<double>(
        key: f.key,
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: f.delayMs + _flyMs),
        builder: (_, t, child) {
          final delayFrac = f.delayMs / (f.delayMs + _flyMs);
          final u = Curves.easeInOut.transform(((t - delayFrac) / (1 - delayFrac)).clamp(0.0, 1.0));
          final o = Offset.lerp(f.from, f.to, u)!;
          return Positioned(
              left: o.dx - 50, top: o.dy - 22, width: 100, child: Opacity(opacity: t < delayFrac ? 0 : 1, child: child));
        },
        child: _ChipPile(text: f.label, amount: f.amount, bigBlind: st['bigBlind'] as int, big: widget.wide),
      ));
    }

    return Stack(clipBehavior: Clip.none, children: [...children, ...overlays]);
  }
}

/// Gomila pravih žetona sa iznosom ispod (ulog igrača ili pot na sredini).
class _ChipPile extends StatelessWidget {
  final String text;
  final int amount;
  final int bigBlind;
  final bool big;
  const _ChipPile({required this.text, required this.amount, required this.bigBlind, this.big = false});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ChipStacks(amount: amount, bigBlind: bigBlind, chipSize: big ? 22 : 16),
      const SizedBox(height: 2),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: gold.withOpacity(0.35), width: 0.8),
        ),
        child: Text(text, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: big ? 13 : 11.5)),
      ),
    ]);
  }
}

/// Natpis na čoji: znak kluba, naziv stola i pravila igre.
class _FeltInfo extends StatelessWidget {
  final Json st;
  final double w;
  /// Na računaru su podaci o stolu u kartici gore levo, pa se na čoji vidi samo znak kluba.
  final bool logoOnly;
  const _FeltInfo({required this.st, required this.w, this.logoOnly = false});

  @override
  Widget build(BuildContext context) {
    final omaha = st['variant'] == 'OMAHA';
    const faint = TextStyle(fontSize: 10.5, color: Color(0x99E8D9A8), height: 1.35);
    return Column(children: [
      // Znak kluba na čoji: zlatni, providan
      Opacity(
        opacity: 0.55,
        child: Column(children: [
          GoldText('♠', style: TextStyle(fontSize: w * 0.05, height: 1)),
          GoldText('TRILING', style: TextStyle(fontFamily: 'Cinzel', fontSize: w * 0.075, fontWeight: FontWeight.w800, height: 1)),
          GoldText('— POKER KLUB —',
              style: TextStyle(fontFamily: 'Cinzel', fontSize: w * 0.025, fontWeight: FontWeight.w600, letterSpacing: 3)),
        ]),
      ),
      if (!logoOnly) ...[
      const SizedBox(height: 6),
      Text(st['name'] as String, style: faint.copyWith(fontWeight: FontWeight.w700)),
      Text('${omaha ? 'Omaha pot-limit' : "Hold'em no-limit"} · Blind ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} RSD',
          style: faint),
      Text('Ante ${chips(st['ante'] ?? 0)} RSD · Ulaz ${chips(st['minBuyIn'])} – ${rsd(st['maxBuyIn'])}', style: faint),
      ],
    ]);
  }
}

class _ResultText extends StatelessWidget {
  final Json result;
  final Money money;
  const _ResultText({required this.result, required this.money});

  @override
  Widget build(BuildContext context) {
    final pots = (result['pots'] as List).cast<Json>();
    final lines = <String>[];
    for (var k = 0; k < pots.length; k++) {
      final p = pots[k];
      final names = (p['winners'] as List).map((w) => w['name']).join(' i ');
      final prefix = pots.length > 1 ? (k == 0 ? 'Glavni: ' : 'Sporedni: ') : '';
      lines.add('$prefix$names +${money(p['amount'])}${p['handName'] != null ? ' · ${p['handName']}' : ''}');
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), borderRadius: BorderRadius.circular(10)),
      child: Text(lines.join('\n'),
          textAlign: TextAlign.center, style: const TextStyle(color: gold, fontWeight: FontWeight.w800, fontSize: 11.5)),
    );
  }
}

/// Igrač: avatar sa malim kartama preko njega, ispod ime i stek.
class _SeatView extends StatelessWidget {
  final Json seat;
  final bool isMe;
  final double avatarSize;
  final int? won;
  final double? timeLeft;

  /// Sekunde preostale od dodatnog vremena (TIME), ako je osnovno isteklo.
  final int? timeBankLeft;
  final String? handName;
  final Set<String> best;
  final Money money;

  /// Svoje karte sakrivene (poleđina) dok ih igrač ne dodirne.
  final bool hideCards;
  final VoidCallback? onTap;
  const _SeatView({
    required this.seat,
    required this.isMe,
    required this.avatarSize,
    this.hideCards = false,
    this.onTap,
    this.timeBankLeft,
    required this.won,
    required this.best,
    required this.money,
    this.timeLeft,
    this.handName,
  });

  @override
  Widget build(BuildContext context) {
    final cards = (seat['cards'] as List?)?.cast<String>();
    final count = seat['cardCount'] as int;
    final folded = seat['folded'] == true;
    final acting = timeLeft != null;
    final name = seat['name'] as String;
    final away = seat['sittingOut'] == true && seat['inHand'] != true;
    final act = seat['lastAct'] as Json?;
    final a = avatarSize;

    // Oznaka ispod pločice: pobeda, potez ili stanje igrača.
    ({String label, Color color})? tag;
    final bank = timeBankLeft != null;
    const timeColor = Color(0xFFFF9F1C);
    if (acting && bank) {
      // Osnovno vreme je isteklo: teče dodatno vreme.
      tag = (label: 'TIME $timeBankLeft', color: timeColor);
    } else if (won != null) {
      tag = (label: 'WIN +${money(won)}', color: gold);
    } else if (handName != null) {
      tag = (label: handName!, color: Colors.black87);
    } else if (act != null && !acting) {
      tag = actLabel(act, money);
    } else if (seat['leaving'] == true) {
      tag = (label: 'USTAJE', color: const Color(0xFF2B2F38));
    } else if (away) {
      tag = (label: 'PAUZA', color: const Color(0xFF2B2F38));
    } else if (seat['stack'] == 0 && seat['inHand'] != true) {
      tag = (label: 'PRAZAN STEK', color: const Color(0xFF2B2F38));
    }

    // Karte preko gornjeg dela avatara: svoje i otvorene licem, tuđe poleđinom.
    Widget? cardsWidget;
    final scale = a / 50;
    if (cards != null && cards.isNotEmpty) {
      final cw = (isMe ? (cards.length > 2 ? 28.0 : 34.0) : (cards.length > 2 ? 19.0 : 24.0)) * (isMe ? scale * 0.86 : scale);
      cardsWidget = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var k = 0; k < cards.length; k++)
          Transform.translate(
            offset: Offset(-k * cw * 0.14, 0),
            child: Transform.rotate(
              angle: (k - (cards.length - 1) / 2) * 0.07,
              child: hideCards && won == null
                  ? PlayingCard(width: cw)
                  : PlayingCard(code: cards[k], width: cw, dim: folded && !isMe, highlight: best.contains(cards[k])),
            ),
          ),
      ]);
    } else if (count > 0 && !folded) {
      final cw = 21.0 * scale;
      cardsWidget = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var k = 0; k < count; k++)
          Transform.translate(
            offset: Offset(-k * cw * 0.45, 0),
            child: Transform.rotate(angle: (k - (count - 1) / 2) * 0.12, child: PlayingCard(width: cw)),
          ),
      ]);
    }

    final avatar = SizedBox(
      width: a + 8,
      height: a + 8,
      child: Stack(alignment: Alignment.center, children: [
        Avatar(
          name: name,
          url: seat['avatarUrl'] as String?,
          size: a,
          borderColor: won != null ? goldLight : (acting ? winGreen : gold),
          borderWidth: won != null || acting ? 3 : 2.2,
          shadow: [
            const BoxShadow(color: Colors.black54, blurRadius: 4),
            if (won != null) const BoxShadow(color: Color(0xAAF2C14E), blurRadius: 14),
          ],
        ),
        if (acting)
          SizedBox(
            width: a + 8,
            height: a + 8,
            child: CircularProgressIndicator(
              value: timeLeft,
              strokeWidth: 3.5,
              color: bank ? (timeLeft! < 0.3 ? accent : timeColor) : winGreen,
              backgroundColor: Colors.black38,
            ),
          ),
      ]),
    );

    final big = a >= 60;
    final plate = Container(
      constraints: BoxConstraints(minWidth: big ? 104 : (isMe ? 84 : 76)),
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: big ? 4 : 2),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xF21E1914), Color(0xF20C0A08)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: acting ? (bank ? timeColor : winGreen) : gold.withOpacity(0.55), width: acting ? 1.6 : 1),
        boxShadow: const [BoxShadow(color: Colors.black87, blurRadius: 6)],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: big ? 13.5 : 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: big ? 9 : 7,
            height: big ? 9 : 7,
            margin: const EdgeInsets.only(right: 5),
            decoration: BoxDecoration(shape: BoxShape.circle, color: seat['sittingOut'] == true ? Colors.white24 : online),
          ),
          seat['allIn'] == true
              ? Text('ALL-IN', style: TextStyle(fontWeight: FontWeight.w800, fontSize: big ? 15 : 12, color: accent))
              : GoldText(money(seat['stack']), style: TextStyle(fontWeight: FontWeight.w800, fontSize: big ? 16 : 12)),
        ]),
        // Traka vremena za potez ispod steka
        if (acting)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: timeLeft,
                minHeight: 3,
                color: bank ? timeColor : goldLight,
                backgroundColor: Colors.white10,
              ),
            ),
          ),
      ]),
    );

    return Opacity(
      opacity: (folded && !isMe) || away ? 0.5 : 1,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Avatar i karte preko njega
        GestureDetector(
          onTap: onTap,
          child: SizedBox(
            width: a + 50,
            height: a + 8,
            child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
              avatar,
              // Svoje karte iznad avatara; tuđe (poleđine) gore desno, kao u dizajnu
              if (cardsWidget != null)
                isMe ? Positioned(top: -a * 0.02, child: cardsWidget) : Positioned(top: -a * 0.18, right: 0, child: cardsWidget),
            ]),
          ),
        ),
        Transform.translate(offset: const Offset(0, -6), child: plate),
        if (tag != null)
          Transform.translate(
            offset: const Offset(0, -4),
            child: _Pop(
              key: ValueKey(won != null ? 'win-${seat['userId']}' : 'tag'),
              pop: won != null,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 130),
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: big ? 2.5 : 1.5),
                decoration: BoxDecoration(color: tag.color, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  tag.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: big ? 11.5 : 10, fontWeight: FontWeight.w900, color: won != null ? Colors.black : Colors.white),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

/// Oznaka koja "iskoči" kad se pojavi (WIN).
class _Pop extends StatelessWidget {
  final bool pop;
  final Widget child;
  const _Pop({super.key, required this.pop, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!pop) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.3, end: 1),
      duration: const Duration(milliseconds: 500),
      curve: Curves.elasticOut,
      builder: (_, t, c) => Transform.scale(scale: t, child: c),
      child: child,
    );
  }
}

/// Donji deo: potezi (kao u dizajnu). Na računaru i podešavanja "Sakrij karte" i "Automatski re-buy".
class _MyPanel extends StatelessWidget {
  final Json st;
  final AppState app;
  final Money money;
  final bool wide;
  final PreAction? pre;
  final void Function(PreAction p) onPre;
  final VoidCallback onTopUp;
  const _MyPanel({
    required this.st,
    required this.app,
    required this.money,
    required this.pre,
    required this.onPre,
    required this.onTopUp,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final legal = st['legal'] as Json?;
    final tableId = st['id'] as String;
    final myHand = st['myHand'] as String?;
    final inHand = me['inHand'] == true && me['folded'] != true && st['inProgress'] == true;
    final h = wide ? 64.0 : 48.0;

    Widget? bottom;
    if (legal != null) {
      bottom = ActionBar(
        legal: legal,
        pot: st['pot'] as int,
        myBet: me['bet'] as int,
        myStack: me['stack'] as int,
        bigBlind: st['bigBlind'] as int,
        potLimit: st['variant'] == 'OMAHA',
        money: money,
        wide: wide,
        onAction: (action, [amount]) =>
            app.run('table:act', {'tableId': tableId, 'action': action, if (amount != null) 'amount': amount}),
      );
    } else if (me['sittingOut'] == true) {
      bottom = LuxButton(
        title: 'Vrati se u igru',
        icon: Icons.play_arrow,
        height: h,
        onTap: () => app.run('table:sitout', {'tableId': tableId, 'value': false}),
      );
    } else if (me['stack'] == 0 && me['inHand'] != true) {
      bottom = LuxButton(title: 'Dopuni', icon: Icons.add_circle, height: h, onTap: onTopUp);
    } else if (inHand && me['allIn'] != true) {
      // Potez unapred, kao u velikim poker aplikacijama.
      bottom = Row(children: [
        Expanded(
            child: _PreButton(
                label: 'Check / Fold', selected: pre == PreAction.checkFold, onTap: () => onPre(PreAction.checkFold), height: h)),
        const SizedBox(width: 8),
        Expanded(
            child: _PreButton(
                label: 'Call any', selected: pre == PreAction.callAny, onTap: () => onPre(PreAction.callAny), height: h)),
      ]);
    }

    final status = Row(children: [
      if (myHand != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.black45,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: gold.withOpacity(0.4)),
          ),
          child: GoldText(myHand, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
        )
      else if (bottom == null)
        Text(
          st['inProgress'] == true ? (inHand ? 'Čeka se potez…' : 'Igrate od sledeće ruke.') : 'Sledeća ruka uskoro počinje…',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      const Spacer(),
      if (!wide) Text('Nalog: ${rsd(app.balance)}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
    ]);

    if (!wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          status,
          if (bottom != null) ...[const SizedBox(height: 6), bottom],
        ]),
      );
    }

    // Računar: traka preko cele širine dole
    Widget check(String label, bool v, String key) => InkWell(
          onTap: () => app.setSetting(key, !v),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(width: 26, height: 26, child: Checkbox(value: v, onChanged: (x) => app.setSetting(key, x ?? false))),
              const SizedBox(width: 6),
              Text(label, style: const TextStyle(fontSize: 13)),
            ]),
          ),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xFF14100C), Color(0xFF080605)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        border: Border(top: BorderSide(color: gold.withOpacity(0.35))),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(
          width: 230,
          child: LuxPanel(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            radius: 12,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              check('Sakrij karte', app.hideCards, 'hideCards'),
              check('Automatski re-buy', app.autoRebuy, 'autoRebuy'),
            ]),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            status,
            const SizedBox(height: 6),
            bottom ?? SizedBox(height: h),
          ]),
        ),
      ]),
    );
  }
}

class _PreButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final double height;
  const _PreButton({required this.label, required this.selected, required this.onTap, this.height = 40});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: Size.fromHeight(height),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        backgroundColor: selected ? gold.withOpacity(0.15) : Colors.black38,
        side: BorderSide(color: selected ? goldLight : gold.withOpacity(0.4), width: selected ? 2 : 1),
      ),
      onPressed: onTap,
      icon: Icon(selected ? Icons.check_box : Icons.check_box_outline_blank,
          size: 18, color: selected ? goldLight : Colors.white54),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
    );
  }
}

/// Izbor iznosa žetona (ulaz za sto ili dopuna).
class ChipsDialog extends StatefulWidget {
  final String title;
  final String confirm;
  final String info;
  final int min;
  final int max;
  final int balance;
  const ChipsDialog({
    super.key,
    required this.title,
    required this.confirm,
    required this.info,
    required this.min,
    required this.max,
    required this.balance,
  });

  @override
  State<ChipsDialog> createState() => _ChipsDialogState();
}

class _ChipsDialogState extends State<ChipsDialog> {
  late int _value;
  late final int _top = min(widget.max, widget.balance);

  @override
  void initState() {
    super.initState();
    _value = _top;
  }

  @override
  Widget build(BuildContext context) {
    final enough = _top >= widget.min;
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.info, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 4),
          Text('Na nalogu: ${rsd(widget.balance)}', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          if (!enough)
            Text('Nemate dovoljno na nalogu (potrebno bar ${rsd(widget.min)}). Javite se svom agentu za uplatu.',
                style: const TextStyle(color: Color(0xFFFF8A80)))
          else ...[
            Center(child: Text(rsd(_value), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
            if (_top > widget.min)
              Slider(
                min: widget.min.toDouble(),
                max: _top.toDouble(),
                value: _value.toDouble(),
                onChanged: (v) => setState(() => _value = v.round()),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(onPressed: () => setState(() => _value = widget.min), child: Text('Min ${rsd(widget.min)}')),
                TextButton(onPressed: () => setState(() => _value = _top), child: Text('Max ${rsd(_top)}')),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Otkaži')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(100, 44)),
          onPressed: enough ? () => Navigator.pop(context, _value) : null,
          child: Text(widget.confirm),
        ),
      ],
    );
  }
}
