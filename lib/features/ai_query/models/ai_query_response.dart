import 'package:flutter/foundation.dart';

/// Production-ready data model representing the response from the Retail Mind AI Query Engine
/// (`POST /askquery`).
///
/// Designed defensively to accommodate variations across backend versions,
/// missing fields, and arbitrary SQL result shapes without throwing runtime exceptions.
class AIQueryResponse {
  final String? queryEngineVersion;
  final String? query;
  final String? translatedQuery;
  final String? answer;
  final String? generatedSql;
  final String? generatedModelResponse;
  final List<dynamic> retrievedTableInformation;
  final String? sql;
  final List<dynamic> results;
  final DateTime timestamp;
  final bool isSuccess;
  final String? errorMessage;
  final Map<String, dynamic>? productDiscovery;

  AIQueryResponse({
    this.queryEngineVersion,
    this.query,
    this.translatedQuery,
    this.answer,
    this.generatedSql,
    this.generatedModelResponse,
    this.retrievedTableInformation = const [],
    this.sql,
    this.results = const [],
    DateTime? timestamp,
    this.isSuccess = true,
    this.errorMessage,
    this.productDiscovery,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Create an error response instance with a shopkeeper-friendly message.
  factory AIQueryResponse.error(String message, {String? query}) {
    return AIQueryResponse(
      query: query,
      isSuccess: false,
      errorMessage: message,
      answer: message,
      generatedModelResponse: message,
      results: const [],
      retrievedTableInformation: const [],
    );
  }

  /// Factory constructor to parse backend JSON safely with defensive fallbacks.
  factory AIQueryResponse.fromJson(Map<String, dynamic> json, {String? originalQuery}) {
    try {
      // 1. Query Engine Version
      final queryEngineVersion = json['query_engine_version']?.toString();

      // 2. Query
      final query = json['query']?.toString() ?? originalQuery;
      final translatedQuery = json['translated_query']?.toString();

      // 3. Generated SQL / SQL
      final generatedSql = json['generated_sql']?.toString();
      final sql = json['sql']?.toString() ?? generatedSql;

      // 4. Keep the user-facing answer separate from the raw LLM/SQL response.
      // The backend's generated_model_response may contain "TABLE: ... SQL: ...";
      // never let that override the plain, result-grounded "answer" field.
      String? answerText;
      for (final key in ['answer', 'reply', 'response', 'message']) {
        final candidate = json[key]?.toString().trim();
        if (candidate != null &&
            candidate.isNotEmpty &&
            !_looksLikeTechnicalText(candidate)) {
          answerText = candidate;
          break;
        }
      }

      // Preserve the raw model response for diagnostics/compatibility, but it is
      // not the primary display or TTS text when it contains SQL.
      String? generatedModelResponse = json['generated_model_response']?.toString();
      if (generatedModelResponse == null || generatedModelResponse.trim().isEmpty) {
        generatedModelResponse = answerText;
      }

      // 5. Retrieved table information
      List<dynamic> tableInfo = const [];
      final rawTables = json['retrieved_table_information'] ?? json['tables'];
      if (rawTables is List) {
        tableInfo = rawTables;
      } else if (rawTables is String && rawTables.isNotEmpty) {
        tableInfo = [rawTables];
      }

      // 6. Results array
      List<dynamic> resultsList = const [];
      final rawResults = json['results'] ?? json['data'] ?? json['Data'];
      if (rawResults is List) {
        resultsList = rawResults;
      } else if (rawResults is Map<String, dynamic>) {
        resultsList = [rawResults];
      }

      final rawProductDiscovery = json['product_discovery'];
      final productDiscovery = rawProductDiscovery is Map
          ? Map<String, dynamic>.from(rawProductDiscovery)
          : null;

      // If generatedModelResponse is still empty but results exist, synthesize a gentle fallback message
      if ((generatedModelResponse == null || generatedModelResponse.trim().isEmpty) && resultsList.isNotEmpty) {
        generatedModelResponse = _synthesizeAnswerFromResults(resultsList, query);
      }

      return AIQueryResponse(
        queryEngineVersion: queryEngineVersion,
        query: query,
        translatedQuery: translatedQuery,
        answer: answerText,
        generatedSql: generatedSql,
        generatedModelResponse: generatedModelResponse,
        retrievedTableInformation: tableInfo,
        sql: sql,
        results: resultsList,
        productDiscovery: productDiscovery,
        isSuccess: true,
      );
    } catch (e, stack) {
      if (kDebugMode) {
        debugPrint('⚠️ Error parsing AIQueryResponse JSON: $e\n$stack');
      }
      return AIQueryResponse.error(
        'Unable to parse the AI response. Please try again.',
        query: originalQuery,
      );
    }
  }

  /// Detects SQL/schema text that must never be shown or spoken as the answer.
  static bool _looksLikeTechnicalText(String value) {
    final text = value.trim();
    return RegExp(r'^(?:TABLE\s*:|SQL\s*:|SELECT\b|WITH\b)', caseSensitive: false).hasMatch(text) ||
        (RegExp(r'\bSQL\s*:', caseSensitive: false).hasMatch(text) &&
         RegExp(r'\bSELECT\b', caseSensitive: false).hasMatch(text));
  }

  /// Synthesizes a clean fallback summary if the backend only returned raw data rows
  static String _synthesizeAnswerFromResults(List<dynamic> results, String? query) {
    if (results.isEmpty) return 'No records found matching your request.';
    if (results.length == 1 && results.first is Map) {
      final map = results.first as Map;
      if (map.length == 1) {
        final entry = map.entries.first;
        final humanKey = entry.key.toString().replaceAll('_', ' ');
        return 'Found $humanKey: ${entry.value}';
      }
    }
    return 'Found ${results.length} result(s) for your query.';
  }

  /// Returns the effective SQL string if available
  String? get effectiveSql => (sql != null && sql!.trim().isNotEmpty) ? sql : generatedSql;

  /// Returns whether any SQL was returned
  bool get hasSql => effectiveSql != null && effectiveSql!.trim().isNotEmpty;

  /// Returns whether tabular or KPI results were returned
  bool get hasResults => results.isNotEmpty;

  /// Returns true if results represent a single high-level metric (1 row with 1-2 columns)
  bool get isSingleKpi {
    if (results.length == 1 && results.first is Map) {
      final map = results.first as Map;
      return map.isNotEmpty && map.length <= 2;
    }
    return false;
  }

  /// User-friendly display/TTS text. Always prefer the backend's grounded answer.
  /// Raw SQL is only for the collapsible technical section and must never be spoken.
  String get displayAnswer {
    final directAnswer = answer?.trim() ?? '';
    if (directAnswer.isNotEmpty && !_looksLikeTechnicalText(directAnswer)) {
      return directAnswer;
    }

    final modelText = generatedModelResponse?.trim() ?? '';
    if (modelText.isNotEmpty && !_looksLikeTechnicalText(modelText)) {
      return modelText;
    }

    if (hasResults) {
      return _synthesizeAnswerFromResults(results, query);
    }
    if (errorMessage != null && errorMessage!.trim().isNotEmpty) {
      return errorMessage!.trim();
    }
    return 'No readable answer was returned for this question.';
  }

  Map<String, dynamic> toJson() {
    return {
      'query_engine_version': queryEngineVersion,
      'query': query,
      'translated_query': translatedQuery,
      'answer': answer,
      'generated_sql': generatedSql,
      'generated_model_response': generatedModelResponse,
      'retrieved_table_information': retrievedTableInformation,
      'sql': sql,
      'results': results,
      'timestamp': timestamp.toIso8601String(),
      'is_success': isSuccess,
      'error_message': errorMessage,
      'product_discovery': productDiscovery,
    };
  }
}


class AIQueryHistoryItem {
  final int id;
  final String question;
  final String answer;
  final int resultCount;
  final DateTime createdAt;

  const AIQueryHistoryItem({
    required this.id,
    required this.question,
    required this.answer,
    required this.resultCount,
    required this.createdAt,
  });

  factory AIQueryHistoryItem.fromJson(Map<String, dynamic> json) {
    return AIQueryHistoryItem(
      id: int.tryParse(json['id']?.toString() ?? '') ?? 0,
      question: json['question']?.toString() ?? '',
      answer: json['answer']?.toString() ?? '',
      resultCount: int.tryParse(json['result_count']?.toString() ?? '') ?? 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }
}
