import 'package:flutter/material.dart';

/// 配色：接近纯黑但偏暖的中性灰，唯一的高饱和色是「待机灯」琥珀，
/// 只用在播放态、进度和主按钮上；其余靠层级和留白拉开距离。
abstract final class C {
  static const bg = Color(0xFF0B0C0E);
  static const panel = Color(0xFF121418);
  static const panelAlt = Color(0xFF171A1F);
  static const line = Color(0xFF23262C);
  static const lineStrong = Color(0xFF31353D);

  static const text = Color(0xFFE9EBEF);
  static const textDim = Color(0xFF9AA1AC);
  static const textFaint = Color(0xFF69707B);

  static const amber = Color(0xFFEBB15D);
  static const amberInk = Color(0xFF201605);
  static const amberSoft = Color(0x1FEBB15D);

  static const red = Color(0xFFF0655E);
  static const green = Color(0xFF5FC08A);
  static const blue = Color(0xFF6FA8FF);
  static const violet = Color(0xFFB08CFF);
}

abstract final class T {
  static const display = TextStyle(
    fontSize: 30,
    fontWeight: FontWeight.w600,
    height: 1.18,
    letterSpacing: -0.4,
    color: C.text,
  );
  static const title = TextStyle(
    fontSize: 16.5,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    color: C.text,
  );
  static const body = TextStyle(fontSize: 13, height: 1.45, color: C.text);
  static const bodyDim = TextStyle(fontSize: 12.5, height: 1.45, color: C.textDim);
  static const meta = TextStyle(fontSize: 11.5, height: 1.35, color: C.textDim);
  static const section = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 1.1,
    color: C.textFaint,
  );
  static const button = TextStyle(
    fontSize: 12.5,
    fontWeight: FontWeight.w500,
    color: C.text,
  );
  static const mono = TextStyle(
    fontFamily: 'Menlo',
    fontFamilyFallback: ['Consolas', 'DejaVu Sans Mono', 'monospace'],
    fontSize: 11.5,
    height: 1.5,
    color: C.textDim,
  );
}

ThemeData buildTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: C.bg,
    canvasColor: C.bg,
    colorScheme: const ColorScheme.dark(
      primary: C.amber,
      onPrimary: C.amberInk,
      secondary: C.amber,
      surface: C.panel,
      onSurface: C.text,
      error: C.red,
      onError: Colors.white,
    ),
    textTheme: base.textTheme.apply(bodyColor: C.text, displayColor: C.text),
    dividerColor: C.line,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    iconTheme: const IconThemeData(color: C.textDim, size: 18),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: C.amber,
      selectionColor: C.amberSoft,
      selectionHandleColor: C.amber,
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 420),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF24282F),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: C.lineStrong),
      ),
      textStyle: const TextStyle(fontSize: 11.5, color: C.text, height: 1.3),
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      activeTrackColor: C.amber,
      inactiveTrackColor: const Color(0xFF2B3038),
      disabledActiveTrackColor: C.lineStrong,
      disabledInactiveTrackColor: C.line,
      thumbColor: C.amber,
      disabledThumbColor: C.lineStrong,
      overlayColor: C.amberSoft,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, disabledThumbRadius: 5),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
      trackShape: const RoundedRectSliderTrackShape(),
      valueIndicatorColor: C.amber,
      valueIndicatorShape: const PaddleSliderValueIndicatorShape(),
      valueIndicatorTextStyle: const TextStyle(
        color: C.amberInk,
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: C.panelAlt,
      elevation: 12,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: C.lineStrong),
      ),
      textStyle: T.body,
    ),
    scrollbarTheme: const ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(Color(0xFF3B4048)),
      thickness: WidgetStatePropertyAll(6),
      radius: Radius.circular(3),
      crossAxisMargin: 2,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: C.amber,
      linearTrackColor: Color(0xFF2B3038),
      circularTrackColor: Color(0xFF2B3038),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.panelAlt,
      contentTextStyle: T.body,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: C.lineStrong),
      ),
    ),
  );
}
