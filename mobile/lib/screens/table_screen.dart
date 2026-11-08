import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/action_bar.dart';
import '../widgets/avatar.dart';
import '../widgets/playing_card.dart';

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
    app.watch(widget.tableId);
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
            if (didPop) return;
            final nav = Navigator.of(context);
            if (await _confirmLeave(st)) nav.pop();
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(st?['name'] ?? 'Sto', overflow: TextOverflow.ellipsis),
              actions: [
                if (st != null)
                  TextButton(
                    onPressed: () => app.setShowBB(!showBB),
                    child: Text(showBB ? 'BB' : 'RSD', style: const TextStyle(color: gold, fontWeight: FontWeight.w800)),
                  ),
                if (st != null && (st['mySeat'] as int) >= 0) _menu(st, showBB),
              ],
            ),
            body: st == null ? const Center(child: CircularProgressIndicator()) : _body(st, money),
          ),
        );
      },
    );
  }

  Widget _menu(Json st, bool showBB) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final sittingOut = me['sittingOut'] == true;
    return PopupMenuButton<String>(
      onSelected: (v) async {
        switch (v) {
          case 'bb':
            app.setShowBB(!showBB);
          case 'topup':
            _topUp(st, me);
          case 'sitout':
            await app.run('table:sitout', {'tableId': widget.tableId, 'value': !sittingOut});
          case 'leave':
            final nav = Navigator.of(context);
            if (await _confirmLeave(st)) nav.pop();
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'bb',
          child: ListTile(
            leading: const Icon(Icons.swap_horiz),
            title: Text(showBB ? 'Prikaži u dinarima (RSD)' : 'Prikaži u velikim blajndovima (BB)'),
          ),
        ),
        const PopupMenuItem(value: 'topup', child: ListTile(leading: Icon(Icons.add_circle), title: Text('Dopuni'))),
        PopupMenuItem(
          value: 'sitout',
          child: ListTile(
            leading: Icon(sittingOut ? Icons.play_arrow : Icons.pause),
            title: Text(sittingOut ? 'Vrati se u igru' : 'Pauza (preskoči ruke)'),
          ),
        ),
        const PopupMenuItem(value: 'leave', child: ListTile(leading: Icon(Icons.logout), title: Text('Ustani sa stola'))),
      ],
    );
  }

  Widget _body(Json st, Money money) {
    final mySeat = st['mySeat'] as int;
    return SafeArea(
      child: Column(
        children: [
          _InfoBar(st: st),
          Expanded(
            child: LayoutBuilder(
              builder: (_, c) => _TableView(st: st, size: c.biggest, money: money, onSit: (i) => _sit(st, i)),
            ),
          ),
          if (mySeat >= 0)
            _MyPanel(
              st: st,
              app: app,
              money: money,
              pre: _pre,
              onPre: (p) => _setPre(st, p),
              onTopUp: () => _topUp(st, (st['seats'] as List)[mySeat] as Json),
            )
          else
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Dodirnite slobodno mesto da sednete za sto.', style: TextStyle(color: Colors.white70)),
            ),
        ],
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
        info: 'Blajndovi ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} · ulaz ${rsd(min)} – ${rsd(max)}',
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

class _InfoBar extends StatelessWidget {
  final Json st;
  const _InfoBar({required this.st});

  @override
  Widget build(BuildContext context) {
    final rake = st['rakePercent'] as num;
    final short = st['variant'] == 'OMAHA' ? 'PLO' : 'NLH';
    const streets = {'preflop': 'PRE-FLOP', 'flop': 'FLOP', 'turn': 'TURN', 'river': 'RIVER', 'showdown': 'OTVARANJE'};
    final street = streets[st['street']];
    return Container(
      width: double.infinity,
      color: const Color(0xFF101217),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(4)),
            child: Text(short, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 8),
          Text('Blajndovi ${chips(st['smallBlind'])}/${chips(st['bigBlind'])}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          if (street != null)
            Text(street, style: const TextStyle(fontSize: 12, color: gold, fontWeight: FontWeight.w800)),
          Text(
            '${street != null ? '  ·  ' : ''}${rake > 0 ? 'Rake $rake%' : 'Bez rake-a'}',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

/// Naziv i boja poteza za prikaz kod igrača i u spisku poteza.
({String label, Color color}) actLabel(Json act, Money money) {
  final amount = act['amount'] as int? ?? 0;
  return switch (act['type'] as String) {
    'sb' => (label: 'SB ${money(amount)}', color: const Color(0xFF4A4F5C)),
    'bb' => (label: 'BB ${money(amount)}', color: const Color(0xFF4A4F5C)),
    'fold' => (label: 'FOLD', color: const Color(0xFF2B2F38)),
    'check' => (label: 'CHECK', color: const Color(0xFF2E7D5B)),
    'call' => (label: 'CALL ${money(amount)}', color: const Color(0xFF1B6FD8)),
    'bet' => (label: 'BET ${money(amount)}', color: const Color(0xFFE07A18)),
    'raise' => (label: 'RAISE ${money(amount)}', color: accent),
    'allin' => (label: 'ALL-IN ${money(amount)}', color: const Color(0xFF9B1BD8)),
    _ => (label: '', color: Colors.black),
  };
}

/// Ovalni sto sa sedištima. Igrač je uvek dole u sredini.
class _TableView extends StatelessWidget {
  final Json st;
  final Size size;
  final Money money;
  final void Function(int seat) onSit;
  const _TableView({required this.st, required this.size, required this.money, required this.onSit});

  @override
  Widget build(BuildContext context) {
    final seats = (st['seats'] as List).cast<Json?>();
    final n = seats.length;
    final mySeat = st['mySeat'] as int;
    final base = mySeat >= 0 ? mySeat : 0;
    final w = size.width, h = size.height;
    final center = Offset(w / 2, h * 0.47);
    final rx = w * 0.38, ry = h * 0.36;
    final app = context.read<AppState>();
    const seatW = 104.0;

    Offset pos(int i, [double scale = 1]) {
      final k = (i - base + n) % n;
      final angle = pi / 2 + 2 * pi * k / n;
      return center + Offset(rx * scale * cos(angle), ry * scale * sin(angle));
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
    final cardW = min(46.0, (w * 0.62) / 5 - 4);

    final children = <Widget>[
      // Sto: tamna ivica i zelena čoja
      Positioned(
        left: w * 0.06,
        top: h * 0.08,
        width: w * 0.88,
        height: h * 0.78,
        child: Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(w),
            gradient: const LinearGradient(colors: [railInner, railOuter], begin: Alignment.topCenter, end: Alignment.bottomCenter),
            boxShadow: const [BoxShadow(color: Colors.black, blurRadius: 24, spreadRadius: 2)],
          ),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(w),
              border: Border.all(color: Colors.white10, width: 2),
              gradient: const RadialGradient(colors: [feltLight, felt, feltDark], stops: [0, 0.65, 1], radius: 0.9),
            ),
          ),
        ),
      ),
      // Sredina: ukupan pot, karte na stolu, rezultat
      Positioned(
        left: 0,
        right: 0,
        top: center.dy - cardW * 1.4 / 2 - 34,
        child: Column(
          children: [
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: (st['pot'] as int) > 0 ? 1 : 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(14)),
                child: Text('Pot: ${money(st['pot'])}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: cardW * 1.4,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var k = 0; k < 5; k++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: k < board.length
                          ? PlayingCard(
                              code: board[k],
                              width: cardW,
                              highlight: best.contains(board[k]),
                              dim: best.isNotEmpty && !best.contains(board[k]),
                            )
                          : Container(
                              width: cardW,
                              height: cardW * 1.4,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(cardW * 0.12),
                                border: Border.all(color: Colors.white10),
                              ),
                            ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (result != null) _ResultText(result: result, money: money),
            if (st['closing'] == true) const Text('Sto se zatvara posle ove ruke.', style: TextStyle(color: gold)),
            if (st['inProgress'] != true && result == null && seats.where((s) => s != null).length < 2)
              const Text('Čeka se još igrača…', style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
      // Spisak poslednjih poteza (gore levo)
      Positioned(left: 8, top: 4, child: _ActionFeed(actions: ((st['actions'] as List?) ?? []).cast<Json>(), money: money)),
    ];

    for (var i = 0; i < n; i++) {
      final s = seats[i];
      final p = pos(i);
      if (s == null) {
        if (mySeat >= 0) continue;
        children.add(Positioned(
          left: p.dx - 28,
          top: p.dy - 28,
          child: GestureDetector(
            onTap: () => onSit(i),
            child: Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.black38,
                border: Border.all(color: accent.withOpacity(0.7), width: 2),
              ),
              alignment: Alignment.center,
              child: const Text('SEDI', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
            ),
          ),
        ));
        continue;
      }
      final isMe = i == mySeat;
      final bet = s['bet'] as int;
      // Smer od igrača ka sredini stola (za ulog i dugme).
      final toCenter = center - p;
      final dir = toCenter / max(1.0, toCenter.distance);
      final side = Offset(-dir.dy, dir.dx);
      if (bet > 0) {
        // Ulog stoji ispred igrača, prema sredini stola, da ne preklapa pot.
        var b = isMe ? Offset(center.dx, pos(i).dy - 150) : p + dir * min(100.0, toCenter.distance * 0.45);
        // Ako bi ulog prekrio natpis sa potom, pomeri ga iznad ili ispod njega.
        final potY = center.dy - cardW * 0.7 - 21;
        if (!isMe && (b.dy - potY).abs() < 30 && (b.dx - center.dx).abs() < 125) {
          b = Offset(b.dx, p.dy < center.dy ? potY - 32 : potY + 32);
        }
        children.add(Positioned(left: b.dx - 55, top: b.dy - 13, width: 110, child: Center(child: _BetChips(text: money(bet)))));
      }
      if (st['button'] == i) {
        final d = isMe ? Offset(center.dx + 62, pos(i).dy - 120) : p + dir * 62 + side * 46;
        children.add(Positioned(
          left: d.dx - 11,
          top: d.dy - 11,
          child: Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(
              color: gold,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 3)],
            ),
            alignment: Alignment.center,
            child: const Text('D', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 12)),
          ),
        ));
      }
      final deadline = st['deadline'] as int?;
      double? timeLeft;
      if (st['toAct'] == i && deadline != null) {
        final total = (st['actionSeconds'] as int) * 1000;
        timeLeft = ((deadline - app.serverNow) / total).clamp(0.0, 1.0);
      }
      // Svoje sedište: dovoljno visoko da se vidi cela pločica sa žetonima.
      final top = isMe ? min(p.dy - 100, h - 192) : p.dy - 64;
      children.add(Positioned(
        left: p.dx - seatW / 2,
        top: top,
        width: seatW,
        child: _SeatView(
          seat: s,
          isMe: isMe,
          won: won[i],
          timeLeft: timeLeft,
          best: best,
          money: money,
          handName: (result?['shown'] as List?)?.cast<Json>().where((x) => x['seat'] == i).map((x) => x['handName'] as String).firstOrNull,
        ),
      ));
    }
    return Stack(clipBehavior: Clip.none, children: children);
  }
}

class _ActionFeed extends StatelessWidget {
  final List<Json> actions;
  final Money money;
  const _ActionFeed({required this.actions, required this.money});

  @override
  Widget build(BuildContext context) {
    final list = actions.reversed.take(4).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var k = 0; k < list.length; k++)
          Opacity(
            opacity: 1 - k * 0.22,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text('${list[k]['name']}  ', style: const TextStyle(fontSize: 11, color: Colors.white70)),
                Text(
                  actLabel(list[k], money).label,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Color.lerp(actLabel(list[k], money).color, Colors.white, 0.35)),
                ),
              ]),
            ),
          ),
      ],
    );
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
      final prefix = pots.length > 1 ? (k == 0 ? 'Glavni pot: ' : 'Sporedni pot: ') : '';
      lines.add('$prefix$names dobija ${money(p['amount'])}${p['handName'] != null ? ' · ${p['handName']}' : ''}');
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 36),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
      child: Text(lines.join('\n'),
          textAlign: TextAlign.center, style: const TextStyle(color: gold, fontWeight: FontWeight.w800, fontSize: 13)),
    );
  }
}

