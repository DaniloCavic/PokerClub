import 'package:audioplayers/audioplayers.dart';

/// Zvukovi za stolom (karte, žetoni, check, fold, "tvoj potez", pobeda).
/// Zvukovi su napravljeni sintezom (assets/sounds), bez tuđih snimaka.
class Sounds {
  static bool enabled = true;
  static final _players = <String, AudioPlayer>{};

  static Future<void> play(String name, {double volume = 0.7}) async {
    if (!enabled) return;
    try {
      final p = _players.putIfAbsent(name, () => AudioPlayer()..setReleaseMode(ReleaseMode.stop));
      await p.stop();
      await p.play(AssetSource('sounds/$name.wav'), volume: volume);
    } catch (_) {
      // Pregledač ponekad ne dozvoli zvuk pre prvog dodira; tada se samo preskoči.
    }
  }
}
