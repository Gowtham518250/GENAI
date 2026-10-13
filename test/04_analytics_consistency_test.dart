import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/analytics_engine.dart';
import 'package:retail_mind/invoice_analytics_snapshot.dart';

void main() {
  group('P0/P1 Analytics integrity', () {
    test('placeholder product names are detected', () {
      final engine = AnalyticsEngine();

      expect(AnalyticsEngine.isPlaceholderProductName('Product'), isTrue);
      expect(AnalyticsEngine.isPlaceholderProductName('Unknown'), isTrue);
      expect(AnalyticsEngine.isPlaceholderProductName('sale_123'), isTrue);
      expect(AnalyticsEngine.isPlaceholderProductName('invoice_77'), isTrue);
      expect(AnalyticsEngine.isPlaceholderProductName('Aashirvaad Atta'), isFalse);
    });

    test('same sale data produces expected lifetime totals', () {
      final engine = AnalyticsEngine();

      engine.recalculateAnalytics([
        {
          'sale_id': 'SALE-1',
          'business_date': '2026-08-13T10:00:00Z',
          'total': 10,
          'items': [
            {
              'product_id': 1,
              'product_name': 'Rice',
              'quantity': 1,
              'price': 10,
            }
          ],
        },
        {
          'sale_id': 'SALE-2',
          'business_date': '2026-08-13T11:00:00Z',
          'total': 20,
          'items': [
            {
              'product_id': 2,
              'product_name': 'Oil',
              'quantity': 1,
              'price': 20,
            }
          ],
        },
      ], 0);

      expect(engine.totalSales, 30);
      expect(engine.totalTransactions, 2);
    });

    test('four line items remain attached to one sale', () {
      final engine = AnalyticsEngine();

      engine.recalculateAnalytics([
        {
          'sale_id': 'SALE-4',
          'business_date': '2026-08-13T12:00:00Z',
          'total': 100,
          'items': [
            {'product_id': 1, 'product_name': 'A', 'quantity': 1, 'price': 10},
            {'product_id': 2, 'product_name': 'B', 'quantity': 1, 'price': 20},
            {'product_id': 3, 'product_name': 'C', 'quantity': 1, 'price': 30},
            {'product_id': 4, 'product_name': 'D', 'quantity': 1, 'price': 40},
          ],
        },
      ], 0);

      expect(engine.totalSales, 100);
      expect(engine.totalTransactions, 1);
    });

    test('invoice analytics keeps paid invoices and aggregates all payment states', () {
      final snapshot = InvoiceAnalyticsSnapshot.fromRows(
        [
          {
            'invoice_number': 'BILL-0001',
            'customer_name': 'Paid Customer',
            'customer_phone': '9876543210',
            'total_amount': 100.0,
            'paid_amount': 100.0,
          },
          {
            'invoice_number': 'BILL-0002',
            'customer_name': 'Partial Customer',
            'customer_phone': '9876543211',
            'total_amount': 80.0,
            'paid_amount': 30.0,
          },
          {
            'invoice_number': 'BILL-0003',
            'customer_name': 'Guest Customer',
            'total_amount': 25.0,
            'paid_amount': 0.0,
          },
        ],
        isValidCustomerPhone: (phone) =>
            RegExp(r'^[6-9][0-9]{9}$').hasMatch(phone),
      );

      expect(snapshot.invoices, hasLength(3));
      expect(snapshot.invoices.first['payment_status'], 'PAID');
      expect(snapshot.paidCount, 1);
      expect(snapshot.partialCount, 1);
      expect(snapshot.unpaidCount, 1);
      expect(snapshot.totalInvoiced, 205.0);
      expect(snapshot.totalPaid, 130.0);
      expect(snapshot.totalPending, 75.0);
      expect(snapshot.outstandingCreditInvoices, hasLength(1));
      expect(
        snapshot.outstandingCreditInvoices.single['invoice_number'],
        'BILL-0002',
      );
    });

  });
}