/// Ulog ispred igrača: mala gomila žetona i iznos.
class _BetChips extends StatelessWidget {
  final String text;
  const _BetChips({required this.text});

  @override
  Widget build(BuildContext context) {
    const colors = [Color(0xFFE0182D), Color(0xFF2F80ED), Color(0xFF27AE60)];
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 3, 10, 3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 24,
          height: 18,
          child: Stack(children: [
            for (var k = 0; k < 3; k++)
              Positioned(
                left: k * 3.5,
                top: 3.0 - k * 1.5,
                child: Container(
                  width: 15,
                  height: 15,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: colors[k], border: Border.all(color: Colors.white, width: 2)),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 3),
        Text(text, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
      ]),
    );
  }
}

class _SeatView extends StatelessWidget {
  final Json seat;
  final bool isMe;
  final int? won;
  final double? timeLeft;
  final String? handName;
  final Set<String> best;
  final Money money;
  const _SeatView({
    required this.seat,
    required this.isMe,
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

    // Šta piše na traci iznad imena: pobeda, potez, ili stanje igrača.
    ({String label, Color color})? strip;
    if (won != null) {
      strip = (label: 'WIN +${money(won)}', color: gold);
    } else if (acting) {
      strip = (label: 'NA POTEZU', color: const Color(0xFF2E7D5B));
    } else if (act != null) {
      strip = actLabel(act, money);
    } else if (seat['leaving'] == true) {
      strip = (label: 'USTAJE', color: const Color(0xFF2B2F38));
    } else if (away) {
      strip = (label: 'PAUZA', color: const Color(0xFF2B2F38));
    } else if (seat['stack'] == 0 && seat['inHand'] != true) {
      strip = (label: 'PRAZAN STEK', color: const Color(0xFF2B2F38));
    }

    // Karte: svoje velike iznad avatara, tuđe poleđine pored, otvorene posle ruke.
    Widget? cardsRow;
    if (cards != null && cards.isNotEmpty) {
      final cw = isMe ? (cards.length > 2 ? 36.0 : 46.0) : (cards.length > 2 ? 23.0 : 30.0);
      cardsRow = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final c in cards)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: PlayingCard(code: c, width: cw, dim: folded, highlight: best.contains(c)),
            ),
        ],
      );
    } else if (count > 0 && !folded) {
      cardsRow = SizedBox(
        width: 44,
        height: 30,
        child: Stack(children: [
          for (var k = 0; k < count; k++)
            Positioned(
              left: 8.0 + k * (count > 2 ? 5 : 9),
              top: 2,
              child: Transform.rotate(angle: (k - (count - 1) / 2) * 0.18, child: const PlayingCard(width: 18)),
            ),
        ]),
      );
    }

    final avatar = Stack(
      alignment: Alignment.center,
      children: [
        Avatar(
          name: name,
          url: seat['avatarUrl'] as String?,
          size: 50,
          borderColor: won != null ? gold : (isMe ? Colors.white70 : Colors.white24),
          borderWidth: won != null ? 3 : 2,
          shadow: [
            const BoxShadow(color: Colors.black54, blurRadius: 4),
            if (won != null) const BoxShadow(color: Color(0xAAF2C14E), blurRadius: 14),
          ],
        ),
        if (acting)
          SizedBox(
            width: 58,
            height: 58,
            child: CircularProgressIndicator(
              value: timeLeft,
              strokeWidth: 4,
              color: timeLeft! < 0.3 ? accent : winGreen,
              backgroundColor: Colors.black38,
            ),
          ),
      ],
    );

    final plate = Container(
      width: double.infinity,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xF2101217),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: acting ? winGreen : (won != null ? gold : Colors.white12), width: acting || won != null ? 1.5 : 1),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (strip != null)
            Container(
              width: double.infinity,
              color: strip.color,
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                strip.label,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w900,
                  color: won != null ? Colors.black : Colors.white,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 3),
            child: Column(children: [
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white70)),
              Text(
                seat['allIn'] == true ? 'ALL-IN' : money(seat['stack']),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: seat['allIn'] == true ? accent : Colors.white),
              ),
            ]),
          ),
        ],
      ),
    );

    return Opacity(
      opacity: (folded && cards == null) || away ? 0.55 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: isMe ? 66 : 32, child: cardsRow == null ? null : Center(child: cardsRow)),
          avatar,
          Transform.translate(offset: const Offset(0, -6), child: plate),
          if (handName != null)
            Transform.translate(
              offset: const Offset(0, -3),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(10)),
                child: Text(handName!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: gold)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Donji deo ekrana: jačina ruke i potezi.
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

    Widget bottom;
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
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        icon: const Icon(Icons.play_arrow),
        label: const Text('Vrati se u igru'),
        onPressed: () => app.run('table:sitout', {'tableId': tableId, 'value': false}),
      );
    } else if (me['stack'] == 0 && me['inHand'] != true) {
      bottom = FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        icon: const Icon(Icons.add_circle),
        label: const Text('Dopuni'),
        onPressed: onTopUp,
      );
    } else if (inHand && me['allIn'] != true) {
      // Potez unapred, kao u velikim poker aplikacijama.
      bottom = Row(
        children: [
          Expanded(child: _PreButton(label: 'Check / Fold', selected: pre == PreAction.checkFold, onTap: () => onPre(PreAction.checkFold))),
          const SizedBox(width: 8),
          Expanded(child: _PreButton(label: 'Call bilo šta', selected: pre == PreAction.callAny, onTap: () => onPre(PreAction.callAny))),
        ],
      );
    } else {
      bottom = SizedBox(
        height: 48,
        child: Center(
          child: Text(
            inHand
                ? 'Čeka se potez drugih igrača…'
                : st['inProgress'] == true
                    ? 'Igrate od sledeće ruke.'
                    : 'Sledeća ruka uskoro počinje…',
            style: const TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF101217),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              if (myHand != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(color: panelLight, borderRadius: BorderRadius.circular(10)),
                  child: Text(myHand, style: const TextStyle(color: gold, fontWeight: FontWeight.w800, fontSize: 15)),
                ),
              const Spacer(),
              Text('Nalog: ${rsd(app.balance)}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          bottom,
        ],
      ),
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
        minimumSize: const Size.fromHeight(48),
        backgroundColor: selected ? const Color(0xFF1B3A2E) : Colors.transparent,
        side: BorderSide(color: selected ? winGreen : Colors.white24, width: selected ? 2 : 1),
      ),
      onPressed: onTap,
      icon: Icon(selected ? Icons.check_box : Icons.check_box_outline_blank, size: 20, color: selected ? winGreen : Colors.white54),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
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
