import 'package:flutter/material.dart';

abstract final class Palette {
  static const bg = Color(0xFF0B0C0F);
  static const surface = Color(0xFF15171C);
  static const surfaceHigh = Color(0xFF1F222A);
  static const outline = Color(0xFF2C303A);
  static const text = Color(0xFFF3F1EC);
  static const muted = Color(0xFF9DA1AC);
  static const accent = Color(0xFFFF6A3D);
  static const onAccent = Color(0xFF1A0B05);
  static const plex = Color(0xFFE5A00D);
  static const jellyfin = Color(0xFFA95CE0);
}

ThemeData buildTheme({required bool trueBlack}) {
  final bg = trueBlack ? Colors.black : Palette.bg;
  final scheme = const ColorScheme.dark().copyWith(
    primary: Palette.accent,
    onPrimary: Palette.onAccent,
    secondary: Palette.accent,
    onSecondary: Palette.onAccent,
    surface: bg,
    onSurface: Palette.text,
    onSurfaceVariant: Palette.muted,
    surfaceContainerLowest: bg,
    surfaceContainerLow: Palette.surface,
    surfaceContainer: Palette.surface,
    surfaceContainerHigh: Palette.surfaceHigh,
    surfaceContainerHighest: Palette.surfaceHigh,
    outline: Palette.outline,
    outlineVariant: Palette.outline,
    error: const Color(0xFFFF6B6B),
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    splashFactory: InkSparkle.splashFactory,
    visualDensity: VisualDensity.standard,
  );
  final t = base.textTheme.apply(
    bodyColor: Palette.text,
    displayColor: Palette.text,
  );
  return base.copyWith(
    textTheme: t.copyWith(
      displaySmall: t.displaySmall
          ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.8),
      headlineMedium: t.headlineMedium
          ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall: t.headlineSmall
          ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleLarge: t.titleLarge
          ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyMedium: t.bodyMedium?.copyWith(height: 1.45),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Palette.accent.withValues(alpha: 0.18),
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(
          t.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 46),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: t.labelLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
      ).copyWith(
        // A white ring keeps the focused button obvious from the sofa.
        side: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused)
                ? const BorderSide(color: Colors.white, width: 2.5)
                : null),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 46),
        foregroundColor: Palette.text,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ).copyWith(
        side: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused)
                ? const BorderSide(color: Colors.white, width: 2.5)
                : const BorderSide(color: Palette.outline)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        side: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.focused)
                ? const BorderSide(color: Colors.white, width: 2)
                : null),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: Palette.surface,
      selectedColor: Palette.text,
      side: const BorderSide(color: Palette.outline),
      shape: const StadiumBorder(),
      showCheckmark: false,
      // Selected chips invert to dark-on-light.
      labelStyle: t.labelLarge?.copyWith(
        fontWeight: FontWeight.w600,
        fontSize: 13,
        color: WidgetStateColor.resolveWith((s) =>
            s.contains(WidgetState.selected) ? Palette.bg : Palette.text),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Palette.surface,
      hintStyle: const TextStyle(color: Palette.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Palette.accent, width: 2),
      ),
    ),
    listTileTheme: const ListTileThemeData(iconColor: Palette.muted),
    dividerTheme: const DividerThemeData(color: Palette.outline, space: 1),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: Palette.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Palette.surfaceHigh,
      contentTextStyle: TextStyle(color: Palette.text),
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: Palette.accent),
  );
}

/// Sizes that change with the device class. Resolved once per build from the
/// window width and the TV flag.
@immutable
class AppLayout extends InheritedWidget {
  const AppLayout({
    super.key,
    required this.width,
    required this.tv,
    required super.child,
  });

  final double width;
  final bool tv;

  bool get phone => !tv && width < 600;
  bool get tablet => !tv && width >= 600 && width < 1100;
  bool get desktop => !tv && width >= 1100;

  /// Side navigation instead of a bottom bar.
  bool get sideNav => !phone;

  double get gutter => tv ? 48 : (phone ? 16 : (tablet ? 24 : 36));
  double get posterWidth => tv ? 176 : (phone ? 116 : (tablet ? 140 : 156));
  double get landscapeWidth => tv ? 340 : (phone ? 248 : (tablet ? 280 : 304));
  double get squareWidth => tv ? 190 : (phone ? 132 : 156);
  double get shelfGap => tv ? 20 : (phone ? 10 : 14);

  static AppLayout of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppLayout>()!;

  @override
  bool updateShouldNotify(AppLayout old) =>
      old.width != width || old.tv != tv;
}
