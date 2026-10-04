/// The app's visual language: light, card-based, generous whitespace.
///
/// Derived from the WorkBuddy mobile app the user asked to match:
///
///   * a near-white page carrying pure-white cards, separated by whitespace
///     rather than borders — almost no shadows and no hard outlines;
///   * exactly one accent colour (green), used for state and links, never for
///     large fills;
///   * one black circular primary action (send), which is the strongest element
///     on any screen;
///   * large corner radii and pill-shaped controls.
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  /// Page background. Cards sit on this, so it must be clearly lighter than the
  /// muted surface used inside cards.
  static const page = Color(0xFFF2F2F5);
  static const surface = Color(0xFFFFFFFF);

  /// Fills that must read as a fill on the page: user bubbles, chips, inline
  /// code. Kept a clear step darker than [page] — at only two levels apart the
  /// bubbles were invisible.
  static const surfaceMuted = Color(0xFFEBEBEF);
  static const surfaceMutedStrong = Color(0xFFE0E0E6);

  /// The process timeline's vertical rail. Needs its own value: [divider] on
  /// [page] is all but invisible.
  static const rail = Color(0xFFDCDCE3);

  static const textPrimary = Color(0xFF17171A);
  static const textSecondary = Color(0xFF8A8A8F);
  static const textTertiary = Color(0xFFB3B3B9);

  static const accent = Color(0xFF00C16A);
  static const accentText = Color(0xFF00A15A);
  static const accentSoft = Color(0xFFE6F8EF);

  static const danger = Color(0xFFE5544B);
  static const dangerSoft = Color(0xFFFDECEA);

  static const divider = Color(0xFFEDEDF0);
  static const primaryAction = Color(0xFF17171A);

  /// The online indicator, and the "已完成" tick colour.
  static const online = Color(0xFF00C16A);
  static const offline = Color(0xFFC4C4CA);
}

abstract final class AppRadius {
  static const card = 22.0;
  static const bubble = 22.0;
  static const field = 18.0;
  static const sheet = 28.0;
  static const timeline = 14.0;

  /// Pills and chips.
  static const full = 999.0;
}

abstract final class AppGap {
  static const page = 16.0;
  static const tight = 6.0;
  static const base = 12.0;
  static const loose = 20.0;
}

/// White card on the light page. No shadow: the reference separates surfaces by
/// colour alone, and shadows on a near-white background read as dirt.
BoxDecoration cardDecoration({
  double radius = AppRadius.card,
  Color color = AppColors.surface,
}) {
  return BoxDecoration(
    color: color,
    borderRadius: BorderRadius.circular(radius),
  );
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.accent,
    brightness: Brightness.light,
  ).copyWith(
    surface: AppColors.page,
    primary: AppColors.accent,
    onPrimary: Colors.white,
    error: AppColors.danger,
    onError: Colors.white,
  );

  const appBarTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: AppColors.textPrimary,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.page,
    dividerColor: AppColors.divider,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      foregroundColor: AppColors.textPrimary,
      titleTextStyle: appBarTitle,
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight: Radius.circular(AppRadius.sheet),
          bottomRight: Radius.circular(AppRadius.sheet),
        ),
      ),
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.divider,
      thickness: 1,
      space: 1,
    ),
    textTheme: const TextTheme(
      // The welcome headline.
      headlineMedium: TextStyle(
        fontSize: 30,
        fontWeight: FontWeight.w800,
        height: 1.3,
        color: AppColors.textPrimary,
      ),
      titleMedium: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      titleSmall: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      bodyMedium: TextStyle(fontSize: 15, height: 1.45, color: AppColors.textPrimary),
      bodySmall: TextStyle(fontSize: 13, height: 1.4, color: AppColors.textSecondary),
      labelSmall: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: AppColors.textPrimary,
      textColor: AppColors.textPrimary,
      contentPadding: EdgeInsets.symmetric(horizontal: AppGap.page),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceMuted,
      hintStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 15),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.field),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
      ),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: AppColors.surface,
      side: BorderSide.none,
      labelStyle: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
      shape: StadiumBorder(),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.primaryAction,
      contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primaryAction,
        foregroundColor: Colors.white,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.textPrimary,
        side: const BorderSide(color: AppColors.divider),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.accentText,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: AppColors.accent),
  );
}
