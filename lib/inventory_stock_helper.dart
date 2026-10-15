import 'dart:convert';

import 'cache_consistency_service.dart';

/// Shared parsing and stock-field handling for inventory API responses.
class InventoryStockHelper {
  static const List<String> _envelopeKeys = [
    'data',
    'products',
    'results',
    'items',
  ];

  /// Parse product lists returned directly or wrapped in common API envelopes.
  ///
  /// Supports nested envelopes and JSON-encoded strings (including a string
  /// nested inside a `data` or `products` field). Malformed responses throw
  /// instead of quietly presenting an empty inventory.
  static List<Map<String, dynamic>> parseProductsResponse(dynamic response) {
    dynamic value = response;

    for (var depth = 0; depth < 8; depth++) {
      if (value is String) {
        try {
          value = jsonDecode(value);
          continue;
        } on FormatException {
          throw const FormatException(
            'Inventory response contained invalid JSON-encoded data.',
          );
        }
      }

      if (value is List) {
        return normalizeProducts(value);
      }

      if (value is Map) {
        dynamic wrapped;
        var foundEnvelope = false;
        for (final key in _envelopeKeys) {
          if (value.containsKey(key) && value[key] != null) {
            wrapped = value[key];
            foundEnvelope = true;
            break;
          }
        }
        if (foundEnvelope) {
          value = wrapped;
          continue;
        }

        final productKeys = <String>{
          'id',
          'product_id',
          'backend_id',
          'server_id',
          'product_name',
          'name',
          'sku',
          'barcode',
        };
        if (value.keys.any((key) => productKeys.contains(key.toString()))) {
          return <Map<String, dynamic>>[
            normalizeProduct(Map<String, dynamic>.from(value)),
          ];
        }
      }

      throw const FormatException(
        'Inventory response was not a product list or supported envelope.',
      );
    }

    throw const FormatException(
      'Inventory response nesting exceeded the supported limit.',
    );
  }

  /// API uses stock/quantity, while some UI components use current_stock.
  static double readStock(Map<String, dynamic> product) {
    for (final key in [
      'current_stock',
      'stock',
      'quantity',
      'qty',
      'available_stock',
    ]) {
      final value = product[key];
      if (value == null) continue;
      final number = double.tryParse(value.toString());
      if (number != null && number.isFinite) return number;
    }
    return 0;
  }

  static void writeStock(Map<String, dynamic> product, double value) {
    product['current_stock'] = value;
    product['stock'] = value;
    product['quantity'] = value;
  }

  static Map<String, dynamic> normalizeProduct(Map<String, dynamic> raw) {
    final product = Map<String, dynamic>.from(raw);

    // Preserve the canonical backend identity for update/delete operations.
    final canonicalId = product['id'] ??
        product['product_id'] ??
        product['backend_id'] ??
        product['server_id'];
    if (canonicalId != null && canonicalId.toString().trim().isNotEmpty) {
      product['id'] = canonicalId;
      product['product_id'] ??= canonicalId;
    }

    final name = (product['product_name'] ??
            product['name'] ??
            product['product'] ??
            '')
        .toString();
    if (name.isNotEmpty) product['product_name'] = name;

    writeStock(product, readStock(product));
    product['min_stock'] =
        double.tryParse(product['min_stock']?.toString() ?? '10') ?? 10;
    return product;
  }

  static List<Map<String, dynamic>> normalizeProducts(List<dynamic> list) {
    return list
        .whereType<Map>()
        .map((entry) => normalizeProduct(Map<String, dynamic>.from(entry)))
        .toList();
  }

  static bool _isPendingLocalMutation(Map<String, dynamic> product) {
    return CacheConsistencyService.isPending(product) ||
        product['local_pending'] == true ||
        product['pending_sync'] == true;
  }

  /// Merge the authoritative API catalogue with cached records.
  ///
  /// Duplicate API product IDs collapse to one row. Unacknowledged local
  /// mutations remain visible, while acknowledged cached products absent from
  /// the server response are not resurrected indefinitely.
  static List<Map<String, dynamic>> mergeApiWithLocalCache(
    List<Map<String, dynamic>> apiList,
    List<Map<String, dynamic>> localList,
  ) {
    final localById = <String, Map<String, dynamic>>{};
    final deletedIds = <String>{};

    for (final raw in localList) {
      final product = normalizeProduct(Map<String, dynamic>.from(raw));
      final id = (product['id'] ??
              product['product_id'] ??
              product['sku'] ??
              product['barcode'] ??
              '')
          .toString()
          .trim();
      if (id.isEmpty) continue;

      if (product['is_deleted'] == true &&
          _isPendingLocalMutation(product)) {
        deletedIds.add(id);
        localById.remove(id);
        continue;
      }

      localById[id] = product;
    }

    // De-duplicate incoming server rows by stable identity before merging.
    final apiById = <String, Map<String, dynamic>>{};
    final apiWithoutId = <Map<String, dynamic>>[];
    for (final raw in apiList) {
      final product = normalizeProduct(Map<String, dynamic>.from(raw));
      final id = (product['id'] ??
              product['product_id'] ??
              product['sku'] ??
              product['barcode'] ??
              '')
          .toString()
          .trim();
      if (id.isEmpty) {
        apiWithoutId.add(product);
        continue;
      }
      if (apiById.containsKey(id)) {
        apiById[id] = <String, dynamic>{...apiById[id]!, ...product};
      } else {
        apiById[id] = product;
      }
    }

    final merged = <Map<String, dynamic>>[];
    final seen = <String>{};

    for (final apiProduct in [...apiById.values, ...apiWithoutId]) {
      final id = (apiProduct['id'] ??
              apiProduct['product_id'] ??
              apiProduct['sku'] ??
              apiProduct['barcode'] ??
              '')
          .toString()
          .trim();

      if (id.isNotEmpty && deletedIds.contains(id)) {
        seen.add(id);
        continue;
      }

      final local = id.isEmpty ? null : localById[id];
      if (local != null) {
        final reconciled = CacheConsistencyService.mergeRecord(
          local,
          apiProduct,
          dataset: 'inventory',
        );
        merged.add(normalizeProduct(reconciled));
      } else {
        merged.add(apiProduct);
      }
      if (id.isNotEmpty) seen.add(id);
    }

    // Only keep cached records missing from the authoritative response when
    // they represent a pending local mutation. This avoids stale deleted stock
    // entries reappearing on every inventory refresh.
    for (final entry in localById.entries) {
      if (seen.contains(entry.key)) continue;
      if (_isPendingLocalMutation(entry.value)) merged.add(entry.value);
    }

    return merged;
  }
}
