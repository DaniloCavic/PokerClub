import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../i18n.dart';
import '../share/share.dart';
import '../widgets/avatar.dart';
import '../widgets/playing_card.dart';
import '../widgets/hand_history.dart' show HandDetailScreen;

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

/// Stek u velikim blajndovima: " (31 BB)".
String inBb(num? stack, num? bb) => (bb ?? 0) > 0 ? ' (${bbNumber((stack ?? 0) / bb!)} BB)' : '';

/// Blajndovi sa ante-om: "100/200 (ante 25)".
String blindsLabel(num? sb, num? bb, num? ante) => '${chips(sb)}/${chips(bb)}${(ante ?? 0) > 0 ? ' (ante ${chips(ante)})' : ''}';

/// Kraj kasne prijave ili rebuy-a: odbrojavanje dok turnir traje, a pre početka okvirno vreme.
String untilLabel(Json d, int? at, int serverNow) {
  if (at == null) return '';
  if (d['status'] == 'REGISTERING') {
    final t = DateTime.fromMillisecondsSinceEpoch(at).toLocal();
    return tr('until about ${two(t.hour)}:${two(t.minute)}', 'do oko ${two(t.hour)}:${two(t.minute)}');
  }
  if (at <= serverNow) return tr('closed', 'zatvoreno');
  return '${tr('ends in', 'još')} ${clockLeft(at, serverNow)}';
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
      return (label: tr('Registering', 'Prijave otvorene'), color: const Color(0xFF2E7BD6));
    case 'RUNNING':
      return t['regOpen'] == true
          ? (label: tr('Running · late reg', 'U toku · kasna prijava'), color: const Color(0xFF1E8E4E))
          : (label: tr('Running', 'U toku'), color: const Color(0xFF1E8E4E));
    case 'FINISHED':
      return (label: tr('Finished', 'Završen'), color: const Color(0xFF555B66));
    default:
      return (label: tr('Cancelled', 'Otkazan'), color: const Color(0xFF8A2430));
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
          ? ListView(children: [
              SizedBox(height: 120),
              Center(child: Text(tr('No tournaments right now.', 'Trenutno nema turnira.'), style: TextStyle(color: Colors.white60))),
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
                Row(children: [
                  Flexible(
                    child: Text(t['name'] as String, style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
                  ),
                  if ((t['bounty'] as num? ?? 0) > 0) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: const Color(0xFFB34A1A), borderRadius: BorderRadius.circular(5)),
                      child: const Text('KO', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900)),
                    ),
                  ],
                  if (t['repeat'] == 'DAILY' || t['repeat'] == 'WEEKLY') ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.repeat, size: 15, color: gold),
                  ],
                ]),
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
                          ? '${tr('Level', 'Nivo')} ${t['level']} · ${chips(t['smallBlind'])}/${chips(t['bigBlind'])}${t['onBreak'] == true ? tr(' · break', ' · pauza') : ''}'
                          : t['status'] == 'REGISTERING' && start.difference(DateTime.now()).inHours < 12
                              ? '${tr('Starts', 'Počinje')} ${countdown(start)}'
                              : opensLabel(start),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                ]),
                const SizedBox(height: 4),
                Text(
                  '${tr('Buy-in', 'Ulaz')} ${rsd((t['buyIn'] as num) + (t['bounty'] as num? ?? 0) + (t['fee'] as num))}${guarantee > 0 ? ' · ${tr('GTD', 'Garantovano')} ${chips(guarantee)}' : ''}',
                  style: const TextStyle(fontSize: 12.5, color: goldLight),
                ),
                Text(
                  running
                      ? tr('${t['playersLeft']} left of ${t['entries']} entries', 'U igri ${t['playersLeft']} od ${t['entries']} ulaza')
                      : t['status'] == 'FINISHED' || t['status'] == 'CANCELLED'
                          ? tr('${t['entries']} entries', '${t['entries']} ulaza')
                      : '${tr('Registered', 'Prijavljeno')} ${t['entries']}${(t['maxPlayers'] as num? ?? 0) > 0 ? ' / ${t['maxPlayers']}' : ''}'
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
  /// Otvoren kao prozor preko stola (X umesto strelice nazad).
  final bool closeIcon;
  const TournamentScreen({super.key, required this.id, this.closeIcon = false});

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
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel', 'Odustani'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Confirm', 'Potvrdi'))),
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
        automaticallyImplyLeading: !widget.closeIcon,
        actions: [
          if (widget.closeIcon) IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
        ],
        title: Text(d?['name'] as String? ?? tr('Tournament', 'Turnir'), style: const TextStyle(fontWeight: FontWeight.w800)),
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
                      TabBar(
                        indicatorColor: gold,
                        labelColor: goldLight,
                        unselectedLabelColor: Colors.white60,
                        labelStyle: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w800, fontSize: 14),
                        unselectedLabelStyle: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w600, fontSize: 14),
                        tabs: [Tab(text: 'Info'), Tab(text: tr('Prizes', 'Nagrade')), Tab(text: tr('Players', 'Igrači')), Tab(text: tr('Tables', 'Stolovi'))],
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
    final total = (d['buyIn'] as num) + (d['bounty'] as num? ?? 0) + (d['fee'] as num);
    final clock = d['clock'] as Json?;
    final now = app.serverNow;
    final running = d['status'] == 'RUNNING';
    final buttons = <Widget>[];
    if (me != null) {
      if (me['canRegister'] == true) {
        buttons.add(LuxButton(
          title: me['isReentry'] == true ? 'RE-ENTRY' : tr('REGISTER', 'PRIJAVI SE'),
          subtitle: rsd(total),
          onTap: _busy
              ? null
              : () => _run('tour:register',
                  confirm: (d['bounty'] as num? ?? 0) > 0
                      ? tr('Buy-in ${rsd(total)} (${chips(d['buyIn'])} prize pool + ${chips(d['bounty'])} bounty + ${chips(d['fee'])} fee) will be taken from your account.',
                          'Ulaz ${rsd(total)} (${chips(d['buyIn'])} nagradni fond + ${chips(d['bounty'])} bounty + ${chips(d['fee'])} fee) se skida sa naloga.')
                      : tr('Buy-in ${rsd(total)} (${chips(d['buyIn'])} prize pool + ${chips(d['fee'])} fee) will be taken from your account.',
                          'Ulaz ${rsd(total)} (${chips(d['buyIn'])} nagradni fond + ${chips(d['fee'])} fee) se skida sa naloga.'),
                  done: tr('You are registered.', 'Prijavljeni ste.')),
        ));
      }
      if (me['canUnregister'] == true) {
        buttons.add(LuxButton(
          title: tr('UNREGISTER', 'ODJAVI SE'),
          subtitle: tr('buy-in refunded', 'ulaz se vraća'),
          gradient: redGradient,
          textColor: Colors.white,
          onTap: _busy ? null : () => _run('tour:unregister', confirm: tr('Unregister from the tournament? Your buy-in goes back to your account.', 'Odjaviti se sa turnira? Ulaz se vraća na nalog.'), done: tr('You are unregistered.', 'Odjavljeni ste.')),
        ));
      }
      if (me['tableId'] != null) {
        buttons.add(LuxButton(
          title: tr('PLAY', 'IGRAJ'),
          subtitle: me['position'] != null ? '${tr('Rank', 'Mesto')} ${me['position']}' : null,
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
          onTap: _busy ? null : () => _run('tour:rebuy', done: tr('Rebuy done.', 'Rebuy je kupljen.')),
        ));
      }
      if (me['canAddon'] == true) {
        final r = d['addonRules'] as Json;
        buttons.add(LuxButton(
          title: 'ADD-ON',
          subtitle: '${rsd((r['price'] as num) + (r['fee'] as num))} → ${chips(r['chips'])}',
          onTap: _busy ? null : () => _run('tour:addon', done: tr('Add-on done.', 'Add-on je kupljen.')),
        ));
      }
    }
    final fin = (me?['finished'] as Json?)?['position'] == null ? null : me!['finished'] as Json;
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
            _stat(tr('Prize pool', 'Nagradni fond'), chips(d['prizePool']), big: true),
            if ((d['guarantee'] as num? ?? 0) > 0) _stat(tr('Guaranteed', 'Garantovano'), chips(d['guarantee'])),
            _stat(tr('Buy-in', 'Ulaz'), rsd(total)),
            _stat(running ? tr('Players left', 'U igri') : tr('Registered', 'Prijavljeno'), running ? '${d['playersLeft']} / ${d['entries']}' : '${d['entries']}'),
            if (d['status'] == 'REGISTERING') _stat(tr('Starts', 'Počinje'), '${opensLabel(start)}\n${countdown(start)}'),
            if (running && clock != null)
              clock['onBreak'] == true
                  ? _stat(tr('Break', 'Pauza'), '${tr('ends in', 'još')} ${clockLeft((clock['breakEndsAt'] as num?)?.toInt(), now)}')
                  : _stat('${tr('Level', 'Nivo')} ${d['level']}',
                      clock['levelEndsAt'] == null ? tr('last level', 'poslednji nivo') : '${tr('next in', 'sledeći za')} ${clockLeft((clock['levelEndsAt'] as num?)?.toInt(), now)}'),
            if (d['estimatedMinutes'] != null && d['status'] == 'REGISTERING') _stat(tr('Duration', 'Trajanje'), '~${durationLabel((d['estimatedMinutes'] as num).toInt())}'),
          ]),
          if (running || d['status'] == 'REGISTERING') ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Colors.white12),
            const SizedBox(height: 10),
            _stacks(d, now),
          ],
          if (fin != null) ...[
            const SizedBox(height: 10),
            GoldText(
              tr('You finished #${fin['position']}${(fin['prize'] as num? ?? 0) > 0 ? ' · prize ${rsd(fin['prize'])}' : ''}',
                  'Završili ste na ${fin['position']}. mestu${(fin['prize'] as num? ?? 0) > 0 ? ' · nagrada ${rsd(fin['prize'])}' : ''}'),
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

  /// Blajndovi, kasna prijava, rebuy i stekovi (sa vrednošću u velikim blajndovima).
  Widget _stacks(Json d, int now) {
    final running = d['status'] == 'RUNNING';
    final bb = d['bigBlind'] as num?;
    final lateAt = (d['lateRegEndsAt'] as num?)?.toInt();
    final rebuyAt = (d['rebuyEndsAt'] as num?)?.toInt();
    final lateOpen = lateAt != null && (!running || d['regOpen'] == true);
    final rows = <(String, String, Color?)>[
      (running ? tr('Blinds', 'Blajndovi') : tr('Starting blinds', 'Početni blajndovi'), blindsLabel(d['smallBlind'], bb, d['ante']), goldLight),
      (
        tr('Late registration', 'Kasna prijava'),
        lateAt == null ? tr('only before the start', 'samo pre početka') : (lateOpen ? untilLabel(d, lateAt, now) : tr('closed', 'zatvorena')),
        lateOpen ? winGreen : Colors.white54,
      ),
      if (rebuyAt != null) ('Rebuy', untilLabel(d, rebuyAt, now), running && rebuyAt <= now ? Colors.white54 : null),
      (tr('Starting stack', 'Početni stek'), '${chips(d['startingStack'])}${inBb(d['startingStack'], bb)}', null),
      if (running) ...[
        (tr('Average stack', 'Prosečan stek'), '${chips(d['avgStack'])}${inBb(d['avgStack'], bb)}', null),
        (tr('Largest stack', 'Najveći stek'), '${chips(d['maxStack'])}${inBb(d['maxStack'], bb)}', null),
        (tr('Smallest stack', 'Najmanji stek'), '${chips(d['minStack'])}${inBb(d['minStack'], bb)}', null),
      ],
    ];
    return Column(children: [
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.5),
          child: Row(children: [
            Expanded(child: Text(r.$1, style: const TextStyle(color: Colors.white60, fontSize: 13))),
            Text(r.$2, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800, color: r.$3 ?? Colors.white)),
          ]),
        ),
    ]);
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
      'HOURLY' => tr('Every hour, ${d['breakMinutes']} min (at :${60 - (d['breakMinutes'] as num)})', 'Svakog sata, ${d['breakMinutes']} min (od ${60 - (d['breakMinutes'] as num)}. minuta)'),
      'LEVELS' => tr('After every ${d['breakEvery']} levels, ${d['breakMinutes']} min', 'Posle svakih ${d['breakEvery']} nivoa, ${d['breakMinutes']} min'),
      _ => tr('No breaks', 'Bez pauza'),
    };
    return ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 20), children: [
      _section(tr('Rules', 'Pravila'), [
        _kv(tr('Starting stack', 'Početni stek'), chips(d['startingStack'])),
        _kv(tr('Buy-in', 'Ulaz'), '${chips(d['buyIn'])}${(d['bounty'] as num? ?? 0) > 0 ? ' + ${chips(d['bounty'])} bounty' : ''} + ${chips(d['fee'])} fee'),
        if ((d['bounty'] as num? ?? 0) > 0)
          _kv(
              d['progressive'] == false ? 'Bounty (KO)' : tr('Progressive bounty (PKO)', 'Progresivni bounty (PKO)'),
              d['progressive'] == false
                  ? tr('You win ${rsd(d['bounty'])} for every player you knock out; the winner also gets their own bounty.',
                      'Za svakog igrača koga izbacite dobijate ${rsd(d['bounty'])}; pobednik dobija i svoj bounty.')
                  : tr('Everyone starts with ${rsd(d['bounty'])} on their head. Knock a player out: half of their bounty is paid to you, the other half is added to your head. The winner also gets their own head. Bounties are shown at the table.',
                      'Svako počinje sa ${rsd(d['bounty'])} na glavi. Kad izbacite igrača, pola njegovog bounty-ja dobijate odmah, a pola se dodaje na vašu glavu. Pobednik dobija i svoju glavu. Bounty svakog igrača vidi se za stolom.')),
        if (d['repeat'] == 'DAILY' || d['repeat'] == 'WEEKLY')
          _kv(tr('Repeats', 'Ponavlja se'), d['repeat'] == 'DAILY' ? tr('every day at the same time', 'svaki dan u isto vreme') : tr('every week at the same time', 'svake nedelje u isto vreme')),
        _kv('Players per table', '${d['tableSize'] ?? 9}'),
        if (d['actionSeconds'] != null) _kv('Time to act', '${d['actionSeconds']} s'),
        _kv(
            tr('Breaks', 'Pauze'),
            (ad != null && (ad['breakMinutes'] as num? ?? 0) > 0 && (ad['level'] as num? ?? 0) > 0)
                ? '$breaks · ${tr('add-on break ${ad['breakMinutes']} min after level ${ad['level']}', 'add-on pauza ${ad['breakMinutes']} min posle nivoa ${ad['level']}')}'
                : breaks),
        _kv(tr('Late registration', 'Kasna prijava'), (d['lateRegLevels'] as num? ?? 0) > 0 ? tr('until the end of level ${d['lateRegLevels']}', 'do kraja nivoa ${d['lateRegLevels']}') : tr('only before the start', 'samo pre početka')),
        if ((d['reentryMax'] as num? ?? 0) > 0) _kv('Re-entry', tr('up to ${d['reentryMax']}× (during late registration)', 'do ${d['reentryMax']}× (tokom kasne prijave)')),
        if (rb != null && (rb['levels'] as num) > 0)
          _kv(
            'Rebuy',
            '${rsd((rb['price'] as num) + (rb['fee'] as num))} → ${chips(rb['chips'])} ${tr('chips, until the end of level', 'žetona, do kraja nivoa')} ${rb['levels']}'
                '${(rb['max'] as num) > 0 ? tr(', up to ${rb['max']}×', ', najviše ${rb['max']}×') : ''}'
                '${(rb['below'] as num) > 0 ? tr(', when you have ${chips(rb['below'])} or less', ', kad imate ${chips(rb['below'])} ili manje') : tr(', when you run out of chips', ', kad ostanete bez žetona')}',
          ),
        if (ad != null && (ad['level'] as num) > 0)
          _kv('Add-on', '${rsd((ad['price'] as num) + (ad['fee'] as num))} → ${chips(ad['chips'])} ${tr('chips, once, at the end of late registration (level ${ad['level']})', 'žetona, jednom, na kraju kasne prijave (nivo ${ad['level']})')}'
              '${(ad['breakMinutes'] as num? ?? 0) > 0 ? tr(', during the ${ad['breakMinutes']}-min add-on break', ', tokom add-on pauze od ${ad['breakMinutes']} min') : ''}'),
        if (d['minPlayers'] != null) _kv('Minimum players', tr('${d['minPlayers']} (otherwise the tournament is cancelled and buy-ins refunded)', '${d['minPlayers']} (inače se turnir otkazuje i ulaz vraća)')),
        if (d['estimatedMinutes'] != null) _kv('Duration', '${tr('about', 'oko')} ${durationLabel((d['estimatedMinutes'] as num).toInt())}'),
      ]),
      _section(tr('Blind structure', 'Blajndovi'), [
        Row(children: [
          SizedBox(width: 50, child: Text(tr('Level', 'Nivo'), style: TextStyle(color: Colors.white60, fontSize: 12))),
          Expanded(child: Text(tr('Blinds', 'Blajndovi'), style: TextStyle(color: Colors.white60, fontSize: 12))),
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
      _section(d['poolFinal'] == true || d['status'] == 'FINISHED' ? tr('Prizes', 'Nagrade') : tr('Prizes (pool can still grow)', 'Nagrade (fond još raste)'), [
        Text(tr('Prize pool: ${chips(d['prizePool'])} · paid places: ${p.length}', 'Nagradni fond: ${chips(d['prizePool'])} · plaćeno mesta: ${p.length}'), style: const TextStyle(color: Colors.white70)),
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
    final bounty = (d['bounty'] as num? ?? 0) > 0;
    if (s.isEmpty) return Center(child: Text(tr('No players registered yet.', 'Još nema prijavljenih igrača.'), style: TextStyle(color: Colors.white60)));
    const head = TextStyle(fontSize: 11.5, color: Colors.white54, fontWeight: FontWeight.w700);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 20),
      itemCount: s.length + 1,
      itemBuilder: (_, row) {
        if (row == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
            child: Row(children: [
              const SizedBox(width: 44, child: Text('#', style: head)),
              Expanded(child: Text(tr('Player', 'Igrač'), style: head)),
              if (bounty) const SizedBox(width: 44, child: Text('KO', textAlign: TextAlign.right, style: head)),
              SizedBox(width: 92, child: Text(tr('Chips / prize', 'Žetoni / nagrada'), textAlign: TextAlign.right, style: head)),
              if (bounty) const SizedBox(width: 80, child: Text('Bounty', textAlign: TextAlign.right, style: head)),
            ]),
          );
        }
        final x = s[row - 1];
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
            if (bounty)
              SizedBox(
                width: 44,
                child: Text('${x['knockouts'] ?? 0}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 13, color: Color(0xFFFF8A65), fontWeight: FontWeight.w800)),
              ),
            SizedBox(
              width: 92,
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: !out
                      ? Text(chips(x['chips']), style: const TextStyle(fontWeight: FontWeight.w800, color: goldLight))
                      : (x['prize'] as num? ?? 0) > 0
                          ? Text(rsd(x['prize']), style: const TextStyle(fontWeight: FontWeight.w800, color: winGreen))
                          : Text(tr('out', 'ispao'), style: const TextStyle(color: Colors.white38, fontSize: 12)),
                ),
              ),
            ),
            if (bounty)
              SizedBox(
                width: 80,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text((x['bountyWon'] as num? ?? 0) > 0 ? rsd(x['bountyWon']) : '—',
                        style: TextStyle(fontWeight: FontWeight.w800, color: (x['bountyWon'] as num? ?? 0) > 0 ? const Color(0xFFFF8A65) : Colors.white38)),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }

  Widget _tables(Json d) {
    final ts = ((d['tables'] as List?) ?? const []).cast<Map>();
    if (ts.isEmpty) return Center(child: Text(tr('Tables are created when the tournament starts.', 'Stolovi se prave kad turnir počne.'), style: TextStyle(color: Colors.white60)));
    return ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 20), children: [
      for (final x in ts)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            tileColor: panel,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: gold.withOpacity(0.3))),
            leading: const Icon(Icons.table_restaurant, color: gold),
            title: Text(x['name'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(tr('${x['players']} players', '${x['players']} igrača')),
            trailing: Text(tr('WATCH', 'GLEDAJ'), style: TextStyle(color: goldLight, fontWeight: FontWeight.w800)),
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
/// Kraj turnira za igrača (ispadanje ili pobeda): mesto, nagrada (redovna i bounty), vreme,
/// najbolja ruka, bad beat, poslednja ruka, izbačeni igrači, zahvalnica; re-entry ako je moguć; deljenje.
class TourResultDialog extends StatelessWidget {
  final Json r;
  const TourResultDialog({super.key, required this.r});

  String _time(int s) => '${two(s ~/ 3600)}:${two((s % 3600) ~/ 60)}:${two(s % 60)}';

  Future<void> _openHand(BuildContext context, String? id) async {
    if (id == null) return;
    final app = context.read<AppState>();
    try {
      final res = await app.api.get('/me/hands?id=$id');
      final items = (res['items'] as List).cast<Json>();
      if (items.isEmpty || !context.mounted) return;
      final h = items.first;
      final bb = ((h['table'] as Map?)?['bigBlind'] as int?) ?? 1;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => HandDetailScreen(hand: h, money: Money(bb, false))));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final prize = (r['prize'] as num?)?.toInt() ?? 0;
    final bounty = (r['bountyWon'] as num?)?.toInt() ?? 0;
    final total = prize + bounty;
    final winner = r['winner'] == true;
    final position = r['position'];
    final victims = ((r['victims'] as List?) ?? const []).cast<String>();
    final ko = (r['knockouts'] as num?)?.toInt() ?? victims.length;
    final name = (r['playerName'] as String?) ?? (app.user?['displayName'] as String? ?? '');
    Widget handChip(String label, Json? h, IconData icon) => Expanded(
          child: Opacity(
            opacity: h == null ? 0.35 : 1,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: h == null ? null : () => _openHand(context, h['handId'] as String?),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  height: 48,
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    if (h != null)
                      for (final c in ((h['cards'] as List).cast<String>()).take(4))
                        Padding(padding: const EdgeInsets.symmetric(horizontal: 1), child: PlayingCard(code: c, width: (h['cards'] as List).length > 2 ? 20 : 30))
                    else
                      const Icon(Icons.remove, color: Colors.white38),
                  ]),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(12)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 13, color: goldLight),
                    const SizedBox(width: 3),
                    Text(label, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800)),
                  ]),
                ),
                if (h?['name'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(h!['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, color: Colors.white54)),
                  ),
              ]),
            ),
          ),
        );

    String shareText() => [
          'Poker klub Triling — ${r['name']}',
          tr('$name finished #$position of ${r['entries']}', '$name: ${position}. mesto od ${r['entries']}'),
          if (total > 0) '${tr('Total prize', 'Ukupna nagrada')}: ${rsd(total)}${bounty > 0 ? ' (${tr('prize', 'nagrada')} ${rsd(prize)} + bounty ${rsd(bounty)})' : ''}',
          if (ko > 0) tr('Knocked out $ko players', 'Izbacio $ko igrača'),
        ].join('\n');

    return Dialog(
      backgroundColor: panel,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: gold.withOpacity(0.6))),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Zaglavlje: pehar (pobeda) ili zastavica, ime igrača na traci, turnir, mesto
            Container(
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
                gradient: LinearGradient(
                    colors: winner ? const [Color(0xFF5A1020), Color(0xFF2A0810)] : const [Color(0xFF2A1F17), Color(0xFF15100C)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter),
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Column(children: [
                // Znak kluba (kao ikonica aplikacije), levo vreme igre
                Stack(alignment: Alignment.center, children: [
                  Container(
                    width: 118,
                    height: 118,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(colors: [Color(0xFF7A1424), Color(0xFF3A0810)], radius: 0.8),
                      border: Border.all(color: gold, width: 2.5),
                      boxShadow: [BoxShadow(color: gold.withOpacity(0.35), blurRadius: 22, spreadRadius: 2)],
                    ),
                    child: const Center(child: TrilingLogo(size: 24, horizontal: false)),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(tr('Total time', 'Ukupno vreme'), style: const TextStyle(fontSize: 11, color: Colors.white60)),
                      Text(_time((r['totalSeconds'] as num?)?.toInt() ?? 0), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: winGreen)),
                    ]),
                  ),
                  const SizedBox(width: double.infinity, height: 118),
                ]),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                  decoration: BoxDecoration(gradient: redGradient, borderRadius: BorderRadius.circular(8), boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 6)]),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Avatar(name: name, url: r['avatar'] as String?, size: 30),
                    const SizedBox(width: 10),
                    Text(name, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: Colors.white)),
                  ]),
                ),
                const SizedBox(height: 10),
                GoldText(r['name'] as String? ?? '', align: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                if (r['startedAt'] != null) Text(dateTime(r['startedAt'] as String), style: const TextStyle(fontSize: 12, color: Colors.white54)),
                const SizedBox(height: 4),
                const SizedBox(height: 6),
                // Mesto: zlatna oznaka (pobednik: "POBEDNIK")
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                  decoration: BoxDecoration(
                    gradient: winner ? goldGradient : null,
                    color: winner ? null : Colors.black38,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: gold.withOpacity(0.7)),
                  ),
                  child: Text.rich(TextSpan(children: [
                    if (winner) TextSpan(text: '${tr('WINNER', 'POBEDNIK')}  ', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Colors.black)),
                    TextSpan(text: '$position', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: winner ? Colors.black : Colors.white)),
                    TextSpan(text: ' / ${r['entries']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: winner ? Colors.black54 : Colors.white60)),
                  ])),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(children: [
                // Nagrada
                if (total > 0) ...[
                  Text(tr('Total prize', 'Ukupna nagrada'), style: const TextStyle(fontSize: 15, color: Colors.white70)),
                  GoldText(rsd(total), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                  if (bounty > 0) ...[
                    Text('${tr('Regular prize', 'Nagrada za mesto')}: ${rsd(prize)}', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                    Text('${tr('Bounty prize', 'Bounty nagrada')}: ${rsd(bounty)}', style: const TextStyle(color: Color(0xFFFF8A65), fontWeight: FontWeight.w700)),
                  ],
                ] else if (r['pendingPrize'] == true)
                  Text(tr('You are in the money — the prize is paid when the tournament ends.', 'U nagradama ste — nagrada se isplaćuje na kraju turnira.'),
                      textAlign: TextAlign.center, style: const TextStyle(color: goldLight, fontWeight: FontWeight.w700))
                else
                  Text(tr('No prize this time.', 'Ovaj put bez nagrade.'), style: const TextStyle(color: Colors.white60)),
                const SizedBox(height: 10),
                Text(
                    winner
                        ? tr('Congratulations on the win! Thank you for playing.', 'Čestitamo na pobedi! Hvala što ste igrali.')
                        : tr('Thank you for playing! See you at the next tournament.', 'Hvala što ste učestvovali! Vidimo se na sledećem turniru.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 14),
                // Ruke: bad beat, najbolja, poslednja (dodir otvara ruku)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  handChip('Bad beat', r['badBeat'] as Json?, Icons.sentiment_very_dissatisfied),
                  handChip(tr('Best hand', 'Najbolja ruka'), r['bestHand'] as Json?, Icons.star),
                  handChip(tr('Last hand', 'Poslednja ruka'), r['lastHand'] as Json?, Icons.history),
                ]),
                // Izbačeni igrači
                if (ko > 0) ...[
                  const SizedBox(height: 14),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white10)),
                    child: Column(children: [
                      Text.rich(TextSpan(children: [
                        TextSpan(text: tr('You knocked out ', 'Izbacili ste ')),
                        TextSpan(text: '$ko', style: const TextStyle(color: winGreen, fontWeight: FontWeight.w900)),
                        TextSpan(text: tr(' players', ' igrača')),
                      ]), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: 62,
                        child: ListView(scrollDirection: Axis.horizontal, children: [
                          for (final v in victims)
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 5),
                              child: Column(children: [
                                Avatar(name: v, size: 38),
                                const SizedBox(height: 3),
                                SizedBox(width: 60, child: Text(v, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11))),
                              ]),
                            ),
                        ]),
                      ),
                    ]),
                  ),
                ],
                const SizedBox(height: 16),
                if (r['canReenter'] == true) ...[
                  LuxButton(
                    title: 'RE-ENTRY',
                    subtitle: '${tr('play again', 'uđi ponovo')} · ${rsd(r['reentryPrice'])}',
                    onTap: () async {
                      Navigator.pop(context);
                      await app.run('tour:register', {'id': r['tournamentId']});
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                Row(children: [
                  Expanded(
                    child: LuxButton(
                      title: tr('CLOSE', 'ZATVORI'),
                      gradient: const LinearGradient(colors: [Color(0xFF3A3F4A), Color(0xFF262A33)]),
                      textColor: Colors.white,
                      height: 46,
                      onTap: () => Navigator.pop(context),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LuxButton(
                      title: tr('SHARE', 'PODELI'),
                      gradient: redGradient,
                      textColor: Colors.white,
                      height: 46,
                      onTap: () async {
                        final res = await HandShare.share(r['name'] as String? ?? 'Triling', shareText());
                        if (res == 'copied' && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Copied — paste it anywhere.', 'Kopirano — nalepite gde želite.'))));
                        }
                      },
                    ),
                  ),
                ]),
              ]),
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
          item('${tr('LEVEL', 'NIVO')} ${tour['level']}', '${chips(tour['sb'])}/${chips(tour['bb'])}${(tour['ante'] as num) > 0 ? ' (${chips(tour['ante'])})' : ''}', color: goldLight),
          if (!onBreak && tour['levelEndsAt'] != null) item('${tr('NEXT', 'SLEDEĆI')} ${chips(tour['nextSb'])}/${chips(tour['nextBb'])}', clockLeft((tour['levelEndsAt'] as num?)?.toInt(), now)),
          if (onBreak) item(tr('BREAK', 'PAUZA'), clockLeft((tour['breakEndsAt'] as num?)?.toInt(), now), color: goldLight),
          if (!onBreak && nextBreak != null) item(tr('BREAK IN', 'PAUZA ZA'), clockLeft(nextBreak, now)),
          item(tr('RANK', 'MESTO'), tour['position'] != null ? '${tour['position']}/${tour['playersLeft']}' : tr('${tour['playersLeft']} left', '${tour['playersLeft']} igrača')),
          if (tour['lateRegEndsAt'] != null) item(tr('LATE REG', 'KASNA PRIJAVA'), clockLeft((tour['lateRegEndsAt'] as num).toInt(), now), color: winGreen),
          if (tour['rebuyEndsAt'] != null && (wide || vertical)) item('REBUY', clockLeft((tour['rebuyEndsAt'] as num).toInt(), now)),
          item(tr('AVG STACK', 'PROSEK'), '${chips(tour['avgStack'])}${inBb(tour['avgStack'], tour['bb'] as num?)}'),
          if (wide || vertical) ...[
            item(tr('LARGEST', 'NAJVEĆI'), '${chips(tour['maxStack'])}${inBb(tour['maxStack'], tour['bb'] as num?)}'),
            item(tr('SMALLEST', 'NAJMANJI'), '${chips(tour['minStack'])}${inBb(tour['minStack'], tour['bb'] as num?)}'),
            item(tr('STARTING STACK', 'POČETNI STEK'), '${chips(tour['startingStack'])}${inBb(tour['startingStack'], tour['bb'] as num?)}'),
          ],
          if ((tour['bounty'] as num? ?? 0) > 0) item(tr('BOUNTIES', 'BOUNTY'), '${tour['myKnockouts'] ?? 0} KO · ${chips(tour['myBountyWon'] ?? 0)}', color: const Color(0xFFFF8A65)),
          if (wide) item(tr('PRIZE POOL', 'FOND'), chips(tour['prizePool'])),
        ]),
      ),
    );
  }
}
