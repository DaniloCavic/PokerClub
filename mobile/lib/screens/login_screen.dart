import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _hide = true;
  String? _error;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().login(_username.text.trim(), _password.text);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(colors: [Color(0xFF4A0A12), Color(0xFF16090C), bg], radius: 1.1, center: Alignment(0, -0.5)),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('♠ ♥ ♦ ♣', textAlign: TextAlign.center, style: TextStyle(fontSize: 30, color: accent, letterSpacing: 8)),
                    const SizedBox(height: 8),
                    const Text.rich(
                      TextSpan(children: [
                        TextSpan(text: 'POKER ', style: TextStyle(color: Colors.white)),
                        TextSpan(text: 'KLUB', style: TextStyle(color: accent)),
                      ]),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: 2),
                    ),
                    const SizedBox(height: 4),
                    const Text("Texas Hold'em i Omaha · cash stolovi",
                        textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 32),
                    TextField(
                      controller: _username,
                      decoration: const InputDecoration(labelText: 'Korisničko ime', prefixIcon: Icon(Icons.person)),
                      autocorrect: false,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: _hide,
                      decoration: InputDecoration(
                        labelText: 'Lozinka',
                        prefixIcon: const Icon(Icons.lock),
                        suffixIcon: IconButton(
                          icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
                          onPressed: () => setState(() => _hide = !_hide),
                        ),
                      ),
                      onSubmitted: (_) => _submit(),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80))),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Prijava'),
                    ),
                    const SizedBox(height: 24),
                    const Text(
                      'Nalog vam otvara vaš agent. Igra se virtuelnim žetonima koji nemaju novčanu vrednost.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54, fontSize: 13),
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
