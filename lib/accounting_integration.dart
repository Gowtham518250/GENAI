import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:csv/csv.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AccountingSoftware {
  tally,
  quickBooks,
  gst,
  mitra,
  busy,
  fintech,
}

class AccountingIntegration {
  static String _escapeXml(String text) {
    return text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  }

  static double? _numberOrNull(dynamic value) {
    if (value is num) {
      final number = value.toDouble();
      return number.isFinite ? number : null;
    }
    if (value == null) return null;
    final number = double.tryParse(value.toString().trim());
    return number != null && number.isFinite ? number : null;
  }

  static double _roundMoney(double value) => double.parse(value.toStringAsFixed(2));

  /// Uses recorded tax when available; otherwise derives tax only when the sale has an explicit GST rate.
  /// The sale amount is treated as GST-inclusive for derived tax calculations.
  static Map<String, dynamic> _deriveGstLine(Map<String, dynamic> sale) {
    final amount = _numberOrNull(sale['total']) ??
        _numberOrNull(sale['total_amount']) ??
        0.0;

    double? rate;
    for (final key in const [
      'gstRate', 'gst_rate', 'gstPercentage', 'gst_percentage',
      'taxRate', 'tax_rate',
    ]) {
      rate = _numberOrNull(sale[key]);
      if (rate != null) break;
    }
    if (rate != null && (rate < 0 || rate > 100)) rate = null;

    double? recordedTax;
    for (final key in const [
      'gstAmount', 'gst_amount', 'taxAmount', 'tax_amount', 'tax',
    ]) {
      recordedTax = _numberOrNull(sale[key]);
      if (recordedTax != null) break;
    }
    if (recordedTax != null && recordedTax < 0) recordedTax = null;

    final calculatedTax = rate == null
        ? null
        : _roundMoney(amount * rate / (100 + rate));
    final tax = recordedTax != null
        ? _roundMoney(recordedTax)
        : calculatedTax;
    final taxable = tax == null ? null : _roundMoney(amount - tax);
    final mismatch = recordedTax != null &&
        calculatedTax != null &&
        (recordedTax - calculatedTax).abs() > 0.02;
    final rateLabel = rate == null
        ? 'UNSPECIFIED'
        : (rate == rate.truncateToDouble()
            ? '${rate.toStringAsFixed(0)}%'
            : '${rate.toStringAsFixed(2)}%');

    return {
      'total': _roundMoney(amount),
      'gstRate': rate,
      'gstRateLabel': rateLabel,
      'taxableAmount': taxable,
      'taxAmount': tax,
      'taxSource': recordedTax != null
          ? 'RECORDED_TAX_AMOUNT'
          : (calculatedTax != null ? 'CALCULATED_FROM_EXPLICIT_RATE' : 'MISSING'),
      'taxMismatch': mismatch,
      'needsReview': rate == null || tax == null || mismatch || (taxable != null && taxable < 0),
    };
  }

