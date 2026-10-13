import 'invoice_dedup_helper.dart';

/// Keeps transaction event timestamps timezone-aware when building UI view
/// models, and reconciles local sale/server invoice mirrors using all stable IDs.
class TransactionReconciliationHelper {
  /// Convert an already-localized DateTime back to an unambiguous UTC ISO
  /// timestamp before putting it into a string-backed view model.
  static String? serializeEventTime(DateTime? eventTime) {
    return eventTime?.toUtc().toIso8601String();
  }

  /// Deduplicate only records that share a stable identity alias.
  ///
  /// Sale content (same amount/items/time) is never enough to merge records:
  /// two genuine purchases may have identical contents.
  static List<Map<String, dynamic>> dedupe(
    List<Map<String, dynamic>> transactions,
  ) {
    final result = <Map<String, dynamic>>[];

    Map<String, dynamic> identityRow(Map<String, dynamic> transaction) {
      final raw = transaction['raw'];
      if (raw is Map) return Map<String, dynamic>.from(raw);
      return transaction;
    }

    for (final incoming in transactions) {
      final incomingRaw = identityRow(incoming);
      var matchIndex = -1;

      for (var index = 0; index < result.length; index++) {
        final existing = result[index];
        final existingRaw = identityRow(existing);
        final existingId = existing['id']?.toString().trim() ?? '';
        final incomingId = incoming['id']?.toString().trim() ?? '';
        final sameDisplayId = existingId.isNotEmpty && existingId == incomingId;
        if (sameDisplayId ||
            InvoiceDedupHelper.sameInvoice(existingRaw, incomingRaw)) {
          matchIndex = index;
          break;
        }
      }

      if (matchIndex < 0) {
        result.add(Map<String, dynamic>.from(incoming));
        continue;
      }

      final existing = result[matchIndex];
      final mergedRaw = Map<String, dynamic>.from(identityRow(existing));
      for (final entry in incomingRaw.entries) {
        final value = entry.value;
        if (value == null) continue;
        if (value is String && value.trim().isEmpty) continue;
        mergedRaw[entry.key] = value;
      }

      // Incoming records are loaded in category order with invoices last.
      // Prefer the invoice wrapper when a local sale and server invoice mirror
      // match, while preserving aliases from both sides in mergedRaw.
      result[matchIndex] = <String, dynamic>{
        ...existing,
        ...incoming,
        'raw': mergedRaw,
      };
    }

    return result;
  }
}
