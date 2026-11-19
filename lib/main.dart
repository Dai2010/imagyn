import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'package:window_manager/window_manager.dart';

import 'core/store.dart';
import 'core/studio.dart';
import 'l10n/strings.dart';
import 'ui/graphite_frame.dart';
import 'ui/shell.dart';
import 'ui/visuals.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  TransitionBuilder? frame;
  try {
    if (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux) {
      await windowManager.ensureInitialized();
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      frame = (_, child) => GraphiteFrame(child: child!);
    }
    final studio = Studio(await LocalStore.open());
    await studio.initialize();
    runApp(ImagynApp(studio: studio, frame: frame));
  } catch (_) {
    runApp(MaterialApp(builder: frame, localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: Strings.locales,
      home: Builder(builder: (context) => Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(32), child: Text(Strings.of(context).t('error'))))))));
  }
}

/// Built once and reused. `ImagynApp` rebuilds on every studio change, and a
/// fresh ThemeData each time is a new object, so every Theme-dependent widget
/// in the tree is marked for rebuild on each change, not just the ones whose
/// state moved.
final _lightTheme = studioTheme(Brightness.light);
final _darkTheme = studioTheme(Brightness.dark);

class ImagynApp extends StatelessWidget {
  const ImagynApp({super.key, required this.studio, this.frame});
  final TransitionBuilder? frame;
  final Studio studio;
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: studio,
    builder: (context, _) => MaterialApp(
      title: 'Imagyn', debugShowCheckedModeBanner: false,
      locale: studio.languageSetting == 'system' ? null : Locale(studio.languageSetting),
      supportedLocales: Strings.locales,
      localeListResolutionCallback: (preferred, supported) =>
        Locale(preferred == null ? 'en' : Strings.resolve(preferred)),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      themeMode: switch (studio.theme) {
        'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system},
      theme: _lightTheme, darkTheme: _darkTheme,
      builder: (context, child) => StudioPageBackground(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations:
            studio.reduceMotion || MediaQuery.of(context).disableAnimations),
          child: frame?.call(context, child) ?? child!,
        ),
      ),
      home: StudioShell(studio: studio),
    ));
}

/// The UI family the platform itself uses. Material's default is Roboto on
/// every desktop, which is neither Windows' nor a Linux desktop's own font —
/// and its CJK glyphs come from whichever fallback the engine finds, so the
/// text reads as "not quite this system's". Android keeps Roboto and macOS
/// already resolves to San Francisco through Material's Cupertino typography.
String? interfaceFont() => switch (defaultTargetPlatform) {
  TargetPlatform.windows => 'Segoe UI',
  TargetPlatform.linux => 'Noto Sans',
  _ => null,
};

/// Families tried for glyphs [interfaceFont] lacks, chiefly CJK. Listing the
/// common system faces keeps Chinese, Japanese and Korean text in the same
/// family as the rest of the window instead of dropping to the engine default.
const fontFallbacks = [
  'Microsoft YaHei', // Windows
  'PingFang SC', // macOS
  'Noto Sans CJK SC', // Linux
  'WenQuanYi Micro Hei', // Linux
  'Ubuntu',
  'DejaVu Sans',
];

ThemeData studioTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  // Google Material You / Google Gemini palette
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff0b57d0),
    brightness: brightness,
  ).copyWith(
    primary: dark ? const Color(0xffa8c7fa) : const Color(0xff0b57d0),
    onPrimary: dark ? const Color(0xff062e6f) : Colors.white,
    primaryContainer: dark ? const Color(0xff004a77) : const Color(0xffd3e3fd),
    onPrimaryContainer: dark
        ? const Color(0xffd3e3fd)
        : const Color(0xff041e49),
    secondary: dark ? const Color(0xffc2e7ff) : const Color(0xff00639b),
    onSecondary: dark ? const Color(0xff00344a) : Colors.white,
    secondaryContainer: dark ? const Color(0xff004d61) : const Color(0xffc2e7ff),
    onSecondaryContainer: dark
        ? const Color(0xffc2e7ff)
        : const Color(0xff001f28),
    tertiary: dark ? const Color(0xffd0bcff) : const Color(0xff6750a4),
    onTertiary: dark ? const Color(0xff381e72) : Colors.white,
    tertiaryContainer: dark ? const Color(0xff4f378b) : const Color(0xffeaddff),
    onTertiaryContainer: dark
        ? const Color(0xffeaddff)
        : const Color(0xff21005d),
    surface: dark ? const Color(0xff131314) : const Color(0xffffffff),
    onSurface: dark ? const Color(0xffe3e3e3) : const Color(0xff1f1f1f),
    onSurfaceVariant: dark ? const Color(0xffc4c7c5) : const Color(0xff444746),
    surfaceContainerLowest: dark
        ? const Color(0xff0e0e0f)
        : const Color(0xffffffff),
    surfaceContainerLow: dark
        ? const Color(0xff1e1f20)
        : const Color(0xfff0f4f9),
    surfaceContainer: dark
        ? const Color(0xff232527)
        : const Color(0xffe9eef6),
    surfaceContainerHigh: dark
        ? const Color(0xff282a2c)
        : const Color(0xffe1e7ee),
    surfaceContainerHighest: dark
        ? const Color(0xff333537)
        : const Color(0xffd9e2ec),
    outline: dark ? const Color(0xff8e918f) : const Color(0xff72777a),
    outlineVariant: dark ? const Color(0xff444746) : const Color(0xffe0e3e7),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: interfaceFont(),
    fontFamilyFallback: fontFallbacks,
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      actionsIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
      titleTextStyle: TextStyle(
        fontFamily: interfaceFont(),
        fontFamilyFallback: fontFallbacks,
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
        letterSpacing: -0.2,
      ),
    ),
    cardTheme: CardThemeData(
      color: dark ? scheme.surfaceContainerHigh : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: dark ? 0.7 : 0.8),
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow,
      hintStyle: TextStyle(
        color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
        fontSize: 14,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: scheme.primary,
          width: 1.6,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.primary,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 64,
      elevation: 0,
      backgroundColor: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: const StadiumBorder(),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? scheme.surfaceContainerHighest : scheme.onSurface,
      contentTextStyle: TextStyle(
        color: dark ? scheme.onSurface : scheme.surface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: dark ? 0.6 : 0.8),
      thickness: 1,
    ),
  );
}
