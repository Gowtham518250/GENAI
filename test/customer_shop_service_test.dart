import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/customer_shop_service.dart';

void main() {
  group('Customer storefront product normalization', () {
    test('reads stock_available and unit_price from online-store API rows', () {
      final product = CustomerShopService.normalizeProduct({
        'id': 17,
        'name': 'Rice',
        'unit_price': 54.5,
        'stock_available': 8.0,
        'category': 'Groceries',
        'image_url': 'https://example.invalid/rice.png',
      });

      expect(product['id'], '17');
      expect(product['name'], 'Rice');
      expect(product['price'], 54.5);
      expect(product['stock'], 8);
      expect(product['stock_available'], 8);
      expect(product['category'], 'Groceries');
    });

    test('parses numeric stock strings and hides exhausted inventory', () {
      final fractionalNumeric = CustomerShopService.normalizeProduct({
        'id': 18,
        'product_name': 'Tea',
        'price': '120.00',
        'stock_available': '3.0',
      });
      final unavailable = CustomerShopService.normalizeProduct({
        'id': 19,
        'product_name': 'Out of stock',
        'price': 10,
        'stock_available': 0,
      });

      expect(fractionalNumeric['stock'], 3);
      expect(unavailable['stock'], 0);
      expect(unavailable['price'], 10.0);
    });
  });
}
