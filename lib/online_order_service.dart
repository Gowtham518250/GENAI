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
    const empty = {
      'pending': 0,
      'todayCount': 0,
      'todayRevenue': 0.0,
      'paidCount': 0,
      'todayPaidCount': 0,
      'totalCount': 0,
      'totalRevenue': 0.0,
      'totalPaidCount': 0,
      'rejectedCount': 0,
    };

    if (shopId.isEmpty || shopId == '0') return empty;

    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return empty;

      final response = await ApiClient.getJson(
        '/store/owner/orders',
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 12));

      if (response.statusCode != 200) {
        throw Exception(
          'Owner orders returned HTTP ' + response.statusCode.toString(),
        );
      }

      final body = jsonDecode(response.body);
      final raw = body is Map ? body['orders'] : body;
      if (raw is! List) return empty;

      final ordersById = <String, Map<String, dynamic>>{};
      for (final item in raw) {
        if (item is! Map) continue;
        final order = Map<String, dynamic>.from(item);
        final id = (order['order_id'] ?? order['id'] ?? '').toString();
        if (id.isNotEmpty) ordersById[id] = order;
      }

      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      int pending = 0;
      int todayCount = 0;
      int paidCount = 0;
      int todayPaidCount = 0;
      int totalPaidCount = 0;
      int rejectedCount = 0;
      double todayRevenue = 0.0;
      double totalRevenue = 0.0;

      for (final order in ordersById.values) {
        final status =
            (order['status'] ?? order['order_status'] ?? '').toString().toUpperCase();
        final total = (order['total_amount'] as num?)?.toDouble() ??
            double.tryParse(order['total_amount']?.toString() ?? '0') ??
            0.0;

        if (status == 'PENDING') pending++;
        if (status == 'REJECTED') {
          rejectedCount++;
        } else {
          totalRevenue += total;
        }

        final paymentStatus =
            (order['payment_status'] ?? '').toString().toUpperCase();
        // Fulfilment does not prove payment, especially for UPI orders.
        final isPaid = paymentStatus == 'PAID';
        if (isPaid) totalPaidCount++;

        final rawDate =
            order['created_at'] ?? order['timestamp'] ?? order['placed_at'];
        final dt = rawDate == null
            ? null
            : DateTime.tryParse(rawDate.toString())?.toLocal();
        final isToday = dt != null &&
            DateTime(dt.year, dt.month, dt.day) == today &&
            status != 'REJECTED';

        if (isToday) {
          todayCount++;
          todayRevenue += total;
          if (isPaid) {
            paidCount++;
            todayPaidCount++;
          }
        }
      }

      return {
        'pending': pending,
        'todayCount': todayCount,
        'todayRevenue': todayRevenue,
        'paidCount': paidCount,
        'todayPaidCount': todayPaidCount,
        'totalCount': ordersById.length,
        'totalRevenue': totalRevenue,
        'totalPaidCount': totalPaidCount,
        'rejectedCount': rejectedCount,
      };
    } catch (e) {
      if (kDebugMode) debugPrint('getAnalytics: ' + e.toString());
      return empty;
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
