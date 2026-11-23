import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../i18n.dart';

class TransactionsScreen extends StatefulWidget {
  /// U glavnom okviru aplikacije kao Blagajna (bez sopstvene gornje trake).
  final bool embedded;
  const TransactionsScreen({super.key, this.embedded = false});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  String _type = '';
  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;

  List<Map<String, dynamic>> _requests = [];
  num? _lastBalance;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
    _loadRequests();
  }

  Future<void> _loadRequests() async {
    try {
      final res = await context.read<AppState>().api.get('/me/cash-requests');
      if (mounted) setState(() => _requests = (res as List).cast<Map<String, dynamic>>());
    } catch (_) {}
  }

  Future<void> _cancel(String id) async {
    final app = context.read<AppState>();
    try {
      await app.api.post('/me/cash-requests/$id/cancel', {});
    } catch (e) {
      app.toast(e.toString());
    }
    _loadRequests();
  }

  /// Prozor za iznos zahteva (uplata ili isplata).
  Future<void> _request(String type) async {
    final app = context.read<AppState>();
    final amount = TextEditingController();
    final note = TextEditingController();
    final deposit = type == 'DEPOSIT';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(deposit ? tr('Deposit request', 'Zahtev za uplatu') : tr('Withdrawal request', 'Zahtev za isplatu')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: amount,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: tr('Amount (RSD)', 'Iznos (RSD)')),
          ),
          const SizedBox(height: 8),
          TextField(controller: note, maxLength: 200, decoration: InputDecoration(labelText: tr('Note (optional)', 'Napomena (nije obavezna)'), counterText: '')),
          if (!deposit)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('${tr('On account', 'Na nalogu')}: ${rsd(app.balance)}', style: const TextStyle(color: Colors.white60, fontSize: 12.5)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel', 'Odustani'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Send', 'Pošalji'))),
        ],
      ),
    );
    if (ok != true) return;
    final v = int.tryParse(amount.text.replaceAll(RegExp(r'[^0-9]'), ''));
    if (v == null || v <= 0) {
      app.toast(tr('Enter an amount.', 'Unesite iznos.'));
      return;
    }
    try {
      await app.api.post('/me/cash-requests', {'type': type, 'amount': v, if (note.text.trim().isNotEmpty) 'note': note.text.trim()});
      app.toast(tr('Request sent to your agent.', 'Zahtev je poslat agentu.'));
    } catch (e) {
      app.toast(e.toString());
    }
    _loadRequests();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    final app = context.read<AppState>();
    try {
      final page = reset ? 1 : _page + 1;
      final res = await app.api.get('/me/transactions?page=$page&type=$_type');
      final items = (res['items'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _page = page;
        _total = res['total'] as int;
        _items = reset ? items : [..._items, ...items];
      });
    } catch (e) {
      app.toast(e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static const _icons = {
    'DEPOSIT': (Icons.south_west, Color(0xFF3DDC84)),
    'WITHDRAWAL': (Icons.north_east, Color(0xFFFF6B6B)),
    'BUY_IN': (Icons.event_seat, Color(0xFF6FA8FF)),
    'CASH_OUT': (Icons.logout, Color(0xFFF2C14E)),
    'TOURNAMENT_BUY_IN': (Icons.emoji_events_outlined, Color(0xFF6FA8FF)),
    'TOURNAMENT_PRIZE': (Icons.emoji_events, Color(0xFFE8C766)),
    'TOURNAMENT_REFUND': (Icons.undo, Color(0xFF3DDC84)),
    'TOURNAMENT_BOUNTY': (Icons.gps_fixed, Color(0xFFFF8A3D)),
  };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // Stanje se promenilo (agent je odobrio zahtev): osveži zahteve i listu.
    if (_lastBalance != null && _lastBalance != app.balance) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadRequests();
        _load(reset: true);
      });
    }
    _lastBalance = app.balance;
    final body = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          children: [
            if (widget.embedded)
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: GoldText(tr('Cashier', 'Blagajna'), style: const TextStyle(fontFamily: 'Cinzel', fontSize: 22, fontWeight: FontWeight.w800)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: LuxPanel(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Row(children: [
                    const Icon(Icons.account_balance_wallet, color: gold),
                    const SizedBox(width: 8),
                    Text(tr('Account balance', 'Stanje na nalogu'), style: const TextStyle(color: Colors.white70)),
                    const Spacer(),
                    GoldText(rsd(app.balance), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                  ]),
                  const SizedBox(height: 8),
                  const SizedBox(height: 4),
                  // Zahtev za uplatu ili isplatu: agent dobija obaveštenje i odobrava jednim dodirom.
                  Row(children: [
                    Expanded(
                      child: LuxButton(
                        title: tr('DEPOSIT', 'UPLATA'),
                        icon: Icons.south_west,
                        height: 46,
                        onTap: () => _request('DEPOSIT'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: LuxButton(
                        title: tr('WITHDRAW', 'ISPLATA'),
                        icon: Icons.north_east,
                        height: 46,
                        gradient: redGradient,
                        textColor: Colors.white,
                        onTap: () => _request('WITHDRAWAL'),
                      ),
                    ),
                  ]),
                  for (final r in _requests.where((r) => r['status'] == 'PENDING'))
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(10), border: Border.all(color: gold.withOpacity(0.3))),
                      child: Row(children: [
                        const Icon(Icons.hourglass_top, size: 18, color: goldLight),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                              '${r['type'] == 'DEPOSIT' ? tr('Deposit', 'Uplata') : tr('Withdrawal', 'Isplata')} ${rsd(r['amount'])} · ${tr('waiting for agent', 'čeka agenta')}',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        ),
                        TextButton(onPressed: () => _cancel(r['id'] as String), child: Text(tr('Cancel', 'Otkaži'))),
                      ]),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    tr('Your agent approves requests; the change shows here right away.', 'Zahtev odobrava vaš agent; promena se ovde vidi odmah.'),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ]),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(children: [
                for (final f in [('', tr('All', 'Sve')), ('money', tr('Deposits & withdrawals', 'Uplate i isplate')), ('tables', tr('Games', 'Igra'))])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f.$2),
                      selected: _type == f.$1,
                      showCheckmark: false,
                      selectedColor: accent,
                      onSelected: (_) {
                        setState(() => _type = f.$1);
                        _load(reset: true);
                      },
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  await _loadRequests();
                  await _load(reset: true);
                },
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _items.length + 1,
                  separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
                  itemBuilder: (_, i) {
                    if (i == _items.length) {
                      if (_loading) {
                        return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                      }
                      if (_items.isEmpty) {
                        return Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: Text(tr('No transactions.', 'Nema transakcija.'), style: const TextStyle(color: Colors.white60))),
                        );
                      }
                      return _items.length < _total
                          ? TextButton(onPressed: () => _load(), child: Text(tr('Load more', 'Učitaj još')))
                          : const SizedBox(height: 8);
                    }
                    final t = _items[i];
                    final amount = (t['amount'] as num).toInt();
                    final icon = _icons[t['type']] ?? (Icons.circle, Colors.white54);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                          backgroundColor: icon.$2.withOpacity(0.15), child: Icon(icon.$1, color: icon.$2, size: 20)),
                      title: Text(txLabels[t['type']] ?? t['type'], style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text([dateTime(t['createdAt']), if (t['note'] != null) t['note']].join(' · '),
                          style: const TextStyle(fontSize: 12)),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${amount > 0 ? '+' : ''}${rsd(amount)}',
                            style: TextStyle(fontWeight: FontWeight.w900, color: amount > 0 ? winGreen : const Color(0xFFFF6B6B)),
                          ),
                          Text('${tr('balance', 'stanje')} ${rsd(t['balanceAfter'])}', style: const TextStyle(fontSize: 11, color: Colors.white54)),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: Text(tr('Transactions', 'Transakcije'))), body: body);
  }
}
