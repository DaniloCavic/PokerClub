import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/brand.dart';

typedef Json = Map<String, dynamic>;

String _variantShort(Json t) => t['variant'] == 'OMAHA' ? 'PLO' : 'NLH';

/// "1 h 20 min", "45 min"
String durationLabel(int minutes) {
  if (minutes >= 60) {
    final m = minutes % 60;
    return '${minutes ~/ 60} h${m > 0 ? ' $m min' : ''}';
  }
  return '$minutes min';
}

/// "04:12" (ili "1:04:12") do trenutka `at` (ms, vreme servera).
String clockLeft(int? at, int serverNow) {
  if (at == null) return '--:--';
  final s = ((at - serverNow) / 1000).ceil().clamp(0, 1 << 30);
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '${two(m)}:${two(sec)}';
}

({String label, Color color}) tourStatus(Json t) {
  switch (t['status']) {
    case 'REGISTERING':
      return (label: 'Registering', color: const Color(0xFF2E7BD6));
    case 'RUNNING':
      return t['regOpen'] == true
          ? (label: 'Running · late reg', color: const Color(0xFF1E8E4E))
          : (label: 'Running', color: const Color(0xFF1E8E4E));
    case 'FINISHED':
      return (label: 'Finished', color: const Color(0xFF555B66));
    default:
      return (label: 'Cancelled', color: const Color(0xFF8A2430));
  }
}

/// Lista turnira u lobiju.
class TournamentList extends StatefulWidget {
  final String filter;
  const TournamentList({super.key, this.filter = 'ALL'});

  @override
  State<TournamentList> createState() => _TournamentListState();
}

class _TournamentListState extends State<TournamentList> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadTournaments());
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final list = app.tournaments.where((t) => widget.filter == 'ALL' || t['variant'] == widget.filter).toList();
    return RefreshIndicator(
      color: gold,
      onRefresh: app.loadTournaments,
      child: list.isEmpty
          ? ListView(children: const [
              SizedBox(height: 120),
              Center(child: Text('No tournaments right now.', style: TextStyle(color: Colors.white60))),
            ])
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              itemCount: list.length,
              itemBuilder: (_, i) => _TournamentTile(t: list[i]),
            ),
    );
  }
}

class _TournamentTile extends StatelessWidget {
  final Json t;
  const _TournamentTile({required this.t});

  @override
  Widget build(BuildContext context) {
    final st = tourStatus(t);
    final start = DateTime.parse(t['startAt'] as String).toLocal();
    final running = t['status'] == 'RUNNING';
    final pool = (t['prizePool'] as num?)?.toInt() ?? 0;
    final guarantee = (t['guarantee'] as num?)?.toInt() ?? 0;
    final narrow = MediaQuery.of(context).size.width < 500;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => openTournament(context, t['id'] as String),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: const LinearGradient(colors: [Color(0xFF1E1408), Color(0xFF141110)], begin: Alignment.centerLeft, end: Alignment.centerRight),
            border: Border.all(color: gold.withOpacity(0.35)),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 10)],
          ),
          child: Row(children: [
            // Pehar sa nagradnim fondom
            Container(
              width: narrow ? 64 : 82,
              height: narrow ? 64 : 76,
              decoration: BoxDecoration(
                gradient: const RadialGradient(colors: [Color(0xFF4A3510), Color(0xFF1A1208)]),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: gold.withOpacity(0.8), width: 1.6),
              ),
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.emoji_events, color: goldLight, size: 22),
                Text(_variantShort(t), style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: goldLight)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: FittedBox(
                    child: Text(chips(pool), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.white)),
                  ),
                ),
              ]),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t['name'] as String, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Row(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: st.color, borderRadius: BorderRadius.circular(6)),
                    child: Text(st.label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      running && t['level'] != null
                          ? 'Level ${t['level']} · ${chips(t['smallBlind'])}/${chips(t['bigBlind'])}${t['onBreak'] == true ? ' · break' : ''}'
                          : t['status'] == 'REGISTERING' && start.difference(DateTime.now()).inHours < 12
                              ? 'Starts ${countdown(start)}'
                              : opensLabel(start),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                Text(
                  'Buy-in ${rsd((t['buyIn'] as num) + (t['fee'] as num))}${guarantee > 0 ? ' · GTD ${chips(guarantee)}' : ''}',
                  style: const TextStyle(fontSize: 12.5, color: goldLight),
                ),
                Text(
                  running
                      ? '${t['playersLeft']} left of ${t['entries']} entries'
                      : t['status'] == 'FINISHED' || t['status'] == 'CANCELLED'
                          ? '${t['entries']} entries'
                      : 'Registered ${t['entries']}${(t['maxPlayers'] as num? ?? 0) > 0 ? ' / ${t['maxPlayers']}' : ''}'
                          '${t['rebuy'] == true ? ' · Rebuy' : ''}${t['reentry'] == true ? ' · Re-entry' : ''}${t['addon'] == true ? ' · Add-on' : ''}',
                  style: const TextStyle(fontSize: 12, color: Colors.white60),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: gold),
          ]),
        ),
      ),
    );
  }
}

