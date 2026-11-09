import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  String _type = '';
  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
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
  };

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return Scaffold(
      appBar: AppBar(title: const Text('Transakcije')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            children: [
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  const Text('Stanje', style: TextStyle(color: Colors.white60)),
                  const Spacer(),
                  Text(rsd(app.balance), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: gold)),
                ]),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  for (final f in const [('', 'Sve'), ('money', 'Uplate i isplate'), ('tables', 'Stolovi')])
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
                  onRefresh: () => _load(reset: true),
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
                          return const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(child: Text('Nema transakcija.', style: TextStyle(color: Colors.white60))),
                          );
                        }
                        return _items.length < _total
                            ? TextButton(onPressed: () => _load(), child: const Text('Učitaj još'))
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
                              style:
                                  TextStyle(fontWeight: FontWeight.w900, color: amount > 0 ? winGreen : const Color(0xFFFF6B6B)),
                            ),
                            Text('stanje ${rsd(t['balanceAfter'])}', style: const TextStyle(fontSize: 11, color: Colors.white54)),
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
      ),
    );
  }
}
