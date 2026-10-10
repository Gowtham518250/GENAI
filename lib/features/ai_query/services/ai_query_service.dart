import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../api_client.dart';
import '../models/ai_query_response.dart';

/// Successful or failed result from recorded-audio voice queries.
class AIQueryVoiceResult {
  final AIQueryResponse response;
  final String transcript;
  final String englishQuery;

  const AIQueryVoiceResult({
    required this.response,
    this.transcript = '',
    this.englishQuery = '',
  });

  factory AIQueryVoiceResult.error(String message) => AIQueryVoiceResult(
        response: AIQueryResponse.error(message),
      );
}

/// Service for executing AI-powered natural-language business queries against the
/// Retail Mind backend (`POST /askquery`) and managing local query history.
class AiQueryService {
  static const String _historyKey = 'retail_mind_ai_query_history_v1';
  static const int _maxHistoryItems = 20;
  static const Duration _requestTimeout = Duration(seconds: 30);

  static String _friendlyVoiceServiceError(String? detail, int statusCode) {
    final message = (detail ?? '').trim();
    final normalized = message.toLowerCase();

    if (normalized.contains('open-source voice service is not configured') ||
        normalized.contains('indic_speech_service_url') ||
        normalized.contains('indic_speech_service_api_key must be configured')) {
      return 'Multilingual speech recognition is not configured on the server yet. '
          'Please ask the app administrator to finish the speech-service setup. '
          'Your phone does not need to support the selected language.';
    }
    if (normalized.contains('speech models are not ready') ||
        normalized.contains('temporarily unreachable') ||
        normalized.contains('speech service is not configured')) {
      return 'The multilingual speech service is unavailable or still starting. '
          'Please try again shortly.';
    }
    if (normalized.contains('unsupported voice language')) {
      return 'Speech recognition is not enabled for this language on the server yet. '
          'Please choose another language or contact the app administrator.';
    }
    if (statusCode == 401 || normalized.contains('invalid speech service credentials')) {
      return 'The multilingual speech service credentials need to be checked by the app administrator.';
    }

    if (message.isNotEmpty &&
        !normalized.contains('traceback') &&
        !normalized.contains('sqlalchemy') &&
        !normalized.contains('internal server error')) {
      return message;
    }
    return 'Voice processing failed (HTTP $statusCode). Please try again.';
  }

  /// Transcribe a recorded question into the selected spoken language.
  ///
  /// This endpoint only returns text. The screen displays that text in the query
  /// box first, then submits it to /askquery with the same language code so the
  /// existing Groq text translator runs before business-data retrieval.
  static Future<String> transcribeVoiceQuery({
    required String audioPath,
    required String languageCode,
  }) async {
    if (audioPath.trim().isEmpty) {
      throw Exception('No voice recording was saved. Please record your question again.');
    }

    final fileName = audioPath.split(Platform.pathSeparator).last;
    final audioFile = await http.MultipartFile.fromPath(
      'audio',
      audioPath,
      filename: fileName.isEmpty ? 'voice-query.wav' : fileName,
    );

    try {
      final streamedResponse = await ApiClient.postMultipart(
        ApiClient.askQueryTranscribeEndpoint,
        {'language_code': languageCode},
        files: [audioFile],
        timeout: const Duration(minutes: 2),
      );
      final response = await http.Response.fromStream(streamedResponse)
          .timeout(const Duration(minutes: 2));

      dynamic decoded;
      try {
        decoded = json.decode(response.body);
      } catch (_) {
        decoded = null;
      }

      if (response.statusCode != 200 && response.statusCode != 201) {
        final detail = decoded is Map
            ? (decoded['detail'] ?? decoded['error'] ?? decoded['message'])?.toString()
            : null;
        throw Exception(
          (detail != null && detail.trim().isNotEmpty)
              ? detail.trim()
              : 'Speech recognition failed (HTTP ${response.statusCode}). Please try again.',
        );
      }

      if (decoded is! Map) {
        throw Exception('The speech service returned an invalid transcript.');
      }
      final transcript = (decoded['transcript'] ?? '').toString().trim();
      if (transcript.isEmpty) {
        throw Exception('No clear speech was detected. Please record your question again.');
      }
      unawaited(saveQueryToHistory(transcript));
      return transcript;
    } on TimeoutException {
      throw Exception('Speech recognition timed out. Please try a shorter recording.');
    } on SocketException {
      throw Exception('No internet connection. Please check your connection.');
    }
  }

