import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../format.dart';
import '../i18n.dart';
import '../theme.dart';
import 'brand.dart';
import 'playing_card.dart';

typedef Json = Map<String, dynamic>;

/// Ponovno odigravanje ruke iz istorije, potez po potez (kao video).
void showHandReplay(BuildContext context, Json hand, Money money) {
  showDialog(context: context, builder: (_) => HandReplayDialog(hand: hand, money: money));
}

class HandReplayDialog extends StatefulWidget {
  final Json hand;
  final Money money;
  const HandReplayDialog({super.key, required this.hand, required this.money});

  @override
  State<HandReplayDialog> createState() => _HandReplayDialogState();
}

class _Frame {
  final Map<int, int> stack;
  final Map<int, int> bet;
  final Set<int> folded;
  final int pot;
  final int boardCount;
  final int? actor;
  final String? label;
  final bool end;
  _Frame(this.stack, this.bet, this.folded, this.pot, this.boardCount, this.actor, this.label, {this.end = false});
}

class _HandReplayDialogState extends State<HandReplayDialog> {
  late final List<Json> players;
  late final List<String> board;
  late final List<_Frame> frames;
  int step = 0;
  Timer? _play;

  @override
  void initState() {
    super.initState();
    players = (widget.hand['players'] as List).cast<Json>()..sort((a, b) => (a['seat'] as int).compareTo(b['seat'] as int));
    board = (widget.hand['board'] as List).cast<String>();
    frames = _build();
  }

  @override
  void dispose() {
    _play?.cancel();
    super.dispose();
  }

  /// Svi kadrovi ruke: početak, pa stanje posle svakog poteza, pa kraj (ko je šta dobio).
  List<_Frame> _build() {
    final actions = ((widget.hand['actions'] as List?) ?? const []).cast<Json>();
    final stack = {for (final p in players) p['seat'] as int: p['startStack'] as int};
    final bet = <int, int>{};
    final folded = <int>{};
    var pot = 0;
    var street = 'preflop';
    var boardCount = 0;
    final out = <_Frame>[_Frame({...stack}, {}, {}, 0, 0, null, null)];
    int streetCards(String s) => switch (s) { 'flop' => 3, 'turn' => 4, 'river' => 5, _ => 0 };
    for (final a in actions) {
      final s = a['street'] as String? ?? 'preflop';
      if (s != street) {
        // Nova ulica: ulozi idu u pot, otvaraju se karte.
        pot += bet.values.fold(0, (x, y) => x + y);
        bet.clear();
        street = s;
        boardCount = max(boardCount, min(board.length, streetCards(s)));
      }
      final seat = a['seat'] as int;
      final amount = (a['amount'] as num?)?.toInt() ?? 0;
      final type = a['type'] as String;
      if (type == 'ante' || type == 'bomb') {
        stack[seat] = (stack[seat] ?? 0) - amount;
        pot += amount;
      } else if (type == 'fold') {
        folded.add(seat);
      } else if (type != 'check') {
        // Iznos je ukupan ulog igrača u ovoj ulici.
        final add = max(0, amount - (bet[seat] ?? 0));
        stack[seat] = (stack[seat] ?? 0) - add;
        bet[seat] = amount;
      }
      out.add(_Frame({...stack}, {...bet}, {...folded}, pot, boardCount, seat, _label(type, amount)));
    }
    // Kraj: preostale karte stola i ishod.
    pot += bet.values.fold(0, (x, y) => x + y);
    out.add(_Frame({for (final p in players) p['seat'] as int: p['endStack'] as int}, {}, folded, pot, board.length, null, null, end: true));
    return out;
  }

  String _label(String type, int amount) => switch (type) {
        'ante' => 'ANTE',
        'bomb' => 'BOMB POT',
        'straddle' => 'STRADDLE',
        'sb' => 'SB',
        'bb' => 'BB',
        'fold' => 'FOLD',
        'check' => 'CHECK',
        'call' => 'CALL',
        'bet' => 'BET',
        'raise' => 'RAISE',
        'allin' => 'ALL-IN',
        _ => type.toUpperCase(),
      };

