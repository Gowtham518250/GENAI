import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/app_localizations.dart';

void main() {
  test('all supported locales have the same dictionary keys', () {
    const supportedLanguageCodes = <String>{
      'en',
      'te',
      'hi',
      'ta',
      'kn',
      'ml',
      'mr',
      'gu',
      'pa',
      'bn',
    };

    expect(AppLocalizations.translations.keys.toSet(),
        equals(supportedLanguageCodes));

    final englishKeys =
        AppLocalizations.translations['en']!.keys.toSet();

    for (final languageCode in supportedLanguageCodes) {
      final locale = AppLocalizations.translations[languageCode]!;
      expect(locale.keys.toSet(), equals(englishKeys),
          reason: 'Locale $languageCode must contain every English key.');
    }
  });
}
