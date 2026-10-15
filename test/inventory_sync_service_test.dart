import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/inventory_sync_service.dart';

void main() {
  group('InventorySyncService stock quantity preparation', () {
    test('preserves fractional stock quantities to three decimal places', () {
      expect(InventorySyncService.parsePositiveQuantity('1.750'), 1.75);
      expect(InventorySyncService.parsePositiveQuantity(0.875), 0.875);
      expect(InventorySyncService.parsePositiveQuantity(2), 2);
    });

    test('rejects invalid or over-precision quantities', () {
      expect(InventorySyncService.parsePositiveQuantity('0'), isNull);
      expect(InventorySyncService.parsePositiveQuantity('-1'), isNull);
      expect(InventorySyncService.parsePositiveQuantity('NaN'), isNull);
      expect(InventorySyncService.parsePositiveQuantity('1.2345'), isNull);
      expect(InventorySyncService.parsePositiveQuantity('not a number'), isNull);
    });

    test('aggregates duplicate product lines into one stable stock operation', () {
      final result = InventorySyncService.prepareBatchStockUpdates([
        {
          'id': 7,
          'quantity': 1.250,
          'invoice_number': 'BILL-0007',
        },
        {
          'product_id': 7,
          'qty': '0.750',
          'reference_id': 'BILL-0007',
        },
        {
          'product_id': 8,
          'qty': 2,
          'reference_id': 'BILL-0007',
        },
      ]);

      expect(result['valid'], isTrue);
      final updates = List<Map<String, dynamic>>.from(result['updates'] as List);
      expect(updates, hasLength(2));
      final product7 = updates.singleWhere((row) => row['product_id'] == 7);
      expect(product7['quantity'], 2.0);
      expect(product7['reason'], 'INVOICE_SYNC');
      expect(product7['reference_id'], 'BILL-0007');
      expect(product7['idempotency_key'], isA<String>());
      expect((product7['idempotency_key'] as String).length, 64);
    });

    test('same input produces same idempotency key and invalid rows stop the batch', () {
      final input = [
        {'product_id': 7, 'quantity': 1, 'reference_id': 'BILL-12'},
      ];
      final first = InventorySyncService.prepareBatchStockUpdates(input);
      final second = InventorySyncService.prepareBatchStockUpdates(input);
      expect(
        (first['updates'] as List).first['idempotency_key'],
        (second['updates'] as List).first['idempotency_key'],
      );

      final invalid = InventorySyncService.prepareBatchStockUpdates([
        {'product_id': 7, 'quantity': 1.2345, 'reference_id': 'BILL-12'},
      ]);
      expect(invalid['valid'], isFalse);
      expect(invalid['updates'], isEmpty);
      expect(invalid['errors'], isNotEmpty);
    });
  });
}