void openTournament(BuildContext context, String id) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => TournamentScreen(id: id)));
}

/// Detalji turnira: prijava, struktura, nagrade, igrači i stolovi.
class TournamentScreen extends StatefulWidget {
  final String id;
  const TournamentScreen({super.key, required this.id});

  @override
  State<TournamentScreen> createState() => _TournamentScreenState();
}

class _TournamentScreenState extends State<TournamentScreen> {
  late final AppState app;
  Json? t;
  bool _busy = false;
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    app = context.read<AppState>();
    _load();
    app.tourTick.addListener(_load);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && t?['status'] != 'FINISHED') setState(() {});
    });
  }

  @override
  void dispose() {
    app.tourTick.removeListener(_load);
    _clock?.cancel();
    app.emit('tour:unwatch', {'id': widget.id});
    super.dispose();
  }

  Future<void> _load() async {
    final d = await app.tournament(widget.id, watch: true);
    if (mounted && d != null) setState(() => t = d);
  }

  Future<void> _run(String event, {String? confirm, String? done}) async {
    if (confirm != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t!['name'] as String),
          content: Text(confirm),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Odustani')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Potvrdi')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    final ok = await app.run(event, {'id': widget.id});
    if (ok && done != null) app.toast(done);
    await _load();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final d = t;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0E0B08),
        title: Text(d?['name'] as String? ?? 'Tournament', style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: LuxBackground(
        child: d == null
            ? const Center(child: CircularProgressIndicator(color: gold))
            : DefaultTabController(
                length: 4,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 820),
                    child: Column(children: [
                      _header(d),
                      const TabBar(
                        indicatorColor: gold,
                        labelColor: goldLight,
                        unselectedLabelColor: Colors.white60,
                        labelStyle: TextStyle(fontWeight: FontWeight.w800),
                        tabs: [Tab(text: 'Info'), Tab(text: 'Prizes'), Tab(text: 'Players'), Tab(text: 'Tables')],
                      ),
                      Expanded(
                        child: TabBarView(children: [
                          _info(d),
                          _payouts(d),
                          _players(d),
                          _tables(d),
                        ]),
                      ),
                    ]),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _header(Json d) {
    final st = tourStatus(d);
    final me = d['me'] as Json?;
    final start = DateTime.parse(d['startAt'] as String).toLocal();
    final total = (d['buyIn'] as num) + (d['fee'] as num);
    final clock = d['clock'] as Json?;
    final now = app.serverNow;
    final running = d['status'] == 'RUNNING';
    final buttons = <Widget>[];
    if (me != null) {
      if (me['canRegister'] == true) {
        buttons.add(LuxButton(
          title: me['isReentry'] == true ? 'RE-ENTRY' : 'REGISTER',
          subtitle: rsd(total),
          onTap: _busy
              ? null
              : () => _run('tour:register',
                  confirm: 'Buy-in ${rsd(total)} (${chips(d['buyIn'])} prize pool + ${chips(d['fee'])} fee) will be taken from your account.',
                  done: 'You are registered.'),
        ));
      }
      if (me['canUnregister'] == true) {
        buttons.add(LuxButton(
          title: 'UNREGISTER',
          subtitle: 'buy-in refunded',
          gradient: redGradient,
          textColor: Colors.white,
          onTap: _busy ? null : () => _run('tour:unregister', confirm: 'Unregister from the tournament? Your buy-in goes back to your account.', done: 'You are unregistered.'),
        ));
      }
      if (me['tableId'] != null) {
        buttons.add(LuxButton(
          title: 'PLAY',
          subtitle: me['position'] != null ? 'Rank ${me['position']}' : null,
          onTap: () {
            app.showTable(me['tableId'] as String);
            Navigator.of(context).popUntil((r) => r.isFirst);
          },
        ));
      }
      if (me['canRebuy'] == true) {
        final r = d['rebuyRules'] as Json;
        buttons.add(LuxButton(
          title: 'REBUY',
          subtitle: '${rsd((r['price'] as num) + (r['fee'] as num))} → ${chips(r['chips'])}',
          onTap: _busy ? null : () => _run('tour:rebuy', done: 'Rebuy done.'),
        ));
      }
      if (me['canAddon'] == true) {
        final r = d['addonRules'] as Json;
        buttons.add(LuxButton(
          title: 'ADD-ON',
          subtitle: '${rsd((r['price'] as num) + (r['fee'] as num))} → ${chips(r['chips'])}',
          onTap: _busy ? null : () => _run('tour:addon', done: 'Add-on done.'),
        ));
      }
    }
    final fin = me?['finished'] as Json?;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: LuxPanel(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: st.color, borderRadius: BorderRadius.circular(6)),
              child: Text(st.label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 8),
            Text(d['variant'] == 'OMAHA' ? 'Omaha · pot-limit' : "Texas Hold'em · no-limit", style: const TextStyle(color: Colors.white70)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 18, runSpacing: 8, children: [
            _stat('Prize pool', chips(d['prizePool']), big: true),
            if ((d['guarantee'] as num? ?? 0) > 0) _stat('Guaranteed', chips(d['guarantee'])),
            _stat('Buy-in', rsd(total)),
            _stat(running ? 'Players left' : 'Registered', running ? '${d['playersLeft']} / ${d['entries']}' : '${d['entries']}'),
            if (d['status'] == 'REGISTERING') _stat('Starts', '${opensLabel(start)}\n${countdown(start)}'),
            if (running && clock != null)
              clock['onBreak'] == true
                  ? _stat('Break', 'ends in ${clockLeft((clock['breakEndsAt'] as num?)?.toInt(), now)}')
                  : _stat('Level ${d['level']}', '${chips(d['smallBlind'])}/${chips(d['bigBlind'])} · ${clockLeft((clock['levelEndsAt'] as num?)?.toInt(), now)}'),
            if (d['estimatedMinutes'] != null && d['status'] == 'REGISTERING') _stat('Duration', '~${durationLabel((d['estimatedMinutes'] as num).toInt())}'),
          ]),
          if (fin != null) ...[
            const SizedBox(height: 10),
            GoldText(
              'You finished #${fin['position']}${(fin['prize'] as num? ?? 0) > 0 ? ' · prize ${rsd(fin['prize'])}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
            ),
          ],
          if (buttons.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(children: [
              for (var k = 0; k < buttons.length; k++) ...[
                if (k > 0) const SizedBox(width: 8),
                Expanded(child: buttons[k]),
              ],
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, {bool big = false}) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 11.5, color: Colors.white60)),
        big
            ? GoldText(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))
            : Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
      ]);

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: LuxPanel(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            GoldText(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14.5)),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 150, child: Text(k, style: const TextStyle(color: Colors.white60, fontSize: 13))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))),
        ]),
      );

  Widget _info(Json d) {
    final levels = ((d['levels'] as List?) ?? const []).cast<Map>();
    final rb = d['rebuyRules'] as Json?;
    final ad = d['addonRules'] as Json?;
    final cur = d['level'] as int?;
    final breaks = switch (d['breakMode']) {
      'HOURLY' => 'Every hour, ${d['breakMinutes']} min (at :${60 - (d['breakMinutes'] as num)})',
      'LEVELS' => 'After every ${d['breakEvery']} levels, ${d['breakMinutes']} min',
      _ => 'No breaks',
    };
    return ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 20), children: [
      _section('Rules', [
        _kv('Starting stack', chips(d['startingStack'])),
        _kv('Buy-in', '${chips(d['buyIn'])} + ${chips(d['fee'])} fee'),
        _kv('Players per table', '${d['tableSize'] ?? 9}'),
        if (d['actionSeconds'] != null) _kv('Time to act', '${d['actionSeconds']} s'),
        _kv('Breaks', breaks),
        _kv('Late registration', (d['lateRegLevels'] as num? ?? 0) > 0 ? 'until the end of level ${d['lateRegLevels']}' : 'only before the start'),
        if ((d['reentryMax'] as num? ?? 0) > 0) _kv('Re-entry', 'up to ${d['reentryMax']}× (during late registration)'),
        if (rb != null && (rb['levels'] as num) > 0)
          _kv(
            'Rebuy',
            '${rsd((rb['price'] as num) + (rb['fee'] as num))} → ${chips(rb['chips'])} chips, until the end of level ${rb['levels']}'
                '${(rb['max'] as num) > 0 ? ', up to ${rb['max']}×' : ''}'
                '${(rb['below'] as num) > 0 ? ', when you have ${chips(rb['below'])} or less' : ', when you run out of chips'}',
          ),
        if (ad != null && (ad['level'] as num) > 0)
          _kv('Add-on', '${rsd((ad['price'] as num) + (ad['fee'] as num))} → ${chips(ad['chips'])} chips, once, until the end of level ${ad['level']}'),
        if (d['minPlayers'] != null) _kv('Minimum players', '${d['minPlayers']} (otherwise the tournament is cancelled and buy-ins refunded)'),
        if (d['estimatedMinutes'] != null) _kv('Duration', 'about ${durationLabel((d['estimatedMinutes'] as num).toInt())}'),
      ]),
      _section('Blind structure', [
        const Row(children: [
          SizedBox(width: 50, child: Text('Level', style: TextStyle(color: Colors.white60, fontSize: 12))),
          Expanded(child: Text('Blinds', style: TextStyle(color: Colors.white60, fontSize: 12))),
          SizedBox(width: 70, child: Text('Ante', style: TextStyle(color: Colors.white60, fontSize: 12))),
          SizedBox(width: 60, child: Text('Min', textAlign: TextAlign.right, style: TextStyle(color: Colors.white60, fontSize: 12))),
        ]),
        const Divider(color: Colors.white12),
        for (var i = 0; i < levels.length; i++)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            decoration: BoxDecoration(
              color: cur == i + 1 ? gold.withOpacity(0.18) : null,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(children: [
              SizedBox(width: 46, child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700))),
              Expanded(child: Text('${chips(levels[i]['sb'])}/${chips(levels[i]['bb'])}', style: const TextStyle(fontWeight: FontWeight.w700))),
              SizedBox(width: 70, child: Text((levels[i]['ante'] as num) > 0 ? chips(levels[i]['ante']) : '—')),
              SizedBox(width: 56, child: Text('${levels[i]['minutes']}', textAlign: TextAlign.right)),
            ]),
          ),
      ]),
    ]);
  }

  Widget _payouts(Json d) {
    final p = ((d['payouts'] as List?) ?? const []).cast<Map>();
    return ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 20), children: [
      _section(d['poolFinal'] == true || d['status'] == 'FINISHED' ? 'Prizes' : 'Prizes (pool can still grow)', [
        Text('Prize pool: ${chips(d['prizePool'])} · paid places: ${p.length}', style: const TextStyle(color: Colors.white70)),
        const SizedBox(height: 8),
        for (final x in p)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              SizedBox(
                width: 46,
                child: Text('${x['place']}.', style: TextStyle(fontWeight: FontWeight.w800, color: (x['place'] as int) <= 3 ? goldLight : Colors.white)),
              ),
              SizedBox(width: 70, child: Text('${x['percent']} %', style: const TextStyle(color: Colors.white60))),
              Expanded(child: Text(rsd(x['amount']), textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w800))),
            ]),
          ),
      ]),
    ]);
  }

  Widget _players(Json d) {
    final s = ((d['standings'] as List?) ?? const []).cast<Map>();
    final myId = app.user?['id'];
    if (s.isEmpty) return const Center(child: Text('No players registered yet.', style: TextStyle(color: Colors.white60)));
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
      itemCount: s.length,
      itemBuilder: (_, i) {
        final x = s[i];
        final mine = x['userId'] == myId;
        final out = x['status'] == 'BUSTED';
        return Container(
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: mine ? gold.withOpacity(0.16) : panel.withOpacity(0.7),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: mine ? gold : Colors.white10),
          ),
          child: Row(children: [
            SizedBox(width: 44, child: Text('${x['position']}.', style: const TextStyle(fontWeight: FontWeight.w800))),
            Expanded(
              child: Text(x['name'] as String,
                  overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w700, color: out ? Colors.white54 : Colors.white)),
            ),
            if (!out) Text(chips(x['chips']), style: const TextStyle(fontWeight: FontWeight.w800, color: goldLight)),
            if (out && (x['prize'] as num? ?? 0) > 0) Text(rsd(x['prize']), style: const TextStyle(fontWeight: FontWeight.w800, color: winGreen)),
            if (out && (x['prize'] as num? ?? 0) == 0) const Text('out', style: TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
        );
      },
    );
  }

  Widget _tables(Json d) {
    final ts = ((d['tables'] as List?) ?? const []).cast<Map>();
    if (ts.isEmpty) return const Center(child: Text('Tables are created when the tournament starts.', style: TextStyle(color: Colors.white60)));
    return ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 20), children: [
      for (final x in ts)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            tileColor: panel,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: gold.withOpacity(0.3))),
            leading: const Icon(Icons.table_restaurant, color: gold),
            title: Text(x['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${x['players']} players'),
            trailing: const Text('WATCH', style: TextStyle(color: goldLight, fontWeight: FontWeight.w800)),
            onTap: () {
              app.showTable(x['id'] as String);
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
        ),
    ]);
  }
}

