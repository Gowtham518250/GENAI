import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'online_order_service.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';
import 'services/order_history_service.dart';

/// Loads products for a customer's selected online shop.
class CustomerShopService {
  /// Fetch products through the canonical marketplace API.
  /// This keeps customer visibility aligned with the backend's
  /// is_online_store_enabled guard and avoids exposing disabled shops through
  /// the legacy Firestore fallback.
  static Future<List<Map<String, dynamic>>> fetchProducts(String shopId) async {
    if (shopId.isEmpty) return [];

    try {
      final res = await ApiClient.getJson(
        '/store/shops/$shopId/products?limit=200',
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode != 200) {
        return [];
      }

      final body = json.decode(res.body);
      final raw = body is Map && body['products'] is List ? body['products'] as List : <dynamic>[];
      final products = raw
          .whereType<Map>()
          .map((p) => normalizeProduct(Map<String, dynamic>.from(p)))
          .toList();

      return _filterInStock(products);
    } catch (e) {
      if (kDebugMode) debugPrint('CustomerShopService marketplace API: $e');
      return [];
    }
  }

  static List<Map<String, dynamic>> _filterInStock(List<Map<String, dynamic>> list) {
    return list.where((p) {
      final price = (p['price'] as num?)?.toDouble() ?? 0;
      final stock = (p['stock'] as num?)?.toInt() ?? 0;
      return price > 0 && stock > 0;
    }).toList();
  }

  static Future<double> fetchOnlineSetupFee(String shopId) async {
    if (shopId.isEmpty) return 0.0;
    try {
      final res = await ApiClient.getJson(
        '/store/shops/$shopId/products?limit=1',
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        if (body is Map) {
          return double.tryParse(body['online_setup_fee']?.toString() ?? '0') ?? 0.0;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('CustomerShopService setup fee: $e');
    }
    return 0.0;
  }

  static Future<String> fetchShopName(String shopId) async {
    if (shopId.isEmpty) return 'Shop';
    try {
      final res = await ApiClient.getJson(
        '/store/shops/$shopId/products?limit=1',
      ).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        if (body is Map) {
          final name = body['shop_name']?.toString().trim();
          if (name != null && name.isNotEmpty) return name;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('CustomerShopService shop profile: $e');
    }
    return 'Shop';
  }

  static Map<String, dynamic> normalizeProduct(Map raw) {
    final name = (raw['product_name'] ?? raw['name'] ?? raw['product'] ?? 'Item').toString();
    final price = double.tryParse(
          (raw['price'] ?? raw['selling_price'] ?? raw['unit_price'] ?? '0')
              .toString(),
        ) ??
        0;
    // The online-store API calls available inventory stock_available.
    // Without this alias, every API product normalized to stock=0 and the
    // storefront filtered the entire catalogue out as unavailable.
    final rawStock = raw['stock'] ??
        raw['stock_available'] ??
        raw['current_stock'] ??
        raw['available_quantity'] ??
        raw['quantity'] ??
        0;
    // The API/DB may serialize an integral Numeric inventory quantity as 8.0.
    // The UI currently sells whole units, so convert numeric strings safely.
    final stock = rawStock is num
        ? rawStock.floor()
        : (int.tryParse(rawStock.toString()) ??
            double.tryParse(rawStock.toString())?.floor() ??
            0);
    final id = (raw['id'] ?? raw['product_id'] ?? '').toString().trim();
    final imageUrl = (raw['image_url'] ?? raw['imageUrl'] ?? raw['photo'] ?? '').toString();
    return {
      'id': id,
      'name': name,
      'price': price,
      'stock': stock,
      'stock_available': stock,
      'category': raw['category']?.toString() ?? 'General',
      'image_url': imageUrl,
    };
  }

  /// Place order in Firestore for owner to see in Online Orders tab.
  static Future<String> placeOrder({
    required String shopId,
    required String shopName,
    required String customerEmail,
    required List<Map<String, dynamic>> items,
    required double totalAmount,
    required String paymentMethod,
    String paymentStatus = 'pending',
    String fulfillmentMethod = 'PICKUP',
    String deliveryAddress = 'Store Pickup',
  }) async {
    final localOrderId = 'LOCAL_ORDER_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toIso8601String();
    final localOrder = <String, dynamic>{
      'order_id': localOrderId,
      'local_order_id': localOrderId,
      'shop_id': shopId,
      'shop_name': shopName,
      'customer_email': customerEmail,
      'items': items.map((i) => {
        'name': i['name'],
        'qty': i['qty'],
        'price': i['price'],
        'id': i['id'],
      }).toList(),
      'total_amount': totalAmount,
      'payment_method': paymentMethod,
      'payment_status': paymentStatus,
      'fulfillment_method': fulfillmentMethod.toUpperCase(),
      'delivery_address': deliveryAddress,
      'status': 'PENDING_SYNC',
      'sync_status': 'pending',
      'created_at': now,
      'updated_at': now,
    };

    // Local order history is the immediate source of truth.
    await OrderHistoryService.addOrder(localOrder);

    final apiItems = items.map((i) => {
      'product_id': int.tryParse(i['id'].toString()) ?? 0,
      'quantity': int.tryParse(i['qty']?.toString() ?? '1') ?? 1,
    }).toList();

    final queued = await SyncQueueManager.enqueue('customer_place_order', {
      'operation_id': localOrderId,
      'idempotency_key': localOrderId,
      'local_order_id': localOrderId,
      'shop_id': int.tryParse(shopId) ?? 0,
      'items': apiItems,
      'delivery_address': deliveryAddress,
      'fulfillment_method': fulfillmentMethod.toUpperCase(),
      'customer_email': customerEmail,
      'payment_method': paymentMethod.toUpperCase() == 'UPI' ? 'UPI' : 'COD',
      'payment_status': paymentStatus.toUpperCase(),
    });
    if (!queued) {
      throw StateError('Unable to save customer order to the offline outbox');
    }

    // Flush immediately when possible; the durable event remains pending
    // while offline.
    unawaited(SyncService.processQueueSafe());
    return localOrderId;
  }

  /// Push owner inventory row to Firestore (stock + image for storefront).
  static Future<void> upsertProductToFirestore({
    required String shopId,
    required String productId,
    required String name,
    required double price,
    required int stock,
    String? imageUrl,
    String category = 'General',
  }) async {
    if (shopId.isEmpty) return;
    final available = stock > 0 && price > 0;
    await FirebaseFirestore.instance
        .collection('shops')
        .doc(shopId)
        .collection('products')
        .doc(productId)
        .set({
      'name': name,
      'price': price,
      'stock': stock,
      'available': available,
      'image_url': imageUrl ?? '',
      'category': category,
      'updated_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> syncInventoryToFirestore(
    String shopId,
    List<Map<String, dynamic>> inventory,
  ) async {
    if (shopId.isEmpty) return;
    for (final item in inventory) {
      final name = (item['product_name'] ?? item['name'] ?? '').toString();
      if (name.isEmpty) continue;
      final id = (item['id'] ?? name).toString().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');
      final price = double.tryParse(item['price']?.toString() ?? '0') ?? 0;
      final stock = int.tryParse(item['stock']?.toString() ?? item['quantity']?.toString() ?? '0') ?? 0;
      final imageUrl = (item['image_url'] ?? item['imageUrl'] ?? '').toString();
      await upsertProductToFirestore(
        shopId: shopId,
        productId: id,
        name: name,
        price: price,
        stock: stock,
        imageUrl: imageUrl.isEmpty ? null : imageUrl,
      );
    }
    await OnlineOrderService.syncShopUpiToFirestore(shopId);
  }
}
