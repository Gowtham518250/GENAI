import 'dart:collection';

import 'live_translation_web.dart'
    if (dart.library.io) 'live_translation_native.dart' as platform;

/// Translates dynamic, English-language content for display.
///
/// App controls should continue to use AppLocalizations so important labels
/// remain immediate and stable. Use this service for dynamic text such as
/// product descriptions, shop descriptions, order notes and AI responses.
class LiveTranslationService {
  LiveTranslationService._();

  static final LiveTranslationService instance = LiveTranslationService._();

  final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();

  Future<String> translateForDisplay(
    String text, {
    required String targetLanguageCode,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        targetLanguageCode == 'en' ||
        !_hasAnyLetters(trimmed)) {
      return text;
    }

    final key = targetLanguageCode + '\u0000' + trimmed;
    final cached = _cache[key];
    if (cached != null) return cached;

    final translated = await platform.translateEnglishText(
      trimmed,
      targetLanguageCode,
    );
    _cache[key] = translated;
    while (_cache.length > 1000) {
      _cache.remove(_cache.keys.first);
    }
    return translated;
  }

  bool _hasAnyLetters(String value) =>
      RegExp(r'[A-Za-z\u00C0-\u024F]').hasMatch(value);
}
