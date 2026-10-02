  }

  static Future<bool> markSaleAsSynced(String saleId) async {
    if (saleId.trim().isEmpty) return false;
    return _markSaleAsSynced(saleId.trim());
  }

  static void triggerBackgroundAlert(Map<String, dynamic> item) {
    try {
      StockAlertService.checkAndAlertLowStock(
        productName: item['product_name']?.toString() ?? 'Unknown',
        quantitySold: (item['qty'] is num
            ? (item['qty'] as num).toDouble()
            : double.tryParse(item['qty']?.toString() ?? '1') ?? 1.0).round(),
        productId: int.tryParse((item['product_id'] ?? item['id'] ?? '0').toString()) ?? 0,
      );
    } catch (_) {}
  }

  /// Local-only stock check. Missing stock fields default to 0 (not 9999).
  static Future<Map<String, dynamic>> _validateStockAvailabilityLocally(List<Map<String, dynamic>> items) async {
    try {
      final localProducts = await LocalStorageService.loadLocalProducts();
      final productsList = localProducts is List ? localProducts as List : localProducts.values.toList();
      final insufficientItems = <Map<String, dynamic>>[];
      final bool catalogLoaded = productsList.isNotEmpty;

      for (var item in items) {
        final productId = int.tryParse((item['product_id'] ?? item['id'] ?? '0').toString()) ?? 0;
        final qty = (item['qty'] is num
            ? (item['qty'] as num).toDouble()
            : double.tryParse(item['qty']?.toString() ?? '1') ?? 1.0);
        final itemName = (item['product_name'] ?? item['itemName'] ?? item['name'] ?? '').toString().toLowerCase();

        if (productId > 0 || itemName.isNotEmpty) {
          Map<String, dynamic>? found;
          for (var p in productsList) {
            final pIdRaw = (p['id'] ?? p['product_id'] ?? '').toString();
            final pId = int.tryParse(pIdRaw) ?? 0;
            final pName = (p['product_name'] ?? p['name'] ?? '').toString().toLowerCase();

            if ((productId > 0 && pId == productId) || (itemName.isNotEmpty && pName == itemName)) {
              found = Map<String, dynamic>.from(p as Map);
              break;
            }
          }

          if (found != null) {
            final stockRaw = found['current_stock'] ?? found['stock'] ?? found['quantity'];
            final currentStock = stockRaw == null
                ? 0.0
                : ((stockRaw is num) ? stockRaw.toDouble() : double.tryParse(stockRaw.toString()) ?? 0.0);
            if (qty > currentStock) {
              insufficientItems.add({
                'product_id': productId,
                'product_name': found['product_name'] ?? found['name'] ?? itemName,
                'requested_qty': qty,
                'available_stock': currentStock,
              });
            }
          } else {
            // Unknown/local-unsynced products cannot be safely rejected solely
            // because the local catalog is stale or unavailable. Backend
            // invoice validation remains authoritative when connectivity exists.
            // Only reject when the product was actually found and confirmed
            // to have insufficient stock locally.
          }
        }
      }

      if (insufficientItems.isEmpty) {
        return {'valid': true, 'message': 'Stock check passed'};
      }
      final productNames = insufficientItems.map((i) => i['product_name']).join(', ');
      return {
        'valid': false,
        'message': 'Insufficient stock for: $productNames',
        'insufficient_items': insufficientItems,
      };
    } catch (e) {
      // Local stock is an optimization/safety check, not the authority for
      // whether a bill may be created. Fresh installs, data clears and a
      // closed Hive box must never brick billing. The backend invoice-sync
      // endpoint remains authoritative when available.
      if (kDebugMode) debugPrint('⚠️ Local stock validation unavailable; allowing sale to proceed: $e');
      return {
        'valid': true,
        'message': 'Stock check skipped (catalog unavailable)',
        'stock_check_skipped': true,
      };
    }
  }

  static void clearInFlight() => _pendingSales.clear();

  static Future<void> _persistToLocalHistory({
    required SharedPreferences prefs,
    required String saleId,
    required String customerName,
    required String customerPhone,
    required List<Map<String, dynamic>> items,
    required double grandTotal,
    required double paidAmount,
    required bool withTax,
    required Map<String, dynamic> totals,
    String paymentMethod = 'Cash',
    String syncStatus = 'synced',
  }) async {
    List<dynamic> history = await LocalStorageService.loadSales();

    int existingIndex = history.indexWhere((s) {
      if (s is! Map) return false;
      final id = (s['sale_id'] ?? s['invoice_number'] ?? s['id'] ?? '').toString();
      return id == saleId;
    });

    final String safePhone = customerPhone.isNotEmpty
        ? customerPhone
        : 'GUEST_${saleId.length >= 6 ? saleId.substring(saleId.length - 6) : saleId.padLeft(6, '0')}';

    final existingSale = existingIndex >= 0
      ? Map<String, dynamic>.from(history[existingIndex] as Map)
      : null;
    final String saleTimestamp = DateTime.now().toUtc().toIso8601String();
    final String businessDate = (existingSale?['business_date'] ??
        existingSale?['sale_date'] ??
        existingSale?['invoice_date'] ??
        existingSale?['date'] ??
        saleTimestamp)
      .toString();

    final List<Map<String, dynamic>> normalizedItems = items.map((item) {
      final double price = (item['unit_price'] ?? item['price'] ?? 0.0) is num
          ? (item['unit_price'] ?? item['price'] ?? 0.0).toDouble()
          : double.tryParse((item['unit_price'] ?? item['price'] ?? '0').toString()) ?? 0.0;
      final double qty = (item['quantity'] ?? item['qty'] ?? 1) is num
          ? (item['quantity'] ?? item['qty'] ?? 1).toDouble()
          : double.tryParse((item['quantity'] ?? item['qty'] ?? '1').toString()) ?? 1.0;
      final double lineTotal = (item['line_total'] ?? item['total']) is num
          ? (item['line_total'] ?? item['total']).toDouble()
          : CurrencyManager.multiply(price, qty);

      return {
        ...item,
        'price': price,
        'price_str': price.toString(),
        'unit_price': price,
        'qty': qty,
        'quantity': qty,
        'qty_str': qty.toString(),
        'total': lineTotal,
        'line_total': lineTotal,
        'total_with_tax': lineTotal,
        'product': item['product_name'] ?? item['product'] ?? item['item'] ?? '',
        'name': item['product_name'] ?? item['product'] ?? item['item'] ?? '',
        'item': item['product_name'] ?? item['product'] ?? item['item'] ?? '',
      };
    }).toList();

    final userId = prefs.getInt('user_id') ?? prefs.getInt('userId');

    final Map<String, dynamic> saleRecord = {
      'sale_id': saleId,
      'offline_id': saleId,
      'invoice_number': (invoiceNumber ?? saleId),
      'bill_number': (invoiceNumber ?? saleId),
      'invoice_display_number': (invoiceNumber ?? saleId),
      'created_at': existingSale?['created_at'] ?? saleTimestamp,
      'sale_timestamp': existingSale?['sale_timestamp'] ?? (existingSale?['created_at'] ?? saleTimestamp),
      'updated_at': saleTimestamp,
      'user_id': userId,
      'sync_status': syncStatus,
      'pending_sync': syncStatus != 'synced',
      'sync_attempts': 0,
      'last_sync_attempt': null,
      'backend_id': existingSale?['backend_id'],
      'is_deleted': false,
      'customer_name': customerName.isNotEmpty ? customerName : 'Guest Customer',
      'customer_phone': customerPhone,
      'guest_id': safePhone,
      'items': normalizedItems,
      'business_date': businessDate,
      'subtotal': totals['subtotal'].toString(),
      'total': grandTotal.toString(),
      'total_amount': grandTotal,
      'paid_amount': paidAmount.toString(),
      'payment_status': paymentStatusFor(paidAmount, grandTotal),
      'gst_applied': withTax,
      'payment_method': paymentMethod,
    };

    if (existingIndex >= 0) {
      history[existingIndex] = {
        ...existingSale!,
        ...saleRecord,
        'updated_at': saleTimestamp,
      };
    } else {
      history.add(saleRecord);
    }

    if (history.length > 5000) {
      history = history.sublist(history.length - 5000);
    }
    await LocalStorageService.saveSales(history);
    if (kDebugMode) debugPrint('📝 Created local sale with sync metadata: $saleId');
  }
}