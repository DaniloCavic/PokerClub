import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import 'transactions_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().refreshMe();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    final app = context.read<AppState>();
    try {
      final file = await ImagePicker().pickImage(source: source, maxWidth: 320, maxHeight: 320, imageQuality: 80);
      if (file == null) return;
      setState(() => _uploading = true);
      await app.setAvatar(await file.readAsBytes());
      app.toast('Slika profila je sačuvana.');
    } catch (e) {
      app.toast(e.toString());
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _photoMenu(bool hasPhoto) {
    showModalBottomSheet(
      context: context,
      backgroundColor: panel,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Izaberi iz galerije'),
            onTap: () {
              Navigator.pop(ctx);
              _pickPhoto(ImageSource.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: const Text('Fotografiši se'),
            onTap: () {
              Navigator.pop(ctx);
              _pickPhoto(ImageSource.camera);
            },
          ),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.delete, color: accent),
              title: const Text('Ukloni sliku'),
              onTap: () async {
                Navigator.pop(ctx);
                final app = context.read<AppState>();
                try {
                  await app.setAvatar(null);
                } catch (e) {
                  app.toast(e.toString());
                }
              },
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final u = app.user ?? {};
    final name = u['displayName']?.toString() ?? '';
    final hasPhoto = u['avatarUrl'] != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Moj profil')),
      body: RefreshIndicator(
        onRefresh: app.refreshMe,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // Zaglavlje: slika, ime i stanje
            Container(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(colors: [Color(0xFF4A0A12), Color(0xFF16181E)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(children: [
                GestureDetector(
                  onTap: _uploading ? null : () => _photoMenu(hasPhoto),
                  child: Stack(
                    children: [
                      Avatar(name: name, url: u['avatarUrl'] as String?, size: 104, borderColor: Colors.white70, borderWidth: 3),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(color: accent, shape: BoxShape.circle, border: Border.all(color: bg, width: 3)),
                          child: _uploading
                              ? const Padding(padding: EdgeInsets.all(7), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.photo_camera, size: 17),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                Text('@${u['username'] ?? ''}', style: const TextStyle(color: Colors.white60)),
                if (u['agentName'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('Agent: ${u['agentName']}', style: const TextStyle(color: Colors.white54, fontSize: 13)),
                  ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(14)),
                  child: Column(children: [
                    const Text('Stanje na nalogu', style: TextStyle(color: Colors.white60, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(rsd(app.balance), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: gold)),
                  ]),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            _MenuCard(children: [
              _MenuItem(
                icon: Icons.receipt_long,
                title: 'Transakcije',
                subtitle: 'Uplate, isplate i stolovi',
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TransactionsScreen())),
              ),
              _MenuItem(
                icon: Icons.lock,
                title: 'Promena lozinke',
                onTap: () => showDialog(context: context, builder: (_) => const _PasswordDialog()),
              ),
              _MenuItem(
                icon: Icons.photo_camera,
                title: hasPhoto ? 'Promeni sliku profila' : 'Dodaj sliku profila',
                onTap: () => _photoMenu(hasPhoto),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.swap_horiz, color: Colors.white70),
                title: const Text('Iznosi za stolom u BB'),
                subtitle: const Text('Umesto u dinarima, u velikim blajndovima', style: TextStyle(fontSize: 12)),
                value: app.showBB,
                activeColor: accent,
                onChanged: app.setShowBB,
              ),
            ]),
            const SizedBox(height: 12),
            _MenuCard(children: [
              _MenuItem(icon: Icons.logout, title: 'Odjava', color: accent, onTap: app.logout),
            ]),
            const SizedBox(height: 12),
            const Text(
              'Uplate i isplate radi vaš agent. Novac koji imate za stolom vraća se na nalog kad ustanete.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _MenuCard extends StatelessWidget {
  final List<Widget> children;
  const _MenuCard({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white10)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: Colors.white10),
          children[i],
        ],
      ]),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? color;
  final VoidCallback onTap;
  const _MenuItem({required this.icon, required this.title, required this.onTap, this.subtitle, this.color});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: color ?? Colors.white70),
      title: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: onTap,
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
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _save() async {
    if (_new.text != _confirm.text) {
      setState(() => _error = 'Nove lozinke se ne poklapaju.');
      return;
    }
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
          const SizedBox(height: 12),
          TextField(controller: _confirm, obscureText: true, decoration: const InputDecoration(labelText: 'Ponovite novu lozinku')),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80)))),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Otkaži')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Sačuvaj')),
      ],
    );
  }
}
