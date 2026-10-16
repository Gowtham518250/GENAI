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
      }
    });
  });
}
