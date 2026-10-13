import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/transaction_reconciliation_helper.dart';

void main() {
  group('TransactionReconciliationHelper', () {
    test('serializes a localized event timestamp as explicit UTC', () {
      final local = DateTime(2026, 10, 13, 21, 47);
      final serialized =
          TransactionReconciliationHelper.serializeEventTime(local)!;

      expect(serialized.endsWith('Z'), isTrue);
      expect(DateTime.parse(serialized).toLocal(), local);
    });

    test('merges a local sale and its backend invoice by shared invoice number', () {
      final localSale = <String, dynamic>{
        'id': 'SALE_1791928020000000',
        'type': 'Cash Sale',
        'amount': 12.0,
        'raw': <String, dynamic>{
          'sale_id': 'SALE_1791928020000000',
          'offline_id': 'SALE_1791928020000000',
          'invoice_number': 'BILL-0007',
          'total_amount': 12.0,
        },
      };
      final backendInvoice = <String, dynamic>{
        'id': 'BILL-0007',
        'type': 'Invoice',
        'amount': 12.0,
        'items_count': 1,
        'raw': <String, dynamic>{
          'id': 42,
          'invoice_id': 42,
          'invoice_number': 'BILL-0007',
          'total_amount': 12.0,
        },
      };

      final result = TransactionReconciliationHelper.dedupe(
        [localSale, backendInvoice],
      );

      expect(result, hasLength(1));
      expect(result.single['type'], 'Invoice');
      expect(result.single['raw']['sale_id'], 'SALE_1791928020000000');
      expect(result.single['raw']['invoice_id'], 42);
    });

    test('does not merge different sales just because their content matches', () {
      final first = <String, dynamic>{
        'id': 'SALE_A',
        'type': 'Cash Sale',
        'amount': 12.0,
        'raw': <String, dynamic>{
          'sale_id': 'SALE_A',
          'invoice_number': 'BILL-0001',
          'total_amount': 12.0,
        },
      };
      final second = <String, dynamic>{
        'id': 'SALE_B',
        'type': 'Cash Sale',
        'amount': 12.0,
        'raw': <String, dynamic>{
          'sale_id': 'SALE_B',
          'invoice_number': 'BILL-0002',
          'total_amount': 12.0,
        },
      };

      expect(
        TransactionReconciliationHelper.dedupe([first, second]),
        hasLength(2),
      );
    });
  });
}
