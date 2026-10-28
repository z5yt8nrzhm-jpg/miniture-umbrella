/// Gilbert Flex Studio's look, from its flyers: warm cream paper, sage green,
/// terracotta and a touch of gold, in Cormorant (headings) and Montserrat.
library;

import 'package:flutter/material.dart';

class Brand {
  static const cream = Color(0xFFF4EFE6);
  static const paper = Color(0xFFFBF8F2);
  static const line = Color(0xFFE4DBCC);
  static const ink = Color(0xFF4E524D);       // text: 7.6:1 on cream
  static const inkSoft = Color(0xFF6E716B);   // secondary text: 4.6:1 on cream
  static const sage = Color(0xFFB9C4B2);
  static const sageMid = Color(0xFF8FA58A);
  static const sageDeep = Color(0xFF5C615B);  // buttons and headings
  static const clay = Color(0xFFE9C9AE);
  static const terracotta = Color(0xFFB0714F); // fills and decoration
  static const terracottaText = Color(0xFF8E5A3C); // small text: 5.2:1 on cream
  static const gold = Color(0xFFF6CF73);
  static const brown = Color(0xFF4A3428);
  static const danger = Color(0xFF9A3B2E);

  static const avatarColors = {
    'sage': Color(0xFFB9C4B2), 'clay': Color(0xFFE9C9AE), 'gold': Color(0xFFF6CF73),
    'sky': Color(0xFFA9C7D8), 'rose': Color(0xFFE3B8B0),
  };
}

const _display = 'Cormorant';
const _text = 'Montserrat';

TextStyle displayStyle(double size, {Color color = Brand.sageDeep, bool italic = true, double weight = 500}) => TextStyle(
      fontFamily: _display, fontSize: size, height: 1.1, color: color, fontStyle: italic ? FontStyle.italic : FontStyle.normal,
      fontVariations: [FontVariation('wght', weight)],
      // Cormorant's default numerals are old-style, where a 0 looks like the letter o.
      fontFeatures: const [FontFeature.liningFigures()],
    );

TextStyle bodyStyle({double size = 15, Color color = Brand.ink, double weight = 400, double height = 1.5}) => TextStyle(
      fontFamily: _text, fontSize: size, height: height, color: color, fontVariations: [FontVariation('wght', weight)],
    );

TextStyle labelStyle({Color color = Brand.terracottaText, double size = 11}) => TextStyle(
      fontFamily: _text, fontSize: size, letterSpacing: 2.2, height: 1.3, color: color, fontVariations: const [FontVariation('wght', 600)],
    );

ThemeData buildTheme() {
  final base = ThemeData(useMaterial3: true, brightness: Brightness.light, fontFamily: _text);
  return base.copyWith(
    scaffoldBackgroundColor: Brand.cream,
    colorScheme: ColorScheme.fromSeed(seedColor: Brand.sageDeep, brightness: Brightness.light).copyWith(
      primary: Brand.sageDeep, onPrimary: Brand.cream, secondary: Brand.terracottaText, surface: Brand.paper, onSurface: Brand.ink, error: Brand.danger,
    ),
    appBarTheme: const AppBarTheme(backgroundColor: Brand.cream, foregroundColor: Brand.sageDeep, elevation: 0, scrolledUnderElevation: 0),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Brand.paper,
      indicatorColor: Brand.sage,
      height: 68,
      labelTextStyle: WidgetStatePropertyAll(labelStyle(color: Brand.sageDeep, size: 10.5)),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? Brand.brown : Brand.inkSoft)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: Brand.paper,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      hintStyle: bodyStyle(color: Brand.inkSoft),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Brand.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Brand.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Brand.sageDeep, width: 2)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating, backgroundColor: Brand.sageDeep,
      contentTextStyle: bodyStyle(color: Brand.cream, size: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dividerTheme: const DividerThemeData(color: Brand.line, space: 1),
  );
}
