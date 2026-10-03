import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'api_client.dart';

class FmcgProduct {
  final String barcode;
  final String name;
  final double mrp;
  final double stateTaxModifier;
  final String? brand;
  final String? model;
  final String? category;
  final String? imageUrl;

  FmcgProduct({
    required this.barcode,
    required this.name,
    required this.mrp,
    this.stateTaxModifier = 1.0,
    this.brand,
    this.model,
    this.category,
    this.imageUrl,
  });

  double get adjustedPrice =>
      mrp > 0 ? (mrp * stateTaxModifier).roundToDouble() : 0;
}

class FmcgBarcodeService {
  static Future<FmcgProduct?> fetchProductFromCdn(
    String barcode,
    String stateCode,
  ) async {
    final clean = barcode.replaceAll(RegExp(r'\D'), '');

    if (![8, 12, 13, 14].contains(clean.length)) {
      if (kDebugMode) {
        debugPrint('🚫 Ignoring non-GTIN barcode: ' + clean);
      }
      return null;
    }

    try {
      final response = await ApiClient.getJson(
        '/api/inventory/barcode-lookup?barcode=' + clean,
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        if (kDebugMode) {
          debugPrint(
            'Barcode lookup failed: ' + response.statusCode.toString() +
                ' ' + response.body,
          );
        }
        return null;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['found'] != true) {
        if (kDebugMode) {
          debugPrint(
            'No real product match for barcode ' +
                clean +
                ': ' +
                (decoded is Map ? (decoded['message']?.toString() ?? 'unknown') : 'unknown'),
          );
        }
        return null;
      }

      final lowest =
          double.tryParse('${decoded['lowest_recorded_price'] ?? ''}') ?? 0;

      return FmcgProduct(
        barcode: decoded['barcode']?.toString() ?? clean,
        name: decoded['name']?.toString().trim() ?? '',
        mrp: lowest,
        brand: decoded['brand']?.toString(),
        model: decoded['model']?.toString(),
        category: decoded['category']?.toString(),
        imageUrl: decoded['image_url']?.toString(),
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Barcode lookup exception: ' + e.toString());
      }
      return null;
    }
  }
}