import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/sale_payment_policy.dart';

void main() {
  group('POS sale payment policy', () {
    test('regular cash sale defaults to fully paid when no partial receipt was entered', () {
      expect(
        SalePaymentPolicy.resolvePaidAmount(
          totalAmount: 12,
          enteredPaidAmount: 0,
          isBorrow: false,
          isCashPayment: true,
          paymentConfirmed: false,
        ),
        12,
      );
    });

    test('an explicitly recorded partial cash receipt remains partial', () {
      expect(
        SalePaymentPolicy.resolvePaidAmount(
          totalAmount: 100,
          enteredPaidAmount: 30,
          isBorrow: false,
          isCashPayment: true,
          paymentConfirmed: false,
        ),
        30,
      );
    });

    test('confirmed online checkout with no explicit amount is fully paid', () {
      expect(
        SalePaymentPolicy.resolvePaidAmount(
          totalAmount: 85,
          enteredPaidAmount: 0,
          isBorrow: false,
          isCashPayment: false,
          paymentConfirmed: true,
        ),
        85,
      );
    });

    test('unconfirmed online checkout cannot be recorded as paid', () {
      expect(
        SalePaymentPolicy.resolvePaidAmount(
          totalAmount: 85,
          enteredPaidAmount: 0,
          isBorrow: false,
          isCashPayment: false,
          paymentConfirmed: false,
        ),
        0,
      );
    });

    test('borrow invoices stay credit even if an amount was selected elsewhere', () {
      expect(
        SalePaymentPolicy.resolvePaidAmount(
          totalAmount: 100,
          enteredPaidAmount: 100,
          isBorrow: true,
          isCashPayment: true,
          paymentConfirmed: true,
        ),
        0,
      );
    });

    test('received amount is never allowed to exceed the invoice total', () {
      expect(
        SalePaymentPolicy.resolvePaidAmount(
          totalAmount: 100,
          enteredPaidAmount: 140,
          isBorrow: false,
          isCashPayment: true,
          paymentConfirmed: false,
        ),
        100,
      );
    });
  });
}
