import 'package:flutter/material.dart';

/// Nanote brand seed — the launcher blue (see assets/icon + flutter_launcher_icons).
const kBrandBlue = Color(0xFF155EEF);

/// Material 3 themes for Nanote.
///
/// Both brightnesses are derived from the brand seed so the app instantly
/// reads as one product across the library and the editor. Paper shades on
/// the canvas are deliberately INDEPENDENT of this theme (a dark-ink user
/// may still want light paper) — see PaperShade.
ThemeData nanoteTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: kBrandBlue,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: brightness == Brightness.light
        ? const Color(0xFFF6F7FA)
        : const Color(0xFF0E1116),
    appBarTheme: AppBarTheme(
      backgroundColor: brightness == Brightness.light
          ? const Color(0xFFF6F7FA)
          : const Color(0xFF0E1116),
      foregroundColor: scheme.onSurface,
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 1,
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
    // `DialogTheme` (not DialogThemeData): works on every Flutter from the
    // project floor (3.22) to current stable, where it is merely deprecated.
    dialogTheme: DialogTheme(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      showDragHandle: true,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 4,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        side: WidgetStatePropertyAll(
          BorderSide(color: scheme.outlineVariant),
        ),
      ),
    ),
    tooltipTheme: const TooltipThemeData(preferBelow: false),
    visualDensity: VisualDensity.adaptivePlatformDensity,
  );
}
