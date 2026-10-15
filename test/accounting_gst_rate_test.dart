import 'package:flutter_test/flutter_test.dart';
import '../lib/accounting_integration.dart';

void main() {
  group('GST accounting exports', () {
    test('uses each sale GST rate instead of assuming 18 percent', () {
      final report = AccountingIntegration.generateGSTReport(
        [
          {'date': '2026-10-01', 'product': 'A', 'total': 105.0, 'gstRate': 5.0, 'tax': 5.0},
          {'date': '2026-10-02', 'product': 'B', 'total': 112.0, 'gst_rate': 12.0, 'tax_amount': 12.0},
          {'date': '2026-10-03', 'product': 'C', 'total': 118.0, 'tax_rate': 18.0},
        ],
        gstIn: 'TEST-GSTIN',
        shopName: 'Test Shop',
        period: 'Test Period',
      );
      final summary = report['summary'] as Map<String, dynamic>;
      final rows = report['transactions'] as List<dynamic>;
      expect(summary['totalSales'], 335.0);
      expect(summary['totalTax'], 35.0);
      expect(rows[0]['gst'], 5.0);
      expect(rows[1]['gst'], 12.0);
      expect(rows[2]['gst'], 18.0);
      expect(rows[0]['gstRate'], '5%');
      expect(rows[1]['gstRate'], '12%');
      expect(rows[2]['gstRate'], '18%');
      expect((report['breakdown'] as List).map((row) => (row as Map)['gstRate']).toList(), ['5%', '12%', '18%']);
    });

    test('does not invent a GST rate when metadata is missing', () {
      final report = AccountingIntegration.generateGSTReport(
        [{'date': '2026-10-01', 'product': 'Unknown rate', 'total': 118.0}],
        gstIn: 'TEST-GSTIN',
        shopName: 'Test Shop',
        period: 'Test Period',
      );
      final summary = report['summary'] as Map<String, dynamic>;
      final row = (report['transactions'] as List).single as Map;
      expect(row['gst'], isNull);
      expect(row['gstRate'], 'UNSPECIFIED');
      expect(row['needsReview'], isTrue);
      expect(summary['totalTax'], 0.0);
      expect(summary['unclassifiedCount'], 1);
      expect(summary['unclassifiedSalesAmount'], 118.0);
    });

    test('Tally XML carries tax per sale and flags missing metadata', () {
      final xml = AccountingIntegration.generateTallyXML(
        [
          {'invoice_number': 'A-1', 'product': 'Goods & More', 'total': 105.0, 'gstRate': 5.0, 'tax': 5.0},
          {'invoice_number': 'A-2', 'product': 'Unknown', 'total': 100.0},
        ],
        shopName: 'Test & Shop',
        gstIn: 'TEST-GSTIN',
      );
      expect(xml, contains('<GSTRATE>5%</GSTRATE>'));
      expect(xml, contains('<GSTAMOUNT>5.00</GSTAMOUNT>'));
      expect(xml, contains('<TAXABLE>100.00</TAXABLE>'));
      expect(xml, contains('<TAXREVIEW>TRUE</TAXREVIEW>'));
      expect(xml, contains('Goods &amp; More'));
      expect(xml, contains('Test &amp; Shop'));
    });
  });
}
