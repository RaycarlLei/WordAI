// ignore_for_file: overridden_fields, annotate_overrides

import 'package:flutter/material.dart';

import 'package:shared_preferences/shared_preferences.dart';

const kThemeModeKey = '__theme_mode__';
SharedPreferences? _prefs;

abstract class FlutterFlowTheme {
  static Future initialize() async =>
      _prefs = await SharedPreferences.getInstance();
  static ThemeMode get themeMode {
    final darkMode = _prefs?.getBool(kThemeModeKey);
    return darkMode == null
        ? ThemeMode.system
        : darkMode
            ? ThemeMode.dark
            : ThemeMode.light;
  }

  static void saveThemeMode(ThemeMode mode) => mode == ThemeMode.system
      ? _prefs?.remove(kThemeModeKey)
      : _prefs?.setBool(kThemeModeKey, mode == ThemeMode.dark);

  static FlutterFlowTheme of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? DarkModeTheme()
        : LightModeTheme();
  }

  @Deprecated('Use primary instead')
  Color get primaryColor => primary;
  @Deprecated('Use secondary instead')
  Color get secondaryColor => secondary;
  @Deprecated('Use tertiary instead')
  Color get tertiaryColor => tertiary;

  late Color primary;
  late Color secondary;
  late Color tertiary;
  late Color alternate;
  late Color primaryText;
  late Color secondaryText;
  late Color primaryBackground;
  late Color secondaryBackground;
  late Color accent1;
  late Color accent2;
  late Color accent3;
  late Color accent4;
  late Color success;
  late Color warning;
  late Color error;
  late Color info;

  late Color primaryBtnText;
  late Color lineColor;
  late Color backgroundComponents;

  @Deprecated('Use displaySmallFamily instead')
  String get title1Family => displaySmallFamily;
  @Deprecated('Use displaySmall instead')
  TextStyle get title1 => typography.displaySmall;
  @Deprecated('Use headlineMediumFamily instead')
  String get title2Family => typography.headlineMediumFamily;
  @Deprecated('Use headlineMedium instead')
  TextStyle get title2 => typography.headlineMedium;
  @Deprecated('Use headlineSmallFamily instead')
  String get title3Family => typography.headlineSmallFamily;
  @Deprecated('Use headlineSmall instead')
  TextStyle get title3 => typography.headlineSmall;
  @Deprecated('Use titleMediumFamily instead')
  String get subtitle1Family => typography.titleMediumFamily;
  @Deprecated('Use titleMedium instead')
  TextStyle get subtitle1 => typography.titleMedium;
  @Deprecated('Use titleSmallFamily instead')
  String get subtitle2Family => typography.titleSmallFamily;
  @Deprecated('Use titleSmall instead')
  TextStyle get subtitle2 => typography.titleSmall;
  @Deprecated('Use bodyMediumFamily instead')
  String get bodyText1Family => typography.bodyMediumFamily;
  @Deprecated('Use bodyMedium instead')
  TextStyle get bodyText1 => typography.bodyMedium;
  @Deprecated('Use bodySmallFamily instead')
  String get bodyText2Family => typography.bodySmallFamily;
  @Deprecated('Use bodySmall instead')
  TextStyle get bodyText2 => typography.bodySmall;

  String get displayLargeFamily => typography.displayLargeFamily;
  TextStyle get displayLarge => typography.displayLarge;
  String get displayMediumFamily => typography.displayMediumFamily;
  TextStyle get displayMedium => typography.displayMedium;
  String get displaySmallFamily => typography.displaySmallFamily;
  TextStyle get displaySmall => typography.displaySmall;
  String get headlineLargeFamily => typography.headlineLargeFamily;
  TextStyle get headlineLarge => typography.headlineLarge;
  String get headlineMediumFamily => typography.headlineMediumFamily;
  TextStyle get headlineMedium => typography.headlineMedium;
  String get headlineSmallFamily => typography.headlineSmallFamily;
  TextStyle get headlineSmall => typography.headlineSmall;
  String get titleLargeFamily => typography.titleLargeFamily;
  TextStyle get titleLarge => typography.titleLarge;
  String get titleMediumFamily => typography.titleMediumFamily;
  TextStyle get titleMedium => typography.titleMedium;
  String get titleSmallFamily => typography.titleSmallFamily;
  TextStyle get titleSmall => typography.titleSmall;
  String get labelLargeFamily => typography.labelLargeFamily;
  TextStyle get labelLarge => typography.labelLarge;
  String get labelMediumFamily => typography.labelMediumFamily;
  TextStyle get labelMedium => typography.labelMedium;
  String get labelSmallFamily => typography.labelSmallFamily;
  TextStyle get labelSmall => typography.labelSmall;
  String get bodyLargeFamily => typography.bodyLargeFamily;
  TextStyle get bodyLarge => typography.bodyLarge;
  String get bodyMediumFamily => typography.bodyMediumFamily;
  TextStyle get bodyMedium => typography.bodyMedium;
  String get bodySmallFamily => typography.bodySmallFamily;
  TextStyle get bodySmall => typography.bodySmall;

  Typography get typography => ThemeTypography(this);
}

