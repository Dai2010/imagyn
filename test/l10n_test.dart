import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imagyn/l10n/strings.dart';
import 'package:imagyn/l10n/translations.dart';

void main() {
  const languages = ['en', 'zh', 'fr', 'es', 'ru', 'ar'];

  test('every supported locale ships a table and a display name', () {
    expect(Strings.locales.map((locale) => locale.languageCode).toSet(), translations.keys.toSet());
    expect(Strings.names.keys.toSet(), translations.keys.toSet());
  });

  test('all languages define exactly the same keys', () {
    final reference = translations['en']!.keys.toSet();
    for (final language in languages) {
      expect(translations[language]!.keys.toSet(), reference, reason: language);
    }
  });

  test('no translation is empty', () {
    for (final language in languages) {
      translations[language]!.forEach((key, value) {
        expect(value.trim(), isNotEmpty, reason: '$language.$key');
      });
    }
  });

  test('every error code the network layer can raise has text', () {
    const errorCodes = [
      'invalidEndpoint', 'invalidProxy', 'missingKey', 'missingImageModel', 'missingAgentModel',
      'referenceLimit', 'visionDisabled', 'invalidImage', 'imageTooLarge', 'invalidImageUrl',
      'noImage', 'invalidResponse', 'unsupportedTool', 'invalidTool', 'multipleCalls',
      'authError', 'rateLimit', 'serviceError', 'emptyPrompt', 'cancelled', 'unknown', 'error',
      'invalidAgentOptions', 'redirectBlocked', 'invalidImageOptions', 'promptTooLong', 'downloadFailed', 'incompleteImageStream',
      'responseTooLarge', 'incompleteStream',
    ];
    for (final code in errorCodes) {
      expect(translations['en']!.containsKey(code), isTrue, reason: code);
    }
  });

  test('the language picker has a label in every language', () {
    for (final key in ['system', 'language']) {
      for (final language in languages) {
        expect(translations[language]![key]!.trim(), isNotEmpty, reason: '$language.$key');
      }
    }
  });

  test('the second-language tables are actually translated', () {
    final english = translations['en']!;
    for (final language in ['zh', 'fr', 'es', 'ru', 'ar']) {
      final table = translations[language]!;
      final translated = table.keys.where((key) => table[key] != english[key]).length;
      expect(translated / english.length, greaterThan(0.8), reason: language);
    }
  });

  test('an unknown language falls back to English instead of leaking keys', () {
    expect(Strings('de').t('save'), translations['en']!['save']);
    expect(Strings('de').t('nope.not.a.key'), 'nope.not.a.key');
  });

  group('device language resolution', () {
    test('takes the first device language we actually speak', () {
      expect(Strings.resolve([const Locale('de'), const Locale('pt'), const Locale('fr')]), 'fr');
      expect(Strings.resolve([const Locale('ja'), const Locale('ar')]), 'ar');
    });

    test('ignores the region so zh_CN, zh_TW and zh_Hans all match', () {
      expect(Strings.resolve([const Locale('zh', 'CN')]), 'zh');
      expect(Strings.resolve([const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans')]), 'zh');
    });

    test('falls back to English rather than to whichever locale is listed first', () {
      expect(Strings.resolve(const []), 'en');
      expect(Strings.resolve([const Locale('de')]), 'en');
    });

    test('knows which codes are supported', () {
      for (final language in languages) {
        expect(Strings.isSupported(language), isTrue, reason: language);
      }
      expect(Strings.isSupported('de'), isFalse);
      expect(Strings.isSupported('system'), isFalse);
    });
  });
}
