import '../../live_translated_text.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';
import '../../api_client.dart';
import '../../visual_widgets.dart';
import '../../sync_service.dart';
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
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _searchedOrders = [];
  bool _isSearchingHistory = false;
  String _searchError = '';
  int _searchTotal = 0;
  int _historySearchVersion = 0;
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
  StreamSubscription<List<Map<String, dynamic>>>? _durableEventsSubscription;
  bool _ordersFetchInProgress = false;
  bool _ordersRefreshPending = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 8, vsync: this);
    _loadShopIdAndOrders();
    _durableEventsSubscription = SyncService.durableEventsStream.listen((events) {
      if (!mounted) return;
      final hasOrderChange = events.any((event) {
        final type = event['type']?.toString();
        return type == 'order.created' ||
            type == 'order.status_changed' ||
            type == 'order.payment_confirmed';
      });
      if (hasOrderChange) unawaited(_fetchAllOrders(showLoading: false));
    });
  }

  @override
  void dispose() {
    _durableEventsSubscription?.cancel();
    _searchDebounce?.cancel();
    _searchController.dispose();
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
    // WebSocket events, durable recovery, and manual refresh may coincide.
    // Coalesce concurrent reads but guarantee a follow-up if a newer event
    // arrived after the current request started.
    if (_ordersFetchInProgress) {
      _ordersRefreshPending = true;
      return;
    }
    _ordersFetchInProgress = true;
    if (showLoading && mounted) {
      setState(() => _isLoading = true);
    }

    try {
      // Fetch the canonical owner order list once. The backend already scopes
      // this response to the authenticated shop. Grouping locally avoids the
      // old four-request status/filter path that could show zero orders even
      // while the dashboard correctly reported existing online orders.
      final res = await ApiClient.getJson('/store/owner/orders?limit=200');

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

      // Keep name/phone search results in sync when an order advances locally
      // or another worker changes it through the durable event feed.
      final activeQuery = _searchController.text.trim();
      if (activeQuery.isNotEmpty) {
        _searchDebounce?.cancel();
        final searchVersion = ++_historySearchVersion;
        if (mounted) setState(() => _isSearchingHistory = true);
        unawaited(_searchOnlineHistory(activeQuery, searchVersion));
      }
    } catch (e) {
      debugPrint('Failed to fetch online orders: ' + e.toString());
      // Preserve locally cached data when a refresh fails.
    } finally {
      _ordersFetchInProgress = false;
      if (mounted && showLoading) setState(() => _isLoading = false);
      if (_ordersRefreshPending && mounted) {
        _ordersRefreshPending = false;
        unawaited(_fetchAllOrders(showLoading: false));
      }
    }
  }

  List<Map<String, dynamic>> _allLoadedOrders() {
    final byId = <String, Map<String, dynamic>>{};
    for (final order in <Map<String, dynamic>>[
      ..._pendingOrders,
      ..._acceptedOrders,
      ..._dispatchedOrders,
      ..._deliveredOrders,
      ..._returnedOrders,
      ..._cancelledOrders,
    ]) {
      final id = (order['order_id'] ?? '').toString();
      final key = id.isEmpty
          ? (order['customer_name'] ?? '').toString() + '_' +
              (order['created_at'] ?? '').toString() + '_' + byId.length.toString()
          : id;
      byId[key] = order;
    }

    final orders = byId.values.toList();
    DateTime dateOf(Map<String, dynamic> order) =>
        DateTime.tryParse((order['created_at'] ?? '').toString()) ??
        DateTime.fromMillisecondsSinceEpoch(0);
    orders.sort((a, b) => dateOf(b).compareTo(dateOf(a)));
    return orders;
  }

  String _statusOf(Map<String, dynamic> order) =>
      (order['status'] ?? order['order_status'] ?? '')
          .toString()
          .trim()
          .toUpperCase();

  List<Map<String, dynamic>> _ordersForStatus(String? status) {
    final searching = _searchController.text.trim().isNotEmpty;
    final source = searching ? _searchedOrders : _allLoadedOrders();
    if (status == null) return source;

    return source.where((order) {
      final actual = _statusOf(order);
      if (status == 'CANCELLED') {
        return actual == 'CANCELLED' || actual == 'REJECTED';
      }
      return actual == status;
    }).toList();
  }

  void _onOrderSearchChanged(String rawValue) {
    _searchDebounce?.cancel();
    final requestVersion = ++_historySearchVersion;
    final query = rawValue.trim();

    if (query.isEmpty) {
      if (!mounted) return;
      setState(() {
        _searchedOrders = [];
        _searchTotal = 0;
        _searchError = '';
        _isSearchingHistory = false;
      });
      return;
    }

    if (_tabController.index != 0) {
      _tabController.animateTo(0);
    }
    setState(() {
      _searchedOrders = [];
      _searchTotal = 0;
      _searchError = '';
      _isSearchingHistory = true;
    });
    _searchDebounce = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_searchOnlineHistory(query, requestVersion)),
    );
  }

  Future<void> _searchOnlineHistory(String query, int requestVersion) async {
    try {
      final res = await ApiClient.getJson(
        '/store/owner/orders?search=' + Uri.encodeQueryComponent(query) + '&limit=200',
      ).timeout(const Duration(seconds: 15));

      if (res.statusCode != 200) {
        throw Exception('Order history search failed (' + res.statusCode.toString() + ').');
      }

      final decoded = json.decode(res.body);
      final rawOrders = decoded is Map ? decoded['orders'] : decoded;
      final orders = rawOrders is List
          ? rawOrders
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
          : <Map<String, dynamic>>[];
      final total = decoded is Map
          ? (int.tryParse(decoded['total']?.toString() ?? '') ?? orders.length)
          : orders.length;

      if (!mounted ||
          requestVersion != _historySearchVersion ||
          query != _searchController.text.trim()) {
        return;
      }

      setState(() {
        _searchedOrders = orders;
        _searchTotal = total;
        _searchError = '';
        _isSearchingHistory = false;
      });
    } catch (error) {
      if (!mounted ||
          requestVersion != _historySearchVersion ||
          query != _searchController.text.trim()) {
        return;
      }
      setState(() {
        _searchedOrders = [];
        _searchTotal = 0;
        _searchError = 'Could not search order history. Pull down to retry.';
        _isSearchingHistory = false;
      });
      if (kDebugMode) {
        debugPrint('Online order history search failed: $error');
      }
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
        title: LiveTranslatedText(approve ? 'Accept returned order' : 'Reject return request'),
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
            child: const LiveTranslatedText('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, noteController.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: approve ? Colors.green : Colors.redAccent,
            ),
            child: LiveTranslatedText(approve ? 'Accept return' : 'Reject return'),
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
          content: LiveTranslatedText(
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
          content: LiveTranslatedText(e.toString().replaceFirst('Exception: ', '')),
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
      } else if (action == 'REJECT') {
        _cancelledOrders.insert(0, {...order, 'status': 'REJECTED'});
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
        SnackBar(content: LiveTranslatedText('Order $action successfully!')),
      );
    } else {
      await _persistCurrentOrderCaches();

      // Keep the order visible (still marked as "syncing failed") and offer a
      // manual retry instead of losing the action entirely.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: LiveTranslatedText('Order $action saved locally but not confirmed by server yet — tap to retry.'),
          action: SnackBarAction(
            label: 'RETRY',
            onPressed: () => _updateOrderStatus(order, action),
          ),
        ),
      );
    }
  }

  /// Persist the optimistic order state locally. The server action itself
  /// is intentionally sent only once here: POST actions can commit on the
  /// server even when the client times out before receiving the response.
  /// The backend action endpoint is idempotent, so a later manual retry is safe.
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
    try {
      // Do not layer another retry loop on top of ApiClient's transport
      // retries. If the server commits the POST and the response is delayed,
      // a second client POST can race on the same order row and leave the UI
      // looking stuck. The backend now treats already-applied transitions as
      // idempotent, so a deliberate manual retry remains safe.
      final res = await ApiClient.postJson(
        '/store/owner/orders/$orderId/action?action=$action',
        body ?? const <String, dynamic>{},
      ).timeout(const Duration(seconds: 30));

      if (res.statusCode >= 200 && res.statusCode < 300) {
        return true;
      }

      if (kDebugMode) {
        debugPrint(
          'Order action $action for #$orderId returned ${res.statusCode}: ${res.body}',
        );
      }
      return false;
    } catch (e) {
      debugPrint('Order action $action for #$orderId failed: $e');
      return false;
    }
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
          content: LiveTranslatedText(
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
        title: const LiveTranslatedText('Verify customer before delivery'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LiveTranslatedText(
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
                  label: LiveTranslatedText('Customer OTP'),
                  hint: LiveTranslatedText('000000'),
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
            child: const LiveTranslatedText('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (!RegExp(r'^\d{6}$').hasMatch(value)) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(
                    content: LiveTranslatedText('Enter the 6-digit customer OTP.'),
                  ),
                );
                return;
              }
              Navigator.pop(dialogContext, value);
            },
            child: const LiveTranslatedText('Verify & deliver'),
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
          content: LiveTranslatedText('Customer OTP verified. Order marked as delivered.'),
          backgroundColor: Colors.green,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: LiveTranslatedText(
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
          ? ListView(children: [
              SizedBox(height: 180),
              Center(child: CircularProgressIndicator()),
            ])
          : _returnRequests.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 120),
                  Center(child: LiveTranslatedText('No return requests yet')),
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
                                      LiveTranslatedText(
                                        'Return for Order #$orderId',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 16,
                                          color: AppColors.primary,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      LiveTranslatedText(
                                        customer,
                                        style: const TextStyle(color: Colors.black87, fontSize: 14),
                                      ),
                                    ],
                                  ),
                                ),
                                Badge(
                                  label: LiveTranslatedText(status),
                                  backgroundColor: status == 'REQUESTED'
                                      ? Colors.orange
                                      : status == 'REJECTED'
                                          ? Colors.redAccent
                                          : Colors.green,
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            LiveTranslatedText(
                              reason,
                              style: const TextStyle(color: Colors.black87, fontSize: 14, height: 1.4),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const LiveTranslatedText('Refund / order value',
                                    style: TextStyle(color: Colors.black54)),
                                LiveTranslatedText(
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
                                  LiveTranslatedText('Stock restored',
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
                                      label: const LiveTranslatedText('Reject Return'),
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
                                      label: const LiveTranslatedText('Accept Return'),
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
          ? ListView(children: [
              SizedBox(height: 180),
              Center(child: CircularProgressIndicator()),
            ])
          : _reviews.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 120),
                  Center(child: LiveTranslatedText('No customer reviews yet')),
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
                                  child: LiveTranslatedText(
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
                                      LiveTranslatedText(customer,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.bold,
                                            color: Colors.black87,
                                          )),
                                      LiveTranslatedText('Order #$orderId',
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
                                child: LiveTranslatedText(
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

  Widget _buildOrdersHero() {
    final all = _allLoadedOrders();
    final count = _searchController.text.trim().isNotEmpty
        ? _searchTotal
        : all.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF312E81), Color(0xFF635BFF), Color(0xFF8B5CF6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF635BFF).withValues(alpha: 0.18),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LiveTranslatedText(
                  'ORDER CONTROL CENTRE',
                  style: TextStyle(
                    color: Color(0xFFDAD7FF),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                const LiveTranslatedText(
                  'Every order, in control.',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 21,
                    height: 1.2,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                LiveTranslatedText(
                  _searchController.text.trim().isEmpty
                      ? 'Track orders from acceptance to delivery.'
                      : 'Searching the full order history.',
                  style: const TextStyle(
                    color: Color(0xFFE7E5FF),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.13),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
            ),
            child: const Icon(Icons.shopping_bag_rounded, color: Colors.white, size: 32),
          ),
        ],
      ),
    );
  }

  Widget _buildOrderSearch() {
    final query = _searchController.text.trim();
    String helperText;
    if (query.isEmpty) {
      helperText = 'Search by customer name, phone number, or order ID';
    } else if (_isSearchingHistory) {
      helperText = 'Searching all order statuses…';
    } else if (_searchError.isNotEmpty) {
      helperText = _searchError;
    } else if (_searchTotal > _searchedOrders.length) {
      helperText = 'Showing ' + _searchedOrders.length.toString() +
          ' of ' + _searchTotal.toString() + ' matching orders';
    } else {
      helperText = _searchTotal.toString() + ' matching order' +
          (_searchTotal == 1 ? '' : 's') + ' found';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _searchController,
          onChanged: _onOrderSearchChanged,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hint: LiveTranslatedText('Find an order or customer…'),
            hintStyle: TextStyle(color: Colors.grey.shade500, fontSize: 14),
            prefixIcon: const Icon(Icons.search_rounded, color: AppColors.primary),
            suffixIcon: query.isEmpty
                ? const Icon(Icons.manage_search_rounded, color: Colors.black38)
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _searchController.clear();
                      _onOrderSearchChanged('');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
            filled: true,
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFE7EAF3)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: Color(0xFFE7EAF3)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              if (_isSearchingHistory)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              else
                Icon(
                  query.isEmpty ? Icons.tips_and_updates_outlined : Icons.check_circle_outline,
                  size: 14,
                  color: query.isEmpty ? Colors.black45 : AppColors.primary,
                ),
              const SizedBox(width: 6),
              Expanded(
                child: LiveTranslatedText(
                  helperText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _searchError.isNotEmpty ? Colors.redAccent : Colors.black54,
                    fontSize: 11,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildOrderStat({
    required String label,
    required int value,
    required IconData icon,
    required Color tint,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE9ECF5)),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(icon, size: 18, color: tint),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LiveTranslatedText(
                    value.toString(),
                    style: const TextStyle(
                      color: Color(0xFF17172A),
                      fontSize: 18,
                      height: 1.15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 3),
                  LiveTranslatedText(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderStats() {
    final pending = _ordersForStatus('PENDING').length;
    final processing =
        _ordersForStatus('ACCEPTED').length + _ordersForStatus('DISPATCHED').length;
    final delivered = _ordersForStatus('DELIVERED').length;
    return Row(
      children: [
        _buildOrderStat(
          label: 'Pending',
          value: pending,
          icon: Icons.notifications_active_outlined,
          tint: const Color(0xFFF59E0B),
        ),
        const SizedBox(width: 8),
        _buildOrderStat(
          label: 'In progress',
          value: processing,
          icon: Icons.local_shipping_outlined,
          tint: const Color(0xFF3B82F6),
        ),
        const SizedBox(width: 8),
        _buildOrderStat(
          label: 'Delivered',
          value: delivered,
          icon: Icons.check_circle_outline_rounded,
          tint: const Color(0xFF16A34A),
        ),
      ],
    );
  }

  Widget _buildOrderTabs() {
    final allCount = _searchController.text.trim().isNotEmpty
        ? _searchTotal
        : _allLoadedOrders().length;
    final returnsCount = _returnRequests.where(
      (r) => (r['status'] ?? '').toString().toUpperCase() == 'REQUESTED',
    ).length;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: const Color(0xFFE9ECF5)),
      ),
      child: TabBar(
        controller: _tabController,
        isScrollable: true,
        labelColor: Colors.white,
        unselectedLabelColor: Colors.black54,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: Colors.transparent,
        indicator: BoxDecoration(
          color: AppColors.primary,
          borderRadius: BorderRadius.circular(13),
        ),
        labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        unselectedLabelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        tabs: [
          Tab(text: 'All (' + allCount.toString() + ')'),
          Tab(text: 'Pending (' + _ordersForStatus('PENDING').length.toString() + ')'),
          Tab(text: 'Accepted (' + _ordersForStatus('ACCEPTED').length.toString() + ')'),
          Tab(text: 'Dispatched (' + _ordersForStatus('DISPATCHED').length.toString() + ')'),
          Tab(text: 'Delivered (' + _ordersForStatus('DELIVERED').length.toString() + ')'),
          Tab(text: 'Returns (' + returnsCount.toString() + ')'),
          Tab(text: 'Cancelled (' + _ordersForStatus('CANCELLED').length.toString() + ')'),
          Tab(text: 'Reviews (' + _reviews.length.toString() + ')'),
        ],
      ),
    );
  }

  Widget _buildOrderStatusBadge({
    required String status,
    required bool syncing,
  }) {
    final normalized = status.trim().toUpperCase();
    final label = syncing
        ? 'SYNCING'
        : normalized == 'PENDING'
            ? 'NEW'
            : normalized.isEmpty
                ? 'ORDER'
                : normalized.replaceAll('_', ' ');
    final Color color = syncing
        ? Colors.orange
        : normalized == 'PENDING'
            ? const Color(0xFFD97706)
            : normalized == 'ACCEPTED'
                ? AppColors.primary
                : normalized == 'DISPATCHED'
                    ? const Color(0xFF2563EB)
                    : normalized == 'DELIVERED'
                        ? const Color(0xFF15803D)
                        : normalized == 'RETURNED'
                            ? const Color(0xFF7C3AED)
                            : normalized == 'CANCELLED' || normalized == 'REJECTED'
                                ? const Color(0xFFDC2626)
                                : Colors.blueGrey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: LiveTranslatedText(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          letterSpacing: 0.3,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_shopId.isEmpty || _shopId == '0') {
      return const Scaffold(body: Center(child: LiveTranslatedText('Invalid Shop Profile')));
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        toolbarHeight: 70,
        iconTheme: const IconThemeData(color: Color(0xFF17172A)),
        title: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppColors.primary, Color(0xFF8B5CF6)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(Icons.shopping_bag_outlined, color: Colors.white, size: 23),
            ),
            const SizedBox(width: 11),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LiveTranslatedText(
                    'Online Orders',
                    style: TextStyle(color: Color(0xFF17172A), fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 2),
                  LiveTranslatedText(
                    'Fulfilment dashboard',
                    style: TextStyle(color: Colors.black54, fontSize: 11, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh orders',
            onPressed: () {
              final query = _searchController.text.trim();
              if (query.isNotEmpty) {
                _onOrderSearchChanged(query);
              } else {
                unawaited(_fetchAllOrders(showLoading: false));
              }
            },
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  child: _buildOrdersHero(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: _buildOrderSearch(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: _buildOrderStats(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: _buildOrderTabs(),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildOrderList(
                        orders: _ordersForStatus(null),
                        emptyText: 'No online orders yet',
                        nextAction: null,
                      ),
                      _buildOrderList(
                        orders: _ordersForStatus('PENDING'),
                        emptyText: 'No incoming orders',
                        nextAction: 'ACCEPT',
                      ),
                      _buildOrderList(
                        orders: _ordersForStatus('ACCEPTED'),
                        emptyText: 'No accepted orders yet',
                        nextAction: 'DISPATCH',
                      ),
                      _buildOrderList(
                        orders: _ordersForStatus('DISPATCHED'),
                        emptyText: 'No dispatched orders yet',
                        nextAction: 'DELIVER',
                      ),
                      _buildOrderList(
                        orders: _ordersForStatus('DELIVERED'),
                        emptyText: 'No delivered orders yet',
                        nextAction: null,
                      ),
                      _buildReturnRequestsTab(),
                      _buildOrderList(
                        orders: _ordersForStatus('CANCELLED'),
                        emptyText: 'No cancelled orders yet',
                        nextAction: null,
                      ),
                      _buildReviewsTab(),
                    ],
                  ),
                ),
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
            label: const LiveTranslatedText('Location'),
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
    final query = _searchController.text.trim();
    return RefreshIndicator(
      onRefresh: () async {
        if (query.isNotEmpty) {
          await _searchOnlineHistory(query, _historySearchVersion);
        } else {
          await _fetchAllOrders();
        }
      },
      child: _isSearchingHistory && query.isNotEmpty
          ? ListView(
              children: const [
                SizedBox(height: 110),
                Center(child: CircularProgressIndicator()),
                SizedBox(height: 14),
                Center(child: LiveTranslatedText('Searching full order history…')),
              ],
            )
          : orders.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 85),
                    Icon(
                      query.isNotEmpty ? Icons.search_off_rounded : Icons.inbox_outlined,
                      size: 48,
                      color: Colors.black26,
                    ),
                    const SizedBox(height: 10),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 30),
                        child: LiveTranslatedText(
                          query.isNotEmpty
                              ? (_searchError.isNotEmpty
                                  ? _searchError
                                  : 'No orders found for "' + query + '"')
                              : emptyText,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: orders.length,
              itemBuilder: (context, index) {
                final order = orders[index];
                final orderId = order['order_id']?.toString() ?? '0';
                final orderStatus = _statusOf(order);
                final effectiveAction = nextAction ??
                    (orderStatus == 'PENDING'
                        ? 'ACCEPT'
                        : orderStatus == 'ACCEPTED'
                            ? 'DISPATCH'
                            : orderStatus == 'DISPATCHED'
                                ? 'DELIVER'
                                : null);
                final items = order['items'] as List<dynamic>? ?? [];
                final syncing = _pendingSync.contains(orderId);
                final paymentStatus = (order['payment_status'] ?? '').toString().toUpperCase();
                final paymentMethod = (order['payment_method'] ?? '').toString().toUpperCase();
                final paymentLabel = paymentStatus == 'REFUND_REQUIRED'
                    ? 'REFUND REQUIRED — owner follow-up needed'
                    : paymentStatus == 'REVIEW_REQUIRED'
                        ? 'PAYMENT NEEDS REVIEW'
                        : paymentStatus == 'PAID'
                            ? (paymentMethod == 'UPI' ? 'UPI PAYMENT CONFIRMED' : 'PAID')
                            : paymentStatus == 'PENDING'
                                ? 'UPI PAYMENT PENDING'
                                : paymentStatus == 'COD_DUE'
                                    ? 'CASH ON DELIVERY'
                                    : paymentStatus == 'UNPAID'
                                        ? 'PAYMENT DUE'
                                        : '';

                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(17),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFE8EBF4)),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF1F2A5A).withValues(alpha: 0.035),
                        blurRadius: 16,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          LiveTranslatedText('Order #$orderId',
                              style: const TextStyle(
                                  color: AppColors.primary, fontWeight: FontWeight.bold, fontSize: 16)),
                          _buildOrderStatusBadge(status: orderStatus, syncing: syncing),
                        ],
                      ),
                      const Divider(color: Colors.black12, height: 24),
                      // FIX: backend never sends 'customer_email' -- it sends
                      // customer_name + customer_phone. This previously
                      // always rendered "Customer: null".
                      LiveTranslatedText('Customer: ${order['customer_name'] ?? 'Guest'}',
                          style: const TextStyle(color: Colors.black87, fontSize: 16)),
                      if ((order['customer_phone'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: LiveTranslatedText(order['customer_phone'].toString(),
                              style: const TextStyle(color: Colors.black54, fontSize: 13)),
                        ),
                      if ((order['delivery_address'] ?? '').toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: LiveTranslatedText('Deliver to: ${order['delivery_address']}',
                              style: const TextStyle(color: Colors.black54, fontSize: 13)),
                        ),
                      const SizedBox(height: 10),
                      _buildCustomerActions(order),
                      const SizedBox(height: 16),
                      const LiveTranslatedText('Items Requested:', style: TextStyle(color: Colors.black54, fontSize: 14)),
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
                              LiveTranslatedText('${qty}x ${item['product_name'] ?? 'Item'}',
                                  style: const TextStyle(color: Colors.black87)),
                              LiveTranslatedText('Rs ${lineTotal.toStringAsFixed(2)}',
                                  style: const TextStyle(color: Colors.black87)),
                            ],
                          ),
                        );
                      }),
                      const Divider(color: Colors.black12, height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const LiveTranslatedText('Total Value', style: TextStyle(color: Colors.black54, fontSize: 16)),
                          LiveTranslatedText('Rs ${order['total_amount']}',
                              style: const TextStyle(
                                  color: Colors.green, fontSize: 20, fontWeight: FontWeight.bold)),
                        ],
                      ),
                      if (paymentLabel.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: LiveTranslatedText(
                            paymentLabel,
                            style: TextStyle(
                              color: paymentStatus == 'REFUND_REQUIRED' ||
                                      paymentStatus == 'REVIEW_REQUIRED'
                                  ? Colors.redAccent
                                  : paymentStatus == 'PAID'
                                      ? Colors.green.shade700
                                      : Colors.black54,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      if (effectiveAction == 'ACCEPT') ...[
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
                                child: const LiveTranslatedText('Reject'),
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
                                child: const LiveTranslatedText('Accept Order'),
                              ),
                            ),
                          ],
                        ),
                      ] else if (effectiveAction == 'DISPATCH') ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: syncing ? null : () => _updateOrderStatus(order, 'DISPATCH'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                            icon: const Icon(Icons.local_shipping_outlined, size: 18),
                            label: const LiveTranslatedText('Mark as Dispatched'),
                          ),
                        ),
                      ] else if (effectiveAction == 'DELIVER') ...[
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: syncing ? null : () => _updateOrderStatus(order, 'DELIVER'),
                            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                            icon: const Icon(Icons.check_circle_outline, size: 18),
                            label: const LiveTranslatedText('Mark as Delivered'),
                          ),
                        ),
                      ] else if (syncing) ...[
                        const SizedBox(height: 12),
                        const LiveTranslatedText('Confirming with server…', style: TextStyle(color: Colors.orange, fontSize: 12)),
                      ],
                    ],
                  ),
                ),
                );
              },
            ),
    );
  }
}