import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sales_item.dart';
import '../services/voice_nlp_service.dart';
import '../../../inventory_sync_service.dart';
import '../../../local_storage_service.dart';
import '../../../sale_service.dart';
import '../../../api_client.dart';

class SalesEntryProvider extends ChangeNotifier {
  List<SalesItem> entries = [];
  bool withTax = true;
  double paidAmount = 0.0;
  bool isOnlinePayment = false;
  String? paymentStatus;
  String selectedPaymentMethod = 'Cash';

  bool isSaving = false;
  bool isGeneratingBill = false;
  bool isVoiceProcessing = false;
  String? lastVoiceMessage;

  final TextEditingController customerPhoneController = TextEditingController();
  final TextEditingController customerNameController = TextEditingController();

  String shopName = 'My Shop';
  String shopLocation = '';
  String shopType = '';
  String shopPhone = '';
  String shopEmail = '';

  SalesEntryProvider() {
    _initializeEmptyRow();
  }

  void _initializeEmptyRow() {
    entries.add(SalesItem(id: DateTime.now().millisecondsSinceEpoch.toString()));
    notifyListeners();
  }

  double get totalAmount {
    double total = 0.0;
    for (var entry in entries) {
      total += entry.finalAmount;
    }
    return total;
  }

  double get subtotalAmount {
    double total = 0.0;
    for (var entry in entries) {
      total += entry.subtotal;
    }
    return total;
  }

  void addEntry() {
    entries.add(SalesItem(id: DateTime.now().millisecondsSinceEpoch.toString()));
    notifyListeners();
  }

  void removeEntry(int index) {
    if (entries.length > 1) {
      entries.removeAt(index);
      notifyListeners();
    }
  }

  void updateEntry(int index, SalesItem newItem) {
    if (index >= 0 && index < entries.length) {
      entries[index] = newItem;
      notifyListeners();
    }
  }

  void toggleTax() {
    withTax = !withTax;
    notifyListeners();
  }

  void setOnlinePayment(bool value) {
    isOnlinePayment = value;
    notifyListeners();
  }

