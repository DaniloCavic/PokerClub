import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'playing_card.dart';
import '../screens/table_screen.dart' show openHandReplay;
import '../i18n.dart';
import '../share/share.dart';

typedef Json = Map<String, dynamic>;

const _streetNames = {'preflop': 'PRE-FLOP', 'flop': 'FLOP', 'turn': 'TURN', 'river': 'RIVER'};

/// Naziv i boja poteza (isto kao na stolu).
({String label, Color color}) historyLabel(Json act, Money money) {
  final amount = act['amount'] as int? ?? 0;
  return switch (act['type'] as String) {
    'ante' => (label: 'ante ${money(amount)}', color: Colors.white38),
    'bomb' => (label: 'bomb pot ${money(amount)}', color: const Color(0xFFFF6B6B)),
    'straddle' => (label: 'straddle ${money(amount)}', color: const Color(0xFFE0B341)),
    'sb' => (label: 'small blind ${money(amount)}', color: Colors.white60),
    'bb' => (label: 'big blind ${money(amount)}', color: Colors.white60),
    'fold' => (label: 'FOLD', color: Colors.white54),
    'check' => (label: 'CHECK', color: const Color(0xFF5FD39A)),
    'call' => (label: 'CALL ${money(amount)}', color: const Color(0xFF6FA8FF)),
    'bet' => (label: 'BET ${money(amount)}', color: const Color(0xFFFFA24A)),
    'raise' => (label: 'RAISE to ${money(amount)}', color: const Color(0xFFFF5A6A)),
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
          TabBar(
            indicatorColor: accent,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            labelStyle: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w800, fontSize: 14),
                        unselectedLabelStyle: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w600, fontSize: 14),
            tabs: [Tab(text: tr('This hand', 'Ova ruka')), Tab(text: tr('Previous hands', 'Prethodne ruke'))],
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
                    return Center(child: Text(tr('The hand has not started yet.', 'Ruka još nije počela.'), style: const TextStyle(color: Colors.white54)));
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
          Text(tr('BOARD', 'STO'), style: const TextStyle(color: gold, fontWeight: FontWeight.w900)),
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
                widget.tableId == null
                    ? tr('You have not played any hands yet.', 'Još niste odigrali nijednu ruku.')
                    : tr('You have not played any hands at this table yet.', 'Još niste odigrali nijednu ruku za ovim stolom.'),
                style: const TextStyle(color: Colors.white54)),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 12),
        itemCount: _items.length + 2,
        itemBuilder: (_, k) {
          if (k == 0) return const HandListHeader();
          final i = k - 1;
          if (i == _items.length) {
            return _items.length < _total
                ? TextButton(onPressed: _loading ? null : () => _load(), child: Text(tr('Load more', 'Učitaj još')))
                : const SizedBox(height: 16);
          }
          final bb = ((_items[i]['table'] as Map?)?['bigBlind'] as int?) ?? widget.bigBlind;
          return _HandTile(hand: _items[i], money: Money(bb, money.inBB), showTable: widget.tableId == null);
        },
      ),
    );
  }
}

/// Red u listi ruku: moje karte · pobednik · pot (moj profit). Dodir otvara detalj ruke.
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
    final myCards = ((me['cards'] as List?) ?? []).cast<String>();
    final pots = (hand['pots'] as List).cast<Json>();
    final pot = pots.fold<int>(0, (a, p) => a + (p['amount'] as int));
    final winners = <String>{for (final p in pots) for (final w in (p['winners'] as List)) w['name'] as String};
    final iWon = winners.contains(me['name']);
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HandDetailScreen(hand: hand, money: money))),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white10))),
        child: Row(children: [
          SizedBox(
            width: 64,
            child: Row(children: [
              for (final c in myCards.take(4)) Padding(padding: const EdgeInsets.only(right: 2), child: PlayingCard(code: c, width: myCards.length > 2 ? 14 : 24)),
            ]),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Text(winners.isEmpty ? '—' : winners.join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: iWon ? const Color(0xFFFF9F43) : Colors.white, fontStyle: iWon ? FontStyle.italic : null)),
              Text(showTable ? '${(hand['table'] as Map?)?['name'] ?? ''} · #${hand['handNo']}' : '#${hand['handNo']} · ${dateTime(hand['createdAt'])}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white38)),
            ]),
          ),
          SizedBox(
            width: 92,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(money(pot), style: const TextStyle(fontWeight: FontWeight.w800, color: goldLight, fontSize: 14)),
              Text('(${diff > 0 ? '+' : ''}${money(diff)})',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: diff > 0 ? winGreen : (diff < 0 ? const Color(0xFFFF6B6B) : Colors.white54))),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Zaglavlje liste ruku.
