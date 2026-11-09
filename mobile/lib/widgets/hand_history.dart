import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'playing_card.dart';

typedef Json = Map<String, dynamic>;

const _streetNames = {'preflop': 'PRE-FLOP', 'flop': 'FLOP', 'turn': 'TURN', 'river': 'RIVER'};

/// Naziv i boja poteza (isto kao na stolu).
({String label, Color color}) historyLabel(Json act, Money money) {
  final amount = act['amount'] as int? ?? 0;
  return switch (act['type'] as String) {
    'ante' => (label: 'ante ${money(amount)}', color: Colors.white38),
    'sb' => (label: 'mali blajnd ${money(amount)}', color: Colors.white60),
    'bb' => (label: 'veliki blajnd ${money(amount)}', color: Colors.white60),
    'fold' => (label: 'FOLD', color: Colors.white54),
    'check' => (label: 'CHECK', color: const Color(0xFF5FD39A)),
    'call' => (label: 'CALL ${money(amount)}', color: const Color(0xFF6FA8FF)),
    'bet' => (label: 'BET ${money(amount)}', color: const Color(0xFFFFA24A)),
    'raise' => (label: 'RAISE na ${money(amount)}', color: const Color(0xFFFF5A6A)),
    'allin' => (label: 'ALL-IN ${money(amount)}', color: const Color(0xFFC77DFF)),
    _ => (label: act['type'].toString(), color: Colors.white),
  };
}

/// Otvara istoriju: potezi u ruci koja je u toku i prethodne ruke igrača za ovim stolom.
void showHandHistory(BuildContext context, {required String tableId, required ValueNotifier<Json?> table}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.85,
      child: Column(children: [
        const SizedBox(height: 8),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
        Expanded(child: HandHistoryTabs(tableId: tableId, table: table)),
      ]),
    ),
  );
}

/// Istorija za sto: potezi u ruci koja je u toku i prethodne ruke (u panelu ili u listi odozdo).
class HandHistoryTabs extends StatelessWidget {
  final String tableId;
  final ValueNotifier<Json?> table;
  const HandHistoryTabs({super.key, required this.tableId, required this.table});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          const TabBar(
            indicatorColor: accent,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            labelStyle: TextStyle(fontWeight: FontWeight.w800),
            tabs: [Tab(text: 'Ova ruka'), Tab(text: 'Prethodne ruke')],
          ),
          Expanded(
            child: TabBarView(children: [
              // Ruka u toku: osvežava se uživo
              ValueListenableBuilder<Json?>(
                valueListenable: table,
                builder: (context, st, _) {
                  if (st == null) return const SizedBox.shrink();
                  final money = Money(st['bigBlind'] as int, context.select<AppState, bool>((a) => a.showBB));
                  final actions = ((st['actions'] as List?) ?? []).cast<Json>();
                  if (actions.isEmpty) {
                    return const Center(child: Text('Ruka još nije počela.', style: TextStyle(color: Colors.white54)));
                  }
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      Text('Ruka #${st['handNo']}${st['inProgress'] == true ? ' · u toku' : ' · završena'}',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                      const SizedBox(height: 8),
                      ActionsByStreet(actions: actions, board: (st['board'] as List).cast<String>(), money: money),
                    ],
                  );
                },
              ),
              PreviousHands(tableId: tableId, bigBlind: (table.value?['bigBlind'] as int?) ?? 0),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Potezi grupisani po fazama ruke, sa kartama koje su tada podeljene.
class ActionsByStreet extends StatelessWidget {
  final List<Json> actions;
  final List<String> board;
  final Money money;
  const ActionsByStreet({super.key, required this.actions, required this.board, required this.money});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    String? street;
    for (final a in actions) {
      if (a['street'] != street) {
        street = a['street'] as String;
        final dealt = switch (street) {
          'flop' => board.take(3).toList(),
          'turn' => board.length > 3 ? [board[3]] : <String>[],
          'river' => board.length > 4 ? [board[4]] : <String>[],
          _ => <String>[],
        };
        children.add(Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 6),
          child: Row(children: [
            Text(_streetNames[street] ?? street, style: const TextStyle(color: gold, fontWeight: FontWeight.w900)),
            const SizedBox(width: 10),
            for (final c in dealt) Padding(padding: const EdgeInsets.only(right: 3), child: PlayingCard(code: c, width: 22)),
          ]),
        ));
      }
      final l = historyLabel(a, money);
      children.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(a['name'] as String, style: const TextStyle(color: Colors.white70))),
          Text(l.label, style: TextStyle(color: l.color, fontWeight: FontWeight.w800)),
        ]),
      ));
    }
    // Karte koje su otvorene posle poslednjeg poteza (all-in) — prikaži ostatak stola.
    final shownStreets = actions.map((a) => a['street']).toSet();
    final rest = <String>[
      if (!shownStreets.contains('flop') && board.length >= 3) ...board.take(3),
      if (!shownStreets.contains('turn') && board.length >= 4) board[3],
      if (!shownStreets.contains('river') && board.length >= 5) board[4],
    ];
    if (rest.isNotEmpty) {
      children.add(Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Row(children: [
          const Text('STO', style: TextStyle(color: gold, fontWeight: FontWeight.w900)),
          const SizedBox(width: 10),
          for (final c in rest) Padding(padding: const EdgeInsets.only(right: 3), child: PlayingCard(code: c, width: 22)),
        ]),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}

class PreviousHands extends StatefulWidget {
  /// null = ruke sa svih stolova.
  final String? tableId;
  final int bigBlind;
  const PreviousHands({super.key, this.tableId, required this.bigBlind});

  @override
  State<PreviousHands> createState() => _PreviousHandsState();
}

class _PreviousHandsState extends State<PreviousHands> {
  List<Json> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final page = reset ? 1 : _page + 1;
      final res = await context
          .read<AppState>()
          .api
          .get('/me/hands?${widget.tableId != null ? 'tableId=${widget.tableId}&' : ''}page=$page');
      final items = (res['items'] as List).cast<Json>();
      setState(() {
        _page = page;
        _total = res['total'] as int;
        _items = reset ? items : [..._items, ...items];
        _error = null;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final money = Money(widget.bigBlind, context.select<AppState, bool>((a) => a.showBB));
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white54)));
    if (_items.isEmpty) {
      return Center(
        child: _loading
            ? const CircularProgressIndicator()
            : Text(
                widget.tableId == null ? 'Još niste odigrali nijednu ruku.' : 'Još niste odigrali nijednu ruku za ovim stolom.',
                style: const TextStyle(color: Colors.white54)),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _items.length + 1,
        itemBuilder: (_, i) {
          if (i == _items.length) {
            return _items.length < _total
                ? TextButton(onPressed: _loading ? null : () => _load(), child: const Text('Učitaj još'))
                : const SizedBox(height: 16);
          }
          final bb = ((_items[i]['table'] as Map?)?['bigBlind'] as int?) ?? widget.bigBlind;
          return _HandTile(hand: _items[i], money: Money(bb, money.inBB), showTable: widget.tableId == null);
        },
      ),
    );
  }
}