  /// Upload a complete recording to the self-hosted open-source speech service.
  /// The server runs IndicConformer + IndicTrans2 before invoking the same
  /// authenticated RAG/SQL query path. This deliberately avoids device locale
  /// availability and speech recognizers that clear partial text after silence.
  static Future<AIQueryVoiceResult> askVoiceQuery({
    required String audioPath,
    required String languageCode,
  }) async {
    if (audioPath.trim().isEmpty) {
      return AIQueryVoiceResult.error('No voice recording was saved. Please record your question again.');
    }

    try {
      final fileName = audioPath.split(Platform.pathSeparator).last;
      final audioFile = await http.MultipartFile.fromPath(
        'audio',
        audioPath,
        filename: fileName.isEmpty ? 'voice-query.wav' : fileName,
      );
      final streamedResponse = await ApiClient.postMultipart(
        ApiClient.askQueryVoiceEndpoint,
        {'language_code': languageCode},
        files: [audioFile],
        // Cold starts can take longer while the open-source model weights load.
        timeout: const Duration(minutes: 4),
      );
      final response = await http.Response.fromStream(streamedResponse);

      dynamic decoded;
      try {
        decoded = json.decode(response.body);
      } catch (_) {
        decoded = null;
      }

      if (response.statusCode != 200 && response.statusCode != 201) {
        final detail = decoded is Map
            ? (decoded['detail'] ?? decoded['error'] ?? decoded['message'])?.toString()
            : null;
        return AIQueryVoiceResult.error(
          _friendlyVoiceServiceError(detail, response.statusCode),
        );
      }

      if (decoded is! Map) {
        return AIQueryVoiceResult.error('The voice service returned an invalid response. Please try again.');
      }
      final payload = Map<String, dynamic>.from(decoded);
      final rawVoice = payload['voice'];
      final voice = rawVoice is Map ? rawVoice : const <String, dynamic>{};
      final transcript = (voice['transcript'] ?? payload['original_query'] ?? '').toString().trim();
      final englishQuery = (voice['translated_query'] ?? payload['translated_query'] ?? payload['query'] ?? '').toString().trim();

      if (transcript.isEmpty || englishQuery.isEmpty) {
        return AIQueryVoiceResult.error('Speech was captured, but no clear question was recognized. Please speak once more and try again.');
      }

      final queryResponse = AIQueryResponse.fromJson(
        payload,
        originalQuery: transcript,
      );
      unawaited(saveQueryToHistory(transcript));
      return AIQueryVoiceResult(
        response: queryResponse,
        transcript: transcript,
        englishQuery: englishQuery,
      );
    } on TimeoutException {
      return AIQueryVoiceResult.error('Voice processing took too long. Please try a shorter question or retry.');
    } catch (error) {
      if (kDebugMode) debugPrint('AI voice query upload failed: $error');
      return AIQueryVoiceResult.error('Could not reach the open-source speech service. Check the connection and speech-service configuration, then retry.');
    }
  }

  /// Translates an already-generated answer for spoken playback.
  ///
  /// The backend uses the existing Groq translation configuration/key, so the
  /// Flutter client never stores or exposes a provider secret.
  static Future<String> translateAnswerForSpeech(
    String answer, {
    required String languageCode,
  }) async {
    final cleanAnswer = answer.trim();
    if (cleanAnswer.isEmpty) {
      throw Exception('There is no answer to speak.');
    }
    if (languageCode == 'en') return cleanAnswer;

    final response = await ApiClient.postForm(
      ApiClient.askQueryTranslateAnswerEndpoint,
      {
        'text': cleanAnswer,
        'language_code': languageCode,
      },
    ).timeout(const Duration(seconds: 45));

    dynamic decoded;
    try {
      decoded = json.decode(response.body);
    } catch (_) {
      decoded = null;
    }

    if (response.statusCode != 200 && response.statusCode != 201) {
      final detail = decoded is Map
          ? (decoded['detail'] ?? decoded['error'] ?? decoded['message'])?.toString()
          : null;
      throw Exception(
        detail != null && detail.trim().isNotEmpty
            ? detail.trim()
            : 'Answer translation failed (HTTP ${response.statusCode}).',
      );
    }

    if (decoded is! Map) {
      throw Exception('The translation service returned an invalid response.');
    }
    final translated = (decoded['translated_text'] ?? '').toString().trim();
    if (translated.isEmpty) {
      throw Exception('No translated answer was produced.');
    }
    return translated;
  }

