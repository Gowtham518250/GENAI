import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/sales_dedup_helper.dart';
import 'package:retail_mind/invoice_dedup_helper.dart';

Map<String, dynamic> sale(String id) => {
  'sale_id': id,
  'offline_id': id,
  'invoice_number': id,
  'business_date': '2026-08-13T18:00:00Z',
  'total': 50.0,
  'items': [
    {
      'product_id': 1,
      'product_name': 'Product A',
      'qty': 1,
      'price': 50.0,
      'total': 50.0,
    }
  ],
};

void main() {
  group('P0 Sales identity / deduplication', () {
    test('two different stable sale IDs remain two sales', () {
      final result = SalesDedupHelper.dedupeBills([
        sale('SALE_100'),
        sale('SALE_101'),
      ]);

      expect(result.length, 2);
      expect(result.map((e) => e['sale_id']).toSet(),
          containsAll(<String>{'SALE_100', 'SALE_101'}));
    });

    test('same stable sale ID is collapsed to one logical sale', () {
      final result = SalesDedupHelper.dedupeBills([
        sale('SALE_100'),
        {
          ...sale('SALE_100'),
          'customer_name': 'Updated Customer',
        },
      ]);

      expect(result.length, 1);
      expect(result.single['sale_id'], 'SALE_100');
    });

    test('content-identical rapid sales are not treated as duplicates', () {
      final a = sale('SALE_100');
      final b = sale('SALE_101');

      expect(
        SalesDedupHelper.isDuplicateBill(a, [b]),
        isFalse,
      );
    });

    test('same sale is detected by stable identity', () {
      final a = sale('SALE_100');
      final b = sale('SALE_100');

      expect(
        SalesDedupHelper.isDuplicateBill(a, [b]),
        isTrue,
      );
    });

    test('local SALE ID and cloud BILL ID are recognized as one bill', () {
      final local = {
        ...sale('SALE_100'),
        'invoice_number': 'BILL-0007',
        'bill_number': 'BILL-0007',
      };
      final cloud = {
        ...sale('BILL-0007'),
        'id': 42,
        'invoice_id': 42,
        'invoice_number': 'BILL-0007',
        'sale_id': 'BILL-0007',
        'offline_id': null,
        'backend_id': 42,
      };

      expect(SalesDedupHelper.isDuplicateBill(cloud, [local]), isTrue);
      final result = SalesDedupHelper.dedupeBills([local, cloud]);
      expect(result, hasLength(1));
      expect(result.single['invoice_number'], 'BILL-0007');
      expect(result.single['sale_id'], 'SALE_100');
      expect(result.single['invoice_id'], 42);
    });

    test('a numeric backend ID never matches a numeric bill number by accident', () {
      final backend = {'id': 12};
      final local = {'invoice_number': '12', 'total': 50.0, 'items': [{'name': 'A'}]};

      expect(
        InvoiceDedupHelper.sameInvoice(backend, local),
        isFalse,
      );
    });
  });
}
