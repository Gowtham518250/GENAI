import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'online_order_service.dart';
import 'payment_detection_service.dart';
import 'payment_event.dart';
import 'secure_token_storage.dart';

/// Realtime-ish owner-side order listener.
///
/// Firestore is retained for instant new-order notifications. The canonical
/// FastAPI/PostgreSQL order API is polled every 2 seconds so status and
/// inventory-related order changes are reflected even when Firestore is not
/// involved in the checkout flow.
class OnlineOrdersListener {
  static final OnlineOrdersListener instance = OnlineOrdersListener._();
  OnlineOrdersListener._();

  StreamSubscription<QuerySnapshot>? _ordersSub;
  StreamSubscription<PaymentEvent>? _paymentSub;
  final Set<String> _notifiedOrderIds = {};
  final Map<String, String> _lastApiOrderState = {};
  final _updatesController = StreamController<Map<String, dynamic>>.broadcast();

  Timer? _pollTimer;
  Timer? _retryTimer;
  bool _pollInFlight = false;
  bool _apiSnapshotInitialized = false;

  String _shopId = '';
  bool _started = false;

  Stream<Map<String, dynamic>> get updates => _updatesController.stream;
  bool get isRunning => _started;

  Future<void> stop() async {
    await _ordersSub?.cancel();
    await _paymentSub?.cancel();
    _ordersSub = null;
    _paymentSub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _notifiedOrderIds.clear();
    _lastApiOrderState.clear();
    _apiSnapshotInitialized = false;
    _shopId = '';
    _started = false;
    if (kDebugMode) debugPrint('🛑 OnlineOrdersListener stopped');
  }

  /// Call after login or account switch.
  Future<void> restartForCurrentUser() async {
    await stop();
    await start();
  }

  Future<void> start() async {
    if (_started) return;

    final prefs = await SharedPreferences.getInstance();
    final role = (prefs.getString('role') ?? '').toLowerCase();

    if (role == 'customer') {
      _started = false;
      return;
    }

    _shopId = (prefs.getInt('user_id') ?? prefs.getInt('userId') ?? 0).toString();

    if (_shopId.isEmpty || _shopId == '0') {
      // main.dart initializes this service before a user may have logged in.
      // Keep a lightweight retry so a later owner login automatically starts
      // realtime order/inventory updates without requiring an app restart.
      _started = false;
      _retryTimer ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => unawaited(_retryStart()),
      );
      return;
    }

    _retryTimer?.cancel();
    _retryTimer = null;
    _started = true;

    await OnlineOrderService.syncShopUpiToFirestore(_shopId);

    _ordersSub = FirebaseFirestore.instance
        .collection('orders')
        .where('shop_id', isEqualTo: _shopId)
        .where('status', isEqualTo: 'Pending')
        .snapshots()
        .listen(_onPendingOrders);

    _paymentSub = PaymentDetectionService().onPaymentDetected.listen((event) {
      OnlineOrderService.tryMatchOnlineOrderPayment(event, _shopId);
    });

    // Canonical backend polling. This catches REST-created online orders,
    // status transitions, and any future backend order writer.
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_pollOwnerOrders()),
    );

    await _pollOwnerOrders();

    if (kDebugMode) debugPrint('✅ OnlineOrdersListener started for shop $_shopId');
  }

  Future<void> _retryStart() async {
    if (_started) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    await start();
  }

  Future<void> _pollOwnerOrders() async {
    if (!_started || _pollInFlight || _shopId.isEmpty) return;
    _pollInFlight = true;

    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) return;

      final response = await ApiClient.getJson(
        '/store/owner/orders',
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) return;

      final decoded = jsonDecode(response.body);
      final rawOrders = decoded is Map && decoded['orders'] is List
          ? decoded['orders'] as List
          : const <dynamic>[];

      final nextSnapshot = <String, String>{};

      for (final raw in rawOrders) {
        if (raw is! Map) continue;
        final order = Map<String, dynamic>.from(raw);
        final id = (order['order_id'] ?? order['id'] ?? '').toString();
        if (id.isEmpty) continue;

        final status = (order['status'] ?? order['order_status'] ?? 'PENDING')
            .toString()
            .toUpperCase();
        final fingerprint = jsonEncode({
          'status': status,
          'items': order['items'] ?? const [],
          'total': order['total_amount'] ?? 0,
          'address': order['delivery_address'] ?? '',
        });
        nextSnapshot[id] = fingerprint;

        if (!_apiSnapshotInitialized) continue;

        final previous = _lastApiOrderState[id];
        if (previous == null) {
          _emitUpdate({
            'type': 'NEW_ORDER',
            'order': order,
            'order_id': id,
          });
        } else if (previous != fingerprint) {
          _emitUpdate({
            'type': 'ORDER_CHANGED',
            'order': order,
            'order_id': id,
          });
        }
      }

      // Detect removals only for consumers that need a fresh list.
      if (_apiSnapshotInitialized &&
          nextSnapshot.length != _lastApiOrderState.length) {
        _emitUpdate({'type': 'ORDER_LIST_CHANGED'});
      }

      _lastApiOrderState
        ..clear()
        ..addAll(nextSnapshot);
      _apiSnapshotInitialized = true;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Owner order realtime poll failed: $e');
    } finally {
      _pollInFlight = false;
    }
  }

  void _emitUpdate(Map<String, dynamic> update) {
    if (!_updatesController.isClosed) {
      _updatesController.add(update);
    }
  }

  void _onPendingOrders(QuerySnapshot snap) {
    for (final doc in snap.docChanges) {
      if (doc.type != DocumentChangeType.added) continue;
      final id = doc.doc.id;
      if (_notifiedOrderIds.contains(id)) continue;
      _notifiedOrderIds.add(id);

      final d = doc.doc.data() as Map<String, dynamic>?;
      if (d == null) continue;

      final total = (d['total_amount'] as num?)?.toDouble() ?? 0;
      final email = d['customer_email']?.toString() ?? 'Customer';
      unawaited(
        OnlineOrderService.notifyNewOrderForOwner(
          orderId: id,
          total: total,
          customerEmail: email,
        ),
      );
    }
  }

  void dispose() {
    _updatesController.close();
    unawaited(stop());
  }
}
