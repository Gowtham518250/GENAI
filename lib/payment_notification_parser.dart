/// Extracts readable text from notification and accessibility payloads.
///
/// Android/payment-app integrations do not always put the transaction details
/// in the primary notification body. Some expose them in expanded text lines,
/// grouped-message fields, or accessibility labels. This helper flattens those
/// fields safely without depending on a specific plugin version.
abstract final class PaymentNotificationParser {
  static String combine(Iterable<Object?> values) {
    final chunks = <String>[];
    final seen = <String>{};

    void addValue(Object? value) {
      if (value == null) return;

      if (value is String) {
        final normalized = value.replaceAll(RegExp(r'\\s+'), ' ').trim();
        if (normalized.isEmpty) return;
        final key = normalized.toLowerCase();
        if (seen.add(key)) chunks.add(normalized);
        return;
      }

      if (value is Iterable) {
        for (final item in value) {
          addValue(item);
        }
        return;
      }

      if (value is Map) {
        for (final item in value.values) {
          addValue(item);
        }
      }
    }

    for (final value in values) {
      addValue(value);
    }

    return chunks.join(' ').replaceAll(RegExp(r'\\s+'), ' ').trim();
  }
}
