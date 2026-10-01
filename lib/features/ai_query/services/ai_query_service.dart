import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../../api_client.dart';
import '../models/ai_query_response.dart';

/// Service for executing AI-powered natural-language business queries against the
/// Retail Mind backend (`POST /askquery`) and managing local query history.
class AiQueryService {
  static const String _historyKey = 'retail_mind_ai_query_history_v1';
  static const int _maxHistoryItems = 20;
  static const Duration _requestTimeout = Duration(seconds: 30);

  /// Executes a natural-language business query against the backend.
  ///
  /// The user question is sent as-is without manual date conversion or SQL generation.
  /// Returns a structured [AIQueryResponse].
  static Future<AIQueryResponse> askQuery(String userQuery) async {
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

      // The backend /askquery endpoint accepts form data. Send the
      // correct payload first instead of intentionally triggering a 422 and
      // then retrying, which made simple queries feel unnecessarily slow.
      http.Response response;
      try {
        response = await ApiClient.postForm(
          ApiClient.askQueryEndpoint,
          {'query': trimmedQuery},
        ).timeout(_requestTimeout);
      } catch (formErr) {
        if (formErr is SocketException ||
            formErr.toString().contains('No network connectivity') ||
            formErr is TimeoutException) {
          rethrow;
        }
        // Compatibility fallback for a backend build that expects JSON.
        response = await ApiClient.postJson(
          ApiClient.askQueryEndpoint,
          {'query': trimmedQuery},
        ).timeout(_requestTimeout);
      }

      // Compatibility retry for older deployments that still advertise the
      // opposite content type.
      if (response.statusCode == 422) {
        try {
          final jsonResp = await ApiClient.postJson(
            ApiClient.askQueryEndpoint,
            {'query': trimmedQuery},
          ).timeout(_requestTimeout);
          if (jsonResp.statusCode != 422) {
            response = jsonResp;
          }
        } catch (_) {
          // Keep the original response.
        }
      }

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
