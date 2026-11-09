import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../widgets/brand.dart';
import '../widgets/playing_card.dart';
import 'account_screen.dart';

/// Podešavanja igre i naloga.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    Widget sw(String title, String sub, bool v, ValueChanged<bool> on) => SwitchListTile(
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
          value: v,
          onChanged: on,
        );
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const GoldText('Podešavanja', style: TextStyle(fontFamily: 'Cinzel', fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          LuxPanel(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: [
              sw('Iznosi u velikim blajndovima (BB)', 'Umesto u dinarima; menja se i za stolom', app.showBB, app.setShowBB),
              sw('Karte u četiri boje', 'Pik crn, herc crven, karo plav, tref zelen', app.fourColor,
                  (v) => app.setSetting('fourColor', v)),
              sw('Sakrij karte', 'Svoje karte vidite tek kad ih dodirnete', app.hideCards, (v) => app.setSetting('hideCards', v)),
              sw('Automatski re-buy', 'Kad ostanete bez novca na stolu, dopuni do najvećeg ulaza', app.autoRebuy,
                  (v) => app.setSetting('autoRebuy', v)),
            ]),
          ),
          const SizedBox(height: 12),
          // Primer izgleda karata
          Center(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final c in const ['As', 'Kh', 'Qd', 'Jc'])
                Padding(
                    padding: const EdgeInsets.all(3),
                    child: PlayingCard(code: c, width: 40, key: ValueKey('$c${app.fourColor}'))),
            ]),
          ),
          const SizedBox(height: 16),
          LuxPanel(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(children: [
              ListTile(
                leading: const Icon(Icons.lock),
                title: const Text('Promena lozinke', style: TextStyle(fontWeight: FontWeight.w700)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => showPasswordDialog(context),
              ),
              ListTile(
                leading: const Icon(Icons.logout, color: Color(0xFFFF6B6B)),
                title: const Text('Odjava', style: TextStyle(fontWeight: FontWeight.w700, color: Color(0xFFFF6B6B))),
                onTap: app.logout,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