/// Kraj turnira za igrača: mesto i nagrada (i re-entry, ako je moguć).
class TourResultDialog extends StatelessWidget {
  final Json r;
  const TourResultDialog({super.key, required this.r});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final prize = (r['prize'] as num?)?.toInt() ?? 0;
    final winner = r['winner'] == true;
    return Dialog(
      backgroundColor: panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: gold.withOpacity(0.6))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(winner ? Icons.emoji_events : Icons.flag, color: goldLight, size: 46),
            const SizedBox(height: 8),
            GoldText(winner ? 'You won!' : 'You are out',
                align: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(r['name'] as String? ?? '', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            Text('#${r['position']} of ${r['entries']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
            if (prize > 0) ...[
              const SizedBox(height: 6),
              Text('Prize: ${rsd(prize)}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: winGreen)),
            ],
            if (r['pendingPrize'] == true) ...[
              const SizedBox(height: 6),
              const Text('You are in the money — the prize is paid when the tournament ends.', textAlign: TextAlign.center, style: TextStyle(color: goldLight)),
            ],
            const SizedBox(height: 16),
            if (r['canReenter'] == true) ...[
              LuxButton(
                title: 'RE-ENTRY',
                subtitle: rsd(r['reentryPrice']),
                onTap: () async {
                  Navigator.pop(context);
                  await app.run('tour:register', {'id': r['tournamentId']});
                },
              ),
              const SizedBox(height: 8),
            ],
            LuxButton(
              title: 'CLOSE',
              gradient: redGradient,
              textColor: Colors.white,
              height: 46,
              onTap: () => Navigator.pop(context),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Traka turnira na stolu: nivo, blajndovi, vreme do sledećeg nivoa i pauze, mesto i prosečan stek.
class TourBar extends StatelessWidget {
  final Json tour;
  final int now;
  final bool wide;
  /// Računar: stavke jedna ispod druge (kartica sa leve strane stola).
  final bool vertical;
  const TourBar({super.key, required this.tour, required this.now, this.wide = false, this.vertical = false});

  @override
  Widget build(BuildContext context) {
    final fs = wide ? 13.0 : 11.5;
    final onBreak = tour['onBreak'] == true;
    final nextBreak = (tour['nextBreakAt'] as num?)?.toInt();
    Widget item(String k, String v, {Color? color}) => vertical
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
            child: SizedBox(
              width: 290,
              child: Row(children: [
                Expanded(child: Text(k, style: TextStyle(fontSize: fs - 1.5, color: Colors.white54, fontWeight: FontWeight.w600))),
                Text(v, style: TextStyle(fontSize: fs, fontWeight: FontWeight.w800, color: color ?? Colors.white)),
              ]),
            ),
          )
        : Padding(
            padding: EdgeInsets.symmetric(horizontal: wide ? 10 : 6),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(k, style: TextStyle(fontSize: fs - 2, color: Colors.white54, fontWeight: FontWeight.w600)),
              Text(v, style: TextStyle(fontSize: fs, fontWeight: FontWeight.w800, color: color ?? Colors.white)),
            ]),
          );
    return Container(
      padding: EdgeInsets.symmetric(vertical: wide ? 6 : 4, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: gold.withOpacity(0.35)),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Flex(direction: vertical ? Axis.vertical : Axis.horizontal, mainAxisSize: MainAxisSize.min, children: [
          item('LEVEL ${tour['level']}', '${chips(tour['sb'])}/${chips(tour['bb'])}${(tour['ante'] as num) > 0 ? ' (${chips(tour['ante'])})' : ''}', color: goldLight),
          if (!onBreak) item('NEXT ${chips(tour['nextSb'])}/${chips(tour['nextBb'])}', clockLeft((tour['levelEndsAt'] as num?)?.toInt(), now)),
          if (onBreak) item('BREAK', clockLeft((tour['breakEndsAt'] as num?)?.toInt(), now), color: goldLight),
          if (!onBreak && nextBreak != null) item('BREAK IN', clockLeft(nextBreak, now)),
          item('RANK', tour['position'] != null ? '${tour['position']}/${tour['playersLeft']}' : '${tour['playersLeft']} left'),
          item('AVG STACK', chips(tour['avgStack'])),
          if (wide) item('PRIZE POOL', chips(tour['prizePool'])),
        ]),
      ),
    );
  }
}
