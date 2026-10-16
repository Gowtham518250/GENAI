import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:retail_mind/app_localizations.dart';

void main() {
  group('AppLocalizations coverage', () {
    test('every supported language resolves shared and customer auth labels', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = AppLocalizations(locale);
        expect(l.translate('dashboard'), isNot('dashboard'),
            reason: 'dashboard must resolve for ${locale.languageCode}');
        if (locale.languageCode != 'en') {
          expect(l.translate('dashboard'), isNot('Dashboard'),
              reason: 'dashboard should be translated for ${locale.languageCode}');
        }
        expect(l.translate('backToHome'), isNot('backToHome'),
            reason: 'backToHome must resolve for ${locale.languageCode}');
        expect(l.translate('resetCustomerPassword'), isNot('resetCustomerPassword'),
            reason: 'password reset label must resolve for ${locale.languageCode}');
        expect(l.translate('phoneTenDigits'), isNot('phoneTenDigits'),
            reason: 'phone label must resolve for ${locale.languageCode}');
        if (locale.languageCode != 'en') {
          expect(l.translate('generateBill'), isNot('Generate Bill'),
              reason: 'billing action must be translated for ${locale.languageCode}');
          expect(l.translate('paymentMethod'), isNot('Payment Method'),
              reason: 'payment label must be translated for ${locale.languageCode}');
          expect(l.translate('salesByMonth'), isNot('Sales by Month'),
              reason: 'sales analytics label must be translated for ${locale.languageCode}');
        } else {
          expect(l.translate('generateBill'), 'Generate Bill');
          expect(l.translate('paymentMethod'), 'Payment Method');
          expect(l.translate('salesByMonth'), 'Sales by Month');
        }
      }
    });
  });

  test('payment status and payment-provenance copy exists in every supported locale', () {
    const keys = [
      'paymentStatusLine',
      'paymentMatchedNotificationHint',
      'paymentPendingHint',
      'paymentStatusPaid',
      'paymentStatusPending',
      'paymentStatusCodDue',
      'paymentStatusFailed',
      'paymentStatusRefund',
      'paymentStatusPartial',
    ];
    final english = AppLocalizations(const Locale('en'));
    for (final locale in AppLocalizations.supportedLocales) {
      final localizations = AppLocalizations(locale);
      for (final key in keys) {
        final translated = localizations.translate(key);
        expect(translated, isNot(key),
            reason: '$key must resolve for ${locale.languageCode}');
        if (locale.languageCode != 'en') {
          expect(translated, isNot(english.translate(key)),
              reason: '$key must not silently fall back to English for ${locale.languageCode}');
        }
      }
    }
  });
}
