import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:syncfusion_flutter_pdf/pdf.dart' as sf_pdf;

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

/// Search bank statement rows by customer name, phone number or reference.
class BankStatementSearchMatcher {
  static bool matches(BankEntry entry, String query) {
    final value = query.trim();
    if (value.isEmpty) return true;

    final digits = value.replaceAll(RegExp(r'\D'), '');
    final numericPhoneQuery =
        RegExp(r'^[+\d\s()\-]+$').hasMatch(value) && digits.length >= 7;
    if (numericPhoneQuery) {
      var target = digits;
      if (target.length == 12 && target.startsWith('91')) {
        target = target.substring(2);
      }

      final source = entry.counterparty + ' ' + entry.description + ' ' + entry.rawLine;
      final phonePattern = RegExp(
        r'(?<!\d)(?:\+?91[\s-]?)?[6-9](?:[\s()-]*\d){9}(?!\d)',
      );
      for (final match in phonePattern.allMatches(source)) {
        var phone = (match.group(0) ?? '').replaceAll(RegExp(r'\D'), '');
        if (phone.length == 12 && phone.startsWith('91')) {
          phone = phone.substring(2);
        }
        if (target.length >= 10 ? phone == target : phone.contains(target)) {
          return true;
        }
      }

      // Numeric UTR/reference searches must not match a partial longer ID.
      final exactNumber = RegExp(r'(?<!\d)' + RegExp.escape(digits) + r'(?!\d)');
      return exactNumber.hasMatch(entry.reference) ||
          exactNumber.hasMatch(entry.description) ||
          exactNumber.hasMatch(entry.rawLine);
    }

    final normalized = value.toLowerCase();
    return entry.counterparty.toLowerCase().contains(normalized) ||
        entry.description.toLowerCase().contains(normalized) ||
        entry.reference.toLowerCase().contains(normalized) ||
        entry.rawLine.toLowerCase().contains(normalized) ||
        entry.bankName.toLowerCase().contains(normalized);
  }
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
    final sourceLines = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final headerText = sourceLines.take(40).join(' ').toLowerCase();
    final debitHeader = RegExp(
      r'\b(?:debit|withdrawal)(?:\s+(?:amount|amt))?\b',
    ).firstMatch(headerText);
    final creditHeader = RegExp(
      r'\b(?:credit|deposit)(?:\s+(?:amount|amt))?\b',
    ).firstMatch(headerText);
    final hasBalanceHeader = RegExp(
      r'\b(?:balance|closing balance|running balance)\b',
    ).hasMatch(headerText);
    final hasDebitCreditColumns = debitHeader != null &&
        creditHeader != null &&
        (debitHeader.start - creditHeader.start).abs() < 180 &&
        hasBalanceHeader;
    final debitColumnFirst = !hasDebitCreditColumns ||
        debitHeader!.start < creditHeader!.start;

    // PDF extractors sometimes put each cell on a separate line. Combine those
    // fragments until a complete dated transaction is found, then start a new
    // record on the next dated row. This preserves the original column order
    // without guessing whether an unmarked amount was a credit or a debit.
    final logicalRows = <String>[];
    var buffer = '';
    for (final line in sourceLines) {
      final startsWithDate = RegExp(
        r'^(?:\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|(?:[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9},?\s+\d{2,4}))\b',
      ).hasMatch(line);
      if (startsWithDate && buffer.isNotEmpty) {
        if (_parseTransactionLine(buffer, bankName, hasDebitCreditColumns: hasDebitCreditColumns, debitColumnFirst: debitColumnFirst) != null) {
          logicalRows.add(buffer);
          buffer = line;
        } else {
          final dateOnlyFragments = RegExp(
            r'^(?:(?:\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|(?:[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9},?\s+\d{2,4}))(?:\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AP]M)?)?)(?:\s+(?:(?:\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|(?:[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9},?\s+\d{2,4}))(?:\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AP]M)?)?))*$',
            caseSensitive: false,
          ).hasMatch(buffer);
          // Discard headers/preamble before the first transaction. If PDF
          // extraction puts transaction date and value date in separate cells,
          // retain those short date-only fragments together.
          buffer = dateOnlyFragments ? '$buffer $line' : line;
        }
      } else {
        buffer = buffer.isEmpty ? line : '$buffer $line';
      }
      // Guard malformed PDF extraction from joining a huge document into one
      // string. Keep long non-transaction sections from consuming unbounded RAM.
      if (buffer.length > 5000 && _parseTransactionLine(buffer, bankName, hasDebitCreditColumns: hasDebitCreditColumns, debitColumnFirst: debitColumnFirst) == null) {
        buffer = buffer.substring(buffer.length - 1200);
      }
    }
    if (buffer.isNotEmpty) logicalRows.add(buffer);

