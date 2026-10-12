/// Bank transaction extracted locally from a selectable-text bank statement PDF.
class BankEntry {
  final DateTime date;
  final double amount; // Always positive; use direction to determine money flow.
  final String reference;
  final String rawLine;
  final String counterparty;
  final String description;
  final String direction; // CREDIT = money received; DEBIT = money paid.
  final String bankName;

  const BankEntry({
    required this.date,
    required this.amount,
    required this.reference,
    required this.rawLine,
    this.counterparty = '',
    this.description = '',
    this.direction = 'CREDIT',
    this.bankName = 'Unknown bank',
  });

  double get receivedAmount => direction == 'CREDIT' ? amount : 0.0;
  double get paidAmount => direction == 'DEBIT' ? amount : 0.0;

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'amount': amount,
        'received_amount': receivedAmount,
        'paid_amount': paidAmount,
        'direction': direction,
        'reference': reference,
        'counterparty': counterparty,
        'description': description,
        'rawLine': rawLine,
        'bankName': bankName,
      };
}

/// Bank statement parser. PDF text is extracted on-device; statement content is
/// not sent to a cloud model. Supports UPI/NEFT/IMPS and explicit CR/DR rows.
class BankStatementParser {
  static const String _tag = '🏦 BANK_PARSER';

  static Future<List<BankEntry>> parsePDFFile(String filepath) async {
    final file = File(filepath);
    if (!await file.exists()) {
      throw Exception('The selected PDF could not be found.');
    }
    final bytes = await file.readAsBytes();
    final text = await _extractTextFromPDF(bytes);
    if (text.trim().length < 20) {
      throw Exception(
        'No selectable transaction text was found. This may be a scanned/image PDF; download a text-based statement from net banking.',
      );
    }
    final entries = parseText(text);
    if (entries.isEmpty) {
      throw Exception(
        'The PDF text was readable, but no transactions with a recognizable date, amount and credit/debit direction were found.',
      );
    }
    return entries;
  }

  static Future<String> _extractTextFromPDF(Uint8List bytes) async {
    sf_pdf.PdfDocument? document;
    try {
      document = sf_pdf.PdfDocument(inputBytes: bytes);
      final extractor = sf_pdf.PdfTextExtractor(document);
      return extractor.extractText() ?? '';
    } catch (error) {
      debugPrint('$_tag PDF text extraction failed: $error');
      return '';
    } finally {
      document?.dispose();
    }
  }

  static List<BankEntry> parseText(String text) {
    final entries = <BankEntry>[];
    final seen = <String>{};
    final bankName = _detectBankName(text);

    for (final sourceLine in text.split(RegExp(r'[\r\n]+'))) {
      final line = sourceLine.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (line.isEmpty) continue;
      final entry = _parseTransactionLine(line, bankName);
      if (entry == null) continue;
      final dedupeKey = [
        entry.date.toIso8601String().split('T').first,
        entry.amount.toStringAsFixed(2),
        entry.direction,
        entry.reference,
        entry.rawLine,
      ].join('|');
      if (seen.add(dedupeKey)) entries.add(entry);
    }

    entries.sort((a, b) {
      final dateOrder = b.date.compareTo(a.date);
      return dateOrder != 0 ? dateOrder : a.rawLine.compareTo(b.rawLine);
    });
    debugPrint('$_tag Parsed ' + entries.length.toString() + ' transactions locally');
    return entries;
  }

  static String _detectBankName(String text) {
    final value = text.toUpperCase();
    if (value.contains('HDFC BANK') || value.contains('HDFC')) return 'HDFC';
    if (value.contains('STATE BANK OF INDIA') || RegExp(r'\bSBI\b').hasMatch(value)) return 'SBI';
    if (value.contains('ICICI BANK') || value.contains('ICICI')) return 'ICICI';
    if (value.contains('AXIS BANK') || value.contains('AXIS')) return 'AXIS';
    if (value.contains('KOTAK MAHINDRA') || value.contains('KOTAK')) return 'KOTAK';
    return 'Unknown bank';
  }

