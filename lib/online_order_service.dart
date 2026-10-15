import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'notification_service.dart';
import 'api_client.dart';
import 'secure_token_storage.dart';
import 'payment_event.dart';

/// Online orders: analytics, UPI matching, notifications helpers.
class OnlineOrderService {
  static const _orders = 'orders';

  /// Count distinct online orders in legacy sales rows without confusing a
  /// line-item row ID or currency amount with an order ID. Online orders write
  /// one sales row per item, so reference_order_id is the canonical grouping key.
  static int countDistinctOnlineOrdersFromSales(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final orderIds = <String>{};
    for (final row in rows) {
      final source = (row['source'] ?? row['order_source'] ?? 'OFFLINE')
          .toString()
          .trim()
          .toUpperCase();
      final invoiceKey = (row['invoice_number'] ??
              row['sale_id'] ??
              row['_bill_id'] ??
              row['id'] ??
              row['created_at'] ??
              '')
          .toString()
          .trim();
      final isOnline = const {'ONLINE', 'ONLINE_ORDER', 'WEB', 'APP'}
              .contains(source) ||
          invoiceKey.toUpperCase().startsWith('ONL');
      if (!isOnline) continue;

      final referenceOrderId = (row['reference_order_id'] ??
              row['online_order_id'] ??
              row['order_id'] ??
              '')
          .toString()
          .trim();
      if (referenceOrderId.isNotEmpty) {
        orderIds.add('order:$referenceOrderId');
      } else if (invoiceKey.isNotEmpty) {
        orderIds.add('invoice:${invoiceKey.toUpperCase()}');
      }
    }
    return orderIds.length;
  }

  /// Shop UPI for customer checkout — Firestore only (never owner prefs.upi_id).
  static Future<String?> fetchShopUpi(String shopId) async {
    if (shopId.isEmpty) return null;
    try {
      final doc = await FirebaseFirestore.instance.collection('shops').doc(shopId).get();
      final upi = doc.data()?['upi_id']?.toString().trim();
      if (upi != null && upi.isNotEmpty) return upi;
    } catch (e) {
      if (kDebugMode) debugPrint('fetchShopUpi Firestore: $e');
    }
    return null;
  }

