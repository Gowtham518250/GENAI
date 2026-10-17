import 'live_translation_remote.dart';

/// Flutter Web does not have the ML Kit platform-channel implementation.
/// Use the authenticated backend batch route and retain source text whenever
/// the browser has no valid app session or the translation service is offline.
Future<List<String>> translateTexts(
  List<String> texts,
  String targetLanguageCode,
) {
  return translateTextBatchRemotely(texts, targetLanguageCode);
}