  /// Generate Tally-compatible XML format
  static String generateTallyXML(List<Map<String, dynamic>> sales, {
    required String shopName,
    required String gstIn,
    String period = 'Monthly',
  }) {
    final buffer = StringBuffer();
    buffer.write('<?xml version="1.0" encoding="utf-8"?>\n');
    buffer.write('<TALLYREQUEST>\n');
    buffer.write('  <COMPANYNAME>${_escapeXml(shopName)}</COMPANYNAME>\n');

    final taxLines = sales.map(_deriveGstLine).toList();
    final totalAmount = _roundMoney(sales.fold<double>(
      0,
      (sum, sale) => sum + (_numberOrNull(sale['total']) ?? _numberOrNull(sale['total_amount']) ?? 0),
    ));
    final taxableAmount = _roundMoney(taxLines.fold<double>(
      0,
      (sum, line) => sum + ((line['taxableAmount'] as num?)?.toDouble() ?? 0),
    ));
    final totalTax = _roundMoney(taxLines.fold<double>(
      0,
      (sum, line) => sum + ((line['taxAmount'] as num?)?.toDouble() ?? 0),
    ));
    final reviewCount = taxLines.where((line) => line['needsReview'] == true).length;

    buffer.write('  <INVOICES>\n');
    for (var i = 0; i < sales.length; i++) {
      final sale = sales[i];
      final line = taxLines[i];
      buffer.write('    <INVOICE>\n');
      buffer.write('      <INVOICENO>${_escapeXml((sale['invoice_number'] ?? sale['invoiceNumber'] ?? (i + 1)).toString())}</INVOICENO>\n');
      buffer.write('      <DATE>${_formatDateDDMMYYYY(sale['date'])}</DATE>\n');
      buffer.write('      <PRODUCT>${_escapeXml(sale['product']?.toString() ?? 'N/A')}</PRODUCT>\n');
      buffer.write('      <QUANTITY>${sale['quantity'] ?? 0}</QUANTITY>\n');
      buffer.write('      <RATE>${(_numberOrNull(sale['price']) ?? 0).toStringAsFixed(2)}</RATE>\n');
      buffer.write('      <GROSS>${(line['total'] as num).toStringAsFixed(2)}</GROSS>\n');
      buffer.write('      <GSTRATE>${_escapeXml(line['gstRateLabel'].toString())}</GSTRATE>\n');
      buffer.write('      <TAXABLE>${(line['taxableAmount'] as num?)?.toStringAsFixed(2) ?? ''}</TAXABLE>\n');
      buffer.write('      <GSTAMOUNT>${(line['taxAmount'] as num?)?.toStringAsFixed(2) ?? ''}</GSTAMOUNT>\n');
      buffer.write('      <TAXREVIEW>${line['needsReview'] == true ? 'TRUE' : 'FALSE'}</TAXREVIEW>\n');
      buffer.write('      <PAYMENTMODE>${_escapeXml(sale['paymentMethod']?.toString() ?? 'Cash')}</PAYMENTMODE>\n');
      buffer.write('    </INVOICE>\n');
    }
    buffer.write('  </INVOICES>\n');
    buffer.write('  <SUMMARY>\n');
    buffer.write('    <TOTALINVOICES>${sales.length}</TOTALINVOICES>\n');
    buffer.write('    <TOTALGROSS>${totalAmount.toStringAsFixed(2)}</TOTALGROSS>\n');
    buffer.write('    <TAXABLE>${taxableAmount.toStringAsFixed(2)}</TAXABLE>\n');
    buffer.write('    <TAX>${totalTax.toStringAsFixed(2)}</TAX>\n');
    buffer.write('    <TAXREVIEWCOUNT>$reviewCount</TAXREVIEWCOUNT>\n');
    buffer.write('    <GSTIN>${_escapeXml(gstIn)}</GSTIN>\n');
    buffer.write('    <PERIOD>${_escapeXml(period)}</PERIOD>\n');
    buffer.write('  </SUMMARY>\n');
    buffer.write('</TALLYREQUEST>\n');
    return buffer.toString();
  }

  /// Generate QuickBooks-compatible IIF format
  static String generateQuickBooksIIF(List<Map<String, dynamic>> sales, {
    required String companyName,
  }) {
    final buffer = StringBuffer();
    buffer.write('!ACCNT\tNAME\tACCNUM\tDESC\tACCNTTYPE\tDESC\tEXTRA\n');
    buffer.write('ACCNT\tSales\t4100\tProduct Sales\tINCOME\t\t\n');
    buffer.write('ENDACCNT\n\n');

    buffer.write('!TRNS\tTRNSID\tTRNSTYPE\tDATE\tACCNT\tNAME\tDESC\tAMOUNT\n');
    buffer.write('!SPL\tSPLID\tTRNSTYPE\tDATE\tACCNT\tAMOUNT\tDESC\n');
    buffer.write('!ENDTRNS\n\n');

    for (int i = 0; i < sales.length; i++) {
      final sale = sales[i];
      final amount = (sale['total'] as num? ?? 0).toStringAsFixed(2);
      final date = _formatDateMMDDYYYY(sale['date']);

      buffer.write('TRNS\tTRN$i\tCHECK\t$date\tSales\t$companyName\t${sale['product'] ?? 'Sale'}\t$amount\n');
      buffer.write('SPL\tSPL$i\tCHECK\t$date\tSales\t$amount\t${sale['paymentMethod'] ?? 'Cash'}\n');
      buffer.write('ENDTRNS\n');
    }

    return buffer.toString();
  }

