import 'dart:async';
import 'dart:collection';

import 'live_translation_web.dart'
    if (dart.library.io) 'live_translation_native.dart' as platform;

/// Translates dynamic display strings with a small bounded queue.
/// Duplicate strings are coalesced and requests are batched to avoid a remote
/// AI call for every widget on the page.
class LiveTranslationService {
  LiveTranslationService._();

  static final LiveTranslationService instance = LiveTranslationService._();

  static const int _maxConcurrentBatches = 2;
  static const int _maxBatchItems = 20;
  static const int _maxCachedTranslations = 2000;
  static const Duration _batchCoalesceDelay = Duration(milliseconds: 25);

  final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();
  final Map<String, Future<String>> _inFlight = <String, Future<String>>{};
  final Queue<_TranslationTask> _queue = Queue<_TranslationTask>();
  int _activeBatches = 0;
  bool _pumpScheduled = false;

  Future<String> translateForDisplay(
    String text, {
    required String targetLanguageCode,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        targetLanguageCode == 'en' ||
        !_containsTranslatableLetters(trimmed, targetLanguageCode)) {
      return Future<String>.value(text);
    }

    final key = '$targetLanguageCode\u0000$trimmed';
    final cached = _cache[key];
    if (cached != null) return Future<String>.value(cached);

    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;

    final completer = Completer<String>();
    _inFlight[key] = completer.future;
    _queue.add(
      _TranslationTask(
        key: key,
        text: trimmed,
        targetLanguageCode: targetLanguageCode,
        completer: completer,
      ),
    );
    _schedulePump();
    return completer.future;
  }

  void _schedulePump() {
    if (_pumpScheduled) return;
    _pumpScheduled = true;
    Timer(_batchCoalesceDelay, () {
      _pumpScheduled = false;
      _pumpQueue();
    });
  }

  void _pumpQueue() {
    while (_activeBatches < _maxConcurrentBatches && _queue.isNotEmpty) {
      final first = _queue.removeFirst();
      final batch = <_TranslationTask>[first];
      for (final candidate in _queue.toList()) {
        if (batch.length >= _maxBatchItems) break;
        if (candidate.targetLanguageCode == first.targetLanguageCode) {
          _queue.remove(candidate);
          batch.add(candidate);
        }
      }
      _activeBatches++;
      unawaited(_translateBatch(batch));
    }
  }

  Future<void> _translateBatch(List<_TranslationTask> batch) async {
    try {
      final translated = await platform.translateTexts(
        batch.map((task) => task.text).toList(),
        batch.first.targetLanguageCode,
      );
      for (var index = 0; index < batch.length; index++) {
        final task = batch[index];
        final value = index < translated.length &&
                translated[index].trim().isNotEmpty
            ? translated[index]
            : task.text;
        // Avoid caching a transient offline/auth fallback forever. A later
        // screen rebuild can retry once the session or connection is restored.
        if (value.trim() != task.text.trim()) {
          _cache[task.key] = value;
          while (_cache.length > _maxCachedTranslations) {
            _cache.remove(_cache.keys.first);
          }
        }
        if (!task.completer.isCompleted) task.completer.complete(value);
        _inFlight.remove(task.key);
      }
    } catch (_) {
      for (final task in batch) {
        if (!task.completer.isCompleted) task.completer.complete(task.text);
        _inFlight.remove(task.key);
      }
    } finally {
      _activeBatches--;
      if (_queue.isNotEmpty) _schedulePump();
    }
  }

  bool _containsTranslatableLetters(String value, String targetCode) {
    if (RegExp(r'[A-Za-z\u00C0-\u024F]').hasMatch(value)) return true;
    return !_hasTargetScript(value, targetCode);
  }

  bool _hasTargetScript(String value, String targetCode) {
    final pattern = switch (targetCode) {
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
    return pattern.hasMatch(value);
  }
}

class _TranslationTask {
  const _TranslationTask({
    required this.key,
    required this.text,
    required this.targetLanguageCode,
    required this.completer,
  });

  final String key;
  final String text;
  final String targetLanguageCode;
  final Completer<String> completer;
}
