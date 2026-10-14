import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/store.dart';
import 'core/studio.dart';
import 'l10n/strings.dart';
import 'ui/shell.dart';

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
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations:
          studio.reduceMotion || MediaQuery.of(context).disableAnimations), child: child!),
      home: StudioShell(studio: studio),
    ));
}

ThemeData studioTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xff7863c7), brightness: brightness);
  return ThemeData(useMaterial3: true, colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xff131217) : const Color(0xfffaf9fc),
    appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0),
    inputDecorationTheme: InputDecorationTheme(filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))),
  );
}
