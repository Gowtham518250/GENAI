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
      backgroundColor: const Color(0xFFF3F6FC),
      appBar: AppBar(
        backgroundColor: const Color(0xFF203A68),
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
                gradient: LinearGradient(colors: [Color(0xFF7C3AED), Color(0xFF2563EB)]),
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
          if (MediaQuery.sizeOf(context).width >= 480)
            TextButton.icon(
              onPressed: _openHistory,
              icon: const Icon(Icons.history_rounded, size: 19),
              label: Text('Query History', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700)),
              style: TextButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
            )
          else
            IconButton(
              onPressed: _openHistory,
              tooltip: 'Query History',
              icon: const Icon(Icons.history_rounded, color: Colors.white),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1120;
            final tablet = constraints.maxWidth >= 760;
            final horizontalPadding = constraints.maxWidth >= 1400 ? 24.0 : constraints.maxWidth >= 760 ? 18.0 : 12.0;
            final mainContent = _buildMainContent(busy);
            final helperSidebar = _buildHelperSidebar();
            return SingleChildScrollView(
              controller: _scrollController,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(horizontalPadding, 20, horizontalPadding, 30),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1680),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(flex: 7, child: mainContent),
                            const SizedBox(width: 20),
                            Expanded(flex: 3, child: helperSidebar),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            mainContent,
                            if (tablet) ...[
                              const SizedBox(height: 18),
                              helperSidebar,
                            ],
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

  Widget _buildMainContent(bool busy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHero(),
        const SizedBox(height: 16),
        _buildLanguagePicker(),
        const SizedBox(height: 14),
        _buildPipelineHint(),
        const SizedBox(height: 20),
        Row(
          children: [
            const Icon(Icons.lightbulb_rounded, size: 20, color: Color(0xFFF59E0B)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Suggested questions',
                style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800, color: const Color(0xFF18284A)),
              ),
            ),
            Text('Quick prompts', style: GoogleFonts.inter(fontSize: 10.5, color: const Color(0xFF64748B), fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 10),
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
            ResultCard(results: _currentResponse!.results, queryContext: _currentResponse!.query),
          ],
        ],
        const SizedBox(height: 22),
        _buildPrivacyNote(),
      ],
    );
  }

  Widget _buildHelperSidebar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE1E8F5)),
            boxShadow: [BoxShadow(color: const Color(0xFF233E70).withValues(alpha: 0.055), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: const Color(0xFFEFF4FF), borderRadius: BorderRadius.circular(13)),
                    child: const Icon(Icons.track_changes_rounded, color: Color(0xFF2563EB), size: 21),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Try asking', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: const Color(0xFF17264A)))),
                ],
              ),
              const SizedBox(height: 14),
              _quickQuestionTile(icon: Icons.bar_chart_rounded, tint: const Color(0xFF2563EB), title: 'What were my total sales today?', query: 'How many sales did I make today?'),
              const SizedBox(height: 9),
              _quickQuestionTile(icon: Icons.inventory_2_rounded, tint: const Color(0xFF0891B2), title: 'Which items need reordering?', query: 'Show low stock items that need reordering'),
              const SizedBox(height: 9),
              _quickQuestionTile(icon: Icons.emoji_events_rounded, tint: const Color(0xFFF59E0B), title: 'Show my top-selling products', query: 'List my top 5 selling products this month'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFFE1E8F5)),
            boxShadow: [BoxShadow(color: const Color(0xFF233E70).withValues(alpha: 0.055), blurRadius: 24, offset: const Offset(0, 8))],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(color: const Color(0xFFEEF2FF), borderRadius: BorderRadius.circular(13)),
                    child: const Icon(Icons.settings_suggest_rounded, color: Color(0xFF6366F1), size: 21),
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: Text('How it works', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: const Color(0xFF17264A)))),
                ],
              ),
              const SizedBox(height: 17),
              _workflowRow(1, 'You speak or type', 'Use your preferred language'),
              const SizedBox(height: 14),
              _workflowRow(2, 'We convert to English', 'Open-source speech models'),
              const SizedBox(height: 14),
              _workflowRow(3, 'Search your shop data', 'RAG retrieves relevant data for your query'),
              const SizedBox(height: 14),
              _workflowRow(4, 'Get useful answers', 'Insights with results when available'),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(color: const Color(0xFFF0F8F4), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFD5EEE0))),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.verified_user_rounded, size: 24, color: Color(0xFF16A34A)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Your data stays private', style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: const Color(0xFF14532D))),
                          const SizedBox(height: 3),
                          Text('Your question is sent through your authenticated Retail Mind session.', style: GoogleFonts.inter(fontSize: 10.5, height: 1.45, color: const Color(0xFF47705A))),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _quickQuestionTile({
    required IconData icon,
    required Color tint,
    required String title,
    required String query,
  }) {
    return Material(
      color: const Color(0xFFF4F7FD),
      borderRadius: BorderRadius.circular(17),
      child: InkWell(
        borderRadius: BorderRadius.circular(17),
        onTap: () => _handleSuggestionTap(query),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(color: tint.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(13)),
                child: Icon(icon, color: tint, size: 21),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(title, style: GoogleFonts.inter(fontSize: 11.5, height: 1.4, fontWeight: FontWeight.w600, color: const Color(0xFF22345B))),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, color: Color(0xFF2563EB), size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _workflowRow(int number, String title, String subtitle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: const BoxDecoration(color: Color(0xFFEAF0FF), shape: BoxShape.circle),
          alignment: Alignment.center,
          child: Text('$number', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, color: const Color(0xFF2563EB))),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800, color: const Color(0xFF17264A))),
              const SizedBox(height: 3),
              Text(subtitle, style: GoogleFonts.inter(fontSize: 10.5, height: 1.35, color: const Color(0xFF64748B))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHero() {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFFFF), Color(0xFFF0F5FF), Color(0xFFF6F0FF)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFDDE7FA)),
        boxShadow: [
          BoxShadow(color: const Color(0xFF2B4F90).withValues(alpha: 0.065), blurRadius: 26, offset: const Offset(0, 9)),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 540;
          final titleSize = compact ? 23.0 : 31.0;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFFEAEFFF), Color(0xFFF1E8FF)]),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.auto_awesome_rounded, size: 15, color: Color(0xFF6D45E8)),
                        const SizedBox(width: 6),
                        Text('AI BUSINESS ASSISTANT', style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 0.55, color: const Color(0xFF5538C9))),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                    decoration: BoxDecoration(color: const Color(0xFFEAF8F0), borderRadius: BorderRadius.circular(999), border: Border.all(color: const Color(0xFFCBEED9))),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.circle, size: 7, color: Color(0xFF16A34A)),
                        const SizedBox(width: 6),
                        Text('Ready to help', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: const Color(0xFF167342))),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 15),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text.rich(
                          TextSpan(
                            style: GoogleFonts.inter(fontSize: titleSize, height: 1.08, fontWeight: FontWeight.w900, letterSpacing: -0.9, color: const Color(0xFF101D3C)),
                            children: const [
                              TextSpan(text: 'Ask your shop '),
                              TextSpan(text: 'anything', style: TextStyle(color: Color(0xFF2563EB))),
                            ],
                          ),
                        ),
                        const SizedBox(height: 9),
                        Text('Sales, stock, customers and invoices — in the language you speak.', style: GoogleFonts.inter(fontSize: compact ? 12 : 13.5, height: 1.5, fontWeight: FontWeight.w500, color: const Color(0xFF536584))),
                      ],
                    ),
                  ),
                  SizedBox(width: compact ? 8 : 18),
                  Container(
                    width: compact ? 62 : 104,
                    height: compact ? 62 : 104,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFDDEBFF), Color(0xFFEAE2FF)]),
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: const Color(0xFF6D5AE8).withValues(alpha: 0.15), blurRadius: 22, offset: const Offset(0, 8))],
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(Icons.graphic_eq_rounded, size: compact ? 35 : 58, color: const Color(0xFF3855EE)),
                        Positioned(
                          top: compact ? 9 : 15,
                          right: compact ? 9 : 16,
                          child: Icon(Icons.auto_awesome_rounded, size: compact ? 12 : 17, color: const Color(0xFF9747FF)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  _heroTag(Icons.check_circle_rounded, 'Useful insights', const Color(0xFF2563EB)),
                  _heroTag(Icons.language_rounded, 'Multilingual', const Color(0xFF0D9488)),
                  _heroTag(Icons.verified_user_rounded, 'Private session', const Color(0xFF16A34A)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _heroTag(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.13)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(label, style: GoogleFonts.inter(fontSize: 9.5, fontWeight: FontWeight.w700, color: const Color(0xFF435574))),
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
      (Icons.mic_none_rounded, 'Your voice', 'Speak or type'),
      (Icons.translate_rounded, 'English', 'Translate'),
      (Icons.storage_rounded, 'RAG + SQL', 'Search shop data'),
      (Icons.insights_rounded, 'Answer', 'Useful insights'),
    ];

    Widget stepCard(int index) {
      final item = items[index];
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FAFF),
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: const Color(0xFFE7ECFA)),
        ),
        child: Column(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [Color(0xFFE7EEFF), Color(0xFFF0E9FF)]),
                shape: BoxShape.circle,
              ),
              child: Icon(item.$1, color: const Color(0xFF4161E9), size: 20),
            ),
            const SizedBox(height: 5),
            Container(
              width: 19,
              height: 19,
              alignment: Alignment.center,
              decoration: const BoxDecoration(color: Color(0xFFE6EDFF), shape: BoxShape.circle),
              child: Text((index + 1).toString(), style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w800, color: const Color(0xFF3159D8))),
            ),
            const SizedBox(height: 5),
            Text(item.$2, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w800, color: const Color(0xFF17264A))),
            const SizedBox(height: 3),
            Text(item.$3, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 9.5, height: 1.3, color: const Color(0xFF71809B))),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFE1E8F5)),
        boxShadow: [
          BoxShadow(color: const Color(0xFF203A68).withValues(alpha: 0.035), blurRadius: 16, offset: const Offset(0, 5)),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 520) {
            final tileWidth = (constraints.maxWidth - 8) / 2;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < items.length; i++)
                  SizedBox(width: tileWidth, child: stepCard(i)),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < items.length; i++) ...[
                Expanded(child: stepCard(i)),
                if (i < items.length - 1)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Icons.chevron_right_rounded, size: 18, color: Color(0xFF9AA8C2)),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildComposer(bool busy) {
    final canAsk = _queryController.text.trim().isNotEmpty && !busy && !_isRecording;

    Widget voiceButton({required bool fullWidth}) {
      final button = OutlinedButton.icon(
        onPressed: busy ? null : (_isRecording ? _stopRecordingAndAsk : _startRecording),
        icon: Icon(_isRecording ? Icons.stop_circle_rounded : Icons.mic_rounded, size: 20),
        label: Text(_isRecording ? 'Stop recording · ${_recordSeconds}s' : 'Tap to speak', maxLines: 1, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          foregroundColor: _isRecording ? const Color(0xFFDC2626) : const Color(0xFF5546D8),
          backgroundColor: _isRecording ? const Color(0xFFFFF1F2) : const Color(0xFFF1EEFF),
          side: BorderSide(color: _isRecording ? const Color(0xFFFECACA) : const Color(0xFFDCD6FF)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          textStyle: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800),
        ),
      );
      return fullWidth ? SizedBox(width: double.infinity, child: button) : Expanded(child: button);
    }

    Widget askButton({required bool fullWidth}) {
      final button = ElevatedButton.icon(
        onPressed: canAsk ? () => _executeQuery(_queryController.text) : null,
        icon: const Icon(Icons.auto_awesome_rounded, size: 19),
        label: const Text('Ask Retail Mind'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF315FF4),
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0xFFBEC9F6),
          disabledForegroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 17),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          elevation: 0,
          textStyle: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w800),
        ),
      );
      return fullWidth ? SizedBox(width: double.infinity, child: button) : Expanded(child: button);
    }

    return Container(
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFDCE6F7)),
        boxShadow: [
          BoxShadow(color: const Color(0xFF203A68).withValues(alpha: 0.06), blurRadius: 23, offset: const Offset(0, 8)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: const Color(0xFFEFF2FF), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: Color(0xFF5B50E7)),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text('Ask a business question', style: GoogleFonts.inter(fontSize: 13, fontWeight: FontWeight.w800, color: const Color(0xFF17264A))),
              ),
              Text('TEXT OR VOICE', style: GoogleFonts.inter(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.55, color: const Color(0xFF8592AB))),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _queryController,
            focusNode: _inputFocusNode,
            enabled: !busy && !_isRecording,
            minLines: 2,
            maxLines: 5,
            textInputAction: TextInputAction.newline,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _executeQuery(_queryController.text),
            style: GoogleFonts.inter(fontSize: 14, height: 1.5, color: const Color(0xFF17264A), fontWeight: FontWeight.w500),
            decoration: InputDecoration(
              hintText: 'Ask about sales, revenue, customers, stock…',
              hintStyle: GoogleFonts.inter(fontSize: 13, color: const Color(0xFF9AA7BD), height: 1.5),
              prefixIcon: const Icon(Icons.auto_awesome_rounded, color: Color(0xFF6878E8), size: 20),
              filled: true,
              fillColor: const Color(0xFFF8FAFE),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE7ECF6))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFFE7ECF6))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF7287F8), width: 1.5)),
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 560;
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    voiceButton(fullWidth: true),
                    const SizedBox(height: 9),
                    askButton(fullWidth: true),
                  ],
                );
              }
              return Row(
                children: [
                  voiceButton(fullWidth: false),
                  const SizedBox(width: 12),
                  askButton(fullWidth: false),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock_outline_rounded, size: 14, color: Color(0xFF71809B)),
              const SizedBox(width: 6),
              Expanded(
                child: Text('Your question is translated to English before your shop data is queried.', style: GoogleFonts.inter(fontSize: 10, height: 1.4, color: const Color(0xFF71809B))),
              ),
              const SizedBox(width: 8),
              Text('${_queryController.text.length}/500', style: GoogleFonts.inter(fontSize: 10, fontWeight: FontWeight.w700, color: const Color(0xFF71809B))),
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
