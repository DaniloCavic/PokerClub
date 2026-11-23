import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../format.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/playing_card.dart';
import '../i18n.dart';
import 'leaderboard_screen.dart';

class AccountScreen extends StatefulWidget {
  /// U glavnom okviru aplikacije (bez sopstvene gornje trake).
  final bool embedded;
  const AccountScreen({super.key, this.embedded = false});

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
      app.toast(tr('Profile picture saved.', 'Slika profila je sačuvana.'));
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
            title: Text(tr('Choose from gallery', 'Izaberi iz galerije')),
            onTap: () {
              Navigator.pop(ctx);
              _pickPhoto(ImageSource.gallery);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_camera),
            title: Text(tr('Take a photo', 'Fotografiši se')),
            onTap: () {
              Navigator.pop(ctx);
              _pickPhoto(ImageSource.camera);
            },
          ),
          if (hasPhoto)
            ListTile(
              leading: const Icon(Icons.delete, color: accent),
              title: Text(tr('Remove picture', 'Ukloni sliku')),
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

  Future<void> _emailDialog(String? current) async {
    final c = TextEditingController(text: current ?? '');
    final app = context.read<AppState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Email', 'E-pošta')),
        content: TextField(
          controller: c,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(hintText: 'name@example.com', helperText: tr('Used to sign in and reset your password.', 'Za prijavu i povraćaj lozinke.')),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel', 'Otkaži'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('Save', 'Sačuvaj'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.setEmail(c.text.trim());
      app.toast(tr('Email saved.', 'E-pošta je sačuvana.'));
    } catch (e) {
      app.toast(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final u = app.user ?? {};
    final name = u['displayName']?.toString() ?? '';
    final hasPhoto = u['avatarUrl'] != null;

    final body = RefreshIndicator(
      onRefresh: app.refreshMe,
      child: ListView(
        // Na računaru sadržaj ne ide preko cele širine.
        padding: EdgeInsets.fromLTRB(max(16, (MediaQuery.of(context).size.width - 640) / 2), 8,
            max(16, (MediaQuery.of(context).size.width - 640) / 2), 24),
        children: [
          // Zaglavlje: slika, ime i stanje
          Container(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                  colors: [Color(0xFF4A0A12), Color(0xFF16181E)], begin: Alignment.topLeft, end: Alignment.bottomRight),
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
                            ? const Padding(
                                padding: EdgeInsets.all(7), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
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
                  Text(tr('Account balance', 'Stanje na nalogu'), style: const TextStyle(color: Colors.white60, fontSize: 13)),
                  const SizedBox(height: 2),
                  Text(rsd(app.balance), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: gold)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          _MenuCard(children: [
            _MenuItem(
              icon: Icons.emoji_events,
              title: tr('Leaderboard', 'Rang lista'),
              subtitle: tr('Best players this month', 'Najbolji igrači ovog meseca'),
              color: goldLight,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LeaderboardScreen())),
            ),
            _MenuItem(
              icon: Icons.style,
              title: tr('Card color', 'Boja karata'),
              subtitle: app.fourColor ? tr('Colored (whole card)', 'U boji (cela karta obojena)') : tr('Classic (white)', 'Klasične (bele)'),
              onTap: () => showDialog(context: context, builder: (_) => const _CardColorDialog()),
            ),
            const _PushSwitch(),
            _MenuItem(
              icon: Icons.language,
              title: tr('Language', 'Jezik'),
              subtitle: app.lang == 'sr' ? 'Srpski' : 'English',
              onTap: () => showDialog(context: context, builder: (_) => const _LanguageDialog()),
            ),
            _MenuItem(
              icon: Icons.email,
              title: tr('Email', 'E-pošta'),
              subtitle: (u['email'] as String?) ?? tr('Not set — add it so you can reset a forgotten password', 'Nije uneta — dodajte je da biste mogli da vratite lozinku'),
              onTap: () => _emailDialog(u['email'] as String?),
            ),
            _MenuItem(
              icon: Icons.lock,
              title: tr('Change password', 'Promena lozinke'),
              onTap: () => showDialog(context: context, builder: (_) => const _PasswordDialog()),
            ),
            _MenuItem(
              icon: Icons.photo_camera,
              title: hasPhoto ? tr('Change profile picture', 'Promeni sliku profila') : tr('Add profile picture', 'Dodaj sliku profila'),
              onTap: () => _photoMenu(hasPhoto),
            ),
          ]),
          const SizedBox(height: 12),
          _MenuCard(children: [
            _MenuItem(icon: Icons.logout, title: tr('Sign out', 'Odjava'), color: accent, onTap: app.logout),
          ]),
          const SizedBox(height: 12),
          Text(
            tr('Deposits and withdrawals are done by your agent. Chips you have at a table go back to your account when you stand up.',
                'Uplate i isplate radi vaš agent. Novac koji imate za stolom vraća se na nalog kad ustanete.'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ],
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(appBar: AppBar(title: Text(tr('Profile', 'Moj profil'))), body: body);
  }
}

/// Obaveštenja na telefonu: igrač ih uključuje i isključuje na ovom uređaju.
class _PushSwitch extends StatefulWidget {
  const _PushSwitch();

  @override
  State<_PushSwitch> createState() => _PushSwitchState();
}

class _PushSwitchState extends State<_PushSwitch> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final status = app.pushStatus;
    final on = app.pushOn && status == 'granted';
    String subtitle;
    bool available = true;
    if (status == 'ios-install') {
      subtitle = tr('On iPhone: Share → “Add to Home Screen”, then open Triling from there', 'Na iPhone-u: Deli → „Dodaj na početni ekran“, pa otvorite Triling odatle');
      available = false;
    } else if (status == 'unsupported') {
      subtitle = tr('This browser or app does not support notifications', 'Ovaj pregledač ili aplikacija ne podržava obaveštenja');
      available = false;
    } else if (status == 'denied') {
      subtitle = tr('Notifications are blocked in the phone/browser settings', 'Obaveštenja su blokirana u podešavanjima telefona/pregledača');
      available = false;
    } else {
      subtitle = on
          ? tr('New tables and tournaments, scheduled starts, your turn', 'Novi stolovi i turniri, početak zakazanih, na potezu ste')
          : tr('Off on this phone', 'Isključena na ovom telefonu');
    }
    final tile = SwitchListTile(
      secondary: Icon(on ? Icons.notifications_active : Icons.notifications_off, color: Colors.white70),
      title: Text(tr('Notifications', 'Obaveštenja'), style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      value: on,
      onChanged: !available || _busy
          ? null
          : (v) async {
              setState(() => _busy = true);
              if (v) {
                final ok = await app.enablePush();
                if (!ok) app.toast(app.pushError ?? tr('Notifications are not on.', 'Obaveštenja nisu uključena.'));
              } else {
                await app.disablePush();
                app.toast(tr('Notifications are off on this phone.', 'Obaveštenja su isključena na ovom telefonu.'));
              }
              if (mounted) setState(() => _busy = false);
            },
    );
    return tile;
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

/// Izbor izgleda karata: klasične bele ili u boji (cela karta obojena po znaku).
class _CardColorDialog extends StatelessWidget {
  const _CardColorDialog();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    Widget option(String title, bool colored) {
      final selected = app.fourColor == colored;
      final cards = Row(mainAxisSize: MainAxisSize.min, children: [
        for (final c in const ['As', 'Kh', 'Qd', 'Jc'])
          Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: PlayingCard(code: c, width: 38, colored: colored)),
      ]);
      return InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () {
          app.setSetting('fourColor', colored);
          Navigator.pop(context);
        },
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? gold : Colors.white12, width: selected ? 2 : 1),
          ),
          child: Column(children: [
            Row(children: [
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? gold : Colors.white38, size: 20),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 10),
            cards,
          ]),
        ),
      );
    }

    return AlertDialog(
      title: Text(tr('Card color', 'Boja karata')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        option(tr('Classic', 'Klasične'), false),
        const SizedBox(height: 12),
        option(tr('Colored', 'U boji'), true),
      ]),
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
      setState(() => _error = tr('The new passwords do not match.', 'Nove lozinke se ne poklapaju.'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final app = context.read<AppState>();
    try {
      final res = await app.api.post('/me/password', {'oldPassword': _old.text, 'newPassword': _new.text});
      // Nova lozinka: ostali uređaji su odjavljeni, ovaj dobija novu prijavu.
      if (res['accessToken'] != null) await app.setToken(res['accessToken'] as String);
      if (!mounted) return;
      Navigator.pop(context);
      app.toast(tr('Password changed.', 'Lozinka je promenjena.'));
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(tr('Change password', 'Promena lozinke')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(controller: _old, obscureText: true, decoration: InputDecoration(labelText: tr('Old password', 'Stara lozinka'))),
          const SizedBox(height: 12),
          TextField(
              controller: _new, obscureText: true, decoration: InputDecoration(labelText: tr('New password (at least 6 characters)', 'Nova lozinka (bar 6 znakova)'))),
          const SizedBox(height: 12),
          TextField(
              controller: _confirm, obscureText: true, decoration: InputDecoration(labelText: tr('Repeat the new password', 'Ponovite novu lozinku'))),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80)))),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel', 'Otkaži'))),
        FilledButton(onPressed: _busy ? null : _save, child: Text(tr('Save', 'Sačuvaj'))),
      ],
    );
  }
}

/// Dijalog za promenu lozinke (iz profila i podešavanja).
void showPasswordDialog(BuildContext context) => showDialog(context: context, builder: (_) => const _PasswordDialog());

/// Izbor jezika aplikacije.
class _LanguageDialog extends StatelessWidget {
  const _LanguageDialog();

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    Widget option(String code, String label) => RadioListTile<String>(
          value: code,
          groupValue: app.lang,
          activeColor: gold,
          title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          onChanged: (v) {
            Navigator.pop(context);
            if (v != null && v != app.lang) app.setLang(v);
          },
        );
    return AlertDialog(
      backgroundColor: panel,
      title: Text(tr('Language', 'Jezik')),
      content: Column(mainAxisSize: MainAxisSize.min, children: [option('en', 'English'), option('sr', 'Srpski')]),
    );
  }
}
