import 'package:flutter_test/flutter_test.dart';
import '../lib/features/ai_query/screens/voice_language_option.dart';

void main() {
  group('Ask Retail Mind voice languages', () {
    test('offers all 22 scheduled Indian languages plus English', () {
      final codes = kVoiceLanguages.map((language) => language.code).toSet();

      expect(kVoiceLanguages.length, 23);
      expect(codes.length, 23);
      expect(codes, containsAll([
        'as', 'bn', 'brx', 'doi', 'gu', 'hi', 'kn', 'ks', 'kok', 'mai',
        'ml', 'mni', 'mr', 'ne', 'or', 'pa', 'sa', 'sat', 'sd', 'ta',
        'te', 'ur', 'en',
      ]));
    });

    test('defaults can be selected by stable language code', () {
      final telugu = kVoiceLanguages.firstWhere((language) => language.code == 'te');
      expect(telugu.name, 'Telugu');
      expect(telugu.nativeName, 'తెలుగు');
    });
  });
}
