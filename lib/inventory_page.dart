import 'dart:async';
import 'cache_consistency_service.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
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
  String _inventorySearch = '';
  String _stockFilter = 'All';
  int? _userId;
  // 🔧 FIX: distinguishes "backend confirmed 0 products" from "we couldn't
  // reach the backend" (e.g. slow/flaky 5G) so we never show the scary
  // "No products yet" empty-state when the real problem is just network.
  bool _lastFetchFailed = false;
  bool _realtimeConnected = false;
  StreamSubscription<List<Map<String, dynamic>>>? _durableEventsSubscription;
  bool _durableInventoryRefreshInProgress = false;
  bool _durableInventoryRefreshPending = false;

  // Add-product form controllers
  final _nameC = TextEditingController();
  final _barcodeC = TextEditingController();
  final _priceC = TextEditingController();
  final _purchasePriceC = TextEditingController();
  final _mrpC = TextEditingController();
  final _stockC = TextEditingController();
  final _catC = TextEditingController();
  final _minStockC = TextEditingController(text: '10');
  final _unitC = TextEditingController(text: 'pcs');
  final _imageUrlC = TextEditingController();
  Uint8List? _selectedProductImageBytes;
  String? _selectedProductImageDataUrl;
  bool _imageLookupLoading = false;

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
    _durableEventsSubscription = SyncService.durableEventsStream.listen((events) {
      if (!mounted) return;
      final hasInventoryChange = events.any(
        (event) => event['type']?.toString() == 'inventory.changed',
      );
      if (hasInventoryChange) unawaited(_refreshInventoryFromDurableFeed());
    });
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

  /// Apply a bounded remote reconciliation for inventory changes recovered
  /// from the durable feed. Redis events update known stock immediately; this
  /// path also handles product create/update/archive events whose payload only
  /// contains an ID, and catches WebSocket messages that were missed.
  Future<void> _refreshInventoryFromDurableFeed() async {
    if (!mounted) return;
    if (_durableInventoryRefreshInProgress) {
      _durableInventoryRefreshPending = true;
      return;
    }
    _durableInventoryRefreshInProgress = true;
    try {
      await _fetch(forceRemote: true);
    } catch (e) {
      if (kDebugMode) debugPrint('Inventory durable refresh deferred: $e');
    } finally {
      _durableInventoryRefreshInProgress = false;
      if (_durableInventoryRefreshPending && mounted) {
        _durableInventoryRefreshPending = false;
        unawaited(_refreshInventoryFromDurableFeed());
      }
    }
  }

  double? _asStockNumber(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '');
  }

  @override
  void dispose() {
    _durableEventsSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    RealtimeClient.disconnect();
    _nameC.dispose(); _barcodeC.dispose(); _priceC.dispose(); _purchasePriceC.dispose(); _mrpC.dispose();
    _stockC.dispose(); _catC.dispose(); _minStockC.dispose(); _unitC.dispose();
    _imageUrlC.dispose();
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
                '${ApiClient.inventoryPrefix}/products?skip=0&limit=1000',
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
            // The shared parser handles direct lists and supported API envelopes.
            final apiProducts =
                InventoryStockHelper.parseProductsResponse(decoded);
            // A valid empty response is authoritative. The merge helper retains
            // only pending local mutations rather than resurrecting deleted stock.
            final effectiveApiProducts = apiProducts;

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
    final purchasePrice = double.tryParse(_purchasePriceC.text);
    final imageUrlValue = _selectedProductImageDataUrl ??
        (_imageUrlC.text.trim().isEmpty ? null : _imageUrlC.text.trim());
    if (imageUrlValue != null &&
        (imageUrlValue.length > 120000 ||
         (!imageUrlValue.startsWith('https://') &&
          !imageUrlValue.startsWith('http://') &&
          !imageUrlValue.startsWith('data:image/')))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Use an http(s) image URL or upload a supported image.')),
      );
      return;
    }
    if (_nameC.text.isEmpty || _priceC.text.isEmpty || purchasePrice == null || !purchasePrice.isFinite || purchasePrice <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Product name, selling price, and purchase cost (greater than zero) are required')));
      return;
    }

    final productData = {
      'product_name': _nameC.text.trim(),
      'sku': (_barcodeC.text.trim().isNotEmpty ? _barcodeC.text.trim() : _nameC.text.trim()).toLowerCase(),
      'unit_price': double.tryParse(_priceC.text) ?? 0,
      'purchase_price': purchasePrice,
      'mrp': double.tryParse(_mrpC.text) ?? 0,
      'current_stock': int.tryParse(_stockC.text) ?? 0,
      'min_stock': int.tryParse(_minStockC.text) ?? 10,
      'category': _catC.text.trim().isNotEmpty ? _catC.text.trim() : 'General',
      'unit': _unitC.text.trim().isNotEmpty ? _unitC.text.trim() : 'pcs',
      'image_url': imageUrlValue,
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
      _nameC.clear(); _barcodeC.clear(); _priceC.clear(); _purchasePriceC.clear(); _mrpC.clear();
      _stockC.clear(); _catC.clear(); _minStockC.text = '10'; _unitC.text = 'pcs';
      _imageUrlC.clear(); _selectedProductImageBytes = null; _selectedProductImageDataUrl = null;
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


  Widget _productImagePreview(Uint8List? bytes, String? imageUrl, {double size = 82}) {
    final value = (imageUrl ?? '').trim();
    Widget image = Container(
      width: size,
      height: size,
      color: const Color(0xFFF1F5F9),
      child: Icon(Icons.inventory_2_rounded, color: Colors.blueGrey.shade400, size: size * 0.36),
    );
    if (bytes != null && bytes.isNotEmpty) {
      image = Image.memory(bytes, width: size, height: size, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(Icons.inventory_2_rounded, color: Colors.blueGrey.shade400, size: size * 0.36));
    } else if (value.startsWith('data:image/')) {
      final comma = value.indexOf(',');
      if (comma > 0) {
        try {
          image = Image.memory(base64Decode(value.substring(comma + 1)), width: size, height: size, fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, color: Colors.blueGrey.shade400, size: size * 0.36));
        } catch (_) {}
      }
    } else if (value.startsWith('https://') || value.startsWith('http://')) {
      image = Image.network(value, width: size, height: size, fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Icon(Icons.broken_image_outlined, color: Colors.blueGrey.shade400, size: size * 0.36));
    }
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Center(child: image),
    );
  }

  Future<List<Map<String, dynamic>>> _findProductImageSuggestions(
    String productName,
    String category,
  ) async {
    final encodedName = Uri.encodeQueryComponent(productName.trim());
    final encodedCategory = Uri.encodeQueryComponent(category.trim());
    final response = await ApiClient.getJson(
      '/api/inventory/product-image-suggestions?product_name=' + encodedName +
      (encodedCategory.isEmpty ? '' : '&category=' + encodedCategory),
    ).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      String message = 'Online image search failed (HTTP ' + response.statusCode.toString() + ').';
      try {
        final body = jsonDecode(response.body);
        if (body is Map && body['detail'] != null) message = body['detail'].toString();
      } catch (_) {}
      throw Exception(message);
    }
    final decoded = jsonDecode(response.body);
    final raw = decoded is Map ? decoded['images'] : null;
    if (raw is! List) return <Map<String, dynamic>>[];
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) => (item['image_url']?.toString() ?? '').startsWith('https://'))
        .take(8)
        .toList();
  }

  Future<String?> _chooseProductImage(String productName, List<Map<String, dynamic>> images) {
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Choose a matching image', style: GoogleFonts.poppins(fontWeight: FontWeight.w800, fontSize: 17)),
        content: SizedBox(
          width: 440,
          height: 420,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Suggestions for ' + productName + '. Check the package/brand before saving.',
              style: GoogleFonts.poppins(fontSize: 11, color: Colors.blueGrey.shade600)),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.separated(
                itemCount: images.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final item = images[index];
                  final url = item['image_url']?.toString() ?? '';
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => Navigator.of(dialogContext).pop(url),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        _productImagePreview(null, url, size: 66),
                        const SizedBox(width: 10),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(item['title']?.toString() ?? productName, maxLines: 2, overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(fontSize: 11, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text(item['source']?.toString() ?? 'Online image result', maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.poppins(fontSize: 9, color: Colors.blueGrey.shade500)),
                          const SizedBox(height: 3),
                          Text('Use this image', style: GoogleFonts.poppins(fontSize: 9, color: _primary, fontWeight: FontWeight.w800)),
                        ])),
                        const Icon(Icons.chevron_right_rounded),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel'))],
      ),
    );
  }

  Future<void> _pickProductImage(StateSetter updateDialog) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 28,
        maxWidth: 320,
        maxHeight: 320,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) throw Exception('The selected image is empty.');
      if (bytes.length > 45 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Choose a smaller image. Please crop it or use a lower-resolution photo (45 KB max).')),
          );
        }
        return;
      }
      updateDialog(() {
        _selectedProductImageBytes = bytes;
        _selectedProductImageDataUrl = 'data:image/jpeg;base64,' + base64Encode(bytes);
        _imageUrlC.clear();
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not select image: ' + error.toString())),
        );
      }
    }
  }

  Future<void> _lookupProductImageForAdd(StateSetter updateDialog) async {
    final name = _nameC.text.trim();
    if (name.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter the product name first.')));
      return;
    }
    updateDialog(() => _imageLookupLoading = true);
    try {
      final suggestions = await _findProductImageSuggestions(name, _catC.text);
      if (suggestions.isEmpty) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No online images found. You can upload a photo or paste an image URL.')),
        );
        return;
      }
      if (!mounted) return;
      final selected = await _chooseProductImage(name, suggestions);
      if (selected != null) {
        updateDialog(() {
          _imageUrlC.text = selected;
          _selectedProductImageBytes = null;
          _selectedProductImageDataUrl = null;
        });
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      try { updateDialog(() => _imageLookupLoading = false); } catch (_) {}
    }
  }

  Future<void> _showProductImageDialog(Map<String, dynamic> product) async {
    final urlController = TextEditingController(text: product['image_url']?.toString() ?? '');
    Uint8List? selectedBytes;
    String? selectedDataUrl;
    bool lookupLoading = false;
    bool saving = false;
    final productName = product['product_name']?.toString() ?? 'Product';
    final category = product['category']?.toString() ?? '';
    final rawId = int.tryParse(product['id']?.toString() ?? '');
    final sku = product['sku']?.toString() ?? product['barcode']?.toString() ?? '';

    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) => StatefulBuilder(
          builder: (sheetContext, ss) => Container(
            padding: EdgeInsets.only(bottom: MediaQuery.of(sheetContext).viewInsets.bottom),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.photo_camera_back_rounded, color: _primary),
                  const SizedBox(width: 9),
                  Expanded(child: Text('Product image · ' + productName, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w800))),
                  IconButton(onPressed: () => Navigator.pop(sheetContext), icon: const Icon(Icons.close)),
                ]),
                const SizedBox(height: 12),
                Center(child: _productImagePreview(selectedBytes, urlController.text, size: 130)),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: saving ? null : () async {
                      try {
                        final picked = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 28, maxWidth: 320, maxHeight: 320);
                        if (picked == null) return;
                        final bytes = await picked.readAsBytes();
                        if (bytes.isEmpty || bytes.length > 45 * 1024) {
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Choose a smaller image (45 KB max).')));
                          return;
                        }
                        ss(() {
                          selectedBytes = bytes;
                          selectedDataUrl = 'data:image/jpeg;base64,' + base64Encode(bytes);
                          urlController.clear();
                        });
                      } catch (error) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Image selection failed: ' + error.toString())));
                      }
                    },
                    icon: const Icon(Icons.upload_rounded),
                    label: const Text('Upload photo'),
                  ),
                  OutlinedButton.icon(
                    onPressed: saving || lookupLoading ? null : () async {
                      ss(() => lookupLoading = true);
                      try {
                        final suggestions = await _findProductImageSuggestions(productName, category);
                        if (!mounted) return;
                        if (suggestions.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No matching images found.')));
                        } else {
                          final selected = await _chooseProductImage(productName, suggestions);
                          if (selected != null) ss(() {
                            urlController.text = selected;
                            selectedBytes = null;
                            selectedDataUrl = null;
                          });
                        }
                      } catch (error) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.toString().replaceFirst('Exception: ', ''))));
                      } finally {
                        try { ss(() => lookupLoading = false); } catch (_) {}
                      }
                    },
                    icon: lookupLoading ? const SizedBox(width: 14,height: 14,child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.travel_explore_rounded),
                    label: const Text('Find online image'),
                  ),
                ]),
                const SizedBox(height: 10),
                TextField(
                  controller: urlController,
                  onChanged: (_) => ss(() { selectedBytes = null; selectedDataUrl = null; }),
                  decoration: InputDecoration(
                    labelText: 'Image URL (optional)',
                    hintText: 'https://…',
                    prefixIcon: const Icon(Icons.link_rounded),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 18),
                SizedBox(width: double.infinity, child: FilledButton.icon(
                  onPressed: saving ? null : () async {
                    final imageUrl = selectedDataUrl ?? (urlController.text.trim().isEmpty ? null : urlController.text.trim());
                    if (imageUrl != null && !imageUrl.startsWith('https://') && !imageUrl.startsWith('http://') && !imageUrl.startsWith('data:image/')) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Use an http(s) image URL or upload a photo.')));
                      return;
                    }
                    ss(() => saving = true);
                    try {
                      final updated = Map<String, dynamic>.from(product);
                      updated['image_url'] = imageUrl;
                      final timestamp = DateTime.now().toUtc().toIso8601String();
                      updated['local_updated_at'] = timestamp;
                      updated['sync_status'] = 'pending';
                      final backendProducts = await LocalStorageService.loadBackendProducts();
                      // API/cache rows can identify the same product through id,
                      // product_id, backend_id or server_id. Resolve through the
                      // canonical helper instead of assuming product['id'] exists.
                      final backendProductId = _resolveBackendProductId(
                        product,
                        cachedProducts: backendProducts,
                      ) ?? rawId;
                      final backendIndex = backendProductId == null
                          ? -1
                          : backendProducts.indexWhere((item) =>
                              _resolveBackendProductId(item) == backendProductId ||
                              (sku.isNotEmpty &&
                                  (item['sku'] ?? item['barcode'])?.toString() == sku));

                      if (backendIndex >= 0) {
                        final cachedProduct = Map<String, dynamic>.from(backendProducts[backendIndex]);
                        cachedProduct['image_url'] = imageUrl;
                        cachedProduct['local_updated_at'] = timestamp;
                        cachedProduct['sync_status'] = 'pending';
                        backendProducts[backendIndex] = cachedProduct;
                        await LocalStorageService.saveBackendProducts(backendProducts);
                      } else if (backendProductId != null) {
                        // The API product may be visible in the current list but
                        // not yet persisted in the cache. Add the pending row so
                        // the next remote refresh cannot replace its image with
                        // an older/null image_url before the update is acked.
                        final cachedProduct = InventoryStockHelper.normalizeProduct(product);
                        cachedProduct['id'] = backendProductId;
                        cachedProduct['product_id'] ??= backendProductId;
                        cachedProduct['image_url'] = imageUrl;
                        cachedProduct['local_updated_at'] = timestamp;
                        cachedProduct['sync_status'] = 'pending';
                        backendProducts.add(cachedProduct);
                        await LocalStorageService.saveBackendProducts(backendProducts);
                      }

                      final local = await LocalStorageService.loadLocalProducts();
                      final productIds = <String>{
                        rawId?.toString() ?? '',
                        backendProductId?.toString() ?? '',
                        product['product_id']?.toString() ?? '',
                        product['backend_id']?.toString() ?? '',
                        product['server_id']?.toString() ?? '',
                      }..removeWhere((value) => value.isEmpty || value == 'null' || value == '0');
                      final normalizedName = productName.trim().toLowerCase();
                      final sameNameLocalCount = normalizedName.isEmpty ? 0 : local.values
                          .whereType<Map>()
                          .where((value) =>
                              (value['product_name'] ?? value['name'] ?? '').toString().trim().toLowerCase() == normalizedName)
                          .length;
                      final localKey = local.keys.firstWhere((key) {
                        if (sku.isNotEmpty && key.toString() == sku) return true;
                        final raw = local[key];
                        if (raw is! Map) return false;
                        final row = Map<String, dynamic>.from(raw);
                        final localSku = (row['sku'] ?? row['barcode'] ?? '').toString();
                        if (sku.isNotEmpty && localSku == sku) return true;
                        final localIds = <String>{
                          row['id']?.toString() ?? '',
                          row['product_id']?.toString() ?? '',
                          row['backend_id']?.toString() ?? '',
                          row['server_id']?.toString() ?? '',
                        };
                        if (productIds.any(localIds.contains)) return true;
                        return sku.isEmpty &&
                            sameNameLocalCount == 1 &&
                            normalizedName.isNotEmpty &&
                            (row['product_name'] ?? row['name'] ?? '').toString().trim().toLowerCase() == normalizedName;
                      }, orElse: () => '');

                      if (localKey.isNotEmpty && local[localKey] is Map) {
                        final localRecord = Map<String, dynamic>.from(local[localKey] as Map);
                        localRecord['image_url'] = imageUrl;
                        localRecord['local_updated_at'] = timestamp;
                        localRecord['sync_status'] = 'pending';
                        local[localKey] = localRecord;
                        await LocalStorageService.saveLocalProducts(local);
                      }

                      if (backendProductId != null && backendProductId > 0 && _userId != null) {
                        final operationId = 'PRODUCT_IMAGE_UPDATE_' + backendProductId.toString() + '_' + DateTime.now().microsecondsSinceEpoch.toString();
                        await CacheConsistencyService.markLocalMutation('inventory', operationId: operationId);
                        await SyncQueueManager.enqueue('update_local_product', {
                          'operation_id': operationId,
                          'id': backendProductId,
                          'user_id': _userId,
                          'payload': {'image_url': imageUrl, 'local_updated_at': timestamp},
                        });
                        unawaited(SyncService.processQueueSafe());
                      } else if (localKey.isEmpty) {
                        throw StateError('Could not match this product to a saved inventory record. Refresh Inventory and try again.');
                      }
                      if (mounted) {
                        setState(() {
                          updated['id'] ??= backendProductId;
                          final index = _products.indexWhere((item) {
                            final itemId = _resolveBackendProductId(item, cachedProducts: backendProducts);
                            if (backendProductId != null && itemId == backendProductId) return true;
                            if (sku.isNotEmpty && (item['sku'] ?? item['barcode'])?.toString() == sku) return true;
                            return sku.isEmpty &&
                                sameNameLocalCount == 1 &&
                                (item['product_name'] ?? item['name'] ?? '').toString().trim().toLowerCase() == normalizedName;
                          });
                          if (index >= 0) _products[index] = updated;
                        });
                        Navigator.pop(sheetContext);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Product image saved locally and queued to sync.')));
                      }
                    } catch (error) {
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save image: ' + error.toString())));
                    } finally {
                      try { ss(() => saving = false); } catch (_) {}
                    }
                  },
                  icon: saving ? const SizedBox(width: 15,height: 15,child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_rounded),
                  label: Text(saving ? 'Saving…' : 'Save product image'),
                )),
              ]),
            ),
          ),
        ),
      );
    } finally {
      urlController.dispose();
    }
  }

  void _showAddDialog() {
    _isAddingProduct = false; // reset in case a previous sheet left it stuck
    _imageUrlC.clear();
    _selectedProductImageBytes = null;
    _selectedProductImageDataUrl = null;
    _imageLookupLoading = false;
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

              _field(_purchasePriceC, 'Purchase Cost Price (₹) *', Icons.price_check,
                  type: TextInputType.number),
              _field(_priceC, 'Selling Price (₹) *', Icons.currency_rupee,
                  type: TextInputType.number),
              _field(_mrpC, 'MRP - Declared (₹) [GST Compliance]', Icons.verified_user,
                  type: TextInputType.number),
              _field(_stockC, 'Current Stock', Icons.numbers,
                  type: TextInputType.number),
              _field(_minStockC, 'Min Stock Alert', Icons.warning_amber,
                  type: TextInputType.number),
              _field(_catC, 'Category', Icons.category),
              Container(
                margin: const EdgeInsets.only(top: 2, bottom: 14),
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.add_photo_alternate_rounded, color: _primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Product image', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700)),
                      Text('Optional · upload your own or choose a matching online image', style: GoogleFonts.poppins(fontSize: 10, color: Colors.blueGrey.shade500)),
                    ])),
                  ]),
                  const SizedBox(height: 11),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _productImagePreview(_selectedProductImageBytes, _imageUrlC.text, size: 86),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 7, runSpacing: 7, children: [
                        OutlinedButton.icon(
                          onPressed: () => _pickProductImage(ss),
                          icon: const Icon(Icons.upload_rounded, size: 16),
                          label: const Text('Upload'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _imageLookupLoading ? null : () => _lookupProductImageForAdd(ss),
                          icon: _imageLookupLoading
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.travel_explore_rounded, size: 16),
                          label: const Text('Find online'),
                        ),
                      ]),
                      const SizedBox(height: 5),
                      Text('Confirm the brand/package before using an online suggestion.', style: GoogleFonts.poppins(fontSize: 9, color: Colors.blueGrey.shade500, height: 1.4)),
                    ])),
                  ]),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _imageUrlC,
                    onChanged: (_) => ss(() {
                      _selectedProductImageBytes = null;
                      _selectedProductImageDataUrl = null;
                    }),
                    decoration: InputDecoration(
                      labelText: 'Image URL (optional)',
                      hintText: 'https://…',
                      prefixIcon: const Icon(Icons.link_rounded),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ]),
              ),
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
    final lowStock = _products.where((p) {
      final stock = _stockNumber(p['current_stock']);
      final minimum = _stockNumber(p['min_stock'], fallback: 10);
      return stock > 0 && stock <= minimum;
    }).length;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: Text(AppLocalizations.of(context).inventory, style: GoogleFonts.poppins(
            fontWeight: FontWeight.w800, color: const Color(0xFF172554))),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF172554),
        surfaceTintColor: Colors.white,
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

  double _stockNumber(dynamic value, {double fallback = 0}) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  int _inventoryFilterCount(String filter) {
    return _products.where((raw) {
      if (raw is! Map) return false;
      final product = Map<String, dynamic>.from(raw);
      final stock = _stockNumber(product['current_stock']);
      final minimum = _stockNumber(product['min_stock'], fallback: 10);
      switch (filter) {
        case 'Low Stock': return stock > 0 && stock <= minimum;
        case 'Out of Stock': return stock <= 0;
        case 'In Stock': return stock > minimum;
        default: return true;
      }
    }).length;
  }

  Widget _stockFilterChip(String filter) {
    final selected = _stockFilter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text('$filter (' + _inventoryFilterCount(filter).toString() + ')'),
        selected: selected,
        onSelected: (_) => setState(() => _stockFilter = filter),
        showCheckmark: false,
        selectedColor: const Color(0xFFEDE9FE),
        backgroundColor: const Color(0xFFF7F8FC),
        side: BorderSide(color: selected ? _primary.withValues(alpha: 0.3) : const Color(0xFFE5E7EB)),
        labelStyle: GoogleFonts.poppins(color: selected ? _primary : const Color(0xFF64748B), fontSize: 11, fontWeight: selected ? FontWeight.w700 : FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      ),
    );
  }

  Widget _buildList(int lowStock) {
    final outOfStock = _inventoryFilterCount('Out of Stock');
    final filteredProducts = _products.where((raw) {
      if (raw is! Map) return false;
      final product = Map<String, dynamic>.from(raw);
      final stock = _stockNumber(product['current_stock']);
      final minimum = _stockNumber(product['min_stock'], fallback: 10);
      final search = _inventorySearch.trim().toLowerCase();
      final searchable = [product['product_name'], product['category'], product['sku'], product['barcode']]
          .where((value) => value != null).join(' ').toLowerCase();
      final matchesSearch = search.isEmpty || searchable.contains(search);
      var matchesFilter = true;
      if (_stockFilter == 'Low Stock') {
        matchesFilter = stock > 0 && stock <= minimum;
      } else if (_stockFilter == 'Out of Stock') {
        matchesFilter = stock <= 0;
      } else if (_stockFilter == 'In Stock') {
        matchesFilter = stock > minimum;
      }
      return matchesSearch && matchesFilter;
    }).map((raw) => Map<String, dynamic>.from(raw as Map)).toList();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: const BoxDecoration(color: Colors.white, border: Border(bottom: BorderSide(color: Color(0xFFE8ECF4)))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: _statChip('Products', _products.length.toString(), Icons.inventory_2_rounded, color: _primary)),
                  const SizedBox(width: 8),
                  Expanded(child: _statChip('Low stock', lowStock.toString(), Icons.warning_amber_rounded, color: lowStock > 0 ? _warning : _success)),
                  const SizedBox(width: 8),
                  Expanded(child: _statChip('Out of stock', outOfStock.toString(), Icons.remove_shopping_cart_rounded, color: outOfStock > 0 ? const Color(0xFFDC2626) : _success)),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                onChanged: (value) => setState(() => _inventorySearch = value),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Search products, barcode, or category',
                  hintStyle: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFF94A3B8)),
                  prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFF64748B), size: 21),
                  suffixIcon: _inventorySearch.isEmpty ? null : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => setState(() => _inventorySearch = ''),
                  ),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: _primary, width: 1.5)),
                ),
              ),
              const SizedBox(height: 12),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Row(children: [
                  _stockFilterChip('All'),
                  _stockFilterChip('Low Stock'),
                  _stockFilterChip('Out of Stock'),
                  _stockFilterChip('In Stock'),
                ]),
              ),
            ],
          ),
        ),
        Expanded(
          child: filteredProducts.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(padding: const EdgeInsets.all(18), decoration: const BoxDecoration(color: Color(0xFFEDE9FE), shape: BoxShape.circle), child: const Icon(Icons.search_off_rounded, color: _primary, size: 34)),
                        const SizedBox(height: 14),
                        Text('No matching products', style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w700, color: const Color(0xFF172554))),
                        const SizedBox(height: 5),
                        Text('Try another search or stock filter.', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 12, color: const Color(0xFF64748B))),
                        const SizedBox(height: 12),
                        TextButton.icon(
                          onPressed: () => setState(() { _inventorySearch = ''; _stockFilter = 'All'; }),
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          label: const Text('Reset filters'),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 110),
                  itemCount: filteredProducts.length,
                  itemBuilder: (_, i) => _productCard(filteredProducts[i]),
                ),
        ),
      ],
    );
  }

  Widget _statChip(String label, String val, IconData icon, {Color color = _primary}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xFFE8ECF4)),
        boxShadow: [BoxShadow(color: const Color(0xFF172554).withValues(alpha: 0.035), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Row(
        children: [
          Container(padding: const EdgeInsets.all(7), decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)), child: Icon(icon, size: 17, color: color)),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(val, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(fontSize: 17, height: 1.2, fontWeight: FontWeight.w800, color: const Color(0xFF172554))),
                const SizedBox(height: 2),
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: GoogleFonts.poppins(fontSize: 9.5, color: const Color(0xFF64748B), fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _productCard(Map<String, dynamic> p) {
    final stock = _stockNumber(p['current_stock']);
    final minimum = _stockNumber(p['min_stock'], fallback: 10);
    final isLow = stock <= minimum;
    final isOut = stock <= 0;
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
                _productImagePreview(null, p['image_url']?.toString(), size: 46),
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
                GestureDetector(
                  onTap: () => _showProductImageDialog(Map<String, dynamic>.from(p)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.teal.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      (p['image_url']?.toString().isNotEmpty ?? false)
                        ? Icons.photo_camera_back_rounded
                        : Icons.add_photo_alternate_outlined,
                      size: 16,
                      color: Colors.teal.shade700,
                    ),
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
    final purchasePriceC = TextEditingController(text: (p['purchase_price'] ?? p['cost_price'] ?? 0).toString());
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
            _field(purchasePriceC, 'Purchase Cost Price (₹)', Icons.price_check, type: TextInputType.number),
            _field(priceC, 'Selling Price (₹) *', Icons.currency_rupee, type: TextInputType.number),
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
                    updated['purchase_price'] = double.tryParse(purchasePriceC.text) ?? updated['purchase_price'] ?? 0;
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
                      'purchase_price': updated['purchase_price'] ?? 0,
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