class LightModeTheme extends FlutterFlowTheme {
  @Deprecated('Use primary instead')
  Color get primaryColor => primary;
  @Deprecated('Use secondary instead')
  Color get secondaryColor => secondary;
  @Deprecated('Use tertiary instead')
  Color get tertiaryColor => tertiary;

  // iOS 26 Style - Light Mode: Modern dark blue, gray, and white palette
  late Color primary = const Color(0xFF0051D5); // Deep dark blue - iOS primary
  late Color secondary = const Color(0xFF007AFF); // Bright blue accent
  late Color tertiary = const Color(0xFF5856D6); // Purple accent for variety
  late Color alternate = const Color(0xFFE5E5EA); // Light gray separator
  late Color primaryText =
      const Color(0xFF000000); // Pure black for maximum contrast
  late Color secondaryText =
      const Color(0xFF6E6E73); // Medium gray for secondary text
  late Color primaryBackground =
      const Color(0xFFF2F2F7); // iOS light gray background
  late Color secondaryBackground =
      const Color(0xFFFFFFFF); // Pure white cards/surfaces
  late Color accent1 = const Color(0x1A0051D5); // Light blue tint (10% opacity)
  late Color accent2 =
      const Color(0x330051D5); // Medium blue tint (20% opacity)
  late Color accent3 =
      const Color(0x4D0051D5); // Stronger blue tint (30% opacity)
  late Color accent4 =
      const Color(0xFFF9F9F9); // Very light gray for subtle backgrounds
  late Color success = const Color(0xFF34C759); // iOS green
  late Color warning = const Color(0xFFFF9500); // iOS orange
  late Color error = const Color(0xFFFF3B30); // iOS red
  late Color info = const Color(0xFF007AFF); // iOS blue for info

  late Color primaryBtnText =
      const Color(0xFFFFFFFF); // White text on blue buttons
  late Color lineColor = const Color(0xFFE5E5EA); // iOS separator gray
  late Color backgroundComponents =
      const Color(0xFFFFFFFF); // White component backgrounds
}

abstract class Typography {
  String get displayLargeFamily;
  TextStyle get displayLarge;
  String get displayMediumFamily;
  TextStyle get displayMedium;
  String get displaySmallFamily;
  TextStyle get displaySmall;
  String get headlineLargeFamily;
  TextStyle get headlineLarge;
  String get headlineMediumFamily;
  TextStyle get headlineMedium;
  String get headlineSmallFamily;
  TextStyle get headlineSmall;
  String get titleLargeFamily;
  TextStyle get titleLarge;
  String get titleMediumFamily;
  TextStyle get titleMedium;
  String get titleSmallFamily;
  TextStyle get titleSmall;
  String get labelLargeFamily;
  TextStyle get labelLarge;
  String get labelMediumFamily;
  TextStyle get labelMedium;
  String get labelSmallFamily;
  TextStyle get labelSmall;
  String get bodyLargeFamily;
  TextStyle get bodyLarge;
  String get bodyMediumFamily;
  TextStyle get bodyMedium;
  String get bodySmallFamily;
  TextStyle get bodySmall;
}

class ThemeTypography extends Typography {
  ThemeTypography(this.theme);

  final FlutterFlowTheme theme;

