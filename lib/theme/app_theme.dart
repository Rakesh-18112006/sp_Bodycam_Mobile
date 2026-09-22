import 'package:flutter/material.dart';

/// Presentation-only design system for the Police Body Camera app.
///
/// This file defines shared colors, spacing, radii and text styles so every
/// screen looks consistent. It has ZERO knowledge of and ZERO effect on
/// recording/auth/upload/GPS/websocket logic -- it is purely a set of
/// values other widgets reference when building their UI.
class AppColors {
  AppColors._();

  // Brand
  static const Color primary = Color(0xFF0B1F3B); // deep navy
  static const Color primaryLight = Color(0xFF14335C);
  static const Color secondary = Color(0xFF1B5FBF); // professional blue

  // Neutral surfaces
  static const Color background = Color(0xFFF4F6F9);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE3E7EE);

  // Text
  static const Color textPrimary = Color(0xFF101828);
  static const Color textSecondary = Color(0xFF5B6472);
  static const Color textOnPrimary = Color(0xFFFFFFFF);

  // Semantic status colors
  static const Color success = Color(0xFF15803D);
  static const Color successBg = Color(0xFFE7F6EC);
  static const Color warning = Color(0xFFB45309);
  static const Color warningBg = Color(0xFFFDF1DF);
  static const Color danger = Color(0xFFC01C28);
  static const Color dangerBg = Color(0xFFFBEAEA);
  static const Color neutralBg = Color(0xFFEEF0F3);
  static const Color info = Color(0xFF1B5FBF);
  static const Color infoBg = Color(0xFFE8F0FC);

  // Emergency accent -- used ONLY for emergency/critical/destructive
  // states, never as the app's general background.
  static const Color emergency = Color(0xFFD92D20);
  static const Color emergencyBg = Color(0xFFFCEAE9);
}

class AppSpacing {
  AppSpacing._();
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppRadii {
  AppRadii._();
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
}

class AppTypography {
  AppTypography._();

  static const TextStyle screenTitle = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
    letterSpacing: -0.2,
  );

  static const TextStyle sectionTitle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: AppColors.textSecondary,
    letterSpacing: 0.8,
  );

  static const TextStyle cardTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    color: AppColors.textPrimary,
  );

  static const TextStyle body = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    color: AppColors.textPrimary,
  );

  static const TextStyle bodySecondary = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );

  static const TextStyle caption = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    color: AppColors.textSecondary,
  );

  static const TextStyle button = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
  );

  static const TextStyle metric = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w800,
    color: AppColors.textPrimary,
    letterSpacing: -0.5,
  );
}

/// Builds the app's Material 3 [ThemeData]. Swapping this in for the old
/// `ThemeData(colorSchemeSeed: Colors.red, useMaterial3: true)` in
/// main.dart changes only presentation (colors/typography/component
/// defaults) -- it does not touch navigation, state, or any service.
ThemeData buildAppTheme() {
  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    primary: AppColors.primary,
    secondary: AppColors.secondary,
    error: AppColors.danger,
    surface: AppColors.surface,
    brightness: Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: AppColors.background,
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.primary,
      foregroundColor: AppColors.textOnPrimary,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.textOnPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, space: 1),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.textOnPrimary,
        disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.4),
        minimumSize: const Size.fromHeight(50),
        textStyle: AppTypography.button,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.sm)),
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.primary,
        side: const BorderSide(color: AppColors.border),
        minimumSize: const Size.fromHeight(44),
        textStyle: AppTypography.button,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.sm)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.background,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        borderSide: const BorderSide(color: AppColors.secondary, width: 1.5),
      ),
      labelStyle: const TextStyle(color: AppColors.textSecondary),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: AppColors.primary,
        selectedForegroundColor: AppColors.textOnPrimary,
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    textTheme: const TextTheme(
      titleLarge: AppTypography.screenTitle,
      titleMedium: AppTypography.cardTitle,
      bodyMedium: AppTypography.body,
      bodySmall: AppTypography.bodySecondary,
      labelSmall: AppTypography.caption,
    ),
  );
}