  /// Executes a natural-language business query against the backend.
  ///
  /// The user question is sent as-is without manual date conversion or SQL generation.
  /// Returns a structured [AIQueryResponse].
  static Future<AIQueryResponse> askQuery(
    String userQuery, {
    String languageCode = 'en',
  }) async {
    final trimmedQuery = userQuery.trim();
    if (trimmedQuery.isEmpty) {
      return AIQueryResponse.error(
        'Please enter a question to ask Retail Mind.',
      );
    }

    final stopwatch = Stopwatch()..start();
    int? statusCode;
    String? engineVersion;
    int resultCount = 0;

    try {
      // NOTE: Do NOT pre-check the stored token here. ApiClient.postJson already
      // wraps every request in _withTokenRefresh, which intercepts a 401, silently
      // calls /api/session/refresh with the stored refresh token, stores the new
      // access token, and retries the original request — all transparently.
      // A pre-check would bypass that flow and give a false "session expired" error
      // even when the refresh token is perfectly valid.

      // /askquery has a form-data contract. Send exactly one request per
      // user action; retrying the same query as JSON after a 422 caused duplicate
      // backend hits on validation errors and older deployments.
      final response = await ApiClient.postForm(
        ApiClient.askQueryEndpoint,
        {
          'query': trimmedQuery,
          'language_code': languageCode,
        },
      ).timeout(_requestTimeout);

      stopwatch.stop();
      statusCode = response.statusCode;

      // Step 3: Handle HTTP Status Codes
      if (response.statusCode == 200 || response.statusCode == 201) {
        final dynamic decoded = json.decode(response.body);
        if (decoded is Map<String, dynamic>) {
          final queryResponse = AIQueryResponse.fromJson(
            decoded,
            originalQuery: trimmedQuery,
          );
          engineVersion = queryResponse.queryEngineVersion;
          resultCount = queryResponse.results.length;

          // Save to local history asynchronously
          unawaited(saveQueryToHistory(trimmedQuery));

          _logTelemetry(
            query: trimmedQuery,
            status: statusCode,
            engineVersion: engineVersion,
            duration: stopwatch.elapsed,
            resultCount: resultCount,
          );

          return queryResponse;
        } else if (decoded is List) {
          final queryResponse = AIQueryResponse(
            query: trimmedQuery,
            results: decoded,
            generatedModelResponse:
                'Found ${decoded.length} records matching your query.',
            isSuccess: true,
          );
          unawaited(saveQueryToHistory(trimmedQuery));
          return queryResponse;
        } else {
          return AIQueryResponse.error(
            'Received an unexpected response structure from the AI service.',
            query: trimmedQuery,
          );
        }
      } else if (response.statusCode == 401) {
        // _withTokenRefresh in ApiClient already attempted a silent refresh + retry.
        // If we still see a 401 here, the refresh token itself is also invalid/expired.
        if (kDebugMode)
          debugPrint(
            '[AUTH] /askquery still 401 after refresh attempt — refresh token expired',
          );
        return AIQueryResponse.error(
          'Your session has expired. Please sign in again.',
          query: trimmedQuery,
        );
      } else if (response.statusCode == 403) {
        return AIQueryResponse.error(
          'You do not have permission to access this data.',
          query: trimmedQuery,
        );
      } else if (response.statusCode == 404) {
        return AIQueryResponse.error(
          'The AI Query service is currently unavailable. Please try again later.',
          query: trimmedQuery,
        );
      } else if (response.statusCode == 422) {
        return AIQueryResponse.error(
          'Unable to process this query format. Please try rephrasing your question.',
          query: trimmedQuery,
        );
      } else if (response.statusCode >= 500 && response.statusCode < 600) {
        return AIQueryResponse.error(
          'Retail Mind couldn\'t process that question right now. Please try again.',
          query: trimmedQuery,
        );
      } else {
        String message =
            'Retail Mind couldn\'t process that question right now. Please try again.';
        try {
          final errBody = json.decode(response.body);
          if (errBody is Map && errBody['detail'] != null) {
            final detail = errBody['detail'].toString();
            // Only use detail if it's friendly and doesn't leak raw database traces
            if (!detail.toLowerCase().contains('traceback') &&
                !detail.toLowerCase().contains('syntax') &&
                !detail.toLowerCase().contains('column') &&
                !detail.toLowerCase().contains('table')) {
              message = detail;
            }
          }
        } catch (_) {}
        return AIQueryResponse.error(message, query: trimmedQuery);
      }
    } on TimeoutException {
      stopwatch.stop();
      _logTelemetry(
        query: trimmedQuery,
        status: 408,
        engineVersion: null,
        duration: stopwatch.elapsed,
        resultCount: 0,
        error: 'Timeout',
      );
      return AIQueryResponse.error(
        'The request timed out. Retail Mind AI is taking longer than expected. Please try again.',
        query: trimmedQuery,
      );
    } on SocketException {
      stopwatch.stop();
      _logTelemetry(
        query: trimmedQuery,
        status: 0,
        engineVersion: null,
        duration: stopwatch.elapsed,
        resultCount: 0,
        error: 'No Internet',
      );
      return AIQueryResponse.error(
        'No internet connection. Please check your connection.',
        query: trimmedQuery,
      );
    } catch (e) {
      stopwatch.stop();
      final errStr = e.toString();
      _logTelemetry(
        query: trimmedQuery,
        status: statusCode ?? 500,
        engineVersion: null,
        duration: stopwatch.elapsed,
        resultCount: 0,
        error: errStr,
      );

      if (errStr.contains('SocketException') ||
          errStr.contains('HandshakeException') ||
          errStr.contains('Connection failed') ||
          errStr.contains('No network connectivity')) {
        return AIQueryResponse.error(
          'No internet connection. Please check your connection.',
          query: trimmedQuery,
        );
      }

      return AIQueryResponse.error(
        'Retail Mind couldn\'t process that question right now. Please try again.',
        query: trimmedQuery,
      );
    }
  }