  String get displayLargeFamily => 'System';
  TextStyle get displayLarge => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Display)
        color: theme.primaryText,
        fontWeight: FontWeight.normal,
        fontSize: 57.0,
      );
  String get displayMediumFamily => 'System';
  TextStyle get displayMedium => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Display)
        color: theme.primaryText,
        fontWeight: FontWeight.normal,
        fontSize: 45.0,
      );
  String get displaySmallFamily => 'System';
  TextStyle get displaySmall => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Display)
        color: theme.primaryText,
        fontWeight: FontWeight.w600,
        fontSize: 36.0,
      );
  String get headlineLargeFamily => 'System';
  TextStyle get headlineLarge => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Display)
        color: theme.primaryText,
        fontWeight: FontWeight.normal,
        fontSize: 32.0,
      );
  String get headlineMediumFamily => 'System';
  TextStyle get headlineMedium => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Display)
        color: theme.primaryText,
        fontWeight: FontWeight.w600,
        fontSize: 32.0,
      );
  String get headlineSmallFamily => 'System';
  TextStyle get headlineSmall => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Display)
        color: theme.primaryText,
        fontWeight: FontWeight.bold,
        fontSize: 24.0,
      );
  String get titleLargeFamily => 'System';
  TextStyle get titleLarge => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Display)
        color: theme.primaryText,
        fontWeight: FontWeight.w500,
        fontSize: 22.0,
      );
  String get titleMediumFamily => 'System';
  TextStyle get titleMedium => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Text)
        color: theme.info,
        fontWeight: FontWeight.w500,
        fontSize: 16.0,
      );
  String get titleSmallFamily => 'System';
  TextStyle get titleSmall => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Text)
        color: theme.info,
        fontWeight: FontWeight.w500,
        fontSize: 14.0,
      );
  String get labelLargeFamily => 'System';
  TextStyle get labelLarge => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Text)
        color: theme.secondaryText,
        fontWeight: FontWeight.w500,
        fontSize: 16.0,
      );
  String get labelMediumFamily => 'System';
  TextStyle get labelMedium => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Text)
        color: theme.secondaryText,
        fontWeight: FontWeight.w500,
        fontSize: 14.0,
      );
  String get labelSmallFamily => 'System';
  TextStyle get labelSmall => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Text)
        color: theme.secondaryText,
        fontWeight: FontWeight.w500,
        fontSize: 12.0,
      );
  String get bodyLargeFamily => 'System';
  TextStyle get bodyLarge => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Text)
        color: theme.primaryText,
        fontWeight: FontWeight.w500,
        fontSize: 16.0,
      );
  String get bodyMediumFamily => 'System';
  TextStyle get bodyMedium => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Text)
        color: theme.primaryText,
        fontWeight: FontWeight.w500,
        fontSize: 14.0,
      );
  String get bodySmallFamily => 'System';
  TextStyle get bodySmall => TextStyle(
        fontFamily: null, // Uses iOS system font (SF Pro Text)
        color: theme.primaryText,
        fontWeight: FontWeight.w500,
        fontSize: 12.0,
      );
}

class DarkModeTheme extends FlutterFlowTheme {
  @Deprecated('Use primary instead')
  Color get primaryColor => primary;
  @Deprecated('Use secondary instead')
  Color get secondaryColor => secondary;
  @Deprecated('Use tertiary instead')
  Color get tertiaryColor => tertiary;

  // iOS 26 Style - Dark Mode: Modern dark blue, gray, and white palette
  late Color primary = const Color(0xFF4A9EFF); // Bright blue for dark mode
  late Color secondary = const Color(0xFF5AC8FA); // Lighter blue accent
  late Color tertiary = const Color(0xFFAF52DE); // Purple accent for variety
  late Color alternate = const Color(0xFF38383A); // Dark gray separator
  late Color primaryText =
      const Color(0xFFFFFFFF); // Pure white for maximum contrast
  late Color secondaryText =
      const Color(0xFF98989D); // Light gray for secondary text
  late Color primaryBackground =
      const Color(0xFF000000); // Pure black iOS background
  late Color secondaryBackground =
      const Color(0xFF1C1C1E); // Dark gray cards/surfaces
  late Color accent1 = const Color(0x1A4A9EFF); // Light blue tint (10% opacity)
  late Color accent2 =
      const Color(0x334A9EFF); // Medium blue tint (20% opacity)
  late Color accent3 =
      const Color(0x4D4A9EFF); // Stronger blue tint (30% opacity)
  late Color accent4 =
      const Color(0xFF2C2C2E); // Dark gray for subtle backgrounds
  late Color success =
      const Color(0xFF30D158); // iOS green (brighter for dark mode)
  late Color warning =
      const Color(0xFFFF9F0A); // iOS orange (brighter for dark mode)
  late Color error =
      const Color(0xFFFF453A); // iOS red (brighter for dark mode)
  late Color info = const Color(0xFF5AC8FA); // iOS blue for info

  late Color primaryBtnText =
      const Color(0xFFFFFFFF); // White text on blue buttons
  late Color lineColor = const Color(0xFF38383A); // iOS dark separator gray
  late Color backgroundComponents =
      const Color(0xFF1C1C1E); // Dark gray component backgrounds
}

extension TextStyleHelper on TextStyle {
  TextStyle override({
    String? fontFamily,
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    double? letterSpacing,
    FontStyle? fontStyle,
    bool useGoogleFonts = false, // Changed to false - using iOS system fonts
    TextDecoration? decoration,
    double? lineHeight,
  }) =>
      copyWith(
        fontFamily: fontFamily, // Use null to get iOS system font
        color: color,
        fontSize: fontSize,
        letterSpacing: letterSpacing,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        decoration: decoration,
        height: lineHeight,
      );
}
