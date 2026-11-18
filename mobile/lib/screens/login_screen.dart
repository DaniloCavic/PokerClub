import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import '../i18n.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  final _confirm = TextEditingController();
  final _code = TextEditingController();
  /// Pravljenje novog naloga umesto prijave.
  bool _signup = false;
  bool _busy = false;
  bool _hide = true;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final app = context.read<AppState>();
      if (_signup) {
        if (_password.text != _confirm.text) throw tr('The passwords do not match.', 'Lozinke se ne poklapaju.');
        await app.register(_username.text.trim(), _name.text.trim().isEmpty ? _username.text.trim() : _name.text.trim(), _password.text, _code.text);
      } else {
        await app.login(_username.text.trim(), _password.text);
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    Text(tr("Texas Hold'em & Omaha · cash games & tournaments", "Texas Hold'em i Omaha · cash stolovi i turniri"),
                        textAlign: TextAlign.center, style: TextStyle(color: gold.withOpacity(0.8), letterSpacing: 1)),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _username,
                      decoration: InputDecoration(labelText: tr('Username', 'Korisničko ime'), prefixIcon: const Icon(Icons.person)),
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                    ),
                    if (_signup) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _name,
                        decoration: InputDecoration(
                            labelText: tr('Name at the table', 'Ime za stolom'),
                            prefixIcon: const Icon(Icons.badge)),
                        textInputAction: TextInputAction.next,
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: _hide,
                      decoration: InputDecoration(
                        labelText: tr('Password', 'Lozinka'),
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _hide = !_hide),
                        ),
                      ),
                      onSubmitted: (_) => _signup ? null : _submit(),
                    ),
                    if (_signup) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirm,
                        obscureText: _hide,
                        decoration: InputDecoration(labelText: tr('Repeat password', 'Ponovite lozinku'), prefixIcon: const Icon(Icons.lock_outline)),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _code,
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          labelText: tr('Agent code (optional)', 'Kod agenta (nije obavezan)'),
                          helperText: tr('Your agent gives you this code.', 'Kod vam daje vaš agent.'),
                          prefixIcon: const Icon(Icons.vpn_key),
                        ),
                        onSubmitted: (_) => _submit(),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80))),
                    ],
                    const SizedBox(height: 20),
                    LuxButton(
                      title: _busy
                          ? '…'
                          : _signup
                              ? tr('CREATE ACCOUNT', 'NAPRAVI NALOG')
                              : tr('SIGN IN', 'PRIJAVA'),
                      onTap: _busy ? null : _submit,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _signup = !_signup;
                                _error = null;
                              }),
                      child: Text(
                        _signup
                            ? tr('Already have an account? Sign in', 'Već imate nalog? Prijavite se')
                            : tr('New player? Create an account', 'Novi igrač? Napravite nalog'),
                        style: const TextStyle(color: goldLight, fontWeight: FontWeight.w700),
                      ),
                    ),
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
