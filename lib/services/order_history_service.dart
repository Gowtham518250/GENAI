import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../cache_consistency_service.dart';
import '../api_client.dart';

/// 🔧 FLIPKART-LEVEL: Order History Service
/// Manages order history, tracking, and status updates
class OrderHistoryService {
  static const String _ordersKey = 'order_history';
  static const String _ordersSyncKey = 'orders_sync_timestamp';

  static Future<String> _scopedKey(String base) async {
    final prefs = await SharedPreferences.getInstance();
    final role = (prefs.getString('user_type') ?? prefs.getString('role') ?? 'CUSTOMER').trim().toUpperCase();
    // SharedPreferences keys were historically written as both int and
    // String across registration flows. getInt() throws if the stored value
    // is a String, so read dynamically and normalize without a type cast.
    final rawUserId = prefs.get('user_id') ?? prefs.get('userId');
    final userId = rawUserId?.toString() ??
        prefs.getString('user_email') ??
        'anonymous';
    return base + '_' + role + '_' + userId;
  }

  /// 🔧 FLIPKART-LEVEL: Order status enum
  static const List<String> orderStatuses = [
    'PENDING',
    'ACCEPTED',
    'PLACED',
    'CONFIRMED',
    'PROCESSING',
    'SHIPPED',
    'OUT_FOR_DELIVERY',
    'DELIVERED',
    'CANCELLED',
    'RETURNED',
    'REFUNDED',
  ];

  /// 🔧 FLIPKART-LEVEL: Get all orders
  static Future<List<Map<String, dynamic>>> getAllOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final ordersJson = prefs.getString(await _scopedKey(_ordersKey));
    
    if (ordersJson == null) return [];
    
