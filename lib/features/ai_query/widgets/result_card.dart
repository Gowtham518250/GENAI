import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../visual_widgets.dart';

/// Reusable dynamic Result Card / Table widget for database query results.
///
/// Converts raw SQL / database rows into clean shopkeeper-friendly KPI cards
/// or structured data tables. Handles nulls, arbitrary column schemas, and formatted currency.
class ResultCard extends StatelessWidget {
  final List<dynamic> results;
  final String? queryContext;

  const ResultCard({
    super.key,
    required this.results,
    this.queryContext,
  });

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      return const SizedBox.shrink();
    }

    // Defensive check: filter for non-null items
    final safeRows = results.where((item) => item != null).toList();
    if (safeRows.isEmpty) {
      return const SizedBox.shrink();
    }

    // If single row with 1 or 2 metrics -> Render high-impact KPI Cards
    if (safeRows.length == 1 && safeRows.first is Map) {
      final map = safeRows.first as Map;
      if (map.isNotEmpty && map.length <= 2) {
        return _buildKpiSection(map);
      }
    }

    // If multiple rows or wide table -> Render structured tabular presentation
    return _buildTabularResults(context, safeRows);
  }

  /// Builds a high-impact KPI card for single-metric responses
  Widget _buildKpiSection(Map map) {
    final entries = map.entries.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            children: [
              const Icon(Icons.insights_rounded, size: 16, color: Color(0xFF818CF8)),
              const SizedBox(width: 6),
              Text(
                'Key Metric',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 500 && entries.length > 1;

            if (isWide) {
              return Row(
                children: entries.map((entry) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: _KpiMetricCard(
                        title: _humanizeLabel(entry.key.toString()),
                        value: entry.value,
                        rawKey: entry.key.toString(),
                        queryContext: queryContext,
                      ),
                    ),
                  );
                }).toList(),
              );
            }

            return Column(
              children: entries.map((entry) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _KpiMetricCard(
                    title: _humanizeLabel(entry.key.toString()),
                    value: entry.value,
                    rawKey: entry.key.toString(),
                    queryContext: queryContext,
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  /// Builds a modern scrollable data table for multi-row or multi-column results
  Widget _buildTabularResults(BuildContext context, List<dynamic> rows) {
    // Extract column keys dynamically from maps
    final Set<String> columnKeys = {};
    for (final row in rows) {
      if (row is Map) {
        for (final key in row.keys) {
          columnKeys.add(key.toString());
        }
      }
    }

    if (columnKeys.isEmpty) {
      // Primitive list fallback
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows.map((r) => Text('• $r', style: GoogleFonts.inter(color: Colors.white))).toList(),
        ),
      );
    }

    final columnsList = columnKeys.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.table_chart_outlined, size: 16, color: Color(0xFF818CF8)),
                  const SizedBox(width: 6),
                  Text(
                    'Result Details',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.brandLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${rows.length} ${rows.length == 1 ? "row" : "rows"}',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.brand,
                  ),
                ),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.of(context).size.width - 48,
              ),
              child: DataTable(
                headingRowColor: WidgetStateProperty.all(
                  const Color(0xFF0F172A).withValues(alpha: 0.9),
                ),
                headingRowHeight: 44,
                dataRowMinHeight: 48,
                dataRowMaxHeight: 64,
                horizontalMargin: 16,
                columnSpacing: 24,
                dividerThickness: 0.6,
                columns: columnsList.map((colKey) {
                  return DataColumn(
                    label: Text(
                      _humanizeLabel(colKey),
                      style: GoogleFonts.inter(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: AppColors.brand,
                        letterSpacing: 0.3,
                      ),
                    ),
                  );
                }).toList(),
                rows: List<DataRow>.generate(rows.length, (index) {
                  final rowItem = rows[index];
                  final isEven = index.isEven;

                  return DataRow(
                    color: WidgetStateProperty.all(
                      isEven
                          ? Colors.transparent
                          : Colors.white.withValues(alpha: 0.025),
                    ),
                    cells: columnsList.map((colKey) {
                      dynamic cellVal;
                      if (rowItem is Map) {
                        cellVal = rowItem[colKey];
                      }
                      return DataCell(
                        Text(
                          _formatCellValue(colKey, cellVal),
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: AppColors.textPrimary,
                            fontWeight: _isNumericOrAmount(colKey)
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      );
                    }).toList(),
                  );
                }),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Converts snake_case and camelCase column names into readable words
  /// e.g. `total_sales_amount` -> `Total Sales Amount`
  static String _humanizeLabel(String label) {
    if (label.isEmpty) return label;
    // Replace underscores and hyphens with spaces
    final withSpaces = label.replaceAll(RegExp(r'[_\\-]'), ' ');
    // Insert space before camelCase capitals
    final splitCamel = withSpaces.replaceAllMapped(
      RegExp(r'([a-z])([A-Z])'),
      (Match m) => '${m[1]} ${m[2]}',
    );

    // Title Case each word
    return splitCamel
        .split(' ')
        .where((word) => word.trim().isNotEmpty)
        .map((word) => word[0].toUpperCase() + word.substring(1).toLowerCase())
        .join(' ');
  }

  /// Formats currency and number values appropriately
  static String _formatCellValue(String key, dynamic value) {
    if (value == null) return '—';

    final lowerKey = key.toLowerCase();
    final isCurrency = lowerKey.contains('amount') ||
        lowerKey.contains('sales') ||
        lowerKey.contains('revenue') ||
        lowerKey.contains('price') ||
        lowerKey.contains('total') ||
        lowerKey.contains('cost') ||
        lowerKey.contains('balance') ||
        lowerKey.contains('value');

    if (value is num) {
      final numberFormat = NumberFormat.decimalPattern('en_IN');
      if (isCurrency && !lowerKey.contains('count') && !lowerKey.contains('qty') && !lowerKey.contains('quantity')) {
        return '₹${numberFormat.format(value)}';
      }
      return numberFormat.format(value);
    }

    final strVal = value.toString().trim();
    final parsedNum = num.tryParse(strVal);
    if (parsedNum != null) {
      final numberFormat = NumberFormat.decimalPattern('en_IN');
      if (isCurrency && !lowerKey.contains('count') && !lowerKey.contains('qty') && !lowerKey.contains('quantity')) {
        return '₹${numberFormat.format(parsedNum)}';
      }
      return numberFormat.format(parsedNum);
    }

    return strVal.isEmpty ? '—' : strVal;
  }

  static bool _isNumericOrAmount(String key) {
    final lower = key.toLowerCase();
    return lower.contains('amount') ||
        lower.contains('sales') ||
        lower.contains('count') ||
        lower.contains('qty') ||
        lower.contains('total') ||
        lower.contains('price');
  }
}

/// A large, visual KPI Card for primary metrics (e.g. Sales Count, Total Sales Amount)
class _KpiMetricCard extends StatelessWidget {
  final String title;
  final dynamic value;
  final String rawKey;
  final String? queryContext;

  const _KpiMetricCard({
    required this.title,
    required this.value,
    required this.rawKey,
    this.queryContext,
  });

  @override
  Widget build(BuildContext context) {
    final formattedValue = ResultCard._formatCellValue(rawKey, value);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFF6366F1).withValues(alpha: 0.22),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title.toUpperCase(),
                style: GoogleFonts.inter(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                  color: AppColors.brand,
                ),
              ),
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: AppColors.brandLight,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.trending_up_rounded,
                  size: 16,
                  color: Color(0xFF818CF8),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            formattedValue,
            style: GoogleFonts.inter(
              fontSize: 28,
              fontWeight: FontWeight.w800,
              color: AppColors.textPrimary,
              letterSpacing: -0.5,
            ),
          ),
          if (queryContext != null && queryContext!.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              queryContext!,
              style: GoogleFonts.inter(
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
