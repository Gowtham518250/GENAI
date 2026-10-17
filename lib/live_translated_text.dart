import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'language_provider.dart';
import 'app_localizations.dart';
import 'live_translation_service.dart';

/// A display-only text widget for dynamic text returned by APIs or user content.
/// It never mutates the original record stored on the backend or on-device.
class LiveTranslatedText extends StatefulWidget {
  const LiveTranslatedText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.semanticsLabel,
  });

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final String? semanticsLabel;

  @override
  State<LiveTranslatedText> createState() => _LiveTranslatedTextState();
}

class _LiveTranslatedTextState extends State<LiveTranslatedText> {
  String? _curatedTranslation(String input, String targetCode) {
    final normalized = input.trim();
    final english = AppLocalizations.translations['en'];
    final target = AppLocalizations.translations[targetCode];
    if (english == null || target == null) return null;
    for (final entry in english.entries) {
      if (entry.value.trim() == normalized) {
        return target[entry.key] ?? normalized;
      }
    }
    return null;
  }

  bool _shouldPreserve(String input) {
    final value = input.trim();
    if (value.isEmpty ||
        value.contains('@') ||
        RegExp(r'^https?://', caseSensitive: false).hasMatch(value) ||
        RegExp(r'^\+?[0-9][0-9 ()-]{6,}
  String? _requestKey;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _displayText = widget.text;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to locale changes so visible dynamic text is translated again
    // immediately after the user changes language in Settings.
    _queueTranslation(context.watch<LanguageProvider>().locale.languageCode);
  }

  @override
  void didUpdateWidget(covariant LiveTranslatedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _requestKey = null;
      _displayText = widget.text;
      _queueTranslation(context.read<LanguageProvider>().locale.languageCode);
    }
  }

  void _queueTranslation(String targetCode) {
    final requestKey = targetCode + '\u0000' + widget.text;
    if (_requestKey == requestKey) return;
    _requestKey = requestKey;
    final requestVersion = ++_requestVersion;

    if (targetCode == 'en' || widget.text.trim().isEmpty) {
      _displayText = widget.text;
      return;
    }

    // Use curated app strings whenever a matching dictionary entry exists.
    // This keeps navigation, buttons, statuses and common labels instant/offline.
    final curated = _curatedTranslation(widget.text, targetCode);
    if (curated != null) {
      _displayText = curated;
      return;
    }

    // Never pass machine identifiers, URLs, emails, phone-like strings, or
    // all-uppercase abbreviations to a translation model.
    if (_shouldPreserve(widget.text)) {
      _displayText = widget.text;
      return;
    }

    // Show the source immediately, then replace it when live translation
    // completes. The cache prevents repeated model calls for identical strings.
    _displayText = widget.text;
    LiveTranslationService.instance
        .translateForDisplay(widget.text, targetLanguageCode: targetCode)
        .then((translated) {
      if (!mounted || requestVersion != _requestVersion) return;
      if (_displayText != translated) {
        setState(() => _displayText = translated);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _displayText.isEmpty ? widget.text : _displayText,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      softWrap: widget.softWrap,
      semanticsLabel: widget.semanticsLabel,
    );
  }
}
).hasMatch(value) ||
        RegExp(r'^[#A-Z0-9][A-Z0-9_./:#-]{4,}
  String? _requestKey;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _displayText = widget.text;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to locale changes so visible dynamic text is translated again
    // immediately after the user changes language in Settings.
    _queueTranslation(context.watch<LanguageProvider>().locale.languageCode);
  }

  @override
  void didUpdateWidget(covariant LiveTranslatedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _requestKey = null;
      _displayText = widget.text;
      _queueTranslation(context.read<LanguageProvider>().locale.languageCode);
    }
  }

