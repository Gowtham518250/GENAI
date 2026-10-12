import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api_client.dart';
import 'local_storage_service.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';

class PurchaseOrdersPage extends StatefulWidget {
  const PurchaseOrdersPage({super.key});
  @override
  State<PurchaseOrdersPage> createState() => _PurchaseOrdersPageState();
}

class _PurchaseOrdersPageState extends State<PurchaseOrdersPage> {
  bool _loading = true;
  List<dynamic> _orders = [];
  bool _reorderLoading = false;
  List<Map<String, dynamic>> _reorderSuggestions = [];
  String _reorderNotice = 'Checking products against their reorder levels…';

  static const _bg = Color(0xFF1A1A2E);
  static const _card = Color(0xFF16213E);

  @override
  void initState() {
    super.initState();
    _fetchOrders();
    _fetchReorderRecommendations();
  }

  Future<void> _fetchReorderRecommendations({bool lookupOnline = true}) async {
    if (mounted) setState(() => _reorderLoading = true);
    try {
      final res = await ApiClient.getJson(
        '/purchase-orders/reorder-recommendations?lookup_online=${lookupOnline ? 'true' : 'false'}&limit=12',
      ).timeout(const Duration(seconds: 55));
      final decoded = jsonDecode(res.body);
      if (res.statusCode == 200 && decoded is Map) {
        final rawItems = decoded['items'];
        final items = rawItems is List
            ? rawItems.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
            : <Map<String, dynamic>>[];
        if (!mounted) return;
        setState(() {
          _reorderSuggestions = items;
          _reorderNotice = (decoded['notice'] ?? '').toString();
        });
      } else {
        final detail = decoded is Map ? (decoded['detail'] ?? decoded['message'])?.toString() : null;
        if (mounted) setState(() => _reorderNotice = detail?.trim().isNotEmpty == true
            ? detail!.trim()
            : 'Could not load stock-reorder suggestions. Refresh to try again.');
      }
    } catch (e) {
      if (mounted) setState(() => _reorderNotice =
          'Stock suggestions are temporarily unavailable. Check the connection and refresh.');
      debugPrint('⚠️ Reorder recommendations unavailable: $e');
    } finally {
      if (mounted) setState(() => _reorderLoading = false);
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_fetchOrders(), _fetchReorderRecommendations()]);
  }

  double _number(dynamic value, [double fallback = 0]) =>
      value is num ? value.toDouble() : double.tryParse(value?.toString() ?? '') ?? fallback;

  String _money(dynamic value) => '₹${_number(value).toStringAsFixed(2)}';

  Future<void> _openOffer(dynamic rawUrl) async {
    final url = Uri.tryParse(rawUrl?.toString() ?? '');
    if (url == null || url.scheme != 'https' || url.host.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The seller did not provide a usable product link.')),
      );
      return;
    }
    final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
    if (!opened && mounted) ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Could not open the seller link.')),
    );
  }

  Widget _buildReorderSuggestions() {
    return Container(
      margin: const EdgeInsets.only(bottom: 22),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.indigoAccent.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.inventory_2_outlined, color: Colors.orangeAccent),
          const SizedBox(width: 9),
          Expanded(child: Text('Low-stock reorder suggestions',
              style: GoogleFonts.poppins(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold))),
          IconButton(
            tooltip: 'Refresh stock and online prices',
            onPressed: _reorderLoading ? null : () => _fetchReorderRecommendations(),
            icon: _reorderLoading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh, color: Colors.white70),
          ),
        ]),
        Text(
          'Items at or below your reorder threshold. Listed online prices are comparison hints—not confirmed wholesale quotes. Creating a PO here does not place an online order.',
          style: GoogleFonts.poppins(color: Colors.white60, fontSize: 11, height: 1.4),
        ),
        if (_reorderLoading && _reorderSuggestions.isEmpty) ...[
          const SizedBox(height: 16),
          const LinearProgressIndicator(color: Colors.indigoAccent),
        ],
        if (!_reorderLoading && _reorderSuggestions.isEmpty) ...[
          const SizedBox(height: 12),
          Text(
            _reorderNotice.contains('SERPAPI_API_KEY')
                ? 'No low-stock items were returned, or online price search needs configuration. Check inventory thresholds and backend settings.'
                : 'No products are currently at or below their configured reorder level.',
            style: GoogleFonts.poppins(color: Colors.white54, fontSize: 12),
          ),
        ],
        if (_reorderSuggestions.isNotEmpty) ...[
          const SizedBox(height: 12),
          ..._reorderSuggestions.map(_buildReorderCard),
        ],
        if (_reorderNotice.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(_reorderNotice, style: GoogleFonts.poppins(color: Colors.white38, fontSize: 10, height: 1.35)),
        ],
      ]),
    );
  }

  Widget _buildReorderCard(Map<String, dynamic> item) {
    final offers = item['online_offers'] is List
        ? (item['online_offers'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
        : <Map<String, dynamic>>[];
    final stock = _number(item['current_stock']);
    final minStock = _number(item['min_stock']);
    final triggerStock = _number(item['reorder_level']) > minStock ? _number(item['reorder_level']) : minStock;
    final suggestedQty = (_number(item['suggested_reorder_qty'], 1)).ceil().clamp(1, 1000000);
    final recordedCost = _number(item['recorded_purchase_price']);
    final bestPrice = _number(item['best_online_price'], -1);
    final urgency = (item['urgency'] ?? 'REORDER').toString().toUpperCase();
    final urgencyColor = urgency == 'CRITICAL' ? Colors.redAccent : urgency == 'HIGH' ? Colors.deepOrangeAccent : Colors.orangeAccent;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.045), borderRadius: BorderRadius.circular(13)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text((item['product_name'] ?? 'Unnamed product').toString(),
              style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13))),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: urgencyColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
            child: Text(urgency, style: GoogleFonts.poppins(color: urgencyColor, fontSize: 9, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 6),
        Text('Stock: ${stock.toStringAsFixed(stock % 1 == 0 ? 0 : 2)} • Reorder threshold: ${triggerStock.toStringAsFixed(triggerStock % 1 == 0 ? 0 : 2)} • Suggested quantity: $suggestedQty',
            style: GoogleFonts.poppins(color: Colors.white60, fontSize: 10.5, height: 1.4)),
        const SizedBox(height: 8),
        Wrap(spacing: 12, runSpacing: 5, children: [
          Text('Recorded cost ${_money(recordedCost)}', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 11)),
          if (bestPrice > 0) Text('Lowest online ${_money(bestPrice)}', style: GoogleFonts.poppins(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 11)),
          if (bestPrice > 0 && recordedCost > 0)
            Text(bestPrice < recordedCost ? '₹${(recordedCost - bestPrice).toStringAsFixed(2)} lower' : bestPrice > recordedCost ? '₹${(bestPrice - recordedCost).toStringAsFixed(2)} higher' : 'Same as recorded cost',
                style: GoogleFonts.poppins(color: bestPrice <= recordedCost ? Colors.greenAccent : Colors.orangeAccent, fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
        if (offers.isNotEmpty) ...[
          const SizedBox(height: 7),
          ...offers.take(3).map((offer) => Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Row(children: [
              Expanded(child: Text('${offer['source'] ?? 'Online seller'} · ${offer['title'] ?? item['product_name']}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(color: Colors.white54, fontSize: 10))),
              const SizedBox(width: 6),
              Text(_money(offer['price']), style: GoogleFonts.poppins(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
              TextButton(
                onPressed: () => _openOffer(offer['url']),
                style: TextButton.styleFrom(minimumSize: const Size(0, 28), padding: const EdgeInsets.symmetric(horizontal: 7), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('Open'),
              ),
            ]),
          )),
        ] else if ((item['online_lookup_message'] ?? '').toString().trim().isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(item['online_lookup_message'].toString(), style: GoogleFonts.poppins(color: Colors.white38, fontSize: 10)),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: () => _showCreatePO(suggestion: item),
            icon: const Icon(Icons.playlist_add, size: 17),
            label: Text('Draft purchase order ($suggestedQty)', style: const TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.indigoAccent, side: const BorderSide(color: Colors.indigoAccent)),
          ),
        ),
      ]),
    );
  }

  Widget _buildOrderCard(dynamic po, int i) {
    final status = (po['status'] ?? 'PENDING').toString().toUpperCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(16)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('PO #${po['id'] ?? i + 1}', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: _statusColor(status).withValues(alpha: 0.2), borderRadius: BorderRadius.circular(8)),
            child: Text(status, style: GoogleFonts.poppins(color: _statusColor(status), fontSize: 11, fontWeight: FontWeight.bold)),
          ),
        ]),
        const SizedBox(height: 8),
        Text(po['supplier_name']?.toString() ?? 'Supplier', style: GoogleFonts.poppins(color: Colors.white70)),
        Text('Rs ${po['total_cost']?.toString() ?? '0'}', style: GoogleFonts.poppins(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 18)),
        if (status == 'PENDING') ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              onPressed: () => _markDelivered(po['id']), icon: const Icon(Icons.check, size: 16), label: const Text('Delivered'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
            )),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton.icon(
              onPressed: () => _cancelPO(po['id']), icon: const Icon(Icons.close, size: 16), label: const Text('Cancel'),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            )),
          ]),
        ],
      ]),
    );
  }

  Future<void> _fetchOrders() async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> localOrders = [];

    try {
      final localPOData = prefs.getString('purchase_orders_data');
      if (localPOData != null && localPOData.isNotEmpty) {
        final d = jsonDecode(localPOData);
        final raw = d is List ? d : (d is Map && d['orders'] is List ? d['orders'] : const []);
        localOrders = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      }
    } catch (e) {
      debugPrint('⚠️ Error parsing local PO data: $e');
    }

    // Local source renders immediately, including pending offline orders.
    if (mounted) setState(() => _orders = localOrders);

    try {
      final res = await ApiClient.getJson('/purchase-orders/');
      if (res.statusCode == 200) {
        final d = jsonDecode(res.body);
        final raw = d is List ? d : (d is Map && d['orders'] is List ? d['orders'] : const []);
        final remoteOrders = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();

        // Merge by server id while preserving local records that are still
        // pending in the canonical outbox. A remote refresh must not erase an
        // offline order before the server has acknowledged it.
        final merged = <String, Map<String, dynamic>>{};
        for (final local in localOrders) {
          final key = (local['server_id'] ?? local['id'] ?? local['operation_id'] ?? '').toString();
          if (key.isNotEmpty) merged[key] = local;
        }
        for (final remote in remoteOrders) {
          final key = (remote['id'] ?? remote['server_id'] ?? remote['order_id'] ?? '').toString();
          if (key.isEmpty) continue;
          final existing = merged[key];
          if (existing != null && existing['sync_status'] == 'pending') {
            merged[key] = {...remote, ...existing, 'sync_status': 'pending'};
          } else {
            merged[key] = {...?existing, ...remote, 'sync_status': existing?['sync_status'] ?? 'synced'};
          }
        }

        final mergedList = merged.values.toList();
        await prefs.setString('purchase_orders_data', jsonEncode(mergedList));
        if (mounted) setState(() => _orders = mergedList);
      }
    } catch (e) {
      debugPrint('⚠️ Backend PO sync failed, using local data: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Color _statusColor(String status) {
    switch (status.toUpperCase()) {
      case 'DELIVERED': return Colors.greenAccent;
      case 'CANCELLED': return Colors.redAccent;
      default: return Colors.orangeAccent;
    }
  }

  Future<void> _markDelivered(dynamic poId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('purchase_orders_data');
      final list = <dynamic>[];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) list.addAll(decoded);
      }

      var changed = false;
      for (var i = 0; i < list.length; i++) {
        final value = list[i];
        if (value is! Map) continue;
        if (value['id'].toString() == poId.toString()) {
          list[i] = {...Map<String, dynamic>.from(value), 'status': 'DELIVERED', 'sync_status': 'pending'};
          changed = true;
          break;
        }
      }

      if (!changed) throw StateError('Purchase order not found locally: $poId');
      await prefs.setString('purchase_orders_data', jsonEncode(list));
      if (mounted) setState(() => _orders = list);

      await SyncQueueManager.enqueue('update_purchase_order_status', {
        'operation_id': 'PO_STATUS_${poId}_delivered',
        'po_id': poId,
        'po_action': 'mark-delivered',
      });
      unawaited(SyncService.processQueueSafe());
    } catch (e) {
      debugPrint('❌ Failed to update local PO status: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update purchase order: $e')),
        );
      }
    }
  }

  Future<void> _cancelPO(dynamic poId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('purchase_orders_data');
      final list = <dynamic>[];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) list.addAll(decoded);
      }

      var changed = false;
      for (var i = 0; i < list.length; i++) {
        final value = list[i];
        if (value is! Map) continue;
        if (value['id'].toString() == poId.toString()) {
          list[i] = {...Map<String, dynamic>.from(value), 'status': 'CANCELLED', 'sync_status': 'pending'};
          changed = true;
          break;
        }
      }

      if (!changed) throw StateError('Purchase order not found locally: $poId');
      await prefs.setString('purchase_orders_data', jsonEncode(list));
      if (mounted) setState(() => _orders = list);

      await SyncQueueManager.enqueue('update_purchase_order_status', {
        'operation_id': 'PO_STATUS_${poId}_cancelled',
        'po_id': poId,
        'po_action': 'cancel',
      });
      unawaited(SyncService.processQueueSafe());
    } catch (e) {
      debugPrint('❌ Failed to cancel PO locally: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not cancel purchase order: $e')),
        );
      }
    }
  }

  /// 🔧 FIX: previously this always sent `'items': []` — the backend's
  /// PurchaseOrderCreate schema requires `items: List[POItem]` with at
  /// least one entry (`min_length=1`), so every single "Create PO" here
  /// was rejected by the backend with a 422 the moment it tried to sync.
  /// This also durably queues the create so a flaky connection doesn't
  /// silently lose the order (matches the retry pattern used for sales).
  Future<void> _createPurchaseOrder(Map<String, dynamic> payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('purchase_orders_data');
      final list = <dynamic>[];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) list.addAll(decoded);
      }

      final operationId =
          'PO_CREATE_${DateTime.now().millisecondsSinceEpoch}';
      final localOrder = {
        ...payload,
        'id': 'LOCAL-PO-${DateTime.now().millisecondsSinceEpoch}',
        'status': 'PENDING',
        'created_at': DateTime.now().toIso8601String(),
        'sync_status': 'pending',
        'operation_id': operationId,
      };

      list.insert(0, localOrder);
      await prefs.setString('purchase_orders_data', jsonEncode(list));
      if (mounted) setState(() => _orders = list);

      await SyncQueueManager.enqueue('create_purchase_order', {
        ...payload,
        'operation_id': operationId,
        'local_id': localOrder['id'],
      });

      // Canonical local-first path: the UI is already committed. Try to
      // deliver immediately; the durable outbox remains authoritative offline.
      unawaited(SyncService.processQueueSafe());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('✅ Purchase order saved locally and queued for sync.')),
        );
      }
    } catch (e) {
      debugPrint('❌ PO local save failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save purchase order: $e')),
        );
      }
    }
  }

  void _showCreatePO({Map<String, dynamic>? suggestion}) {
    final bestOffer = suggestion?['best_offer'] is Map
        ? Map<String, dynamic>.from(suggestion!['best_offer'] as Map)
        : <String, dynamic>{};
    final suggestedCost = _number(suggestion?['best_online_price'], _number(suggestion?['recorded_purchase_price']));
    final supplierC = TextEditingController(text: (bestOffer['source'] ?? '').toString());
    final notesC = TextEditingController(text: suggestion == null
        ? ''
        : 'Draft from low-stock recommendation. Confirm pack size, seller, final price and delivery before ordering.');
    List<Map<String, dynamic>> orderItems = suggestion == null ? [] : [
      {
        'product_id': suggestion['product_id'],
        'product_name': suggestion['product_name'],
        'quantity': (_number(suggestion['suggested_reorder_qty'], 1)).ceil().clamp(1, 1000000),
        'unit_cost': suggestedCost,
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) {
          Future<void> pickProduct() async {
            final products = await LocalStorageService.loadBackendProducts();
            if (!ctx.mounted) return;
            final selected = await showDialog<Map<String, dynamic>>(
              context: ctx,
              builder: (dCtx) => AlertDialog(
                backgroundColor: _card,
                title: const Text('Select Product', style: TextStyle(color: Colors.white)),
                content: SizedBox(
                  width: double.maxFinite,
                  height: 340,
                  child: products.isEmpty
                      ? const Center(child: Text('No products in inventory yet', style: TextStyle(color: Colors.white38)))
                      : ListView.builder(
                          itemCount: products.length,
                          itemBuilder: (_, i) {
                            final p = products[i];
                            return ListTile(
                              title: Text(p['product_name']?.toString() ?? 'Unknown', style: const TextStyle(color: Colors.white)),
                              subtitle: Text('Stock: ${p['current_stock'] ?? 0}', style: const TextStyle(color: Colors.white38)),
                              onTap: () => Navigator.pop(dCtx, p),
                            );
                          },
                        ),
                ),
              ),
            );
            if (selected == null || !ctx.mounted) return;

            final qtyC = TextEditingController(text: '1');
            final costC = TextEditingController(text: (selected['price'] ?? 0).toString());
            final add = await showDialog<bool>(
              context: ctx,
              builder: (dCtx) => AlertDialog(
                backgroundColor: _card,
                title: Text(selected['product_name']?.toString() ?? 'Item', style: const TextStyle(color: Colors.white)),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  _field(qtyC, 'Quantity', numeric: true),
                  const SizedBox(height: 12),
                  _field(costC, 'Unit Cost (₹)', numeric: true),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancel')),
                  TextButton(onPressed: () => Navigator.pop(dCtx, true), child: const Text('Add')),
                ],
              ),
            );
            final qty = int.tryParse(qtyC.text.trim()) ?? 0;
            if (add == true && qty > 0) {
              setModalState(() {
                orderItems.add({
                  'product_id': selected['id'],
                  'product_name': selected['product_name'],
                  'quantity': qty,
                  'unit_cost': double.tryParse(costC.text.trim()) ?? 0.0,
                });
              });
            }
          }

          final total = orderItems.fold<double>(
            0.0,
            (sum, it) => sum + ((it['quantity'] as int) * (it['unit_cost'] as num).toDouble()),
          );

          return Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('New Purchase Order', style: GoogleFonts.poppins(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  _field(supplierC, 'Supplier Name'),
                  const SizedBox(height: 12),
                  _field(notesC, 'Notes (optional)'),
                  const SizedBox(height: 16),
                  Text('Items (at least one required)', style: GoogleFonts.poppins(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  ...orderItems.asMap().entries.map((e) {
                    final i = e.key;
                    final it = e.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(10)),
                      child: Row(children: [
                        Expanded(child: Text('${it['product_name']}', style: const TextStyle(color: Colors.white))),
                        Text('${it['quantity']} × ₹${it['unit_cost']}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline, color: Colors.redAccent, size: 20),
                          onPressed: () => setModalState(() => orderItems.removeAt(i)),
                        ),
                      ]),
                    );
                  }),
                  OutlinedButton.icon(
                    onPressed: pickProduct,
                    icon: const Icon(Icons.add, color: Colors.indigoAccent),
                    label: const Text('Add Item', style: TextStyle(color: Colors.indigoAccent)),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.indigoAccent)),
                  ),
                  const SizedBox(height: 12),
                  Text('Estimated Total: ₹${total.toStringAsFixed(2)}',
                      style: GoogleFonts.poppins(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final supplierName = supplierC.text.trim();
                        if (supplierName.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Supplier name is required')));
                          return;
                        }
                        if (orderItems.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Add at least one item')));
                          return;
                        }
                        final payload = {
                          'supplier_name': supplierName,
                          'items': orderItems,
                          if (notesC.text.trim().isNotEmpty) 'notes': notesC.text.trim(),
                        };
                        if (ctx.mounted) Navigator.pop(ctx);
                        await _createPurchaseOrder(payload);
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.indigoAccent, padding: const EdgeInsets.symmetric(vertical: 14)),
                      child: const Text('Create PO', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, {bool numeric = false}) {
    return TextField(
      controller: c,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white38),
        filled: true,
        fillColor: Colors.white10,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _card,
        title: Text('Purchase Orders', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Colors.indigoAccent,
        onPressed: _showCreatePO,
        child: const Icon(Icons.add),
      ),
      body: _loading && _orders.isEmpty
          ? const Center(child: CircularProgressIndicator(color: Colors.indigoAccent))
          : RefreshIndicator(
              onRefresh: _refreshAll,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                children: [
                  _buildReorderSuggestions(),
                  Text('Purchase Orders', style: GoogleFonts.poppins(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)),
                  const SizedBox(height: 12),
                  if (_orders.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 36),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.receipt_long, color: Colors.white24, size: 72),
                        const SizedBox(height: 12),
                        Text('No purchase orders yet', style: GoogleFonts.poppins(color: Colors.white38)),
                      ]),
                    )
                  else
                    ..._orders.asMap().entries.map((entry) => _buildOrderCard(entry.value, entry.key)),
                ],
              ),
            ),
    );
  }
}