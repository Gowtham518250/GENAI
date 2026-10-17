import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_localizations.dart';
import 'language_provider.dart';
import 'live_translation_service.dart';

/// Display-only translation for static labels and dynamic text.
///
/// Exact app dictionary matches use curated translations first, so common
/// controls are immediate and work offline. Unlisted English data strings use
/// the native on-device translator when the platform/language supports it.
/// The original value in the repository/API is never modified.
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
  String _displayText = '';
  String? _requestKey;
  int _requestVersion = 0;

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
        RegExp(r'^\+?[0-9][0-9 ()-]{6,}$').hasMatch(value) ||
        RegExp(r'^[#A-Z0-9][A-Z0-9_./:#-]{4,}$').hasMatch(value)) {
      return true;
    }
    return value == value.toUpperCase() &&
        RegExp(r'^[A-Z0-9 _./:#-]{2,}$').hasMatch(value);
  }

  @override
  void initState() {
    super.initState();
    _displayText = widget.text;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to locale changes so visible text translates again immediately
    // after the language is changed in Settings.
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

    // Use curated dictionary strings before invoking an on-device model.
    final curated = _curatedTranslation(widget.text, targetCode);
    if (curated != null) {
      _displayText = curated;
      return;
    }

    // Don't translate URLs, email addresses, phone numbers, or machine codes.
    if (_shouldPreserve(widget.text)) {
      _displayText = widget.text;
      return;
    }

    // Render source text immediately; replace it as soon as translation ends.
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
