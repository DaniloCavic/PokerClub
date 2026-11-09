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
    return ValueListenableBuilder<Json?>(
      valueListenable: app.tableNotifier(widget.tableId),
      builder: (context, st, _) {
        final money = Money((st?['bigBlind'] as int?) ?? 0, showBB);
        return PopScope(
          canPop: st == null || (st['mySeat'] as int) < 0,
          onPopInvokedWithResult: (didPop, _) async {
            if (!didPop) await _back(st);
          },
          child: Scaffold(
            backgroundColor: const Color(0xFF0E1012),
            body: st == null ? const Center(child: CircularProgressIndicator()) : _body(st, money),
          ),
        );
      },
    );
  }

  Widget _body(Json st, Money money) {
    final mySeat = st['mySeat'] as int;
    return SafeArea(
      child: Column(
        children: [
          _TopBar(
            st: st,
            showBB: money.inBB,
            onBack: () => _back(st),
            onToggle: app.setShowBB,
            onHistory: () => showHandHistory(context, tableId: widget.tableId, table: app.tableNotifier(widget.tableId)),
            onChat: () => showTableChat(context, widget.tableId),
            unread: app.unreadOf(widget.tableId),
            onMenu: mySeat >= 0 ? () => _menu(st) : null,
          ),
          Expanded(
            child: LayoutBuilder(builder: (_, c) {
              // Na širokom ekranu (računar) sto zadržava dobru srazmeru i stoji u sredini.
              final w = min(c.maxWidth, c.maxHeight * 1.6);
              final h = min(c.maxHeight, w * 2.0);
              return Center(
                child: SizedBox(
                  width: w,
                  height: h,
                  child: ValueListenableBuilder<List<Json>>(
                    valueListenable: app.chatOf(widget.tableId),
                    builder: (_, chat, __) =>
                        _TableView(st: st, size: Size(w, h), money: money, chat: chat, onSit: (i) => _sit(st, i)),
                  ),
                ),
              );
            }),
          ),
          if (mySeat >= 0)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _MyPanel(
                st: st,
                app: app,
                money: money,
                pre: _pre,
                onPre: (p) => _setPre(st, p),
                onTopUp: () => _topUp(st, (st['seats'] as List)[mySeat] as Json),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Dodirnite slobodno mesto da sednete za sto.', style: TextStyle(color: Colors.white60, fontSize: 13)),
            ),
        ],
      ),
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

/// Sitne kontrole na vrhu: nazad, meni, prikaz u RSD/BB i istorija.
class _TopBar extends StatelessWidget {
  final Json st;
  final bool showBB;
  final VoidCallback onBack;
  final VoidCallback onHistory;
  final VoidCallback? onMenu;
  final VoidCallback onChat;
  final ValueNotifier<int> unread;
  final ValueChanged<bool> onToggle;
  const _TopBar({
    required this.st,
    required this.showBB,
    required this.onBack,
    required this.onHistory,
    required this.onToggle,
    required this.onChat,
    required this.unread,
    this.onMenu,
  });

  @override
  Widget build(BuildContext context) {
    Widget round(IconData icon, VoidCallback? onTap, String tip) => Tooltip(
          message: tip,
          child: InkResponse(
            onTap: onTap,
            radius: 22,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), shape: BoxShape.circle),
              child: Icon(icon, size: 18, color: Colors.white70),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(children: [
        round(Icons.arrow_back_ios_new, onBack, 'Nazad'),
        const SizedBox(width: 6),
        if (onMenu != null) round(Icons.menu, onMenu, 'Meni'),
        const Spacer(),
        // Prikaz iznosa: dinari ili veliki blajndovi
        Container(
          decoration: BoxDecoration(color: Colors.white.withOpacity(0.06), borderRadius: BorderRadius.circular(17)),
          padding: const EdgeInsets.all(3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final opt in const [(false, 'RSD'), (true, 'BB')])
              GestureDetector(
                onTap: () => onToggle(opt.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                      color: showBB == opt.$1 ? accent : Colors.transparent, borderRadius: BorderRadius.circular(14)),
                  child: Text(opt.$2, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 6),
        // Chat sa brojem nepročitanih poruka
        ValueListenableBuilder<int>(
          valueListenable: unread,
          builder: (_, n, __) => Stack(clipBehavior: Clip.none, children: [
            round(Icons.chat_bubble_outline, onChat, 'Chat'),
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
        const SizedBox(width: 6),
        round(Icons.history, onHistory, 'Istorija ruku'),
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
  _Layout(this.size, this.n, this.base, this.mySeat);

  double get w => size.width;
  double get h => size.height;
  Offset get center => Offset(w / 2, h * 0.5);
  double get cardW => min(min(w, h) > 600 ? 46.0 : 38.0, (w * 0.56) / 5 - 4);
  double get boardTop => center.dy - cardW * 1.4 / 2 - 6;
  double get potTop => boardTop - 40;

  /// Gomila žetona sakupljenog pota (ispod karata, kao u velikim aplikacijama).
  Offset get pile => Offset(center.dx, boardTop + cardW * 1.4 + 18);

  Offset seat(int i) {
    final k = (i - base + n) % n;
    final angle = pi / 2 + 2 * pi * k / n;
    return center + Offset(w * 0.40 * cos(angle), h * 0.41 * sin(angle));
  }

  Offset dir(int i) {
    final d = center - seat(i);
    return d / max(1.0, d.distance);
  }

  /// Gde stoji ulog igrača u tekućoj rundi.
  Offset bet(int i) {
    final p = seat(i);
    if (i == mySeat) return Offset(p.dx + 74, min(p.dy, h - 104) - 34);
    final d = dir(i);
    var b = p + d * (70.0 + 34 * d.dy.abs());
    if ((b.dy - (potTop + 16)).abs() < 26 && (b.dx - center.dx).abs() < 70) b = Offset(b.dx, potTop - 18);
    return b;
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
  _Flight(this.from, this.to, this.label, {this.delayMs = 0}) : key = UniqueKey();
}

/// Veliki ovalni sto preko celog ekrana. Igrač je uvek dole u sredini.
class _TableView extends StatefulWidget {
  final Json st;
  final Size size;
  final Money money;
  final List<Json> chat;
  final void Function(int seat) onSit;
  const _TableView({required this.st, required this.size, required this.money, required this.chat, required this.onSit});

  @override
  State<_TableView> createState() => _TableViewState();
}

class _TableViewState extends State<_TableView> {
  final List<_Flight> _flights = [];
  static const _flyMs = 450;

  _Layout _layoutFor(Json st) {
    final n = (st['seats'] as List).length;
    final my = st['mySeat'] as int;
    return _Layout(widget.size, n, my >= 0 ? my : 0, my);
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
        if (bet > 0) added.add(_Flight(lay.bet(i), lay.pile, widget.money(bet)));
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
          added.add(_Flight(lay.pile, lay.seat(seat), widget.money(amount), delayMs: delay));
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
    const seatW = 86.0;

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
      // Sto: tamna ivica i zelena čoja, skoro do ivica ekrana
      Positioned(
        left: w * 0.08,
        top: h * 0.05,
        width: w * 0.84,
        height: h * 0.90,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(w),
            gradient: const LinearGradient(
                colors: [Color(0xFF34373D), Color(0xFF16181B)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
            boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 20, spreadRadius: 2)],
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(w),
              border: Border.all(color: Colors.black54, width: 3),
              gradient: const RadialGradient(
                  colors: [Color(0xFF2E7A3A), Color(0xFF1E5A28), Color(0xFF123A19)], stops: [0, 0.7, 1], radius: 0.95),
            ),
          ),
        ),
      ),
      // Znak kluba i podaci o igri na čoji (ispod pota)
      Positioned(
        left: 0,
        right: 0,
        top: lay.pile.dy + 28,
        child: IgnorePointer(child: _FeltInfo(st: st, w: min(w, h * 0.75))),
      ),
      // Ukupan pot iznad karata
      Positioned(
        left: 0,
        right: 0,
        top: lay.potTop,
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: (st['pot'] as int) > 0 ? 1 : 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(12)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Ukupan pot', style: TextStyle(fontSize: 10, color: Colors.white70)),
                Text(money(st['pot']), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: gold)),
              ]),
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
      if (collected > 0 && !flyingIn)
        Positioned(
          left: lay.pile.dx - 50,
          top: lay.pile.dy - 14,
          width: 100,
          child: _ChipPile(text: money(collected), big: true),
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
          builder: (_, o, child) => Positioned(left: o.dx - 45, top: o.dy - 16, width: 90, child: child!),
          child: _ChipPile(text: money(bet)),
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
      final avatarSize = isMe ? 60.0 : 50.0;
      final topY = isMe ? min(p.dy - avatarSize / 2, h - avatarSize - 44) : p.dy - avatarSize / 2;
      children.add(Positioned(
        left: p.dx - seatW / 2,
        top: topY,
        width: seatW,
        child: _SeatView(
          seat: s,
          isMe: isMe,
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
              left: o.dx - 45, top: o.dy - 16, width: 90, child: Opacity(opacity: t < delayFrac ? 0 : 1, child: child));
        },
        child: _ChipPile(text: f.label),
      ));
    }

    return Stack(clipBehavior: Clip.none, children: [...children, ...overlays]);
  }
}

/// Gomila žetona sa iznosom (ulog igrača ili pot na sredini).
class _ChipPile extends StatelessWidget {
  final String text;
  final bool big;
  const _ChipPile({required this.text, this.big = false});

  @override
  Widget build(BuildContext context) {
    const colors = [Color(0xFFD7263D), Color(0xFF2F80ED), Color(0xFF27AE60), Color(0xFFF2C14E)];
    final size = big ? 15.0 : 13.0;
    final count = big ? 4 : 3;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: size + (count - 1) * (size * 0.65),
        height: size + 4,
        child: Stack(children: [
          for (var k = 0; k < count; k++)
            Positioned(
              left: k * size * 0.65,
              top: (k % 2) * 2.0,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors[k % colors.length],
                  border: Border.all(color: Colors.white, width: 2),
                  boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 2)],
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 1),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: big ? 12.5 : 11.5)),
      ),
    ]);
  }
}

