import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:retail_mind/services/order_history_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'role': 'customer',
      'user_type': 'CUSTOMER',
      'user_id': '42',
      'order_history_CUSTOMER_42': jsonEncode([
        {
          'order_id': '900',
          'server_order_id': '900',
          'local_order_id': 'LOCAL_ORDER_1',
          'sync_status': 'synced',
          'status': 'PENDING',
          'total_amount': 300,
          'total': 300,
          'created_at': '2026-10-15T14:00:00Z',
          'items': <dynamic>[],
        },
        {
          'order_id': 'LOCAL_ORDER_2',
          'local_order_id': 'LOCAL_ORDER_2',
          'sync_status': 'pending',
          'status': 'PENDING_SYNC',
          'total_amount': 12,
          'total': 12,
          'created_at': '2026-10-15T15:00:00Z',
          'items': <dynamic>[],
        },
      ]),
    });
  });

  test('remote order refresh updates a local mirror without duplicating it', () async {
    final merged = await OrderHistoryService.mergeRemoteOrders([
      {
        'order_id': 900,
        'shop_name': 'Corner Shop',
        'status': 'ACCEPTED',
        'total_amount': 275.0,
        'created_at': '2026-10-15T14:00:00Z',
        'items': [
          {'product_id': 5, 'quantity': 1},
        ],
      },
      {
        'order_id': 901,
        'shop_name': 'Market Shop',
        'status': 'PENDING',
        'total_amount': 85.0,
        'created_at': '2026-10-16T08:00:00Z',
        'items': <dynamic>[],
      },
    ]);

    expect(merged, hasLength(3));
    final refreshed = merged.singleWhere((order) => order['order_id'] == '900');
    expect(refreshed['status'], 'ACCEPTED');
    expect(refreshed['total_amount'], 275.0);
    expect(refreshed['shop_name'], 'Corner Shop');
    expect(refreshed['local_order_id'], 'LOCAL_ORDER_1');

    final newRemote = merged.singleWhere((order) => order['order_id'] == '901');
    expect(newRemote['sync_status'], 'synced');

    final pendingLocal =
        merged.singleWhere((order) => order['order_id'] == 'LOCAL_ORDER_2');
    expect(pendingLocal['status'], 'PENDING_SYNC');
    expect(pendingLocal['sync_status'], 'pending');
  });

  test('server pending statuses are available to the order filter UI', () {
    expect(OrderHistoryService.orderStatuses, contains('PENDING'));
    expect(OrderHistoryService.orderStatuses, contains('ACCEPTED'));
  });
}
