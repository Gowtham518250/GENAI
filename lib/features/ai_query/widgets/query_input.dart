import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../visual_widgets.dart';

/// Production-ready Question Input Widget for AI Business Queries.
///
/// Features:
/// - Multi-line capability with auto-expanding height
/// - Quick clear button
/// - Glowing gradient [ ✨ Ask ] button
/// - Disabled states during query execution
/// - Prevents empty queries with soft visual feedback
class QueryInputCard extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String> onSubmit;
  final bool isLoading;
  final FocusNode? focusNode;

  const QueryInputCard({
    super.key,
    required this.controller,
    required this.onSubmit,
    this.isLoading = false,
    this.focusNode,
  });

  @override
  State<QueryInputCard> createState() => _QueryInputCardState();
}

class _QueryInputCardState extends State<QueryInputCard> {
  bool _hasText = false;
  late final FocusNode _internalFocusNode;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _internalFocusNode = widget.focusNode ?? FocusNode();
    _internalFocusNode.addListener(_handleFocusChange);
    widget.controller.addListener(_handleTextChange);
    _hasText = widget.controller.text.trim().isNotEmpty;
  }

  void _handleFocusChange() {
    setState(() {
      _isFocused = _internalFocusNode.hasFocus;
    });
  }

  void _handleTextChange() {
    final hasContent = widget.controller.text.trim().isNotEmpty;
    if (_hasText != hasContent) {
      setState(() {
        _hasText = hasContent;
      });
    }
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _internalFocusNode.dispose();
    } else {
      _internalFocusNode.removeListener(_handleFocusChange);
    }
    widget.controller.removeListener(_handleTextChange);
    super.dispose();
  }

  void _handleSubmit() {
    final text = widget.controller.text.trim();
    if (text.isEmpty || widget.isLoading) return;
    HapticFeedback.lightImpact();
    widget.onSubmit(text);
  }

  void _handleClear() {
    widget.controller.clear();
    setState(() {
      _hasText = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    const brandPrimary = Color(0xFF6366F1);
    const brandIndigo = Color(0xFF4F46E5);
    const lightSurface = AppColors.surface;

    final canSubmit = _hasText && !widget.isLoading;

    return Container(
      decoration: BoxDecoration(
        color: lightSurface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: _isFocused
              ? brandPrimary.withValues(alpha: 0.8)
              : AppColors.border,
          width: _isFocused ? 1.8 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: _isFocused
                ? brandPrimary.withValues(alpha: 0.14)
                : Colors.black.withValues(alpha: 0.06),
            blurRadius: _isFocused ? 16 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Input field row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: widget.controller,
                  focusNode: _internalFocusNode,
                  enabled: !widget.isLoading,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _handleSubmit(),
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w500,
                    height: 1.4,
                  ),
                  decoration: InputDecoration(
                    hintText: 'Ask about sales, revenue, customers, stock...',
                    hintStyle: GoogleFonts.inter(
                      fontSize: 14,
                      color: AppColors.textTertiary,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
              if (_hasText && !widget.isLoading) ...[
                IconButton(
                  onPressed: _handleClear,
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: AppColors.textTertiary,
                  ),
                  tooltip: 'Clear text',
                  splashRadius: 18,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          // Action footer row: hint & Send button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'e.g. "What were my sales yesterday?"',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  color: AppColors.textTertiary,
                  fontStyle: FontStyle.italic,
                ),
              ),
              ElevatedButton(
                onPressed: canSubmit ? _handleSubmit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: brandPrimary,
                  disabledBackgroundColor: brandIndigo.withValues(alpha: 0.3),
                  foregroundColor: Colors.white,
                  disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
                  elevation: canSubmit ? 4 : 0,
                  shadowColor: brandPrimary.withValues(alpha: 0.5),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: widget.isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.auto_awesome, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            'Ask',
                            style: GoogleFonts.inter(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
