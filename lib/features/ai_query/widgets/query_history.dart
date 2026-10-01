import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../models/ai_query_response.dart';

/// Persistent Q&A history for the authenticated shop owner.
class QueryHistoryView extends StatelessWidget {
  final List<AIQueryHistoryItem> history;
  final ValueChanged<AIQueryHistoryItem> onSelectQuery;
  final ValueChanged<int> onRemoveQuery;
  final VoidCallback onClearAll;

  const QueryHistoryView({
    super.key,
    required this.history,
    required this.onSelectQuery,
    required this.onRemoveQuery,
    required this.onClearAll,
  });

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    final date = '${local.day.toString().padLeft(2, '0')}/'
        '${local.month.toString().padLeft(2, '0')}/'
        '${local.year}';
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final meridiem = local.hour >= 12 ? 'PM' : 'AM';
    return '$date • $hour:$minute $meridiem';
  }

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              const Icon(
                Icons.history_rounded,
                size: 17,
                color: Color(0xFF818CF8),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Past Q&A History',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white.withValues(alpha: 0.9),
                  ),
                ),
              ),
              Text(
                '${history.length} saved',
                style: GoogleFonts.inter(
                  fontSize: 10.5,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: onClearAll,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white54,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Clear all'),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF111827).withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: history.length,
            separatorBuilder: (_, _) => Divider(
              color: Colors.white.withValues(alpha: 0.06),
              height: 1,
            ),
            itemBuilder: (context, index) {
              final item = history[index];
              return InkWell(
                onTap: () => onSelectQuery(item),
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 15, 10, 15),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: const Color(0xFF6366F1).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: const Icon(
                          Icons.forum_rounded,
                          size: 17,
                          color: Color(0xFFA5B4FC),
                        ),
                      ),
                      const SizedBox(width: 11),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.question,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.white.withValues(alpha: 0.95),
                                height: 1.35,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              item.answer,
                              maxLines: 5,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.68),
                                height: 1.45,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Text(
                                  _formatDate(item.createdAt),
                                  style: GoogleFonts.inter(
                                    fontSize: 9.5,
                                    color: Colors.white38,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                if (item.resultCount > 0)
                                  Text(
                                    '${item.resultCount} result(s)',
                                    style: GoogleFonts.inter(
                                      fontSize: 9.5,
                                      color: const Color(0xFF818CF8),
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 17,
                          color: Colors.white38,
                        ),
                        onPressed: () => onRemoveQuery(item.id),
                        tooltip: 'Delete this history entry',
                        splashRadius: 17,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