  /// Generate GST-compliant JSON report
  static Map<String, dynamic> generateGSTReport(
    List<Map<String, dynamic>> sales, {
    required String gstIn,
    required String shopName,
    required String period,
  }) {
    final lines = sales.map(_deriveGstLine).toList();
    final totalSales = _roundMoney(lines.fold<double>(
      0, (sum, line) => sum + (line['total'] as num).toDouble(),
    ));
    final totalTax = _roundMoney(lines.fold<double>(
      0, (sum, line) => sum + ((line['taxAmount'] as num?)?.toDouble() ?? 0),
    ));
    final unclassified = lines.where((line) => line['gstRate'] == null || line['taxAmount'] == null).toList();
    final unclassifiedGross = _roundMoney(unclassified.fold<double>(
      0, (sum, line) => sum + (line['total'] as num).toDouble(),
    ));
    final grouped = <String, Map<String, dynamic>>{};

    for (final line in lines) {
      final label = line['gstRateLabel'].toString();
      final group = grouped.putIfAbsent(label, () => {
        'gstRate': label,
        'taxableAmount': 0.0,
        'tax': 0.0,
        'items': 0,
        'needsReviewItems': 0,
      });
      group['taxableAmount'] = (group['taxableAmount'] as double) +
          ((line['taxableAmount'] as num?)?.toDouble() ?? 0);
      group['tax'] = (group['tax'] as double) +
          ((line['taxAmount'] as num?)?.toDouble() ?? 0);
      group['items'] = (group['items'] as int) + 1;
      if (line['needsReview'] == true) {
        group['needsReviewItems'] = (group['needsReviewItems'] as int) + 1;
      }
    }

    final rateLabels = grouped.keys.toList()
      ..sort((a, b) {
        final ar = double.tryParse(a.replaceAll('%', ''));
        final br = double.tryParse(b.replaceAll('%', ''));
        if (ar == null) return br == null ? a.compareTo(b) : 1;
        if (br == null) return -1;
        return ar.compareTo(br);
      });

    return {
      'gstIn': gstIn,
      'period': period,
      'shopName': shopName,
      'summary': {
        'totalSales': totalSales,
        'totalTax': totalTax,
        'unclassifiedSalesAmount': unclassifiedGross,
        'unclassifiedCount': unclassified.length,
        'needsReviewCount': lines.where((line) => line['needsReview'] == true).length,
      },
      'breakdown': rateLabels.map((label) {
        final group = grouped[label]!;
        return {
          'gstRate': group['gstRate'],
          'taxableAmount': _roundMoney(group['taxableAmount'] as double),
          'tax': _roundMoney(group['tax'] as double),
          'items': group['items'],
          'needsReviewItems': group['needsReviewItems'],
        };
      }).toList(),
      'transactions': List.generate(sales.length, (i) {
        final sale = sales[i];
        final line = lines[i];
        return {
          'date': sale['date'],
          'product': sale['product'],
          'amount': line['total'],
          'gst': line['taxAmount'],
          'gstRate': line['gstRateLabel'],
          'taxableAmount': line['taxableAmount'],
          'taxSource': line['taxSource'],
          'needsReview': line['needsReview'],
        };
      }),
    };
  }

