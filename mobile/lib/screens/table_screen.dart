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
    return Container(
      width: double.infinity,
      color: feltDark,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Text(variantLong(st['variant']), style: const TextStyle(fontSize: 13, color: Colors.white70)),
          const Spacer(),
          Text(
            '${chips(st['smallBlind'])}/${chips(st['bigBlind'])}${rake > 0 ? ' · rake $rake%' : ''}'
            '${(st['handNo'] as int) > 0 ? ' · #${st['handNo']}' : ''}',
            style: const TextStyle(fontSize: 13, color: Colors.white70),
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
    final rx = w * 0.38, ry = h * 0.38;
    final seatW = min(96.0, w / 4.2);
    final app = context.read<AppState>();

    Offset pos(int i, [double scale = 1]) {
      final k = (i - base + n) % n;
      final angle = pi / 2 + 2 * pi * k / n;
      return center + Offset(rx * scale * cos(angle), ry * scale * sin(angle));
    }

    final result = st['result'] as Json?;
    final winners = <int>{};
    for (final p in (result?['pots'] as List? ?? [])) {
      for (final w in (p['winners'] as List)) {
        winners.add(w['seat'] as int);
      }
    }
    final best = <String>{};
    for (final s in (result?['shown'] as List? ?? [])) {
      if (winners.contains(s['seat'])) best.addAll((s['best'] as List).cast<String>());
    }

    final children = <Widget>[
      // Sto
      Positioned(
        left: w * 0.08,
        top: h * 0.1,
        width: w * 0.84,
        height: h * 0.8,
        child: Container(
          decoration: BoxDecoration(
            color: felt,
            borderRadius: BorderRadius.circular(w),
            border: Border.all(color: tableRail, width: 10),
            gradient: const RadialGradient(colors: [Color(0xFF1A8A52), felt, feltDark], stops: [0, 0.7, 1]),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 16)],
          ),
        ),
      ),
      // Sredina: pot, karte na stolu, rezultat
      Positioned(
        left: 0,
        right: 0,
        top: h / 2 - 70,
        child: Column(
          children: [
            if ((st['pot'] as int) > 0)
              _Chip(label: 'Pot ${chips(st['pot'])}', big: true)
            else
              const SizedBox(height: 26),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final c in (st['board'] as List).cast<String>())
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: PlayingCard(code: c, width: min(44, w / 9), highlight: best.contains(c), dim: best.isNotEmpty && !best.contains(c)),
                  ),
              ],
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
                color: Colors.black26,
                border: Border.all(color: Colors.white38, width: 2),
              ),
              alignment: Alignment.center,
              child: const Text('Sedi', style: TextStyle(fontSize: 13, color: Colors.white)),
            ),
          ),
        ));
        continue;
      }
      final bet = s['bet'] as int;
      if (bet > 0) {
        final b = pos(i, 0.55);
        children.add(Positioned(left: b.dx - 40, top: b.dy - 12, width: 80, child: Center(child: _Chip(label: chips(bet)))));
      }
      if (st['button'] == i) {
        final d = pos(i, 0.72) + const Offset(26, 0);
        children.add(Positioned(
          left: d.dx - 11,
          top: d.dy - 11,
          child: Container(
            width: 22,
            height: 22,
            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black45, blurRadius: 2)]),
            alignment: Alignment.center,
            child: const Text('D', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
        ));
      }
      final deadline = st['deadline'] as int?;
      double? timeLeft;
      if (st['toAct'] == i && deadline != null) {
        final total = (st['actionSeconds'] as int) * 1000;
        timeLeft = ((deadline - app.serverNow) / total).clamp(0.0, 1.0);
      }
      children.add(Positioned(
        left: p.dx - seatW / 2,
        top: p.dy - 44,
        width: seatW,
        child: _SeatView(
          seat: s,
          isMe: i == mySeat,
          winner: winners.contains(i),
          timeLeft: timeLeft,
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
    final lines = <String>[];
    final pots = (result['pots'] as List).cast<Json>();
    for (var k = 0; k < pots.length; k++) {
      final p = pots[k];
      final names = (p['winners'] as List).map((w) => '${w['name']} +${chips(w['amount'])}').join(', ');
      final label = pots.length > 1 ? (k == 0 ? 'Glavni pot: ' : 'Sporedni pot: ') : '';
      lines.add('$label$names${p['handName'] != null ? ' · ${p['handName']}' : ''}');
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 40),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
      child: Text(lines.join('\n'), textAlign: TextAlign.center, style: const TextStyle(color: gold, fontWeight: FontWeight.w600, fontSize: 13)),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool big;
  const _Chip({required this.label, this.big = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: big ? 12 : 8, vertical: big ? 4 : 2),
      decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(20)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.toll, size: big ? 16 : 13, color: gold),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: big ? 15 : 12)),
      ]),
    );
  }
}

