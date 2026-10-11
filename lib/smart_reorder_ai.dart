/// Shop-scoped, local-first stockout estimates from completed sale history.
///
/// This is a deterministic demand estimate, not an LLM prediction. It uses
/// seven calendar days of sale quantities recorded on the current owner device.
/// Products without a stable backend ID or a valid owner scope are not mixed
/// into another shop's history.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class SmartReorderAIService {
  static const String _salesHistoryKey = 'daily_sales_history_v2';
  static const String _recordedOperationsKey = 'smart_reorder_recorded_sale_lines_v1';
  static const int _velocityWindowDays = 7;
  static const int _defaultLeadTimeDays = 7;
  static const double _safetyStockFactor = 1.2;

  static Future<int?> _currentShopId(SharedPreferences prefs) async {
    final role = (prefs.getString('role') ??
            prefs.getString('user_role') ??
            prefs.getString('user_type') ??
            '')
        .trim()
        .toLowerCase();
    if (role == 'customer') return null;

    int? intId;
    try {
      intId = prefs.getInt('user_id') ?? prefs.getInt('userId');
    } catch (_) {
      // Some older login paths stored the identifier as a string.
    }
    if (intId != null && intId > 0) return intId;

    String? stringId;
    try {
      stringId = prefs.getString('user_id') ?? prefs.getString('userId');
    } catch (_) {
      // Ignore non-string legacy values.
    }
    final parsed = int.tryParse(stringId ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static String _dateKey(DateTime date) {
    final local = date.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  static String _historyKey(int shopId, DateTime date) =>
      '${_salesHistoryKey}_shop_${shopId}_${_dateKey(date)}';

  static double _asDouble(Object? value, [double fallback = 0]) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  /// Record a completed local sale line. The saleId + productId operation key
  /// prevents retries from inflating velocity. Callers should aggregate lines
  /// for the same product inside one invoice before calling this method.
  static Future<void> recordSale({
    required String saleId,
    required int productId,
    required double quantity,
  }) async {
    if (saleId.trim().isEmpty || productId <= 0 || quantity <= 0) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final shopId = await _currentShopId(prefs);
      if (shopId == null) return;

      final operationKey = '${saleId.trim()}:$productId';
      final operationPrefsKey = '${_recordedOperationsKey}_shop_$shopId';
      final recorded = prefs.getStringList(operationPrefsKey) ?? <String>[];
      if (recorded.contains(operationKey)) return;

      final now = DateTime.now();
      final historyPrefsKey = _historyKey(shopId, now);
      final raw = prefs.getString(historyPrefsKey);
      final daily = <String, double>{};
      if (raw != null && raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            daily[entry.key.toString()] = _asDouble(entry.value);
          }
        }
      }

      final productKey = productId.toString();
      daily[productKey] = (daily[productKey] ?? 0) + quantity;
      final historySaved = await prefs.setString(
        historyPrefsKey,
        jsonEncode(daily),
      );
      if (!historySaved) return;

      recorded.add(operationKey);
      // Bound preference growth while retaining enough history for ordinary
      // retry/recovery windows.
      if (recorded.length > 20000) {
        recorded.removeRange(0, recorded.length - 15000);
      }
      await prefs.setStringList(operationPrefsKey, recorded);
    } catch (_) {
      // Forecasting is advisory. It must never cause a completed bill to fail.
    }
  }

  /// Mean daily quantity over the last seven calendar days, including zero-sale
  /// days in the denominator so infrequent sales don't exaggerate demand.
  static Future<double> calculateVelocity({
    required int productId,
  }) async {
    if (productId <= 0) return 0;

    try {
      final prefs = await SharedPreferences.getInstance();
      final shopId = await _currentShopId(prefs);
      if (shopId == null) return 0;

      var totalQuantity = 0.0;
      final key = productId.toString();
      for (var dayOffset = 0; dayOffset < _velocityWindowDays; dayOffset++) {
        final date = DateTime.now().subtract(Duration(days: dayOffset));
        final raw = prefs.getString(_historyKey(shopId, date));
        if (raw == null || raw.trim().isEmpty) continue;

        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded.containsKey(key)) {
          totalQuantity += _asDouble(decoded[key]);
        }
      }
      return totalQuantity / _velocityWindowDays;
    } catch (_) {
      return 0;
    }
  }

  /// Predict approximate calendar days to stockout. A zero-stock item with
  /// observed demand returns zero days; no observed demand returns null.
  static Future<int?> predictStockoutDays({
    required int productId,
    required double currentStock,
  }) async {
    final velocity = await calculateVelocity(productId: productId);
    if (velocity <= 0) return null;
    if (currentStock <= 0) return 0;
    return (currentStock / velocity).ceil();
  }

  /// Generate reorder suggestions for inventory rows with stable server IDs.
  ///
  /// Suggested quantity targets seven days of demand plus a 20% safety buffer,
  /// less the stock already on hand. Rows with no recorded demand are omitted
  /// rather than presented as confident forecasts.
  static Future<List<Map<String, dynamic>>> getReorderAlerts({
    required List<Map<String, dynamic>> inventory,
    int stockoutThresholdDays = 5,
    int leadTimeDays = _defaultLeadTimeDays,
  }) async {
    final alerts = <Map<String, dynamic>>[];

    for (final product in inventory) {
      final productId = int.tryParse(
            (product['id'] ?? product['product_id'] ?? product['backend_id'] ?? '')
                .toString(),
          ) ??
          0;
      if (productId <= 0) continue;

      final productName =
          (product['product_name'] ?? product['name'] ?? 'Product $productId')
              .toString();
      final currentStock = _asDouble(
        product['current_stock'] ?? product['stock'] ?? product['quantity'],
      );
      final velocity = await calculateVelocity(productId: productId);
      if (velocity <= 0) continue;

      final stockoutDays = currentStock <= 0 ? 0 : (currentStock / velocity).ceil();
      if (stockoutDays > stockoutThresholdDays) continue;

      final targetStock = (velocity * leadTimeDays * _safetyStockFactor).ceil();
      final suggestedQuantity = (targetStock - currentStock.ceil()).clamp(0, 1000000);

      alerts.add({
        'product_id': productId,
        'product_name': productName,
        'current_stock': currentStock,
        'daily_velocity': double.parse(velocity.toStringAsFixed(2)),
        'days_until_stockout': stockoutDays,
        'suggested_reorder_qty': suggestedQuantity,
        'supplier_whatsapp': product['supplier_whatsapp'],
        'lead_time_days': leadTimeDays,
      });
    }

    alerts.sort((a, b) =>
        (a['days_until_stockout'] as int).compareTo(b['days_until_stockout'] as int));
    return alerts;
  }

  /// Generate a supplier message for owner approval; never sends it automatically.
  static String generateReorderMessage({
    required String productName,
    required int suggestedQty,
    required String shopName,
  }) {
    return 'Reorder Request\n\n'
        'Product: $productName\n'
        'Suggested Qty: $suggestedQty units\n'
        'From: $shopName\n\n'
        'Please confirm availability and pricing.';
  }
}
