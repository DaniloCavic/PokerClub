import 'package:flutter/material.dart';

// Luksuzna tema: crna, zlatna i bordo.
const bg = Color(0xFF0A0908);
const panel = Color(0xFF15120F);
const panelLight = Color(0xFF221D18);
const gold = Color(0xFFD4AF37);
const goldLight = Color(0xFFF6E27A);
const goldDark = Color(0xFF9C7A2B);
const accent = Color(0xFFB3122A); // bordo/crvena
const accentDark = Color(0xFF6B0F1A);
const winGreen = Color(0xFF35D07F);
const online = Color(0xFF2ECC71);
// Sto
const feltLight = Color(0xFF8E1426);
const felt = Color(0xFF6A0E1C);
const feltDark = Color(0xFF34070D);
const railOuter = Color(0xFF1A1310);
const railInner = Color(0xFF3A2A1C);

const goldGradient = LinearGradient(
  colors: [goldLight, gold, goldDark, gold],
  stops: [0, 0.35, 0.75, 1],
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
);

const redGradient = LinearGradient(
  colors: [Color(0xFFD81F3A), Color(0xFF8E0F22)],
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
);

const buttonGoldGradient = LinearGradient(
  colors: [Color(0xFFF3D27A), Color(0xFFC9962F), Color(0xFF9C6F1E)],
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: gold,
    brightness: Brightness.dark,
    primary: gold,
    secondary: accent,
    surface: panel,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    fontFamily: 'Montserrat',
    scaffoldBackgroundColor: bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF0E0C0A),
      foregroundColor: Colors.white,
      centerTitle: true,
      elevation: 0,
      titleTextStyle: TextStyle(fontFamily: 'Montserrat', fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: panelLight,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      enabledBorder:
          OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: gold.withOpacity(0.25))),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: gold)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: gold,
        foregroundColor: Colors.black,
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontFamily: 'Montserrat', fontSize: 16, fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: gold.withOpacity(0.4)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: gold)),
    cardTheme: CardTheme(
      color: panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: gold.withOpacity(0.18))),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: gold.withOpacity(0.35))),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: panel),
    dividerTheme: DividerThemeData(color: gold.withOpacity(0.12)),
    sliderTheme: const SliderThemeData(activeTrackColor: gold, thumbColor: goldLight, inactiveTrackColor: Colors.white24),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? goldLight : Colors.white54),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? goldDark : Colors.white12),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? gold : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Colors.black),
      side: BorderSide(color: gold.withOpacity(0.6)),
    ),
    tabBarTheme: const TabBarTheme(
      labelColor: Colors.white,
      unselectedLabelColor: Colors.white54,
      indicatorColor: gold,
      labelStyle: TextStyle(fontFamily: 'Montserrat', fontWeight: FontWeight.w700),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0E0C0A),
      indicatorColor: gold.withOpacity(0.18),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(color: s.contains(WidgetState.selected) ? gold : Colors.white60),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontFamily: 'Montserrat',
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: s.contains(WidgetState.selected) ? gold : Colors.white60,
        ),
      ),
    ),
  );
}

/// Boja avatara iz imena (uvek ista za istog igrača).
Color avatarColor(String seed) {
  const colors = [
    Color(0xFF8E1426),
    Color(0xFF7A5A1E),
    Color(0xFF1F5E46),
    Color(0xFF3A3F7A),
    Color(0xFF6A2C70),
    Color(0xFF125E73),
    Color(0xFF8A3B12),
    Color(0xFF4A4A4A),
  ];
  var h = 0;
  for (final c in seed.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return colors[h % colors.length];
}
