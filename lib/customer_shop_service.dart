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
  /// Fetch in-stock products with price > 0.
  static Future<List<Map<String, dynamic>>> fetchProducts(String shopId) async {
    if (shopId.isEmpty) return [];

    List<Map<String, dynamic>> products = [];

    try {
      final res = await ApiClient.getJson(
        '/api/inventory/products?shop_id=$shopId',
      ).timeout(const Duration(seconds: 12));

      if (res.statusCode == 200) {
        final body = json.decode(res.body);
        final List raw = body is List ? body : (body['products'] as List? ?? []);
        if (raw.isNotEmpty) {
          products = raw.map((p) => _normalizeProduct(p as Map)).toList();
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('CustomerShopService API: $e');
    }

    if (products.isEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('shops')
            .doc(shopId)
            .collection('products')
            .where('available', isEqualTo: true)
            .get();

        if (snap.docs.isNotEmpty) {
          products = snap.docs.map((d) {
            final data = d.data();
            return _normalizeProduct({
              'id': d.id,
              'product_name': data['name'] ?? data['product_name'],
              'price': data['price'],
              'stock': data['stock'] ?? data['quantity'],
              'image_url': data['image_url'],
              'category': data['category'],
            });
          }).toList();
        }
      } catch (e) {
        if (kDebugMode) debugPrint('CustomerShopService Firestore: $e');
      }
    }

    return _filterInStock(products);
  }

  static List<Map<String, dynamic>> _filterInStock(List<Map<String, dynamic>> list) {
    return list.where((p) {
      final price = (p['price'] as num?)?.toDouble() ?? 0;
      final stock = (p['stock'] as num?)?.toInt() ?? 0;
      return price > 0 && stock > 0;
    }).toList();
  }

  static Future<String> fetchShopName(String shopId) async {
    if (shopId.isEmpty) return 'Shop';
    try {
      final doc = await FirebaseFirestore.instance.collection('shops').doc(shopId).get();
      if (doc.exists) {
        return doc.data()?['shop_name']?.toString() ?? 'Shop';
      }
    } catch (_) {}
    return 'Shop';
  }

  static Map<String, dynamic> _normalizeProduct(Map raw) {
    final name = (raw['product_name'] ?? raw['name'] ?? raw['product'] ?? 'Item').toString();
    final price = double.tryParse(raw['price']?.toString() ?? raw['selling_price']?.toString() ?? '0') ?? 0;
    final stock = int.tryParse(raw['stock']?.toString() ?? raw['quantity']?.toString() ?? '0') ?? 0;
    final id = (raw['id'] ?? raw['product_id'] ?? name).toString();
    final imageUrl = (raw['image_url'] ?? raw['imageUrl'] ?? raw['photo'] ?? '').toString();
    return {
      'id': id,
      'name': name,
      'price': price,
      'stock': stock,
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
      'delivery_address': 'Store Pickup',
      'customer_email': customerEmail,
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
