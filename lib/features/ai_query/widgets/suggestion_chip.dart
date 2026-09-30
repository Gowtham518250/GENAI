import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../visual_widgets.dart';

/// Data class representing a recommended business query template.
class QuerySuggestion {
  final String title;
  final String query;
  final IconData icon;
  final Color accentColor;

  const QuerySuggestion({
    required this.title,
    required this.query,
    required this.icon,
    required this.accentColor,
  });
}

/// Curated suggestions covering sales, revenue, inventory, customers, and invoices.
const List<QuerySuggestion> kDefaultQuerySuggestions = [
  QuerySuggestion(
    title: 'Sales today',
    query: 'How many sales did I make today?',
    icon: Icons.point_of_sale_rounded,
    accentColor: Color(0xFF6366F1),
  ),
  QuerySuggestion(
    title: 'Revenue today',
    query: 'What is my total sales amount today?',
    icon: Icons.currency_rupee_rounded,
    accentColor: Color(0xFF10B981),
  ),
  QuerySuggestion(
    title: 'Items sold',
    query: 'How many items did I sell today?',
    icon: Icons.shopping_bag_outlined,
    accentColor: Color(0xFF3B82F6),
  ),
  QuerySuggestion(
    title: 'Yesterday\'s sales',
    query: 'What were my sales yesterday?',
    icon: Icons.history_rounded,
    accentColor: Color(0xFF8B5CF6),
  ),
  QuerySuggestion(
    title: 'Total sales',
    query: 'Show my total sales',
    icon: Icons.analytics_outlined,
    accentColor: Color(0xFF06B6D4),
  ),
  QuerySuggestion(
    title: 'Top customers',
    query: 'Who are my top customers?',
    icon: Icons.people_outline_rounded,
    accentColor: Color(0xFFEC4899),
  ),
  QuerySuggestion(
    title: 'Low stock',
    query: 'What products are low in stock?',
    icon: Icons.inventory_2_outlined,
    accentColor: Color(0xFFF59E0B),
  ),
  QuerySuggestion(
    title: 'Monthly invoices',
    query: 'How many invoices did I create this month?',
    icon: Icons.receipt_long_rounded,
    accentColor: Color(0xFF14B8A6),
  ),
];

/// Horizontal scrollable chips bar displaying recommended questions.
class SuggestedQuestionsBar extends StatelessWidget {
  final ValueChanged<String> onSuggestionSelected;
  final bool isLoading;

  const SuggestedQuestionsBar({
    super.key,
    required this.onSuggestionSelected,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  size: 14,
                  color: Color(0xFF818CF8),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'Suggested Questions',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: kDefaultQuerySuggestions.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final suggestion = kDefaultQuerySuggestions[index];
              return _SuggestionChipItem(
                suggestion: suggestion,
                onTap: isLoading ? null : () => onSuggestionSelected(suggestion.query),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SuggestionChipItem extends StatelessWidget {
  final QuerySuggestion suggestion;
  final VoidCallback? onTap;

  const _SuggestionChipItem({
    required this.suggestion,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isEnabled = onTap != null;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        splashColor: suggestion.accentColor.withValues(alpha: 0.25),
        highlightColor: suggestion.accentColor.withValues(alpha: 0.1),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: isEnabled ? 1.0 : 0.5,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: suggestion.accentColor.withValues(alpha: 0.28),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  suggestion.icon,
                  size: 16,
                  color: suggestion.accentColor,
                ),
                const SizedBox(width: 8),
                Text(
                  suggestion.title,
                  style: GoogleFonts.inter(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
