import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:retail_mind/language_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LanguageProvider', () {
    test('loads and saves the current account language separately', () async {
      SharedPreferences.setMockInitialValues({
        'user_id': 42,
        'user_role': 'OWNER',
        'language_code': 'te',
      });

      final provider = LanguageProvider();
      await provider.initialized;
      expect(provider.locale.languageCode, 'te');

      await provider.setLanguage('hi');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('language_code'), 'hi');
      expect(prefs.getString('language_code_OWNER_42'), 'hi');
      expect(provider.locale.languageCode, 'hi');
    });

    test('prefers an existing account language over device fallback', () async {
      SharedPreferences.setMockInitialValues({
        'user_id': 8,
        'user_role': 'OWNER',
        'language_code': 'te',
        'language_code_OWNER_8': 'ta',
      });

      final provider = LanguageProvider();
      await provider.initialized;
      expect(provider.locale.languageCode, 'ta');
    });

    test('unsupported language codes safely fall back to English', () async {
      SharedPreferences.setMockInitialValues({'language_code': 'xx'});

      final provider = LanguageProvider();
      await provider.initialized;
      expect(provider.locale.languageCode, 'en');

      await provider.setLanguage('xx');
      expect(provider.locale.languageCode, 'en');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('language_code'), 'en');
    });
  });
}
