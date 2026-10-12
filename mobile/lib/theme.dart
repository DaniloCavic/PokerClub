import 'package:flutter/material.dart';

const felt = Color(0xFF0F6B3E);
const feltDark = Color(0xFF0B3D26);
const gold = Color(0xFFD4A62A);
const tableRail = Color(0xFF3B2414);
const bg = Color(0xFF0E1A14);

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: felt,
    brightness: Brightness.dark,
    primary: const Color(0xFF34B36F),
    secondary: gold,
    surface: const Color(0xFF15261D),
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: bg,
    appBarTheme: const AppBarTheme(backgroundColor: feltDark, foregroundColor: Colors.white, centerTitle: true),
    inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), textStyle: const TextStyle(fontSize: 16)),
    ),
    cardTheme: const CardTheme(color: Color(0xFF15261D)),
  );
}