  void _queueTranslation(String targetCode) {
    final requestKey = targetCode + '\u0000' + widget.text;
    if (_requestKey == requestKey) return;
    _requestKey = requestKey;
    final requestVersion = ++_requestVersion;

    if (targetCode == 'en' || widget.text.trim().isEmpty) {
      _displayText = widget.text;
      return;
    }

    // Use curated app strings whenever a matching dictionary entry exists.
    // This keeps navigation, buttons, statuses and common labels instant/offline.
    final curated = _curatedTranslation(widget.text, targetCode);
    if (curated != null) {
      _displayText = curated;
      return;
    }

    // Never pass machine identifiers, URLs, emails, phone-like strings, or
    // all-uppercase abbreviations to a translation model.
    if (_shouldPreserve(widget.text)) {
      _displayText = widget.text;
      return;
    }

    // Show the source immediately, then replace it when live translation
    // completes. The cache prevents repeated model calls for identical strings.
    _displayText = widget.text;
    LiveTranslationService.instance
        .translateForDisplay(widget.text, targetLanguageCode: targetCode)
        .then((translated) {
      if (!mounted || requestVersion != _requestVersion) return;
      if (_displayText != translated) {
        setState(() => _displayText = translated);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _displayText.isEmpty ? widget.text : _displayText,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      softWrap: widget.softWrap,
      semanticsLabel: widget.semanticsLabel,
    );
  }
}
).hasMatch(value)) {
      return true;
    }
    return value == value.toUpperCase() &&
        RegExp(r'^[A-Z0-9 _./:#-]{2,}
  String? _requestKey;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _displayText = widget.text;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to locale changes so visible dynamic text is translated again
    // immediately after the user changes language in Settings.
    _queueTranslation(context.watch<LanguageProvider>().locale.languageCode);
  }

  @override
  void didUpdateWidget(covariant LiveTranslatedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _requestKey = null;
      _displayText = widget.text;
      _queueTranslation(context.read<LanguageProvider>().locale.languageCode);
    }
  }

  void _queueTranslation(String targetCode) {
    final requestKey = targetCode + '\u0000' + widget.text;
    if (_requestKey == requestKey) return;
    _requestKey = requestKey;
    final requestVersion = ++_requestVersion;

    if (targetCode == 'en' || widget.text.trim().isEmpty) {
      _displayText = widget.text;
      return;
    }

    // Use curated app strings whenever a matching dictionary entry exists.
    // This keeps navigation, buttons, statuses and common labels instant/offline.
    final curated = _curatedTranslation(widget.text, targetCode);
    if (curated != null) {
      _displayText = curated;
      return;
    }

    // Never pass machine identifiers, URLs, emails, phone-like strings, or
    // all-uppercase abbreviations to a translation model.
    if (_shouldPreserve(widget.text)) {
      _displayText = widget.text;
      return;
    }

    // Show the source immediately, then replace it when live translation
    // completes. The cache prevents repeated model calls for identical strings.
    _displayText = widget.text;
    LiveTranslationService.instance
        .translateForDisplay(widget.text, targetLanguageCode: targetCode)
        .then((translated) {
      if (!mounted || requestVersion != _requestVersion) return;
      if (_displayText != translated) {
        setState(() => _displayText = translated);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _displayText.isEmpty ? widget.text : _displayText,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      softWrap: widget.softWrap,
      semanticsLabel: widget.semanticsLabel,
    );
  }
}
).hasMatch(value);
  }

  String _displayText = '';
  String? _requestKey;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _displayText = widget.text;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to locale changes so visible dynamic text is translated again
    // immediately after the user changes language in Settings.
    _queueTranslation(context.watch<LanguageProvider>().locale.languageCode);
  }

  @override
  void didUpdateWidget(covariant LiveTranslatedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _requestKey = null;
      _displayText = widget.text;
      _queueTranslation(context.read<LanguageProvider>().locale.languageCode);
    }
  }

  void _queueTranslation(String targetCode) {
    final requestKey = targetCode + '\u0000' + widget.text;
    if (_requestKey == requestKey) return;
    _requestKey = requestKey;
    final requestVersion = ++_requestVersion;

    if (targetCode == 'en' || widget.text.trim().isEmpty) {
      _displayText = widget.text;
      return;
    }

    // Use curated app strings whenever a matching dictionary entry exists.
    // This keeps navigation, buttons, statuses and common labels instant/offline.
    final curated = _curatedTranslation(widget.text, targetCode);
    if (curated != null) {
      _displayText = curated;
      return;
    }

    // Never pass machine identifiers, URLs, emails, phone-like strings, or
    // all-uppercase abbreviations to a translation model.
    if (_shouldPreserve(widget.text)) {
      _displayText = widget.text;
      return;
    }

    // Show the source immediately, then replace it when live translation
    // completes. The cache prevents repeated model calls for identical strings.
    _displayText = widget.text;
    LiveTranslationService.instance
        .translateForDisplay(widget.text, targetLanguageCode: targetCode)
        .then((translated) {
      if (!mounted || requestVersion != _requestVersion) return;
      if (_displayText != translated) {
        setState(() => _displayText = translated);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _displayText.isEmpty ? widget.text : _displayText,
      style: widget.style,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.overflow,
      softWrap: widget.softWrap,
      semanticsLabel: widget.semanticsLabel,
    );
  }
}
