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

Future<List<String>> translateTexts(
  List<String> texts,
  String targetLanguageCode,
) async {
  if (texts.isEmpty || targetLanguageCode == 'en') return texts;

  final target = _targetFor(targetLanguageCode);
  final result = List<String>.of(texts);
  final localIndexes = <int>[];
  final remoteIndexes = <int>[];

  final targetScriptRegex = switch (targetLanguageCode) {
    'te' => RegExp(r'[\u0C00-\u0C7F]'),
    'hi' || 'mr' => RegExp(r'[\u0900-\u097F]'),
    'ta' => RegExp(r'[\u0B80-\u0BFF]'),
    'kn' => RegExp(r'[\u0C80-\u0CFF]'),
    'ml' => RegExp(r'[\u0D00-\u0D7F]'),
    'gu' => RegExp(r'[\u0A80-\u0AFF]'),
    'pa' => RegExp(r'[\u0A00-\u0A7F]'),
    'bn' => RegExp(r'[\u0980-\u09FF]'),
    _ => RegExp(r'(?!)'),
  };
  final anyIndicScript = RegExp(r'[\u0900-\u0DFF]');
  final latinLetters = RegExp(r'[A-Za-z\u00C0-\u024F]');

  for (var index = 0; index < texts.length; index++) {
    final text = texts[index];
    if (text.trim().isEmpty) continue;
    final hasLatin = latinLetters.hasMatch(text);
    final hasIndic = anyIndicScript.hasMatch(text);
    if (!hasLatin && targetScriptRegex.hasMatch(text)) {
      // Already in the target writing system: preserve its spelling exactly.
      continue;
    }
    if (target == null || !hasLatin || hasIndic) {
      remoteIndexes.add(index);
    } else {
      localIndexes.add(index);
    }
  }

  if (target != null && localIndexes.isNotEmpty) {
    try {
      final translator = await _translatorFor(targetLanguageCode, target);
      final translated = await Future.wait(
        localIndexes.map((index) => translator.translateText(texts[index])),
      );
      for (var index = 0; index < localIndexes.length; index++) {
        result[localIndexes[index]] = translated[index];
      }
    } catch (_) {
      // If a local model is missing or fails, retry those entries remotely.
      remoteIndexes.addAll(localIndexes);
    }
  }

  if (remoteIndexes.isNotEmpty) {
    final remoteTexts = remoteIndexes.map((index) => texts[index]).toList();
    final translated =
        await translateTextBatchRemotely(remoteTexts, targetLanguageCode);
    for (var index = 0; index < remoteIndexes.length; index++) {
      result[remoteIndexes[index]] = translated[index];
    }
  }
  return result;
}
