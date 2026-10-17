import 'dart:async';
import 'dart:collection';

import 'live_translation_web.dart'
    if (dart.library.io) 'live_translation_native.dart' as platform;

/// Translates dynamic, English-language display content.
///
/// Curated dictionary strings never use this service. For uncatalogued strings,
/// results and in-flight requests are shared and the local model queue is
/// bounded so opening a screen with hundreds of labels won't flood the plugin.
class LiveTranslationService {
  LiveTranslationService._();

  static final LiveTranslationService instance = LiveTranslationService._();

  static const int _maxConcurrentTranslations = 3;
  static const int _maxCachedTranslations = 1000;

  final LinkedHashMap<String, String> _cache = LinkedHashMap<String, String>();
  final Map<String, Future<String>> _inFlight = <String, Future<String>>{};
  final Queue<_TranslationTask> _queue = Queue<_TranslationTask>();
  int _activeTranslations = 0;

  Future<String> translateForDisplay(
    String text, {
    required String targetLanguageCode,
  }) {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        targetLanguageCode == 'en' ||
        !_hasAnyLetters(trimmed)) {
      return Future<String>.value(text);
    }

    final key = '$targetLanguageCode\u0000$trimmed';
    final cached = _cache[key];
    if (cached != null) return Future<String>.value(cached);

    // Multiple widgets can request the same string in the same frame.
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
    _pumpQueue();
    return completer.future;
  }

  void _pumpQueue() {
    while (_activeTranslations < _maxConcurrentTranslations &&
        _queue.isNotEmpty) {
      final task = _queue.removeFirst();
      _activeTranslations++;

      Future<String>.sync(
        () => platform.translateEnglishText(
          task.text,
          task.targetLanguageCode,
        ),
      ).catchError((Object _) => task.text).then((translated) {
        _cache[task.key] = translated;
        while (_cache.length > _maxCachedTranslations) {
          _cache.remove(_cache.keys.first);
        }
        if (!task.completer.isCompleted) {
          task.completer.complete(translated);
        }
      }).whenComplete(() {
        _activeTranslations--;
        _inFlight.remove(task.key);
        _pumpQueue();
      });
    }
  }

  bool _hasAnyLetters(String value) =>
      RegExp(r'[A-Za-z\u00C0-\u024F]').hasMatch(value);
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
