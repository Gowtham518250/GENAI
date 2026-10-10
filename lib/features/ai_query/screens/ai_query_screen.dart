import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../../visual_widgets.dart';
import '../models/ai_query_response.dart';
import '../services/ai_query_service.dart';
import '../widgets/ai_answer_card.dart';
import '../widgets/ai_loading_indicator.dart';
import '../widgets/result_card.dart';
import '../widgets/suggestion_chip.dart';
import 'ai_query_history_screen.dart';
import 'voice_language_option.dart';

/// Ask Retail Mind: text or voice in an Indian language, followed by the
/// existing authenticated RAG -> SQL -> result pipeline.
class AiQueryScreen extends StatefulWidget {
  final String? initialQuery;

  const AiQueryScreen({super.key, this.initialQuery});

  @override
  State<AiQueryScreen> createState() => _AiQueryScreenState();
}

class _AiQueryScreenState extends State<AiQueryScreen> {
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();
  final Record _recorder = Record();

  bool _isLoading = false;
  bool _isRecording = false;
  bool _isVoiceProcessing = false;
  AIQueryResponse? _currentResponse;
  String? _errorMessage;
  String? _originalTranscript;
  String? _translatedEnglish;
  VoiceLanguageOption _selectedLanguage = kVoiceLanguages.firstWhere(
    (language) => language.code == 'te',
  );
  Timer? _recordTimer;
  int _recordSeconds = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery != null && widget.initialQuery!.trim().isNotEmpty) {
      _queryController.text = widget.initialQuery!.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _executeQuery(widget.initialQuery!.trim());
      });
    }
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _queryController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    unawaited(_recorder.dispose());
    super.dispose();
  }

  Future<void> _openHistory() async {
    final selectedQuery = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const AiQueryHistoryScreen()),
    );
    if (!mounted || selectedQuery == null || selectedQuery.trim().isEmpty) return;
    _executeQuery(selectedQuery);
  }

  Future<void> _executeQuery(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty || _isLoading || _isVoiceProcessing) return;

    _inputFocusNode.unfocus();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _originalTranscript = null;
      _translatedEnglish = null;
      _queryController.text = cleanQuery;
    });
    _scrollToBottom();

    try {
      final response = await AiQueryService.askQuery(cleanQuery);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _currentResponse = response;
        if (!response.isSuccess) {
          _errorMessage = response.errorMessage ?? 'Unable to process this question.';
        }
      });
      _scrollToBottom();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Retail Mind could not process that question. Please try again.';
      });
    }
  }

  Future<void> _startRecording() async {
    if (_isLoading || _isVoiceProcessing || _isRecording) return;
    try {
      final allowed = await _recorder.hasPermission();
      if (!allowed) {
        _showMessage('Allow microphone access to ask a voice question.');
        return;
      }
      final directory = await getTemporaryDirectory();
      final path = '${directory.path}/retail_mind_query_${DateTime.now().millisecondsSinceEpoch}.wav';
      await _recorder.start(
        path: path,
        encoder: AudioEncoder.wav,
        samplingRate: 16000,
        bitRate: 256000,
      );
      if (!mounted) return;
      setState(() {
        _isRecording = true;
        _recordSeconds = 0;
        _errorMessage = null;
        _originalTranscript = null;
        _translatedEnglish = null;
      });
      _recordTimer?.cancel();
      _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted || !_isRecording) {
          timer.cancel();
          return;
        }
        setState(() => _recordSeconds++);
        if (_recordSeconds >= 60) {
          _stopRecordingAndAsk();
        }
      });
    } catch (error) {
      if (mounted) _showMessage('Could not start recording. Check microphone permissions and try again.');
    }
  }

  Future<void> _stopRecordingAndAsk() async {
    if (!_isRecording || _isVoiceProcessing) return;
    _recordTimer?.cancel();
    _recordTimer = null;

    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = null;
    }

    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isVoiceProcessing = true;
      _errorMessage = null;
    });

    if (path == null || path.isEmpty || !await File(path).exists()) {
      if (!mounted) return;
      setState(() {
        _isVoiceProcessing = false;
        _errorMessage = 'No audio was captured. Please try recording again.';
      });
      return;
    }

    try {
      final voiceResult = await AiQueryService.askQueryFromAudio(
        File(path),
        languageCode: _selectedLanguage.code,
      );
      if (!mounted) return;

      setState(() {
        _isVoiceProcessing = false;
        _originalTranscript = voiceResult.transcript;
        _translatedEnglish = voiceResult.englishQuery;
        _queryController.text = voiceResult.englishQuery;
        _currentResponse = voiceResult.response;
        if (!voiceResult.response.isSuccess) {
          _errorMessage = voiceResult.response.errorMessage ?? 'Unable to answer this voice query.';
        }
      });
      _scrollToBottom();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isVoiceProcessing = false;
        _errorMessage = _friendlyVoiceError(error);
      });
    } finally {
      try {
        await File(path).delete();
      } catch (_) {
        // Temporary file cleanup is best-effort.
      }
    }
  }

  String _friendlyVoiceError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '');
    if (message.contains('503') || message.toLowerCase().contains('speech service')) {
      return 'The open-source voice model service is not configured or is offline. Start the Retail Mind voice service and set INDIC_SPEECH_SERVICE_URL on the backend, then retry.';
    }
    if (message.toLowerCase().contains('timeout')) {
      return 'Voice processing took too long. Try a shorter recording or retry when the model service is ready.';
    }
    return message.length > 220 ? '${message.substring(0, 220)}…' : message;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSuggestionTap(String query) => _executeQuery(query);

  @override
  Widget build(BuildContext context) {
    final busy = _isLoading || _isVoiceProcessing;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 19),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Back',
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFF6366F1)]),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 17),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Ask Retail Mind', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
                  Text('Your AI business assistant', style: GoogleFonts.inter(fontSize: 10.5, color: Colors.white70, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _openHistory,
            tooltip: 'Open query history',
            icon: const Icon(Icons.history_rounded, color: Colors.white, size: 25),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontal = constraints.maxWidth > 650 ? 32.0 : 16.0;
            return SingleChildScrollView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(horizontal, 18, horizontal, 30),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHero(),
                      const SizedBox(height: 18),
                      _buildLanguagePicker(),
                      const SizedBox(height: 14),
                      _buildPipelineHint(),
                      const SizedBox(height: 18),
                      SuggestedQuestionsBar(
                        onSuggestionSelected: _handleSuggestionTap,
                        isLoading: busy || _isRecording,
                      ),
                      const SizedBox(height: 16),
                      _buildComposer(busy),
                      if (_isRecording) ...[
                        const SizedBox(height: 10),
                        _buildRecordingState(),
                      ],
                      if (_isVoiceProcessing) ...[
                        const SizedBox(height: 10),
                        _buildVoiceProgress(),
                      ],
                      if (_originalTranscript != null || _translatedEnglish != null) ...[
                        const SizedBox(height: 14),
                        _buildTranslationPreview(),
                      ],
                      if (_errorMessage != null && !busy) ...[
                        const SizedBox(height: 14),
                        _buildErrorBanner(_errorMessage!),
                      ],
                      if (_isLoading || _isVoiceProcessing) ...[
                        const SizedBox(height: 16),
                        const AILoadingIndicator(),
                      ],
                      if (_currentResponse != null && !busy && _currentResponse!.isSuccess) ...[
                        const SizedBox(height: 18),
                        AIAnswerCard(response: _currentResponse!),
                        if (_currentResponse!.hasResults) ...[
                          const SizedBox(height: 14),
                          ResultCard(
                            results: _currentResponse!.results,
                            queryContext: _currentResponse!.query,
                          ),
                        ],
                      ],
                      const SizedBox(height: 24),
                      _buildPrivacyNote(),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHero() {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 5, 4, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ask your shop anything', style: GoogleFonts.inter(fontSize: 25, height: 1.12, fontWeight: FontWeight.w900, letterSpacing: -0.7, color: const Color(0xFF12264A))),
                const SizedBox(height: 9),
                Text('Sales, stock, customers and invoices — in the language you speak.', style: GoogleFonts.inter(fontSize: 13, height: 1.45, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFDBEAFE), Color(0xFFEDE9FE)]),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Icon(Icons.smart_toy_rounded, size: 38, color: Color(0xFF6366F1)),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguagePicker() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFDDE5F4)),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: const Color(0xFF1B3A6B).withValues(alpha: 0.04), blurRadius: 14, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(13)),
            child: const Icon(Icons.language_rounded, color: Color(0xFF2563EB), size: 21),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Speak in your language', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w500)),
                DropdownButtonHideUnderline(
                  child: DropdownButton<VoiceLanguageOption>(
                    isExpanded: true,
                    value: _selectedLanguage,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w800, color: const Color(0xFF142B52)),
                    items: kVoiceLanguages.map((language) => DropdownMenuItem(
                      value: language,
                      child: Text('${language.nativeName}  ·  ${language.name}', overflow: TextOverflow.ellipsis),
                    )).toList(),
                    onChanged: (_isRecording || _isVoiceProcessing || _isLoading)
                        ? null
                        : (language) {
                            if (language != null) setState(() => _selectedLanguage = language);
                          },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPipelineHint() {
    const items = [
      (Icons.mic_none_rounded, 'Your voice'),
      (Icons.translate_rounded, 'English'),
      (Icons.schema_rounded, 'RAG + SQL'),
      (Icons.insights_rounded, 'Answer'),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
      decoration: BoxDecoration(
        color: const Color(0xFFEEF2FF).withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFDDE3FF)),
      ),
      child: Row(
        children: [
          for (int i = 0; i < items.length; i++) ...[
            if (i > 0) const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.chevron_right_rounded, size: 14, color: Color(0xFF9CA3AF)),
            ),
            Expanded(
              child: Column(
                children: [
                  Icon(items[i].$1, color: const Color(0xFF6366F1), size: 18),
                  const SizedBox(height: 4),
                  Text(items[i].$2, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.w700, color: const Color(0xFF475569))),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildComposer(bool busy) {
    final canAsk = _queryController.text.trim().isNotEmpty && !busy && !_isRecording;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFE3E8F1)),
        boxShadow: [BoxShadow(color: const Color(0xFF102A56).withValues(alpha: 0.06), blurRadius: 22, offset: const Offset(0, 8))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _queryController,
            focusNode: _inputFocusNode,
            enabled: !busy && !_isRecording,
            minLines: 2,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _executeQuery(_queryController.text),
            style: GoogleFonts.inter(fontSize: 15, height: 1.5, color: AppColors.textPrimary, fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: 'Ask about sales, revenue, customers, stock…',
              hintStyle: GoogleFonts.inter(fontSize: 14, color: AppColors.textTertiary, height: 1.5),
              border: InputBorder.none,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : (_isRecording ? _stopRecordingAndAsk : _startRecording),
                  icon: Icon(_isRecording ? Icons.stop_circle_rounded : Icons.mic_rounded, size: 19),
                  label: Text(
                    _isRecording ? 'Stop · ${_recordSeconds}s' : 'Tap to speak',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _isRecording ? const Color(0xFFDC2626) : const Color(0xFF5B46D6),
                    backgroundColor: _isRecording ? const Color(0xFFFEF2F2) : const Color(0xFFF3F0FF),
                    side: BorderSide(color: _isRecording ? const Color(0xFFFECACA) : const Color(0xFFDAD4FF)),
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: canAsk ? () => _executeQuery(_queryController.text) : null,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: const Text('Ask Retail Mind'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF635BEB),
                    disabledBackgroundColor: const Color(0xFFB8B5EE),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                    elevation: 0,
                    textStyle: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 11),
          Row(
            children: [
              const Icon(Icons.lock_outline_rounded, size: 14, color: Color(0xFF64748B)),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Your question is translated to English before database search.', style: GoogleFonts.inter(fontSize: 10.5, color: AppColors.textSecondary)),
              ),
              Text('${_queryController.text.length}/500', style: GoogleFonts.inter(fontSize: 10, color: AppColors.textTertiary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRecordingState() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFFFF1F2), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFECACA))),
      child: Row(
        children: [
          const Icon(Icons.fiber_manual_record_rounded, color: Color(0xFFDC2626), size: 16),
          const SizedBox(width: 10),
          Expanded(child: Text('Listening in ${_selectedLanguage.nativeName}. Speak clearly, then tap Stop.', style: GoogleFonts.inter(fontSize: 12.5, color: const Color(0xFF991B1B), fontWeight: FontWeight.w600))),
          Text('${_recordSeconds}s', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: const Color(0xFF991B1B))),
        ],
      ),
    );
  }

  Widget _buildVoiceProgress() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFBFDBFE))),
      child: Row(
        children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.3, color: Color(0xFF2563EB))),
          const SizedBox(width: 11),
          Expanded(child: Text('Transcribing ${_selectedLanguage.name}, translating to English, then querying your shop data…', style: GoogleFonts.inter(fontSize: 12.5, color: const Color(0xFF1D4ED8), fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Widget _buildTranslationPreview() {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFD8E5F5))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.translate_rounded, size: 18, color: Color(0xFF6366F1)),
            const SizedBox(width: 8),
            Text('Voice → English', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, color: const Color(0xFF142B52))),
          ]),
          if (_originalTranscript != null) ...[
            const SizedBox(height: 12),
            Text('What you said · ${_selectedLanguage.name}', style: GoogleFonts.inter(fontSize: 10.5, color: AppColors.textSecondary, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(_originalTranscript!, style: GoogleFonts.inter(fontSize: 13, color: AppColors.textPrimary, height: 1.45)),
          ],
          if (_translatedEnglish != null) ...[
            const SizedBox(height: 12),
            Text('English question sent to Retail Mind', style: GoogleFonts.inter(fontSize: 10.5, color: AppColors.textSecondary, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(_translatedEnglish!, style: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF4338CA), fontWeight: FontWeight.w700, height: 1.45)),
          ],
        ],
      ),
    );
  }

  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFFECACA))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.error_outline_rounded, color: Color(0xFFDC2626), size: 20),
        const SizedBox(width: 9),
        Expanded(child: Text(message, style: GoogleFonts.inter(fontSize: 12.5, color: const Color(0xFF991B1B), height: 1.45))),
        IconButton(onPressed: () => setState(() => _errorMessage = null), icon: const Icon(Icons.close_rounded, size: 17, color: Color(0xFF991B1B)), visualDensity: VisualDensity.compact),
      ]),
    );
  }

  Widget _buildPrivacyNote() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.verified_user_outlined, color: Color(0xFF94A3B8), size: 14),
        const SizedBox(width: 6),
        Flexible(child: Text('Open-source speech models · no paid translation API', textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 10.5, color: AppColors.textTertiary, fontWeight: FontWeight.w500))),
      ],
    );
  }
}
