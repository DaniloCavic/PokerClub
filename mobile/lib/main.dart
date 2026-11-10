import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/home_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Aplikacija radi samo uspravno (bez rotiranja telefona).
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final state = AppState()..init();
  runApp(ChangeNotifierProvider.value(value: state, child: const PokerApp()));
}

class PokerApp extends StatelessWidget {
  const PokerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return MaterialApp(
      title: 'Poker klub Triling',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: app.navigatorKey,
      scaffoldMessengerKey: app.messengerKey,
      builder: (context, child) => _PortraitOnly(child: child!),
      home: Selector<AppState, AuthStatus>(
        selector: (_, s) => s.status,
        builder: (_, status, __) => switch (status) {
          AuthStatus.loading => const Scaffold(body: Center(child: CircularProgressIndicator(color: gold))),
          AuthStatus.loggedOut => const LoginScreen(),
          AuthStatus.loggedIn => const HomeShell(),
        },
      ),
    );
  }
}

/// U pregledaču telefon ne može da se zaključa, pa kad se okrene vodoravno
/// pokažemo poruku da ga vrati uspravno. Računar (veliki ekran) radi normalno.
class _PortraitOnly extends StatelessWidget {
  final Widget child;
  const _PortraitOnly({required this.child});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final phoneLandscape = kIsWeb && size.width > size.height && size.height < 500;
    if (!phoneLandscape) return child;
    return const Material(
      color: Color(0xFF0C0A08),
      child: Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.screen_rotation, color: gold, size: 48),
          SizedBox(height: 14),
          Text('Okrenite telefon uspravno',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}
