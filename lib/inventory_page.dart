import 'dart:async';
import 'cache_consistency_service.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'app_localizations.dart';
import 'package:provider/provider.dart';
import 'language_provider.dart';
import 'inventory_upload_page.dart';
import 'qr_scanner_page.dart';
import 'fmcg_barcode_service.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'inventory_management_service.dart';
import 'local_storage_service.dart';
import 'inventory_stock_helper.dart';
import 'sync_queue_manager.dart';
import 'sync_service.dart';
import 'secure_token_storage.dart';
import 'realtime_client.dart';
import 'ai_negotiation_service.dart';
import 'simple_loader.dart';
import 'package:share_plus/share_plus.dart';
import 'visual_widgets.dart';

class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});
  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> with WidgetsBindingObserver {
  // Modern SaaS Colors - synced with visual_widgets.dart
  static const Color _primary = AppColors.primary;        // #635BFF
  static const Color _warning = AppColors.warning;        // #F59E0B
  static const Color _success = AppColors.success;        // #22C55E

  bool _loading = true;
  List<dynamic> _products = [];
  int? _userId;
  // 🔧 FIX: distinguishes "backend confirmed 0 products" from "we couldn't
  // reach the backend" (e.g. slow/flaky 5G) so we never show the scary
  // "No products yet" empty-state when the real problem is just network.
  bool _lastFetchFailed = false;
  bool _realtimeConnected = false;

  // Add-product form controllers
  final _nameC = TextEditingController();
  final _barcodeC = TextEditingController();
  final _priceC = TextEditingController();
  final _mrpC = TextEditingController();
  final _stockC = TextEditingController();
  final _catC = TextEditingController();
  final _minStockC = TextEditingController(text: '10');
  final _unitC = TextEditingController(text: 'pcs');

  // Voice to Text
  late stt.SpeechToText _speech;
  bool _isListening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _speech = stt.SpeechToText();
    _init();
    InventoryManagementService.onInventoryChanged = () {
      if (mounted) _fetch(preferLocalCache: true);
    };
    _connectRealtime();
  }

  Future<void> _connectRealtime() async {
    final userId = _userId ??
        await SecureTokenStorage.getUserId();
    if (!mounted || userId == null || userId <= 0) return;

    await RealtimeClient.connect(
      userId: userId,
      shopId: userId,
      onMessage: _handleRealtimeMessage,
      onStatus: (connected, message) {
        if (mounted) setState(() => _realtimeConnected = connected);
      },
    );
  }

  Future<void> _handleRealtimeMessage(Map<String, dynamic> message) async {
    if (message['type']?.toString() != 'inventory.changed') return;

    final changes = <Map<String, dynamic>>[];
    final rawChanges = message['changes'];

    if (rawChanges is List) {
      for (final raw in rawChanges) {
        if (raw is Map) {
          changes.add(Map<String, dynamic>.from(raw));
        }
      }
    } else if (message['product_id'] != null &&
        message['new_stock'] != null) {
      changes.add({
        'product_id': message['product_id'],
        'new_stock': message['new_stock'],
      });
    }

    if (changes.isEmpty) return;

    final updatedProducts = <dynamic>[];
    final changedIds = <String>{};

    for (final product in _products) {
      if (product is! Map) {
        updatedProducts.add(product);
        continue;
      }

      final copy = Map<String, dynamic>.from(product);
      final productId = copy['id']?.toString();
      if (productId == null || productId.isEmpty) {
        updatedProducts.add(product);
        continue;
      }

      Map<String, dynamic>? change;
      for (final candidate in changes) {
        if (candidate['product_id']?.toString() == productId) {
          change = candidate;
          break;
        }
      }

      if (change == null) {
        updatedProducts.add(product);
        continue;
      }

      final newStock = _asStockNumber(change['new_stock']);
      if (newStock == null) {
        updatedProducts.add(product);
        continue;
      }

      final remoteSnapshot = <String, dynamic>{
        'id': productId,
        'product_id': productId,
        'stock': newStock,
        'current_stock': newStock,
        'quantity': newStock,
        if (change['updated_at'] != null) 'updated_at': change['updated_at'],
        if (change['server_updated_at'] != null) 'server_updated_at': change['server_updated_at'],
      };
      final reconciled = CacheConsistencyService.mergeRecord(
        copy,
        remoteSnapshot,
        dataset: 'inventory',
      );
      changedIds.add(productId);
      updatedProducts.add(
        InventoryStockHelper.normalizeProduct(reconciled),
      );
    }

    final missingProduct = changes.any((change) {
      final productId = change['product_id']?.toString();
      return productId != null && !changedIds.contains(productId);
    });

    if (mounted && changedIds.isNotEmpty) {
      setState(() => _products = updatedProducts);
    }

    // Keep the local backend-product cache aligned with server-authoritative
    // stock so the next offline screen render starts from the latest value.
    try {
      final backendProducts =
          await LocalStorageService.loadBackendProducts();
      var cacheChanged = false;

      for (final change in changes) {
        final productId = change['product_id']?.toString();
        final newStock = _asStockNumber(change['new_stock']);
        if (productId == null || newStock == null) continue;

        for (var i = 0; i < backendProducts.length; i++) {
          final product = backendProducts[i];
          if (product['id']?.toString() != productId) continue;
          final remoteSnapshot = <String, dynamic>{
            'id': productId,
            'product_id': productId,
            'stock': newStock,
            'current_stock': newStock,
            'quantity': newStock,
            if (change['updated_at'] != null) 'updated_at': change['updated_at'],
            if (change['server_updated_at'] != null) 'server_updated_at': change['server_updated_at'],
          };
          backendProducts[i] = InventoryStockHelper.normalizeProduct(
            CacheConsistencyService.mergeRecord(
              Map<String, dynamic>.from(product),
              remoteSnapshot,
              dataset: 'inventory',
            ),
          );
          cacheChanged = true;
          break;
        }
      }

      if (cacheChanged) {
        await LocalStorageService.saveBackendProducts(backendProducts);
        await CacheConsistencyService.markRemoteRefresh('inventory', recordCount: backendProducts.length);
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint(
          '⚠️ Failed to persist realtime inventory cache: $e',
        );
      }
    }

    // A realtime event for an unloaded product usually means the current
    // filtered list is stale. Reconcile from the API once.
    if (missingProduct && mounted) {
      await _fetch(forceRemote: true);
    }
  }

  double? _asStockNumber(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RealtimeClient.disconnect();
    _nameC.dispose(); _barcodeC.dispose(); _priceC.dispose(); _mrpC.dispose();
    _stockC.dispose(); _catC.dispose(); _minStockC.dispose(); _unitC.dispose();
    InventoryManagementService.onInventoryChanged = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && _userId != null) {
      // Restore the cached inventory immediately, then refresh from cloud.
      _fetch(forceRemote: true);
    }
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getInt('user_id') ?? prefs.getInt('userId');
    if (_userId != null) {
      await _fetch();
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _fetch({bool preferLocalCache = false, bool forceRemote = false}) async {
    setState(() { _loading = true; });
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = await SecureTokenStorage.getToken() ?? '';

      // 1. Load Local Offline Products
      final Map<String, dynamic> localMap = await LocalStorageService.loadLocalProducts();
      final List<Map<String, dynamic>> localOfflineProducts = localMap.entries.map((e) {
        final Map<String, dynamic> data = Map<String, dynamic>.from(e.value as Map);
        data['id'] = e.key; // Assign dummy ID for UI keying
        data['is_offline'] = true; // Flag for UI if needed
        if (data['is_deleted'] == true) return null;
        return data;
      }).whereType<Map<String, dynamic>>().toList();

      // 2. Load Cached Backend Products
      final cachedBackend = await LocalStorageService.loadBackendProducts();
      
      // 3. Show both immediately (offline items at the top)
      if (cachedBackend.isNotEmpty || localOfflineProducts.isNotEmpty) {
        if (!mounted) return;
        setState(() {
          _products = [...localOfflineProducts, ...cachedBackend];
          _loading = false;
        });
        if (kDebugMode) debugPrint('💾 Inventory UI: ${cachedBackend.length} backend, ${localOfflineProducts.length} offline products');
      }

      if (preferLocalCache) return;

      // Fresh read cache is sufficient for ordinary navigation. Explicit
      // refresh/resume bypasses the TTL so another device's edits converge.
      final cacheFresh = await CacheConsistencyService.isFresh(
        'inventory',
        maxAge: const Duration(seconds: 30),
      );
      if (cacheFresh && !forceRemote) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      // Merge API data
      if (_userId != null && token.isNotEmpty) {
        // 4. Promote legacy local-only products into the canonical outbox.
        // They remain in local storage until the SyncEngine receives a server ACK.
        if (localMap.isNotEmpty && _userId != null) {
          for (final entry in localMap.entries) {
            await SyncQueueManager.enqueue('create_local_product', {
              'operation_id': 'PRODUCT_CREATE_${entry.key}',
              'user_id': _userId,
              'payload': Map<String, dynamic>.from(entry.value as Map),
            });
          }
          unawaited(SyncService.processQueueSafe());
        }

        try {
          if (kDebugMode) debugPrint('📡 Merging inventory from backend...');
          // 🔧 FIX: on slow/high-latency connections (common on 5G with poor
          // signal) a single 10s attempt was too aggressive and left the
          // screen stuck showing nothing. Try a fast attempt first, then
          // fall back to one longer-timeout retry before giving up.
          http.Response? res;
          for (final attemptTimeout in const [Duration(seconds: 10), Duration(seconds: 25)]) {
            try {
              res = await ApiClient.getJson(
                '${ApiClient.inventoryPrefix}/products',
                headers: {'Authorization': 'Bearer $token'},
              ).timeout(attemptTimeout);
              break; // got a response, stop retrying
            } catch (e) {
              if (kDebugMode) debugPrint('⚠️ Inventory fetch attempt failed ($attemptTimeout): $e');
              // try again with the longer timeout unless this was already the last attempt
            }
          }
          if (res != null && res.statusCode == 200) {
            final decoded = json.decode(res.body);
            final productsData = decoded is List
                ? decoded
                : (decoded is Map && decoded['products'] is List)
                    ? decoded['products']
                    : <dynamic>[];

            final apiProducts = productsData
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList();

            // Never interpret an empty successful response as inventory
            // deletion when we already have a durable non-empty cache.
            final effectiveApiProducts =
                apiProducts.isEmpty && cachedBackend.isNotEmpty
                    ? cachedBackend
                    : apiProducts;

            final merged = InventoryStockHelper.mergeApiWithLocalCache(
              effectiveApiProducts,
              cachedBackend,
            );

            if (merged.isNotEmpty || apiProducts.isEmpty) {
              await LocalStorageService.saveBackendProducts(merged);
            }
            await CacheConsistencyService.markRemoteRefresh('inventory', recordCount: merged.length);

            if (!mounted) return;
            setState(() {
              _products = [...localOfflineProducts, ...merged];
              _loading = false;
              _lastFetchFailed = false;
            });

            if (kDebugMode) {
              debugPrint(
                '✅ Inventory merged: ${merged.length} products '
                '(API=${apiProducts.length}, cache=${cachedBackend.length})',
              );
            }
            return;

          } else if (res == null) {
            // Both attempts failed — this is a network problem, not an
            // empty catalog. Keep whatever cache we already loaded and
            // flag it so the UI doesn't say "No products yet".
            _lastFetchFailed = true;
          }
        } catch (e) {
          if (kDebugMode) debugPrint('⚠️ Backend fetch failed: $e — keeping cache');
          _lastFetchFailed = true;
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error in _fetch: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not refresh products — showing last known list ($e)'),
          backgroundColor: Colors.red,
        ),
      );
      // 🔧 FIX: previously this cleared `_products` to [] here, which made
      // a transient read/network error look like the products had been
      // deleted. Nothing was actually lost — just keep showing whatever
      // list was already on screen and flag it as a failed refresh.
      _lastFetchFailed = true;
    }
    if (!mounted) return;
    setState(() { _loading = false; });
  }

  void _updateStock(Map<String, dynamic> p, double delta) {
    final idx = _products.indexWhere((x) => x['id'].toString() == p['id'].toString());
    if (idx != -1) {
      final updated = Map<String, dynamic>.from(_products[idx] as Map);
      final current = InventoryStockHelper.readStock(updated);
      InventoryStockHelper.writeStock(updated, current + delta);
      _products[idx] = updated;
      setState(() {}); // Update UI first
      _saveLocal(p['id'].toString(), updated); // Then save async (outside setState)
      // 🔧 FIX: _updateLocalProductItem (sync_service.dart) reads
      // data['id'] / data['user_id'] / data['payload'] — passing `updated`
      // directly here meant every field it read was null, so the PUT it
      // issued on retry was always '/products/null?user_id=null' with a
      // null body and permanently failed. Wrap it in the shape the
      // processor actually expects, matching the working call site in
      // inventory_management_service.dart.
      if (_userId != null) {
        SyncQueueManager.enqueue('update_local_product', {
          'id': p['id'],
          'user_id': _userId,
          'payload': updated,
        });
      }
    }
  }

  Future<void> _saveLocal(String id, Map<String, dynamic> data) async {
    try {
      final local = await LocalStorageService.loadLocalProducts();
      data['sync_status'] = 'pending';
      data['local_updated_at'] = DateTime.now().toUtc().toIso8601String();
      local[id] = data;
      await LocalStorageService.saveLocalProducts(local);
      await CacheConsistencyService.markLocalMutation('inventory', operationId: id);
    } catch (e) {
      if (kDebugMode) debugPrint('Error saving locally: $e');
    }
  }

  Future<void> _addProduct() async {
    if (_nameC.text.isEmpty || _priceC.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Product Name and Price are required')));
      return;
    }

    final productData = {
      'product_name': _nameC.text.trim(),
      'sku': (_barcodeC.text.trim().isNotEmpty ? _barcodeC.text.trim() : _nameC.text.trim()).toLowerCase(),
      'unit_price': double.tryParse(_priceC.text) ?? 0,
      'mrp': double.tryParse(_mrpC.text) ?? 0,
      'current_stock': int.tryParse(_stockC.text) ?? 0,
      'min_stock': int.tryParse(_minStockC.text) ?? 10,
      'category': _catC.text.trim().isNotEmpty ? _catC.text.trim() : 'General',
      'unit': _unitC.text.trim().isNotEmpty ? _unitC.text.trim() : 'pcs',
    };

    try {
      // Local-first: durable local state changes before any network work.
      final local = await LocalStorageService.loadLocalProducts();
      final sku = productData['sku'].toString();
      local[sku] = productData;
      productData['sync_status'] = 'pending';
      productData['local_updated_at'] = DateTime.now().toUtc().toIso8601String();
      await LocalStorageService.saveLocalProducts(local);
      await CacheConsistencyService.markLocalMutation('inventory', operationId: 'PRODUCT_CREATE_$sku');

      if (_userId != null) {
        await SyncQueueManager.enqueue('create_local_product', {
          'operation_id': 'PRODUCT_CREATE_$sku',
          'user_id': _userId,
          'payload': productData,
        });
      }

      if (!mounted) return;
      Navigator.pop(context);
      _nameC.clear(); _barcodeC.clear(); _priceC.clear(); _mrpC.clear();
      _stockC.clear(); _catC.clear(); _minStockC.text = '10'; _unitC.text = 'pcs';
      await _fetch();

      // Flush the canonical outbox immediately when online. The operation
      // remains durable if the device is offline or the request fails.
      unawaited(SyncService.processQueueSafe());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Product saved on this device and queued for sync'),
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Error adding product: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  bool _isAddingProduct = false;

  void _showAddDialog() {
    _isAddingProduct = false; // reset in case a previous sheet left it stuck
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(builder: (_, ss) {
        return Container(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 4, height: 28, color: _primary,
                    margin: const EdgeInsets.only(right: 12)),
                Text('Add New Product',
                    style: GoogleFonts.poppins(
                        fontSize: 18, fontWeight: FontWeight.w700)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context)),
              ]),
              const SizedBox(height: 16),
              
              // VOICE ADD + PRODUCT NAME
              Row(
                children: [
                  Expanded(child: _field(_nameC, 'Product Name *', Icons.inventory_2)),
                  const SizedBox(width: 8),
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: InkWell(
                      onTap: () async {
                        if (!_isListening) {
                          bool available = await _speech.initialize();
                          if (available) {
                            ss(() => _isListening = true);
                            _speech.listen(
                              onResult: (val) => ss(() => _nameC.text = val.recognizedWords),
                            );
                          }
                        } else {
                          ss(() => _isListening = false);
                          _speech.stop();
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _isListening ? Colors.red.withValues(alpha: 0.1) : _primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _isListening ? Colors.red.withValues(alpha: 0.3) : _primary.withValues(alpha: 0.3)),
                        ),
                        child: Icon(
                          _isListening ? Icons.mic : Icons.mic_none, 
                          color: _isListening ? Colors.red : _primary
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              
              // BARCODE FIELD WITH SCANNER
              Row(
                children: [
                  Expanded(child: _field(_barcodeC, 'Barcode (Optional)', Icons.qr_code)),
                  const SizedBox(width: 8),
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: InkWell(
                      onTap: () async {
                        final code = await Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => const QrScannerPage()),
                        );
                        if (code != null && mounted) {
                          ss(() {
                            _barcodeC.text = code;
                          });
                          
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('⏳ Searching Global CDN...'), duration: Duration(milliseconds: 700)),
                          );

                          final prefs = await SharedPreferences.getInstance();
                          final stateCode = prefs.getString('shop_state') ?? 'MH';
                          
                          final magicProduct = await FmcgBarcodeService.fetchProductFromCdn(
                            code,
                            stateCode,
                          );

                          if (magicProduct != null && mounted) {
                            ss(() {
                              _nameC.text = magicProduct.name;
                              if ((magicProduct.category ?? '').trim().isNotEmpty) {
                                _catC.text = magicProduct.category!.split('>').first.trim();
                              }
                            });
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  '✅ Product found: ' +
                                      magicProduct.name +
                                      '. Verify the selling price and MRP.',
                                ),
                                backgroundColor: _success,
                              ),
                            );
                          } else if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Barcode ' +
                                      code +
                                      ' was not matched to a real catalog item. '
                                      'Enter the product name manually.',
                                ),
                                backgroundColor: _warning,
                              ),
                            );
                          }
                        }
                      },
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _primary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _primary.withValues(alpha: 0.3)),
                        ),
                        child: const Icon(Icons.qr_code_scanner_rounded, color: _primary),
                      ),
                    ),
                  ),
                ],
              ),

              _field(_priceC, 'Unit Price (₹) *', Icons.currency_rupee,
                  type: TextInputType.number),
              _field(_mrpC, 'MRP - Declared (₹) [GST Compliance]', Icons.verified_user,
                  type: TextInputType.number),
              _field(_stockC, 'Current Stock', Icons.numbers,
                  type: TextInputType.number),
              _field(_minStockC, 'Min Stock Alert', Icons.warning_amber,
                  type: TextInputType.number),
              _field(_catC, 'Category', Icons.category),
              DropdownButtonFormField<String>(
                value: _unitC.text.isEmpty ? 'pcs' : _unitC.text,
                decoration: InputDecoration(
                  labelText: 'Unit of Measure',
                  prefixIcon: Icon(Icons.scale_rounded, color: _primary, size: 20),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.grey.shade300)),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _primary, width: 2)),
                  filled: true, fillColor: Colors.grey.shade50,
                ),
                items: ['pcs', 'kg', 'g', 'litre', 'ml', 'dozen', 'box', 'pack']
                    .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                    .toList(),
                onChanged: (v) => _unitC.text = v ?? 'pcs',
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  // 🔧 FIX: this button previously had no loading state at
                  // all — tapping it while the backend POST (up to a 10s
                  // timeout) was in flight gave no feedback and allowed a
                  // double-tap to fire two create requests. Now disables
                  // itself and shows a simple spinner for the duration of
                  // _addProduct(), using the bottom sheet's own
                  // StatefulBuilder so it doesn't interfere with the
                  // Navigator.pop() calls _addProduct() already does.
                  onPressed: _isAddingProduct
                      ? null
                      : () async {
                          ss(() => _isAddingProduct = true);
                          try {
                            await _addProduct();
                          } finally {
                            // _addProduct() closes this sheet itself on
                            // success/offline-fallback, but returns early
                            // (without closing it) on validation failure —
                            // in that case we still need to re-enable the
                            // button. Guard with try/catch since calling ss()
                            // after the sheet has already been popped would
                            // throw ("setState called after dispose").
                            _isAddingProduct = false;
                            try {
                              ss(() {});
                            } catch (_) {}
                          }
                        },
                  child: _isAddingProduct
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: Colors.white,
                          ),
                        )
                      : Text('Add Product',
                          style: GoogleFonts.poppins(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 12),
            ]),
          ),
        );
      }),
    );
  }

  Widget _field(TextEditingController c, String label, IconData icon,
      {TextInputType type = TextInputType.text}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: type,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: _primary, size: 20),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: _primary, width: 2)),
          filled: true, fillColor: Colors.grey.shade50,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final lowStock = _products.where((p) =>
        (p['current_stock'] as num) <= (p['min_stock'] as num)).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).inventory, style: GoogleFonts.poppins(
            fontWeight: FontWeight.w700, color: Colors.white)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            tooltip: 'Bulk Upload',
            icon: const Icon(Icons.upload_file_rounded),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const InventoryUploadPage()),
              );
            },
          ),
          IconButton(
            tooltip: 'Scan to Find',
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () async {
              final code = await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const QrScannerPage()),
              );
              if (code != null && mounted) {
                // Check if it's in local inventory first
                bool foundLocal = false;
                setState(() {
                  final filtered = _products.where((p) => p['sku'].toString() == code).toList();
                  if (filtered.isNotEmpty) {
                     _products = filtered;
                     foundLocal = true;
                  }
                });
                
                if (foundLocal) {
                   ScaffoldMessenger.of(context).showSnackBar(
                     const SnackBar(content: Text('✅ Product found in local inventory!'), backgroundColor: Colors.green),
                   );
                   return;
                }

                // If not found locally, suggest adding it via Global CDN!
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Product not found locally. Querying Global CDN for $code...')),
                );
                
                final prefs = await SharedPreferences.getInstance();
                final stateCode = prefs.getString('shop_state') ?? 'MH';
                final magicProduct = await FmcgBarcodeService.fetchProductFromCdn(code, stateCode);

                if (magicProduct != null && mounted) {
                   _showAddDialog(); // Open the dialog to add
                   Future.delayed(const Duration(milliseconds: 300), () {
                     _barcodeC.text = magicProduct.barcode;
                     _nameC.text = magicProduct.name;
                     _priceC.text = magicProduct.adjustedPrice.toString();
                   });
                   ScaffoldMessenger.of(context).showSnackBar(
                     SnackBar(content: Text('✨ Auto-filled ${magicProduct.name} from CDN!'), backgroundColor: Colors.green),
                   );
                } else if (mounted) {
                   _fetch(); // Reset view
                   ScaffoldMessenger.of(context).showSnackBar(
                     const SnackBar(content: Text('❌ Not found in Local Inventory or Global CDN.'), backgroundColor: Colors.red),
                   );
                }
              }
            },
          ),
          _buildLanguageSwitcher(),
          IconButton(icon: const Icon(Icons.refresh),
              onPressed: () => _fetch(forceRemote: true)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _products.isEmpty ? _emptyState() : _buildList(lowStock),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: Text(AppLocalizations.of(context).addProduct,
            style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 34, 28, 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 126,
              height: 126,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    _primary.withValues(alpha: 0.12),
                    _primary.withValues(alpha: 0.05),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.inventory_2_outlined, size: 62, color: _primary),
            ),
            const SizedBox(height: 22),
            Text(
              'Your inventory is empty',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 23,
                fontWeight: FontWeight.w700,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Add your first product and it will appear here instantly.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                fontSize: 13,
                color: Colors.grey.shade600,
              ),
            ),
            if (_lastFetchFailed) ...[
              const SizedBox(height: 16),
              Container(
                constraints: const BoxConstraints(maxWidth: 430),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Colors.orange.withValues(alpha: 0.22)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off_rounded, size: 18, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'The server could not be refreshed just now. Your local data is untouched. Retry to sync again.',
                        style: GoogleFonts.poppins(
                          fontSize: 11,
                          color: Colors.brown,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                onPressed: () => _fetch(forceRemote: true),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry Sync'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _primary,
                  side: BorderSide(color: _primary.withValues(alpha: 0.35)),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                ),
              ),
            ],
            const SizedBox(height: 26),
            Container(
              constraints: const BoxConstraints(maxWidth: 460),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
                border: Border.all(color: Colors.grey.withValues(alpha: 0.08)),
              ),
              child: Column(
                children: [
                  _guideStep('1', 'Tap + Add Product', Icons.add_circle_outline),
                  _guideStep('2', 'Enter name, price and stock', Icons.edit_outlined),
                  _guideStep('3', 'Your product syncs to the server', Icons.cloud_done_outlined),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _guideStep(String num, String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        Container(
          width: 32, height: 32,
          decoration: BoxDecoration(color: _primary, shape: BoxShape.circle),
          child: Center(child: Text(num,
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.bold))),
        ),
        const SizedBox(width: 12),
        Icon(icon, size: 20, color: _primary),
        const SizedBox(width: 8),
        Text(text, style: GoogleFonts.poppins(fontSize: 13,
            color: Colors.grey.shade700)),
      ]),
    );
  }

  Widget _buildList(int lowStock) {
    return Column(children: [
      // Stats bar
      Container(
        color: _primary,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Row(children: [
          _statChip('Total', '${_products.length}', Icons.inventory_2),
          const SizedBox(width: 12),
          _statChip('Low Stock', '$lowStock', Icons.warning_amber,
              color: lowStock > 0 ? _warning : _success),
        ]),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _products.length,
          itemBuilder: (_, i) => _productCard(_products[i]),
        ),
      ),
    ]);
  }

  Widget _statChip(String label, String val, IconData icon,
      {Color color = Colors.white}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(val, style: GoogleFonts.poppins(
              fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
          Text(label, style: GoogleFonts.poppins(
              fontSize: 10, color: Colors.white70)),
        ]),
      ]),
    );
  }

  Widget _productCard(Map<String, dynamic> p) {
    final isLow = (p['current_stock'] as num) <= (p['min_stock'] as num);
    final isOut = (p['current_stock'] as num) == 0;
    final statusColor = isOut ? Colors.red : (isLow ? _warning : _success);
    final statusText = isOut ? 'OUT' : (isLow ? 'LOW' : 'OK');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: isLow ? Border.all(color: statusColor.withValues(alpha: 0.5)) : null,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          // ✨ Enhanced Stock Status Icon with Animation
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 50, height: 50,
            decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: statusColor.withValues(alpha: 0.3), width: 2)),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Icon(Icons.inventory_2, color: statusColor, size: 24),
                // ✨ Pulse animation for low stock
                if (isLow)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['product_name'] ?? ''}',
                style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w600, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Text('${p['sku'] != null && p['sku'].toString().isNotEmpty ? 'Barcode: ${p['sku']} · ' : ''}${p['category'] ?? 'General'}',
                style: GoogleFonts.poppins(
                    fontSize: 12, color: Colors.grey.shade500),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            Text('\u20b9${p['unit_price'] ?? 0}',
                style: GoogleFonts.poppins(
                    fontSize: 12, color: _primary,
                    fontWeight: FontWeight.w600)),
          ])),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            // ✨ Enhanced Status Badge with Animation
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: statusColor.withValues(alpha: 0.4), width: 1.5)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Status Icon
                  Icon(
                    isOut ? Icons.block : isLow ? Icons.warning_amber_rounded : Icons.check_circle_rounded,
                    size: 12,
                    color: statusColor,
                  ),
                  const SizedBox(width: 4),
                  Text(statusText, style: GoogleFonts.poppins(
                      fontSize: 11, fontWeight: FontWeight.bold,
                      color: statusColor)),
                ],
              ),
            ),
            const SizedBox(height: 6),
            // ✨ Animated Stock Count
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 300),
              style: GoogleFonts.poppins(
                  fontSize: 24, fontWeight: FontWeight.w700,
                  color: statusColor),
              child: Text('${p['current_stock']}'),
            ),
            Text('${p['unit'] ?? 'pcs'}',
                style: GoogleFonts.poppins(
                    fontSize: 10, color: Colors.grey.shade400)),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: () => _showEditDialog(p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.edit_rounded, size: 16, color: _primary),
                  ),
                ),
                const SizedBox(width: 6),
                if (isLow)
                GestureDetector(
                  onTap: () async {
                    // Show a quick loading toast/snackbar
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('🤖 AI is thinking... generating negotiation message.')));
                    
                    final msg = await AiNegotiationService.generateNegotiationMessage(
                      productName: p['product_name'] ?? 'Product',
                      currentStock: (p['current_stock'] as num).toDouble(),
                      minStock: (p['min_stock'] as num).toDouble(),
                      unitPrice: (p['unit_price'] as num).toDouble(),
                      category: p['category'] ?? 'Retail',
                    );

                    if (mounted) {
                      Share.share(msg, subject: 'Negotiation for ${p['product_name']}');
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                    ),
                    child: const Icon(Icons.auto_awesome_rounded, size: 16, color: Colors.blueAccent),
                  ),
                ),
                GestureDetector(
                  onTap: () => _confirmDelete(p),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent),
                  ),
                ),
              ],
            ),
          ]),
        ]),
      ),
    );
  }

  void _confirmDelete(Map<String, dynamic> p) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete Product?', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
        content: Text('Are you sure you want to remove "${p['product_name']}" from inventory?',
            style: GoogleFonts.poppins(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: GoogleFonts.poppins())),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: () async {
              Navigator.pop(context);
              // 🔧 FIX: give the user feedback while the delete request
              // (backend call + local cache update) is in flight instead of
              // no visual response at all.
              await SimpleLoader.run(context, 'Deleting product...', () {
                return _deleteProduct(p);
              });
            },
            child: Text('Delete', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  int? _resolveBackendProductId(
    Map<String, dynamic> product, {
    List<Map<String, dynamic>>? cachedProducts,
  }) {
    final candidates = <dynamic>[
      product['id'],
      product['product_id'],
      product['backend_id'],
      product['server_id'],
    ];

    for (final value in candidates) {
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null && parsed > 0) return parsed;
    }

    // A stale cache may contain the server row under the same SKU/name.
    final cache = cachedProducts ?? const <Map<String, dynamic>>[];
    final sku = product['sku']?.toString().trim().toLowerCase() ?? '';
    final name = product['product_name']?.toString().trim().toLowerCase() ?? '';

    for (final candidate in cache) {
      final candidateSku =
          candidate['sku']?.toString().trim().toLowerCase() ?? '';
      final candidateName =
          candidate['product_name']?.toString().trim().toLowerCase() ?? '';

      final sameSku = sku.isNotEmpty && candidateSku == sku;
      final sameName = name.isNotEmpty && candidateName == name;
      if (!sameSku && !sameName) continue;

      for (final value in <dynamic>[
        candidate['id'],
        candidate['product_id'],
        candidate['backend_id'],
        candidate['server_id'],
      ]) {
        final parsed = int.tryParse(value?.toString() ?? '');
        if (parsed != null && parsed > 0) return parsed;
      }
    }

    return null;
  }

  Future<void> _deleteUnsyncedLocalProduct(
    Map<String, dynamic> product,
  ) async {
    final localProducts = await LocalStorageService.loadLocalProducts();

    final identityCandidates = <String>{
      product['id']?.toString() ?? '',
      product['sku']?.toString() ?? '',
      product['barcode']?.toString() ?? '',
      product['product_name']?.toString() ?? '',
    }..removeWhere((value) => value.trim().isEmpty);

    localProducts.removeWhere((key, value) {
      if (identityCandidates.contains(key.toString())) return true;
      if (value is! Map) return false;

      final map = Map<String, dynamic>.from(value);
      return identityCandidates.contains(map['id']?.toString()) ||
          identityCandidates.contains(map['sku']?.toString()) ||
          identityCandidates.contains(map['barcode']?.toString()) ||
          identityCandidates.contains(map['product_name']?.toString());
    });

    await LocalStorageService.saveLocalProducts(localProducts);

    // Cancel the pending CREATE so deleting an unsynced product cannot make
    // it reappear on the next outbox retry.
    final operationId = product['operation_id']?.toString().isNotEmpty == true
        ? product['operation_id'].toString()
        : 'PRODUCT_CREATE_${product['id'] ?? product['sku'] ?? product['product_name']}';
    await SyncQueueManager.removeByBusinessIdentifier(
      'create_local_product',
      {'operation_id': operationId},
    );

    if (!mounted) return;
    setState(() {
      _products.removeWhere((item) {
        if (identityCandidates.contains(item['id']?.toString() ?? '')) {
          return true;
        }
        if (identityCandidates.contains(item['sku']?.toString() ?? '')) {
          return true;
        }
        return identityCandidates.contains(
          item['product_name']?.toString() ?? '',
        );
      });
    });
  }

  Future<void> _deleteProduct(Map<String, dynamic> p) async {
    final cached = await LocalStorageService.loadBackendProducts();
    final productId = _resolveBackendProductId(
      p,
      cachedProducts: cached,
    );

    if (productId == null) {
      final isUnsyncedLocal = p['is_offline'] == true ||
          p['sync_status']?.toString().toLowerCase() == 'pending' ||
          p['sync_status']?.toString().toLowerCase() == 'local';

      if (isUnsyncedLocal) {
        try {
          await _deleteUnsyncedLocalProduct(p);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('✅ Local product removed. It was not synced to the backend yet.'),
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not remove local product: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
        return;
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'This product has no valid server ID. Refresh inventory and try again.',
            ),
          ),
        );
      }
      return;
    }

    try {
      // Remove only after the server operation is queued. For an online
      // account the durable outbox remains the source of retry truth.
      final operationId = 'PRODUCT_DELETE_${_userId ?? 0}_$productId';
      final queued = _userId == null
          ? false
          : await SyncQueueManager.enqueue(
              'delete_product',
              {
                'operation_id': operationId,
                'id': productId,
                'product_id': productId,
                'user_id': _userId,
              },
            );

      if (!queued && _userId != null) {
        throw StateError('Could not queue product deletion');
      }

      final localProducts = await LocalStorageService.loadLocalProducts();
      localProducts['__deleted_$productId'] = {
        'id': productId,
        'product_id': productId,
        'is_deleted': true,
        'sync_status': 'pending',
        'local_updated_at': DateTime.now().toUtc().toIso8601String(),
        'operation_id': operationId,
      };
      await LocalStorageService.saveLocalProducts(localProducts);

      final cachedAfterQueue = await LocalStorageService.loadBackendProducts();
      cachedAfterQueue.removeWhere((item) {
        final id = _resolveBackendProductId(item);
        return id == productId;
      });
      await LocalStorageService.saveBackendProducts(cachedAfterQueue);

      if (mounted) {
        setState(() {
          _products.removeWhere((item) {
            return _resolveBackendProductId(item) == productId;
          });
        });
      }

      // Try immediately; the durable queue remains if the network is down.
      unawaited(SyncService.processQueueSafe());

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Product deletion queued and syncing.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Delete failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }


  void _showEditDialog(Map<String, dynamic> p) {
    final nameC = TextEditingController(text: p['product_name']?.toString() ?? '');
    final priceC = TextEditingController(text: p['unit_price']?.toString() ?? '');
    final stockC = TextEditingController(text: p['current_stock']?.toString() ?? '');
    final minC = TextEditingController(text: p['min_stock']?.toString() ?? '10');
    final catC = TextEditingController(text: p['category']?.toString() ?? '');

    bool isSaving = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => StatefulBuilder(builder: (_, ss) => Container(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 4, height: 28, color: _primary, margin: const EdgeInsets.only(right: 12)),
              Text('Edit Product', style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
            const SizedBox(height: 16),
            _field(nameC, 'Product Name *', Icons.inventory_2),
            _field(priceC, 'Unit Price (\u20b9) *', Icons.currency_rupee, type: TextInputType.number),
            _field(stockC, 'Current Stock', Icons.numbers, type: TextInputType.number),
            _field(minC, 'Min Stock Alert', Icons.warning_amber, type: TextInputType.number),
            _field(catC, 'Category', Icons.category),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary, foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: isSaving
                    ? null
                    : () async {
                  ss(() => isSaving = true);
                  try {
                    final updated = Map<String, dynamic>.from(p);
                    updated['product_name'] = nameC.text.trim();
                    updated['unit_price'] = double.tryParse(priceC.text) ?? updated['unit_price'];
                    final newStock = double.tryParse(stockC.text) ??
                        InventoryStockHelper.readStock(updated);
                    InventoryStockHelper.writeStock(updated, newStock);
                    updated['min_stock'] = int.tryParse(minC.text) ?? updated['min_stock'];
                    updated['category'] = catC.text.trim().isNotEmpty ? catC.text.trim() : updated['category'];

                    final productId = int.tryParse(p['id']?.toString() ?? '');
                    if (productId == null) throw Exception('Invalid backend product id');

                    final apiUpdate = <String, dynamic>{
                      'product_name': updated['product_name'],
                      'sku': updated['sku'] ?? updated['barcode'] ?? '',
                      'unit_price': updated['unit_price'],
                      'current_stock': InventoryStockHelper.readStock(updated),
                      'min_stock': updated['min_stock'] ?? 10,
                      'category': updated['category'] ?? 'General',
                    };

                    // Local-first cache update.
                    final cached = await LocalStorageService.loadBackendProducts();
                    final idx = cached.indexWhere((item) => item['id'].toString() == productId.toString());
                    final operationId = 'PRODUCT_UPDATE_${_userId ?? 0}_${productId}_${DateTime.now().microsecondsSinceEpoch}';
                    updated['sync_status'] = 'pending';
                    updated['local_updated_at'] = DateTime.now().toUtc().toIso8601String();
                    if (idx >= 0) {
                      cached[idx] = updated;
                      await LocalStorageService.saveBackendProducts(cached);
                    }
                    await CacheConsistencyService.markLocalMutation(
                      'inventory',
                      operationId: operationId,
                    );

                    await SyncQueueManager.enqueue('update_local_product', {
                      'operation_id': operationId,
                      'id': productId,
                      'user_id': _userId,
                      'payload': apiUpdate,
                    });

                    if (mounted) {
                      setState(() {
                        final prodIdx = _products.indexWhere((i) => i['id'].toString() == productId.toString());
                        if (prodIdx >= 0) _products[prodIdx] = updated;
                      });
                      Navigator.pop(context);
                      await _fetch();
                    }

                    unawaited(SyncService.processQueueSafe());

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✅ Product updated locally and queued for sync.'), backgroundColor: _warning),
                      );
                    }
                  } finally {
                    isSaving = false;
                    try { ss(() {}); } catch (_) {}
                  }
                },
                child: isSaving
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                      )
                    : Text('Save Changes', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 12),
          ]),
        ),
      )),
    );
  }

  Widget _buildLanguageSwitcher() {
    final langProvider = Provider.of<LanguageProvider>(context, listen: false);
    return PopupMenuButton<String>(
      icon: const Icon(Icons.language, color: Colors.white, size: 24),
      tooltip: 'Change Language',
      onSelected: (code) => langProvider.setLanguage(code),
      itemBuilder: (ctx) => LanguageProvider.languages.map((l) {
        return PopupMenuItem<String>(
          value: l['code'],
          child: Text('${l['nativeName']} (${l['name']})'),
        );
      }).toList(),
    );
  }
}