  static BankEntry? _parseTransactionLine(String line, String bankName) {
    final hasMovement = RegExp(
      r'\bUPI\b|\bNEFT\b|\bIMPS\b|\bRTGS\b|\bCR(?:EDIT(?:ED)?)?\b|\bDR(?:EBIT(?:ED)?)?\b|\bRECEIVED\b|\bWITHDRAW(?:AL|N)?\b|\bDEPOSIT\b|\bTRANSFER\b',
      caseSensitive: false,
    ).hasMatch(line);
    if (!hasMovement) return null;

    final dateMatch = RegExp(
      r'\b(\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9}\s+\d{2,4})\b',
    ).firstMatch(line);
    if (dateMatch == null) return null;
    final date = _parseDate(dateMatch.group(1)!);
    if (date == null) return null;

    final isCredit = RegExp(
      r'UPI\s*/\s*CR\b|UPI-REC\b|\bCR\b|\bCREDIT(?:ED)?\b|\bRECEIVED\b|\bINWARD\b|\bDEPOSIT\b',
      caseSensitive: false,
    ).hasMatch(line);
    final isDebit = RegExp(
      r'UPI\s*/\s*DR\b|\bDR\b|\bDEBIT(?:ED)?\b|\bPAID\b|\bWITHDRAW(?:AL|N)?\b|\bOUTWARD\b',
      caseSensitive: false,
    ).hasMatch(line);
    if (isCredit == isDebit) return null;
    final direction = isCredit ? 'CREDIT' : 'DEBIT';

    final tail = line.substring(dateMatch.end).trim();
    double? amount;
    final markerAmount = RegExp(
      r'\b(?:CR|DR)\b\s*[:\-]?\s*(?:₹|RS\.?\s*)?([0-9][0-9,]*(?:\.\d{1,2})?)',
      caseSensitive: false,
    ).firstMatch(tail);
    if (markerAmount != null) amount = _parseAmount(markerAmount.group(1));

    if (amount == null || amount <= 0) {
      final moneyPattern = RegExp(
        r'(?<![A-Za-z0-9/])(?:₹\s*|Rs\.?\s*)?(-?[0-9][0-9,]*(?:\.\d{1,2})?)(?![A-Za-z0-9/])',
        caseSensitive: false,
      );
      final candidates = <double>[];
      for (final match in moneyPattern.allMatches(tail)) {
        final raw = match.group(1) ?? '';
        final normalized = raw.replaceAll(',', '').replaceAll('-', '');
        if (!raw.contains(',') && !raw.contains('.') && normalized.length >= 6) continue;
        final parsed = _parseAmount(raw);
        if (parsed != null && parsed >= 0) candidates.add(parsed);
      }
      if (candidates.isNotEmpty) {
        if (candidates.length >= 3) {
          final index = direction == 'CREDIT' ? candidates.length - 2 : candidates.length - 3;
          amount = candidates[index.clamp(0, candidates.length - 1)];
        } else {
          amount = candidates.firstWhere((candidate) => candidate > 0, orElse: () => candidates.last);
        }
      }
    }
    if (amount == null || amount <= 0 || !amount.isFinite) return null;

    var description = tail;
    final terminalMarker = RegExp(
      r'\s+\b(?:CR|DR)\b\s*(?:₹|RS\.?\s*)?[0-9][0-9,]*(?:\.\d{1,2})?.*$',
      caseSensitive: false,
    ).firstMatch(description);
    if (terminalMarker != null) {
      description = description.substring(0, terminalMarker.start).trim();
    } else {
      final money = RegExp(
        r'(?<![A-Za-z0-9/])(?:₹\s*|Rs\.?\s*)?[0-9][0-9,]*(?:\.\d{1,2})?(?![A-Za-z0-9/])',
        caseSensitive: false,
      ).firstMatch(description);
      if (money != null) description = description.substring(0, money.start).trim();
    }
    description = description
        .replaceAll(RegExp(r'\b(?:CR|DR|CREDIT|DEBIT)\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final counterparty = _extractCounterparty(description);
    final reference = _extractReference(line, description);
    return BankEntry(
      date: date,
      amount: amount,
      reference: reference.isEmpty ? description : reference,
      rawLine: line,
      counterparty: counterparty.isEmpty ? description : counterparty,
      description: description,
      direction: direction,
      bankName: bankName,
    );
  }

  static DateTime? _parseDate(String value) {
    try {
      final iso = RegExp(r'^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$').firstMatch(value);
      if (iso != null) {
        return _validatedDate(int.parse(iso.group(1)!), int.parse(iso.group(2)!), int.parse(iso.group(3)!));
      }
      final named = RegExp(r'^(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{2,4})$').firstMatch(value);
      if (named != null) {
        const months = {
          'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
          'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7,
          'july': 7, 'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9,
          'oct': 10, 'october': 10, 'nov': 11, 'november': 11, 'dec': 12, 'december': 12,
        };
        final month = months[named.group(2)!.toLowerCase()];
        if (month == null) return null;
        var year = int.parse(named.group(3)!);
        if (year < 100) year += year < 50 ? 2000 : 1900;
        return _validatedDate(year, month, int.parse(named.group(1)!));
      }
      final parts = value.split(RegExp(r'[-/]'));
      if (parts.length != 3) return null;
      final day = int.parse(parts[0]);
      final month = int.parse(parts[1]);
      var year = int.parse(parts[2]);
      if (year < 100) year += year < 50 ? 2000 : 1900;
      return _validatedDate(year, month, day);
    } catch (_) {
      return null;
    }
  }

  static DateTime? _validatedDate(int year, int month, int day) {
    final parsed = DateTime(year, month, day);
    if (parsed.year != year || parsed.month != month || parsed.day != day) return null;
    return parsed;
  }

  static double? _parseAmount(String? value) {
    if (value == null) return null;
    final parsed = double.tryParse(value.replaceAll(',', '').replaceAll('₹', '').trim());
    if (parsed == null || !parsed.isFinite) return null;
    return parsed.abs();
  }

  static String _extractCounterparty(String description) {
    final patterns = [
      RegExp(r'UPI\s*/\s*(?:CR|DR)\s*/\s*[^/\s]+\s*/\s*([^/]+)', caseSensitive: false),
      RegExp(r'UPI-(?:REC-)?(.+?)(?:-\d{8,}|\s+(?:CR|DR)\b|$)', caseSensitive: false),
      RegExp(r'(?:NEFT|IMPS|RTGS)[/-](?:CR|DR)?[/-]*\d{4,}[/-]([^/]+)', caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(description);
      if (match != null) {
        final result = (match.group(1) ?? '').trim().replaceAll(RegExp(r'[-/]+$'), '');
        if (result.isNotEmpty) return result;
      }
    }
    return description.replaceFirst(RegExp(r'^(?:UPI[-/]?)', caseSensitive: false), '').trim();
  }

  static String _extractReference(String line, String description) {
    final labelled = RegExp(
      r'\b(?:UTR|RRN|REF(?:ERENCE)?\s*(?:NO\.?)?|TXN\s*ID)\s*[:#/-]?\s*([A-Z0-9]{6,})',
      caseSensitive: false,
    ).firstMatch(line);
    if (labelled != null) return labelled.group(1) ?? '';
    for (final part in description.split('/')) {
      final value = part.trim();
      if (RegExp(r'^[A-Z0-9]{8,}
    }
    return '';
  }
}

class BankReconciliation {
  /// Reconciles bank transactions with app sales
  /// Returns list of unmatched transactions for manual review
  static List<Map<String, dynamic>> reconcile(
    List<Map<String, dynamic>> bankTransactions,
    List<Map<String, dynamic>> appSales,
  ) {
    final unmatched = <Map<String, dynamic>>[];

    for (final txn in bankTransactions) {
      // Debits represent money paid out; they should remain in bank history,
      // but must not be treated as incoming customer sale payments.
      if ((txn['direction'] ?? 'CREDIT').toString().toUpperCase() == 'DEBIT') continue;
      final amount = double.tryParse(txn['amount']?.toString() ?? '');
      final dateText = txn['date']?.toString().split('T').first ?? '';
      if (amount == null || !amount.isFinite || amount <= 0 || dateText.isEmpty) {
        unmatched.add({
          ...txn,
          'status': 'UNMATCHED',
          'reconciled_at': DateTime.now().toIso8601String(),
        });
        continue;
      }

      final matched = appSales.any((sale) {
        final saleAmount = double.tryParse(
          (sale['total'] ?? sale['total_amount'] ?? sale['amount'] ?? '').toString(),
        );
        final saleDate = (sale['date'] ?? sale['sale_date'] ?? sale['created_at'] ?? '').toString();
        final normalizedSaleDate = saleDate.split('T').first;
        if (saleAmount == null || !saleAmount.isFinite || normalizedSaleDate != dateText) return false;
        return (saleAmount - amount).abs() < 0.01;
      });

      if (!matched) {
        unmatched.add({
          ...txn,
          'status': 'UNMATCHED',
          'reconciled_at': DateTime.now().toIso8601String(),
        });
      }
    }

    return unmatched;
  }

  /// Get reconciliation summary
  static Map<String, dynamic> getSummary(
    List<Map<String, dynamic>> bankTransactions,
    List<Map<String, dynamic>> appSales,
  ) {
    final unmatched = reconcile(bankTransactions, appSales);

    // Calculate totals
    double bankTotal = 0;
    double appTotal = 0;
    double unmatchedTotal = 0;

    for (final txn in bankTransactions) {
      bankTotal += double.tryParse(txn['amount']?.toString() ?? '0') ?? 0;
    }

    for (final sale in appSales) {
      appTotal += double.tryParse(sale['total']?.toString() ?? '0') ?? 0;
    }

    for (final um in unmatched) {
      unmatchedTotal += double.tryParse(um['amount']?.toString() ?? '0') ?? 0;
    }

    return {
      'bank_total': bankTotal,
      'app_total': appTotal,
      'matched_total': bankTotal - unmatchedTotal,
      'unmatched_total': unmatchedTotal,
      'unmatched_count': unmatched.length,
      'reconciliation_rate': ((bankTotal - unmatchedTotal) / bankTotal * 100).toStringAsFixed(2) + '%',
      'status': unmatchedTotal == 0 ? 'FULLY_RECONCILED' : 'PARTIAL_RECONCILIATION',
    };
  }

  /// Export unmatched transactions for review
  static Future<String> exportUnmatchedAsJSON(
    List<Map<String, dynamic>> bankTransactions,
    List<Map<String, dynamic>> appSales,
  ) async {
    final unmatched = reconcile(bankTransactions, appSales);
    final summary = getSummary(bankTransactions, appSales);

    final exportData = {
      'export_date': DateTime.now().toIso8601String(),
      'summary': summary,
      'unmatched_transactions': unmatched,
    };

    return jsonEncode(exportData);
  }
}
, caseSensitive: false).hasMatch(value) && RegExp(r'\d').hasMatch(value)) return value;
    }
    return '';
  }
}

