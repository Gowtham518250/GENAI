import 'package:google_mlkit_translation/google_mlkit_translation.dart';

final OnDeviceTranslatorModelManager _modelManager =
    OnDeviceTranslatorModelManager();
final Map<String, OnDeviceTranslator> _translators =
    <String, OnDeviceTranslator>{};

TranslateLanguage? _targetFor(String code) {
  switch (code) {
    case 'en':
      return TranslateLanguage.english;
    case 'te':
      return TranslateLanguage.telugu;
    case 'hi':
      return TranslateLanguage.hindi;
    case 'ta':
      return TranslateLanguage.tamil;
    case 'kn':
      return TranslateLanguage.kannada;
    case 'mr':
      return TranslateLanguage.marathi;
    case 'gu':
      return TranslateLanguage.gujarati;
    case 'bn':
      return TranslateLanguage.bengali;
    default:
      // ML Kit's on-device translator does not currently include every
      // language offered by Retail Mind (notably Punjabi and Malayalam).
      return null;
  }
}

Future<String> translateEnglishText(
  String text,
  String targetLanguageCode,
) async {
  final target = _targetFor(targetLanguageCode);
  if (target == null || targetLanguageCode == 'en') return text;

  try {
    final englishCode = TranslateLanguage.english.bcpCode;
    final targetCode = target.bcpCode;

    if (!await _modelManager.isModelDownloaded(englishCode)) {
      await _modelManager.downloadModel(englishCode);
    }
    if (!await _modelManager.isModelDownloaded(targetCode)) {
      await _modelManager.downloadModel(targetCode);
    }

    final translator = _translators.putIfAbsent(
      targetLanguageCode,
      () => OnDeviceTranslator(
        sourceLanguage: TranslateLanguage.english,
        targetLanguage: target,
      ),
    );
    return await translator.translateText(text);
  } catch (_) {
    // Keep content readable if a model cannot download or translation fails.
    // Translation must never block order or inventory screens.
    return text;
  }
}
