import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../i18n.dart';

enum _Mode { login, signup, forgot, reset }

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _login = TextEditingController();
  final _email = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  final _resetCode = TextEditingController();
  _Mode _mode = _Mode.login;
  bool _busy = false;
  bool _hide = true;
  String? _error;
  String? _info;

  void _go(_Mode m) => setState(() {
        _mode = m;
        _error = null;
        _info = null;
      });

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final app = context.read<AppState>();
      switch (_mode) {
        case _Mode.login:
          await app.login(_login.text.trim(), _password.text);
        case _Mode.signup:
          if (_password.text != _confirm.text) throw tr('The passwords do not match.', 'Lozinke se ne poklapaju.');
          await app.register(_email.text.trim(), _username.text.trim(), _password.text, _code.text);
        case _Mode.forgot:
          await app.forgotPassword(_email.text.trim());
          setState(() {
            _mode = _Mode.reset;
            _info = tr('If an account with this email exists, we sent a 6-digit code to it. Check your inbox (and spam).',
                'Ako postoji nalog sa ovom e-poštom, poslali smo kod od 6 cifara. Proverite poštu (i spam).');
          });
        case _Mode.reset:
          if (_password.text != _confirm.text) throw tr('The passwords do not match.', 'Lozinke se ne poklapaju.');
          await app.resetPassword(_email.text.trim(), _resetCode.text.trim(), _password.text);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, IconData icon,
      {bool password = false, TextInputType? type, String? helper, bool caps = false, bool last = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: password && _hide,
        keyboardType: type,
        autocorrect: false,
        textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.none,
        textInputAction: last ? TextInputAction.done : TextInputAction.next,
        onSubmitted: last ? (_) => _submit() : null,
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          prefixIcon: Icon(icon),
          suffixIcon: password
              ? IconButton(icon: Icon(_hide ? Icons.visibility : Icons.visibility_off), onPressed: () => setState(() => _hide = !_hide))
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fields = switch (_mode) {
      _Mode.login => [
          _field(_login, tr('Email or username', 'E-pošta ili korisničko ime'), Icons.person, type: TextInputType.emailAddress),
          _field(_password, tr('Password', 'Lozinka'), Icons.lock, password: true, last: true),
        ],
      _Mode.signup => [
          _field(_email, tr('Email', 'E-pošta'), Icons.email, type: TextInputType.emailAddress),
          _field(_username, tr('Username (your name at the table)', 'Korisničko ime (ime za stolom)'), Icons.person,
              helper: tr('3–20 letters, digits, dot or underscore', '3–20 slova, brojeva, tačka ili donja crta')),
          _field(_password, tr('Password', 'Lozinka'), Icons.lock, password: true),
          _field(_confirm, tr('Repeat password', 'Ponovite lozinku'), Icons.lock_outline, password: true),
          _field(_code, tr('Agent code (optional)', 'Kod agenta (nije obavezan)'), Icons.vpn_key,
              caps: true, helper: tr('Your agent gives you this code.', 'Kod vam daje vaš agent.'), last: true),
        ],
      _Mode.forgot => [
          _field(_email, tr('Email of your account', 'E-pošta vašeg naloga'), Icons.email, type: TextInputType.emailAddress, last: true),
        ],
      _Mode.reset => [
          _field(_resetCode, tr('Code from the email', 'Kod iz e-pošte'), Icons.pin, type: TextInputType.number),
          _field(_password, tr('New password', 'Nova lozinka'), Icons.lock, password: true),
          _field(_confirm, tr('Repeat the new password', 'Ponovite novu lozinku'), Icons.lock_outline, password: true, last: true),
        ],
    };
    final button = switch (_mode) {
      _Mode.login => tr('SIGN IN', 'PRIJAVA'),
      _Mode.signup => tr('CREATE ACCOUNT', 'NAPRAVI NALOG'),
      _Mode.forgot => tr('SEND CODE', 'POŠALJI KOD'),
      _Mode.reset => tr('SET NEW PASSWORD', 'POSTAVI NOVU LOZINKU'),
    };
    Widget link(String text, VoidCallback onTap) => TextButton(
          onPressed: _busy ? null : onTap,
          child: Text(text, style: const TextStyle(color: goldLight, fontWeight: FontWeight.w700)),
        );
    return Scaffold(
      body: LuxBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: TrilingLogo(size: 46, horizontal: false)),
                    const SizedBox(height: 10),
                    Text(tr("Texas Hold'em & Omaha · cash games & tournaments", "Texas Hold'em i Omaha · keš igra i turniri"),
                        textAlign: TextAlign.center, style: TextStyle(color: gold.withOpacity(0.8), letterSpacing: 1)),
                    const SizedBox(height: 28),
                    if (_mode == _Mode.forgot || _mode == _Mode.reset) ...[
                      GoldText(tr('Forgot password', 'Zaboravljena lozinka'),
                          align: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                      const SizedBox(height: 14),
                    ],
                    ...fields,
                    if (_info != null) ...[
                      Text(_info!, style: const TextStyle(color: goldLight, fontSize: 13)),
                      const SizedBox(height: 8),
                    ],
                    if (_error != null) ...[
                      Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80))),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 8),
                    LuxButton(title: _busy ? '…' : button, onTap: _busy ? null : _submit),
                    const SizedBox(height: 12),
                    if (_mode == _Mode.login) ...[
                      link(tr('Forgot password?', 'Zaboravili ste lozinku?'), () => _go(_Mode.forgot)),
                      link(tr('New player? Create an account', 'Novi igrač? Napravite nalog'), () => _go(_Mode.signup)),
                    ] else
                      link(tr('Back to sign in', 'Nazad na prijavu'), () => _go(_Mode.login)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
