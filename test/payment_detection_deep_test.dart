import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/payment_detection_service.dart';
import 'package:retail_mind/payment_event.dart';
import 'package:retail_mind/language_engine.dart';
import 'package:retail_mind/humanizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Payment Detection Real World Scenarios', () {
    test('Google Pay Merchant Notification is confirmed and not rejected', () {
      final text = "Received ₹ 250.00 from SHUBHAM KUMAR via Google Pay";
      final event = PaymentDetectionService.analyze(
        text: text,
        source: 'notification',
        sender: null,
        amount: 250.0,
        utr: null,
        vpa: null,
      );
      expect(event.decision, equals(PaymentDecision.confirmed));
      expect(event.confidenceScore, greaterThanOrEqualTo(0.70));
      expect(event.app, equals(PaymentApp.googlePay));
    });

    test('PhonePe Business Notification is confirmed', () {
      final text = "Payment of ₹150 received from Amit on PhonePe";
      final event = PaymentDetectionService.analyze(
        text: text,
        source: 'notification',
        sender: null,
        amount: 150.0,
        utr: null,
        vpa: null,
      );
      expect(event.decision, equals(PaymentDecision.confirmed));
      expect(event.confidenceScore, greaterThanOrEqualTo(0.70));
      expect(event.app, equals(PaymentApp.phonePe));
    });

    test('Paytm Business Notification is confirmed', () {
      final text = "Received ₹500 from Ramesh via Paytm UPI";
      final event = PaymentDetectionService.analyze(
        text: text,
        source: 'notification',
        sender: null,
        amount: 500.0,
        utr: null,
        vpa: null,
      );
      expect(event.decision, equals(PaymentDecision.confirmed));
      expect(event.confidenceScore, greaterThanOrEqualTo(0.70));
      expect(event.app, equals(PaymentApp.paytm));
    });

    test('HDFC Bank SMS is confirmed with high confidence', () {
      final text = "Dear Customer, A/c *1234 credited with INR 500.00 on 29-Sep-26 by UPI/412345678901/Rahul (UPI). Avl Bal: INR 12500.00 - HDFC Bank";
      final event = PaymentDetectionService.analyze(
        text: text,
        source: 'sms',
        sender: 'VM-HDFCBK',
        amount: 500.0,
        utr: '412345678901',
        vpa: null,
      );
      expect(event.decision, equals(PaymentDecision.confirmed));
      expect(event.confidenceScore, greaterThanOrEqualTo(0.85));
      expect(event.app, equals(PaymentApp.bankSms));
    });

    test('Extraction of amounts with Indian comma formatting', () {
      expect(PaymentDetectionService.debugExtractAmount('₹ 1,250 received via UPI'), equals(1250.0));
      expect(PaymentDetectionService.debugExtractAmount('Received ₹ 250.00 from Amit'), equals(250.0));
      expect(PaymentDetectionService.debugExtractAmount('Rs. 10,000 credited to account'), equals(10000.0));
    });
  });

  group('Payment Announcement and Voice Generation', () {
    test('LanguageEngine resolves all major Indian languages', () {
      final engine = LanguageEngine();
      expect(engine.resolve('en-US').locale, equals('en-IN'));
      expect(engine.resolve('hi-IN').locale, equals('hi-IN'));
      expect(engine.resolve('ta-IN').locale, equals('ta-IN'));
      expect(engine.resolve('te-IN').locale, equals('te-IN'));
      expect(engine.resolve('kn-IN').locale, equals('kn-IN'));
      expect(engine.resolve('mr-IN').locale, equals('mr-IN'));
      expect(engine.resolve('gu-IN').locale, equals('gu-IN'));
      expect(engine.resolve('bn-IN').locale, equals('bn-IN'));
      expect(engine.resolve('pa-IN').locale, equals('pa-IN'));
      expect(engine.resolve('ml-IN').locale, equals('ml-IN'));
    });

    test('VoiceBuilder produces correct phrase in English and Hindi', () {
      final enText = VoiceBuilder.received(250, 'Rahul', VoiceLanguage.english);
      expect(enText, contains('250'));
      expect(enText, contains('Rahul'));

      final hiText = VoiceBuilder.received(500, 'Amit', VoiceLanguage.hindi);
      expect(hiText, contains('पेमेंट मिला'));
      expect(hiText, contains('Amit'));
    });

    test('Humanizer processes payment text into natural speakable chunks', () {
      final humanizer = Humanizer();
      final result = humanizer.process(
        rawText: '250 rupees received from Rahul, thank you',
        style: VoiceStyle.friendly,
        langKey: 'en',
      );
      expect(result.text.isNotEmpty, isTrue);
      expect(result.chunks.isNotEmpty, isTrue);
      expect(result.rate, greaterThan(0.0));
    });
  });
}
