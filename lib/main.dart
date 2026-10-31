import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/store.dart';
import 'core/studio.dart';
import 'l10n/strings.dart';
import 'ui/shell.dart';
import 'ui/visuals.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final studio = Studio(await LocalStore.open());
    await studio.initialize();
    runApp(ImagynApp(studio: studio));
  } catch (_) {
    runApp(MaterialApp(localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: Strings.locales,
      home: Builder(builder: (context) => Scaffold(body: Center(child: Padding(
        padding: const EdgeInsets.all(32), child: Text(Strings.of(context).t('error'))))))));
  }
}

class ImagynApp extends StatelessWidget {
  const ImagynApp({super.key, required this.studio});
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
      theme: studioTheme(Brightness.light), darkTheme: studioTheme(Brightness.dark),
      builder: (context, child) => StudioPageBackground(
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations:
            studio.reduceMotion || MediaQuery.of(context).disableAnimations),
          child: child!,
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
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xff7c5ce0),
    brightness: brightness,
  ).copyWith(
    primary: dark ? const Color(0xffc4b5fd) : const Color(0xff6d3fd1),
    onPrimary: dark ? const Color(0xff24124d) : Colors.white,
    primaryContainer: dark ? const Color(0xff3a2a5e) : const Color(0xffede6ff),
    onPrimaryContainer: dark
        ? const Color(0xffede6ff)
        : const Color(0xff2a145e),
    secondary: const Color(0xff8b5cf6),
    surface: dark ? const Color(0xff17121f) : const Color(0xfffbfaff),
    onSurface: dark ? const Color(0xffede9f5) : const Color(0xff1e1a26),
    surfaceContainerLow: dark
        ? const Color(0xff1e1929)
        : const Color(0xfff5f1fc),
    surfaceContainerHigh: dark
        ? const Color(0xff2c2439)
        : const Color(0xffe9e2f6),
    outline: dark ? const Color(0xff9b90b5) : const Color(0xff7a718c),
    outlineVariant: dark ? const Color(0xff433955) : const Color(0xffd9d0ea),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: interfaceFont(),
    fontFamilyFallback: fontFallbacks,
    scaffoldBackgroundColor: Colors.transparent,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      hintStyle: TextStyle(color: scheme.outline),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(
          color: scheme.primary.withValues(alpha: .55),
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      elevation: 0,
      backgroundColor: scheme.surface.withValues(alpha: .94),
      indicatorColor: scheme.primaryContainer,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .6),
      thickness: 1,
    ),
  );
}
