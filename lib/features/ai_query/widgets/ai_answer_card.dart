import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../models/ai_query_response.dart';
import '../../../visual_widgets.dart';

/// Answer card displaying the AI-generated answer, query timestamp, copy utility,
/// and an optional collapsible "Technical Details" section hiding raw SQL from shopkeepers.
class AIAnswerCard extends StatefulWidget {
  final AIQueryResponse response;

  const AIAnswerCard({
    super.key,
    required this.response,
  });

  @override
  State<AIAnswerCard> createState() => _AIAnswerCardState();
}

class _AIAnswerCardState extends State<AIAnswerCard> {
  bool _isTechnicalDetailsExpanded = false;

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$label copied to clipboard',
          style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        backgroundColor: const Color(0xFF1E293B),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF6366F1), width: 1),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final queryText = widget.response.query ?? 'Your Question';
    final answerText = widget.response.displayAnswer;
    final timeStr = DateFormat('dd MMM, hh:mm a').format(widget.response.timestamp);
    final hasSql = widget.response.hasSql;
    final effectiveSql = widget.response.effectiveSql;
    final version = widget.response.queryEngineVersion;
    final tables = widget.response.retrievedTableInformation;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: const Color(0xFF6366F1).withValues(alpha: 0.24),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: You asked & timestamp
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: AppColors.brandLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.help_outline_rounded,
                  size: 15,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'You asked:',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '"$queryText"',
                      style: GoogleFonts.inter(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                timeStr,
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          Divider(color: AppColors.divider, height: 1),
          const SizedBox(height: 16),

          // Primary AI Answer Section
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 16,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Retail Mind',
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                            color: const Color(0xFF818CF8),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.copy_rounded,
                            size: 16,
                            color: AppColors.textTertiary,
                          ),
                          onPressed: () => _copyToClipboard(context, answerText, 'Answer'),
                          tooltip: 'Copy Answer',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                          splashRadius: 16,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      answerText,
                      style: GoogleFonts.inter(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          // Optional Expandable Technical Details (Raw SQL hidden by default for clean shopkeeper experience)
          if (hasSql || version != null || tables.isNotEmpty) ...[
            const SizedBox(height: 16),
            InkWell(
              onTap: () {
                setState(() {
                  _isTechnicalDetailsExpanded = !_isTechnicalDetailsExpanded;
                });
              },
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isTechnicalDetailsExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: const Color(0xFF818CF8),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isTechnicalDetailsExpanded
                          ? 'Hide Technical Details'
                          : 'Show Technical Details',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF818CF8),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            if (_isTechnicalDetailsExpanded) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (version != null && version.isNotEmpty) ...[
                      Row(
                        children: [
                          Text(
                            'Engine:',
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 11,
                              color: Colors.white54,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF6366F1).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              version,
                              style: GoogleFonts.jetBrainsMono(
                                fontSize: 10.5,
                                color: const Color(0xFF818CF8),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                    ],

                    if (effectiveSql != null && effectiveSql.isNotEmpty) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'GENERATED SQL QUERY',
                            style: GoogleFonts.jetBrainsMono(
                              fontSize: 10.5,
                              letterSpacing: 0.8,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textSecondary,
                            ),
                          ),
                          InkWell(
                            onTap: () => _copyToClipboard(context, effectiveSql, 'SQL Query'),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Row(
                                children: [
                                  const Icon(Icons.copy_rounded, size: 13, color: Color(0xFF818CF8)),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Copy SQL',
                                    style: GoogleFonts.inter(
                                      fontSize: 11,
                                      color: const Color(0xFF818CF8),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF090D16),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                        ),
                        child: SelectableText(
                          effectiveSql,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 12,
                            color: const Color(0xFF38BDF8),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],

                    if (tables.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Retrieved Schema Context: ${tables.length} table(s)',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
