import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/expense_submission_identity.dart';

void main() {
  test('retries of the same normalized payload reuse the same key', () {
    final identity = ExpenseSubmissionIdentity();
    final first = identity.keyFor(
      category: 'Utilities',
      amount: 125.0,
      description: 'Electric bill',
      expenseDate: '2026-10-15',
      paymentMethod: 'cash',
    );
    final retry = identity.keyFor(
      category: 'utilities',
      amount: 125.00,
      description: ' Electric bill ',
      expenseDate: '2026-10-15',
      paymentMethod: 'CASH',
    );

    expect(retry, first);
    expect(first.length, 36);
  });

  test('edited payload receives a different key', () {
    final identity = ExpenseSubmissionIdentity();
    final first = identity.keyFor(
      category: 'Utilities',
      amount: 125.0,
      description: 'Electric bill',
      expenseDate: '2026-10-15',
      paymentMethod: 'cash',
    );
    final edited = identity.keyFor(
      category: 'Utilities',
      amount: 126.0,
      description: 'Electric bill',
      expenseDate: '2026-10-15',
      paymentMethod: 'cash',
    );

    expect(edited, isNot(first));
  });

  test('changing away and back preserves original key for that payload', () {
    final identity = ExpenseSubmissionIdentity();
    final original = identity.keyFor(
      category: 'Utilities',
      amount: 125.0,
      description: 'Electric bill',
      expenseDate: '2026-10-15',
      paymentMethod: 'cash',
    );
    identity.keyFor(
      category: 'Utilities',
      amount: 130.0,
      description: 'Electric bill',
      expenseDate: '2026-10-15',
      paymentMethod: 'cash',
    );
    final again = identity.keyFor(
      category: 'Utilities',
      amount: 125.0,
      description: 'Electric bill',
      expenseDate: '2026-10-15',
      paymentMethod: 'cash',
    );

    expect(again, original);
  });
}
