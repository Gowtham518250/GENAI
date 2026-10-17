import 'live_translated_text.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'local_storage_service.dart';
import 'inventory_stock_helper.dart';
import 'smart_reorder_ai.dart';

/// Demand-based reorder suggestions. Forecasts use seven days of local sale
/// history for the signed-in shop; the page does not auto-create purchase orders.
class SmartReorderPage extends StatefulWidget {
  const SmartReorderPage({super.key});

  @override
  State<SmartReorderPage> createState() => _SmartReorderPageState();
}

class _SmartReorderPageState extends State<SmartReorderPage> {
  static const Color _primary = Color(0xFF635BFF);
  List<Map<String, dynamic>> _alerts = [];
  bool _loading = true;
  bool _usingLocalCache = false;
  String? _error;
  String _shopName = 'My Shop';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    var inventory = <Map<String, dynamic>>[];
    var usingLocalCache = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      _shopName = (prefs.getString('shop_name') ??
              prefs.getString('shopName') ??
              prefs.getString('business_name') ??
              'My Shop')
          .trim();
      if (_shopName.isEmpty) _shopName = 'My Shop';

      final response = await ApiClient.getJson(
        '/api/inventory/products?skip=0&limit=500',
      ).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) {
        throw Exception('Inventory API returned HTTP ${response.statusCode}.');
      }

      final decoded = jsonDecode(response.body);
      inventory = InventoryStockHelper.parseProductsResponse(decoded);
    } catch (error) {
      // The screen remains useful offline by using the owner's local cache.
      try {
        final local = await LocalStorageService.loadLocalProducts();
        final cachedBackend = await LocalStorageService.loadBackendProducts();
        // Keep both acknowledged server cache and pending offline products usable
        // when the backend read fails.
        final offlineProducts = local.values
            .whereType<Map>()
            .map((item) => <String, dynamic>{
                  ...Map<String, dynamic>.from(item),
                  'is_offline': true,
                })
            .toList();
        inventory = InventoryStockHelper.mergeApiWithLocalCache(
          InventoryStockHelper.normalizeProducts(cachedBackend),
          offlineProducts,
        );
        usingLocalCache = inventory.isNotEmpty;
        if (!usingLocalCache) {
          _error = 'Could not load inventory. Check the connection and try again.';
        }
      } catch (_) {
        _error = 'Could not load inventory. Check the connection and try again.';
      }
    }

    List<Map<String, dynamic>> alerts = [];
    if (inventory.isNotEmpty) {
      try {
        alerts = await SmartReorderAIService.getReorderAlerts(
          inventory: inventory,
          stockoutThresholdDays: 5,
          leadTimeDays: 7,
        );
      } catch (error) {
        _error = 'Could not calculate reorder suggestions: $error';
      }
    }

    if (!mounted) return;
    setState(() {
      _alerts = alerts;
      _usingLocalCache = usingLocalCache;
      _loading = false;
    });
  }

  String _qty(Object? value) {
    if (value is! num) return value?.toString() ?? '0';
    if (value.toDouble() == value.toInt().toDouble()) return value.toInt().toString();
    return value.toStringAsFixed(1);
  }

  Future<void> _openWhatsApp(Map<String, dynamic> alert) async {
    final productName = alert['product_name']?.toString() ?? 'Product';
    final quantity = (alert['suggested_reorder_qty'] as num?)?.toInt() ?? 0;
    final message = SmartReorderAIService.generateReorderMessage(
      productName: productName,
      suggestedQty: quantity,
      shopName: _shopName,
    );
    final phone = (alert['supplier_whatsapp'] ?? '')
        .toString()
        .replaceAll(RegExp(r'\D'), '');
    final uri = Uri.https(
      'wa.me',
      phone.isEmpty ? '/' : '/$phone',
      {'text': message},
    );

    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw Exception('WhatsApp could not be opened.');
      }
    } catch (_) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const LiveTranslatedText('Reorder message'),
          content: SelectableText(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const LiveTranslatedText('Close'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FC),
      appBar: AppBar(
        title: const LiveTranslatedText('Smart Reorder'),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Refresh forecast',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? ListView(
                children: const [
                  SizedBox(height: 220),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.insights_rounded, color: _primary),
                            SizedBox(width: 8),
                            LiveTranslatedText(
                              'Demand-based stockout forecast',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                        LiveTranslatedText(
                          'Uses seven days of sales saved on this owner device. '
                          'Suggestions are advisory only; review quantities before ordering.',
                          style: TextStyle(color: Color(0xFF667085), height: 1.45),
                        ),
                      ],
                    ),
                  ),
                  if (_usingLocalCache) ...[
                    const SizedBox(height: 10),
                    const LiveTranslatedText(
                      'Offline mode: using cached inventory. Stock may have changed on the server.',
                      style: TextStyle(color: Color(0xFF9A6700), fontSize: 12),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    LiveTranslatedText(_error!, style: const TextStyle(color: Colors.red)),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                        label: const LiveTranslatedText('Try again'),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_alerts.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE5E7EB)),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.inventory_2_outlined, size: 36, color: Color(0xFF667085)),
                          SizedBox(height: 10),
                          LiveTranslatedText(
                            'No stockout forecasts yet',
                            style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                          ),
                          SizedBox(height: 6),
                          LiveTranslatedText(
                            'Forecasts appear after this device has recorded sales for a product. '
                            'Products without sales history are not given an invented estimate.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Color(0xFF667085), height: 1.45),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    LiveTranslatedText(
                      '${_alerts.length} product(s) may run out in 5 days or less',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                    ),
                    const SizedBox(height: 10),
                    ..._alerts.map((alert) {
                      final stockoutDays =
                          (alert['days_until_stockout'] as num?)?.toInt() ?? 0;
                      final isUrgent = stockoutDays <= 2;
                      final suggestedQty =
                          (alert['suggested_reorder_qty'] as num?)?.toInt() ?? 0;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isUrgent
                                ? const Color(0xFFFECACA)
                                : const Color(0xFFE5E7EB),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: LiveTranslatedText(
                                    alert['product_name']?.toString() ?? 'Product',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isUrgent
                                        ? const Color(0xFFFEE2E2)
                                        : const Color(0xFFFFF3CD),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: LiveTranslatedText(
                                    stockoutDays == 0 ? 'Out of stock' : '$stockoutDays days left',
                                    style: TextStyle(
                                      color: isUrgent
                                          ? const Color(0xFF991B1B)
                                          : const Color(0xFF854D0E),
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 18,
                              runSpacing: 10,
                              children: [
                                _metric('Current stock', _qty(alert['current_stock'])),
                                _metric('Avg. sales/day', _qty(alert['daily_velocity'])),
                                _metric('Suggested qty', suggestedQty.toString()),
                              ],
                            ),
                            const SizedBox(height: 14),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: suggestedQty <= 0 ? null : () => _openWhatsApp(alert),
                                icon: const Icon(Icons.chat_rounded),
                                label: const LiveTranslatedText('Prepare supplier message'),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _metric(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LiveTranslatedText(label, style: const TextStyle(color: Color(0xFF667085), fontSize: 12)),
        const SizedBox(height: 3),
        LiveTranslatedText(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ],
    );
  }
}
