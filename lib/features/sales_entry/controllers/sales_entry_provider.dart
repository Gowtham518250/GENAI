import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
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
  String? _draftBillNumber;
  String? lastCompletedBillNumber;
  String? lastCreditError;

  String? get draftBillNumber => _draftBillNumber;

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

  bool _canUseOfflineVoiceFallback(String transcript, String languageCode) {
    final language = languageCode.trim().toLowerCase().replaceAll('_', '-');
    final baseLanguage = language.split('-').first;
    if (baseLanguage.isNotEmpty && !{'auto', 'en', 'und'}.contains(baseLanguage)) {
      return false;
    }
    if (RegExp(r'[^\x00-\x7F]').hasMatch(transcript)) return false;
    const cues = {
      'rendu', 'moodu', 'nalugu', 'biyyam', 'biyam', 'palu', 'paalu',
      'noone', 'kavali', 'cheyyandi', 'yaabhai', 'iravai', 'chawal',
      'chaval', 'doodh', 'dudh', 'cheeni', 'shakkar', 'pachaas',
      'pachis', 'kilolu', 'rupay', 'paani', 'neeru', 'thanni', 'ennai',
      'nenu', 'naaku', 'naku', 'ivvandi', 'cheppandi',
    };
    final words = transcript.toLowerCase().split(RegExp(r'[^a-z0-9]+')).toSet();
    return words.intersection(cues).isEmpty;
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

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('Voice billing request failed (HTTP ${response.statusCode})');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('Invalid voice billing response');
      }
      _applyVoiceBillingPayload(Map<String, dynamic>.from(decoded));
      return;

    } catch (error) {
      if (kDebugMode) {
        debugPrint('Groq voice billing unavailable; considering safe local parsing: $error');
      }

      if (!_canUseOfflineVoiceFallback(transcript, languageCode)) {
        lastVoiceMessage =
            'Voice translation is unavailable, so I did not add this item or change stock. '
            'Reconnect and retry so the spoken product can be translated to English first.';
        notifyListeners();
        return;
      }

      // Offline fallback only processes English text. Unknown English products can
      // be added as custom lines, but only exact catalog matches get product IDs.
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

        final untrackedItems = <String>[];
        final missingPriceItems = <String>[];
        for (final item in localParsed) {
          final spokenName = (item['item'] ?? '').toString().trim();
          if (spokenName.isEmpty) continue;
          final matchedInventory = inventory.where(
            (product) => normalize((product['name'] ?? '').toString()) == normalize(spokenName),
          );
          final knownProduct = matchedInventory.isEmpty ? null : matchedInventory.first;
          final quantity = double.tryParse((item['qty'] ?? '').toString()) ?? 1;
          final parsedPrice = double.tryParse((item['price'] ?? '').toString()) ?? 0;
          if (quantity <= 0 || !quantity.isFinite || parsedPrice < 0 || !parsedPrice.isFinite) continue;
          final catalogPrice = double.tryParse(
                (knownProduct?['price'] ?? knownProduct?['unit_price'] ?? knownProduct?['selling_price'] ?? '').toString(),
              ) ??
              0;
          final price = parsedPrice > 0 ? parsedPrice : (catalogPrice > 0 ? catalogPrice : 0.0);
          if (knownProduct == null) untrackedItems.add(spokenName);
          if (price <= 0) missingPriceItems.add(spokenName);

          safeItems.add(
            SalesItem(
              id: '${DateTime.now().microsecondsSinceEpoch}_${safeItems.length}',
              itemName: knownProduct?['name']?.toString() ?? spokenName,
              productId: knownProduct == null
                  ? null
                  : int.tryParse((knownProduct['id'] ?? knownProduct['product_id'] ?? '').toString()),
              quantity: quantity,
              price: price,
            ),
          );
        }

        if (safeItems.isNotEmpty) {
          _appendVoiceDraftItems(safeItems);
          final notes = <String>[
            'Groq could not be reached. I added ${safeItems.length} English item(s) to the draft; verify before saving.',
            if (untrackedItems.isNotEmpty)
              'Not in inventory (no stock deduction): ${untrackedItems.take(4).join(', ')}.',
            if (missingPriceItems.isNotEmpty)
              'Enter a selling price for: ${missingPriceItems.take(4).join(', ')}.',
          ];
          lastVoiceMessage = notes.join(' ');
        } else {
          lastVoiceMessage = 'Voice AI is temporarily unavailable, and no reliable product line was recognized. Please retry or enter it manually.';
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

  /// Recordings use Groq Whisper before catalog-grounded line-item extraction.
  /// This is one client upload; the backend performs transcription and parsing.
  Future<void> processVoiceRecording(
    String audioPath, {
    String languageCode = 'auto',
  }) async {
    isVoiceProcessing = true;
    lastVoiceMessage = null;
    notifyListeners();

    try {
      if (!await File(audioPath).exists()) {
        throw Exception('The recording file could not be found. Please record again.');
      }
      final filename = audioPath.split(Platform.pathSeparator).last;
      final multipartFile = await http.MultipartFile.fromPath(
        'audio',
        audioPath,
        filename: filename,
      );
      final streamedResponse = await ApiClient.postMultipart(
        ApiClient.voiceBillingAudioEndpoint,
        {'language_code': languageCode},
        files: [multipartFile],
        timeout: const Duration(seconds: 90),
      );
      final response = await http.Response.fromStream(streamedResponse);
      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final detail = decoded is Map ? (decoded['detail'] ?? decoded['message']) : null;
        throw Exception(
          detail?.toString().trim().isNotEmpty == true
              ? detail.toString()
              : 'Voice billing failed (HTTP ${response.statusCode}). Please retry or enter the item manually.',
        );
      }
      if (decoded is! Map) {
        throw const FormatException('Groq returned an invalid voice billing response.');
      }
      _applyVoiceBillingPayload(Map<String, dynamic>.from(decoded));
    } catch (error) {
      if (kDebugMode) debugPrint('Groq audio voice billing failed: $error');
      lastVoiceMessage = error
          .toString()
          .replaceFirst(RegExp(r'^Exception:\s*'), '')
          .trim();
      if (lastVoiceMessage == null || lastVoiceMessage!.isEmpty) {
        lastVoiceMessage = 'Voice billing could not process the recording. Please retry.';
      }
      notifyListeners();
    } finally {
      isVoiceProcessing = false;
      notifyListeners();
    }
  }

  void _applyVoiceBillingPayload(Map<String, dynamic> decoded) {
    final rawItems = decoded['items'];
    final parsedItems = <SalesItem>[];
    final priceWarningProducts = <String>[];
    final stockWarningProducts = <String>[];
    final untrackedProducts = <String>[];
    final missingPriceProducts = <String>[];

    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map) continue;
        final name = (raw['product_name_en'] ?? raw['product_name'] ?? raw['item'] ?? '')
            .toString()
            .trim();
        final quantity = double.tryParse((raw['quantity'] ?? raw['qty'] ?? '').toString());
        final parsedPrice = double.tryParse((raw['unit_price'] ?? raw['price'] ?? '').toString());
        final priceMissing = raw['price_missing'] == true;
        final confidence = double.tryParse((raw['confidence'] ?? '1').toString()) ?? 0;
        if (name.isEmpty ||
            quantity == null ||
            !quantity.isFinite ||
            quantity <= 0 ||
            !confidence.isFinite ||
            confidence < 0.72 ||
            (parsedPrice == null && !priceMissing) ||
            (parsedPrice != null && (!parsedPrice.isFinite || parsedPrice < 0)) ||
            (parsedPrice != null && parsedPrice <= 0 && !priceMissing)) {
          continue;
        }

        final price = parsedPrice ?? 0.0;
        final rawProductId = int.tryParse((raw['product_id'] ?? '').toString());
        final declaredCatalogMatch = raw['catalog_matched'];
        final isCatalogMatched = declaredCatalogMatch == true ||
            (declaredCatalogMatch == null && rawProductId != null && rawProductId > 0);
        final productId = isCatalogMatched && rawProductId != null && rawProductId > 0
            ? rawProductId
            : null;

        if ((raw['price_warning'] ?? '').toString().trim().isNotEmpty) {
          priceWarningProducts.add(name);
        }
        if (raw['stock_warning'] == true && productId != null) {
          stockWarningProducts.add(name);
        }
        if (productId == null) untrackedProducts.add(name);
        if (priceMissing || price <= 0) missingPriceProducts.add(name);

        parsedItems.add(
          SalesItem(
            id: '${DateTime.now().microsecondsSinceEpoch}_${parsedItems.length}',
            itemName: name,
            productId: productId,
            quantity: quantity,
            price: price,
          ),
        );
      }
    }

    if (parsedItems.isNotEmpty) _appendVoiceDraftItems(parsedItems);

    final clarification = (decoded['clarification_question'] ?? '').toString().trim();
    final needsClarification = decoded['needs_clarification'] == true;
    if (parsedItems.isNotEmpty) {
      final reviewNotes = <String>[
        if (priceWarningProducts.isNotEmpty)
          'Verify price for: ${priceWarningProducts.take(3).join(', ')}.',
        if (stockWarningProducts.isNotEmpty)
          'Quantity exceeds recorded stock for: ${stockWarningProducts.take(3).join(', ')}.',
        if (untrackedProducts.isNotEmpty)
          'Not in inventory (no stock deduction): ${untrackedProducts.take(4).join(', ')}.',
        if (missingPriceProducts.isNotEmpty)
          'Enter a selling price for: ${missingPriceProducts.take(4).join(', ')} before saving.',
      ].join(' ');
      final transcript = (decoded['transcript'] ?? '').toString().trim();
      final english = (decoded['interpreted_text_en'] ?? '').toString().trim();
      final heardPrefix = transcript.isEmpty ? '' : 'Heard: "$transcript". ';
      final englishPrefix = english.isEmpty ? '' : 'English: "$english". ';
      final confirmation =
          '${heardPrefix}${englishPrefix}Added ${parsedItems.length} item(s) to the sale draft. Check every product, quantity and price before saving. ${reviewNotes}'
              .trim();
      lastVoiceMessage = needsClarification && clarification.isNotEmpty
          ? '${confirmation} ${clarification}'.trim()
          : confirmation;
    } else {
      lastVoiceMessage = clarification.isNotEmpty
          ? clarification
          : 'I could not confidently identify a product and quantity. Please retry or enter the item manually.';
    }
    notifyListeners();
  }

  void _appendVoiceDraftItems(List<SalesItem> parsedItems) {
    if (entries.length == 1 && entries.first.itemName.trim().isEmpty) {
      entries.clear();
    }
    entries.addAll(parsedItems);
  }

  bool _validateSaleDraftPrices() {
    final incomplete = entries.where((entry) {
      final name = entry.itemName.trim();
      if (name.isEmpty || name.toLowerCase() == 'unknown' || name.toLowerCase() == 'unknown item') {
        return false;
      }
      return !entry.price.isFinite ||
          entry.price <= 0 ||
          !entry.quantity.isFinite ||
          entry.quantity <= 0;
    }).toList();
    if (incomplete.isEmpty) return true;

    lastVoiceMessage =
        "Enter a positive selling price and quantity for: ${incomplete.take(4).map((entry) => entry.itemName).join(', ')} before saving.";
    notifyListeners();
    return false;
  }

  Future<bool> submitSale() async {
    if (entries.isEmpty) return false;
    if (!_validateSaleDraftPrices()) return false;
    if (totalAmount <= 0) return false;

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
          'product_id': actualProductId > 0 ? actualProductId : null,
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

      final billNumber = await ensureDraftBillNumber();
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
        paymentMethod: selectedPaymentMethod,
        invoiceNumber: billNumber,
      );

      if (result['success'] == true) {
        lastCompletedBillNumber = (result['invoiceNumber'] ?? result['invoice_number'] ?? billNumber).toString();
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

  String? _normalizeKhataPhone(String value) {
    var digits = value.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length == 12 && digits.startsWith('91')) {
      digits = digits.substring(2);
    } else if (digits.length == 11 && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    if (digits.isEmpty) return null;
    if (digits.length != 10 || !RegExp(r'^[6-9][0-9]{9}$').hasMatch(digits)) {
      return null;
    }
    return digits;
  }

  Future<bool> saveAsCredit() async {
    lastCreditError = null;
    if (isSaving) {
      lastCreditError = 'A sale is already being saved. Please wait.';
      return false;
    }
    if (entries.isEmpty) {
      lastCreditError = 'Add at least one item before saving a credit sale.';
      return false;
    }
    if (!_validateSaleDraftPrices()) {
      lastCreditError = 'Check the item quantities and prices before saving.';
      return false;
    }
    if (totalAmount <= 0) {
      lastCreditError = 'The credit sale total must be greater than zero.';
      return false;
    }

    final customerName = customerNameController.text.trim();
    final rawPhone = customerPhoneController.text.trim();
    final normalizedPhone = _normalizeKhataPhone(rawPhone);
    if (customerName.isEmpty) {
      lastCreditError = 'Enter the customer name for a Credit / Borrow sale.';
      return false;
    }
    if (rawPhone.isNotEmpty && normalizedPhone == null) {
      lastCreditError = 'Enter a valid 10-digit Indian mobile number, or leave phone blank.';
      return false;
    }
    // Name-only customers are supported by Khata. When present, a phone is
    // stored in canonical 10-digit form so invoices and customer rows reconcile.
    final customerPhone = normalizedPhone ?? '';

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
          debugPrint('Product is untracked or unmatched: ${e.itemName}; submitting without stock deduction');
        }

        itemsPayload.add({
          'itemName': e.itemName,
          'product_id': actualProductId > 0 ? actualProductId : null,
          'quantity': e.quantity,
          'price': e.price,
          'gst': e.gst,
          'discount': e.discount,
          'total': e.finalAmount,
        });
      }

      if (itemsPayload.isEmpty) {
        lastCreditError = 'Add a valid product with a positive price and quantity.';
        return false;
      }

      final billNumber = await ensureDraftBillNumber();
      final result = await SaleService.submitSale(
        saleId: DateTime.now().millisecondsSinceEpoch.toString(),
        items: itemsPayload,
        grandTotal: totalAmount,
        paidAmount: 0.0,
        customerName: customerName,
        customerPhone: customerPhone,
        withTax: withTax,
        totals: {
          'subtotal': subtotalAmount,
          'cgst': withTax ? subtotalAmount * 0.09 : 0.0,
          'sgst': withTax ? subtotalAmount * 0.09 : 0.0,
        },
        paymentMethod: 'Credit',
        isBorrow: true,
        invoiceNumber: billNumber,
      );

      if (result['success'] == true) {
        lastCompletedBillNumber = (result['invoiceNumber'] ?? result['invoice_number'] ?? billNumber).toString();
        // The invoice/sale record is the single source of truth for outstanding
        // credit. Do not also append the same debt to a separate local ledger:
        // that mirror could drift, inflate customer credit limits, or be counted
        // again by older screens after retries/restoration.
        _clearForm();
        return true;
      }

      lastCreditError = (result['message'] ?? result['error'] ?? 'Credit sale could not be saved. Please try again.')
          .toString()
          .trim();
      if (lastCreditError!.isEmpty) {
        lastCreditError = 'Credit sale could not be saved. Please try again.';
      }
      return false;
    } catch (e) {
      lastCreditError = 'Credit sale could not be saved. Check your connection and try again.';
      if (kDebugMode) debugPrint('Error saving sale as credit: $e');
      return false;
    } finally {
      isSaving = false;
      notifyListeners();
    }
  }

  void _clearForm() {
    entries.clear();
    customerNameController.clear();
    customerPhoneController.clear();
    _draftBillNumber = null;
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

      String normalize(String value) => value
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final normalizedName = normalize(productName);
      for (var product in products) {
        final productDbName = normalize(
          (product['product_name'] ?? product['name'] ?? '').toString(),
        );
        if (productDbName.isNotEmpty && productDbName == normalizedName) {
          return int.tryParse(
                (product['id'] ?? product['product_id'] ?? '').toString(),
              ) ??
              0;
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

  /// Reuse the same customer-facing number for preview, saving, printing and sharing.
  Future<String> ensureDraftBillNumber() async {
    if (_draftBillNumber != null && _draftBillNumber!.isNotEmpty) return _draftBillNumber!;

    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getInt('user_id') ?? prefs.getInt('userId') ?? 0;
    final key = userId > 0 ? 'last_bill_number_$userId' : 'last_bill_number';
    var current = prefs.getInt(key) ?? 0;

    // Include existing local invoices so clearing app cache preferences cannot restart numbering.
    try {
      final sales = await LocalStorageService.loadSales();
      for (final raw in sales) {
        if (raw is! Map) continue;
        final rawBill = raw['bill_number'] ?? raw['invoice_number'] ?? raw['invoice_display_number'] ?? '';
        final match = RegExp(r'BILL-(\d+)', caseSensitive: false).firstMatch(rawBill.toString());
        final sequence = int.tryParse(match?.group(1) ?? '') ?? 0;
        if (sequence > current) current = sequence;
      }
    } catch (error) {
      if (kDebugMode) debugPrint('Could not read local bill history: $error');
    }

    // The backend sequence wins when reachable; local/offline billing still works if it is not.
    try {
      final response = await ApiClient.getJson('/api/invoices/next-bill-number');
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final sequence = int.tryParse(decoded['highest_bill_number']?.toString() ?? '0') ?? 0;
          if (sequence > current) current = sequence;
        }
      }
    } catch (error) {
      if (kDebugMode) debugPrint('Backend bill sequence unavailable; using local sequence: $error');
    }

    final next = current + 1;
    await prefs.setInt(key, next);
    if (userId <= 0) await prefs.setInt('last_bill_number', next);
    _draftBillNumber = 'BILL-' + next.toString().padLeft(4, '0');
    notifyListeners();
    return _draftBillNumber!;
  }

  Future<void> generateBillPreview() async {
    isGeneratingBill = true;
    notifyListeners();
    try {
      await ensureDraftBillNumber();
    } finally {
      isGeneratingBill = false;
      notifyListeners();
    }
  }
}
