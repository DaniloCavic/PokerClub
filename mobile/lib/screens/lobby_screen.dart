import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
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
    final seatedAt = ((app.user?['seatedAt'] as List?) ?? []).cast<String>();
    final tables = app.lobby.where((t) => _filter == 'ALL' || t['variant'] == _filter).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text.rich(TextSpan(children: [
          TextSpan(text: 'POKER '),
          TextSpan(text: 'KLUB', style: TextStyle(color: accent)),
        ]), style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: 1)),
        actions: [
          IconButton(
            tooltip: 'Moj nalog',
            icon: const Icon(Icons.account_circle),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AccountScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          _BalanceBar(name: app.user?['displayName']?.toString() ?? '', balance: app.balance, connected: app.connected),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ALL', label: Text('Svi')),
                ButtonSegment(value: 'HOLDEM', label: Text("Hold'em")),
                ButtonSegment(value: 'OMAHA', label: Text('Omaha')),
              ],
              selected: {_filter},
              onSelectionChanged: (s) => setState(() => _filter = s.first),
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
                      padding: const EdgeInsets.all(12),
                      itemCount: tables.length,
                      itemBuilder: (_, i) => _TableTile(table: tables[i], seated: seatedAt.contains(tables[i]['id'])),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BalanceBar extends StatelessWidget {
  final String name;
  final int balance;
  final bool connected;
  const _BalanceBar({required this.name, required this.balance, required this.connected});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFF3A0911), Color(0xFF121418)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(color: Colors.white70)),
                Row(children: [
                  const Icon(Icons.toll, color: gold, size: 20),
                  const SizedBox(width: 6),
                  Text(chips(balance), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
                ]),
              ],
            ),
          ),
          if (!connected)
            const Row(children: [
              SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('Povezivanje…', style: TextStyle(color: Colors.white60)),
            ]),
        ],
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
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => TableScreen(tableId: t['id']))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: t['variant'] == 'OMAHA' ? const Color(0xFF6A3D9A) : accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Text(t['variant'] == 'OMAHA' ? 'PLO' : 'NLH',
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 16)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(t['name'], style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                      ),
                      if (seated) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: gold, borderRadius: BorderRadius.circular(6)),
                          child: const Text('SEDITE', style: TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 2),
                    Text(variantLong(t['variant']), style: const TextStyle(color: Colors.white60, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(
                      'Blajndovi ${chips(t['smallBlind'])}/${chips(t['bigBlind'])} · ulaz ${chips(t['minBuyIn'])}–${chips(t['maxBuyIn'])}'
                      '${rake > 0 ? ' · rake $rake%' : ''}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              Column(
                children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.person, size: 16, color: Colors.white54),
                    Text(' $players/$max', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  ]),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(14)),
                    child: const Text('IGRAJ', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