  /// Internal debug logging that strictly excludes sensitive data, tokens, or credentials
  static void _logTelemetry({
    required String query,
    required int? status,
    required String? engineVersion,
    required Duration duration,
    required int resultCount,
    String? error,
  }) {
    if (kDebugMode) {
      debugPrint('====================================');
      debugPrint('[AI_QUERY]');
      debugPrint('Question: $query');
      debugPrint('Status: ${status ?? "N/A"}');
      debugPrint('Query Engine Version: ${engineVersion ?? "N/A"}');
      debugPrint('Response Time: ${duration.inMilliseconds}ms');
      debugPrint('Result Count: $resultCount');
      if (error != null) {
        debugPrint('Error: $error');
      }
      debugPrint('====================================');
    }
  }

  /// Uploads recorded audio to the open-source speech service proxy.
  ///
  /// The backend transcribes the selected Indian language, translates it to
  /// English, and feeds that English question into the existing /askquery RAG
  /// + SQL pipeline. One request keeps the transcript, translation and answer
  /// correlated in the UI and history.
  static Future<VoiceQueryResult> askQueryFromAudio(
    File audioFile, {
    required String languageCode,
  }) async {
    if (!await audioFile.exists() || await audioFile.length() == 0) {
      throw Exception('The recording is empty. Please record your question again.');
    }

    final streamed = await ApiClient.postMultipart(
      ApiClient.askQueryVoiceEndpoint,
      {'language_code': languageCode},
      files: [await http.MultipartFile.fromPath('audio', audioFile.path)],
      timeout: const Duration(minutes: 3),
    );
    final body = await streamed.stream
        .bytesToString()
        .timeout(const Duration(minutes: 3));

    dynamic decoded;
    try {
      decoded = json.decode(body);
    } catch (_) {
      decoded = null;
    }

    if (streamed.statusCode != 200 && streamed.statusCode != 201) {
      String message = 'Voice query failed (HTTP ${streamed.statusCode}).';
      if (decoded is Map && decoded['detail'] != null) {
        message = decoded['detail'].toString();
      } else if (decoded is Map && decoded['message'] != null) {
        message = decoded['message'].toString();
      }
      throw Exception(message);
    }

    if (decoded is! Map<String, dynamic>) {
      throw Exception('The voice service returned an unexpected response.');
    }

    final voice = decoded['voice'] is Map
        ? Map<String, dynamic>.from(decoded['voice'] as Map)
        : decoded;
    final transcript = (voice['transcript'] ?? voice['source_transcript'] ?? '').toString().trim();
    final englishQuery = (voice['translated_query'] ??
            voice['english_query'] ??
            decoded['translated_query'] ??
            decoded['query'] ??
            '')
        .toString()
        .trim();

    if (englishQuery.isEmpty) {
      throw Exception('No English question was produced. Try speaking more slowly and clearly.');
    }

    final response = AIQueryResponse.fromJson(
      decoded,
      originalQuery: englishQuery,
    );
    return VoiceQueryResult(
      transcript: transcript,
      englishQuery: englishQuery,
      response: response,
    );
  }

