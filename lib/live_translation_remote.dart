import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'secure_token_storage.dart';

const int _maxRemoteBatchItems = 20;
const int _maxRemoteItemChars = 600;
const int _maxRemoteBatchChars = 4000;

/// Uses the authenticated backend batch endpoint for platforms/locales that
/// have no suitable on-device translation model. No provider secret is shipped
/// inside Flutter. On auth/network errors the original text stays visible.
Future<List<String>> translateTextBatchRemotely(
  List<String> texts,
  String targetLanguageCode,
) async {
  if (texts.isEmpty || targetLanguageCode == 'en') return texts;

  String? token;
  try {
    token = await SecureTokenStorage.getToken();
  } catch (_) {
    return texts;
  }
  if (token == null || token.trim().isEmpty) return texts;

  // Share runtime URL configuration with the rest of the app, including
  // custom deployments configured through ApiClient.setApiBaseUrl.
  final baseUrl = ApiClient.baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
  final result = List<String>.of(texts);
  final segments = <_TextSegment>[];
  final expectedSegments = <int, int>{};

  // The API caps each item, so long descriptions are split on word boundaries
  // and reassembled in original display order after translation.
  for (var index = 0; index < texts.length; index++) {
    final text = texts[index];
    if (text.length <= _maxRemoteItemChars) {
      segments.add(_TextSegment(index, text));
      expectedSegments[index] = (expectedSegments[index] ?? 0) + 1;
      continue;
    }

    var start = 0;
    while (start < text.length) {
      var end = math.min(start + _maxRemoteItemChars, text.length);
      if (end < text.length) {
        final boundary = text.lastIndexOf(RegExp(r'\s'), end);
        if (boundary > start) end = boundary;
      }
      if (end <= start) end = math.min(start + _maxRemoteItemChars, text.length);
      final piece = text.substring(start, end).trim();
      if (piece.isNotEmpty) {
        segments.add(_TextSegment(index, piece));
        expectedSegments[index] = (expectedSegments[index] ?? 0) + 1;
      }
      start = end;
      while (start < text.length && text[start].trim().isEmpty) {
        start++;
      }
    }
  }

  final translatedSegments = <int, List<String>>{};
  var cursor = 0;
  while (cursor < segments.length) {
    final batch = <_TextSegment>[];
    var batchChars = 0;
    while (cursor < segments.length && batch.length < _maxRemoteBatchItems) {
      final candidate = segments[cursor];
      if (batch.isNotEmpty &&
          batchChars + candidate.text.length > _maxRemoteBatchChars) {
        break;
      }
      if (candidate.text.length > _maxRemoteItemChars) {
        cursor++;
        continue;
      }
      batch.add(candidate);
      batchChars += candidate.text.length;
      cursor++;
    }
    if (batch.isEmpty) {
      cursor++;
      continue;
    }

    try {
      final response = await http
          .post(
            Uri.parse(baseUrl + '/askquery/translate-batch'),
            headers: <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/json',
              'Authorization': 'Bearer ' + token.trim(),
            },
            body: jsonEncode(<String, Object>{
              'language_code': targetLanguageCode,
              'texts': batch.map((item) => item.text).toList(),
            }),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) continue;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) continue;
      final translated = decoded['translations'];
      if (translated is! List ||
          translated.length != batch.length ||
          translated.any((value) => value is! String)) {
        continue;
      }

      for (var index = 0; index < batch.length; index++) {
        final value = (translated[index] as String).trim();
        if (value.isEmpty) continue;
        translatedSegments.putIfAbsent(batch[index].originalIndex, () => []);
        translatedSegments[batch[index].originalIndex]!.add(value);
      }
    } catch (_) {
      // Offline, expired session, or server errors keep the original value.
      continue;
    }
  }

  for (final entry in translatedSegments.entries) {
    // Do not display partial output for a long description if any batch failed.
    if (entry.value.length == expectedSegments[entry.key] &&
        entry.value.isNotEmpty) {
      result[entry.key] = entry.value.join(' ');
    }
  }
  return result;
}

class _TextSegment {
  const _TextSegment(this.originalIndex, this.text);

  final int originalIndex;
  final String text;
}