class HandListHeader extends StatelessWidget {
  const HandListHeader({super.key});
  @override
  Widget build(BuildContext context) {
    const st = TextStyle(fontSize: 12.5, color: Colors.white54, fontWeight: FontWeight.w700);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      color: Colors.black26,
      child: Row(children: [
        SizedBox(width: 64, child: Text(tr('My cards', 'Moje karte'), style: st)),
        Expanded(child: Text(tr('Winner', 'Pobednik'), textAlign: TextAlign.center, style: st)),
        SizedBox(width: 92, child: Text(tr('Pot (profit)', 'Pot (profit)'), textAlign: TextAlign.right, style: st)),
      ]),
    );
  }
}

const _suitChar = {'s': '♠', 'h': '♥', 'd': '♦', 'c': '♣'};
String _cardText(String c) => c.length < 2 ? c : '${c.substring(0, c.length - 1).replaceAll('T', '10')}${_suitChar[c[c.length - 1]] ?? ''}';

/// Ruka kao tekst (za deljenje i čuvanje).
String handText(Json hand, Money money) {
  final b = StringBuffer();
  final table = (hand['table'] as Map?)?['name'];
  b.writeln('Poker klub Triling${table != null ? ' — $table' : ''} — ${tr('Hand', 'Ruka')} #${hand['handNo']} — ${dateTime(hand['createdAt'])}');
  final board = (hand['board'] as List).cast<String>();
  if (board.isNotEmpty) b.writeln('${tr('Board', 'Sto')}: ${board.map(_cardText).join(' ')}');
  b.writeln();
  for (final p in (hand['players'] as List).cast<Json>()) {
    final d = (p['endStack'] as int) - (p['startStack'] as int);
    final cards = (p['cards'] as List?)?.cast<String>();
    b.writeln('${p['name']}${p['isMe'] == true ? tr(' (me)', ' (ja)') : ''}: ${money(p['startStack'])} → ${money(p['endStack'])} (${d > 0 ? '+' : ''}${money(d)})'
        '${cards != null ? ' [${cards.map(_cardText).join(' ')}]' : ''}');
  }
  String? street;
  for (final a in ((hand['actions'] as List?) ?? []).cast<Json>()) {
    if (a['street'] != street) {
      street = a['street'] as String;
      final dealt = switch (street) {
        'flop' => board.take(3).toList(),
        'turn' => board.length > 3 ? [board[3]] : <String>[],
        'river' => board.length > 4 ? [board[4]] : <String>[],
        _ => <String>[],
      };
      b.writeln();
      b.writeln('${_streetNames[street] ?? street}${dealt.isNotEmpty ? ' [${dealt.map(_cardText).join(' ')}]' : ''}');
    }
    b.writeln('  ${a['name']}: ${historyLabel(a, money).label}');
  }
  b.writeln();
  for (final pot in (hand['pots'] as List).cast<Json>()) {
    b.writeln('${(pot['winners'] as List).map((w) => w['name']).join(' & ')} ${tr('wins', 'dobija')} ${money(pot['amount'])}'
        '${pot['handName'] != null ? ' — ${pot['handName']}' : ''}');
  }
  return b.toString();
}

/// Detalj ruke preko celog ekrana: sto, igrači, potezi po ulicama (kolone), ponovo odigraj, podeli, sačuvaj.
class HandDetailScreen extends StatelessWidget {
  final Json hand;
  final Money money;
  const HandDetailScreen({super.key, required this.hand, required this.money});

