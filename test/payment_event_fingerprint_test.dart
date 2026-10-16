import 'package:flutter_test/flutter_test.dart';
import '../lib/payment_event.dart';

void main() {
  group('PaymentEvent fingerprint', () {
    test('matches same-day variants in the same five-minute slot', () {
      final first = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 11),
        app: PaymentApp.googlePay,
        rawText: '₹500 credited to your account',
      );
      final variant = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 14),
        app: PaymentApp.googlePay,
        rawText: '₹500 received',
      );

      expect(first.fingerprint, variant.fingerprint);
    });

    test('does not collide with the same amount and slot on another date', () {
      final today = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 11),
        app: PaymentApp.googlePay,
        rawText: '₹500 credited to your account',
      );
      final tomorrow = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 10, 10, 11),
        app: PaymentApp.googlePay,
        rawText: '₹500 credited to your account',
      );

      expect(today.fingerprint, isNot(tomorrow.fingerprint));
    });

    test('keeps native-script credit and debit fingerprints separate', () {
      final credit = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 11),
        app: PaymentApp.googlePay,
        rawText: 'మీ ఖాతాలో ₹500 జమ అయింది',
      );
      final debit = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 11),
        app: PaymentApp.googlePay,
        rawText: 'మీ ఖాతా నుండి ₹500 డెబిట్',
      );

      expect(credit.fingerprint, isNot(debit.fingerprint));
    });

    test('voice fingerprint preserves native-script wording', () {
      final first = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 11),
        app: PaymentApp.googlePay,
        rawText: 'మీ ఖాతాలో ₹500 జమ అయింది',
      );
      final differentText = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 11),
        app: PaymentApp.googlePay,
        rawText: 'మీకు ₹500 అందింది',
      );

      expect(first.fingerprint, differentText.fingerprint);
      expect(first.voiceFingerprint, isNot(differentText.voiceFingerprint));
    });

    test('keeps credit and debit fingerprints separate', () {
      final credit = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 11),
        app: PaymentApp.googlePay,
        rawText: '₹500 credited',
      );
      final debit = PaymentEvent(
        amount: 500,
        timestamp: DateTime(2026, 10, 9, 10, 11),
        app: PaymentApp.googlePay,
        rawText: '₹500 debited',
      );

      expect(credit.fingerprint, isNot(debit.fingerprint));
    });
  });
}
