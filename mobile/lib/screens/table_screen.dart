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
                  decoration: BoxDecoration(color: showBB == opt.$1 ? accent : Colors.transparent, borderRadius: BorderRadius.circular(14)),
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

/// Veliki ovalni sto preko celog ekrana. Igrač je uvek dole u sredini.
class _TableView extends StatelessWidget {
  final Json st;
  final Size size;
  final Money money;
  final List<Json> chat;
  final void Function(int seat) onSit;
  const _TableView({required this.st, required this.size, required this.money, required this.chat, required this.onSit});

  @override
  Widget build(BuildContext context) {
    final seats = (st['seats'] as List).cast<Json?>();
    final n = seats.length;
    final mySeat = st['mySeat'] as int;
    final base = mySeat >= 0 ? mySeat : 0;
    final w = size.width, h = size.height;
    final center = Offset(w / 2, h * 0.5);
    // Sedišta stoje na ivici stola.
    final rx = w * 0.40, ry = h * 0.41;
    final app = context.read<AppState>();
    const seatW = 86.0;

    Offset pos(int i) {
      final k = (i - base + n) % n;
      final angle = pi / 2 + 2 * pi * k / n;
      return center + Offset(rx * cos(angle), ry * sin(angle));
    }

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
    final cardW = min(min(w, h) > 600 ? 46.0 : 38.0, (w * 0.56) / 5 - 4);
    final boardTop = center.dy - cardW * 1.4 / 2 - 6;

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
            gradient: const LinearGradient(colors: [Color(0xFF34373D), Color(0xFF16181B)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
            boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 20, spreadRadius: 2)],
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(w),
              border: Border.all(color: Colors.black54, width: 3),
              gradient: const RadialGradient(colors: [Color(0xFF2E7A3A), Color(0xFF1E5A28), Color(0xFF123A19)], stops: [0, 0.7, 1], radius: 0.95),
            ),
          ),
        ),
      ),
      // Znak kluba i podaci o igri na čoji (ispod karata)
      Positioned(
        left: 0,
        right: 0,
        top: boardTop + cardW * 1.4 + 30,
        child: IgnorePointer(child: _FeltInfo(st: st, w: min(w, h * 0.75))),
      ),
      // Ukupan pot iznad karata
      Positioned(
        left: 0,
        right: 0,
        top: boardTop - 40,
        child: Center(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 200),
            opacity: (st['pot'] as int) > 0 ? 1 : 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
              decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(12)),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('Ukupan pot', style: TextStyle(fontSize: 10, color: Colors.white70)),
                Text(money(st['pot']), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.white)),
              ]),
            ),
          ),
        ),
      ),
      // Karte na stolu (male)
      Positioned(
        left: 0,
        right: 0,
        top: boardTop,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final c in board)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: PlayingCard(code: c, width: cardW, highlight: best.contains(c), dim: best.isNotEmpty && !best.contains(c)),
              ),
          ],
        ),
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

    // Ulozi i dugme se crtaju posle igrača, da ih pločice ne prekriju.
    final overlays = <Widget>[];
    for (var i = 0; i < n; i++) {
      final s = seats[i];
      final p = pos(i);
      if (s == null) {
        if (mySeat >= 0) continue;
        children.add(Positioned(
          left: p.dx - 27,
          top: p.dy - 27,
          child: GestureDetector(
            onTap: () => onSit(i),
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
      final toCenter = center - p;
      final dir = toCenter / max(1.0, toCenter.distance);
      final side = Offset(-dir.dy, dir.dx);
      final bet = s['bet'] as int;
      if (bet > 0) {
        // Ulog: žeton i iznos ispred igrača, prema sredini stola.
        // Svoj ulog gore desno od avatara (kao u velikim aplikacijama), tuđi prema sredini.
        var b = isMe ? Offset(p.dx + 74, min(p.dy, h - 104) - 34) : p + dir * (70.0 + 34 * dir.dy.abs());
        final potTop = boardTop - 40;
        if ((b.dy - (potTop + 16)).abs() < 26 && (b.dx - center.dx).abs() < 70) b = Offset(b.dx, potTop - 18);
        overlays.add(Positioned(left: b.dx - 40, top: b.dy - 18, width: 80, child: _BetChip(text: money(bet))));
      }
      if (st['button'] == i) {
        final d = p + dir * 48 + side * 40;
        overlays.add(Positioned(
          left: d.dx - 9,
          top: d.dy - 9,
          child: Container(
            width: 18,
            height: 18,
            decoration: const BoxDecoration(color: gold, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 3)]),
            alignment: Alignment.center,
            child: const Text('D', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 10)),
          ),
        ));
      }
      // Poslednja poruka igrača iz chata (do 6 sekundi) iznad njegovog avatara.
      final recent = chat.lastWhere(
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
      final deadline = st['deadline'] as int?;
      double? timeLeft;
      if (st['toAct'] == i && deadline != null) {
        final total = (st['actionSeconds'] as int) * 1000;
        timeLeft = ((deadline - app.serverNow) / total).clamp(0.0, 1.0);
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
          best: best,
          money: money,
          handName: (result?['shown'] as List?)?.cast<Json>().where((x) => x['seat'] == i).map((x) => x['handName'] as String).firstOrNull,
        ),
      ));
    }
    return Stack(clipBehavior: Clip.none, children: [...children, ...overlays]);
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
          style: TextStyle(fontSize: w * 0.075, fontWeight: FontWeight.w900, color: const Color(0x66E0182D), letterSpacing: 2, height: 1)),
      Text(omaha ? 'PLO' : 'NLH', style: TextStyle(fontSize: w * 0.04, fontWeight: FontWeight.w900, color: const Color(0x33FFFFFF))),
      const SizedBox(height: 6),
      Text(st['name'] as String, style: faint.copyWith(fontWeight: FontWeight.w700)),
      Text('${omaha ? 'Omaha pot-limit' : "Hold'em no-limit"} · Blind ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} RSD', style: faint),
      Text('Ulaz ${chips(st['minBuyIn'])} – ${rsd(st['maxBuyIn'])}', style: faint),
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

/// Ulog ispred igrača: žeton i iznos ispod njega.
class _BetChip extends StatelessWidget {
  final String text;
  const _BetChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFD7263D),
          border: Border.all(color: Colors.white, width: 2.5),
          boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 2)],
        ),
      ),
      const SizedBox(height: 1),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.55), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11.5)),
      ),
    ]);
  }
}

/// Igrač: avatar sa malim kartama preko njega, ispod ime i stek.
class _SeatView extends StatelessWidget {
  final Json seat;
  final bool isMe;
  final double avatarSize;
  final int? won;
  final double? timeLeft;
  final String? handName;
  final Set<String> best;
  final Money money;
  const _SeatView({
    required this.seat,
    required this.isMe,
    required this.avatarSize,
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
    if (won != null) {
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
        for (var k = 0; k < count; k++) Transform.translate(offset: Offset(-k * cw * 0.45, 0), child: const PlayingCard(width: cw)),
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
              color: timeLeft! < 0.3 ? accent : winGreen,
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
        border: Border.all(color: acting ? winGreen : Colors.white12),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
        Text(
          seat['allIn'] == true ? 'ALL-IN' : money(seat['stack']),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: seat['allIn'] == true ? accent : const Color(0xFF6FD3FF)),
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
      ]),
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
        Expanded(child: _PreButton(label: 'Check / Fold', selected: pre == PreAction.checkFold, onTap: () => onPre(PreAction.checkFold))),
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
      icon: Icon(selected ? Icons.check_box : Icons.check_box_outline_blank, size: 18, color: selected ? winGreen : Colors.white54),
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