/// Natpis na čoji: znak kluba, naziv stola i pravila igre.
class _FeltInfo extends StatelessWidget {
  final Json st;
  final double w;
  const _FeltInfo({required this.st, required this.w});

  @override
  Widget build(BuildContext context) {
    final omaha = st['variant'] == 'OMAHA';
    const faint = TextStyle(fontSize: 10.5, color: Color(0x80FFFFFF), height: 1.35);
    return Column(children: [
      // Znak kluba na čoji
      Text('POKER KLUB',
          style: TextStyle(fontSize: w * 0.032, fontWeight: FontWeight.w800, color: const Color(0x40FFFFFF), letterSpacing: 4)),
      Text('TRILING',
          style: TextStyle(
              fontSize: w * 0.075, fontWeight: FontWeight.w900, color: const Color(0x66E0182D), letterSpacing: 2, height: 1)),
      Text(omaha ? 'PLO' : 'NLH',
          style: TextStyle(fontSize: w * 0.04, fontWeight: FontWeight.w900, color: const Color(0x33FFFFFF))),
      const SizedBox(height: 6),
      Text(st['name'] as String, style: faint.copyWith(fontWeight: FontWeight.w700)),
      Text('${omaha ? 'Omaha pot-limit' : "Hold'em no-limit"} · Blind ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} RSD',
          style: faint),
      Text('Ante ${chips(st['ante'] ?? 0)} RSD · Ulaz ${chips(st['minBuyIn'])} – ${rsd(st['maxBuyIn'])}', style: faint),
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
  const _SeatView({
    required this.seat,
    required this.isMe,
    required this.avatarSize,
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
    if (cards != null && cards.isNotEmpty) {
      final cw = isMe ? (cards.length > 2 ? 26.0 : 32.0) : (cards.length > 2 ? 19.0 : 24.0);
      cardsWidget = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var k = 0; k < cards.length; k++)
          Transform.translate(
            offset: Offset(-k * cw * 0.12, 0),
            child: PlayingCard(code: cards[k], width: cw, dim: folded && !isMe, highlight: best.contains(cards[k])),
          ),
      ]);
    } else if (count > 0 && !folded) {
      const cw = 20.0;
      cardsWidget = Row(mainAxisSize: MainAxisSize.min, children: [
        for (var k = 0; k < count; k++)
          Transform.translate(offset: Offset(-k * cw * 0.45, 0), child: const PlayingCard(width: cw)),
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
          borderColor: won != null ? gold : (acting ? winGreen : Colors.white24),
          borderWidth: won != null || acting ? 2.5 : 1.5,
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

    final plate = Container(
      constraints: BoxConstraints(minWidth: isMe ? 84 : 74),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xE6101214),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: acting ? (bank ? timeColor : winGreen) : Colors.white12),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
        Text(
          seat['allIn'] == true ? 'ALL-IN' : money(seat['stack']),
          style: TextStyle(
              fontWeight: FontWeight.w800, fontSize: 12, color: seat['allIn'] == true ? accent : const Color(0xFF6FD3FF)),
        ),
        // Traka vremena za potez ispod steka
        if (acting)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: timeLeft,
                minHeight: 3,
                color: bank ? timeColor : const Color(0xFFF2C14E),
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
        SizedBox(
          width: 86,
          height: a + 8,
          child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            avatar,
            if (cardsWidget != null) Positioned(top: isMe ? -14 : -6, child: cardsWidget),
          ]),
        ),
        Transform.translate(offset: const Offset(0, -6), child: plate),
        if (tag != null)
          Transform.translate(
            offset: const Offset(0, -4),
            child: _Pop(
              key: ValueKey(won != null ? 'win-${seat['userId']}' : 'tag'),
              pop: won != null,
              child: Container(
                constraints: const BoxConstraints(maxWidth: 110),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1.5),
                decoration: BoxDecoration(color: tag.color, borderRadius: BorderRadius.circular(8)),
                child: Text(
                  tag.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: won != null ? Colors.black : Colors.white),
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

/// Donji deo: kompaktni potezi, da sto ostane pregledan.
class _MyPanel extends StatelessWidget {
  final Json st;
  final AppState app;
  final Money money;
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
  });

  @override
  Widget build(BuildContext context) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final legal = st['legal'] as Json?;
    final tableId = st['id'] as String;
    final myHand = st['myHand'] as String?;
    final inHand = me['inHand'] == true && me['folded'] != true && st['inProgress'] == true;

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
        onAction: (action, [amount]) =>
            app.run('table:act', {'tableId': tableId, 'action': action, if (amount != null) 'amount': amount}),
      );
    } else if (me['sittingOut'] == true) {
      bottom = FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
        icon: const Icon(Icons.play_arrow, size: 20),
        label: const Text('Vrati se u igru'),
        onPressed: () => app.run('table:sitout', {'tableId': tableId, 'value': false}),
      );
    } else if (me['stack'] == 0 && me['inHand'] != true) {
      bottom = FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(42)),
        icon: const Icon(Icons.add_circle, size: 20),
        label: const Text('Dopuni'),
        onPressed: onTopUp,
      );
    } else if (inHand && me['allIn'] != true) {
      // Potez unapred, kao u velikim poker aplikacijama.
      bottom = Row(children: [
        Expanded(
            child:
                _PreButton(label: 'Check / Fold', selected: pre == PreAction.checkFold, onTap: () => onPre(PreAction.checkFold))),
        const SizedBox(width: 8),
        Expanded(child: _PreButton(label: 'Call any', selected: pre == PreAction.callAny, onTap: () => onPre(PreAction.callAny))),
      ]);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          if (myHand != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: panelLight, borderRadius: BorderRadius.circular(8)),
              child: Text(myHand, style: const TextStyle(color: gold, fontWeight: FontWeight.w800, fontSize: 12.5)),
            )
          else if (bottom == null)
            Text(
              st['inProgress'] == true ? (inHand ? 'Čeka se potez…' : 'Igrate od sledeće ruke.') : 'Sledeća ruka uskoro počinje…',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          const Spacer(),
          Text('Nalog: ${rsd(app.balance)}', style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
        if (bottom != null) ...[const SizedBox(height: 6), bottom],
      ]),
    );
  }
}

class _PreButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _PreButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(38),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        backgroundColor: selected ? const Color(0xFF1B3A2E) : Colors.transparent,
        side: BorderSide(color: selected ? winGreen : Colors.white24, width: selected ? 2 : 1),
      ),
      onPressed: onTap,
      icon:
          Icon(selected ? Icons.check_box : Icons.check_box_outline_blank, size: 18, color: selected ? winGreen : Colors.white54),
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