class BankReconciliation {
  /// Reconciles bank transactions with app sales
  /// Returns list of unmatched transactions for manual review
  static List<Map<String, dynamic>> reconcile(
    List<Map<String, dynamic>> bankTransactions,
    List<Map<String, dynamic>> appSales,
  ) {
    final unmatched = <Map<String, dynamic>>[];

    for (final txn in bankTransactions) {
      // Debits represent money paid out; they should remain in bank history,
      // but must not be treated as incoming customer sale payments.
      if ((txn['direction'] ?? 'CREDIT').toString().toUpperCase() == 'DEBIT') continue;
      final amount = double.tryParse(txn['amount']?.toString() ?? '');
      final dateText = txn['date']?.toString().split('T').first ?? '';
      if (amount == null || !amount.isFinite || amount <= 0 || dateText.isEmpty) {
        unmatched.add({
          ...txn,
          'status': 'UNMATCHED',
          'reconciled_at': DateTime.now().toIso8601String(),
        });
        continue;
      }

      final matched = appSales.any((sale) {
        final saleAmount = double.tryParse(
          (sale['total'] ?? sale['total_amount'] ?? sale['amount'] ?? '').toString(),
        );
        final saleDate = (sale['date'] ?? sale['sale_date'] ?? sale['created_at'] ?? '').toString();
        final normalizedSaleDate = saleDate.split('T').first;
        if (saleAmount == null || !saleAmount.isFinite || normalizedSaleDate != dateText) return false;
        return (saleAmount - amount).abs() < 0.01;
      });

      if (!matched) {
        unmatched.add({
          ...txn,
          'status': 'UNMATCHED',
          'reconciled_at': DateTime.now().toIso8601String(),
        });
      }
    }

    return unmatched;
  }

