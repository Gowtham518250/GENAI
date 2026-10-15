import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Contract for the backend POST /bank-recon endpoint.
class BankReconciliationPayload {
  static String dateString(DateTime date) {
    return date.year.toString().padLeft(4, '0') +
        '-' +
        date.month.toString().padLeft(2, '0') +
        '-' +
        date.day.toString().padLeft(2, '0');
  }

  static double parseAmount(String raw, {required String label}) {
    final amount = double.tryParse(raw.trim());
    if (amount == null || !amount.isFinite || amount < 0) {
      throw FormatException(label + ' must be a non-negative amount.');
    }
    final roundedPaise = (amount * 100).round();
    if ((amount * 100 - roundedPaise).abs() > 0.0001) {
      throw FormatException(label + ' can have at most two decimal places.');
    }
    return roundedPaise / 100;
  }

  static Map<String, dynamic> build({
    required DateTime reconDate,
    required String expectedUpiAmount,
    required String actualBankDeposit,
    String? notes,
  }) {
    final expected = parseAmount(expectedUpiAmount, label: 'Expected UPI amount');
    final actual = parseAmount(actualBankDeposit, label: 'Actual bank deposit');
    final normalizedNotes = (notes ?? '').trim();
    final date = dateString(reconDate);
    final expectedFixed = expected.toStringAsFixed(2);
    final actualFixed = actual.toStringAsFixed(2);
    final canonical = jsonEncode(<String, String>{
      'recon_date': date,
      'expected_upi_amount': expectedFixed,
      'actual_bank_deposit': actualFixed,
      'notes': normalizedNotes,
    });
    final digest = sha256.convert(utf8.encode(canonical)).toString();

    return <String, dynamic>{
      'recon_date': date,
      'expected_upi_amount': expected,
      'actual_bank_deposit': actual,
      'notes': normalizedNotes.isEmpty ? null : normalizedNotes,
      // Deterministic so a retry after a timeout/app restart uses the same key.
      'idempotency_key': 'bank-recon-' + digest,
    };
  }
}