  static Future<void> syncShopUpiToFirestore(String shopId) async {
    if (shopId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final upi = prefs.getString('upi_id');
    if (upi == null || upi.isEmpty) return;
    try {
      await FirebaseFirestore.instance.collection('shops').doc(shopId).set(
        {'upi_id': upi},
        SetOptions(merge: true),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('syncShopUpi: $e');
    }
  }


  /// Canonical online-store analytics from the same owner-order dataset
  /// used by the Online Orders page. One request keeps dashboard and hub
  /// figures identical.
  static Future<Map<String, dynamic>> getAnalytics(String shopId) async {
    const empty = <String, dynamic>{
      'pending': 0,
      'todayCount': 0,
      'todayRevenue': 0.0,
      'paidCount': 0,
      'todayPaidCount': 0,
      'totalCount': 0,
      'totalRevenue': 0.0,
      'totalPaidCount': 0,
      'rejectedCount': 0,
      'cancelledCount': 0,
    };

    if (shopId.isEmpty || shopId == '0') return Map<String, dynamic>.from(empty);

    final token = await SecureTokenStorage.getToken() ?? '';
    if (token.isEmpty) return Map<String, dynamic>.from(empty);
    final headers = {'Authorization': 'Bearer $token'};

    try {
      // Prefer the server-side aggregate: the owner orders list is paginated,
      // so calculating totals from its first page silently undercounts larger
      // shops. The fallback keeps the client compatible with older deployments.
      final analyticsResponse = await ApiClient.getJson(
        '/store/owner/orders/analytics',
        headers: headers,
      ).timeout(const Duration(seconds: 12));

      if (analyticsResponse.statusCode == 200) {
        final decoded = jsonDecode(analyticsResponse.body);
        if (decoded is Map) {
          return <String, dynamic>{
            ...empty,
            ...Map<String, dynamic>.from(decoded),
          };
        }
        throw const FormatException('Online order analytics response is not an object.');
      }
      if (analyticsResponse.statusCode != 404 &&
          analyticsResponse.statusCode != 405) {
        throw Exception(
          'Owner order analytics returned HTTP ${analyticsResponse.statusCode}',
        );
      }

      // Backward-compatible fallback for deployments not yet serving the
      // aggregate endpoint. Follow every page using the server's total count.
      final ordersById = <String, Map<String, dynamic>>{};
      var skip = 0;
      var expectedTotal = 0;
      const pageSize = 200;
      do {
        final response = await ApiClient.getJson(
          '/store/owner/orders?skip=$skip&limit=$pageSize',
          headers: headers,
        ).timeout(const Duration(seconds: 12));
        if (response.statusCode != 200) {
          throw Exception('Owner orders returned HTTP ${response.statusCode}');
        }

        final decoded = jsonDecode(response.body);
        final raw = decoded is Map ? decoded['orders'] : decoded;
        if (raw is! List) {
          throw const FormatException('Owner orders response is not a list.');
        }
        if (skip == 0 && decoded is Map) {
          final totalValue = decoded['total'];
          expectedTotal = totalValue is num
              ? totalValue.toInt()
              : int.tryParse(totalValue?.toString() ?? '') ?? raw.length;
        } else if (skip == 0) {
          expectedTotal = raw.length;
        }

        for (final item in raw) {
          if (item is! Map) continue;
          final order = Map<String, dynamic>.from(item);
          final id = (order['order_id'] ?? order['id'] ?? '').toString();
          if (id.isNotEmpty) ordersById[id] = order;
        }

        if (raw.isEmpty) break;
        skip += raw.length;
        if (raw.length < pageSize) break;
      } while (skip < expectedTotal);

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      int pending = 0;
      int todayCount = 0;
      int paidCount = 0;
      int totalPaidCount = 0;
      int rejectedCount = 0;
      int cancelledCount = 0;
      double todayRevenue = 0.0;
      double totalRevenue = 0.0;

      for (final order in ordersById.values) {
        final status = (order['status'] ?? order['order_status'] ?? '')
            .toString()
            .toUpperCase();
        final total = (order['total_amount'] as num?)?.toDouble() ??
            double.tryParse(order['total_amount']?.toString() ?? '0') ??
            0.0;

        if (status == 'PENDING') pending++;
        if (status == 'REJECTED') rejectedCount++;
        if (status == 'CANCELLED' || status == 'RETURNED') cancelledCount++;

        final excludedFromValue = const {'REJECTED', 'CANCELLED', 'RETURNED'}
            .contains(status);
        if (!excludedFromValue) totalRevenue += total;

        final paymentStatus =
            (order['payment_status'] ?? '').toString().toUpperCase();
        final isPaid = paymentStatus == 'PAID';
        if (isPaid) totalPaidCount++;

        final rawDate =
            order['created_at'] ?? order['timestamp'] ?? order['placed_at'];
        final dt = rawDate == null
            ? null
            : DateTime.tryParse(rawDate.toString())?.toLocal();
        final isToday = dt != null &&
            DateTime(dt.year, dt.month, dt.day) == today &&
            !excludedFromValue;

        if (isToday) {
          todayCount++;
          todayRevenue += total;
          if (isPaid) paidCount++;
        }
      }

      return {
        'pending': pending,
        'todayCount': todayCount,
        'todayRevenue': todayRevenue,
        'paidCount': paidCount,
        'todayPaidCount': paidCount,
        'totalCount': ordersById.length,
        'totalRevenue': totalRevenue,
        'totalPaidCount': totalPaidCount,
        'rejectedCount': rejectedCount,
        'cancelledCount': cancelledCount,
      };
    } catch (e) {
      if (kDebugMode) debugPrint('getAnalytics: ' + e.toString());
      return Map<String, dynamic>.from(empty);
    }
  }

  /// Match an owner-device notification to a UPI order in PostgreSQL.
  ///
  /// This does not call a payment gateway or rely on a webhook. The backend
  /// only records an automatic match for a high-confidence confirmed event
  /// with a transaction reference and exactly one matching pending order.
  static Future<String?> tryMatchOnlineOrderPayment(
    PaymentEvent event,
    String shopId,
  ) async {
    if (shopId.isEmpty ||
        event.isFailed ||
        event.isDuplicate ||
        event.amount <= 0 ||
        event.decision != PaymentDecision.confirmed ||
        event.confidenceScore < 0.70 ||
        (event.referenceId ?? '').trim().length < 4) {
      return null;
    }

    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return null;

      final response = await ApiClient.postJson(
        '/store/owner/orders/match-notification-payment',
        {
          'amount': event.amount,
          'payment_reference': event.referenceId!.trim(),
          'idempotency_key': event.fingerprint,
          if (event.saleId != null && event.saleId!.trim().isNotEmpty)
            'invoice_number': event.saleId!.trim(),
          'confidence_score': event.confidenceScore,
          'decision': event.decision.name.toUpperCase(),
          'source': event.detectionSource,
          'payer_name': event.payerName,
          'timestamp': event.timestamp.toIso8601String(),
        },
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint('Online order payment match HTTP ${response.statusCode}');
        }
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['matched'] != true) {
        if (kDebugMode && decoded is Map) {
          debugPrint(
            'Online order payment not auto-matched: ${decoded['reason'] ?? 'manual review required'}',
          );
        }
        if (decoded is Map && decoded['requires_manual_review'] == true) {
          await NotificationService.show(
            'Payment needs review',
            '₹${event.amount.toStringAsFixed(2)} could not be safely matched to one online order. Verify it before marking the order paid.',
          );
        }
        return null;
      }

      final orderId = decoded['order_id']?.toString();
      if (orderId == null || orderId.isEmpty) return null;
      await NotificationService.show(
        'Online payment confirmed',
        '₹${event.amount.toStringAsFixed(2)} matched to order #${orderId.substring(0, orderId.length > 8 ? 8 : orderId.length)}',
      );
      return orderId;
    } catch (e) {
      if (kDebugMode) debugPrint('tryMatchOnlineOrderPayment: $e');
    }
    return null;
  }

  static Future<void> notifyOrderStatusChange({
    required String orderId,
    required String status,
    required String shopName,
    required double total,
  }) async {
    await NotificationService.show(
      'Order update — $shopName',
      '#${orderId.substring(0, 8)}: $status · ₹${total.toStringAsFixed(0)}',
    );
  }

  static Future<void> notifyNewOrderForOwner({
    required String orderId,
    required double total,
    required String customerEmail,
  }) async {
    await NotificationService.show(
      'New online order',
      '₹${total.toStringAsFixed(0)} from $customerEmail · Tap Online Store',
    );
  }
}
