import 'package:retail_mind/payment_event.dart';

/// Suppresses duplicate delivery of one Android payment event through the
/// notification and accessibility channels. This is deliberately a short,
/// event-time window: separate payments with the same amount remain distinct
/// when they have different transaction references.
class RecentPaymentEventDeduplicator {
  RecentPaymentEventDeduplicator({
    this.window = const Duration(seconds: 12),
    this.maxEntries = 100,
  });

  final Duration window;
  final int maxEntries;
  final List<PaymentEvent> _recent = <PaymentEvent>[];

  bool isDuplicate(PaymentEvent candidate) {
    _prune(candidate.timestamp);

    for (final previous in _recent.reversed) {
      final delta = candidate.timestamp.isBefore(previous.timestamp)
          ? previous.timestamp.difference(candidate.timestamp)
          : candidate.timestamp.difference(previous.timestamp);
      if (delta > window) continue;
      if ((candidate.amount - previous.amount).abs() > 0.01) continue;
      if (candidate.isFailed != previous.isFailed) continue;
      if (candidate.transactionDirection != previous.transactionDirection) continue;

      final previousRef = _normalizedReference(previous.referenceId);
      final candidateRef = _normalizedReference(candidate.referenceId);
      if (previousRef != null &&
          candidateRef != null &&
          previousRef != candidateRef) {
        // Two distinct UTRs mean two separate transactions even when amount
        // and payer are identical.
        continue;
      }

      final previousSource = _sourceChannel(previous.detectionSource);
      final candidateSource = _sourceChannel(candidate.detectionSource);
      if (previousRef != null && candidateRef != null) {
        if (previousRef != candidateRef) continue;
        // Preserve the notification -> bank-SMS confirmation upgrade path.
        if ((previousSource == 'sms') != (candidateSource == 'sms')) {
          continue;
        }
        return true;
      }

      if (previous.app != candidate.app) continue;

      final sameText = _normalizeText(previous.rawText) ==
          _normalizeText(candidate.rawText);
      final sources = <String>{previousSource, candidateSource};
      final crossedNotificationAccessibility =
          sources.length == 2 &&
          sources.contains('notification') &&
          sources.contains('accessibility');

      if (sameText || crossedNotificationAccessibility) {
        return true;
      }
    }

    _recent.add(candidate);
    if (_recent.length > maxEntries) {
      _recent.removeRange(0, _recent.length - maxEntries);
    }
    return false;
  }

  void clear() => _recent.clear();

  void _prune(DateTime current) {
    _recent.removeWhere((event) {
      final delta = current.isBefore(event.timestamp)
          ? event.timestamp.difference(current)
          : current.difference(event.timestamp);
      return delta > window;
    });
  }

  static String? _normalizedReference(String? value) {
    final normalized = (value ?? '').trim().toUpperCase();
    return normalized.isEmpty ? null : normalized;
  }

  static String _sourceChannel(String value) {
    final normalized = value.toLowerCase();
    if (normalized.contains('accessibility')) return 'accessibility';
    if (normalized.contains('notification')) return 'notification';
    if (normalized.contains('sms')) return 'sms';
    return normalized;
  }

  static String _normalizeText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u0080-\uFFFF]+'), ' ')
      .trim()
      .replaceAll(RegExp(r'\s+'), ' ');
}