  void _toggle() {
    if (_play != null) {
      _play!.cancel();
      setState(() => _play = null);
      return;
    }
    if (step >= frames.length - 1) step = 0;
    _play = Timer.periodic(const Duration(milliseconds: 1100), (t) {
      if (!mounted) return t.cancel();
      if (step >= frames.length - 1) {
        t.cancel();
        setState(() => _play = null);
      } else {
        setState(() => step++);
      }
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final f = frames[step];
    final m = widget.money;
    final pots = ((widget.hand['pots'] as List?) ?? const []).cast<Json>();
    return Dialog(
      backgroundColor: panel,
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: gold.withOpacity(0.5))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              GoldText('${tr('Replay', 'Replay')} · #${widget.hand['handNo']}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
              const Spacer(),
              Text('${step}/${frames.length - 1}', style: const TextStyle(color: Colors.white54)),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
            ]),
            AspectRatio(
              aspectRatio: 1.45,
              child: LayoutBuilder(builder: (_, c) {
                final w = c.maxWidth, h = c.maxHeight;
                final n = players.length;
                final me = players.indexWhere((p) => p['isMe'] == true);
                Offset pos(int k) {
                  final rel = (k - (me < 0 ? 0 : me) + n) % n;
                  final a = pi / 2 + 2 * pi * rel / n;
                  return Offset(w / 2 + w * 0.40 * cos(a), h * 0.46 + h * 0.38 * sin(a));
                }

                return Stack(clipBehavior: Clip.none, children: [
                  Positioned(
                    left: w * 0.08,
                    top: h * 0.12,
                    width: w * 0.84,
                    height: h * 0.68,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(w),
                        gradient: const RadialGradient(colors: [feltLight, felt, feltDark]),
                        border: Border.all(color: gold.withOpacity(0.8), width: 2.5),
                      ),
                    ),
                  ),
                  // Karte stola i pot
                  Positioned(
                    left: 0,
                    right: 0,
                    top: h * 0.36,
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        for (var k = 0; k < f.boardCount; k++)
                          Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PlayingCard(code: board[k], width: w * 0.07)),
                      ]),
                      const SizedBox(height: 4),
                      if (f.pot > 0)
                        Text('POT ${m(f.pot)}', style: const TextStyle(fontWeight: FontWeight.w900, color: goldLight, fontSize: 12)),
                    ]),
                  ),
                  for (var k = 0; k < n; k++) _seat(players[k], pos(k), f, w),
                ]);
              }),
            ),
            if (f.end)
              for (final pot in pots)
                Text(
                  '${(pot['winners'] as List).map((x) => x['name']).join(tr(' & ', ' i '))} ${tr('wins', 'dobija')} ${m(pot['amount'])}'
                  '${pot['handName'] != null ? ' · ${pot['handName']}' : ''}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: gold, fontWeight: FontWeight.w800),
                ),
            const SizedBox(height: 6),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              IconButton(onPressed: step > 0 ? () => setState(() => step = 0) : null, icon: const Icon(Icons.skip_previous)),
              IconButton(onPressed: step > 0 ? () => setState(() => step--) : null, icon: const Icon(Icons.chevron_left, size: 32)),
              IconButton.filled(
                onPressed: _toggle,
                style: IconButton.styleFrom(backgroundColor: gold, foregroundColor: Colors.black),
                icon: Icon(_play != null ? Icons.pause : Icons.play_arrow, size: 30),
              ),
              IconButton(
                  onPressed: step < frames.length - 1 ? () => setState(() => step++) : null, icon: const Icon(Icons.chevron_right, size: 32)),
              IconButton(
                  onPressed: step < frames.length - 1 ? () => setState(() => step = frames.length - 1) : null,
                  icon: const Icon(Icons.skip_next)),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _seat(Json p, Offset o, _Frame f, double w) {
    final seat = p['seat'] as int;
    final folded = f.folded.contains(seat);
    final cards = (p['cards'] as List?)?.cast<String>();
    final acting = f.actor == seat;
    final bet = f.bet[seat] ?? 0;
    final cw = w * 0.055;
    return Positioned(
      left: o.dx - 52,
      top: o.dy - 36,
      width: 104,
      child: Opacity(
        opacity: folded ? 0.45 : 1,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (cards != null)
              for (final c in cards) Padding(padding: const EdgeInsets.only(right: 1), child: PlayingCard(code: c, width: cw))
            else
              for (var k = 0; k < 2; k++) Padding(padding: const EdgeInsets.only(right: 1), child: PlayingCard(width: cw)),
          ]),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: acting ? goldLight : (p['isMe'] == true ? gold : Colors.white24), width: acting ? 2 : 1),
            ),
            child: Column(children: [
              Text(p['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              Text(widget.money(f.stack[seat] ?? 0), style: const TextStyle(fontSize: 11, color: goldLight, fontWeight: FontWeight.w800)),
            ]),
          ),
          if (acting && f.label != null || bet > 0)
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(color: acting ? accent : Colors.black54, borderRadius: BorderRadius.circular(6)),
              child: Text(
                [if (acting && f.label != null) f.label!, if (bet > 0) widget.money(bet)].join(' '),
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
              ),
            ),
        ]),
      ),
    );
  }
}
