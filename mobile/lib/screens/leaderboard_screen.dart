import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/brand.dart';
import '../i18n.dart';

typedef Json = Map<String, dynamic>;

/// Mesečna rang lista: turniri (poeni) i keš igra (dobitak).
class LeaderboardScreen extends StatefulWidget {
  /// U glavnom meniju (bez strelice nazad).
  final bool embedded;
  const LeaderboardScreen({super.key, this.embedded = false});

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  late DateTime _month;
  Json? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = DateTime(now.year, now.month);
    _load();
  }

  String get _key => '${_month.year}-${two(_month.month)}';

  Future<void> _load() async {
    setState(() {
      _data = null;
      _error = null;
    });
    try {
      final d = await context.read<AppState>().api.get('/leaderboard?month=$_key');
      if (mounted) setState(() => _data = Map<String, dynamic>.from(d as Map));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  static const _months = [
    ['January', 'Januar'], ['February', 'Februar'], ['March', 'Mart'], ['April', 'April'], ['May', 'Maj'], ['June', 'Jun'],
    ['July', 'Jul'], ['August', 'Avgust'], ['September', 'Septembar'], ['October', 'Oktobar'], ['November', 'Novembar'], ['December', 'Decembar'],
  ];

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrent = _month.year == now.year && _month.month == now.month;
    final name = _months[_month.month - 1];
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: widget.embedded ? Colors.transparent : bg,
        appBar: AppBar(
          backgroundColor: widget.embedded ? Colors.transparent : const Color(0xFF0E0B08),
          automaticallyImplyLeading: !widget.embedded,
          centerTitle: false,
          title: widget.embedded
              ? GoldText(tr('Ranking', 'Rang lista'), style: const TextStyle(fontFamily: 'Cinzel', fontSize: 22, fontWeight: FontWeight.w800))
              : Text(tr('Leaderboard', 'Rang lista'), style: const TextStyle(fontWeight: FontWeight.w800)),
          bottom: TabBar(
            indicatorColor: gold,
            labelColor: goldLight,
            unselectedLabelColor: Colors.white60,
            labelStyle: const TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w800, fontSize: 14),
            tabs: [Tab(text: tr('Tournaments', 'Turniri')), Tab(text: tr('Cash game', 'Keš igra'))],
          ),
        ),
        body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: Column(children: [
          // Izbor meseca
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(children: [
              IconButton(
                onPressed: () {
                  setState(() => _month = DateTime(_month.year, _month.month - 1));
                  _load();
                },
                icon: const Icon(Icons.chevron_left, color: goldLight),
              ),
              Expanded(
                child: Center(
                  child: GoldText('${tr(name[0], name[1])} ${_month.year}', style: const TextStyle(fontFamily: 'Cinzel', fontSize: 18, fontWeight: FontWeight.w800)),
                ),
              ),
              IconButton(
                onPressed: isCurrent
                    ? null
                    : () {
                        setState(() => _month = DateTime(_month.year, _month.month + 1));
                        _load();
                      },
                icon: Icon(Icons.chevron_right, color: isCurrent ? Colors.white24 : goldLight),
              ),
            ]),
          ),
          Expanded(
            child: _error != null
                ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white54)))
                : _data == null
                    ? const Center(child: CircularProgressIndicator(color: gold))
                    : TabBarView(children: [
                        _list(
                          ((_data!['tournaments'] as List?) ?? const []).cast<Json>(),
                          (_data!['me'] as Map?)?['tournaments'] as Map?,
                          (r) => '${r['points']}',
                          tr('pts', 'poena'),
                          (r) => tr('${r['played']} played · ${r['wins']} wins', '${r['played']} odigrano · ${r['wins']} pobeda'),
                          tr('Points per tournament: 10 × √(players ÷ place). Bigger tournament and better place = more points.',
                              'Poeni po turniru: 10 × √(broj igrača ÷ mesto). Veći turnir i bolje mesto = više poena.'),
                        ),
                        _list(
                          ((_data!['cash'] as List?) ?? const []).cast<Json>(),
                          (_data!['me'] as Map?)?['cash'] as Map?,
                          (r) => '${(r['profit'] as num) > 0 ? '+' : ''}${chips(r['profit'])}',
                          'RSD',
                          (r) => tr('${r['hands']} hands', '${r['hands']} ruku'),
                          tr('Cash game winnings this month (all hands at cash tables).', 'Dobitak u keš igri ovog meseca (sve ruke za keš stolovima).'),
                        ),
                      ]),
          ),
        ]))),
      ),
    );
  }

  Widget _list(List<Json> rows, Map? me, String Function(Json) value, String unit, String Function(Json) sub, String info) {
    final myId = context.read<AppState>().user?['id'];
    if (rows.isEmpty) {
      return Center(child: Text(tr('No results this month yet.', 'Još nema rezultata ovog meseca.'), style: const TextStyle(color: Colors.white54)));
    }
    Widget row(int rank, Json r, {bool pinned = false}) {
      final mine = r['userId'] == myId;
      final medal = rank <= 3 ? [const Color(0xFFE8C766), const Color(0xFFC9CED6), const Color(0xFFCD8B4E)][rank - 1] : null;
      return Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? gold.withOpacity(0.14) : panel.withOpacity(0.7),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: mine ? gold : (medal ?? Colors.white10).withOpacity(medal != null ? 0.6 : 1)),
        ),
        child: Row(children: [
          SizedBox(
            width: 34,
            child: medal != null
                ? Icon(Icons.emoji_events, color: medal, size: 24)
                : Text('$rank.', style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.white70)),
          ),
          Avatar(name: r['name'] as String, url: r['avatarUrl'] as String?, size: 36),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(sub(r), style: const TextStyle(fontSize: 11.5, color: Colors.white54)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(value(r),
                style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    color: unit == 'RSD' ? ((r['profit'] as num) >= 0 ? winGreen : const Color(0xFFFF6B6B)) : goldLight)),
            Text(unit, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
          ]),
        ]),
      );
    }

    return ListView(padding: const EdgeInsets.fromLTRB(12, 6, 12, 20), children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(info, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, color: Colors.white54)),
      ),
      // Moje mesto (ako nisam među prikazanima)
      if (me != null && !rows.any((r) => r['userId'] == myId)) ...[
        row(me['rank'] as int, Map<String, dynamic>.from(me)),
        const Divider(color: Colors.white12),
      ],
      for (var k = 0; k < rows.length; k++) row(k + 1, rows[k]),
    ]);
  }
}
