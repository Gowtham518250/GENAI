import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/analytics_engine.dart';

void main() {
  group('sales performance timestamp and product revenue regressions', () {
    test('hourly analytics uses event timestamp, not date-only business date', () {
      final engine = AnalyticsEngine();
      final raw = {
        'business_date': '2026-10-15',
        'created_at': '2026-10-15T17:45:32Z',
      };

      expect(engine.getLocalDate(raw).hour, 0);
      expect(
        engine.getEventDate(raw).toUtc(),
        DateTime.utc(2026, 10, 15, 17, 45, 32),
      );
    });

    test('today top product uses nested line_items and description fallback', () {
      final now = DateTime.now();
      final businessDate =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final engine = AnalyticsEngine();

      engine.recalculateAnalytics([
        {
          'sale_id': 'INV-REGRESSION-1',
          'business_date': businessDate,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'total_amount': 240.0,
          'line_items': [
            {
              'product_id': null,
              'description': 'Custom Grocery Bundle',
              'quantity': 2,
              'unit_price': 120.0,
              'line_total': 240.0,
            },
          ],
        },
      ], 0);

      expect(engine.todaySalesValue, 240.0);
      expect(engine.todayTopProduct, 'Custom Grocery Bundle');
    });
  });
}
