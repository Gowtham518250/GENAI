import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/bank_reconciliation_payload.dart';

void main() {
  test('builds the backend contract and keeps a selected calendar date', () {
    final payload = BankReconciliationPayload.build(
      reconDate: DateTime(2026, 10, 15, 23, 45),
      expectedUpiAmount: '1250',
      actualBankDeposit: '1249.50',
      notes: '  UPI batch 7  ',
    );

    expect(payload['recon_date'], '2026-10-15');
    expect(payload['expected_upi_amount'], 1250.0);
    expect(payload['actual_bank_deposit'], 1249.5);
    expect(payload['notes'], 'UPI batch 7');
    expect(payload.containsKey('bank_name'), isFalse);
    expect(payload.containsKey('amount'), isFalse);
    expect((payload['idempotency_key'] as String).length, lessThanOrEqualTo(128));
  });

  test('same financial submission produces a stable retry key', () {
    final first = BankReconciliationPayload.build(
      reconDate: DateTime(2026, 10, 15),
      expectedUpiAmount: '1250',
      actualBankDeposit: '1249.50',
      notes: 'UPI batch 7',
    );
    final retry = BankReconciliationPayload.build(
      reconDate: DateTime(2026, 10, 15, 19),
      expectedUpiAmount: '1250.00',
      actualBankDeposit: '1249.5',
      notes: ' UPI batch 7 ',
    );

    expect(retry['idempotency_key'], first['idempotency_key']);
  });

  test('different amounts produce different idempotency keys', () {
    final first = BankReconciliationPayload.build(
      reconDate: DateTime(2026, 10, 15),
      expectedUpiAmount: '1250.00',
      actualBankDeposit: '1250.00',
    );
    final corrected = BankReconciliationPayload.build(
      reconDate: DateTime(2026, 10, 15),
      expectedUpiAmount: '1250.00',
      actualBankDeposit: '1248.00',
    );

    expect(corrected['idempotency_key'], isNot(first['idempotency_key']));
  });

  test('rejects invalid and over-precision amounts', () {
    expect(
      () => BankReconciliationPayload.build(
        reconDate: DateTime(2026, 10, 15),
        expectedUpiAmount: '-5',
        actualBankDeposit: '10',
      ),
      throwsFormatException,
    );
    expect(
      () => BankReconciliationPayload.build(
        reconDate: DateTime(2026, 10, 15),
        expectedUpiAmount: '10.123',
        actualBankDeposit: '10',
      ),
      throwsFormatException,
    );
  });
}
