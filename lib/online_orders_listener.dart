import 'dart:convert';
import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'online_order_service.dart';
import 'payment_detection_service.dart';
import 'payment_event.dart';
import 'inventory_sync_service.dart';
import 'inventory_management_service.dart';
import 'secure_token_storage.dart';

/// Background listeners: new orders (owner) + UPI payment matching.
class OnlineOrdersListener {
  static final OnlineOrdersListener instance = OnlineOrdersListener._();
  OnlineOrdersListener._();

  StreamSubscription<QuerySnapshot>? _ordersSub;
  StreamSubscription<PaymentEvent>? _paymentSub;
  final Set<String> _notifiedOrderIds = {};
  String _shopId = '';
  WebSocketChannel? _realtimeChannel;
  StreamSubscription? _realtimeSub;
  Timer? _reconnectTimer;
  Timer? _fallbackTimer;
  bool _realtimeConnected = false;
  final StreamController<Map<String, dynamic>> _realtimeEvents =
      StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get onRealtimeEvent => _realtimeEvents.stream;
  bool _started = false;

  Future<void> stop() async {
    await _ordersSub?.cancel();
    await _paymentSub?.cancel();
    await _realtimeSub?.cancel();
    _ordersSub = null;
    _paymentSub = null;
    _realtimeSub = null;
    _realtimeChannel?.sink.close();
    _realtimeChannel = null;
    _reconnectTimer?.cancel();
    _fallbackTimer?.cancel();
    _reconnectTimer = null;
    _fallbackTimer = null;
    _realtimeConnected = false;
    _notifiedOrderIds.clear();
    _shopId = '';
    _started = false;
    if (kDebugMode) debugPrint('🛑 OnlineOrdersListener stopped');
  }

  /// Call after login or account switch (same app process).
  Future<void> restartForCurrentUser() async {
    await stop();
    await start();
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString('role');
    if (role == 'customer') return;

    _shopId = (prefs.getInt('user_id') ?? prefs.getInt('userId') ?? 0).toString();
    if (_shopId.isEmpty || _shopId == '0') {
      _started = false;
      return;
    }

    await OnlineOrderService.syncShopUpiToFirestore(_shopId);

    _connectBackendRealtime();

    _ordersSub = FirebaseFirestore.instance
        .collection('orders')
        .where('shop_id', isEqualTo: _shopId)
        .where('status', isEqualTo: 'Pending')
        .snapshots()
        .listen(_onPendingOrders);

    _paymentSub = PaymentDetectionService().onPaymentDetected.listen((event) {
      OnlineOrderService.tryMatchOnlineOrderPayment(event, _shopId);
    });

    if (kDebugMode) debugPrint('✅ OnlineOrdersListener started for shop $_shopId');
  }

  void _connectBackendRealtime() {
    _reconnectTimer?.cancel();
    _fallbackTimer?.cancel();

    Future<void> open() async {
      if (!_started || _shopId.isEmpty) return;

      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isEmpty) {
        _startFallbackRefresh();
        return;
      }

      try {
        final base = Uri.parse(ApiClient.baseUrl);
        final scheme = base.scheme == 'https' ? 'wss' : 'ws';
        final uri = base.replace(
          scheme: scheme,
          path: '/ws/owner/$_shopId',
          queryParameters: {'token': token},
        );

        await _realtimeSub?.cancel();
        await _realtimeChannel?.sink.close();
        final channel = WebSocketChannel.connect(uri);
        _realtimeChannel = channel;
        await channel.ready;

        _realtimeConnected = true;
        _fallbackTimer?.cancel();
        _fallbackTimer = null;
        if (kDebugMode) {
          debugPrint('✅ Backend realtime connected for shop $_shopId');
        }

        _realtimeSub = channel.stream.listen(
          (message) => _handleRealtimeMessage(message),
          onError: (Object error) {
            _realtimeConnected = false;
            if (kDebugMode) debugPrint('⚠️ Backend realtime error: $error');
            _startFallbackRefresh();
            _scheduleReconnect();
          },
          onDone: () {
            _realtimeConnected = false;
            _startFallbackRefresh();
            _scheduleReconnect();
          },
          cancelOnError: false,
        );

        channel.sink.add('ping');
      } catch (e) {
        _realtimeConnected = false;
        if (kDebugMode) debugPrint('⚠️ Backend realtime connect failed: $e');
        _startFallbackRefresh();
        _scheduleReconnect();
      }
    }

    unawaited(open());
  }

  void _scheduleReconnect() {
    if (!_started || _reconnectTimer != null) return;
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
      _reconnectTimer = null;
      _connectBackendRealtime();
    });
  }

  void _startFallbackRefresh() {
    if (!_started || _fallbackTimer != null) return;
    _fallbackTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (_realtimeConnected || !_started) return;
      final result = await InventorySyncService.refreshAllInventory();
      await InventorySyncService.updateLastSyncTimestamp();
      if (result['success'] == true) {
        _realtimeEvents.add({
          'type': 'fallback_refresh',
          'source': 'polling',
          'timestamp': DateTime.now().toIso8601String(),
        });
      }
    });
  }

  void _handleRealtimeMessage(dynamic message) {
    if (message == null) return;
    try {
      final decoded = message is String ? jsonDecode(message) : message;
      if (decoded is! Map) return;

      final event = Map<String, dynamic>.from(decoded);
      final type = event['type']?.toString() ?? '';
      if (type == 'connected') return;

      _realtimeEvents.add(event);
      if (type == 'online_order_created' || type == 'order_status_changed') {
        unawaited(_refreshAfterRealtimeOrder(event));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Realtime event parse error: $e');
    }
  }

  Future<void> _refreshAfterRealtimeOrder(Map<String, dynamic> event) async {
    final inventoryResult = await InventorySyncService.refreshAllInventory();
    await InventorySyncService.updateLastSyncTimestamp();
    if (inventoryResult['success'] == true) {
      InventoryManagementService.onInventoryChanged?.call();
    }

    final orderId = event['order_id']?.toString() ?? '';
    final eventType = event['type']?.toString() ?? '';

    if (eventType == 'online_order_created') {
      final total = (event['total_amount'] as num?)?.toDouble() ?? 0;
      await NotificationService.show(
        'New online order',
        'Order #' + orderId + ' · ₹' + total.toStringAsFixed(0) + ' · inventory updated',
        payload: 'online_order:' + orderId,
      );
    } else {
      final status = event['status']?.toString() ?? '';
      await NotificationService.show(
        'Order status updated',
        'Order #' + orderId + ' is now ' + status,
        payload: 'order_status:' + orderId,
      );
    }

    if (kDebugMode) {
      debugPrint('🔄 Realtime order sync: inventory=' + inventoryResult['success'].toString());
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
      unawaited(OnlineOrderService.notifyNewOrderForOwner(
        orderId: id,
        total: total,
        customerEmail: email,
      ));
    }
  }

  void dispose() {
    unawaited(stop());
    unawaited(_realtimeEvents.close());
  }
}
