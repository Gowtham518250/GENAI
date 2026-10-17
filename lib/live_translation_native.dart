import 'package:google_mlkit_translation/google_mlkit_translation.dart';

final OnDeviceTranslatorModelManager _modelManager =
    OnDeviceTranslatorModelManager();

// Single-flight maps prevent dozens of text widgets from simultaneously
// downloading the same language model or creating duplicate translators.
final Map<String, Future<void>> _modelDownloads = <String, Future<void>>{};
final Map<String, Future<OnDeviceTranslator>> _translatorTasks =
    <String, Future<OnDeviceTranslator>>{};

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
      // ML Kit's on-device translator doesn't currently include every
      // language offered in the Retail Mind selector (e.g. Punjabi, Malayalam).
      return null;
  }
}

Future<void> _ensureModelDownloaded(String languageCode) async {
  final existing = _modelDownloads[languageCode];
  if (existing != null) {
    await existing;
    return;
  }

  final task = () async {
    if (!await _modelManager.isModelDownloaded(languageCode)) {
      await _modelManager.downloadModel(languageCode);
    }
  }();
  _modelDownloads[languageCode] = task;

  try {
    await task;
  } catch (_) {
    if (identical(_modelDownloads[languageCode], task)) {
      _modelDownloads.remove(languageCode);
    }
    rethrow;
  }
}

Future<OnDeviceTranslator> _translatorFor(
  String targetLanguageCode,
  TranslateLanguage target,
) async {
  final existing = _translatorTasks[targetLanguageCode];
  if (existing != null) {
    try {
      return await existing;
    } catch (_) {
      if (identical(_translatorTasks[targetLanguageCode], existing)) {
        _translatorTasks.remove(targetLanguageCode);
      }
      rethrow;
    }
  }

  final englishCode = TranslateLanguage.english.bcpCode;
  final targetCode = target.bcpCode;
  final task = () async {
    await Future.wait<void>([
      _ensureModelDownloaded(englishCode),
      _ensureModelDownloaded(targetCode),
    ]);
    return OnDeviceTranslator(
      sourceLanguage: TranslateLanguage.english,
      targetLanguage: target,
    );
  }();
  _translatorTasks[targetLanguageCode] = task;

  try {
    return await task;
  } catch (_) {
    if (identical(_translatorTasks[targetLanguageCode], task)) {
      _translatorTasks.remove(targetLanguageCode);
    }
    rethrow;
  }
}

Future<String> translateEnglishText(
  String text,
  String targetLanguageCode,
) async {
  final target = _targetFor(targetLanguageCode);
  if (target == null || targetLanguageCode == 'en') return text;

  try {
    final translator = await _translatorFor(targetLanguageCode, target);
    return await translator.translateText(text);
  } catch (_) {
    // Keep content readable if a model can't be downloaded or translation
    // fails. Translation must never block order or inventory interactions.
    return text;
  }
}
