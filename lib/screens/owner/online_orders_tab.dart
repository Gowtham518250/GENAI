import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../api_client.dart';
import '../../visual_widgets.dart';
import 'dart:async';
import 'package:url_launcher/url_launcher_string.dart';
class OnlineOrdersTab extends StatefulWidget {
  const OnlineOrdersTab({super.key});

  @override
  State<OnlineOrdersTab> createState() => _OnlineOrdersTabState();
}

class _OnlineOrdersTabState extends State<OnlineOrdersTab>
    with SingleTickerProviderStateMixin {
  String _shopId = '';
  List<Map<String, dynamic>> _pendingOrders = [];
  // 🚨 FIX: Accepted orders are now kept in their own list instead of just
  // vanishing once ACCEPT succeeds. Previously _fetchOrders() only ever asked
  // the backend for status=PENDING, so the moment an order was accepted it
  // dropped out of the only list the screen showed — it wasn't lost on the
  // backend, but the owner had no way to see it or its details again in-app.
  List<Map<String, dynamic>> _acceptedOrders = [];
  // 🛡️ FIX: previously only PENDING and ACCEPTED were ever fetched, so an
  // order that got dispatched (a real, valid next stage the backend
  // supports via action=DISPATCH) would disappear from view exactly the
  // same way the original bug worked, just one stage later. Tracking it
  // explicitly closes that gap.
  List<Map<String, dynamic>> _dispatchedOrders = [];
  List<Map<String, dynamic>> _deliveredOrders = [];
  List<Map<String, dynamic>> _returnedOrders = [];
  List<Map<String, dynamic>> _cancelledOrders = [];
  List<Map<String, dynamic>> _returnRequests = [];
  List<Map<String, dynamic>> _reviews = [];
  bool _isLoading = true;
  bool _isReturnsLoading = false;
  bool _isReviewsLoading = false;
  // Tracks order ids whose ACCEPT/REJECT call is still being retried in the
  // background, so the UI can show a "syncing" indicator instead of silently
  // failing if the network drops mid-action.
  final Set<String> _pendingSync = {};
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 7, vsync: this);
    _loadShopIdAndOrders();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _ordersCacheKey(int shopId, String status) =>
      'online_orders_cache_${shopId}_$status';

  Future<List<Map<String, dynamic>>> _loadCachedOrders(
    SharedPreferences prefs,
    int shopId,
    String status,
  ) async {
    final raw = prefs.getString(_ordersCacheKey(shopId, status));
    if (raw == null || raw.isEmpty) return <Map<String, dynamic>>[];

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <Map<String, dynamic>>[];
      return decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<void> _saveCachedOrders(
    SharedPreferences prefs,
    int shopId,
    String status,
    List<Map<String, dynamic>> orders,
  ) async {
    await prefs.setString(
      _ordersCacheKey(shopId, status),
      jsonEncode(orders),
    );
  }

  Future<void> _loadShopIdAndOrders() async {
    final prefs = await SharedPreferences.getInstance();
    final shopId = prefs.getInt('user_id') ?? 0;

    if (mounted) {
      setState(() => _shopId = shopId.toString());
    }

    bool loadedCache = false;

    // LOCAL-FIRST: restore all order tabs immediately.
    for (final status in const ['PENDING', 'ACCEPTED', 'DISPATCHED', 'DELIVERED', 'RETURNED', 'CANCELLED']) {
      final cached = await _loadCachedOrders(prefs, shopId, status);
      if (cached.isEmpty || !mounted) continue;

      loadedCache = true;
      setState(() {
        if (status == 'PENDING') {
          _pendingOrders = cached;
        } else if (status == 'ACCEPTED') {
          _acceptedOrders = cached;
        } else if (status == 'DISPATCHED') {
          _dispatchedOrders = cached;
        } else if (status == 'DELIVERED') {
          _deliveredOrders = cached;
        } else if (status == 'RETURNED') {
          _returnedOrders = cached;
        } else {
          _cancelledOrders = cached;
        }
      });
    }

    // Show cached orders immediately; refresh the server in the background.
    if (mounted && loadedCache) {
      setState(() => _isLoading = false);
    }

    await _fetchAllOrders(showLoading: !loadedCache);
    await Future.wait([
      _loadReturnRequests(),
      _loadReviews(),
    ]);
  }

  Future<void> _fetchAllOrders({bool showLoading = true}) async {
    if (showLoading && mounted) {
      setState(() => _isLoading = true);
    }

    try {
      // Fetch the canonical owner order list once. The backend already scopes
      // this response to the authenticated shop. Grouping locally avoids the
      // old four-request status/filter path that could show zero orders even
      // while the dashboard correctly reported existing online orders.
      final res = await ApiClient.getJson('/store/owner/orders');

      if (res.statusCode != 200) {
        throw Exception('Online orders request failed (status ' + res.statusCode.toString() + ').');
      }

      final decoded = json.decode(res.body);
      final rawOrders = decoded is Map ? decoded['orders'] : decoded;
      final allOrders = rawOrders is List
          ? rawOrders
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
          : <Map<String, dynamic>>[];

      final pending = <Map<String, dynamic>>[];
      final accepted = <Map<String, dynamic>>[];
      final dispatched = <Map<String, dynamic>>[];
      final delivered = <Map<String, dynamic>>[];
      final returned = <Map<String, dynamic>>[];
      final cancelled = <Map<String, dynamic>>[];

      for (final order in allOrders) {
        final status = (order['status'] ?? order['order_status'] ?? '')
            .toString()
            .trim()
            .toUpperCase();

        switch (status) {
          case 'PENDING':
            pending.add(order);
            break;
          case 'ACCEPTED':
            accepted.add(order);
            break;
          case 'DISPATCHED':
            dispatched.add(order);
            break;
          case 'DELIVERED':
            delivered.add(order);
            break;
          case 'RETURNED':
            returned.add(order);
            break;
          case 'CANCELLED':
          case 'REJECTED':
            cancelled.add(order);
            break;
          default:
            // Keep malformed/legacy statuses visible instead of silently
            // discarding an order. Surface it in Pending for owner attention.
            pending.add({...order, 'status': status.isEmpty ? 'PENDING' : status});
        }
      }

      final prefs = await SharedPreferences.getInstance();
      final shopId = int.tryParse(_shopId) ?? 0;
      if (shopId > 0) {
        await Future.wait([
          _saveCachedOrders(prefs, shopId, 'PENDING', pending),
          _saveCachedOrders(prefs, shopId, 'ACCEPTED', accepted),
          _saveCachedOrders(prefs, shopId, 'DISPATCHED', dispatched),
          _saveCachedOrders(prefs, shopId, 'DELIVERED', delivered),
          _saveCachedOrders(prefs, shopId, 'RETURNED', returned),
          _saveCachedOrders(prefs, shopId, 'CANCELLED', cancelled),
        ]);
      }

      if (!mounted) return;
      setState(() {
        _pendingOrders = pending;
        _acceptedOrders = accepted;
        _dispatchedOrders = dispatched;
        _deliveredOrders = delivered;
        _returnedOrders = returned;
        _cancelledOrders = cancelled;
      });

      debugPrint(
        'Loaded ' + allOrders.length.toString() + ' online orders '
        '(pending=' + pending.length.toString() + ', accepted=' +
        accepted.length.toString() + ', dispatched=' +
        dispatched.length.toString() + ', delivered=' +
        delivered.length.toString() + ')',
      );
    } catch (e) {
      debugPrint('Failed to fetch online orders: ' + e.toString());
      // Preserve locally cached data when a refresh fails.
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadReturnRequests() async {
    if (mounted) setState(() => _isReturnsLoading = true);
    try {
      final res = await ApiClient.getJson('/growth/returns');
      if (res.statusCode != 200) throw Exception('Returns request failed.');
      final decoded = json.decode(res.body);
      final rows = decoded is Map ? decoded['returns'] : decoded;
      final list = rows is List
          ? rows.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];
      if (mounted) setState(() => _returnRequests = list);
    } catch (e) {
      debugPrint('Failed to fetch return requests: $e');
    } finally {
      if (mounted) setState(() => _isReturnsLoading = false);
    }
  }

  Future<void> _loadReviews() async {
    if (mounted) setState(() => _isReviewsLoading = true);
    try {
      final res = await ApiClient.getJson('/store/owner/reviews');
      if (res.statusCode != 200) throw Exception('Reviews request failed.');
      final decoded = json.decode(res.body);
      final rows = decoded is Map ? decoded['reviews'] : decoded;
      final list = rows is List
          ? rows.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
          : <Map<String, dynamic>>[];
      if (mounted) setState(() => _reviews = list);
    } catch (e) {
      debugPrint('Failed to fetch reviews: $e');
    } finally {
      if (mounted) setState(() => _isReviewsLoading = false);
    }
  }

  Future<void> _decideReturn(Map<String, dynamic> request, bool approve) async {
    final returnId = request['id']?.toString() ?? '';
    if (returnId.isEmpty) return;

    final noteController = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(approve ? 'Accept returned order' : 'Reject return request'),
        content: TextField(
          controller: noteController,
          maxLines: 3,
          maxLength: 500,
          decoration: InputDecoration(
            labelText: approve ? 'Owner note (optional)' : 'Reason (optional)',
            hintText: approve
                ? 'Stock and online sales will be reversed.'
                : 'Tell the customer why the return is rejected.',
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, noteController.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: approve ? Colors.green : Colors.redAccent,
            ),
            child: Text(approve ? 'Accept return' : 'Reject return'),
          ),
        ],
      ),
    );
    noteController.dispose();

    if (!mounted || note == null) return;

    try {
      final res = await ApiClient.postJson(
        '/growth/returns/$returnId/decision',
        {'approve': approve, 'note': note.isEmpty ? null : note},
      );
      Map<String, dynamic> body = {};
      try {
        final decoded = json.decode(res.body);
        if (decoded is Map) body = Map<String, dynamic>.from(decoded);
      } catch (_) {}

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception(body['detail']?.toString() ?? 'Unable to process return request.');
      }

      await Future.wait([
        _fetchAllOrders(),
        _loadReturnRequests(),
      ]);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve
                ? 'Return accepted. Stock restored and online sale reversed.'
                : 'Return request rejected.',
          ),
          backgroundColor: approve ? Colors.green : Colors.redAccent,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceFirst('Exception: ', '')),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  Future<void> _updateOrderStatus(Map<String, dynamic> order, String action) async {
    final orderId = order['order_id']?.toString() ?? '0';

    // Delivery is a verified hand-off. The customer receives a fresh OTP and
    // the owner must enter it before the backend is allowed to mark DELIVERED.
    if (action == 'DELIVER') {
      await _deliverWithCustomerOtp(order);
      return;
    }

    // Optimistic local update: move the order between lists immediately so the
    // owner keeps seeing its full details right away, and retry the backend
    // call in the background instead of making the order vanish while we wait.
    setState(() {
      _pendingOrders.removeWhere((o) => o['order_id']?.toString() == orderId);
      _acceptedOrders.removeWhere((o) => o['order_id']?.toString() == orderId);
      _dispatchedOrders.removeWhere((o) => o['order_id']?.toString() == orderId);
      _deliveredOrders.removeWhere((o) => o['order_id']?.toString() == orderId);

      if (action == 'ACCEPT') {
        _acceptedOrders.insert(0, {...order, 'status': 'ACCEPTED'});
      } else if (action == 'DISPATCH') {
        _dispatchedOrders.insert(0, {...order, 'status': 'DISPATCHED'});
      } else if (action == 'DELIVER') {
        _deliveredOrders.insert(0, {...order, 'status': 'DELIVERED'});
      }

      _pendingSync.add(orderId);
    });

    // Persist the optimistic state before waiting for the network.
    unawaited(_persistCurrentOrderCaches());

    final ok = await _sendOrderAction(orderId, action);

    if (!mounted) return;
    setState(() => _pendingSync.remove(orderId));

    if (ok) {
      await _fetchAllOrders();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Order $action successfully!')),
      );
    } else {
      await _persistCurrentOrderCaches();

      // Keep the order visible (still marked as "syncing failed") and offer a
      // manual retry instead of losing the action entirely.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Order $action saved locally but not confirmed by server yet — tap to retry.'),
          action: SnackBarAction(
            label: 'RETRY',
            onPressed: () => _updateOrderStatus(order, action),
          ),
        ),
      );
    }
  }

  /// Backend call with a couple of quick retries — protects against a single
  /// dropped packet on flaky mobile data from silently losing the accept/reject.
  Future<void> _persistCurrentOrderCaches() async {
    try {
      final shopId = int.tryParse(_shopId) ?? 0;
      if (shopId <= 0) return;

      final prefs = await SharedPreferences.getInstance();
      await Future.wait([
        _saveCachedOrders(prefs, shopId, 'PENDING', _pendingOrders),
        _saveCachedOrders(prefs, shopId, 'ACCEPTED', _acceptedOrders),
        _saveCachedOrders(prefs, shopId, 'DISPATCHED', _dispatchedOrders),
        _saveCachedOrders(prefs, shopId, 'DELIVERED', _deliveredOrders),
        _saveCachedOrders(prefs, shopId, 'RETURNED', _returnedOrders),
        _saveCachedOrders(prefs, shopId, 'CANCELLED', _cancelledOrders),
      ]);
    } catch (e) {
      debugPrint('⚠️ Online order local cache write failed: $e');
    }
  }

  Future<bool> _sendOrderAction(
    String orderId,
    String action, {
    Map<String, dynamic>? body,
  }) async {
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final res = await ApiClient.postJson(
          '/store/owner/orders/$orderId/action?action=$action',
          body ?? const <String, dynamic>{},
        ).timeout(const Duration(seconds: 12));
        if (res.statusCode == 200) return true;

        // Never retry validation/auth errors. In particular, an invalid
        // delivery OTP must not consume multiple attempts because of client
        // retries.
        if (res.statusCode >= 400 && res.statusCode < 500) return false;
      } catch (e) {
        debugPrint('Order action attempt ${attempt + 1} failed: $e');
      }
      if (attempt < 2) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
    return false;
  }

  Future<Map<String, dynamic>> _requestDeliveryOtp(String orderId) async {
    try {
      final res = await ApiClient.postJson(
        '/store/owner/orders/$orderId/delivery-otp',
        const <String, dynamic>{},
      ).timeout(const Duration(seconds: 12));

      Map<String, dynamic> body = <String, dynamic>{};
      try {
        final decoded = json.decode(res.body);
        if (decoded is Map) {
          body = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}

      return {
        'success': res.statusCode >= 200 && res.statusCode < 300,
        'message': body['message']?.toString() ??
            body['detail']?.toString() ??
            'Unable to send customer delivery OTP.',
        'email': body['email']?.toString(),
        'expires_in': body['expires_in'],
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Unable to send customer delivery OTP. Please try again.',
      };
    }
  }

  Future<Map<String, dynamic>> _verifyDeliveryOtp(
    String orderId,
    String otp,
  ) async {
    try {
      final res = await ApiClient.postJson(
        '/store/owner/orders/$orderId/action?action=DELIVER',
        {'customer_otp': otp},
      ).timeout(const Duration(seconds: 12));

      Map<String, dynamic> body = <String, dynamic>{};
      try {
        final decoded = json.decode(res.body);
        if (decoded is Map) {
          body = Map<String, dynamic>.from(decoded);
        }
      } catch (_) {}

      return {
        'success': res.statusCode >= 200 && res.statusCode < 300,
        'message': body['message']?.toString() ??
            body['detail']?.toString() ??
            (res.statusCode == 200
                ? 'Order marked as delivered.'
                : 'Unable to verify customer delivery OTP.'),
      };
    } catch (e) {
      return {
        'success': false,
        'message': 'Unable to verify customer delivery OTP. Please try again.',
      };
    }
  }

  Future<void> _deliverWithCustomerOtp(Map<String, dynamic> order) async {
    final orderId = order['order_id']?.toString() ?? '0';
    if (orderId == '0') return;

    setState(() => _pendingSync.add(orderId));

    final otpResult = await _requestDeliveryOtp(orderId);
    if (!mounted) return;

    if (otpResult['success'] != true) {
      setState(() => _pendingSync.remove(orderId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            otpResult['message']?.toString() ??
                'Unable to send customer delivery OTP.',
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final controller = TextEditingController();
    final maskedEmail =
        otpResult['email']?.toString() ?? 'the customer account';
    final expires = otpResult['expires_in'] is num
        ? (otpResult['expires_in'] as num).toInt()
        : 600;

    final otp = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Verify customer before delivery'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'A 6-digit delivery OTP was sent to $maskedEmail. '
                'It expires in ${(expires / 60).ceil()} minutes.',
                style: const TextStyle(
                  color: Colors.black54,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Customer OTP',
                  hintText: '000000',
                  prefixIcon: Icon(Icons.verified_user_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (!RegExp(r'^\d{6}$').hasMatch(value)) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: Text('Enter the 6-digit customer OTP.'),
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext, value);
            },
            child: const Text('Verify & deliver'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted) return;

    if (otp == null) {
      setState(() => _pendingSync.remove(orderId));
      return;
    }

    final verifyResult = await _verifyDeliveryOtp(orderId, otp);
    if (!mounted) return;

    setState(() => _pendingSync.remove(orderId));

    if (verifyResult['success'] == true) {
      await _fetchAllOrders();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Customer OTP verified. Order marked as delivered.'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            verifyResult['message']?.toString() ??
                'Invalid or expired customer OTP.',
          ),
          backgroundColor: Colors.redAccent,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }


  Widget _buildReturnRequestsTab() {
    return RefreshIndicator(
      onRefresh: _loadReturnRequests,
      child: _isReturnsLoading
          ? const ListView(children: [
              SizedBox(height: 180),
              Center(child: CircularProgressIndicator()),
            ])
          : _returnRequests.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 120),
                  Center(child: Text('No return requests yet')),
                ])
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _returnRequests.length,
                  itemBuilder: (context, index) {
                    final request = _returnRequests[index];
                    final status = (request['status'] ?? 'REQUESTED').toString().toUpperCase();
                    final orderId = request['order_id']?.toString() ?? '—';
                    final customer = request['customer_name']?.toString() ?? 'Customer';
                    final amount = request['refund_amount'] ?? request['total_amount'] ?? 0;
                    final reason = request['reason']?.toString() ?? 'No reason provided';
                    final processed = status != 'REQUESTED';

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Return for Order #$orderId',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: AppColors.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        customer,
                                        style: const TextStyle(color: Colors.black87, fontSize: 14),
                                      ),
                                    ],
                                  ),
                                ),
                                Badge(
                                  label: Text(status),
                                  backgroundColor: status == 'REQUESTED'
                                      ? Colors.orange
                                      : status == 'REJECTED'
                                          ? Colors.redAccent
                                          : Colors.green,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Text(
                              reason,
                              style: const TextStyle(color: Colors.black87, fontSize: 14, height: 1.4),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text('Refund / order value',
                                    style: TextStyle(color: Colors.black54)),
                                Text(
                                  'Rs ' + (double.tryParse(amount.toString())?.toStringAsFixed(2) ?? amount.toString()),
                                  style: const TextStyle(
                                    color: Colors.black87,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                            if (request['stock_restored'] == true) ...[
                              const SizedBox(height: 8),
                              const Row(
                                children: [
                                  Icon(Icons.inventory_2_outlined, size: 16, color: Colors.green),
                                  SizedBox(width: 6),
                                  Text('Stock restored',
                                      style: TextStyle(color: Colors.green, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ],
                            if (!processed) ...[
                              const SizedBox(height: 16),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () => _decideReturn(request, false),
                                      icon: const Icon(Icons.close, size: 17),
                                      label: const Text('Reject Return'),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor: Colors.redAccent,
                                        side: const BorderSide(color: Colors.redAccent),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: ElevatedButton.icon(
                                      onPressed: () => _decideReturn(request, true),
                                      icon: const Icon(Icons.check_circle_outline, size: 17),
                                      label: const Text('Accept Return'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: Colors.green,
                                        foregroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildReviewsTab() {
    return RefreshIndicator(
      onRefresh: _loadReviews,
      child: _isReviewsLoading
          ? const ListView(children: [
              SizedBox(height: 180),
              Center(child: CircularProgressIndicator()),
            ])
          : _reviews.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 120),
                  Center(child: Text('No customer reviews yet')),
                ])
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _reviews.length,
                  itemBuilder: (context, index) {
                    final review = _reviews[index];
                    final rating = int.tryParse(review['rating']?.toString() ?? '') ?? 0;
                    final customer = review['customer_name']?.toString() ?? 'Customer';
                    final comment = review['comment']?.toString() ?? '';
                    final orderId = review['order_id']?.toString() ?? '—';

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: GlassContainer(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                CircleAvatar(
                                  radius: 21,
                                  backgroundColor: AppColors.primary.withValues(alpha: 0.12),
                                  child: Text(
                                    customer.isEmpty ? '?' : customer[0].toUpperCase(),
                                    style: const TextStyle(
                                      color: AppColors.primary,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(customer,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87,
                                          )),
                                      Text('Order #$orderId',
                                          style: const TextStyle(
                                            color: Colors.black54,
                                            fontSize: 12,
                                          )),
                                    ],
                                  ),
                                ),
                                Row(
                                  children: List.generate(
                                    5,
                                    (star) => Icon(
                                      star < rating ? Icons.star_rounded : Icons.star_border_rounded,
                                      color: Colors.amber,
                                      size: 19,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (comment.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: Colors.grey[50],
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  comment,
                                  style: const TextStyle(
                                    color: Colors.black87,
                                    height: 1.45,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_shopId.isEmpty || _shopId == '0') {
      return const Scaffold(body: Center(child: Text('Invalid Shop Profile')));
    }

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Online Orders', style: TextStyle(color: Colors.black87)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.black87),
        bottom: TabBar(
          controller: _tabController,
          labelColor: AppColors.primary,
          unselectedLabelColor: Colors.black54,
          indicatorColor: AppColors.primary,
          isScrollable: true,
          tabs: [
            Tab(text: 'Pending (${_pendingOrders.length})'),
            Tab(text: 'Accepted (${_acceptedOrders.length})'),
            Tab(text: 'Dispatched (${_dispatchedOrders.length})'),
            Tab(text: 'Delivered (${_deliveredOrders.length})'),
            Tab(text: 'Returns (${_returnRequests.where((r) => (r['status'] ?? '').toString().toUpperCase() == 'REQUESTED').length})'),
            Tab(text: 'Cancelled (${_cancelledOrders.length})'),
            Tab(text: 'Reviews (${_reviews.length})'),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                _buildOrderList(
                  orders: _pendingOrders,
                  emptyText: 'No incoming orders',
                  nextAction: 'ACCEPT',
                ),
                _buildOrderList(
                  orders: _acceptedOrders,
                  emptyText: 'No accepted orders yet',
                  nextAction: 'DISPATCH',
                ),
                _buildOrderList(
                  orders: _dispatchedOrders,
                  emptyText: 'No dispatched orders yet',
                  nextAction: 'DELIVER',
                ),
                _buildOrderList(
                  orders: _deliveredOrders,
                  emptyText: 'No delivered orders yet',
                  nextAction: null,
                ),
                _buildReturnRequestsTab(),
                _buildOrderList(
                  orders: _cancelledOrders,
                  emptyText: 'No cancelled orders yet',
                  nextAction: null,
                ),
                _buildReviewsTab(),
              ],
            ),
    );
  }

  Widget _buildCustomerActions(Map<String, dynamic> order) {
    final phone = (order['customer_phone'] ?? '').toString().replaceAll(RegExp(r'[^0-9+]'), '');
    final address = (order['delivery_address'] ?? order['address'] ?? '').toString().trim();

    Future<void> openMaps() async {
      if (address.isEmpty) return;
      final url = 'https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(address)}';
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    }

    Future<void> callCustomer() async {
      if (phone.isEmpty) return;
      await launchUrlString('tel:$phone');
    }

    Future<void> whatsappCustomer() async {
      if (phone.isEmpty) return;
      final digits = phone.replaceFirst(RegExp(r'^\+'), '');
      final url = 'https://wa.me/$digits';
      await launchUrlString(url, mode: LaunchMode.externalApplication);
    }

    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: address.isEmpty ? null : openMaps,
            icon: const Icon(Icons.location_on_outlined, size: 18),
            label: const Text('Location'),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Call customer',
          onPressed: phone.isEmpty ? null : callCustomer,
          icon: const Icon(Icons.phone_outlined, color: Colors.blue),
        ),
        Tooltip(
          message: 'WhatsApp',
          child: IconButton(
            onPressed: phone.isEmpty ? null : whatsappCustomer,
            icon: Image.network(
              'https://upload.wikimedia.org/wikipedia/commons/thumb/6/6b/WhatsApp.svg/64px-WhatsApp.svg.png',
              width: 24,
              height: 24,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.chat_outlined, color: Colors.green),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOrderList({
    required List<Map<String, dynamic>> orders,
    required String emptyText,
    required String? nextAction, // 'ACCEPT' | 'DISPATCH' | 'DELIVER' | null (no next stage from here)
  }) {
    return RefreshIndicator(
      onRefresh: _fetchAllOrders,
      child: orders.isEmpty
          ? ListView(
              children: [
                const SizedBox(height: 100),
                Center(child: Text(emptyText, style: const TextStyle(color: Colors.black54))),
              ],
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final order = orders[index];
                final orderId = order['order_id']?.toString() ?? '0';
                final items = order['items'] as List<dynamic>? ?? [];
                final syncing = _pendingSync.contains(orderId);

                return GlassContainer(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Order #$orderId',
                              style: const TextStyle(
                                  color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                          if (syncing)
                            const Badge(label: Text('SYNCING'), backgroundColor: Colors.orange)
                          else if (nextAction == 'ACCEPT')
                            const Badge(label: Text('NEW'), backgroundColor: Colors.redAccent)
                          else if (nextAction == 'DISPATCH')
                            const Badge(label: Text('ACCEPTED'), backgroundColor: Colors.green)
                          else
                            const Badge(label: Text('DISPATCHED'), backgroundColor: Colors.blue),
                        ],
                      ),
                      const Divider(color: Colors.black12, height: 24),
                      // FIX: backend never sends 'customer_email' -- it sends
                      // customer_name + customer_phone. This previously
                      // always rendered "Customer: null".
                      Text('Customer: ${order['customer_name'] ?? 'Guest'}',
                          style: const TextStyle(color: Colors.black87, fontSize: 16)),
                      if ((order['customer_phone'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(order['customer_phone'].toString(),
                              style: const TextStyle(color: Colors.black54, fontSize: 13)),
                        ),
                      if ((order['delivery_address'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text('Deliver to: ${order['delivery_address']}',
                              style: const TextStyle(color: Colors.black54, fontSize: 13)),
                        ),
                      const SizedBox(height: 10),
                      _buildCustomerActions(order),
                      const SizedBox(height: 16),
                      const Text('Items Requested:', style: TextStyle(color: Colors.black54, fontSize: 14)),
                      const SizedBox(height: 8),
                      ...items.map((item) {
                        // FIX: backend field is 'unit_price', not 'price' -- previously always 0/blank.
                        final qty = item['quantity'] ?? 1;
                        final unitPrice = (item['unit_price'] is num) ? (item['unit_price'] as num) : 0;
                        final qtyNum = (qty is num) ? qty : (num.tryParse(qty.toString()) ?? 1);
                        final lineTotal = unitPrice * qtyNum;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 4.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text('${qty}x ${item['product_name'] ?? 'Item'}',
                                  style: const TextStyle(color: Colors.black87)),
                              Text('Rs ${lineTotal.toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.black87)),
                            ],
                          ),
                        );
                      }),
                      const Divider(color: Colors.black12, height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Total Value', style: TextStyle(color: Colors.black54, fontSize: 16)),
                          Text('Rs ${order['total_amount']}',
                              style: const TextStyle(
                                  color: Colors.green, fontSize: 20, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      if (nextAction == 'ACCEPT') ...[
                        const SizedBox(height: 24),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: syncing ? null : () => _updateOrderStatus(order, 'REJECT'),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.redAccent,
                                  side: const BorderSide(color: Colors.redAccent),
                                ),
                                child: const Text('Reject'),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: syncing ? null : () => _updateOrderStatus(order, 'ACCEPT'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.primary,
                                  foregroundColor: Colors.white,
                                ),
                                child: const Text('Accept Order'),
                              ),
                            ),
                          ],
                        ),
                      ] else if (nextAction == 'DISPATCH') ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: syncing ? null : () => _updateOrderStatus(order, 'DISPATCH'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                            icon: const Icon(Icons.local_shipping_outlined, size: 18),
                            label: const Text('Mark as Dispatched'),
                          ),
                        ),
                      ] else if (nextAction == 'DELIVER') ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: syncing ? null : () => _updateOrderStatus(order, 'DELIVER'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                            icon: const Icon(Icons.check_circle_outline, size: 18),
                            label: const Text('Mark as Delivered'),
                          ),
                        ),
                      ] else if (syncing) ...[
                        const SizedBox(height: 12),
                        const Text('Confirming with server…', style: TextStyle(color: Colors.orange, fontSize: 12)),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }
}