import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'account_screen.dart';
import 'table_screen.dart';

class LobbyScreen extends StatefulWidget {
  const LobbyScreen({super.key});

  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  String _filter = 'ALL';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().joinLobby());
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final user = app.user ?? {};
    final seatedAt = ((user['seatedAt'] as List?) ?? []).cast<String>();
    final tables = app.lobby.where((t) => _filter == 'ALL' || t['variant'] == _filter).toList();

    return Scaffold(
      appBar: AppBar(
        // Stanje na nalogu gore levo.
        leadingWidth: 150,
        leading: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: panelLight, borderRadius: BorderRadius.circular(10)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Stanje', style: TextStyle(fontSize: 10, color: Colors.white54)),
                  Text(rsd(app.balance), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: gold)),
                ],
              ),
            ),
          ),
        ),
        title: const Text.rich(
          TextSpan(children: [TextSpan(text: 'THE '), TextSpan(text: 'VAULT', style: TextStyle(color: accent))]),
          style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountScreen())),
              child: Avatar(name: user['displayName']?.toString() ?? '', url: user['avatarUrl'] as String?, size: 38),
            ),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            children: [
              if (!app.connected)
                Container(
                  width: double.infinity,
                  color: accentDark,
                  padding: const EdgeInsets.all(6),
                  child: const Text('Povezivanje sa serverom…', textAlign: TextAlign.center, style: TextStyle(fontSize: 13)),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: [
                    const Text('Cash stolovi', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                    const Spacer(),
                    for (final f in const [('ALL', 'Svi'), ('HOLDEM', 'NLH'), ('OMAHA', 'PLO')])
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ChoiceChip(
                          label: Text(f.$2),
                          selected: _filter == f.$1,
                          showCheckmark: false,
                          selectedColor: accent,
                          onSelected: (_) => setState(() => _filter = f.$1),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    await app.joinLobby();
                    await app.refreshMe();
                  },
                  child: tables.isEmpty
                      ? ListView(children: const [
                          SizedBox(height: 120),
                          Center(child: Text('Trenutno nema otvorenih stolova.', style: TextStyle(color: Colors.white60))),
                        ])
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                          itemCount: tables.length,
                          itemBuilder: (_, i) => _TableTile(table: tables[i], seated: seatedAt.contains(tables[i]['id'])),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TableTile extends StatelessWidget {
  final Map<String, dynamic> table;
  final bool seated;
  const _TableTile({required this.table, required this.seated});

  @override
  Widget build(BuildContext context) {
    final t = table;
    final players = t['players'] as int;
    final max = t['maxSeats'] as int;
    final rake = (t['rakePercent'] as num);
    final omaha = t['variant'] == 'OMAHA';
    final color = omaha ? const Color(0xFF7B3FC4) : accent;
    void open() => Navigator.push(context, MaterialPageRoute(builder: (_) => TableScreen(tableId: t['id'])));

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
            colors: [Color.lerp(panel, color, 0.18)!, panel], begin: Alignment.centerLeft, end: Alignment.centerRight),
        border: Border.all(color: seated ? gold : Colors.white10),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: open,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // Ulozi velikim brojevima, kao u lobiju velikih poker sajtova
              Container(
                width: 74,
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
                    child: Text(omaha ? 'PLO' : 'NLH', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900)),
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    child: Text('${chips(t['smallBlind'])}/${chips(t['bigBlind'])}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                  ),
                  const Text('RSD', style: TextStyle(fontSize: 10, color: Colors.white54)),
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(t['name'],
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
                      ),
                      if (seated) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: gold, borderRadius: BorderRadius.circular(6)),
                          child: const Text('SEDITE',
                              style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w900)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(omaha ? 'Omaha · pot-limit' : "Texas Hold'em · no-limit",
                        style: const TextStyle(color: Colors.white60, fontSize: 12.5)),
                    const SizedBox(height: 6),
                    Text('Ulaz ${chips(t['minBuyIn'])} – ${rsd(t['maxBuyIn'])}', style: const TextStyle(fontSize: 12.5)),
                    // Rake je tu za informaciju, ali neupadljivo.
                    if (rake > 0)
                      Text(
                        'rake $rake%${(t['rakeCap'] as int? ?? 0) > 0 ? ', najviše ${rsd(t['rakeCap'])}' : ''}',
                        style: const TextStyle(fontSize: 10.5, color: Colors.white30),
                      ),
                    const SizedBox(height: 6),
                    // Popunjenost stola: tačkice za zauzeta i slobodna mesta
                    Row(children: [
                      for (var k = 0; k < max; k++)
                        Container(
                          width: 9,
                          height: 9,
                          margin: const EdgeInsets.only(right: 3),
                          decoration: BoxDecoration(shape: BoxShape.circle, color: k < players ? winGreen : Colors.white12),
                        ),
                      const SizedBox(width: 4),
                      Text('$players/$max', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
                  ],
                ),
              ),
              FilledButton(
                style:
                    FilledButton.styleFrom(minimumSize: const Size(76, 40), padding: const EdgeInsets.symmetric(horizontal: 12)),
                onPressed: open,
                child: Text(seated ? 'NASTAVI' : 'IGRAJ', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
