import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../../../visual_widgets.dart';
import '../models/ai_query_response.dart';
import '../services/ai_query_service.dart';

/// Dedicated, searchable dashboard for previous Ask Retail Mind queries.
class AiQueryHistoryScreen extends StatefulWidget {
  const AiQueryHistoryScreen({super.key});

  @override
  State<AiQueryHistoryScreen> createState() => _AiQueryHistoryScreenState();
}

class _AiQueryHistoryScreenState extends State<AiQueryHistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  List<AIQueryHistoryItem> _history = [];
  bool _loading = true;
  bool _usingLocalHistory = false;
  String? _error;
  String _category = 'All';
  String _period = 'All time';

  static const List<String> _categories = [
    'All', 'Sales', 'Stock', 'Customers', 'Invoices', 'Revenue', 'Reports',
  ];
  static const List<String> _periods = [
    'All time', 'Today', 'Last 7 days', 'This month',
  ];

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final history = await AiQueryService.fetchQueryHistory(limit: 500);
      if (!mounted) return;
      setState(() {
        _history = history;
        _usingLocalHistory = false;
        _loading = false;
      });
    } catch (_) {
      final local = await AiQueryService.getQueryHistory();
      if (!mounted) return;
      setState(() {
        _history = local.asMap().entries.map((entry) => AIQueryHistoryItem(
          id: -(entry.key + 1),
          question: entry.value,
          answer: 'Question saved on this device. Reconnect to see the complete answer.',
          resultCount: 0,
          createdAt: DateTime.now().subtract(Duration(minutes: entry.key)),
        )).toList();
        _usingLocalHistory = true;
        _loading = false;
        if (local.isEmpty) _error = 'Could not load query history. Check your connection and try again.';
      });
    }
  }

  String _categoryFor(AIQueryHistoryItem item) {
    final text = '${item.question} ${item.answer}'.toLowerCase();
    if (RegExp(r'\b(stock|inventory|product|products|low stock|quantity|items left)\b').hasMatch(text)) return 'Stock';
    if (RegExp(r'\b(customer|customers|buyer|buyers)\b').hasMatch(text)) return 'Customers';
    if (RegExp(r'\b(invoice|invoices|bill|bills|payment due|pending payment)\b').hasMatch(text)) return 'Invoices';
    if (RegExp(r'\b(revenue|profit|income|sales amount|turnover)\b').hasMatch(text)) return 'Revenue';
    if (RegExp(r'\b(sales|sold|orders|order count)\b').hasMatch(text)) return 'Sales';
    return 'Reports';
  }

  List<AIQueryHistoryItem> get _filteredHistory {
    final query = _searchController.text.trim().toLowerCase();
    final now = DateTime.now();
    return _history.where((item) {
      final categoryMatch = _category == 'All' || _categoryFor(item) == _category;
      final searchMatch = query.isEmpty ||
          item.question.toLowerCase().contains(query) ||
          item.answer.toLowerCase().contains(query);
      final age = now.difference(item.createdAt.toLocal());
      var periodMatch = true;
      switch (_period) {
        case 'Today':
          periodMatch = item.createdAt.toLocal().year == now.year &&
              item.createdAt.toLocal().month == now.month &&
              item.createdAt.toLocal().day == now.day;
          break;
        case 'Last 7 days':
          periodMatch = !age.isNegative && age <= const Duration(days: 7);
          break;
        case 'This month':
          periodMatch = item.createdAt.toLocal().year == now.year &&
              item.createdAt.toLocal().month == now.month;
          break;
        default:
          periodMatch = true;
      }
      return categoryMatch && searchMatch && periodMatch;
    }).toList();
  }

  Future<void> _remove(AIQueryHistoryItem item) async {
    try {
      if (item.id > 0) {
        await AiQueryService.deleteQueryHistory(item.id);
      } else {
        await AiQueryService.removeHistoryItem(item.question);
      }
      await _loadHistory();
    } catch (_) {
      if (mounted) _showMessage('Could not delete this item. Please try again.');
    }
  }

  Future<void> _clearAll() async {
    if (_history.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear query history?'),
        content: const Text('This removes your saved Ask Retail Mind history. This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Clear history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      if (_usingLocalHistory) {
        await AiQueryService.clearQueryHistory();
      } else {
        await AiQueryService.clearRemoteQueryHistory();
      }
      await _loadHistory();
    } catch (_) {
      if (mounted) _showMessage('Could not clear history. Please try again.');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredHistory;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 19),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: const BoxDecoration(
                color: Color(0xFF6D65E8),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.history_rounded, color: Colors.white, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Query History', style: GoogleFonts.inter(fontSize: 16, color: Colors.white, fontWeight: FontWeight.w800)),
                  Text('Search and revisit previous answers', style: GoogleFonts.inter(fontSize: 10.5, color: Colors.white70, fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _loadHistory,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
          ),
          IconButton(
            onPressed: _clearAll,
            tooltip: 'Clear all history',
            icon: const Icon(Icons.delete_sweep_outlined, color: Colors.white),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadHistory,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 32),
            children: [
              _buildOverviewCard(filtered.length),
              const SizedBox(height: 16),
              _buildSearchBox(),
              const SizedBox(height: 12),
              _buildPeriodPicker(),
              const SizedBox(height: 12),
              SizedBox(
                height: 38,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: _categories.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final category = _categories[index];
                    final active = category == _category;
                    return ChoiceChip(
                      label: Text(category),
                      selected: active,
                      onSelected: (_) => setState(() => _category = category),
                      selectedColor: const Color(0xFFE9E6FF),
                      backgroundColor: Colors.white,
                      side: BorderSide(color: active ? const Color(0xFF968BFF) : const Color(0xFFE0E7F1)),
                      labelStyle: GoogleFonts.inter(fontSize: 11.5, fontWeight: active ? FontWeight.w800 : FontWeight.w600, color: active ? const Color(0xFF4F46E5) : const Color(0xFF334155)),
                      shape: const StadiumBorder(),
                      showCheckmark: false,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                    );
                  },
                ),
              ),
              if (_usingLocalHistory) ...[
                const SizedBox(height: 12),
                _buildInfoBanner('Offline fallback: showing locally saved questions only. Reconnect to load full answers.'),
              ],
              if (_loading) ...[
                const SizedBox(height: 28),
                const Center(child: CircularProgressIndicator(color: Color(0xFF635BEB))),
              ] else if (_error != null) ...[
                const SizedBox(height: 26),
                _buildEmptyState(Icons.cloud_off_rounded, 'History unavailable', _error!),
              ] else if (filtered.isEmpty) ...[
                const SizedBox(height: 26),
                _buildEmptyState(Icons.search_off_rounded, 'No matching questions', 'Try another keyword, category or time range.'),
              ] else ...[
                const SizedBox(height: 18),
                Row(
                  children: [
                    Text('YOUR QUESTIONS', style: GoogleFonts.inter(fontSize: 10.5, letterSpacing: 1.0, fontWeight: FontWeight.w800, color: AppColors.textSecondary)),
                    const Spacer(),
                    Text('${filtered.length} result${filtered.length == 1 ? '' : 's'}', style: GoogleFonts.inter(fontSize: 11, color: AppColors.textTertiary, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 10),
                ...filtered.map(_buildHistoryCard),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverviewCard(int visibleCount) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF1B3A6B), Color(0xFF303A8B), Color(0xFF5B46D6)]),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [BoxShadow(color: const Color(0xFF28367D).withValues(alpha: 0.16), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 30),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Your business questions', style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
              const SizedBox(height: 4),
              Text('Tap any question to run it again and refresh the result.', style: GoogleFonts.inter(fontSize: 11.5, height: 1.4, color: Colors.white.withValues(alpha: 0.82))),
            ]),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('$visibleCount', style: GoogleFonts.inter(fontSize: 25, fontWeight: FontWeight.w900, color: Colors.white)),
            Text('shown', style: GoogleFonts.inter(fontSize: 10, color: Colors.white70)),
          ]),
        ],
      ),
    );
  }

  Widget _buildSearchBox() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE1E7F0))),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search past questions and answers…',
          hintStyle: GoogleFonts.inter(fontSize: 12.5, color: AppColors.textTertiary),
          prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF7367E8)),
          suffixIcon: _searchController.text.isEmpty ? null : IconButton(onPressed: _searchController.clear, icon: const Icon(Icons.close_rounded, size: 18)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }

  Widget _buildPeriodPicker() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE1E7F0))),
      child: Row(
        children: [
          const Icon(Icons.calendar_month_rounded, size: 18, color: Color(0xFF64748B)),
          const SizedBox(width: 10),
          Expanded(child: Text('Time range', style: GoogleFonts.inter(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.textSecondary))),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _period,
              items: _periods.map((value) => DropdownMenuItem(value: value, child: Text(value, style: GoogleFonts.inter(fontSize: 12, fontWeight: FontWeight.w700)))).toList(),
              onChanged: (value) { if (value != null) setState(() => _period = value); },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard(AIQueryHistoryItem item) {
    final category = _categoryFor(item);
    final color = _colorFor(category);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE4EAF3)),
        boxShadow: [BoxShadow(color: const Color(0xFF102A56).withValues(alpha: 0.035), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => Navigator.pop(context, item.question),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 8, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                child: Icon(_iconFor(category), color: color, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text(item.question, maxLines: 3, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 13, height: 1.35, color: const Color(0xFF17233E), fontWeight: FontWeight.w800))),
                    const SizedBox(width: 7),
                    _categoryPill(category, color),
                  ]),
                  const SizedBox(height: 7),
                  Text(item.answer, maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.inter(fontSize: 11.5, height: 1.4, color: AppColors.textSecondary)),
                  const SizedBox(height: 9),
                  Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(DateFormat('dd MMM yyyy · h:mm a').format(item.createdAt.toLocal()), style: GoogleFonts.inter(fontSize: 9.5, color: AppColors.textTertiary, fontWeight: FontWeight.w500)),
                    if (item.resultCount > 0)
                      Text('${item.resultCount} result${item.resultCount == 1 ? '' : 's'}', style: GoogleFonts.inter(fontSize: 10, color: const Color(0xFF6257D9), fontWeight: FontWeight.w800)),
                  ]),
                ]),
              ),
              IconButton(
                onPressed: () => _remove(item),
                icon: const Icon(Icons.more_vert_rounded, color: Color(0xFF94A3B8)),
                tooltip: 'Delete query',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _categoryPill(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(30)),
    child: Text(text, style: GoogleFonts.inter(fontSize: 9.5, color: color, fontWeight: FontWeight.w800)),
  );

  Widget _buildInfoBanner(String message) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(13), border: Border.all(color: const Color(0xFFFDE68A))),
    child: Row(children: [
      const Icon(Icons.info_outline_rounded, color: Color(0xFFB45309), size: 18),
      const SizedBox(width: 8),
      Expanded(child: Text(message, style: GoogleFonts.inter(fontSize: 11, color: const Color(0xFF92400E), height: 1.4))),
    ]),
  );

  Widget _buildEmptyState(IconData icon, String title, String message) => Container(
    margin: const EdgeInsets.only(top: 14),
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 34),
    decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0xFFE4EAF3))),
    child: Column(children: [
      Icon(icon, size: 36, color: const Color(0xFF9CA3AF)),
      const SizedBox(height: 12),
      Text(title, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
      const SizedBox(height: 6),
      Text(message, textAlign: TextAlign.center, style: GoogleFonts.inter(fontSize: 12, height: 1.45, color: AppColors.textSecondary)),
      const SizedBox(height: 12),
      OutlinedButton.icon(onPressed: _loadHistory, icon: const Icon(Icons.refresh_rounded, size: 17), label: const Text('Try again')),
    ]),
  );

  Color _colorFor(String category) {
    switch (category) {
      case 'Sales': return const Color(0xFF2563EB);
      case 'Stock': return const Color(0xFF059669);
      case 'Customers': return const Color(0xFF7C3AED);
      case 'Invoices': return const Color(0xFFDB2777);
      case 'Revenue': return const Color(0xFFD97706);
      default: return const Color(0xFF6366F1);
    }
  }

  IconData _iconFor(String category) {
    switch (category) {
      case 'Sales': return Icons.bar_chart_rounded;
      case 'Stock': return Icons.inventory_2_outlined;
      case 'Customers': return Icons.people_alt_outlined;
      case 'Invoices': return Icons.receipt_long_rounded;
      case 'Revenue': return Icons.currency_rupee_rounded;
      default: return Icons.forum_outlined;
    }
  }
}
