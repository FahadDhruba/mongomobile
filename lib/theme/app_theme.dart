import 'package:flutter/material.dart';

/// Fonts bundled with the app.
const String uiFont = 'Inter';
const String monoFont = 'JetBrainsMono';

/// Colours used across the app, beyond what [ColorScheme] covers.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.background,
    required this.panel,
    required this.card,
    required this.border,
    required this.text,
    required this.muted,
    required this.accent,
    required this.accentStrong,
    required this.onAccent,
    required this.warning,
    required this.danger,
    required this.key,
    required this.string,
    required this.number,
    required this.boolean,
    required this.date,
    required this.objectId,
    required this.nullValue,
    required this.other,
  });

  final Color background;
  final Color panel;
  final Color card;
  final Color border;
  final Color text;
  final Color muted;

  /// Bright green for highlights and the primary buttons.
  final Color accent;

  /// Deep green for filled surfaces and text on light backgrounds.
  final Color accentStrong;
  final Color onAccent;
  final Color warning;
  final Color danger;

  // Document value colours, one per BSON type family.
  final Color key;
  final Color string;
  final Color number;
  final Color boolean;
  final Color date;
  final Color objectId;
  final Color nullValue;
  final Color other;

  static const dark = AppColors(
    background: Color(0xFF001E2B),
    panel: Color(0xFF00141D),
    card: Color(0xFF0B2B39),
    border: Color(0xFF1C3D4B),
    text: Color(0xFFE8EDEB),
    muted: Color(0xFF8A9BA3),
    accent: Color(0xFF00ED64),
    accentStrong: Color(0xFF00684A),
    onAccent: Color(0xFF001E2B),
    warning: Color(0xFFFFC010),
    danger: Color(0xFFFF6F5C),
    key: Color(0xFFD9E2E6),
    string: Color(0xFFA6E37C),
    number: Color(0xFF6CB8FF),
    boolean: Color(0xFFF48FB1),
    date: Color(0xFFCBA6F7),
    objectId: Color(0xFFF9C46B),
    nullValue: Color(0xFF8C9BA5),
    other: Color(0xFF7FDBD0),
  );

  static const light = AppColors(
    background: Color(0xFFF5F7F6),
    panel: Color(0xFFFFFFFF),
    card: Color(0xFFFFFFFF),
    border: Color(0xFFDDE3E1),
    text: Color(0xFF001E2B),
    muted: Color(0xFF5C6C75),
    accent: Color(0xFF00A35C),
    accentStrong: Color(0xFF00684A),
    onAccent: Color(0xFFFFFFFF),
    warning: Color(0xFF946F00),
    danger: Color(0xFFD03A2B),
    key: Color(0xFF1C2D38),
    string: Color(0xFF1A7F37),
    number: Color(0xFF0B5CAD),
    boolean: Color(0xFFB5338A),
    date: Color(0xFF6C3FC4),
    objectId: Color(0xFF9A5B00),
    nullValue: Color(0xFF6B7780),
    other: Color(0xFF00797A),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(covariant AppColors? other, double t) =>
      t < 0.5 ? this : (other ?? this);
}

extension AppThemeContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}

/// Monospace style for data, queries and documents.
TextStyle monoStyle(BuildContext context,
    {double size = 13, Color? color, FontWeight? weight}) {
  return TextStyle(
    fontFamily: monoFont,
    fontSize: size,
    height: 1.45,
    color: color ?? context.colors.text,
    fontWeight: weight,
  );
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: brightness == Brightness.dark ? c.accent : c.accentStrong,
    onPrimary: c.onAccent,
    secondary: c.accentStrong,
    onSecondary: Colors.white,
    error: c.danger,
    onError: Colors.white,
    surface: c.panel,
    onSurface: c.text,
    surfaceContainerHighest: c.card,
    surfaceContainerHigh: c.card,
    surfaceContainer: c.panel,
    surfaceContainerLow: c.background,
    outline: c.border,
    outlineVariant: c.border,
  );
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: uiFont,
    scaffoldBackgroundColor: c.background,
    extensions: [c],
  );
  final buttonShape =
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: c.panel,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(
          fontFamily: uiFont,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: c.text),
      shape: Border(bottom: BorderSide(color: c.border)),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: c.panel,
      shape: const RoundedRectangleBorder(),
    ),
    cardTheme: CardThemeData(
      color: c.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.border),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.border, space: 1, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: c.background,
      hintStyle: TextStyle(color: c.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.border)),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.border)),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.accent, width: 1.5)),
      errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.danger)),
      focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: c.danger, width: 1.5)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accentStrong,
        foregroundColor: Colors.white,
        disabledBackgroundColor: c.border,
        shape: buttonShape,
        textStyle: const TextStyle(
            fontFamily: uiFont, fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        side: BorderSide(color: c.border),
        shape: buttonShape,
        textStyle: const TextStyle(
            fontFamily: uiFont, fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: brightness == Brightness.dark ? c.accent : c.accentStrong,
        shape: buttonShape,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      elevation: 2,
      highlightElevation: 4,
      backgroundColor: c.accentStrong,
      foregroundColor: Colors.white,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: brightness == Brightness.dark
          ? const Color(0xFF1C3D4B)
          : const Color(0xFF001E2B),
      contentTextStyle:
          const TextStyle(fontFamily: uiFont, color: Colors.white),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.text,
      unselectedLabelColor: c.muted,
      indicatorColor: c.accent,
      dividerColor: c.border,
      labelStyle: const TextStyle(
          fontFamily: uiFont, fontWeight: FontWeight.w600, fontSize: 14),
    ),
    listTileTheme: ListTileThemeData(iconColor: c.muted),
    dialogTheme: DialogThemeData(backgroundColor: c.panel),
    bottomSheetTheme: BottomSheetThemeData(backgroundColor: c.panel),
    popupMenuTheme: PopupMenuThemeData(color: c.panel),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? Colors.white : null),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? c.accentStrong : null),
    ),
  );
}

/// The green call-to-action button used for Find, Insert and Save.
class AccentButton extends StatelessWidget {
  const AccentButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.compact = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = FilledButton.styleFrom(
      backgroundColor: c.accent,
      foregroundColor: c.onAccent,
      disabledBackgroundColor: c.border,
      disabledForegroundColor: c.muted,
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 8)
          : const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      minimumSize: compact ? const Size(0, 36) : const Size(0, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      textStyle: const TextStyle(
          fontFamily: uiFont, fontWeight: FontWeight.w700, fontSize: 14),
    );
    if (icon == null) {
      return FilledButton(onPressed: onPressed, style: style, child: Text(label));
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

/// Colours a saved connection can be tagged with.
const List<Color> connectionColors = [
  Color(0xFF00ED64),
  Color(0xFF0498EC),
  Color(0xFFFFC010),
  Color(0xFFDB3030),
  Color(0xFFB45AF2),
  Color(0xFFFF6F44),
  Color(0xFF8A9BA3),
];
