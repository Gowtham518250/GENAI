import 'live_translated_text.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'bank_reconciliation.dart';
import 'local_storage_service.dart';

class BankStatementParserPage extends StatefulWidget {
  const BankStatementParserPage({super.key});

  @override
  State<BankStatementParserPage> createState() => _BankStatementParserPageState();
}

class _BankStatementParserPageState extends State<BankStatementParserPage> {
  static const Color _primary = Color(0xFF6366F1);
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  
  List<BankEntry> _parsedEntries = [];
  List<Map<String, dynamic>> _appSales = [];
  List<Map<String, dynamic>> _matched = [];
  List<Map<String, dynamic>> _unmatched = [];
  bool _loading = false;
  String _status = 'Ready to parse PDF';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted) setState(() => _searchQuery = _searchController.text.trim().toLowerCase());
    });
    _loadAppSales();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadAppSales() async {
    final sales = await LocalStorageService.loadSales();
    if (!mounted) return;
    setState(() {
      _appSales = sales.map((s) => Map<String, dynamic>.from(s)).toList();
    });
  }

  bool _entryMatchesSearch(BankEntry entry, String query) =>
      BankStatementSearchMatcher.matches(entry, query);

  List<BankEntry> get _filteredEntries {
    final items = _parsedEntries
        .where((entry) => _entryMatchesSearch(entry, _searchQuery))
        .toList();
    items.sort((a, b) => b.date.compareTo(a.date));
    return items;
  }

  String _transactionKey(Map<String, dynamic> txn) => [
        txn['date']?.toString().split('T').first ?? '',
        txn['amount']?.toString() ?? '',
        txn['direction']?.toString() ?? '',
        txn['reference']?.toString() ?? '',
        txn['rawLine']?.toString() ?? '',
      ].join('|');

  Future<void> _parsePDF() async {
    setState(() {
      _loading = true;
      _status = 'Reading the PDF on this device...';
    });

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) {
        if (mounted) setState(() => _status = 'No file selected');
        return;
      }
      final filepath = result.files.single.path;
      if (filepath == null || filepath.isEmpty) {
        throw Exception('This file provider did not return a readable PDF path.');
      }

      final entries = await BankStatementParser.parsePDFFile(filepath);
      final bankTransactions = entries.map((entry) => entry.toJson()).toList();

      // Keep the latest uploaded statement local to this app account so Ask
      // Retail Mind can answer transaction questions without uploading private
      // bank rows to Groq or the backend database.
      final prefs = await SharedPreferences.getInstance();
      final rawUserId = prefs.get('user_id') ?? prefs.get('userId') ?? 'default';
      await prefs.setString(
        BankStatementQueryHelper.storageKeyForUserId(rawUserId.toString()),
        jsonEncode(bankTransactions),
      );

      final incoming = bankTransactions
          .where((txn) => txn['direction']?.toString() == 'CREDIT')
          .toList();
      final unmatched = BankReconciliation.reconcile(incoming, _appSales);
      final unmatchedKeys = unmatched.map(_transactionKey).toSet();
      final matched = incoming
          .where((txn) => !unmatchedKeys.contains(_transactionKey(txn)))
          .toList();

      if (!mounted) return;
      setState(() {
        _parsedEntries = entries;
        _matched = matched;
        _unmatched = unmatched;
        _searchController.clear();
        _searchQuery = '';
        final received = entries.fold<double>(0, (sum, entry) => sum + entry.receivedAmount);
        final paid = entries.fold<double>(0, (sum, entry) => sum + entry.paidAmount);
        _status = 'Parsed ' + entries.length.toString() + ' transactions locally. Received ₹' +
            received.toStringAsFixed(2) + '; paid ₹' + paid.toStringAsFixed(2) +
            '. Saved on this device for Ask Retail Mind questions.';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _parsedEntries = [];
          _matched = [];
          _unmatched = [];
          _status = error.toString().replaceFirst('Exception: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: LiveTranslatedText('Bank Statement Parser', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LiveTranslatedText('Status', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  LiveTranslatedText(_status, style: GoogleFonts.poppins(color: Colors.blue.shade800)),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // Parse Button
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _loading ? null : _parsePDF,
                icon: _loading 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.upload_file),
                label: LiveTranslatedText(_loading ? 'Processing...' : 'Select & Parse PDF'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Results
            if (_parsedEntries.isNotEmpty) ...[
              _buildResultsSection(),
            ],

            // Instructions
            if (_parsedEntries.isEmpty) ...[
              LiveTranslatedText('Instructions', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _buildInstructionCard(
                'Supported Banks',
                'HDFC, SBI, ICICI, AXIS, KOTAK Mahindra and PhonePe transaction statements',
                Icons.account_balance,
              ),
              const SizedBox(height: 12),
              _buildInstructionCard(
                'PDF Format',
                'Use a text-based PDF downloaded from bank net banking or your UPI app. PhonePe transaction statement PDFs are supported and parsed on this device.',
                Icons.picture_as_pdf,
              ),
              const SizedBox(height: 12),
              _buildInstructionCard(
                'Transaction History',
                'Search extracted UPI/NEFT/IMPS entries by name, UPI ID, phone or reference. See money received and money paid separately.',
                Icons.payment,
              ),
              const SizedBox(height: 12),
              _buildInstructionCard(
                'Ask Retail Mind about payments',
                'After parsing, ask questions such as “How much was credited by Rahul?” or “Show the phone number and payment details for Rahul.” Statement answers stay on this device.',
                Icons.chat_bubble_outline,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultsSection() {
    final visible = _filteredEntries;
    final received = visible.fold<double>(0, (sum, entry) => sum + entry.receivedAmount);
    final paid = visible.fold<double>(0, (sum, entry) => sum + entry.paidAmount);
    final net = received - paid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LiveTranslatedText('Statement Summary', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildSummaryCard('Received', '₹${received.toStringAsFixed(2)}', Colors.green, Icons.south_west_rounded)),
            const SizedBox(width: 10),
            Expanded(child: _buildSummaryCard('Paid', '₹${paid.toStringAsFixed(2)}', Colors.red, Icons.north_east_rounded)),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: net >= 0 ? Colors.green.shade50 : Colors.red.shade50,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: (net >= 0 ? Colors.green : Colors.red).withValues(alpha: 0.22)),
          ),
          child: Row(
            children: [
              Icon(net >= 0 ? Icons.account_balance_wallet_outlined : Icons.warning_amber_rounded,
                  color: net >= 0 ? Colors.green.shade800 : Colors.red.shade800),
              const SizedBox(width: 10),
              Expanded(child: LiveTranslatedText('Net flow for this search', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12))),
              LiveTranslatedText('₹${net.toStringAsFixed(2)}', style: GoogleFonts.poppins(fontWeight: FontWeight.w800, color: net >= 0 ? Colors.green.shade800 : Colors.red.shade800)),
            ],
          ),
        ),
        const SizedBox(height: 22),
        LiveTranslatedText('Search Transaction History', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hint: LiveTranslatedText('Search any name, UPI ID, phone or reference...'),
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: _searchController.clear,
                    icon: const Icon(Icons.close_rounded),
                  ),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 8),
        LiveTranslatedText('${visible.length} transaction(s) found', style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade600)),
        if (_searchQuery.isNotEmpty && visible.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildSearchAnalytics(visible),
        ],
        const SizedBox(height: 10),
        if (visible.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
            child: LiveTranslatedText(
              _searchQuery.isEmpty
                  ? 'No transactions were extracted.'
                  : 'No statement rows match “' + _searchController.text.trim() +
                      '”. Phone numbers can only be searched when present in the PDF; try the customer name or UTR/reference if they are not shown.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(color: Colors.grey.shade600),
            ),
          )
        else
          ...visible.map(_buildHistoryCard),

        const SizedBox(height: 24),
        LiveTranslatedText('Sale Reconciliation', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildSummaryCard('Incoming', _parsedEntries.where((e) => e.direction == 'CREDIT').length.toString(), Colors.blue, Icons.receipt)),
            const SizedBox(width: 10),
            Expanded(child: _buildSummaryCard('Matched sales', _matched.length.toString(), Colors.green, Icons.check_circle)),
            const SizedBox(width: 10),
            Expanded(child: _buildSummaryCard('Unmatched', _unmatched.length.toString(), Colors.orange, Icons.warning)),
          ],
        ),
        const SizedBox(height: 20),
        if (_matched.isNotEmpty) ...[
          LiveTranslatedText('✅ Matched Transactions', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green.shade800)),
          const SizedBox(height: 10),
          ..._matched.take(5).map((txn) => _buildTransactionCard(txn, true)),
          if (_matched.length > 5)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: LiveTranslatedText('+ ${_matched.length - 5} more matched transactions', style: GoogleFonts.poppins(color: Colors.green.shade600)),
            ),
          const SizedBox(height: 18),
        ],
        if (_unmatched.isNotEmpty) ...[
          LiveTranslatedText('⚠️ Incoming transactions not matched to a sale', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange.shade800)),
          const SizedBox(height: 10),
          ..._unmatched.map((txn) => _buildTransactionCard(txn, false)),
        ],
      ],
    );
  }

  Widget _buildSearchAnalytics(List<BankEntry> entries) {
    final credits = entries
        .where((entry) => entry.direction.toUpperCase() == 'CREDIT')
        .toList();
    final debits = entries
        .where((entry) => entry.direction.toUpperCase() == 'DEBIT')
        .toList();
    final creditedTotal = credits.fold<double>(0, (sum, entry) => sum + entry.amount);
    final paidTotal = debits.fold<double>(0, (sum, entry) => sum + entry.amount);
    final net = creditedTotal - paidTotal;
    final sorted = List<BankEntry>.from(entries)
      ..sort((a, b) => a.date.compareTo(b.date));

    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final monthly = <String, Map<String, dynamic>>{};
    for (final entry in entries) {
      final key = entry.date.year.toString() + '-' +
          entry.date.month.toString().padLeft(2, '0');
      final month = months[entry.date.month - 1] + ' ' + entry.date.year.toString();
      final bucket = monthly.putIfAbsent(
        key,
        () => <String, dynamic>{
          'key': key,
          'month': month,
          'credit_count': 0,
          'debit_count': 0,
          'credited_total': 0.0,
          'paid_total': 0.0,
        },
      );
      if (entry.direction.toUpperCase() == 'CREDIT') {
        bucket['credit_count'] = (bucket['credit_count'] as int) + 1;
        bucket['credited_total'] = (bucket['credited_total'] as double) + entry.amount;
      } else if (entry.direction.toUpperCase() == 'DEBIT') {
        bucket['debit_count'] = (bucket['debit_count'] as int) + 1;
        bucket['paid_total'] = (bucket['paid_total'] as double) + entry.amount;
      }
    }
    final monthsDescending = monthly.values.toList()
      ..sort((a, b) => (b['key'] as String).compareTo(a['key'] as String));

    Widget metric(String label, String value, Color color, IconData icon) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withValues(alpha: 0.16)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 19),
              const SizedBox(height: 7),
              LiveTranslatedText(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w800, color: color),
              ),
              const SizedBox(height: 2),
              LiveTranslatedText(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(fontSize: 10, height: 1.35, color: Colors.grey.shade700),
              ),
            ],
          ),
        ),
      );
    }

    final netColor = net >= 0 ? const Color(0xFF087F5B) : const Color(0xFFB42318);
    final query = _searchController.text.trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE0E7F2)),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF233B73).withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 39,
                height: 39,
                decoration: BoxDecoration(color: const Color(0xFFEDEAFF), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.insights_rounded, color: _primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LiveTranslatedText('Customer / Search Analytics',
                        style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w800)),
                    LiveTranslatedText(
                      'Matches for “' + query + '”',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(color: const Color(0xFFF0F3FA), borderRadius: BorderRadius.circular(20)),
                child: LiveTranslatedText(
                  entries.length.toString() + ' txns',
                  style: GoogleFonts.poppins(fontSize: 10, fontWeight: FontWeight.w700, color: const Color(0xFF4A5874)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              metric(
                'Credited · ' + credits.length.toString() + ' txns',
                '₹' + creditedTotal.toStringAsFixed(2),
                const Color(0xFF07845F),
                Icons.south_west_rounded,
              ),
              const SizedBox(width: 10),
              metric(
                'Paid · ' + debits.length.toString() + ' txns',
                '₹' + paidTotal.toStringAsFixed(2),
                const Color(0xFFC2414B),
                Icons.north_east_rounded,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: netColor.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(13),
              border: Border.all(color: netColor.withValues(alpha: 0.17)),
            ),
            child: Row(
              children: [
                Icon(Icons.account_balance_wallet_outlined, color: netColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: LiveTranslatedText(
                    'Net flow (credit − debit)',
                    style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600),
                  ),
                ),
                LiveTranslatedText(
                  (net < 0 ? '−' : '') + '₹' + net.abs().toStringAsFixed(2),
                  style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w800, color: netColor),
                ),
              ],
            ),
          ),
          if (sorted.isNotEmpty) ...[
            const SizedBox(height: 9),
            LiveTranslatedText(
              'Activity: ' + sorted.first.date.toIso8601String().split('T').first +
                  ' to ' + sorted.last.date.toIso8601String().split('T').first,
              style: GoogleFonts.poppins(color: Colors.grey.shade600, fontSize: 10),
            ),
          ],
          if (monthsDescending.isNotEmpty) ...[
            const SizedBox(height: 14),
            LiveTranslatedText('Monthly activity', style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w800)),
            const SizedBox(height: 7),
            ...monthsDescending.take(6).map((month) {
              final monthCredit = (month['credited_total'] as num).toDouble();
              final monthPaid = (month['paid_total'] as num).toDouble();
              return Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                decoration: BoxDecoration(color: const Color(0xFFF8FAFD), borderRadius: BorderRadius.circular(11)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LiveTranslatedText(month['month'].toString(), style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        LiveTranslatedText(
                          '+ ₹' + monthCredit.toStringAsFixed(2) + ' received (' + month['credit_count'].toString() + ')',
                          style: GoogleFonts.poppins(color: const Color(0xFF07845F), fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                        LiveTranslatedText(
                          '− ₹' + monthPaid.toStringAsFixed(2) + ' paid (' + month['debit_count'].toString() + ')',
                          style: GoogleFonts.poppins(color: const Color(0xFFC2414B), fontSize: 10, fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
          const SizedBox(height: 9),
          LiveTranslatedText(
            'Based only on transactions in this statement that match the search. Net flow does not automatically mean that either person owes money.',
            style: GoogleFonts.poppins(color: Colors.grey.shade600, fontSize: 9.5, height: 1.45),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard(BankEntry entry) {
    final isCredit = entry.direction == 'CREDIT';
    final color = isCredit ? Colors.green : Colors.red;
    final party = entry.counterparty.trim().isEmpty ? 'Unknown counterparty' : entry.counterparty.trim();
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.22)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: LiveTranslatedText(party, style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LiveTranslatedText('${isCredit ? 'Money received' : 'Money paid'}: ₹${entry.amount.toStringAsFixed(2)}'),
                LiveTranslatedText('Date: ${entry.date.toIso8601String().split('T').first}'),
                LiveTranslatedText('Direction: ${entry.direction}'),
                LiveTranslatedText('Bank: ${entry.bankName}'),
                if (entry.reference.isNotEmpty) LiveTranslatedText('Reference: ${entry.reference}'),
                const SizedBox(height: 8),
                LiveTranslatedText('Description: ${entry.description.isEmpty ? entry.rawLine : entry.description}'),
                const SizedBox(height: 8),
                LiveTranslatedText('Source row: ${entry.rawLine}', style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600)),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const LiveTranslatedText('Close')),
            ],
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                child: Icon(isCredit ? Icons.south_west_rounded : Icons.north_east_rounded, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LiveTranslatedText(party, style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 3),
                    LiveTranslatedText(
                      entry.description.isEmpty ? entry.rawLine : entry.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600),
                    ),
                    const SizedBox(height: 5),
                    LiveTranslatedText(
                      '${entry.date.toIso8601String().split('T').first} • ${entry.bankName}',
                      style: GoogleFonts.poppins(fontSize: 10, color: Colors.grey.shade500),
                    ),
                    if (entry.reference.isNotEmpty)
                      LiveTranslatedText('Ref: ${entry.reference}', maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(fontSize: 10, color: Colors.grey.shade500)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  LiveTranslatedText('${isCredit ? '+' : '-'}₹${entry.amount.toStringAsFixed(2)}',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.w800, color: color, fontSize: 13)),
                  LiveTranslatedText(isCredit ? 'RECEIVED' : 'PAID',
                      style: GoogleFonts.poppins(fontWeight: FontWeight.bold, color: color, fontSize: 9)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(String label, String value, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 8),
          LiveTranslatedText(value, style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          LiveTranslatedText(label, style: GoogleFonts.poppins(fontSize: 12, color: color.withValues(alpha: 0.8))),
        ],
      ),
    );
  }

  Widget _buildTransactionCard(Map<String, dynamic> txn, bool isMatched) {
    final amount = double.tryParse(txn['amount']?.toString() ?? '0') ?? 0;
    final date = txn['date']?.toString() ?? '';
    final reference = txn['reference']?.toString() ?? 'Unknown';
    
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isMatched ? Colors.green.shade50 : Colors.orange.shade50,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              isMatched ? Icons.check_circle : Icons.warning,
              color: isMatched ? Colors.green : Colors.orange,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LiveTranslatedText('₹${amount.toStringAsFixed(2)}', style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
                  LiveTranslatedText(reference, style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade600)),
                  LiveTranslatedText(date.split('T').first, style: GoogleFonts.poppins(fontSize: 10, color: Colors.grey.shade500)),
                ],
              ),
            ),
            if (!isMatched) ...[
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () => _addAsSale(txn),
                child: const LiveTranslatedText('Add as Sale'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  textStyle: GoogleFonts.poppins(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionCard(String title, String description, IconData icon) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
            color: _primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: _primary, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LiveTranslatedText(title, style: GoogleFonts.poppins(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                LiveTranslatedText(description, style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _addAsSale(Map<String, dynamic> txn) async {
    // Reconciliation actions are only offered for incoming credits.
    if ((txn['direction'] ?? 'CREDIT').toString().toUpperCase() != 'CREDIT') return;
    final sale = {
      'sale_id': 'BANK-${DateTime.now().millisecondsSinceEpoch}',
      'total': txn['amount'],
      'payment_method': 'BANK_TRANSFER',
      'customer_name': (txn['counterparty'] ?? txn['description'] ?? 'Bank Transaction').toString(),
      'date': txn['date'],
      'reference': txn['reference'],
      'rawLine': txn['rawLine'],
      'is_from_bank_statement': true,
      'created_at': DateTime.now().toIso8601String(),
    };

    // Add to local storage
    final sales = await LocalStorageService.loadSales();
    sales.add(sale);
    await LocalStorageService.saveSales(sales);

    // Remove from unmatched
    setState(() {
      _unmatched.remove(txn);
      _matched.add(txn);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LiveTranslatedText('Transaction added as sale'), backgroundColor: Colors.green),
    );
  }
}