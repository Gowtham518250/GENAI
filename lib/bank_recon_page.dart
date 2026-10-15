import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'api_client.dart';
import 'bank_reconciliation_payload.dart';

class BankReconPage extends StatefulWidget {
  const BankReconPage({super.key});

  @override
  State<BankReconPage> createState() => _BankReconPageState();
}

class _BankReconPageState extends State<BankReconPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _loading = true;
  bool _submitting = false;
  String? _loadError;
  List<Map<String, dynamic>> _records = [];

  final _expectedUpiC = TextEditingController();
  final _actualDepositC = TextEditingController();
  final _notesC = TextEditingController();
  DateTime _selectedDate = DateTime.now();

  static const _bg = Color(0xFF111827);
  static const _card = Color(0xFF1F2937);
  static const _ink = Color(0xFFF9FAFB);
  static const _muted = Color(0xFF9CA3AF);
  static const _accent = Color(0xFFFBBF24);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _fetchRecords();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _expectedUpiC.dispose();
    _actualDepositC.dispose();
    _notesC.dispose();
    super.dispose();
  }

  Future<void> _fetchRecords() async {
    if (mounted) setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final res = await ApiClient.getJson('/bank-recon');
      final decoded = jsonDecode(res.body);
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final detail = decoded is Map ? decoded['detail']?.toString() : null;
        throw Exception(detail?.trim().isNotEmpty == true
            ? detail
            : 'Could not load reconciliation history (HTTP ' +
                res.statusCode.toString() +
                ').');
      }
      final rawRecords = decoded is Map ? decoded['records'] : decoded;
      final records = rawRecords is List
          ? rawRecords
              .whereType<Map>()
              .map((record) => Map<String, dynamic>.from(record))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    Map<String, dynamic> payload;
    try {
      payload = BankReconciliationPayload.build(
        reconDate: _selectedDate,
        expectedUpiAmount: _expectedUpiC.text,
        actualBankDeposit: _actualDepositC.text,
        notes: _notesC.text,
      );
    } on FormatException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
      return;
    }

    if (mounted) setState(() => _submitting = true);
    try {
      final res = await ApiClient.postJson('/bank-recon', payload);
      dynamic decoded;
      try {
        decoded = jsonDecode(res.body);
      } catch (_) {
        decoded = null;
      }
      if (res.statusCode < 200 || res.statusCode >= 300) {
        final detail = decoded is Map ? decoded['detail']?.toString() : null;
        throw Exception(detail?.trim().isNotEmpty == true
            ? detail
            : 'Reconciliation was not saved (HTTP ' +
                res.statusCode.toString() +
                '). Your entries have been kept so you can retry.');
      }

      final duplicate = decoded is Map && decoded['duplicate'] == true;
      _expectedUpiC.clear();
      _actualDepositC.clear();
      _notesC.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(duplicate
              ? 'This submission was already saved. No duplicate record was created.'
              : 'Reconciliation saved.'),
        ),
      );
      _tabController.animateTo(0);
      await _fetchRecords();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not confirm the save. You can retry the same values safely. ' +
                  error.toString().replaceFirst('Exception: ', ''),
            ),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _money(dynamic raw) {
    final value = raw is num ? raw.toDouble() : double.tryParse(raw?.toString() ?? '');
    return '₹' + (value ?? 0).toStringAsFixed(2);
  }

  String _date(dynamic raw) {
    final value = DateTime.tryParse(raw?.toString() ?? '');
    if (value == null) return raw?.toString() ?? 'Date unavailable';
    return value.year.toString().padLeft(4, '0') +
        '-' +
        value.month.toString().padLeft(2, '0') +
        '-' +
        value.day.toString().padLeft(2, '0');
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool numeric = false,
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        style: const TextStyle(color: _ink),
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          labelStyle: const TextStyle(color: _muted),
          helperStyle: const TextStyle(color: _muted, fontSize: 11),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.055),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
        ),
      ),
    );
  }

  Widget _recordCard(Map<String, dynamic> record) {
    final status = (record['status'] ?? 'PENDING').toString().toUpperCase();
    final matched = status == 'MATCHED';
    final color = matched ? const Color(0xFF34D399) : const Color(0xFFF87171);
    final difference = record['difference'];
    final notes = (record['notes'] ?? '').toString().trim();
    return Container(
      margin: const EdgeInsets.only(bottom: 11),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withValues(alpha: 0.32)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
            matched ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
            color: color,
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              _date(record['date']),
              style: GoogleFonts.poppins(
                color: _ink,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status,
              style: GoogleFonts.poppins(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        _recordLine('Expected UPI collections', _money(record['expected_upi_amount'] ?? record['expected_upi'])),
        const SizedBox(height: 5),
        _recordLine('Actual bank deposit', _money(record['actual_bank_deposit'] ?? record['actual_bank'])),
        const SizedBox(height: 5),
        _recordLine('Difference', _money(difference), valueColor: color),
        if (notes.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            'Audit note: ' + notes,
            style: GoogleFonts.poppins(color: _muted, fontSize: 11, height: 1.4),
          ),
        ],
        if ((record['created_at'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            'Recorded at ' + record['created_at'].toString().replaceFirst('T', ' '),
            style: GoogleFonts.poppins(color: _muted, fontSize: 9),
          ),
        ],
      ]),
    );
  }

  Widget _recordLine(String label, String value, {Color? valueColor}) {
    return Row(children: [
      Expanded(
        child: Text(
          label,
          style: GoogleFonts.poppins(color: _muted, fontSize: 11),
        ),
      ),
      Text(
        value,
        style: GoogleFonts.poppins(
          color: valueColor ?? _ink,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _card,
        foregroundColor: _ink,
        title: Text(
          'Bank Reconciliation',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w800),
        ),
        bottom: TabBar(
          controller: _tabController,
          labelColor: _accent,
          unselectedLabelColor: _muted,
          indicatorColor: _accent,
          tabs: const [Tab(text: 'History'), Tab(text: 'New check')],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator(color: _accent))
              : RefreshIndicator(
                  onRefresh: _fetchRecords,
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_loadError != null) ...[
                        Text(
                          _loadError!,
                          style: GoogleFonts.poppins(
                            color: const Color(0xFFFCA5A5),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _fetchRecords,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Retry loading history'),
                        ),
                      ],
                      if (_records.isEmpty && _loadError == null)
                        Padding(
                          padding: const EdgeInsets.only(top: 42),
                          child: Column(children: [
                            const Icon(Icons.account_balance_rounded, color: _muted, size: 40),
                            const SizedBox(height: 10),
                            Text(
                              'No reconciliation records yet',
                              style: GoogleFonts.poppins(color: _muted),
                            ),
                          ]),
                        )
                      else
                        ..._records.map(_recordCard),
                    ],
                  ),
                ),
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Compare UPI collections with the bank deposit',
                  style: GoogleFonts.poppins(
                    color: _ink,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 7),
                Text(
                  'Enter values from your payment records and bank statement. Differences are saved with an audit note; a matching retry will not create another record.',
                  style: GoogleFonts.poppins(
                    color: _muted,
                    fontSize: 11,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 18),
                _field(
                  _expectedUpiC,
                  'Expected UPI collections (₹)',
                  numeric: true,
                  helper: 'Total recorded UPI/online collections for this date.',
                ),
                _field(
                  _actualDepositC,
                  'Actual bank deposit (₹)',
                  numeric: true,
                ),
                _field(
                  _notesC,
                  'Audit note / bank reference (optional)',
                ),
                ListTile(
                  tileColor: Colors.white.withValues(alpha: 0.055),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  leading: const Icon(Icons.calendar_today_rounded, color: _accent),
                  title: Text(
                    'Reconciliation date: ' +
                        BankReconciliationPayload.dateString(_selectedDate),
                    style: const TextStyle(color: _ink, fontSize: 13),
                  ),
                  trailing: const Icon(Icons.edit_calendar_rounded, color: _muted),
                  onTap: _submitting
                      ? null
                      : () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _selectedDate,
                            firstDate: DateTime(2020),
                            lastDate: DateTime.now().add(const Duration(days: 3650)),
                          );
                          if (picked != null && mounted) {
                            setState(() => _selectedDate = picked);
                          }
                        },
                ),
                const SizedBox(height: 12),
                Text(
                  'The backend marks differences below ₹1.00 as matched. Review bank fees, refunds and settlement delays in the audit note.',
                  style: GoogleFonts.poppins(
                    color: _muted,
                    fontSize: 10,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black,
                            ),
                          )
                        : const Icon(Icons.fact_check_rounded),
                    label: Text(
                      _submitting ? 'Saving…' : 'Save reconciliation',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
