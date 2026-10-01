import 'package:flutter/material.dart';

/// Shared visual language for the whole app.
class AppTheme {
  AppTheme._();

  // Palette
  static const Color background = Color(0xFF0B0F14);
  static const Color surface = Color(0xFF121820);
  static const Color surfaceHigh = Color(0xFF1A2230);
  static const Color outline = Color(0xFF263140);

  static const Color primary = Color(0xFF3DFFA8); // signal green
  static const Color primaryDim = Color(0xFF1E8A5F);
  static const Color secondary = Color(0xFF4DB5FF); // join blue
  static const Color danger = Color(0xFFFF5A6E);
  static const Color warning = Color(0xFFFFB35C);
  static const Color call = Color(0xFFB57BFF); // private call purple
  static const Color textPrimary = Color(0xFFF2F6FA);
  static const Color textSecondary = Color(0xFF8A97A8);

  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);
    const scheme = ColorScheme.dark(
      primary: primary,
      onPrimary: Colors.black,
      secondary: secondary,
      onSecondary: Colors.black,
      error: danger,
      surface: surface,
      onSurface: textPrimary,
    );
    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: scheme,
      primaryColor: primary,
      splashFactory: InkRipple.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: textPrimary,
        elevation: 0,
        centerTitle: false,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceHigh,
        hintStyle: const TextStyle(color: textSecondary),
        labelStyle: const TextStyle(color: textSecondary),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: danger),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          side: const BorderSide(color: outline),
          foregroundColor: textPrimary,
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: surfaceHigh,
        side: const BorderSide(color: outline),
        labelStyle: const TextStyle(color: textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: surfaceHigh,
        contentTextStyle: TextStyle(color: textPrimary),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      dividerTheme: const DividerThemeData(color: outline, thickness: 1),
      listTileTheme: const ListTileThemeData(iconColor: textSecondary),
    );
  }
}
