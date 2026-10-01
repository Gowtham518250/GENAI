import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../visual_widgets.dart';
import '../models/ai_query_response.dart';
import '../services/ai_query_service.dart';
import '../widgets/ai_answer_card.dart';
import '../widgets/ai_loading_indicator.dart';
import '../widgets/query_history.dart';
import '../widgets/query_input.dart';
import '../widgets/result_card.dart';
import '../widgets/suggestion_chip.dart';

/// Production-ready screen for AI-powered Natural Language Business Queries ("Ask Retail Mind").
///
/// Enables shopkeepers to query sales, inventory, revenue, and customer metrics in plain language.
class AiQueryScreen extends StatefulWidget {
  final String? initialQuery;

  const AiQueryScreen({
    super.key,
    this.initialQuery,
  });

  @override
  State<AiQueryScreen> createState() => _AiQueryScreenState();
}

class _AiQueryScreenState extends State<AiQueryScreen> {
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocusNode = FocusNode();

  bool _isLoading = false;
  AIQueryResponse? _currentResponse;
  String? _errorMessage;
  List<AIQueryHistoryItem> _queryHistory = [];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    if (widget.initialQuery != null && widget.initialQuery!.trim().isNotEmpty) {
      _queryController.text = widget.initialQuery!.trim();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _executeQuery(widget.initialQuery!.trim());
      });
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    try {
      final history = await AiQueryService.fetchQueryHistory(limit: 200);
      if (mounted) {
        setState(() {
          _queryHistory = history;
        });
      }
    } catch (_) {
      // Keep a local fallback for an offline session.
      final local = await AiQueryService.getQueryHistory();
      if (!mounted) return;
      setState(() {
        _queryHistory = local
            .asMap()
            .entries
            .map(
              (entry) => AIQueryHistoryItem(
                id: -(entry.key + 1),
                question: entry.value,
                answer: 'Saved locally. Reconnect to load the complete answer history.',
                resultCount: 0,
                createdAt: DateTime.now(),
              ),
            )
            .toList();
      });
    }
  }

  Future<void> _executeQuery(String query) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty || _isLoading) return;

    // Dismiss soft keyboard
    _inputFocusNode.unfocus();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _queryController.text = cleanQuery;
    });

    // Auto-scroll to show loading indicator if needed
    _scrollToSection();

    try {
      final response = await AiQueryService.askQuery(cleanQuery);

      if (mounted) {
        setState(() {
          _isLoading = false;
          _currentResponse = response;
          if (!response.isSuccess) {
            _errorMessage = response.errorMessage ?? 'Unable to process query.';
          }
        });
        _loadHistory();
        _scrollToSection();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Retail Mind couldn\'t process that question right now. Please try again.';
        });
      }
    }
  }

  void _scrollToSection() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _handleSuggestionTap(String query) {
    _executeQuery(query);
  }

  void _handleHistoryTap(AIQueryHistoryItem item) {
    _queryController.text = item.question;
    _executeQuery(item.question);
  }

  Future<void> _handleRemoveHistoryItem(int historyId) async {
    if (historyId > 0) {
      try {
        await AiQueryService.deleteQueryHistory(historyId);
      } catch (_) {
        return;
      }
    }
    await _loadHistory();
  }

  Future<void> _handleClearHistory() async {
    try {
      await AiQueryService.clearRemoteQueryHistory();
    } catch (_) {
      await AiQueryService.clearQueryHistory();
    }
    await _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 20),
          onPressed: () => Navigator.pop(context),
          tooltip: 'Back',
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF6366F1), Color(0xFFA855F7)],
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.auto_awesome, color: Colors.white, size: 14),
            ),
            const SizedBox(width: 8),
            Text(
              'Ask Retail Mind',
              style: GoogleFonts.inter(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.2,
              ),
            ),
          ],
        ),
      ),
      body: AppBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double horizontalPadding = constraints.maxWidth > 650 ? 48.0 : 16.0;

              return SingleChildScrollView(
                controller: _scrollController,
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.fromLTRB(horizontalPadding, 12, horizontalPadding, 32),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // 1. HERO HEADER
                        _buildHeroHeader(),

                        const SizedBox(height: 20),

                        // 2. SUGGESTED QUESTIONS CHIPS
                        SuggestedQuestionsBar(
                          onSuggestionSelected: _handleSuggestionTap,
                          isLoading: _isLoading,
                        ),

                        const SizedBox(height: 16),

                        // 3. QUESTION INPUT CARD
                        QueryInputCard(
                          controller: _queryController,
                          focusNode: _inputFocusNode,
                          isLoading: _isLoading,
                          onSubmit: _executeQuery,
                        ),

                        const SizedBox(height: 20),

                        // 4. ERROR BANNER (if any)
                        if (_errorMessage != null && !_isLoading) ...[
                          _buildErrorBanner(_errorMessage!),
                          const SizedBox(height: 16),
                        ],

                        // 5. LOADING STATE
                        if (_isLoading) ...[
                          const AILoadingIndicator(),
                          const SizedBox(height: 20),
                        ],

                        // 6. ANSWER CARD & RESULT DETAILS
                        if (_currentResponse != null && !_isLoading && _currentResponse!.isSuccess) ...[
                          AIAnswerCard(response: _currentResponse!),
                          const SizedBox(height: 16),

                          if (_currentResponse!.hasResults) ...[
                            ResultCard(
                              results: _currentResponse!.results,
                              queryContext: _currentResponse!.query,
                            ),
                            const SizedBox(height: 20),
                          ],
                        ],

                        // 7. PERSISTENT QUERY HISTORY
                        if (_queryHistory.isNotEmpty && !_isLoading) ...[
                          const SizedBox(height: 8),
                          QueryHistoryView(
                            history: _queryHistory,
                            onSelectQuery: _handleHistoryTap,
                            onRemoveQuery: _handleRemoveHistoryItem,
                            onClearAll: _handleClearHistory,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Hero Header displaying clean branding and description
  Widget _buildHeroHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '✨',
                style: GoogleFonts.inter(fontSize: 22),
              ),
              const SizedBox(width: 8),
              Text(
                'AI Business Query',
                style: GoogleFonts.inter(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: AppColors.textPrimary,
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Ask anything about your shop in normal English',
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 13.5,
              fontWeight: FontWeight.w400,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// Shopkeeper-friendly Error Banner
  Widget _buildErrorBanner(String message) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFEF4444).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFEF4444).withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFEF4444),
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.inter(
                fontSize: 13.5,
                color: Colors.white.withValues(alpha: 0.95),
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () {
              setState(() {
                _errorMessage = null;
              });
            },
            icon: const Icon(Icons.close_rounded, size: 16, color: Colors.white60),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            splashRadius: 14,
          ),
        ],
      ),
    );
  }
}
