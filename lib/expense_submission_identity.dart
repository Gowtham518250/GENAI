import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Stable request identity for one expense dialog session.
/// Re-entering the same normalized payload reuses its key; editing the payload
/// produces another key. The map also preserves a key if the user edits and
/// then returns to the original payload after a timed-out request.
class ExpenseSubmissionIdentity {
  final Map<String, String> _keysByFingerprint = <String, String>{};

  String keyFor({
    required String category,
    required double amount,
    required String description,
    required String expenseDate,
    required String paymentMethod,
  }) {
    final fingerprint = jsonEncode(<String, String>{
      'category': category.trim().toLowerCase(),
      'amount': amount.toStringAsFixed(2),
      'description': description.trim(),
      'expense_date': expenseDate.trim(),
      'payment_method': paymentMethod.trim().toLowerCase(),
    });
    return _keysByFingerprint.putIfAbsent(
      fingerprint,
      () => const Uuid().v4(),
    );
  }
}
