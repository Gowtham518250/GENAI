/// ML Kit's Flutter translation plugin supports Android and iOS, not Web.
/// Keep the original text on Web until an approved remote translation endpoint
/// is configured by the application.
Future<String> translateEnglishText(
  String text,
  String targetLanguageCode,
) async {
  return text;
}
