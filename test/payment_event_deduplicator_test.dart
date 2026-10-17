import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/payment_event.dart';
import 'package:retail_mind/payment_event_deduplicator.dart';

void main() {
  group('RecentPaymentEventDeduplicator', () {
    final deduplicator = RecentPaymentEventDeduplicator();

    setUp(() => deduplicator.clear());

    test('suppresses same credit delivered by notification and accessibility', () {
      final time = DateTime(2026, 10, 17, 10, 0);
      final notification = PaymentEvent(
        amount: 500,
        timestamp: time,
        app: PaymentApp.phonePe,
        rawText: 'Received ₹500 from Gowtham via PhonePe',
        detectionSource: 'notification',
      );
      final accessibility = PaymentEvent(
        amount: 500,
        timestamp: time.add(const Duration(seconds: 2)),
        app: PaymentApp.phonePe,
        rawText: 'PhonePe Payment received Rs 500',
        detectionSource: 'accessibility',
      );

      expect(deduplicator.isDuplicate(notification), isFalse);
      expect(deduplicator.isDuplicate(accessibility), isTrue);
    });

    test('never collapses two payments with different references', () {
      final time = DateTime(2026, 10, 17, 10, 0);
      final first = PaymentEvent(
        amount: 500,
        timestamp: time,
        app: PaymentApp.phonePe,
        referenceId: 'UTR10001',
        rawText: '₹500 credited',
        detectionSource: 'notification',
      );
      final second = PaymentEvent(
        amount: 500,
        timestamp: time.add(const Duration(seconds: 1)),
        app: PaymentApp.phonePe,
        referenceId: 'UTR10002',
        rawText: '₹500 credited',
        detectionSource: 'accessibility',
      );

      expect(deduplicator.isDuplicate(first), isFalse);
      expect(deduplicator.isDuplicate(second), isFalse);
    });

    test('does not collapse different amounts or transaction directions', () {
      final time = DateTime(2026, 10, 17, 10, 0);
      final credit = PaymentEvent(
        amount: 500,
        timestamp: time,
        app: PaymentApp.phonePe,
        rawText: '₹500 credited to account',
        detectionSource: 'notification',
      );
      final otherAmount = PaymentEvent(
        amount: 600,
        timestamp: time.add(const Duration(seconds: 1)),
        app: PaymentApp.phonePe,
        rawText: '₹600 credited to account',
        detectionSource: 'accessibility',
      );
      final debit = PaymentEvent(
        amount: 500,
        timestamp: time.add(const Duration(seconds: 2)),
        app: PaymentApp.phonePe,
        rawText: '₹500 debited from account',
        detectionSource: 'accessibility',
      );

      expect(deduplicator.isDuplicate(credit), isFalse);
      expect(deduplicator.isDuplicate(otherAmount), isFalse);
      expect(deduplicator.isDuplicate(debit), isFalse);
    });

    test('same text after the short window is treated as a new transaction', () {
      final time = DateTime(2026, 10, 17, 10, 0);
      final first = PaymentEvent(
        amount: 500,
        timestamp: time,
        app: PaymentApp.googlePay,
        rawText: '₹500 credited',
        detectionSource: 'notification',
      );
      final later = PaymentEvent(
        amount: 500,
        timestamp: time.add(const Duration(seconds: 20)),
        app: PaymentApp.googlePay,
        rawText: '₹500 credited',
        detectionSource: 'notification',
      );

      expect(deduplicator.isDuplicate(first), isFalse);
      expect(deduplicator.isDuplicate(later), isFalse);
    });
  });
}