    try {
      final List<dynamic> decoded = json.decode(ordersJson);
      return decoded.cast<Map<String, dynamic>>();
    } catch (e) {
      if (kDebugMode) debugPrint('Error loading orders: $e');
      return [];
    }
  }

  /// 🔧 FLIPKART-LEVEL: Save orders
  static Future<void> saveOrders(List<Map<String, dynamic>> orders) async {
    final prefs = await SharedPreferences.getInstance();
    final ordersJson = json.encode(orders);
    await prefs.setString(await _scopedKey(_ordersKey), ordersJson);
    // Saving local state is not evidence of a successful backend read/sync.
    // The explicit remote reconciliation path owns this timestamp.
  }

  /// Merge authenticated server orders into the local, role-scoped cache.
  /// Local-only orders remain visible when they have not synced yet or the
  /// server is temporarily unavailable.
  static Future<List<Map<String, dynamic>>> mergeRemoteOrders(
    List<Map<String, dynamic>> remoteOrders,
  ) async {
    final localOrders = await getAllOrders();
    final consumedLocalIndexes = <int>{};
    final merged = <Map<String, dynamic>>[];

    for (final rawRemote in remoteOrders) {
      final remote = Map<String, dynamic>.from(rawRemote);
      final remoteId = (remote['order_id'] ?? remote['id'] ?? '').toString().trim();
      if (remoteId.isEmpty) continue;

      var localIndex = -1;
      for (var i = 0; i < localOrders.length; i++) {
        if (consumedLocalIndexes.contains(i)) continue;
        final local = localOrders[i];
        final existingServerId =
            (local['server_order_id'] ?? '').toString();
        final existingOrderId = (local['order_id'] ?? '').toString();
        if (existingServerId == remoteId || existingOrderId == remoteId) {
          localIndex = i;
          break;
        }
      }

      final existing = localIndex >= 0
          ? localOrders[localIndex]
          : <String, dynamic>{};
      if (localIndex >= 0) consumedLocalIndexes.add(localIndex);

      final rawCreatedAt = remote['created_at'] ?? existing['created_at'] ?? '';
      final rawItems = remote['items'] ?? existing['items'];
      final status = (remote['status'] ?? existing['status'] ?? 'PENDING')
          .toString()
          .trim()
          .toUpperCase();
      final total = remote['total_amount'] ??
          remote['total'] ??
          existing['total_amount'] ??
          existing['total'] ??
          existing['amount'] ??
          0;

      merged.add({
        ...existing,
        ...remote,
        'order_id': remoteId,
        'server_order_id': remoteId,
        'local_order_id': existing['local_order_id'] ?? remoteId,
        'sync_status': 'synced',
        'status': status,
        'total_amount': total,
        'total': total,
        'created_at': rawCreatedAt.toString(),
        'items': rawItems is List ? rawItems : <dynamic>[],
      });
    }

    // Do not delete locally-created orders just because they are absent from
    // the server response. They may be waiting in the offline outbox.
    for (var i = 0; i < localOrders.length; i++) {
      if (!consumedLocalIndexes.contains(i)) {
        merged.add(localOrders[i]);
      }
    }

    merged.sort((a, b) {
      final aDate = DateTime.tryParse((a['created_at'] ?? '').toString());
      final bDate = DateTime.tryParse((b['created_at'] ?? '').toString());
      if (aDate == null && bDate == null) return 0;
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return bDate.compareTo(aDate);
    });

    await saveOrders(merged);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_ordersSyncKey, DateTime.now().millisecondsSinceEpoch);
    return merged;
  }

  /// 🔧 FLIPKART-LEVEL: Add new order
  static Future<void> addOrder(Map<String, dynamic> order) async {
    final orders = await getAllOrders();
    
    // Add order with timestamp
    order['order_id'] = order['order_id'] ?? 'ORD${DateTime.now().millisecondsSinceEpoch}';
    order['created_at'] = order['created_at'] ?? DateTime.now().toIso8601String();
    order['updated_at'] = DateTime.now().toIso8601String();
    order['status'] = order['status'] ?? 'PLACED';
    
    orders.insert(0, order); // Add to beginning
    await saveOrders(orders);
    await CacheConsistencyService.markLocalMutation('customer_orders', operationId: order['order_id']?.toString());
  }

  /// 🔧 FLIPKART-LEVEL: Update order status
  static Future<void> updateOrderStatus(String orderId, String status) async {
    final orders = await getAllOrders();
    
    for (var order in orders) {
      if (order['order_id'] == orderId) {
        order['status'] = status;
        order['updated_at'] = DateTime.now().toIso8601String();
        
        // Add status history
        final statusHistory = order['status_history'] as List<dynamic>? ?? [];
        statusHistory.add({
          'status': status,
          'timestamp': DateTime.now().toIso8601String(),
        });
        order['status_history'] = statusHistory;
        
        break;
      }
    }
    
    await saveOrders(orders);
    await CacheConsistencyService.markLocalMutation('customer_orders', operationId: orderId);
  }

  /// Reconcile a locally created order with its server acknowledgement.
  static Future<void> markOrderSynced({
    required String localOrderId,
    required String serverOrderId,
    String status = 'PENDING',
  }) async {
    final orders = await getAllOrders();
    for (var i = 0; i < orders.length; i++) {
      final order = orders[i];
      final localId = (order['local_order_id'] ?? order['order_id']).toString();
      if (localId != localOrderId) continue;

      orders[i] = {
        ...order,
        'order_id': serverOrderId,
        'server_order_id': serverOrderId,
        'sync_status': 'synced',
        'status': order['status'] == 'PENDING_SYNC' ? status : order['status'],
        'updated_at': DateTime.now().toIso8601String(),
      };
      break;
    }
    await saveOrders(orders);
    await CacheConsistencyService.markLocalMutationAcknowledged('customer_orders', operationId: serverOrderId);
  }
  /// 🔧 FLIPKART-LEVEL: Get order by ID
  static Future<Map<String, dynamic>?> getOrderById(String orderId) async {
    final orders = await getAllOrders();
    
    for (var order in orders) {
      if (order['order_id'] == orderId) {
        return order;
      }
    }
    
    return null;
  }

  /// 🔧 FLIPKART-LEVEL: Get orders by status
  static Future<List<Map<String, dynamic>>> getOrdersByStatus(String status) async {
    final orders = await getAllOrders();
    return orders.where((order) => order['status'] == status).toList();
  }

  /// 🔧 FLIPKART-LEVEL: Get orders by date range
  static Future<List<Map<String, dynamic>>> getOrdersByDateRange(DateTime startDate, DateTime endDate) async {
    final orders = await getAllOrders();
    
    return orders.where((order) {
      final createdAt = DateTime.tryParse(order['created_at'] ?? '');
      if (createdAt == null) return false;
      return createdAt.isAfter(startDate) && createdAt.isBefore(endDate);
    }).toList();
  }

  /// Cancel a server-backed order through the backend so inventory and
  /// order status are updated atomically. The endpoint only permits PENDING
  /// and ACCEPTED orders; local state changes only after server success.
  static Future<bool> cancelOrder(String orderId) async {
    final order = await getOrderById(orderId);
    if (order == null) return false;

    final currentStatus = (order['status'] ?? '').toString().trim().toUpperCase();
    if (!const {'PENDING', 'ACCEPTED'}.contains(currentStatus)) return false;

    final serverOrderId =
        (order['server_order_id'] ?? order['order_id'] ?? orderId).toString();
    if (int.tryParse(serverOrderId) == null) {
      // A local-only ID has not been accepted by the backend.
      return false;
    }

    try {
      final response = await ApiClient.postJson(
        '/store/order/$serverOrderId/cancel',
        <String, dynamic>{},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 && response.statusCode != 201) {
        if (kDebugMode) {
          debugPrint(
            'Order cancellation rejected by backend: HTTP \${response.statusCode}',
          );
        }
        return false;
      }
      await updateOrderStatus(serverOrderId, 'CANCELLED');
      await CacheConsistencyService.markLocalMutationAcknowledged(
        'customer_orders',
        operationId: serverOrderId,
      );
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Order cancellation request failed: $e');
      return false;
    }
  }

  /// 🔧 FLIPKART-LEVEL: Return order
  static Future<bool> returnOrder(String orderId, String reason) async {
    final order = await getOrderById(orderId);
    if (order == null) return false;
    
    final currentStatus = order['status'] as String?;
    if (currentStatus != 'DELIVERED') return false;
    
    await updateOrderStatus(orderId, 'RETURNED');
    
    // Add return reason
    final orders = await getAllOrders();
    for (var ord in orders) {
      if (ord['order_id'] == orderId) {
        ord['return_reason'] = reason;
        ord['return_requested_at'] = DateTime.now().toIso8601String();
        break;
      }
    }
    await saveOrders(orders);
    
    return true;
  }

  /// 🔧 FLIPKART-LEVEL: Get order tracking timeline
  static Future<List<Map<String, dynamic>>> getOrderTracking(String orderId) async {
    final order = await getOrderById(orderId);
    if (order == null) return [];
    
    final statusHistory = order['status_history'] as List<dynamic>? ?? [];
    final currentStatus = order['status'] as String?;
    
    // Build timeline from status history
    final timeline = <Map<String, dynamic>>[];
    
    for (var entry in statusHistory) {
      timeline.add({
        'status': entry['status'],
        'timestamp': entry['timestamp'],
        'completed': true,
      });
    }
    
    // Add current status if not in history
    if (currentStatus != null && (timeline.isEmpty || timeline.last['status'] != currentStatus)) {
      timeline.add({
        'status': currentStatus,
        'timestamp': order['updated_at'],
        'completed': true,
      });
    }
    
    // Add future statuses
    final statusIndex = orderStatuses.indexOf(currentStatus ?? 'PLACED');
    if (statusIndex != -1 && statusIndex < orderStatuses.length - 1) {
      for (int i = statusIndex + 1; i < orderStatuses.length; i++) {
        timeline.add({
          'status': orderStatuses[i],
          'timestamp': null,
          'completed': false,
        });
      }
    }
    
    return timeline;
  }

  /// 🔧 FLIPKART-LEVEL: Get order statistics
  static Future<Map<String, dynamic>> getOrderStatistics() async {
    final orders = await getAllOrders();
    
    int totalOrders = orders.length;
    int deliveredOrders = 0;
    int cancelledOrders = 0;
    int returnedOrders = 0;
    double totalSpent = 0.0;
    
    for (var order in orders) {
      final status = order['status'] as String?;
      final total = order['total'] ?? order['amount'] ?? 0;
      
      if (status == 'DELIVERED') {
        deliveredOrders++;
        totalSpent += total is num ? total.toDouble() : double.tryParse(total.toString()) ?? 0.0;
      } else if (status == 'CANCELLED') {
        cancelledOrders++;
      } else if (status == 'RETURNED') {
        returnedOrders++;
      }
    }
    
    return {
      'total_orders': totalOrders,
      'delivered_orders': deliveredOrders,
      'cancelled_orders': cancelledOrders,
      'returned_orders': returnedOrders,
      'total_spent': totalSpent,
      'delivery_rate': totalOrders > 0 ? (deliveredOrders / totalOrders * 100).toStringAsFixed(1) : '0.0',
    };
  }

  /// 🔧 FLIPKART-LEVEL: Search orders
  static Future<List<Map<String, dynamic>>> searchOrders(String query) async {
    final orders = await getAllOrders();
    final lowerQuery = query.toLowerCase();
    
    return orders.where((order) {
      final orderId = (order['order_id'] ?? '').toString().toLowerCase();
      final customerName = (order['customer_name'] ?? '').toString().toLowerCase();
      final customerPhone = (order['customer_phone'] ?? '').toString().toLowerCase();
      
      return orderId.contains(lowerQuery) ||
             customerName.contains(lowerQuery) ||
             customerPhone.contains(lowerQuery);
    }).toList();
  }

  /// 🔧 FLIPKART-LEVEL: Get sync timestamp
  static Future<DateTime?> getSyncTimestamp() async {
    final prefs = await SharedPreferences.getInstance();
    final timestamp = prefs.getString(await _scopedKey(_ordersSyncKey));
    if (timestamp == null) return null;
    return DateTime.tryParse(timestamp);
  }

  /// 🔧 FLIPKART-LEVEL: Sync orders with backend
  static Future<bool> syncOrdersWithBackend(String token) async {
    try {
      // This would typically call an API to sync orders
      // For now, just update the sync timestamp
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_ordersSyncKey, DateTime.now().toIso8601String());
      
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('Error syncing orders: $e');
      return false;
    }
  }
}
