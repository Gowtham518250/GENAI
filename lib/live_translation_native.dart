import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'live_translation_remote.dart';

final OnDeviceTranslatorModelManager _modelManager =
    OnDeviceTranslatorModelManager();

// Single-flight maps prevent duplicate downloads and translator instances.
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
      // Malayalam and Punjabi aren't exposed by the plugin version pinned in
      // this app, so use the authenticated backend batch route for those locales.
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

Future<List<String>> translateEnglishTexts(
  List<String> texts,
  String targetLanguageCode,
) async {
  if (texts.isEmpty || targetLanguageCode == 'en') return texts;
  final target = _targetFor(targetLanguageCode);
  if (target == null) {
    return translateEnglishBatchRemotely(texts, targetLanguageCode);
  }

  try {
    final translator = await _translatorFor(targetLanguageCode, target);
    return await Future.wait(
      texts.map((text) => translator.translateText(text)),
    );
  } catch (_) {
    // Keep displayed information visible if a local model isn't available.
    return texts;
  }
}
