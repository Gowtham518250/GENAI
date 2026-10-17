import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'language_provider.dart';
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
    _queueTranslation(context.read<LanguageProvider>().locale.languageCode);
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
      if (_displayText != widget.text && mounted) {
        setState(() => _displayText = widget.text);
      }
      return;
    }

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
