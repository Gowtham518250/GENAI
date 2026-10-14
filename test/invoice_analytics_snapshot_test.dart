import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/invoice_analytics_snapshot.dart';

void main() {
  group('Invoice analytics and Khata eligibility', () {
    test('draft and cancelled invoices remain visible but are not receivables', () {
      final snapshot = InvoiceAnalyticsSnapshot.fromRows(
        [
          {
            'invoice_number': 'INV-OPEN',
            'customer_name': 'Alice',
            'customer_phone': '9876543210',
            'total_amount': 100,
            'paid_amount': 20,
            'status': 'SENT',
          },
          {
            'invoice_number': 'INV-DRAFT',
            'customer_name': 'Bob',
            'customer_phone': '9876543211',
            'total_amount': 500,
            'paid_amount': 0,
            'status': 'DRAFT',
          },
          {
            'invoice_number': 'INV-CANCELLED',
            'customer_name': 'Carol',
            'customer_phone': '9876543212',
            'total_amount': 900,
            'paid_amount': 0,
            'status': 'InvoiceStatus.CANCELLED',
          },
        ],
        isValidCustomerPhone: (phone) => phone.length == 10,
      );

      expect(snapshot.invoices, hasLength(3));
      expect(snapshot.totalInvoiced, 100);
      expect(snapshot.totalPaid, 20);
      expect(snapshot.totalPending, 80);
      expect(snapshot.unpaidCount, 0);
      expect(snapshot.partialCount, 1);
      expect(snapshot.outstandingCreditInvoices, hasLength(1));
      expect(snapshot.outstandingCreditInvoices.single['invoice_number'], 'INV-OPEN');
      expect(
        snapshot.invoices.firstWhere((row) => row['invoice_number'] == 'INV-DRAFT')['payment_status'],
        'DRAFT',
      );
      expect(
        snapshot.invoices.firstWhere((row) => row['invoice_number'] == 'INV-CANCELLED')['payment_status'],
        'CANCELLED',
      );
    });
  });
}
