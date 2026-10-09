import 'package:flutter_test/flutter_test.dart';
import '../lib/payment_notification_parser.dart';

void main() {
  group('PaymentNotificationParser', () {
    test('combines primary and expanded notification text', () {
      final text = PaymentNotificationParser.combine([
        'PhonePe',
        'Received ₹10',
        'from Gowtham',
        ['UPI Ref: 123456789012'],
      ]);

      expect(text, contains('PhonePe'));
      expect(text, contains('Received ₹10'));
      expect(text, contains('UPI Ref: 123456789012'));
    });

    test('normalizes whitespace and removes repeated fields', () {
      expect(
        PaymentNotificationParser.combine([
          'Received   ₹10',
          ' received ₹10 ',
          '  credited\\n  successfully ',
        ]),
        'Received ₹10 credited successfully',
      );
    });

    test('reads string values from grouped-message maps', () {
      final text = PaymentNotificationParser.combine([
        {'title': 'Payment received', 'body': '₹10 credited'},
      ]);

      expect(text, 'Payment received ₹10 credited');
    });

    test('ignores empty and non-text values', () {
      expect(
        PaymentNotificationParser.combine([null, '', '   ', 123, false]),
        isEmpty,
      );
    });
  });
}
