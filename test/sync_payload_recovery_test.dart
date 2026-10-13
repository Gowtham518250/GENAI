import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/sync_payload_recovery.dart';

void main() {
  group('Legacy queued sale payload recovery', () {
    test('rebuilds a missing payload by stable sale identity without changing totals', () {
      final queueData = <String, dynamic>{
        'sale_id': 'offline-sale-42',
        'offline_id': 'offline-sale-42',
        'invoice_number': 'BILL-0042',
      };
      final localSales = <dynamic>[
        <String, dynamic>{
          'sale_id': 'offline-sale-42',
          'offline_id': 'offline-sale-42',
          'invoice_number': 'BILL-0042',
          'customer_name': 'Cash Customer',
          'business_date': '2026-10-13',
          'total_amount': 20.0,
          'paid_amount': '5.00',
          'tax': 0.0,
          'items': <dynamic>[
            <String, dynamic>{
              'product_id': 7,
              'product_name': 'Rice',
              'qty': 2,
              'price': 10.0,
              'total': 20.0,
            },
          ],
        },
      ];

      final payload = buildInvoicePayloadFromLocalSale(queueData, localSales);

      expect(payload, isNotNull);
      expect(payload!['invoice_number'], 'BILL-0042');
      expect(payload['offline_id'], 'offline-sale-42');
      expect(payload['invoice_date'], '2026-10-13');
      expect(payload['total_amount'], 20.0);
      expect(payload['paid_amount'], 5.0);
      expect(payload['payment_status'], 'PARTIAL');
      expect(payload['line_items'], [
        {
          'product_id': 7,
          'product_name': 'Rice',
          'quantity': 2.0,
          'unit_price': 10.0,
          'line_total': 20.0,
          'discount_amount': 0,
        },
      ]);
    });

    test('does not invent a business date for an old queued sale', () {
      final payload = buildInvoicePayloadFromLocalSale(
        <String, dynamic>{
          'sale_id': 'offline-sale-43',
          'invoice_number': 'BILL-0043',
        },
        <dynamic>[
          <String, dynamic>{
            'sale_id': 'offline-sale-43',
            'invoice_number': 'BILL-0043',
            'total_amount': 20.0,
            'paid_amount': 0.0,
            'items': <dynamic>[
              <String, dynamic>{
                'product_name': 'Rice',
                'qty': 2,
                'price': 10.0,
              },
            ],
          },
        ],
      );

      expect(payload, isNull);
    });

    test('does not reconstruct from a different sale with similar amounts', () {
      final payload = buildInvoicePayloadFromLocalSale(
        <String, dynamic>{
          'sale_id': 'offline-sale-missing',
          'invoice_number': 'BILL-0999',
        },
        <dynamic>[
          <String, dynamic>{
            'sale_id': 'offline-sale-other',
            'invoice_number': 'BILL-0001',
            'business_date': '2026-10-13',
            'total_amount': 20.0,
            'paid_amount': 0.0,
            'items': <dynamic>[
              <String, dynamic>{
                'product_name': 'Rice',
                'qty': 2,
                'price': 10.0,
              },
            ],
          },
        ],
      );

      expect(payload, isNull);
    });
  });
}
