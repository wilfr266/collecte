import 'package:flutter/material.dart';

abstract final class AppTheme {
  static const _green = Color(0xFF71C48F);
  static const _violet = Color(0xFF9B83D5);
  static const _darkBackground = Color(0xFF101512);
  static const _darkSurface = Color(0xFF1B231E);

  static final light = _buildTheme(Brightness.light);
  static final dark = _buildTheme(Brightness.dark);

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme =
        ColorScheme.fromSeed(
          seedColor: _green,
          brightness: brightness,
        ).copyWith(
          primary: isDark ? _green : const Color(0xFF276B43),
          secondary: _violet,
          surface: isDark ? _darkSurface : const Color(0xFFF6F8F5),
        );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: isDark ? _darkBackground : Colors.white,
      cardTheme: CardThemeData(
        color: isDark ? _darkSurface : const Color(0xFFF6F8F5),
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