  /// Export to popular accounting software
  static Future<bool> exportToAccountingSoftware(
    AccountingSoftware software,
    List<Map<String, dynamic>> sales, {
    required String shopName,
    String? apiKey,
    String? apiUrl,
  }) async {
    try {
      // FIX-1: Load GSTIN from shop profile instead of hardcoded temp value
      final prefs = await SharedPreferences.getInstance();
      final gstIn = prefs.getString('gstin') ?? '';
      if (gstIn.isEmpty || !RegExp(r'^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z]{1}[1-9A-Z]{1}Z[0-9A-Z]{1}$').hasMatch(gstIn.toUpperCase())) {
        throw Exception('Valid GSTIN not configured. Please update shop profile in settings.');
      }
      
      switch (software) {
        case AccountingSoftware.tally:
          final xml = generateTallyXML(sales, shopName: shopName, gstIn: gstIn);
          return await _exportToService(apiUrl, xml, 'application/xml');

        case AccountingSoftware.quickBooks:
          final iif = generateQuickBooksIIF(sales, companyName: shopName);
          return await _exportToService(apiUrl, iif, 'text/plain');

        case AccountingSoftware.gst:
          final gstReport = generateGSTReport(
            sales,
            gstIn: gstIn,
            shopName: shopName,
            period: DateTime.now().toString(),
          );
          return await _exportToService(apiUrl, jsonEncode(gstReport), 'application/json');

        default:
          throw Exception('Unsupported accounting software');
      }
    } catch (e) {
      throw Exception('Export to accounting software failed: $e');
    }
  }

  /// Get supported integrations
  static List<AccountingIntegrationInfo> getSupportedIntegrations() {
    return [
      AccountingIntegrationInfo(
        name: 'Tally Prime',
        software: AccountingSoftware.tally,
        description: 'Popular in India, supports XML import',
        features: ['Invoice Import', 'GST Compliance', 'Multi-party Tracking'],
        icon: '📊',
      ),
      AccountingIntegrationInfo(
        name: 'QuickBooks',
        software: AccountingSoftware.quickBooks,
        description: 'Global accounting standard',
        features: ['IIF Format', 'Invoice Sync', 'Expense Tracking'],
        icon: '💼',
      ),
      AccountingIntegrationInfo(
        name: 'GST Compliance',
        software: AccountingSoftware.gst,
        description: 'Indian GST portal compatible',
        features: ['GSTR-1', 'Tax Calculation', 'Report Generation'],
        icon: '📋',
      ),
      AccountingIntegrationInfo(
        name: 'MITRA',
        software: AccountingSoftware.mitra,
        description: 'Indian e-invoicing system',
        features: ['e-Invoice', 'e-Way Bill', 'NETSMART'],
        icon: '🇮🇳',
      ),
      AccountingIntegrationInfo(
        name: 'Busy Software',
        software: AccountingSoftware.busy,
        description: 'Indian accounting software',
        features: ['XML Export', 'GST Ready', 'Multi-user Support'],
        icon: '⚙️',
      ),
    ];
  }

  static Future<bool> _exportToService(
    String? url,
    String data,
    String contentType,
  ) async {
    if (url == null || url.isEmpty) return false;

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': contentType},
        body: data,
      );
      return response.statusCode == 200 || response.statusCode == 201;
    } catch (e) {
      throw Exception('Failed to export: $e');
    }
  }

  static String _formatDateDDMMYYYY(dynamic date) {
    if (date is DateTime) {
      return '${date.day.toString().padLeft(2, '0')}${date.month.toString().padLeft(2, '0')}${date.year}';
    }
    return '';
  }

  static String _formatDateMMDDYYYY(dynamic date) {
    if (date is DateTime) {
      return '${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}/${date.year}';
    }
    return '';
  }

  /// Test connection to accounting service
  static Future<bool> testConnection(String apiUrl) async {
    try {
      final response = await http
          .get(Uri.parse('$apiUrl/health'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

class AccountingIntegrationInfo {
  final String name;
  final AccountingSoftware software;
  final String description;
  final List<String> features;
  final String icon;

  AccountingIntegrationInfo({
    required this.name,
    required this.software,
    required this.description,
    required this.features,
    required this.icon,
  });
}
