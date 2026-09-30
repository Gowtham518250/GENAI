import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'api_client.dart';

typedef RealtimeMessageHandler = void Function(Map<String, dynamic> message);
typedef RealtimeStatusHandler = void Function(bool connected, String message);

class _RealtimeSubscriber {
  _RealtimeSubscriber({
    required this.onMessage,
    required this.onStatus,
  });

  final RealtimeMessageHandler onMessage;
  final RealtimeStatusHandler onStatus;
}

class RealtimeClient {
  static WebSocket? _socket;
  static Timer? _heartbeat;
  static Timer? _reconnect;
  static final Map<String, _RealtimeSubscriber> _subscribers =
      <String, _RealtimeSubscriber>{};

  static int? _userId;
  static int? _shopId;
  static bool _closing = false;
  static int _attempt = 0;
  static int _generation = 0;

  static bool get isConnected =>
      _socket != null && _socket!.readyState == WebSocket.open;

  static Future<void> connect({
    required int userId,
    required int shopId,
    required RealtimeMessageHandler onMessage,
    required RealtimeStatusHandler onStatus,
    String subscriberId = 'default',
  }) async {
    if (kIsWeb) {
      onStatus(false, 'Live updates are not supported on web.');
      return;
    }

    final previousUserId = _userId;
    final previousShopId = _shopId;
    final connectionChanged = previousUserId != null &&
        (previousUserId != userId || previousShopId != shopId);

    _subscribers[subscriberId] = _RealtimeSubscriber(
      onMessage: onMessage,
      onStatus: onStatus,
    );

    _userId = userId;
    _shopId = shopId;
    _closing = false;

    if (connectionChanged) {
      await _closeSocket();
    }

    if (isConnected) {
      onStatus(true, 'Live dashboard connected');
      return;
    }

    if (_reconnect != null) {
      _cancelReconnect();
    }
    _attempt = 0;
    await _connect();
  }

  static Future<void> _connect() async {
    final userId = _userId;
    final shopId = _shopId;
    if (_closing || userId == null || shopId == null || _subscribers.isEmpty) {
      return;
    }

    final generation = ++_generation;
    _broadcastStatus(false, 'Connecting to live dashboard...');

    try {
      await _closeSocket();

      final ticket = await _ticket(shopId);
      if (ticket == null || ticket.isEmpty) {
        throw StateError('Realtime ticket unavailable');
      }

      final uri = _wsUri(userId, shopId, ticket);
      final socket =
          await WebSocket.connect(uri.toString()).timeout(
            const Duration(seconds: 15),
          );

      if (_closing || generation != _generation || _subscribers.isEmpty) {
        await socket.close(
          WebSocketStatus.normalClosure,
          'Stale realtime connection',
        );
        return;
      }

      _socket = socket;
      _attempt = 0;

      socket.listen(
        _handleMessage,
        onDone: () => _done(generation),
        onError: (error) => _error(generation, error),
        cancelOnError: true,
      );

      _send({'action': 'subscribe', 'channel': 'all'});
      _startHeartbeat();
      _broadcastStatus(true, 'Live dashboard connected');
    } catch (_) {
      if (_closing || generation != _generation || _subscribers.isEmpty) {
        return;
      }
      _broadcastStatus(false, 'Live connect failed');
      _scheduleReconnect();
    }
  }

  static Future<String?> _ticket(int shopId) async {
    try {
      final ticketReply =
          await ApiClient.getJson('/api/ws/token?shop_id=$shopId');
      if (ticketReply.statusCode != 200) return null;
      final body = jsonDecode(ticketReply.body);
      return body is Map<String, dynamic> ? body['token']?.toString() : null;
    } catch (error) {
      debugPrint('Realtime ticket request failed: $error');
      return null;
    }
  }

  static Uri _wsUri(int userId, int shopId, String ticket) {
    final base = Uri.parse(ApiClient.baseUrl);
    return Uri(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/api/ws/live/$userId/$shopId',
      queryParameters: {'ticket': ticket},
    );
  }

  static Future<void> disconnect({String subscriberId = 'default'}) async {
    _subscribers.remove(subscriberId);

    if (_subscribers.isNotEmpty) {
      return;
    }

    _closing = true;
    ++_generation;
    _cancelHeartbeat();
    _cancelReconnect();
    _attempt = 0;
    await _closeSocket();
    _broadcastStatus(false, 'Realtime disconnected');
  }

  static Future<void> disconnectAll() async {
    _subscribers.clear();
    _closing = true;
    ++_generation;
    _cancelHeartbeat();
    _cancelReconnect();
    _attempt = 0;
    await _closeSocket();
  }

  static Future<void> _closeSocket() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close(
          WebSocketStatus.normalClosure,
          'Realtime reconnect',
        );
      } catch (_) {}
    }
    _cancelHeartbeat();
  }

  static void _handleMessage(dynamic raw) {
    try {
      final body = jsonDecode(raw.toString());
      if (body is Map<String, dynamic>) {
        final snapshot =
            List<_RealtimeSubscriber>.from(_subscribers.values);
        for (final subscriber in snapshot) {
          try {
            subscriber.onMessage(body);
          } catch (error, stack) {
            debugPrint('Realtime subscriber error: $error\n$stack');
          }
        }
      }
    } catch (error) {
      debugPrint('Realtime payload decode failed: $error');
    }
  }

  static void _broadcastStatus(bool connected, String message) {
    final snapshot = List<_RealtimeSubscriber>.from(_subscribers.values);
    for (final subscriber in snapshot) {
      try {
        subscriber.onStatus(connected, message);
      } catch (error, stack) {
        debugPrint('Realtime status subscriber error: $error\n$stack');
      }
    }
  }

  static void _done(int generation) {
    if (generation != _generation) return;
    _cancelHeartbeat();
    _broadcastStatus(false, 'Live dashboard disconnected');
    if (!_closing && _subscribers.isNotEmpty) {
      _scheduleReconnect();
    }
  }

  static void _error(int generation, Object error) {
    if (generation != _generation) return;
    _cancelHeartbeat();
    _broadcastStatus(false, 'Realtime connection error');
    if (!_closing && _subscribers.isNotEmpty) {
      _scheduleReconnect();
    }
  }

  static void _send(Map<String, dynamic> message) {
    if (isConnected) {
      _socket!.add(jsonEncode(message));
    }
  }

  static void _startHeartbeat() {
    _cancelHeartbeat();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _send({'action': 'ping'}),
    );
  }

  static void _cancelHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  static void _scheduleReconnect() {
    if (_closing ||
        _reconnect != null ||
        _userId == null ||
        _shopId == null ||
        _subscribers.isEmpty) {
      return;
    }

    _attempt++;
    final exponent = _attempt.clamp(0, 5).toInt();
    final seconds = (1 << exponent).clamp(2, 30).toInt();

    _reconnect = Timer(Duration(seconds: seconds), () {
      _reconnect = null;
      if (!_closing && _subscribers.isNotEmpty) {
        _connect();
      }
    });
  }

  static void _cancelReconnect() {
    _reconnect?.cancel();
    _reconnect = null;
  }
}
