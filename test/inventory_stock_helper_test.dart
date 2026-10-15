import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/inventory_stock_helper.dart';

void main() {
  group('InventoryStockHelper.parseProductsResponse', () {
    final product = <String, dynamic>{
      'id': 7,
      'name': 'Rice',
      'stock': '12.5',
      'min_stock': '4',
    };

    test('accepts a direct product list', () {
      final result = InventoryStockHelper.parseProductsResponse([product]);

      expect(result, hasLength(1));
      expect(result.single['id'], 7);
      expect(result.single['product_name'], 'Rice');
      expect(result.single['current_stock'], 12.5);
      expect(result.single['quantity'], 12.5);
    });

    for (final key in ['data', 'products', 'results', 'items']) {
      test('accepts a $key envelope', () {
        final result = InventoryStockHelper.parseProductsResponse({
          key: [product],
        });

        expect(result, hasLength(1));
        expect(result.single['product_name'], 'Rice');
      });
    }

    test('accepts nested envelopes and JSON-encoded lists', () {
      final response = jsonEncode({
        'data': jsonEncode({
          'items': [product],
        }),
      });

      final result = InventoryStockHelper.parseProductsResponse(response);

      expect(result, hasLength(1));
      expect(result.single['product_id'], 7);
    });

    test('accepts a JSON-encoded direct list', () {
      final result = InventoryStockHelper.parseProductsResponse(
        jsonEncode([product]),
      );
      expect(result, hasLength(1));
    });

    test('accepts a single product object', () {
      final result = InventoryStockHelper.parseProductsResponse(product);
      expect(result, hasLength(1));
      expect(result.single['id'], 7);
    });

    test('preserves a valid empty product list', () {
      expect(InventoryStockHelper.parseProductsResponse({'data': []}), isEmpty);
    });

    test('rejects an unknown response envelope instead of showing false empty inventory', () {
      expect(
        () => InventoryStockHelper.parseProductsResponse({'message': 'temporarily unavailable'}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  test('deduplicates API products and does not resurrect acknowledged stale cache rows', () {
    final result = InventoryStockHelper.mergeApiWithLocalCache(
      [
        {'id': 1, 'product_name': 'Rice', 'current_stock': 10},
        {'id': 1, 'product_name': 'Rice', 'current_stock': 12},
      ],
      [
        {'id': 1, 'product_name': 'Rice', 'current_stock': 9},
        {'id': 2, 'product_name': 'Deleted item', 'current_stock': 5},
      ],
    );

    expect(result, hasLength(1));
    expect(result.single['id'], 1);
    expect(result.single['current_stock'], 12);
  });
}
