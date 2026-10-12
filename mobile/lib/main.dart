import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'state/app_state.dart';
import 'theme.dart';
import 'screens/login_screen.dart';
import 'screens/lobby_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState()..init();
  runApp(ChangeNotifierProvider.value(value: state, child: const PokerApp()));
}

class PokerApp extends StatelessWidget {
  const PokerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    return MaterialApp(
      title: 'Poker klub',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      navigatorKey: app.navigatorKey,
      scaffoldMessengerKey: app.messengerKey,
      home: Selector<AppState, AuthStatus>(
        selector: (_, s) => s.status,
        builder: (_, status, __) => switch (status) {
          AuthStatus.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
          AuthStatus.loggedOut => const LoginScreen(),
          AuthStatus.loggedIn => const LobbyScreen(),
        },
      ),
    );
  }
}
