import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/action_bar.dart';
import '../widgets/playing_card.dart';

typedef Json = Map<String, dynamic>;

class TableScreen extends StatefulWidget {
  final String tableId;
  const TableScreen({super.key, required this.tableId});

  @override
  State<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends State<TableScreen> {
  late final AppState app;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    app = context.read<AppState>();
    app.watch(widget.tableId);
    // Osvežavanje tajmera za potez.
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final st = app.tableNotifier(widget.tableId).value;
      if (mounted && st?['deadline'] != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    app.unwatch(widget.tableId);
    app.refreshMe();
    super.dispose();
  }

  Future<bool> _confirmLeave(Json? st) async {
    final seated = st != null && (st['mySeat'] as int) >= 0;
    if (!seated) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Napustiti sto?'),
        content: Text(st['inProgress'] == true
            ? 'Ako ste u ruci, odustajete od nje. Žetoni sa stola se vraćaju na vaš nalog.'
            : 'Žetoni sa stola se vraćaju na vaš nalog.'),
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
    return ValueListenableBuilder<Json?>(
      valueListenable: app.tableNotifier(widget.tableId),
      builder: (context, st, _) {
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
              actions: [if (st != null && (st['mySeat'] as int) >= 0) _menu(st)],
            ),
            body: st == null ? const Center(child: CircularProgressIndicator()) : _body(st),
          ),
        );
      },
    );
  }

  Widget _menu(Json st) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final sittingOut = me['sittingOut'] == true;
    return PopupMenuButton<String>(
      onSelected: (v) async {
        switch (v) {
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
        const PopupMenuItem(value: 'topup', child: ListTile(leading: Icon(Icons.add_circle), title: Text('Dopuni žetone'))),
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

  Widget _body(Json st) {
    final mySeat = st['mySeat'] as int;
    return SafeArea(
      child: Column(
        children: [
          _InfoBar(st: st),
          Expanded(child: LayoutBuilder(builder: (_, c) => _TableView(st: st, size: c.biggest, onSit: (i) => _sit(st, i)))),
          if (mySeat >= 0)
            _MyPanel(st: st, app: app, onTopUp: () => _topUp(st, (st['seats'] as List)[mySeat] as Json))
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
        info: 'Blajndovi ${chips(st['smallBlind'])}/${chips(st['bigBlind'])} · ulaz ${chips(min)}–${chips(max)}',
      ),
    );
    if (amount == null) return;
    await app.run('table:sit', {'tableId': widget.tableId, 'seat': seat, 'buyIn': amount});
  }

  Future<void> _topUp(Json st, Json me) async {
    final room = (st['maxBuyIn'] as int) - (me['stack'] as int);
    if (room <= 0) {
      app.toast('Već imate najviše žetona koliko sme na ovom stolu.');
      return;
    }
    final amount = await showDialog<int>(
      context: context,
      builder: (_) => ChipsDialog(
        title: 'Dopuna žetona',
        min: 1,
        max: room,
        balance: app.balance,
        confirm: 'Dopuni',
        info: 'Na stolu imate ${chips(me['stack'])}, najviše ${chips(st['maxBuyIn'])}. Dopuna važi od sledeće ruke.',
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
          Text('${chips(st['smallBlind'])} / ${chips(st['bigBlind'])}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const Spacer(),
          Text(
            '${rake > 0 ? 'Rake $rake%' : 'Bez rake-a'}${(st['handNo'] as int) > 0 ? '  ·  Ruka #${st['handNo']}' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.white54),
          ),
        ],
      ),
    );
  }
}

/// Ovalni sto sa sedištima. Igrač je uvek dole u sredini.
class _TableView extends StatelessWidget {
  final Json st;
  final Size size;
  final void Function(int seat) onSit;
  const _TableView({required this.st, required this.size, required this.onSit});

  @override
  Widget build(BuildContext context) {
    final seats = (st['seats'] as List).cast<Json?>();
    final n = seats.length;
    final mySeat = st['mySeat'] as int;
    final base = mySeat >= 0 ? mySeat : 0;
    final w = size.width, h = size.height;
    final center = Offset(w / 2, h / 2);
    // Sedišta su malo izvan ivice stola (kao u poker aplikacijama).
    final rx = w * 0.40, ry = h * 0.39;
    final app = context.read<AppState>();

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
        left: w * 0.07,
        top: h * 0.12,
        width: w * 0.86,
        height: h * 0.76,
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
            alignment: const Alignment(0, 0.42),
            child: Text(
              'POKER KLUB',
              style: TextStyle(color: Colors.white.withOpacity(0.06), fontSize: w * 0.07, fontWeight: FontWeight.w900, letterSpacing: 4),
            ),
          ),
        ),
      ),
      // Sredina: ukupan pot i karte na stolu
      Positioned(
        left: 0,
        right: 0,
        top: h / 2 - cardW * 1.4 / 2 - 34,
        child: Column(
          children: [
            AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: (st['pot'] as int) > 0 ? 1 : 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(12)),
                child: Text('Ukupan pot: ${chips(st['pot'])}',
                    style: const TextStyle(color: gold, fontWeight: FontWeight.w700, fontSize: 13)),
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
            if (result != null) _ResultText(result: result),
            if (st['closing'] == true) const Text('Sto se zatvara posle ove ruke.', style: TextStyle(color: gold)),
            if (st['inProgress'] != true && result == null && seats.where((s) => s != null).length < 2)
              const Text('Čeka se još igrača…', style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
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
      final bet = s['bet'] as int;
      if (bet > 0) {
        final b = pos(i, 0.58);
        children.add(Positioned(left: b.dx - 45, top: b.dy - 11, width: 90, child: Center(child: _BetChips(amount: bet))));
      }
      if (st['button'] == i) {
        final d = pos(i, 0.72) + const Offset(30, -6);
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
      final isMe = i == mySeat;
      const seatW = 96.0;
      children.add(Positioned(
        left: p.dx - seatW / 2,
        top: p.dy - (isMe ? 92 : 62),
        width: seatW,
        child: _SeatView(
          seat: s,
          isMe: isMe,
          won: won[i],
          timeLeft: timeLeft,
          best: best,
          handName: (result?['shown'] as List?)?.cast<Json>().where((x) => x['seat'] == i).map((x) => x['handName'] as String).firstOrNull,
        ),
      ));
    }
    return Stack(clipBehavior: Clip.none, children: children);
  }
}

class _ResultText extends StatelessWidget {
  final Json result;
  const _ResultText({required this.result});

  @override
  Widget build(BuildContext context) {
    final pots = (result['pots'] as List).cast<Json>();
    final p = pots.first;
    final handName = p['handName'] as String?;
    if (handName == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
      child: Text(handName, style: const TextStyle(color: gold, fontWeight: FontWeight.w800, fontSize: 14)),
    );
  }
}

/// Ulog ispred igrača: mala gomila žetona i iznos.
class _BetChips extends StatelessWidget {
  final int amount;
  const _BetChips({required this.amount});

  @override
  Widget build(BuildContext context) {
    const colors = [Color(0xFFE0182D), Color(0xFF2F80ED), Color(0xFF27AE60)];
    return Container(
      padding: const EdgeInsets.fromLTRB(3, 2, 8, 2),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 22,
          height: 18,
          child: Stack(children: [
            for (var k = 0; k < 3; k++)
              Positioned(
                left: k * 3.0,
                top: 3.0 - k * 1.5,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors[k],
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(width: 2),
        Text(chips(amount), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
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
  const _SeatView({required this.seat, required this.isMe, required this.won, required this.best, this.timeLeft, this.handName});

  @override
  Widget build(BuildContext context) {
    final cards = (seat['cards'] as List?)?.cast<String>();
    final count = seat['cardCount'] as int;
    final folded = seat['folded'] == true;
    final acting = timeLeft != null;
    final name = seat['name'] as String;
    final away = seat['sittingOut'] == true && seat['inHand'] != true;
    String? status = seat['lastAction'] as String?;
    if (seat['leaving'] == true) {
      status = 'Ustaje';
    } else if (away) {
      status = 'Pauza';
    } else if (seat['stack'] == 0 && seat['inHand'] != true) {
      status = 'Bez žetona';
    }

    // Karte: svoje velike iznad avatara, tuđe poleđine pored, otvorene posle ruke.
    Widget? cardsRow;
    if (cards != null && cards.isNotEmpty) {
      final cw = isMe ? (cards.length > 2 ? 34.0 : 44.0) : (cards.length > 2 ? 22.0 : 28.0);
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
    } else if (count > 0) {
      cardsRow = SizedBox(
        width: 40,
        height: 30,
        child: Stack(children: [
          for (var k = 0; k < count; k++)
            Positioned(
              left: 6.0 + k * (count > 2 ? 5 : 9),
              top: 2,
              child: Transform.rotate(angle: (k - (count - 1) / 2) * 0.18, child: const PlayingCard(width: 18)),
            ),
        ]),
      );
    }

    final avatar = Stack(
      alignment: Alignment.center,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [avatarColor(name), Color.lerp(avatarColor(name), Colors.black, 0.5)!],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: won != null ? gold : (isMe ? Colors.white70 : Colors.white24), width: won != null ? 3 : 2),
            boxShadow: [
              const BoxShadow(color: Colors.black54, blurRadius: 4),
              if (won != null) const BoxShadow(color: Color(0xAAF2C14E), blurRadius: 14),
            ],
          ),
          alignment: Alignment.center,
          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
        ),
        if (acting)
          SizedBox(
            width: 60,
            height: 60,
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
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xF0101217),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: acting ? winGreen : Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white70)),
          Text(
            seat['allIn'] == true ? 'ALL-IN' : chips(seat['stack']),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: seat['allIn'] == true ? accent : gold),
          ),
        ],
      ),
    );

    final label = won != null
        ? _Badge(text: 'WIN +${chips(won)}', color: gold, dark: true)
        : handName != null
            ? _Badge(text: handName!, color: Colors.black87)
            : status != null
                ? _Badge(text: status.toUpperCase(), color: _actionColor(status))
                : null;

    return Opacity(
      opacity: (folded && cards == null) || away ? 0.5 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(height: isMe ? 62 : 32, child: cardsRow == null ? null : Center(child: cardsRow)),
          avatar,
          Transform.translate(offset: const Offset(0, -6), child: plate),
          if (label != null) Transform.translate(offset: const Offset(0, -4), child: label),
        ],
      ),
    );
  }

  Color _actionColor(String s) {
    final a = s.toLowerCase();
    if (a.startsWith('raise') || a.startsWith('bet') || a.startsWith('all-in')) return accentDark;
    if (a.startsWith('call')) return const Color(0xFF1B54B0);
    if (a.startsWith('check')) return const Color(0xFF3A3D45);
    return Colors.black54;
  }
}