  /// Fetch persistent question + answer history for the authenticated owner.
  static Future<List<AIQueryHistoryItem>> fetchQueryHistory({
    int limit = 100,
    int offset = 0,
  }) async {
    final response = await ApiClient.getJson(
      '/askquery/history?limit=$limit&offset=$offset',
    ).timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw Exception('Unable to load query history.');
    }

    final decoded = json.decode(response.body);
    final raw = decoded is Map ? decoded['history'] : null;
    if (raw is! List) return <AIQueryHistoryItem>[];

    return raw
        .whereType<Map>()
        .map((row) => AIQueryHistoryItem.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  static Future<void> deleteQueryHistory(int historyId) async {
    final response = await ApiClient.deleteJson(
      '/askquery/history/$historyId',
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Unable to delete this query history entry.');
    }
  }

  static Future<void> clearRemoteQueryHistory() async {
    final response = await ApiClient.deleteJson(
      '/askquery/history',
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Unable to clear query history.');
    }
  }

  // ===========================================================================
  // LOCAL QUERY HISTORY (Up to 20 recent queries via SharedPreferences)
  // ===========================================================================

  /// Loads recent queries from local device storage
  static Future<List<String>> getQueryHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_historyKey) ?? [];
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to load query history: $e');
      return [];
    }
  }

  /// Saves a new query into local storage, maintaining at most 20 recent entries
  static Future<void> saveQueryToHistory(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> list = prefs.getStringList(_historyKey) ?? [];

      // Remove existing occurrence to promote it to the top
      list.removeWhere(
        (item) => item.trim().toLowerCase() == clean.toLowerCase(),
      );
      list.insert(0, clean);

      // Keep only recent 20
      if (list.length > _maxHistoryItems) {
        list = list.sublist(0, _maxHistoryItems);
      }

      await prefs.setStringList(_historyKey, list);
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to save query history: $e');
    }
  }

  /// Removes an individual item from local query history
  static Future<void> removeHistoryItem(String query) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> list = prefs.getStringList(_historyKey) ?? [];
      list.removeWhere((item) => item.trim() == query.trim());
      await prefs.setStringList(_historyKey, list);
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to remove history item: $e');
    }
  }

  /// Clears all stored query history
  static Future<void> clearQueryHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_historyKey);
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to clear query history: $e');
    }
  }
}

/// Result from the multilingual speech -> English -> RAG/SQL flow.
class VoiceQueryResult {
  final String transcript;
  final String englishQuery;
  final AIQueryResponse response;

  const VoiceQueryResult({
    required this.transcript,
    required this.englishQuery,
    required this.response,
  });
}
