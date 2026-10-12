import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  List<Map<String, dynamic>> _items = [];
  int _total = 0;
  int _page = 1;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
    context.read<AppState>().refreshMe();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() => _loading = true);
    final app = context.read<AppState>();
    try {
      final page = reset ? 1 : _page + 1;
      final res = await app.api.get('/me/transactions?page=$page');
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

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final u = app.user ?? {};
    return Scaffold(
      appBar: AppBar(title: const Text('Moj nalog')),
      body: RefreshIndicator(
        onRefresh: () async {
          await app.refreshMe();
          await _load(reset: true);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u['displayName']?.toString() ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    Text('@${u['username'] ?? ''}', style: const TextStyle(color: Colors.white60)),
                    if (u['agentName'] != null) Text('Agent: ${u['agentName']}', style: const TextStyle(color: Colors.white60)),
                    const SizedBox(height: 12),
                    const Text('Žetoni na nalogu', style: TextStyle(color: Colors.white70)),
                    Row(children: [
                      const Icon(Icons.toll, color: gold),
                      const SizedBox(width: 6),
                      Text(chips(app.balance), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                    ]),
                    const SizedBox(height: 8),
                    const Text(
                      'Uplate i isplate radi vaš agent. Žetoni koje imate za stolom vraćaju se na nalog kad ustanete.',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.lock),
                  label: const Text('Promena lozinke'),
                  onPressed: () => showDialog(context: context, builder: (_) => const _PasswordDialog()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Odjava'),
                  onPressed: () => app.logout(),
                ),
              ),
            ]),
            const SizedBox(height: 20),
            const Text('Istorija', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_items.isEmpty && !_loading) const Text('Još nema promena.', style: TextStyle(color: Colors.white60)),
            ..._items.map((t) {
              final amount = (t['amount'] as num).toInt();
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(txLabels[t['type']] ?? t['type']),
                subtitle: Text([dateTime(t['createdAt']), if (t['note'] != null) t['note']].join(' · ')),
                trailing: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${amount > 0 ? '+' : ''}${chips(amount)}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: amount > 0 ? const Color(0xFF6FD39A) : const Color(0xFFFF8A80),
                      ),
                    ),
                    Text('stanje ${chips(t['balanceAfter'])}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                  ],
                ),
              );
            }),
            if (_items.length < _total)
              TextButton(onPressed: _loading ? null : () => _load(), child: const Text('Učitaj još')),
          ],
        ),
      ),
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _old = TextEditingController();
  final _new = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.read<AppState>();
    try {
      await app.api.post('/me/password', {'oldPassword': _old.text, 'newPassword': _new.text});
      if (!mounted) return;
      Navigator.pop(context);
      app.toast('Lozinka je promenjena.');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Promena lozinke'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _old, obscureText: true, decoration: const InputDecoration(labelText: 'Stara lozinka')),
          const SizedBox(height: 12),
          TextField(controller: _new, obscureText: true, decoration: const InputDecoration(labelText: 'Nova lozinka (bar 6 znakova)')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80)))),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Otkaži')),
        TextButton(onPressed: _busy ? null : _save, child: const Text('Sačuvaj')),
      ],
    );
  }
}
