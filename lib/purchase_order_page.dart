import 'live_translated_text.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api_client.dart';
import 'local_storage_service.dart';
import 'secure_token_storage.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';

class PurchaseOrderPage extends StatefulWidget {
  const PurchaseOrderPage({super.key});

  @override
  State<PurchaseOrderPage> createState() => _PurchaseOrderPageState();
}

class _PurchaseOrderPageState extends State<PurchaseOrderPage> {
  bool _loading = true;
  List<dynamic> _orders = [];

  @override
  void initState() {
    super.initState();
    _loadOrders();
  }

  Future<void> _loadOrders() async {
    if (!mounted) return;
    setState(() => _loading = true);

    final localOrders = await LocalStorageService.loadPurchaseOrders();
    if (!mounted) return;
    setState(() => _orders = List<dynamic>.from(localOrders));

    try {
      final token = await SecureTokenStorage.getToken() ?? '';
      if (token.isNotEmpty) {
        final response = await ApiClient.getJson(
          '/purchase-orders/',
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final data = json.decode(response.body);
          final backendOrders = data is List
              ? data
              : (data is Map && data['orders'] is List)
                  ? data['orders']
                  : const <dynamic>[];
          final parsed = List<dynamic>.from(backendOrders);
          if (!mounted) return;
          setState(() => _orders = parsed);
          await LocalStorageService.savePurchaseOrders(parsed);
        }
      }
    } catch (error) {
      // Keep cached purchase orders if the network is unavailable.
      debugPrint('Purchase-order refresh failed; keeping local data: $error');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveLocalOrder(Map<String, dynamic> order) async {
    final orders = await LocalStorageService.loadPurchaseOrders();
    orders.insert(0, order);
    await LocalStorageService.savePurchaseOrders(orders);
    setState(() => _orders = List<dynamic>.from(orders));

    // 🔧 FIX: Transform order structure to match backend expectations before syncing
    // Backend expects: supplier_name (not supplier), items with product_id/quantity/unit_cost
    final backendOrder = {
      'supplier_name': (order['supplier_name'] ?? order['supplier'] ?? '').toString().trim(),
      'expected_delivery': order['expected_delivery'],
      'items': (order['items'] as List?)?.map((item) => {
        'product_id': item['product_id'] ?? item['id'],
        'product_name': item['product_name'] ?? item['product'] ?? item['name'],
        'quantity': double.tryParse((item['quantity'] ?? item['qty'] ?? 0).toString()) ?? 0.0,
        'unit_cost': double.tryParse((item['unit_cost'] ?? item['unit_price'] ?? item['price'] ?? 0).toString()) ?? 0.0,
      }).toList(),
      'notes': order['notes'],
    };

    // Enqueue it on the same durable, auto-retrying sync queue used for sales
    await SyncQueueManager.enqueue('create_purchase_order', backendOrder);
    unawaited(SyncService.processQueueSafe());
  }

  /// Mark purchase order as received and update inventory stock
  Future<void> _receiveOrder(Map<String, dynamic> order) async {
    try {
      final items = order['items'] as List? ?? [];
      final backendProducts = await LocalStorageService.loadBackendProducts();
      final localProducts = await LocalStorageService.loadLocalProducts();
      
      // Update backend products
      for (var item in items) {
        final name = item['product_name']?.toString().toUpperCase() ?? '';
        final qty = double.tryParse(item['quantity']?.toString() ?? '0') ?? 0;
        final idx = backendProducts.indexWhere(
            (p) => p['product_name']?.toString().toUpperCase() == name);
        
        if (idx != -1) {
          backendProducts[idx]['current_stock'] = 
              (double.tryParse(backendProducts[idx]['current_stock']?.toString() ?? '0') ?? 0) + qty;
        }
      }
      
      await LocalStorageService.saveBackendProducts(backendProducts);
      
      // Update order status
      order['status'] = 'RECEIVED';
      order['received_at'] = DateTime.now().toIso8601String();
      
      // Save updated orders
      final orders = await LocalStorageService.loadPurchaseOrders();
      final idx = orders.indexWhere((o) => 
          (o['supplier'] == order['supplier'] && o['created_at'] == order['created_at']) ||
          o['id'] == order['id']);
      if (idx != -1) {
        orders[idx] = order;
        await LocalStorageService.savePurchaseOrders(orders);
      }

      // 🔧 FIX: marking an order received previously only updated local
      // storage — the backend never learned about it, so purchase orders
      // stayed "PENDING" server-side forever. Enqueue the status change
      // the same durable way sales updates are enqueued.
      await SyncQueueManager.enqueue('update_purchase_order_status', {
        'po_id': order['id'],
        'po_action': 'mark-delivered',
      });
      unawaited(SyncService.processQueueSafe());
      
      if (mounted) {
        await _loadOrders();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: LiveTranslatedText('✅ Stock updated from Purchase Order'),
            backgroundColor: Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: LiveTranslatedText('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }


  Future<void> _openSupplierListing(String? rawUrl) async {
    final uri = Uri.tryParse((rawUrl ?? '').trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('No valid online listing link is available.')),
        );
      }
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('Could not open this supplier listing.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: LiveTranslatedText('Could not open this supplier listing.')),
        );
      }
    }
  }

  Future<void> _showReorderRecommendations() async {
    final token = await SecureTokenStorage.getToken() ?? '';
    if (!mounted) return;
    if (token.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LiveTranslatedText('Sign in as a shop owner to check reorder suggestions.')),
      );
      return;
    }

    var loading = true;
    var started = false;
    String? failure;
    var notice = '';
    List<Map<String, dynamic>> suggestions = <Map<String, dynamic>>[];

    Future<void> loadSuggestions(StateSetter setDialogState, BuildContext dialogContext) async {
      setDialogState(() {
        loading = true;
        failure = null;
      });
      try {
        final response = await ApiClient.getJson(
          '/purchase-orders/reorder-recommendations?lookup_online=true&limit=12',
          headers: {'Authorization': 'Bearer $token'},
        ).timeout(const Duration(seconds: 65));
        if (response.statusCode != 200) {
          throw Exception('Request failed (' + response.statusCode.toString() + '). Please try again.');
        }
        final decoded = jsonDecode(response.body);
        final rawItems = decoded is Map ? decoded['items'] : null;
        final parsedItems = (rawItems is List ? rawItems : const <dynamic>[])
            .whereType<Map>()
            .map((entry) => Map<String, dynamic>.from(entry))
            .toList();
        if (!dialogContext.mounted) return;
        setDialogState(() {
          suggestions = parsedItems;
          notice = decoded is Map ? (decoded['notice']?.toString() ?? '') : '';
          failure = null;
          loading = false;
        });
      } catch (e) {
        if (!dialogContext.mounted) return;
        setDialogState(() {
          failure = e.toString().replaceFirst('Exception: ', '');
          loading = false;
        });
      }
    }

    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          if (!started) {
            started = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (dialogContext.mounted) loadSuggestions(setDialogState, dialogContext);
            });
          }
          return Container(
            height: MediaQuery.of(context).size.height * 0.84,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    const Icon(Icons.price_check_rounded, color: Color(0xFF4F46E5), size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LiveTranslatedText('Smart Reorder', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700)),
                          LiveTranslatedText('Low stock • online price comparison', style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh recommendations',
                      onPressed: () { loadSuggestions(setDialogState, dialogContext); },
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (notice.isNotEmpty)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: LiveTranslatedText(notice, style: GoogleFonts.poppins(fontSize: 10, color: Colors.grey.shade700)),
                  ),
                if (loading)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Column(
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 12),
                          LiveTranslatedText('Checking your stock and online listings…'),
                        ],
                      ),
                    ),
                  ),
                if (!loading && failure != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: LiveTranslatedText(failure!, style: GoogleFonts.poppins(color: Colors.red.shade700, fontSize: 12)),
                  ),
                if (!loading && failure == null && suggestions.isEmpty)
                  Expanded(
                    child: Center(
                      child: LiveTranslatedText(
                        'No low-stock products found based on your configured minimum/reorder levels.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.poppins(color: Colors.grey.shade600, fontSize: 13),
                      ),
                    ),
                  ),
                if (!loading && suggestions.isNotEmpty)
                  Expanded(
                    child: ListView.builder(
                      itemCount: suggestions.length,
                      itemBuilder: (context, index) {
                        final item = suggestions[index];
                        final productName = item['product_name']?.toString() ?? 'Product';
                        final urgency = item['urgency']?.toString() ?? 'REORDER';
                        final stock = item['current_stock']?.toString() ?? '0';
                        final qty = int.tryParse(item['suggested_reorder_qty']?.toString() ?? '') ?? 1;
                        final recordedCost = double.tryParse(item['recorded_purchase_price']?.toString() ?? '') ?? 0;
                        final best = item['best_offer'] is Map
                            ? Map<String, dynamic>.from(item['best_offer'] as Map)
                            : null;
                        final offers = (item['online_offers'] as List? ?? [])
                            .whereType<Map>()
                            .map((entry) => Map<String, dynamic>.from(entry))
                            .toList();
                        final bestPrice = double.tryParse(best?['price']?.toString() ?? '');
                        final diff = double.tryParse(item['price_difference_vs_recorded_cost']?.toString() ?? '');
                        final urgencyColor = urgency == 'CRITICAL'
                            ? const Color(0xFFDC2626)
                            : urgency == 'HIGH'
                                ? const Color(0xFFEA580C)
                                : const Color(0xFF4F46E5);

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          elevation: 0,
                          color: const Color(0xFFF8FAFC),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                            side: const BorderSide(color: Color(0xFFE2E8F0)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(13),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      child: LiveTranslatedText(productName, style: GoogleFonts.poppins(fontWeight: FontWeight.w700, fontSize: 14)),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: urgencyColor.withValues(alpha: 0.10),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: LiveTranslatedText(urgency, style: TextStyle(color: urgencyColor, fontSize: 10, fontWeight: FontWeight.w700)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                LiveTranslatedText('On hand: $stock  •  Suggested reorder: $qty',
                                  style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey.shade700)),
                                if (recordedCost > 0)
                                  LiveTranslatedText('Recorded purchase cost: ₹' + recordedCost.toStringAsFixed(2),
                                    style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade700)),
                                if (offers.isNotEmpty) ...[
                                  const SizedBox(height: 9),
                                  LiveTranslatedText('Online offers (lowest first)', style: GoogleFonts.poppins(fontWeight: FontWeight.w600, fontSize: 11)),
                                  ...offers.take(3).map((offer) {
                                    final price = double.tryParse(offer['price']?.toString() ?? '');
                                    final seller = offer['source']?.toString() ?? 'Online seller';
                                    final title = offer['title']?.toString() ?? productName;
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 5),
                                      child: Row(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                LiveTranslatedText(price == null ? seller : '₹' + price.toStringAsFixed(2) + ' • ' + seller,
                                                  style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w600)),
                                                LiveTranslatedText(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                                                  style: GoogleFonts.poppins(fontSize: 10, color: Colors.grey.shade600)),
                                              ],
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () => _openSupplierListing(offer['url']?.toString()),
                                            child: const LiveTranslatedText('Open'),
                                          ),
                                        ],
                                      ),
                                    );
                                  }),
                                  if (diff != null && recordedCost > 0)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: LiveTranslatedText(
                                        diff > 0
                                            ? 'Lowest listing is ₹' + diff.toStringAsFixed(2) + ' below your recorded purchase cost.'
                                            : diff < 0
                                                ? 'Lowest listing is ₹' + diff.abs().toStringAsFixed(2) + ' above your recorded purchase cost.'
                                                : 'Lowest listing matches your recorded purchase cost.',
                                        style: GoogleFonts.poppins(fontSize: 11, color: diff > 0 ? const Color(0xFF047857) : Colors.grey.shade700),
                                      ),
                                    ),
                                ] else
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: LiveTranslatedText(
                                      item['online_lookup_message']?.toString() ??
                                          'No priced listings found. You can still draft a purchase order.',
                                      style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey.shade600),
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                LiveTranslatedText('Confirm the exact brand/pack size, delivery charges and supplier price before ordering.',
                                  style: GoogleFonts.poppins(fontSize: 10, color: Colors.grey.shade600)),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: ElevatedButton.icon(
                                    icon: const Icon(Icons.add_shopping_cart_rounded, size: 16),
                                    label: const LiveTranslatedText('Create draft PO'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF4F46E5),
                                      foregroundColor: Colors.white,
                                    ),
                                    onPressed: () {
                                      final seller = best?['source']?.toString().trim() ?? '';
                                      final chosenPrice = bestPrice ?? (recordedCost > 0 ? recordedCost : null);
                                      final draftItem = <String, dynamic>{
                                        'product_id': item['product_id'],
                                        'product_name': productName,
                                        'quantity': qty > 0 ? qty : 1,
                                        'unit_cost': chosenPrice ?? 0.0,
                                      };
                                      Navigator.of(dialogContext).pop();
                                      WidgetsBinding.instance.addPostFrameCallback((_) {
                                        if (!mounted) return;
                                        _showCreateOrderDialog(
                                          initialItems: [draftItem],
                                          initialSupplier: seller.isEmpty ? 'Supplier to confirm' : seller,
                                          initialNotes: 'Low-stock reorder suggestion. Verify the selected listing and pack size before finalizing.',
                                        );
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showCreateOrderDialog({
    List<Map<String, dynamic>>? initialItems,
    String? initialSupplier,
    String? initialNotes,
  }) {
    final supplierController = TextEditingController(text: initialSupplier ?? '');
    final noteController = TextEditingController(text: initialNotes ?? '');
    List<Map<String, dynamic>> orderItems = (initialItems ?? const <Map<String, dynamic>>[])
        .map((item) => Map<String, dynamic>.from(item))
        .toList();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              padding: EdgeInsets.only(
                left: 24,
                right: 24,
                top: 24,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LiveTranslatedText('New Purchase Order', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: supplierController,
                    decoration: InputDecoration(
                      label: LiveTranslatedText('Supplier Name'),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteController,
                    decoration: InputDecoration(
                      label: LiveTranslatedText('Notes (optional)'),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  LiveTranslatedText('Items (at least one required)', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  ...orderItems.asMap().entries.map((entry) {
                    final index = entry.key;
                    final item = entry.value;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: LiveTranslatedText(item['product_name']?.toString() ?? 'Unknown', style: GoogleFonts.poppins(fontSize: 14)),
                          ),
                          LiveTranslatedText('Qty: ${item['quantity']}', style: GoogleFonts.poppins(fontSize: 14)),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.remove_circle, color: Colors.red),
                            onPressed: () {
                              setModalState(() {
                                orderItems.removeAt(index);
                              });
                            },
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: () async {
                      // Show product picker dialog
                      final products = await LocalStorageService.loadBackendProducts();
                      if (!mounted) return;
                      
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const LiveTranslatedText('Select Product'),
                          content: SizedBox(
                            width: double.maxFinite,
                            height: 300,
                            child: ListView.builder(
                              itemCount: products.length,
                              itemBuilder: (context, index) {
                                final product = products[index];
                                return ListTile(
                                  title: LiveTranslatedText(product['product_name']?.toString() ?? 'Unknown'),
                                  subtitle: LiveTranslatedText('Stock: ${product['current_stock'] ?? 0}'),
                                  onTap: () {
                                    Navigator.pop(context, product);
                                  },
                                );
                              },
                            ),
                          ),
                        ),
                      ).then((selectedProduct) async {
                        if (selectedProduct != null && mounted) {
                          // Show quantity dialog
                          final quantityController = TextEditingController(text: '1');
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: const LiveTranslatedText('Enter Quantity'),
                              content: TextField(
                                controller: quantityController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  label: LiveTranslatedText('Quantity'),
                                  border: OutlineInputBorder(),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const LiveTranslatedText('Cancel'),
                                ),
                                TextButton(
                                  onPressed: () {
                                    final quantity = int.tryParse(quantityController.text) ?? 1;
                                    if (quantity > 0) {
                                      setModalState(() {
                                        orderItems.add({
                                          'product_id': selectedProduct['id'],
                                          'product_name': selectedProduct['product_name'],
                                          'quantity': quantity,
                                          'unit_cost': selectedProduct['price'] ?? 0.0,
                                        });
                                      });
                                    }
                                    Navigator.pop(context);
                                  },
                                  child: const LiveTranslatedText('Add'),
                                ),
                              ],
                            ),
                          );
                        }
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const LiveTranslatedText('Add Item'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6366F1),
                    ),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        final supplierName = supplierController.text.trim();
                        if (supplierName.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: LiveTranslatedText('Supplier name is required')),
                          );
                          return;
                        }
                        if (orderItems.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: LiveTranslatedText('At least one item is required')),
                          );
                          return;
                        }

                        // 🔧 FIX: Create order with backend-compatible structure
                        final order = {
                          'id': DateTime.now().millisecondsSinceEpoch.toString(),
                          'supplier_name': supplierName, // Changed from 'supplier' to 'supplier_name'
                          'items': orderItems, // Now includes proper items array
                          'created_at': DateTime.now().toIso8601String(),
                          'status': 'PENDING',
                          'notes': noteController.text.trim(),
                          'total_cost': orderItems.fold<double>(
                            0.0,
                            (sum, item) => sum + ((item['quantity'] as int) * (item['unit_cost'] as num? ?? 0.0).toDouble()),
                          ),
                        };

                        await _saveLocalOrder(order);
                        if (mounted) Navigator.pop(context);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: LiveTranslatedText('Purchase order saved locally')),
                          );
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const LiveTranslatedText('Create Order'),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> order) {
    final amount = (order['amount'] as num?)?.toDouble() ?? double.tryParse(order['amount']?.toString() ?? '0') ?? 0.0;
    final status = order['status']?.toString().toUpperCase() ?? 'PENDING';
    final createdAt = order['created_at']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 6))],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LiveTranslatedText(order['supplier']?.toString() ?? 'Supplier', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 6),
                      LiveTranslatedText(order['notes']?.toString() ?? 'No items specified', style: GoogleFonts.poppins(fontSize: 12, color: Colors.grey[600])),
                      const SizedBox(height: 8),
                      LiveTranslatedText('Created: ${createdAt.split('T').first}', style: GoogleFonts.poppins(fontSize: 11, color: Colors.grey[500])),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    LiveTranslatedText('₹${amount.toStringAsFixed(0)}', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: status == 'RECEIVED' || status == 'COMPLETED' ? const Color(0xFF10B981).withValues(alpha: 0.12) : const Color(0xFFF59E0B).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: LiveTranslatedText(status, style: TextStyle(color: status == 'RECEIVED' || status == 'COMPLETED' ? const Color(0xFF10B981) : const Color(0xFFF59E0B), fontSize: 11, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
            if (status == 'PENDING') ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.check_circle_rounded, size: 16),
                  label: const LiveTranslatedText('Mark Received'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                  onPressed: () => _receiveOrder(order),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const LiveTranslatedText('Purchase Orders'),
        backgroundColor: const Color(0xFF6366F1),
        actions: [
          IconButton(
            tooltip: 'Find low stock and compare online prices',
            onPressed: _showReorderRecommendations,
            icon: const Icon(Icons.price_check_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadOrders,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _orders.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: LiveTranslatedText(
                        'No purchase orders yet. Tap + to create one and keep supplier orders tracked.',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.poppins(fontSize: 15, color: Colors.grey[600]),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _orders.length,
                    itemBuilder: (_, idx) => _buildOrderCard(Map<String, dynamic>.from(_orders[idx] as Map)),
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFF6366F1),
        foregroundColor: Colors.white,
        onPressed: _showCreateOrderDialog,
        child: const Icon(Icons.add_shopping_cart_rounded),
      ),
    );
  }
}