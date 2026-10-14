import 'package:flutter/widgets.dart';
import 'translations.dart';

class Strings {
  Strings(this.language);
  final String language;
  String t(String key) => translations[language]?[key] ?? translations['en']?[key] ?? key;
  static Strings of(BuildContext context) => Strings(Localizations.localeOf(context).languageCode);
  static const locales = [Locale('zh'), Locale('en'), Locale('fr'), Locale('es'), Locale('ru'), Locale('ar')];
  static const names = {'zh': '中文', 'en': 'English', 'fr': 'Français', 'es': 'Español', 'ru': 'Русский', 'ar': 'العربية'};

  static bool isSupported(String code) => names.containsKey(code);

  /// The first preferred device locale we can actually speak, or English.
  /// Returning English rather than `locale` keeps an unsupported device
  /// language (German, say) from falling back to whichever locale happens to
  /// come first in [locales].
  static String resolve(List<Locale> preferred) {
    for (final locale in preferred) {
      if (isSupported(locale.languageCode)) return locale.languageCode;
    }
    return 'en';
  }
}
