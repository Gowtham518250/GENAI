import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'live_translation_service.dart';

/// A replacement Text widget that localizes dictionary-backed labels and
/// translates other visible strings for display.
///
/// The original model/database value is never changed. Unsupported locales or
/// failed/offline translation keep the source visible rather than hiding data.
class LiveTranslatedText extends StatefulWidget {
  const LiveTranslatedText(
    this.text, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  final String text;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

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
        RegExp(r'^\+?[0-9][0-9 ()-]{6,}$').hasMatch(value)) {
      return true;
    }

    // Preserve values such as ORD-20261017-13, invoice IDs and SKU codes.
    if (RegExp(r'^[#A-Z0-9][A-Z0-9_./:#-]{4,}$').hasMatch(value) &&
        RegExp(r'[0-9_./:#-]').hasMatch(value)) {
      return true;
    }

    // Keep short all-capital tokens (UPI, GST, COD), but let statuses such as
    // PENDING and CANCELLED translate as ordinary labels.
    return value.length <= 4 &&
        value == value.toUpperCase() &&
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
    // Localizations.localeOf subscribes this widget to MaterialApp locale
    // changes without requiring the page to know about a particular provider.
    _queueTranslation(
      (widget.locale ?? Localizations.localeOf(context)).languageCode,
    );
  }

  @override
  void didUpdateWidget(covariant LiveTranslatedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.locale != widget.locale) {
      _requestKey = null;
      _displayText = widget.text;
      _queueTranslation(
        (widget.locale ?? Localizations.localeOf(context)).languageCode,
      );
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

    // Curated dictionary strings are instant and work offline.
    final curated = _curatedTranslation(widget.text, targetCode);
    if (curated != null) {
      _displayText = curated;
      return;
    }

    // Don't send URLs, emails, phone numbers or machine identifiers for
    // translation. Those values must remain exact on screen.
    if (_shouldPreserve(widget.text)) {
      _displayText = widget.text;
      return;
    }

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
      strutStyle: widget.strutStyle,
      textAlign: widget.textAlign,
      textDirection: widget.textDirection,
      locale: widget.locale,
      softWrap: widget.softWrap,
      overflow: widget.overflow,
      textScaler: widget.textScaler,
      maxLines: widget.maxLines,
      semanticsLabel: widget.semanticsLabel,
      textWidthBasis: widget.textWidthBasis,
      textHeightBehavior: widget.textHeightBehavior,
      selectionColor: widget.selectionColor,
    );
  }
}
