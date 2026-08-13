import 'package:flutter/material.dart';

/// Structura's look — a calm, technical dark theme. Instrument-grade, not flashy:
/// the scan is the hero, the chrome stays out of the way.
const _bg = Color(0xFF0B0D12);
const _surface = Color(0xFF14171F);
const _accent = Color(0xFF4CC2FF); // depth-sensor cyan
const _accentWarm = Color(0xFFFFB454);

final ThemeData structuraTheme = ThemeData(
  useMaterial3: true,
  brightness: Brightness.dark,
  scaffoldBackgroundColor: _bg,
  colorScheme: const ColorScheme.dark(
    primary: _accent,
    secondary: _accentWarm,
    surface: _surface,
    onSurface: Color(0xFFE6E9EF),
  ),
  fontFamily: 'SF Pro Text',
  appBarTheme: const AppBarTheme(
    backgroundColor: _bg,
    elevation: 0,
    centerTitle: false,
    titleTextStyle: TextStyle(
      color: Color(0xFFE6E9EF),
      fontSize: 20,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: _accent,
      foregroundColor: Colors.black,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 15),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
  ),
  cardTheme: CardTheme(
    color: _surface,
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
  ),
);

/// Shared spacing scale.
class Insets {
  static const double xs = 6;
  static const double s = 12;
  static const double m = 18;
  static const double l = 28;
}