class _Badge extends StatelessWidget {
  final String text;
  final Color color;
  final bool dark;
  const _Badge({required this.text, required this.color, this.dark = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: dark ? Colors.black : Colors.white),
      ),
    );
  }
}

/// Donji deo ekrana: jačina ruke i potezi.
class _MyPanel extends StatelessWidget {
  final Json st;
  final AppState app;
  final VoidCallback onTopUp;
  const _MyPanel({required this.st, required this.app, required this.onTopUp});

  @override
  Widget build(BuildContext context) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final legal = st['legal'] as Json?;
    final tableId = st['id'] as String;
    final myHand = st['myHand'] as String?;

    Widget bottom;
    if (legal != null) {
      bottom = ActionBar(
        legal: legal,
        pot: st['pot'] as int,
        myBet: me['bet'] as int,
        myStack: me['stack'] as int,
        bigBlind: st['bigBlind'] as int,
        potLimit: st['variant'] == 'OMAHA',
        onAction: (action, [amount]) =>
            app.run('table:act', {'tableId': tableId, 'action': action, if (amount != null) 'amount': amount}),
      );
    } else if (me['sittingOut'] == true) {
      bottom = FilledButton.icon(
        icon: const Icon(Icons.play_arrow),
        label: const Text('Vrati se u igru'),
        onPressed: () => app.run('table:sitout', {'tableId': tableId, 'value': false}),
      );
    } else if (me['stack'] == 0 && me['inHand'] != true) {
      bottom = FilledButton.icon(icon: const Icon(Icons.add_circle), label: const Text('Dopuni žetone'), onPressed: onTopUp);
    } else {
      bottom = SizedBox(
        height: 48,
        child: Center(
          child: Text(
            me['inHand'] == true && me['folded'] != true
                ? 'Čeka se potez drugog igrača…'
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
                  child: Text(myHand, style: const TextStyle(color: gold, fontWeight: FontWeight.w700)),
                ),
              const Spacer(),
              if (legal != null && (legal['call'] as int) > 0)
                Text('Za call: ${chips(legal['call'])}  ·  ', style: const TextStyle(color: Colors.white70, fontSize: 12)),
              Text('Nalog: ${chips(app.balance)}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          bottom,
        ],
      ),
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
          Text('Na nalogu: ${chips(widget.balance)}', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 16),
          if (!enough)
            Text('Nemate dovoljno žetona na nalogu (potrebno bar ${chips(widget.min)}). Javite se svom agentu za uplatu.',
                style: const TextStyle(color: Color(0xFFFF8A80)))
          else ...[
            Center(child: Text(chips(_value), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold))),
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
                TextButton(onPressed: () => setState(() => _value = widget.min), child: Text('Min ${chips(widget.min)}')),
                TextButton(onPressed: () => setState(() => _value = _top), child: Text('Max ${chips(_top)}')),
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
