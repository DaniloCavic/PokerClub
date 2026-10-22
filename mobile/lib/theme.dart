import 'package:flutter/material.dart';

// Tamna tema sa crvenim detaljima (stil modernih poker aplikacija).
const bg = Color(0xFF0B0C10);
const panel = Color(0xFF16181E);
const panelLight = Color(0xFF22252D);
const accent = Color(0xFFE0182D);
const accentDark = Color(0xFF9E0F1F);
const gold = Color(0xFFF2C14E);
const winGreen = Color(0xFF3DDC84);
// Sto
const feltLight = Color(0xFF1E8A6E);
const felt = Color(0xFF0F5E4C);
const feltDark = Color(0xFF073A30);
const railOuter = Color(0xFF15171C);
const railInner = Color(0xFF2B2F38);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: Brightness.dark,
    primary: accent,
    secondary: gold,
    surface: panel,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF101217),
      foregroundColor: Colors.white,
      centerTitle: true,
      elevation: 0,
      titleTextStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: panelLight,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: accent)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
    ),
    cardTheme: CardTheme(color: panel, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    dialogTheme: const DialogTheme(backgroundColor: panel),
    sliderTheme: const SliderThemeData(activeTrackColor: accent, thumbColor: Colors.white, inactiveTrackColor: Colors.white24),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? accent : panel),
        foregroundColor: const WidgetStatePropertyAll(Colors.white),
        side: const WidgetStatePropertyAll(BorderSide(color: Colors.white12)),
      ),
    ),
  );
}

/// Boja avatara iz imena (uvek ista za istog igrača).
Color avatarColor(String seed) {
  const colors = [
    Color(0xFFE0182D), Color(0xFF2F80ED), Color(0xFF27AE60), Color(0xFFF2994A),
    Color(0xFF9B51E0), Color(0xFF00A3A3), Color(0xFFEB5757), Color(0xFFBB6BD9),
  ];
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return colors[h % colors.length];
}
