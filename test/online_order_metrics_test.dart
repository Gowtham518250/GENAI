import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/online_order_service.dart';

void main() {
  group('OnlineOrderService.countDistinctOnlineOrdersFromSales', () {
    test('counts one order once when it creates multiple sales rows', () {
      final rows = <Map<String, dynamic>>[
        {
          'source': 'ONLINE_ORDER',
          'id': 1001,
          'reference_order_id': 42,
          'invoice_number': 'ONL-42-123',
          'total': 85.0,
        },
        {
          'source': 'ONLINE_ORDER',
          'id': 1002,
          'reference_order_id': 42,
          'invoice_number': 'ONL-42-123',
          'total': 15.0,
        },
        {
          'source': 'ONLINE_ORDER',
          'id': 1003,
          'reference_order_id': 43,
          'invoice_number': 'ONL-43-123',
          'total': 100.0,
        },
        {
          'source': 'OFFLINE',
          'id': 1004,
          'total': 250.0,
        },
      ];

      expect(
        OnlineOrderService.countDistinctOnlineOrdersFromSales(rows),
        2,
      );
    });

    test('falls back to a canonical online invoice when order ID is absent', () {
      final rows = <Map<String, dynamic>>[
        {'invoice_number': 'ONL-44-123', 'total': 85.0},
        {'invoice_number': 'ONL-44-123', 'total': 5.0},
        {'invoice_number': 'BILL-0044', 'source': 'OFFLINE', 'total': 90.0},
      ];

      expect(
        OnlineOrderService.countDistinctOnlineOrdersFromSales(rows),
        1,
      );
    });

    test('does not interpret sales currency amounts as order counts', () {
      final rows = <Map<String, dynamic>>[
        {
          'source': 'ONLINE',
          'reference_order_id': 99,
          'total': 85.0,
        },
      ];

      expect(
        OnlineOrderService.countDistinctOnlineOrdersFromSales(rows),
        1,
      );
    });
  });
}
