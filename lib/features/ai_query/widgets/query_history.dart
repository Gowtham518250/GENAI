import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Local Query History list widget displaying recent questions asked by the shopkeeper.
class QueryHistoryView extends StatelessWidget {
  final List<String> history;
  final ValueChanged<String> onSelectQuery;
  final ValueChanged<String> onRemoveQuery;
  final VoidCallback onClearAll;

  const QueryHistoryView({
    super.key,
    required this.history,
    required this.onSelectQuery,
    required this.onRemoveQuery,
    required this.onClearAll,
  });

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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.history_rounded,
                    size: 16,
                    color: Color(0xFF818CF8),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Recent Queries',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.85),
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: onClearAll,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white54,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(
                  'Clear',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B).withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.1),
            ),
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
              final queryItem = history[index];
              return ListTile(
                onTap: () => onSelectQuery(queryItem),
                dense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
                leading: const Icon(
                  Icons.schedule_rounded,
                  size: 16,
                  color: Color(0xFF818CF8),
                ),
                title: Text(
                  queryItem,
                  style: GoogleFonts.inter(
                    fontSize: 13.5,
                    color: Colors.white.withValues(alpha: 0.9),
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: IconButton(
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: Colors.white38,
                  ),
                  onPressed: () => onRemoveQuery(queryItem),
                  tooltip: 'Remove',
                  splashRadius: 16,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  padding: EdgeInsets.zero,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