class _SeatView extends StatelessWidget {
  final Json seat;
  final bool isMe;
  final bool winner;
  final double? timeLeft;
  final String? handName;
  const _SeatView({required this.seat, required this.isMe, required this.winner, this.timeLeft, this.handName});

  @override
  Widget build(BuildContext context) {
    final cards = (seat['cards'] as List?)?.cast<String>();
    final count = seat['cardCount'] as int;
    final folded = seat['folded'] == true;
    final acting = timeLeft != null;
    String? status = seat['lastAction'] as String?;
    if (seat['leaving'] == true) {
      status = 'Ustaje';
    } else if (seat['sittingOut'] == true && seat['inHand'] != true) {
      status = 'Pauza';
    } else if (seat['stack'] == 0 && seat['inHand'] != true) {
      status = 'Bez žetona';
    }

    return Opacity(
      opacity: folded || (seat['sittingOut'] == true && seat['inHand'] != true) ? 0.55 : 1,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Karte iznad imena (svoje karte su veće, u donjem delu ekrana).
          SizedBox(
            height: 34,
            child: isMe
                ? null
                : cards != null
                    ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        for (final c in cards) Padding(padding: const EdgeInsets.symmetric(horizontal: 1), child: PlayingCard(code: c, width: cards.length > 2 ? 20 : 24)),
                      ])
                    : count > 0
                        ? Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            for (var k = 0; k < count; k++)
                              Padding(padding: const EdgeInsets.symmetric(horizontal: 1), child: PlayingCard(width: count > 2 ? 16 : 20)),
                          ])
                        : null,
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xEE101814),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: winner ? gold : acting ? const Color(0xFF6FD39A) : (isMe ? Colors.white54 : Colors.white12),
                width: winner || acting ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(seat['name'], maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                Text(seat['allIn'] == true ? 'ALL-IN' : chips(seat['stack']),
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: seat['allIn'] == true ? gold : Colors.white)),
                if (acting)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: LinearProgressIndicator(
                      value: timeLeft,
                      minHeight: 3,
                      color: timeLeft! < 0.3 ? Colors.redAccent : const Color(0xFF6FD39A),
                      backgroundColor: Colors.white12,
                    ),
                  ),
              ],
            ),
          ),
          if (handName != null || status != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(handName ?? status!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: handName != null ? gold : Colors.white70, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }
}

/// Donji deo ekrana: moje karte i potezi.
class _MyPanel extends StatelessWidget {
  final Json st;
  final AppState app;
  final VoidCallback onTopUp;
  const _MyPanel({required this.st, required this.app, required this.onTopUp});

  @override
  Widget build(BuildContext context) {
    final me = (st['seats'] as List)[st['mySeat'] as int] as Json;
    final cards = (me['cards'] as List?)?.cast<String>() ?? [];
    final legal = st['legal'] as Json?;
    final tableId = st['id'] as String;
    final result = st['result'] as Json?;
    String? myHand;
    for (final s in (result?['shown'] as List? ?? [])) {
      if (s['seat'] == st['mySeat']) myHand = s['handName'];
    }
    final dimCards = me['folded'] == true || (me['inHand'] != true && result == null);

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
            style: const TextStyle(color: Colors.white60),
          ),
        ),
      );
    }

    return Container(
      color: const Color(0xFF0B1410),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              for (final c in cards) Padding(padding: const EdgeInsets.only(right: 4), child: PlayingCard(code: c, width: cards.length > 2 ? 40 : 50, dim: dimCards)),
              if (cards.isEmpty) const SizedBox(height: 70),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (myHand != null) Text(myHand, style: const TextStyle(color: gold, fontWeight: FontWeight.bold)),
                    if (legal != null && (legal['call'] as int) > 0)
                      Text('Za dorovnjavanje: ${chips(legal['call'])}', style: const TextStyle(color: Colors.white70)),
                    Text('Na nalogu: ${chips(app.balance)}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                  ],
                ),
              ),
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