  /// Parse recognized speech through the authenticated backend Groq extractor.
  /// The endpoint only returns validated draft line items; it never submits a sale.
  Future<void> processVoiceCommand(
    String text, {
    String languageCode = 'auto',
  }) async {
    final transcript = text.trim();
    if (transcript.isEmpty) {
      lastVoiceMessage = 'I did not hear a product. Please try again.';
      notifyListeners();
      return;
    }

    isVoiceProcessing = true;
    lastVoiceMessage = null;
    notifyListeners();

    try {
      final response = await ApiClient.postJson(
        ApiClient.voiceBillingParseEndpoint,
        {
          'transcript': transcript,
          'language_code': languageCode,
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is! Map) {
          throw const FormatException('Invalid voice billing response');
        }

        final rawItems = decoded['items'];
        final parsedItems = <SalesItem>[];
        if (rawItems is List) {
          for (final raw in rawItems) {
            if (raw is! Map) continue;
            final name = (raw['product_name'] ?? raw['item'] ?? '').toString().trim();
            final quantity = double.tryParse((raw['quantity'] ?? raw['qty'] ?? '').toString());
            final price = double.tryParse((raw['unit_price'] ?? raw['price'] ?? '').toString());
            final confidence = double.tryParse((raw['confidence'] ?? '1').toString()) ?? 0;
            // Enforce the backend confidence threshold again at the client boundary.
            if (name.isEmpty ||
                quantity == null ||
                !quantity.isFinite ||
                quantity <= 0 ||
                price == null ||
                !price.isFinite ||
                price <= 0 ||
                confidence < 0.72) {
              continue;
            }
            parsedItems.add(
              SalesItem(
                id: '${DateTime.now().microsecondsSinceEpoch}_${parsedItems.length}',
                itemName: name,
                productId: int.tryParse((raw['product_id'] ?? '').toString()),
                quantity: quantity,
                price: price,
              ),
            );
          }
        }

        if (parsedItems.isNotEmpty) {
          _appendVoiceDraftItems(parsedItems);
        }

        final clarification = (decoded['clarification_question'] ?? '').toString().trim();
        final needsClarification = decoded['needs_clarification'] == true;
        if (parsedItems.isNotEmpty) {
          final confirmation = 'Added ${parsedItems.length} item(s) to the sale draft. Check each product, quantity and price before saving.';
          lastVoiceMessage = needsClarification && clarification.isNotEmpty
              ? '$confirmation $clarification'
              : confirmation;
        } else {
          lastVoiceMessage = clarification.isNotEmpty
              ? clarification
              : 'I could not confidently match the spoken product to this shop\'s inventory. Please say the product name again or select it manually.';
        }
        notifyListeners();
        return;
      }

      throw Exception('Voice billing request failed (HTTP ${response.statusCode})');
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Groq voice billing unavailable; trying catalog-constrained local parsing: $error');
      }

      // Offline/AI-outage fallback. Only allow entries that the local catalog
      // matcher maps back to an exact inventory name; never add an unknown item.
      try {
        final rawInventory = await LocalStorageService.loadBackendProducts();
        final inventory = rawInventory.map((product) {
          final name = (product['name'] ??
                  product['product_name'] ??
                  product['itemName'] ??
                  '')
              .toString()
              .trim();
          final price = product['price'] ?? product['unit_price'] ?? product['selling_price'] ?? 0;
          return <String, dynamic>{...product, 'name': name, 'price': price};
        }).where((product) => (product['name'] ?? '').toString().isNotEmpty).toList();

        final localParsed = VoiceNlpService.parseMultipleItems(
          transcript,
          knownInventory: inventory,
        );
        final safeItems = <SalesItem>[];
        String normalize(String value) => value.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

        for (final item in localParsed) {
          final spokenName = (item['item'] ?? '').toString().trim();
          final matchedInventory = inventory.where(
            (product) => normalize((product['name'] ?? '').toString()) == normalize(spokenName),
          );
          if (matchedInventory.isEmpty) continue;
          final quantity = double.tryParse((item['qty'] ?? '').toString()) ?? 1;
          final price = double.tryParse((item['price'] ?? '').toString()) ?? 0;
          if (quantity <= 0 || !quantity.isFinite || price <= 0 || !price.isFinite) continue;
          safeItems.add(
            SalesItem(
              id: '${DateTime.now().microsecondsSinceEpoch}_${safeItems.length}',
              itemName: matchedInventory.first['name'].toString(),
              productId: int.tryParse((matchedInventory.first['id'] ?? matchedInventory.first['product_id'] ?? '').toString()),
              quantity: quantity,
              price: price,
            ),
          );
        }

        if (safeItems.isNotEmpty) {
          _appendVoiceDraftItems(safeItems);
          lastVoiceMessage = 'Groq could not be reached. I filled ${safeItems.length} catalog-matched item(s) using local parsing; carefully verify them before saving.';
        } else {
          lastVoiceMessage = 'Voice AI is temporarily unavailable, and no reliable local product match was found. Please retry or select the product manually.';
        }
      } catch (fallbackError) {
        if (kDebugMode) debugPrint('Local voice billing fallback failed: $fallbackError');
        lastVoiceMessage = 'Voice billing could not process this request. Please retry or enter the item manually.';
      }
      notifyListeners();
    } finally {
      isVoiceProcessing = false;
      notifyListeners();
    }
  }

  void _appendVoiceDraftItems(List<SalesItem> parsedItems) {
    if (entries.length == 1 && entries.first.itemName.trim().isEmpty) {
      entries.clear();
    }
    entries.addAll(parsedItems);
  }

  Future<bool> submitSale() async {
    if (entries.isEmpty || totalAmount <= 0) return false;

    isSaving = true;
    notifyListeners();

    try {
      await _ensureProductsAvailable();

      final itemsPayload = <Map<String, dynamic>>[];
      for (final e in entries.where((e) => e.itemName.isNotEmpty && e.itemName.trim() != 'Unknown' && e.price > 0)) {
        final actualProductId = e.productId != null && e.productId! > 0
            ? e.productId!
            : await _lookupProductIdByName(e.itemName);

        if (actualProductId == 0 && kDebugMode) {
          debugPrint('⚠️ Product lookup failed for: ${e.itemName}, submitting without stock deduction');
        }

        itemsPayload.add({
          'itemName': e.itemName,
          'product_id': actualProductId,
          'quantity': e.quantity,
          'price': e.price,
          'gst': e.gst,
          'discount': e.discount,
          'total': e.finalAmount,
        });
      }

      if (itemsPayload.isEmpty) {
        print('No valid items to submit');
        return false;
      }

      final result = await SaleService.submitSale(
        saleId: DateTime.now().millisecondsSinceEpoch.toString(),
        items: itemsPayload,
        grandTotal: totalAmount,
        paidAmount: totalAmount,
        customerName: customerNameController.text.trim(),
        customerPhone: customerPhoneController.text.trim(),
        withTax: withTax,
        totals: {
          'subtotal': subtotalAmount,
          'cgst': withTax ? subtotalAmount * 0.09 : 0.0,
          'sgst': withTax ? subtotalAmount * 0.09 : 0.0,
        },
        paymentMethod: isOnlinePayment ? 'Online' : 'Cash',
      );

      if (result['success'] == true) {
        _clearForm();
        return true;
      }
      return false;
    } catch (e) {
      print('Error submitting sale: ');
      return false;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<bool> saveAsCredit() async {
    if (entries.isEmpty || totalAmount <= 0) return false;

    isSaving = true;
    notifyListeners();

    try {
      await _ensureProductsAvailable();

      final itemsPayload = <Map<String, dynamic>>[];
      for (final e in entries.where((e) => e.itemName.isNotEmpty && e.itemName.trim() != 'Unknown' && e.price > 0)) {
        final actualProductId = await _lookupProductIdByName(e.itemName);

        if (actualProductId == 0 && kDebugMode) {
          debugPrint('⚠️ Product lookup failed for: ${e.itemName}, submitting without stock deduction');
        }

        itemsPayload.add({
          'itemName': e.itemName,
          'product_id': actualProductId,
          'quantity': e.quantity,
          'price': e.price,
          'gst': e.gst,
          'discount': e.discount,
          'total': e.finalAmount,
        });
      }

      if (itemsPayload.isEmpty) {
        print('No valid items to submit');
        return false;
      }

      final result = await SaleService.submitSale(
        saleId: DateTime.now().millisecondsSinceEpoch.toString(),
        items: itemsPayload,
        grandTotal: totalAmount,
        paidAmount: 0.0,
        customerName: customerNameController.text.trim(),
        customerPhone: customerPhoneController.text.trim(),
        withTax: withTax,
        totals: {
          'subtotal': subtotalAmount,
          'cgst': withTax ? subtotalAmount * 0.09 : 0.0,
          'sgst': withTax ? subtotalAmount * 0.09 : 0.0,
        },
        paymentMethod: 'Credit',
      );

      if (result['success'] == true) {
        await _addToCustomerLedger(
          customerName: customerNameController.text.trim(),
          customerPhone: customerPhoneController.text.trim(),
          amount: totalAmount,
          saleId: result['saleId']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
        );
        _clearForm();
        return true;
      }
      return false;
    } catch (e) {
      print('Error saving sale as credit: ');
      return false;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  Future<void> _addToCustomerLedger({
    required String customerName,
    required String customerPhone,
    required double amount,
    required String saleId,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final ledgerKey = 'khata_ledger';
      final ledgerData = prefs.getString(ledgerKey);
      List<Map<String, dynamic>> ledger = [];

      if (ledgerData != null) {
        try {
          ledger = List<Map<String, dynamic>>.from(
            jsonDecode(ledgerData).map((e) => Map<String, dynamic>.from(e)),
          );
        } catch (_) {}
      }

      final phone = customerPhone.isNotEmpty ? customerPhone : 'GUEST_${saleId.substring(saleId.length - 6)}';
      final name = customerName.isNotEmpty ? customerName : 'Guest Customer';

      ledger.add({
        'customer_name': name,
        'customer_phone': phone,
        'amount': amount,
        'type': 'CREDIT',
        'sale_id': saleId,
        'date': DateTime.now().toIso8601String(),
        'balance': amount,
      });

      await prefs.setString(ledgerKey, jsonEncode(ledger));

      final customersKey = 'customers';
      final customersData = prefs.getString(customersKey);
      List<Map<String, dynamic>> customers = [];

      if (customersData != null) {
        try {
          customers = List<Map<String, dynamic>>.from(
            jsonDecode(customersData).map((e) => Map<String, dynamic>.from(e)),
          );
        } catch (_) {}
      }

      final customerIndex = customers.indexWhere((c) => c['phone'] == phone);

      if (customerIndex >= 0) {
        customers[customerIndex]['credit_balance'] = (customers[customerIndex]['credit_balance'] as num? ?? 0) + amount;
        customers[customerIndex]['credit_limit'] = (customers[customerIndex]['credit_limit'] as num? ?? 0) + amount;
        customers[customerIndex]['last_transaction'] = DateTime.now().toIso8601String();
      } else {
        customers.add({
          'customer_name': name,
          'phone': phone,
          'email': '',
          'city': '',
          'credit_limit': amount,
          'credit_balance': amount,
          'total_purchases': amount,
          'last_purchase': DateTime.now().toIso8601String(),
          'purchase_count': 1,
        });
      }

      await prefs.setString(customersKey, jsonEncode(customers));
    } catch (e) {
      print('Error adding to customer ledger: ');
    }
  }

  void _clearForm() {
    entries.clear();
    customerNameController.clear();
    customerPhoneController.clear();
    _initializeEmptyRow();
  }

  @override
  void dispose() {
    customerNameController.dispose();
    customerPhoneController.dispose();
    super.dispose();
  }

  Future<int> _lookupProductIdByName(String productName) async {
    try {
      final products = await LocalStorageService.loadBackendProducts();

      if (products == null || products.isEmpty) {
        if (kDebugMode) debugPrint('⚠️ No products in local storage - product lookup will fail');
        return 0;
      }

      final normalizedName = productName.toLowerCase().trim();
      for (var product in products) {
        final productDbName = (product['product_name'] ?? product['name'] ?? '').toString().toLowerCase().trim();
        if (productDbName == normalizedName) {
          return int.tryParse(product['id']?.toString() ?? '0') ?? 0;
        }
      }

      for (var product in products) {
        final productDbName = (product['product_name'] ?? product['name'] ?? '').toString().toLowerCase().trim();
        if (productDbName.isNotEmpty && (productDbName.contains(normalizedName) || normalizedName.contains(productDbName))) {
          return int.tryParse(product['id']?.toString() ?? '0') ?? 0;
        }
      }

      if (kDebugMode) debugPrint('⚠️ Could not find product_id for product name: $productName');
      return 0;
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Error looking up product_id: $e');
      return 0;
    }
  }

  Future<void> _ensureProductsAvailable() async {
    try {
      final products = await LocalStorageService.loadBackendProducts();
      if (products.isEmpty) {
        if (kDebugMode) debugPrint('🔄 No products found, forcing inventory refresh...');
        await InventorySyncService.refreshAllInventory();
      }
    } catch (e) {
      if (kDebugMode) debugPrint('⚠️ Failed to ensure products available: $e');
    }
  }

  void setPaymentMethod(String method) {
    selectedPaymentMethod = method;
    isOnlinePayment = method == 'UPI';
    notifyListeners();
  }

  Future<void> generateBillPreview() async {
    isGeneratingBill = true;
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 500));
    isGeneratingBill = false;
    notifyListeners();
  }
}