  @override
  Widget build(BuildContext context) {
    final players = (hand['players'] as List).cast<Json>();
    final board = (hand['board'] as List).cast<String>();
    final actions = ((hand['actions'] as List?) ?? []).cast<Json>();
    final pots = (hand['pots'] as List).cast<Json>();
    final winners = <String>{for (final p in pots) for (final w in (p['winners'] as List)) w['name'] as String};
    final table = (hand['table'] as Map?)?['name'];

    // Potezi po ulicama i pot na početku svake ulice.
    const streets = ['preflop', 'flop', 'turn', 'river'];
    final byStreet = {for (final s in streets) s: <Json>[]};
    final potAt = <String, int>{};
    var pot = 0;
    String? cur;
    final contrib = <String, int>{};
    void closeStreet() {
      pot += contrib.values.fold(0, (a, b) => a + b);
      contrib.clear();
    }
    for (final a in actions) {
      final st = a['street'] as String? ?? 'preflop';
      if (st != cur) {
        if (cur != null) closeStreet();
        cur = st;
        potAt[st] = pot;
      }
      byStreet.putIfAbsent(st, () => []).add(a);
      final amt = a['amount'] as int? ?? 0;
      final who = a['name'] as String;
      switch (a['type']) {
        case 'ante' || 'bomb':
          pot += amt;
        case 'sb' || 'bb' || 'straddle':
          contrib[who] = (contrib[who] ?? 0) + amt;
        case 'call' || 'bet' || 'raise' || 'allin':
          contrib[who] = amt > (contrib[who] ?? 0) ? amt : (contrib[who] ?? 0);
      }
    }
    closeStreet();
    final total = pots.fold<int>(0, (a, p) => a + (p['amount'] as int));
    // Pre-flopa: pot posle antea i blajndova (kao na velikim sajtovima).
    final forced = actions
        .where((a) => const ['ante', 'bomb', 'sb', 'bb', 'straddle'].contains(a['type']))
        .fold<int>(0, (s, a) => s + (a['amount'] as int? ?? 0));

    Widget streetColumn(String st) {
      final dealt = switch (st) {
        'flop' => board.take(3).toList(),
        'turn' => board.length > 3 ? [board[3]] : <String>[],
        'river' => board.length > 4 ? [board[4]] : <String>[],
        _ => <String>[],
      };
      final acts = byStreet[st] ?? [];
      return Container(
        width: 150,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white10))),
            child: Column(children: [
              Text(_streetNames[st] ?? st, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
              const SizedBox(height: 3),
              Text(potAt.containsKey(st) || st == 'preflop' ? money(st == 'preflop' ? forced : potAt[st]!) : '—',
                  style: const TextStyle(color: goldLight, fontWeight: FontWeight.w800)),
              if (dealt.isNotEmpty) ...[
                const SizedBox(height: 5),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (final c in dealt) Padding(padding: const EdgeInsets.symmetric(horizontal: 1.5), child: PlayingCard(code: c, width: 24)),
                ]),
              ],
            ]),
          ),
          for (final a in acts)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(6), border: Border.all(color: historyLabel(a, money).color.withOpacity(0.6))),
                  child: Text(historyLabel(a, money).label,
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: historyLabel(a, money).color)),
                ),
              ]),
            ),
          const SizedBox(height: 8),
        ]),
      );
    }

    Future<void> doShare() async {
      final r = await HandShare.share('${tr('Hand', 'Ruka')} #${hand['handNo']}', handText(hand, money));
      if (!context.mounted) return;
      final msg = switch (r) {
        'copied' => tr('Hand copied — paste it anywhere.', 'Ruka je kopirana — nalepite je gde želite.'),
        'failed' => tr('Sharing is not available here.', 'Deljenje ovde nije moguće.'),
        _ => null,
      };
      if (msg != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }

    void doSave() {
      final r = HandShare.download('triling-ruka-${hand['handNo']}.txt', handText(hand, money));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(r == 'ok' ? tr('Hand saved to Downloads.', 'Ruka je sačuvana u preuzimanja.') : tr('Saving is not available here.', 'Čuvanje ovde nije moguće.'))));
    }

    Widget action(IconData icon, String label, VoidCallback onTap) => Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white10, border: Border.all(color: gold.withOpacity(0.5))),
                  child: Icon(icon, color: goldLight),
                ),
                const SizedBox(height: 4),
                Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        );

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0B08),
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${tr('Hand', 'Ruka')} #${hand['handNo']}', style: const TextStyle(fontWeight: FontWeight.w800)),
          Text('${table ?? ''}${table != null ? ' · ' : ''}${dateTime(hand['createdAt'])}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.all(12), children: [
            // Sto i pot
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                gradient: const RadialGradient(colors: [Color(0xFF8E1B2A), Color(0xFF4A0A14)], radius: 1.2),
                borderRadius: BorderRadius.circular(60),
                border: Border.all(color: gold.withOpacity(0.7), width: 2),
              ),
              child: Column(children: [
                Text('${tr('Total pot', 'Ukupan pot')}: ${money(total)}', style: const TextStyle(fontWeight: FontWeight.w900, color: goldLight)),
                const SizedBox(height: 8),
                if (board.isNotEmpty)
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (final c in board) Padding(padding: const EdgeInsets.symmetric(horizontal: 2), child: PlayingCard(code: c, width: 38)),
                  ])
                else
                  Text(tr('No board (hand ended before the flop)', 'Bez karata na stolu (ruka završena pre flopa)'), style: const TextStyle(color: Colors.white60)),
              ]),
            ),
            const SizedBox(height: 12),
            // Igrači
            for (final p in players)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: p['isMe'] == true ? gold.withOpacity(0.12) : Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: winners.contains(p['name']) ? gold : Colors.white10),
                ),
                child: Row(children: [
                  Expanded(
                    child: Row(children: [
                      Flexible(
                        child: Text(p['name'] as String,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w800, color: p['isMe'] == true ? const Color(0xFFFF9F43) : Colors.white)),
                      ),
                      if (winners.contains(p['name']))
                        Container(
                          margin: const EdgeInsets.only(left: 6),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(gradient: goldGradient, borderRadius: BorderRadius.circular(6)),
                          child: const Text('WIN', style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900, color: Colors.black)),
                        ),
                    ]),
                  ),
                  if (p['cards'] != null)
                    for (final c in (p['cards'] as List).cast<String>())
                      Padding(padding: const EdgeInsets.only(right: 2), child: PlayingCard(code: c, width: 24))
                  else
                    const Text('— ', style: TextStyle(color: Colors.white38)),
                  SizedBox(
                    width: 84,
                    child: Text(() {
                      final d = (p['endStack'] as int) - (p['startStack'] as int);
                      return '${d > 0 ? '+' : ''}${money(d)}';
                    }(),
                        textAlign: TextAlign.right,
                        style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: () {
                              final d = (p['endStack'] as int) - (p['startStack'] as int);
                              return d > 0 ? winGreen : (d < 0 ? const Color(0xFFFF6B6B) : Colors.white54);
                            }())),
                  ),
                ]),
              ),
            for (final pot in pots)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${(pot['winners'] as List).map((w) => w['name']).join(tr(' & ', ' i '))} ${tr('wins', 'dobija')} ${money(pot['amount'])}'
                  '${pot['handName'] != null ? ' · ${pot['handName']}' : ''}',
                  style: const TextStyle(color: gold, fontWeight: FontWeight.w700),
                ),
              ),
            const SizedBox(height: 14),
            // Potezi po ulicama (kolone; prevuci levo-desno)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final st in streets)
                  if (st == 'preflop' || (byStreet[st]?.isNotEmpty ?? false) || potAt.containsKey(st)) streetColumn(st),
              ]),
            ),
          ]),
        ),
        // Dugmad: ponovo odigraj, podeli, sačuvaj
        Container(
          padding: EdgeInsets.fromLTRB(8, 4, 8, 8 + MediaQuery.of(context).padding.bottom),
          decoration: const BoxDecoration(color: Color(0xFF0E0B08), border: Border(top: BorderSide(color: Colors.white10))),
          child: Row(children: [
            action(Icons.play_arrow_rounded, tr('Replay', 'Odigraj ponovo'), () => openHandReplay(context, hand)),
            action(Icons.share, tr('Share', 'Podeli'), doShare),
            action(Icons.download, tr('Save', 'Sačuvaj'), doSave),
          ]),
        ),
      ]),
    );
  }
}
