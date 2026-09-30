import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'api_client.dart';

typedef RealtimeMessageHandler = void Function(Map<String, dynamic> message);
typedef RealtimeStatusHandler = void Function(bool connected, String message);

class RealtimeClient {
  static WebSocket? _socket;
  static Timer? _heartbeat;
  static Timer? _reconnect;
  static RealtimeMessageHandler? _onMessage;
  static RealtimeStatusHandler? _onStatus;
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
  }) async {
    _userId = userId;
    _shopId = shopId;
    _onMessage = onMessage;
    _onStatus = onStatus;
    _closing = false;
    _attempt = 0;
    _cancelReconnect();
    if (kIsWeb) {
      _onStatus?.call(false, 'Live updates are not supported on web.');
      return;
    }
    await _connect();
  }

  static Future<void> _connect() async {
    final userId = _userId, shopId = _shopId;
    if (_closing || userId == null || shopId == null) return;
    final generation = ++_generation;
    _onStatus?.call(false, 'Connecting to live dashboard...');
    try {
      await _closeSocket();
      final ticket = await _ticket(shopId);
      if (ticket == null || ticket.isEmpty) throw StateError('Realtime ticket unavailable');
      final uri = _wsUri(userId, shopId, ticket);
      final socket = await WebSocket.connect(uri).timeout(const Duration(seconds: 15));
      if (_closing || generation != _generation) {
        await socket.close(WebSocketStatus.normalClosure, 'Stale connection');
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
      _onStatus?.call(true, 'Live dashboard connected');
    } catch (_) {
      if (_closing || generation != _generation) return;
      _onStatus?.call(false, 'Live connect failed');
      _scheduleReconnect();
    }
  }

  static Future<String?> _ticket(int shopId) async {
    final ticketReply = await ApiClient.getJson('/api/ws/token?shop_id=$shopId');
    if (ticketReply.statusCode != 200) return null;
    final body = jsonDecode(ticketReply.body);
    return body is Map<String, dynamic> ? body['token']?.toString() : null;
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

  static Future<void> disconnect() async {
    _closing = true;
    ++_generation;
    _cancelHeartbeat();
    _cancelReconnect();
    _attempt = 0;
    await _closeSocket();
    _onStatus?.call(false, 'Realtime disconnected');
  }

  static Future<void> _closeSocket() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close(WebSocketStatus.normalClosure, 'Realtime reconnect');
      } catch (_) {}
    }
    _cancelHeartbeat();
  }

  static void _handleMessage(dynamic raw) {
    try {
      final body = jsonDecode(raw.toString());
      if (body is Map<String, dynamic>) _onMessage?.call(body);
    } catch (_) {}
  }

  static void _done(int generation) {
    if (generation != _generation) return;
    _cancelHeartbeat();
    _onStatus?.call(false, 'Live dashboard disconnected');
    if (!_closing) _scheduleReconnect();
  }

  static void _error(int generation, Object error) {
    if (generation != _generation) return;
    _cancelHeartbeat();
    _onStatus?.call(false, 'Realtime connection error');
    if (!_closing) _scheduleReconnect();
  }

  static void _send(Map<String, dynamic> message) {
    if (isConnected) _socket!.add(jsonEncode(message));
  }

  static void _startHeartbeat() {
    _cancelHeartbeat();
    _heartbeat = Timer.periodic(const Duration(seconds: 20), (_) => _send({'action': 'ping'}));
  }

  static void _cancelHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  static void _scheduleReconnect() {
    if (_closing || _reconnect != null || _userId == null || _shopId == null) return;
    _attempt++;
    final exponent = _attempt.clamp(0, 5).toInt();
    final seconds = (1 << exponent).clamp(2, 30).toInt();
    _reconnect = Timer(Duration(seconds: seconds), () {
      _reconnect = null;
      if (!_closing) _connect();
    });
  }

  static void _cancelReconnect() {
    _reconnect?.cancel();
    _reconnect = null;
  }
}
