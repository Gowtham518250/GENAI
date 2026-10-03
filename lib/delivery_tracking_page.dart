import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'delivery_tracking.dart';
import 'delivery_tracking_websocket.dart';
import 'secure_token_storage.dart';

/// Owner-facing live delivery tracking screen.
///
/// The dashboard can open this page for an order ID. The page does not invent
/// order/customer data; it shows live WebSocket status when the backend sends
/// updates and keeps the rest of the timeline in a safe pending state.
class DeliveryTrackingPage extends StatefulWidget {
  final int orderId;

  const DeliveryTrackingPage({super.key, required this.orderId});

  @override
  State<DeliveryTrackingPage> createState() => _DeliveryTrackingPageState();
}

class _DeliveryTrackingPageState extends State<DeliveryTrackingPage> {
  late final DeliveryTrackingWebSocket _socket;
  late final Future<void> _readyFuture;

  DeliveryUpdate? _latestUpdate;
  String? _error;

  @override
  void initState() {
    super.initState();
    _socket = DeliveryTrackingWebSocket();
    _readyFuture = _connect();
  }

  Future<void> _connect() async {
    final token = await SecureTokenStorage.getToken();
    if (!mounted) return;

    if (token == null || token.isEmpty) {
      setState(() {
        _error = 'Your owner session is unavailable. Please sign in again.';
      });
      return;
    }

    try {
      await _socket.connect(
        orderId: widget.orderId.toString(),
        token: token,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Live tracking is temporarily unavailable.';
      });
    }
  }

  @override
  void dispose() {
    _socket.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Delivery Tracking',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
        ),
      ),
      body: FutureBuilder<void>(
        future: _readyFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (_error != null) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _orderHeader(),
                const SizedBox(height: 16),
                _errorCard(_error!),
              ],
            );
          }

          return StreamBuilder<DeliveryUpdate>(
            stream: _socket.updateStream,
            builder: (context, updateSnapshot) {
              final update = updateSnapshot.data ?? _latestUpdate;

              return ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _orderHeader(),
                  const SizedBox(height: 16),
                  _connectionCard(),
                  const SizedBox(height: 16),
                  _timeline(update?.status),
                  const SizedBox(height: 16),
                  _statusDetails(update),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _orderHeader() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 24,
              child: Icon(Icons.local_shipping_outlined),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Order #${widget.orderId}',
                    style: GoogleFonts.poppins(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Live delivery status',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _connectionCard() {
    final connected = _socket.isConnected;
    return Card(
      child: ListTile(
        leading: Icon(
          connected ? Icons.wifi_rounded : Icons.wifi_off_rounded,
          color: connected ? Colors.green : Colors.orange,
        ),
        title: Text(connected ? 'Live connection active' : 'Connecting to tracking'),
        subtitle: const Text(
          'Status updates will appear here when the delivery service sends them.',
        ),
      ),
    );
  }

  Widget _errorCard(String message) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.info_outline_rounded),
        title: const Text('Tracking unavailable'),
        subtitle: Text(message),
      ),
    );
  }

  Widget _timeline(DeliveryStatus? currentStatus) {
    final status = currentStatus ?? DeliveryStatus.pending;
    final delivered = status == DeliveryStatus.delivered || status == DeliveryStatus.paid;
    final dispatched = delivered ||
        status == DeliveryStatus.dispatched;
    final cancelled = status == DeliveryStatus.cancelled;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tracking Timeline',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            _timelineRow(
              label: 'Order placed',
              completed: !cancelled,
              current: !cancelled && !dispatched,
              icon: Icons.receipt_long_outlined,
            ),
            _connector(dispatched && !cancelled),
            _timelineRow(
              label: 'Dispatched',
              completed: dispatched && !cancelled,
              current: status == DeliveryStatus.dispatched,
              icon: Icons.local_shipping_outlined,
            ),
            _connector(delivered && !cancelled),
            _timelineRow(
              label: status == DeliveryStatus.paid ? 'Paid' : 'Delivered',
              completed: delivered && !cancelled,
              current: delivered,
              icon: status == DeliveryStatus.paid
                  ? Icons.payments_outlined
                  : Icons.check_circle_outline,
            ),
            if (cancelled) ...[
              _connector(true),
              _timelineRow(
                label: 'Cancelled',
                completed: true,
                current: true,
                icon: Icons.cancel_outlined,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _timelineRow({
    required String label,
    required bool completed,
    required bool current,
    required IconData icon,
  }) {
    final color = completed
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.outlineVariant;

    return Row(
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: completed ? 0.14 : 0.06),
            shape: BoxShape.circle,
            border: current ? Border.all(color: color, width: 2) : null,
          ),
          child: Icon(icon, size: 20, color: color),
        ),
        const SizedBox(width: 12),
        Text(
          label,
          style: GoogleFonts.poppins(
            fontWeight: current ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _connector(bool completed) {
    return Padding(
      padding: const EdgeInsets.only(left: 19),
      child: Container(
        width: 2,
        height: 22,
        color: completed
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.45)
            : Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }

  Widget _statusDetails(DeliveryUpdate? update) {
    final status = update?.status ?? DeliveryStatus.pending;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Current status',
              style: GoogleFonts.poppins(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _formatStatus(status),
              style: GoogleFonts.poppins(
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (update != null) ...[
              const SizedBox(height: 8),
              Text(
                update.message,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 4),
              Text(
                _formatTime(update.timestamp),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Waiting for a delivery status update.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatStatus(DeliveryStatus status) {
    final value = status.name;
    return value[0].toUpperCase() + value.substring(1);
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}