  /// Get reconciliation summary
  static Map<String, dynamic> getSummary(
    List<Map<String, dynamic>> bankTransactions,
    List<Map<String, dynamic>> appSales,
  ) {
    final unmatched = reconcile(bankTransactions, appSales);

    // Calculate totals
    double bankTotal = 0;
    double appTotal = 0;
    double unmatchedTotal = 0;

    for (final txn in bankTransactions) {
      bankTotal += double.tryParse(txn['amount']?.toString() ?? '0') ?? 0;
    }

    for (final sale in appSales) {
      appTotal += double.tryParse(sale['total']?.toString() ?? '0') ?? 0;
    }

    for (final um in unmatched) {
      unmatchedTotal += double.tryParse(um['amount']?.toString() ?? '0') ?? 0;
    }

    return {
      'bank_total': bankTotal,
      'app_total': appTotal,
      'matched_total': bankTotal - unmatchedTotal,
      'unmatched_total': unmatchedTotal,
      'unmatched_count': unmatched.length,
      'reconciliation_rate': ((bankTotal - unmatchedTotal) / bankTotal * 100).toStringAsFixed(2) + '%',
      'status': unmatchedTotal == 0 ? 'FULLY_RECONCILED' : 'PARTIAL_RECONCILIATION',
    };
  }

  /// Export unmatched transactions for review
  static Future<String> exportUnmatchedAsJSON(
    List<Map<String, dynamic>> bankTransactions,
    List<Map<String, dynamic>> appSales,
  ) async {
    final unmatched = reconcile(bankTransactions, appSales);
    final summary = getSummary(bankTransactions, appSales);

    final exportData = {
      'export_date': DateTime.now().toIso8601String(),
      'summary': summary,
      'unmatched_transactions': unmatched,
    };

    return jsonEncode(exportData);
  }
}