    for (final line in logicalRows) {
      final entry = _parseTransactionLine(line, bankName, hasDebitCreditColumns: hasDebitCreditColumns, debitColumnFirst: debitColumnFirst);
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
    if (value.contains('PHONEPE') || value.contains('TRANSACTION STATEMENT FOR')) return 'PhonePe';
    return 'Unknown bank';
  }

  static BankEntry? _parseTransactionLine(
    String line,
    String bankName, {
    bool hasDebitCreditColumns = false,
    bool debitColumnFirst = true,
  }) {
    final hasMovement = RegExp(
      r'\bUPI\b|\bNEFT\b|\bIMPS\b|\bRTGS\b|\bPOS\b|\bATM\b|\bECS\b|\bNACH\b|\bCHQ\b|\bCHEQUE\b|\bCARD\b|\bBILLPAY\b|\bCR(?:EDIT(?:ED)?)?\b|\bDR\b|\bDEBIT(?:ED)?\b|\bRECEIVED\b|\bWITHDRAW(?:AL|N)?\b|\bDEPOSIT\b|\bTRANSFER\b|\bPAYMENT\b|\bCHARGE(?:D)?\b|\bSALARY\b|\bINTEREST\b',
      caseSensitive: false,
    ).hasMatch(line);
    if (!hasMovement) return null;

    final dateMatch = RegExp(
      r'\b(\d{4}[/-]\d{1,2}[/-]\d{1,2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|(?:[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9},?\s+\d{2,4}))\b',
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

    var direction = '';
    double? amountFromColumns;
    if (isCredit != isDebit) {
      direction = isCredit ? 'CREDIT' : 'DEBIT';
    } else if (hasDebitCreditColumns) {
      // Some statements encode direction only in Debit/Credit columns and do
      // not append CR/DR to the narration. Infer only when the row has both
      // amount columns plus a balance value and exactly one flow is non-zero.
      final columnTail = line.substring(dateMatch.end).trim();
      final moneyPattern = RegExp(
        r'(?<![A-Za-z0-9/])(?:₹\s*|Rs\.?\s*)?(-?[0-9][0-9,]*(?:\.\d{1,2})?)(?![A-Za-z0-9/])',
        caseSensitive: false,
      );
      final candidates = <double>[];
      for (final match in moneyPattern.allMatches(columnTail)) {
        final raw = match.group(1) ?? '';
        final normalized = raw.replaceAll(',', '').replaceAll('-', '');
        if (!raw.contains(',') && !raw.contains('.') && normalized.length >= 6) continue;
        final parsed = _parseAmount(raw);
        if (parsed != null && parsed >= 0) candidates.add(parsed);
      }
      if (candidates.length < 3) return null;
      final debitAmount = candidates[debitColumnFirst ? candidates.length - 3 : candidates.length - 2];
      final creditAmount = candidates[debitColumnFirst ? candidates.length - 2 : candidates.length - 3];
      if (debitAmount > 0 && creditAmount == 0) {
        direction = 'DEBIT';
        amountFromColumns = debitAmount;
      } else if (creditAmount > 0 && debitAmount == 0) {
        direction = 'CREDIT';
        amountFromColumns = creditAmount;
      } else {
        return null;
      }
    } else {
      return null;
    }
    final tail = line.substring(dateMatch.end).trim();
    double? amount = amountFromColumns;
    final markerAmount = RegExp(
      r'\b(?:CR(?:EDIT(?:ED)?)?|DR|DEBIT(?:ED)?)\b\s*[:\-]?\s*(?:₹|RS\.?\s*)?([0-9][0-9,]*(?:\.\d{1,2})?)',
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
      r'\s+\b(?:CR(?:EDIT(?:ED)?)?|DR|DEBIT(?:ED)?)\b\s*(?:₹|RS\.?\s*)?[0-9][0-9,]*(?:\.\d{1,2})?.*$',
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
      const months = {
        'jan': 1, 'january': 1, 'feb': 2, 'february': 2, 'mar': 3, 'march': 3,
        'apr': 4, 'april': 4, 'may': 5, 'jun': 6, 'june': 6, 'jul': 7, 'july': 7,
        'aug': 8, 'august': 8, 'sep': 9, 'sept': 9, 'september': 9,
        'oct': 10, 'october': 10, 'nov': 11, 'november': 11,
        'dec': 12, 'december': 12,
      };
      final monthFirst = RegExp(
        r'^([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{2,4})$',
      ).firstMatch(value);
      if (monthFirst != null) {
        final month = months[monthFirst.group(1)!.toLowerCase()];
        if (month == null) return null;
        var year = int.parse(monthFirst.group(3)!);
        if (year < 100) year += year < 50 ? 2000 : 1900;
        return _validatedDate(year, month, int.parse(monthFirst.group(2)!));
      }
      final named = RegExp(
        r'^(\d{1,2})\s+([A-Za-z]{3,9}),?\s+(\d{2,4})$',
      ).firstMatch(value);
      if (named != null) {
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
    final actionParty = RegExp(
      r'^(?:received from|credited from|credited by|paid to|sent to|transferred to)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(description.trim());
    if (actionParty != null) {
      final party = (actionParty.group(1) ?? '').trim();
      if (party.isNotEmpty) return party;
    }
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
      r'\b(?:UTR(?:\s*NO\.?)?|RRN|REF(?:ERENCE)?\s*(?:NO\.?|ID)?|TXN\s*ID|TRANSACTION\s*ID)\s*[:#/-]?\s*([A-Z0-9]{6,})',
      caseSensitive: false,
    ).firstMatch(line);
    if (labelled != null) return labelled.group(1) ?? '';

    for (final part in description.split('/')) {
      final value = part.trim();
      if (RegExp(r'^[A-Z0-9]{8,}$', caseSensitive: false).hasMatch(value) &&
          RegExp(r'\d').hasMatch(value)) {
        return value;
      }
    }
    return '';
  }


}


/// Answers questions from the most recently uploaded statement using local data.
/// Returns null when a question does not look statement-related, allowing the
/// normal business AI query route to handle it. Bank transaction rows stay on-device.
class BankStatementQueryHelper {
  static const String _storagePrefix =
      'retail_mind_uploaded_bank_statement_transactions_v1_';

  static String storageKeyForUserId(String userId) =>
      _storagePrefix + (userId.trim().isEmpty ? 'default' : userId.trim());

  static Map<String, dynamic>? answerQuestion(
    String question,
    List<Map<String, dynamic>> transactions,
  ) {
    final query = _normalize(question);
    if (query.isEmpty) return null;

    final hasKnownParty = transactions.any((row) => _matchesKnownParty(query, row));
    final bankIntent = RegExp(
      r'\b(bank|statement|transactions?|upi|neft|imps|rtgs|credited|credit|debited|debit|received|deposit(?:ed)?|withdraw(?:al|n)?|paid|payment|money in|money out|incoming|outgoing|phone number|utr|rrn)\b',
    ).hasMatch(query);
    final businessIntent = RegExp(
      r'\b(sales?|revenue|turnover|profit|margin|stock|inventory|products?|purchase orders?|invoices?|expenses?|attendance|workers?|employees?)\b',
    ).hasMatch(query);
    // A shared counterparty name must not hijack an ordinary business KPI
    // query. Payment-specific wording still selects the local statement path.
    if (businessIntent && !bankIntent) return null;
    if (!bankIntent && !hasKnownParty) return null;

    final wantsCredit = RegExp(
      r'\b(credit|credited|received|deposit(?:ed)?|inward|incoming|paid me|paid into)\b',
    ).hasMatch(query);
    final wantsDebit = RegExp(
      r'\b(debit|debited|spent|withdraw(?:al|n)?|outward|outgoing|paid to|pay to|payment to|i paid|i pay)\b',
    ).hasMatch(query);
    final filterDirection = wantsCredit == wantsDebit
        ? null
        : wantsCredit
            ? 'CREDIT'
            : 'DEBIT';

    final identityMatches = transactions.where((row) =>
        _matchesKnownParty(query, row)).toList();
    final hasIdentityMatch = identityMatches.isNotEmpty;
    var rows = hasIdentityMatch ? identityMatches : List<Map<String, dynamic>>.from(transactions);
    if (filterDirection != null) {
      rows = rows.where((row) =>
          (row['direction'] ?? '').toString().toUpperCase() == filterDirection).toList();
    }

    final now = DateTime.now();
    if (RegExp(r'\btoday\b').hasMatch(query)) {
      rows = rows.where((row) {
        final date = DateTime.tryParse(row['date']?.toString() ?? '');
        return date != null && date.year == now.year &&
            date.month == now.month && date.day == now.day;
      }).toList();
    } else if (RegExp(r'\byesterday\b').hasMatch(query)) {
      final day = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 1));
      rows = rows.where((row) {
        final date = DateTime.tryParse(row['date']?.toString() ?? '');
        return date != null && date.year == day.year &&
            date.month == day.month && date.day == day.day;
      }).toList();
    }

    final amountIntent = RegExp(
      r'\b(total|sum|how much|amount|value|totalled|in total|credited amount|debit amount)\b',
    ).hasMatch(query);
    final total = rows.fold<double>(
      0,
      (sum, row) => sum + _number(row['amount']),
    );
    final results = rows.take(100).map((row) {
      final direction = (row['direction'] ?? '').toString().toUpperCase();
      final amount = _number(row['amount']);
      final counterparty = (row['counterparty'] ?? '').toString().trim();
      final description = (row['description'] ?? row['rawLine'] ?? '').toString().trim();
      final reference = (row['reference'] ?? '').toString().trim();
      final bankName = (row['bankName'] ?? 'Unknown bank').toString();
      final date = (row['date'] ?? '').toString().split('T').first;
      final phoneSource = '$counterparty $description';
      final phones = RegExp(r'(?<!\d)(?:\+?91[ -]?)?[6-9]\d{9}(?!\d)')
          .allMatches(phoneSource)
          .map((m) => m.group(0)!.trim())
          .toSet()
          .toList();
      return <String, dynamic>{
        'date': date,
        'counterparty': counterparty.isEmpty ? 'Not identified in statement' : counterparty,
        'phone_numbers': phones,
        'direction': direction,
        'amount': amount,
        'flow': direction == 'CREDIT' ? 'CREDITED' : direction == 'DEBIT' ? 'PAID' : 'UNKNOWN',
        'reference': reference,
        'description': description,
        'bank': bankName,
      };
    }).toList();

    final queryWantsDetails = RegExp(
      r'\b(details?|list|show|find|who|name|phone|number|reference|utr|rrn|transaction|transactions|history|entries)\b',
    ).hasMatch(query);
    String answer;
    if (rows.isEmpty) {
      answer = hasIdentityMatch
          ? 'A matching name/reference was found, but no transactions match the requested direction or date in the uploaded statement.'
          : 'No matching transactions were found in the latest bank statement saved on this device. Check the name, phone number, reference, date or credit/debit wording.';
    } else if (amountIntent && !queryWantsDetails) {
      final flowText = filterDirection == 'CREDIT'
          ? 'credited/received'
          : filterDirection == 'DEBIT'
              ? 'paid/debited'
              : 'transaction';
      answer = 'The $flowText total in the uploaded statement is ₹${total.toStringAsFixed(2)} across ${rows.length} matching transaction(s).';
    } else {
      final visible = results.take(12).map((row) {
        final phones = (row['phone_numbers'] as List).cast<String>();
        final phoneText = phones.isEmpty ? '' : ' | Phone: ${phones.join(', ')}';
        final party = row['counterparty'].toString();
        final flow = row['flow'].toString();
        final ref = row['reference'].toString();
        final desc = row['description'].toString();
        return '${row['date']} | $flow ₹${_number(row['amount']).toStringAsFixed(2)} | $party$phoneText'
            '${ref.isEmpty ? '' : ' | Ref: $ref'}'
            '${desc.isEmpty || desc == party ? '' : ' | Details: $desc'}';
      }).join('\n');
      answer = 'Found ${rows.length} matching statement transaction(s). '
          'Credited: ₹${rows.where((r) => (r['direction'] ?? '').toString().toUpperCase() == 'CREDIT').fold<double>(0, (sum, r) => sum + _number(r['amount'])).toStringAsFixed(2)}; '
          'paid: ₹${rows.where((r) => (r['direction'] ?? '').toString().toUpperCase() == 'DEBIT').fold<double>(0, (sum, r) => sum + _number(r['amount'])).toStringAsFixed(2)}.\n$visible'
          '${rows.length > 12 ? '\nShowing the first 12 matches; narrow your search for a shorter list.' : ''}';
    }

    return {
      'query': question,
      'answer': answer,
      'results': results,
      'source': 'uploaded_bank_statement_local',
      'transactions_found': rows.length,
    };
  }

  static bool _matchesKnownParty(String query, Map<String, dynamic> row) {
    final identifiers = RegExp(r'\b\d{7,}\b')
        .allMatches(query)
        .map((match) => match.group(0)!)
        .toList();
    final searchable = [
      row['counterparty'],
      row['reference'],
      row['description'],
      row['rawLine'],
    ].map((value) => (value ?? '').toString()).join(' ');
    final normalizedSearchable = _normalize(searchable);
    final normalizedParty = _normalize((row['counterparty'] ?? '').toString());
    if (normalizedParty.length >= 3 && query.contains(normalizedParty)) return true;

    final tokens = normalizedSearchable.split(' ').where((token) =>
      token.length >= 3 && !_stopWords.contains(token) &&
      !RegExp(r'^\d+$').hasMatch(token));
    for (final token in tokens) {
      if (RegExp(r'(?:^| )' + RegExp.escape(token) + r'(?: |$)').hasMatch(query)) return true;
    }

    if (identifiers.isNotEmpty) {
      final rowDigits = searchable.replaceAll(RegExp(r'\D'), '');
      if (identifiers.any(rowDigits.contains)) return true;
    }
    return false;
  }

  static String _normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9+@.]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static double _number(dynamic value) =>
      value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '') ?? 0;

  static const Set<String> _stopWords = {
    'upi', 'neft', 'imps', 'rtgs', 'credit', 'credited', 'debit', 'debited',
    'paid', 'pay', 'payment', 'received', 'receive', 'transfer', 'bank',
    'statement', 'transaction', 'transactions', 'amount', 'total', 'money',
    'cash', 'details', 'detail', 'name', 'phone', 'number', 'reference',
    'account', 'today', 'yesterday', 'show', 'find', 'who', 'what', 'when',
    'where', 'how', 'much', 'was', 'were', 'the', 'for', 'from', 'with',
    'and', 'my', 'me', 'to', 'of', 'is', 'are', 'did', 'do', 'i', 'all',
    'in', 'on', 'by', 'customer', 'customers',
    'list', 'entries', 'history', 'utr', 'rrn', 'sale', 'sales',
    'stock', 'revenue', 'profit', 'product', 'products', 'purchase', 'order',
    'orders', 'invoice', 'invoices', 'expense', 'expenses', 'shop', 'business',

  };
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
