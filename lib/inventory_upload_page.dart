import 'live_translated_text.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import 'api_client.dart';
import 'loading_states.dart';

/// Inventory importer: extract, normalize, review, and only then confirm writes.
class InventoryUploadPage extends StatefulWidget {
  const InventoryUploadPage({super.key});

  @override
  State<InventoryUploadPage> createState() => _InventoryUploadPageState();
}

class _InventoryUploadPageState extends State<InventoryUploadPage> {
  static const Color _accent = Color(0xFF6366F1);
  static const List<String> _allowedExtensions = [
    'csv', 'xlsx', 'xls', 'json', 'txt',
    'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'tif', 'tiff',
  ];

  File? _selectedFile;
  String? _selectedFileName;
  bool _isBusy = false;
  bool _hasPreview = false;
  String _uploadMessage = '';
  String _uploadStatus = '';
  List<Map<String, dynamic>> _previewRows = [];
  Map<String, dynamic> _columnMapping = {};
  List<String> _warnings = [];
  final List<UploadHistory> _uploadHistory = [];

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _allowedExtensions,
        allowMultiple: false,
      );
      if (result == null || result.files.isEmpty) return;
      final picked = result.files.first;
      if (picked.path == null || picked.path!.isEmpty) {
        throw Exception('Save this file to your device and try again.');
      }
      setState(() {
        _selectedFile = File(picked.path!);
        _selectedFileName = picked.name;
        _hasPreview = false;
        _previewRows = [];
        _columnMapping = {};
        _warnings = [];
        _uploadMessage = '';
        _uploadStatus = '';
      });
    } catch (error) {
      _showMessage(_readableError(error), 'error');
    }
  }

  Future<void> _analyzeFile() async {
    if (_selectedFile == null) {
      _showMessage('Choose a file first.', 'error');
      return;
    }
    setState(() {
      _isBusy = true;
      _uploadMessage = '';
      _uploadStatus = '';
    });
    try {
      final streamed = await ApiClient.postMultipart(
        ApiClient.inventoryPrefix + '/upload/preview',
        const <String, String>{},
        files: [
          await http.MultipartFile.fromPath(
            'file',
            _selectedFile!.path,
            filename: _selectedFileName ?? _selectedFile!.path.split(Platform.pathSeparator).last,
          ),
        ],
        timeout: const Duration(seconds: 100),
      );
      final body = await streamed.stream.bytesToString();
      final payload = _decodeObject(body);
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw Exception(_payloadError(payload, 'Could not analyze this file.'));
      }
      final rawRows = payload['rows'];
      if (rawRows is! List) {
        throw Exception('The AI did not return a reviewable table. Try a clearer image or spreadsheet.');
      }
      final rows = rawRows.whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList();
      final rawMapping = payload['mapping'];
      final mapping = rawMapping is Map ? Map<String, dynamic>.from(rawMapping) : <String, dynamic>{};
      final rawWarnings = payload['warnings'];
      final warnings = rawWarnings is List ? rawWarnings.map((item) => item.toString()).toList() : <String>[];
      if (!mounted) return;
      setState(() {
        _previewRows = rows;
        _columnMapping = mapping;
        _warnings = warnings;
        _hasPreview = true;
        _uploadMessage = rows.isEmpty
            ? 'No product rows were detected. Use a clearer image or a file with a header row.'
            : 'Review the detected values below. Inventory has not been changed yet.';
        _uploadStatus = rows.isEmpty ? 'error' : 'info';
      });
      _validatePreviewRows();
    } catch (error) {
      _showMessage(_readableError(error), 'error');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _confirmUpload() async {
    if (_previewRows.isEmpty) {
      _showMessage('Analyze a file and review its rows first.', 'error');
      return;
    }
    if (!_validatePreviewRows()) {
      _showMessage('Some rows need attention. Tap Edit on each flagged row before uploading.', 'error');
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LiveTranslatedText('Confirm inventory import?'),
        content: LiveTranslatedText(
          'This will import ' + _previewRows.length.toString() + ' rows into your inventory. '
          'Rows with an existing SKU will update that product. Nothing was changed during preview.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const LiveTranslatedText('Review again')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const LiveTranslatedText('Confirm upload')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() {
      _isBusy = true;
      _uploadMessage = '';
      _uploadStatus = '';
    });
    try {
      final rowsToSend = _previewRows.map((row) {
        final cleaned = Map<String, dynamic>.from(row);
        cleaned.remove('issues');
        return cleaned;
      }).toList();
      final response = await ApiClient.postJson(
        ApiClient.inventoryPrefix + '/upload/confirm',
        {'rows': rowsToSend},
      );
      final payload = _decodeObject(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(_payloadError(payload, 'Inventory import failed.'));
      }
      final imported = payload['imported'] ?? rowsToSend.length;
      final created = payload['created'] ?? 0;
      final updated = payload['updated'] ?? 0;
      final message = payload['message']?.toString() ??
          ('Imported ' + imported.toString() + ' rows (' + created.toString() + ' created, ' + updated.toString() + ' updated).');
      if (!mounted) return;
      setState(() {
        _uploadMessage = message;
        _uploadStatus = 'success';
        _uploadHistory.insert(0, UploadHistory(
          fileName: _selectedFileName ?? 'Inventory file',
          uploadTime: DateTime.now(),
          status: 'success',
          importedCount: rowsToSend.length,
        ));
        _selectedFile = null;
        _selectedFileName = null;
        _hasPreview = false;
        _previewRows = [];
        _columnMapping = {};
        _warnings = [];
      });
    } catch (error) {
      _showMessage(_readableError(error), 'error');
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Map<String, dynamic> _decodeObject(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
      return {'message': decoded.toString()};
    } catch (_) {
      return {'message': body.trim().isEmpty ? 'The server returned an empty response.' : body.trim()};
    }
  }

  String _payloadError(Map<String, dynamic> payload, String fallback) {
    final detail = payload['detail'];
    if (detail is String && detail.trim().isNotEmpty) return detail;
    if (detail is Map) {
      final message = detail['message'];
      if (message != null && message.toString().trim().isNotEmpty) return message.toString();
      final rows = detail['rows'];
      if (rows is List && rows.isNotEmpty && rows.first is Map) {
        final first = Map<String, dynamic>.from(rows.first as Map);
        return 'Row ' + (first['row_number'] ?? '?').toString() + ': ' + (first['message'] ?? 'Please correct this row.').toString();
      }
    }
    if (payload['message'] != null && payload['message'].toString().trim().isNotEmpty) {
      return payload['message'].toString();
    }
    return fallback;
  }

  String _readableError(Object error) {
    final message = error.toString().replaceFirst('Exception: ', '').trim();
    return message.isEmpty ? 'Something went wrong. Please try again.' : message;
  }

  void _showMessage(String message, String status) {
    if (!mounted) return;
    setState(() {
      _uploadMessage = message;
      _uploadStatus = status;
    });
  }

  int? _wholeNumber(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return null;
    final number = double.tryParse(value.toString().replaceAll(',', '').trim());
    if (number == null || !number.isFinite || number < 0 || number != number.truncateToDouble()) return null;
    return number.toInt();
  }

  double? _priceNumber(dynamic value) {
    if (value == null || value.toString().trim().isEmpty) return null;
    final number = double.tryParse(value.toString().replaceAll(',', '').replaceAll('₹', '').trim());
    if (number == null || !number.isFinite || number < 0) return null;
    return number;
  }

  List<String> _validateRow(Map<String, dynamic> row) {
    final issues = <String>[];
    final name = row['product_name']?.toString().trim() ?? '';
    final sku = row['sku']?.toString().trim() ?? '';
    if (name.length < 2 || name.length > 100) issues.add('Product name must contain 2–100 characters.');
    if (sku.length < 2 || sku.length > 50) issues.add('SKU must contain 2–50 characters.');
    if (_priceNumber(row['unit_price']) == null) issues.add('Unit price is required and must be zero or greater.');
    final currentStock = _wholeNumber(row['current_stock']);
    final minStock = _wholeNumber(row['min_stock']);
    final maxStock = _wholeNumber(row['max_stock']);
    final reorderLevel = _wholeNumber(row['reorder_level']);
    if (currentStock == null) issues.add('Current stock must be a non-negative whole number.');
    if (minStock == null) issues.add('Minimum stock must be a non-negative whole number.');
    if (maxStock == null) issues.add('Maximum stock must be a non-negative whole number.');
    if (reorderLevel == null) issues.add('Reorder level must be a non-negative whole number.');
    if (minStock != null && maxStock != null && minStock > maxStock) issues.add('Minimum stock cannot exceed maximum stock.');
    return issues;
  }

  bool _validatePreviewRows() {
    final skuRows = <String, List<int>>{};
    for (var index = 0; index < _previewRows.length; index++) {
      final sku = _previewRows[index]['sku']?.toString().trim().toLowerCase() ?? '';
      if (sku.isNotEmpty) skuRows.putIfAbsent(sku, () => []).add(index);
    }
    var isValid = true;
    for (var index = 0; index < _previewRows.length; index++) {
      final row = _previewRows[index];
      final issues = _validateRow(row);
      final sku = row['sku']?.toString().trim().toLowerCase() ?? '';
      if (sku.isNotEmpty && (skuRows[sku]?.length ?? 0) > 1) issues.add('Duplicate SKU in this file; edit it to a unique SKU.');
      row['issues'] = issues;
      if (issues.isNotEmpty) isValid = false;
    }
    if (mounted) setState(() {});
    return isValid;
  }

  Future<void> _editRow(int index) async {
    final row = Map<String, dynamic>.from(_previewRows[index]);
    final name = TextEditingController(text: row['product_name']?.toString() ?? '');
    final sku = TextEditingController(text: row['sku']?.toString() ?? '');
    final price = TextEditingController(text: row['unit_price']?.toString() ?? '');
    final stock = TextEditingController(text: row['current_stock']?.toString() ?? '0');
    final minStock = TextEditingController(text: row['min_stock']?.toString() ?? '10');
    final maxStock = TextEditingController(text: row['max_stock']?.toString() ?? '100');
    final reorder = TextEditingController(text: row['reorder_level']?.toString() ?? '20');
    final category = TextEditingController(text: row['category']?.toString() ?? '');
    final description = TextEditingController(text: row['description']?.toString() ?? '');

    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: LiveTranslatedText('Edit row ' + (row['row_number'] ?? index + 2).toString()),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _editorField(name, 'Product name'),
                _editorField(sku, 'SKU / barcode'),
                _editorField(price, 'Unit price (₹)', keyboardType: const TextInputType.numberWithOptions(decimal: true)),
                _editorField(stock, 'Current stock', keyboardType: TextInputType.number),
                _editorField(minStock, 'Minimum stock', keyboardType: TextInputType.number),
                _editorField(maxStock, 'Maximum stock', keyboardType: TextInputType.number),
                _editorField(reorder, 'Reorder level', keyboardType: TextInputType.number),
                _editorField(category, 'Category'),
                _editorField(description, 'Description', maxLines: 2),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const LiveTranslatedText('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const LiveTranslatedText('Save row')),
        ],
      ),
    );
    if (saved == true && mounted) {
      setState(() {
        final target = _previewRows[index];
        target['product_name'] = name.text.trim();
        target['sku'] = sku.text.trim();
        target['unit_price'] = double.tryParse(price.text.replaceAll(',', '').replaceAll('₹', '').trim()) ?? price.text.trim();
        target['current_stock'] = int.tryParse(stock.text.trim()) ?? stock.text.trim();
        target['min_stock'] = int.tryParse(minStock.text.trim()) ?? minStock.text.trim();
        target['max_stock'] = int.tryParse(maxStock.text.trim()) ?? maxStock.text.trim();
        target['reorder_level'] = int.tryParse(reorder.text.trim()) ?? reorder.text.trim();
        target['category'] = category.text.trim().isEmpty ? null : category.text.trim();
        target['description'] = description.text.trim().isEmpty ? null : description.text.trim();
      });
      _validatePreviewRows();
    }
    name.dispose();
    sku.dispose();
    price.dispose();
    stock.dispose();
    minStock.dispose();
    maxStock.dispose();
    reorder.dispose();
    category.dispose();
    description.dispose();
  }

  Widget _editorField(TextEditingController controller, String label, {TextInputType? keyboardType, int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        decoration: InputDecoration(labelText: label, border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)), isDense: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: AppBar(
        title: LiveTranslatedText('Upload Inventory', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
        backgroundColor: isDark ? Colors.grey[900] : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
        elevation: 0,
      ),
      body: _isBusy
          ? const AnimatedLoadingWidget(message: 'Analyzing and preparing your inventory...', type: LoadingType.wave)
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildUploadSection(isDark),
                  const SizedBox(height: 18),
                  if (_selectedFile != null) _buildFileInfo(isDark),
                  if (_uploadMessage.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _buildMessageBox(isDark),
                  ],
                  if (_hasPreview) ...[
                    const SizedBox(height: 22),
                    _buildPreviewSection(isDark),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _pickFile,
                        icon: const Icon(Icons.swap_horiz_rounded),
                        label: const LiveTranslatedText('Choose another file'),
                        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _previewRows.isNotEmpty && _previewRows.every((row) => (row['issues'] as List?)?.isEmpty ?? true)
                            ? _confirmUpload
                            : null,
                        icon: const Icon(Icons.cloud_upload_rounded),
                        label: LiveTranslatedText('Confirm & Upload ' + _previewRows.length.toString() + ' rows'),
                        style: FilledButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 16)),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _selectedFile != null ? _analyzeFile : null,
                        icon: const Icon(Icons.auto_awesome_rounded),
                        label: const LiveTranslatedText('Analyze & Preview'),
                        style: FilledButton.styleFrom(
                          backgroundColor: _accent,
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: Colors.grey.shade300,
                          disabledForegroundColor: Colors.grey.shade500,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  _buildTemplateSection(isDark),
                  const SizedBox(height: 28),
                  if (_uploadHistory.isNotEmpty) _buildHistorySection(isDark),
                ],
              ),
            ),
    );
  }

  Widget _buildUploadSection(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[900] : Colors.grey[50],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _accent.withValues(alpha: 0.32), width: 2),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _pickFile,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 30),
            child: Column(
              children: [
                Icon(Icons.cloud_upload_rounded, size: 60, color: _accent),
                const SizedBox(height: 14),
                LiveTranslatedText('Upload File or Image', style: GoogleFonts.poppins(fontSize: 19, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black87)),
                const SizedBox(height: 8),
                LiveTranslatedText('CSV, XLSX, XLS, JSON, TXT, JPG, PNG, WEBP and more', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 12, color: isDark ? Colors.grey[400] : Colors.grey[600])),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(color: _accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                  child: LiveTranslatedText('Click to browse', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600, color: _accent)),
                ),
                const SizedBox(height: 10),
                LiveTranslatedText('AI reads the file, matches columns, and lets you review everything before import.', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 11, color: isDark ? Colors.grey[400] : Colors.grey[600])),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFileInfo(bool isDark) {
    final file = _selectedFile!;
    final fileSize = file.existsSync() ? file.lengthSync() : 0;
    final extension = (_selectedFileName ?? file.path).split('.').last.toLowerCase();
    final isImage = ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif', 'tif', 'tiff'].contains(extension);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: isDark ? Colors.grey[900] : Colors.grey[50], borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.35))),
      child: Row(
        children: [
          Icon(isImage ? Icons.image_outlined : Icons.description_outlined, color: const Color(0xFF10B981), size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LiveTranslatedText(_selectedFileName ?? file.path.split(Platform.pathSeparator).last, style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                LiveTranslatedText((fileSize / 1024 / 1024).toStringAsFixed(2) + ' MB • Ready for AI analysis', style: GoogleFonts.poppins(fontSize: 11, color: isDark ? Colors.grey[400] : Colors.grey[600])),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Remove file',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => setState(() {
              _selectedFile = null;
              _selectedFileName = null;
              _hasPreview = false;
              _previewRows = [];
              _columnMapping = {};
              _warnings = [];
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewSection(bool isDark) {
    final invalidCount = _previewRows.where((row) => (row['issues'] as List?)?.isNotEmpty ?? false).length;
    final readyCount = _previewRows.length - invalidCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: LiveTranslatedText('Review before upload', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(color: _accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(18)),
              child: LiveTranslatedText('Groq AI', style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w600, color: _accent)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        LiveTranslatedText('Detected ' + _previewRows.length.toString() + ' rows. No inventory changes happen until you confirm.', style: GoogleFonts.poppins(fontSize: 12, color: isDark ? Colors.grey[400] : Colors.grey[600])),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _summaryMetric(isDark, 'Ready', readyCount.toString(), const Color(0xFF059669))),
            const SizedBox(width: 10),
            Expanded(child: _summaryMetric(isDark, 'Needs review', invalidCount.toString(), invalidCount > 0 ? const Color(0xFFDC2626) : const Color(0xFF64748B))),
          ],
        ),
        if (_columnMapping.values.any((value) => value is String && value.isNotEmpty)) ...[
          const SizedBox(height: 16),
          LiveTranslatedText('AI column matching', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _columnMapping.entries
                .where((entry) => entry.value is String && (entry.value as String).isNotEmpty)
                .map((entry) => Chip(
                      label: LiveTranslatedText(entry.value.toString() + '  →  ' + _fieldTitle(entry.key), style: const TextStyle(fontSize: 11)),
                      visualDensity: VisualDensity.compact,
                      side: BorderSide(color: _accent.withValues(alpha: 0.25)),
                    ))
                .toList(),
          ),
        ],
        if (_warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: const Color(0xFFF59E0B).withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LiveTranslatedText('AI notes', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 12)),
                const SizedBox(height: 4),
                ..._warnings.map((warning) => Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: LiveTranslatedText('• ' + warning, style: GoogleFonts.poppins(fontSize: 11)),
                    )),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        ...List.generate(_previewRows.length, (index) => _buildPreviewRow(isDark, index)),
      ],
    );
  }

  Widget _summaryMetric(bool isDark, String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: isDark ? Colors.grey[900] : Colors.grey[50], borderRadius: BorderRadius.circular(12), border: Border.all(color: color.withValues(alpha: 0.22))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LiveTranslatedText(label, style: GoogleFonts.poppins(fontSize: 11, color: isDark ? Colors.grey[400] : Colors.grey[600])),
          const SizedBox(height: 3),
          LiveTranslatedText(value, style: GoogleFonts.poppins(fontSize: 21, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }

  Widget _buildPreviewRow(bool isDark, int index) {
    final row = _previewRows[index];
    final issues = (row['issues'] as List?)?.map((item) => item.toString()).toList() ?? <String>[];
    final rawName = row['product_name']?.toString().trim() ?? '';
    final name = rawName.isNotEmpty ? rawName : 'Unnamed product';
    final price = row['unit_price'];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[900] : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: issues.isEmpty ? Colors.grey.withValues(alpha: 0.22) : const Color(0xFFDC2626).withValues(alpha: 0.55)),
        boxShadow: isDark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.025), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(color: _accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                child: LiveTranslatedText((index + 1).toString(), style: GoogleFonts.poppins(fontWeight: FontWeight.w700, color: _accent)),
              ),
              const SizedBox(width: 10),
              Expanded(child: LiveTranslatedText(name, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600))),
              IconButton(tooltip: 'Edit row', visualDensity: VisualDensity.compact, onPressed: () => _editRow(index), icon: const Icon(Icons.edit_outlined, color: _accent)),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _valuePill('SKU', row['sku']?.toString() ?? '—', isDark),
              _valuePill('Price', price == null ? 'Missing' : '₹' + price.toString(), isDark),
              _valuePill('Stock', row['current_stock']?.toString() ?? '—', isDark),
              if (row['category'] != null && row['category'].toString().isNotEmpty) _valuePill('Category', row['category'].toString(), isDark),
            ],
          ),
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFDC2626).withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: issues.map((issue) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: LiveTranslatedText('• ' + issue, style: GoogleFonts.poppins(fontSize: 11, color: const Color(0xFFDC2626))),
                    )).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _valuePill(String label, String value, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(color: isDark ? Colors.grey[850] : Colors.grey[100], borderRadius: BorderRadius.circular(8)),
      child: LiveTranslatedText(label + ': ' + value, style: GoogleFonts.poppins(fontSize: 10, color: isDark ? Colors.grey[200] : Colors.grey[800])),
    );
  }

  String _fieldTitle(String key) {
    const names = {
      'product_name': 'Product name',
      'sku': 'SKU',
      'description': 'Description',
      'current_stock': 'Current stock',
      'min_stock': 'Minimum stock',
      'max_stock': 'Maximum stock',
      'reorder_level': 'Reorder level',
      'unit_price': 'Unit price',
      'category': 'Category',
    };
    return names[key] ?? key.replaceAll('_', ' ');
  }

  Widget _buildMessageBox(bool isDark) {
    final success = _uploadStatus == 'success';
    final error = _uploadStatus == 'error';
    final color = success ? const Color(0xFF059669) : error ? const Color(0xFFDC2626) : const Color(0xFF2563EB);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.25))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(success ? Icons.check_circle_outline : error ? Icons.error_outline : Icons.info_outline, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(child: LiveTranslatedText(_uploadMessage, style: GoogleFonts.poppins(fontSize: 12, color: color, fontWeight: FontWeight.w500))),
        ],
      ),
    );
  }

  Widget _buildTemplateSection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LiveTranslatedText('Download Templates', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: [
            _buildTemplateCard(isDark, 'CSV Template', Icons.table_chart_rounded),
            _buildTemplateCard(isDark, 'Excel Template', Icons.calculate_rounded),
            _buildTemplateCard(isDark, 'JSON Template', Icons.data_object_rounded),
          ],
        ),
      ],
    );
  }

  void _showTemplateHelp() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LiveTranslatedText('Use columns such as Product Name, SKU, Current Stock, Unit Price and Category. AI can match different header names.')),
    );
  }

  Widget _buildTemplateCard(bool isDark, String label, IconData icon) {
    return Container(
      decoration: BoxDecoration(color: isDark ? Colors.grey[900] : Colors.grey[50], borderRadius: BorderRadius.circular(12), border: Border.all(color: isDark ? Colors.grey[800]! : Colors.grey[300]!)),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _showTemplateHelp,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: _accent, size: 32),
              const SizedBox(height: 8),
              LiveTranslatedText(label, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistorySection(bool isDark) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LiveTranslatedText('Upload History', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        ..._uploadHistory.map((item) => Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: isDark ? Colors.grey[900] : Colors.grey[50], borderRadius: BorderRadius.circular(8), border: Border.all(color: isDark ? Colors.grey[800]! : Colors.grey[300]!)),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_rounded, color: Color(0xFF059669), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LiveTranslatedText(item.fileName, style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
                        LiveTranslatedText(item.importedCount.toString() + ' rows • ' + item.uploadTime.toString().split('.').first, style: GoogleFonts.poppins(fontSize: 10, color: isDark ? Colors.grey[400] : Colors.grey[600])),
                      ],
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}

class UploadHistory {
  final String fileName;
  final DateTime uploadTime;
  final String status;
  final int importedCount;

  UploadHistory({
    required this.fileName,
    required this.uploadTime,
    required this.status,
    required this.importedCount,
  });
}