class _HandTile extends StatelessWidget {
  final Json hand;
  final Money money;
  final bool showTable;
  const _HandTile({required this.hand, required this.money, this.showTable = false});

  @override
  Widget build(BuildContext context) {
    final players = (hand['players'] as List).cast<Json>();
    final me = players.firstWhere((p) => p['isMe'] == true, orElse: () => players.first);
    final diff = (me['endStack'] as int) - (me['startStack'] as int);
    final board = (hand['board'] as List).cast<String>();
    final myCards = ((me['cards'] as List?) ?? []).cast<String>();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        shape: const Border(),
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Row(children: [
          for (final c in myCards) Padding(padding: const EdgeInsets.only(right: 2), child: PlayingCard(code: c, width: 22)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(showTable ? '${(hand['table'] as Map?)?['name'] ?? 'Sto'} · #${hand['handNo']}' : 'Ruka #${hand['handNo']}',
                  overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
              Text(dateTime(hand['createdAt']), style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ]),
          ),
          Text(
            '${diff > 0 ? '+' : ''}${money(diff)}',
            style: TextStyle(
                fontWeight: FontWeight.w900, color: diff > 0 ? winGreen : (diff < 0 ? const Color(0xFFFF6B6B) : Colors.white54)),
          ),
        ]),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          if (board.isNotEmpty)
            Row(children: [
              const Text('Sto: ', style: TextStyle(color: Colors.white54)),
              for (final c in board) Padding(padding: const EdgeInsets.only(right: 3), child: PlayingCard(code: c, width: 24)),
            ]),
          const SizedBox(height: 8),
          // Igrači: karte (svoje i otvorene), stanje pre i posle
          for (final p in players)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Expanded(
                  child: Text(p['name'] + (p['isMe'] == true ? ' (vi)' : ''),
                      style: TextStyle(fontWeight: p['isMe'] == true ? FontWeight.w800 : FontWeight.w500)),
                ),
                if (p['cards'] != null)
                  for (final c in (p['cards'] as List).cast<String>())
                    Padding(padding: const EdgeInsets.only(right: 2), child: PlayingCard(code: c, width: 20))
                else
                  const Text('— ', style: TextStyle(color: Colors.white38)),
                SizedBox(
                  width: 92,
                  child: Text(
                    () {
                      final d = (p['endStack'] as int) - (p['startStack'] as int);
                      return '${d > 0 ? '+' : ''}${money(d)}';
                    }(),
                    textAlign: TextAlign.right,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ]),
            ),
          for (final pot in (hand['pots'] as List).cast<Json>())
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${(pot['winners'] as List).map((w) => w['name']).join(' i ')} dobija ${money(pot['amount'])}'
                '${pot['handName'] != null ? ' · ${pot['handName']}' : ''}',
                style: const TextStyle(color: gold, fontWeight: FontWeight.w700),
              ),
            ),
          const Divider(color: Colors.white10, height: 20),
          ActionsByStreet(actions: ((hand['actions'] as List?) ?? []).cast<Json>(), board: board, money: money),
        ],
      ),
    );
  }
}
