
import 'dart:math' as math;

import 'product_catalog_service.dart';
import 'roman_indian_voice_normalizer.dart';
import 'voice_nlp_engine.dart';

/// Production voice-billing line produced after speech normalization,
/// multilingual parsing, catalog resolution, and price/unit enrichment.
class VoiceBillingLine {
  final String name;
  final double quantity;
  final String unit;
  final double price;
  final double confidence;
  final bool catalogMatched;
  final String priceSource; // spoken | catalog | missing
  final String? barcode;
  final double? gst;
  final String? priceWarning;

  const VoiceBillingLine({
    required this.name,
    required this.quantity,
    required this.unit,
    required this.price,
    required this.confidence,
    required this.catalogMatched,
    required this.priceSource,
    this.barcode,
    this.gst,
    this.priceWarning,
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        'product_name': name,
        'qty': quantity,
        'quantity': quantity,
        'unit': unit,
        'price': price,
        'total': quantity * price,
        'confidence': confidence,
        'catalog_matched': catalogMatched,
        'price_source': priceSource,
        'price_missing': price <= 0,
        if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
        if (gst != null) 'gst': gst,
        if (priceWarning != null && priceWarning!.isNotEmpty)
          'price_warning': priceWarning,
      };
}

class VoiceBillingParseResult {
  final String normalizedTranscript;
  final String languageCode;
  final List<VoiceBillingLine> lines;
  final List<String> warnings;

  const VoiceBillingParseResult({
    required this.normalizedTranscript,
    required this.languageCode,
    required this.lines,
    required this.warnings,
  });

  bool get hasItems => lines.isNotEmpty;
  bool get hasMissingPrices => lines.any((line) => line.price <= 0);
  double get averageConfidence => lines.isEmpty
      ? 0
      : lines.map((e) => e.confidence).reduce((a, b) => a + b) / lines.length;
}

/// Single production parsing path for the full-bill voice experience.
///
/// Design goals:
/// - Normalize Romanized Indian speech and native-script speech first.
/// - Let the existing multilingual engine do deterministic quantity/price parsing.
/// - Resolve products against the store's learned catalog before exposing them
///   to the bill.
/// - Never invent a price when neither the user nor the catalog supplied one.
/// - Preserve the spoken price when the cashier explicitly says one.
/// - Return warnings rather than silently changing a suspicious spoken price.
/// - Merge only genuine duplicate lines.
class ProductionVoiceBillingService {
  static Future<VoiceBillingParseResult> parse({
    required String transcript,
    required String localeCode,
    required ProductCatalogService catalogService,
    List<Map<String, dynamic>> knownProducts = const [],
  }) async {
    final raw = transcript.trim();
    if (raw.isEmpty) {
      return VoiceBillingParseResult(
        normalizedTranscript: '',
        languageCode: localeCode,
        lines: const [],
        warnings: const [
          'No speech was captured. Try speaking the product and quantity again.'
        ],
      );
    }

    final normalized = RomanIndianVoiceNormalizer.normalize(
      raw,
      locale: localeCode,
    ).trim();

    final parsed = VoiceNlpEngineV2.parse(
      normalized,
      localeCode,
      catalog: knownProducts,
      deduplicate: false,
    );

    if (parsed.isEmpty) {
      return VoiceBillingParseResult(
        normalizedTranscript: normalized,
        languageCode: localeCode,
        lines: const [],
        warnings: const [
          'I could not confidently identify a bill item. Try: "2 kg rice 50" or "sugar 60".'
        ],
      );
    }

    final enriched = <VoiceBillingLine>[];
    final warnings = <String>[];

    for (final item in parsed) {
      if (item.name.trim().isEmpty || item.qty <= 0) {
        continue;
      }

      // The shop's current inventory is authoritative. Never allow
      // a persistent learned/global alias (for example "enna" -> Oil) to
      // override a product that exists in this shop's catalog.
      final shopProduct = _findShopProduct(
        knownProducts,
        item.name,
      );

      final learnedMatch = shopProduct == null
          ? catalogService.findBest(
              item.name,
              minScore: 0.72,
            )
          : null;

      final canonicalName = shopProduct?['name']?.toString() ??
          shopProduct?['product_name']?.toString() ??
          learnedMatch?.canonicalName ??
          ((item.catalogMatchName?.trim().isNotEmpty ?? false)
              ? item.catalogMatchName!.trim()
              : item.name.trim());

      final product = shopProduct ??
          _findKnownProduct(
            knownProducts,
            canonicalName,
            learnedMatch?.canonicalName,
          );

      final catalogPrice = _firstPositiveDouble([
        product?['price'],
        product?['selling_price'],
        product?['sale_price'],
        learnedMatch?.defaultPrice,
        item.catalogPrice,
      ]);

      final spokenPrice = item.priceWasSpoken && item.price > 0
          ? item.price
          : null;
      final finalPrice = spokenPrice ?? catalogPrice ?? 0.0;

      final unit = _cleanUnit(
        item.unit,
        fallback: product?['unit']?.toString() ??
            product?['uom']?.toString() ??
            learnedMatch?.defaultUnit ??
            '',
      );

      final warning = _priceWarning(
        productName: canonicalName,
        spokenPrice: spokenPrice,
        catalogPrice: catalogPrice,
      );

      if (warning != null) {
        warnings.add(warning);
      }

      enriched.add(
        VoiceBillingLine(
          name: canonicalName,
          quantity: item.qty,
          unit: unit,
          price: finalPrice,
          confidence: item.confidenceScore,
          catalogMatched:
              product != null || learnedMatch != null || item.catalogMatchName != null,
          priceSource: spokenPrice != null
              ? 'spoken'
              : catalogPrice != null && catalogPrice > 0
                  ? 'catalog'
                  : 'missing',
          barcode: product?['barcode']?.toString() ??
              product?['sku']?.toString() ??
              product?['product_code']?.toString(),
          gst: _firstPositiveDouble([
            product?['gst_percent'],
            product?['gst'],
            product?['tax_percent'],
          ]),
          priceWarning: warning,
        ),
      );
    }

    final deduped = _mergeDuplicates(enriched);

    if (deduped.isEmpty) {
      warnings.add('No valid bill lines were produced from the speech.');
    }

    return VoiceBillingParseResult(
      normalizedTranscript: normalized,
      languageCode: localeCode,
      lines: deduped,
      warnings: warnings.toSet().toList(),
    );
  }

  static Map<String, dynamic>? _findShopProduct(
    List<Map<String, dynamic>> products,
    String spokenName,
  ) {
    if (products.isEmpty || spokenName.trim().isEmpty) return null;

    String normalize(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\\u0900-\\u0d7f\\u0980-\\u09ff\\u0a00-\\u0aff\\u0b80-\\u0bff\\u0c00-\\u0c7f\\u0c80-\\u0cff\\u0d00-\\u0d7f\\s]'), ' ')
        .replaceAll(RegExp(r'\\s+'), ' ')
        .trim();

    Set<String> tokens(String value) => normalize(value)
        .split(RegExp(r'\\s+'))
        .where((token) => token.length >= 3)
        .toSet();

    final query = normalize(spokenName);

    // Exact shop-product name first.
    for (final product in products) {
      final names = [
        product['name'],
        product['product_name'],
        product['canonical_name'],
      ].whereType<String>().map(normalize).where((v) => v.isNotEmpty);

      if (names.any((name) => name == query)) return product;
    }

    final queryTokens = tokens(query);
    if (queryTokens.isEmpty) return null;

    final scored = <MapEntry<Map<String, dynamic>, double>>[];

    for (final product in products) {
      final names = [
        product['name'],
        product['product_name'],
        product['canonical_name'],
      ].whereType<String>().map(normalize).where((v) => v.isNotEmpty);

      var best = 0.0;
      for (final name in names) {
        final productTokens = tokens(name);
        if (productTokens.isEmpty) continue;

        final overlap = queryTokens.intersection(productTokens);
        if (overlap.isEmpty) continue;

        final tokenScore =
            overlap.length / queryTokens.length;
        final coverage =
            overlap.length / productTokens.length;
        final score = (tokenScore * 0.65) + (coverage * 0.35);
        if (score > best) best = score;
      }

      if (best > 0) {
        scored.add(MapEntry(product, best));
      }
    }

    scored.sort((a, b) => b.value.compareTo(a.value));
    if (scored.isEmpty) return null;

    final best = scored.first;
    final second = scored.length > 1 ? scored[1].value : 0.0;

    // High confidence exact token/phrase match with a useful margin.
    if (best.value >= 0.72 && (best.value - second) >= 0.10) {
      return best.key;
    }

    return null;
  }


  static Map<String, dynamic>? _findKnownProduct(
    List<Map<String, dynamic>> products,
    String canonicalName, [
    String? fallbackName,
  ]) {
    if (products.isEmpty) return null;

    final candidates = <String>{
      canonicalName.trim().toLowerCase(),
      if (fallbackName != null && fallbackName.trim().isNotEmpty)
        fallbackName.trim().toLowerCase(),
    }..removeWhere((value) => value.isEmpty);

    for (final product in products) {
      final names = <String>{
        (product['name'] ?? '').toString().trim().toLowerCase(),
        (product['product_name'] ?? '').toString().trim().toLowerCase(),
        (product['canonical_name'] ?? '').toString().trim().toLowerCase(),
      }..removeWhere((value) => value.isEmpty);

      if (names.any(candidates.contains)) {
        return product;
      }
    }

    final qTokens = _tokens(canonicalName);
    if (qTokens.length >= 2) {
      Map<String, dynamic>? best;
      double bestScore = 0;

      for (final product in products) {
        final name =
            (product['name'] ?? product['product_name'] ?? '').toString();
        final productTokens = _tokens(name);
        if (productTokens.isEmpty) continue;

        final intersection = qTokens.intersection(productTokens).length;
        final union = qTokens.union(productTokens).length;
        final score = union == 0 ? 0.0 : intersection / union;

        if (score > bestScore) {
          bestScore = score;
          best = product;
        }
      }

      if (best != null && bestScore >= 0.72) {
        return best;
      }
    }

    return null;
  }

  static Set<String> _tokens(String value) => value
      .toLowerCase()
      .replaceAll(
        RegExp(r'[^a-z0-9\u0900-\u097f\u0c00-\u0c7f\u0b80-\u0bff\s]'),
        ' ',
      )
      .split(RegExp(r'\s+'))
      .where((value) => value.length >= 2)
      .toSet();


  static double? _firstPositiveDouble(Iterable<dynamic> values) {
    for (final value in values) {
      final parsed = value is num
          ? value.toDouble()
          : double.tryParse(value?.toString().trim() ?? '');
      if (parsed != null && parsed > 0 && parsed.isFinite) {
        return parsed;
      }
    }
    return null;
  }

  static String _cleanUnit(String value, {String fallback = ''}) {
    final raw = value.trim();
    final normalized = UnitNormalizer.normalize(raw);
    if (normalized.isNotEmpty) return normalized;

    final normalizedFallback = UnitNormalizer.normalize(fallback.trim());
    if (normalizedFallback.isNotEmpty) return normalizedFallback;

    return raw.isNotEmpty ? raw : 'pc';
  }

  static String? _priceWarning({
    required String productName,
    required double? spokenPrice,
    required double? catalogPrice,
  }) {
    if (spokenPrice == null || catalogPrice == null || catalogPrice <= 0) {
      return null;
    }

    final delta = (spokenPrice - catalogPrice).abs();
    final ratio = delta / catalogPrice;

    if (ratio >= 0.50 && delta >= 10) {
      return 'Spoken price ₹' +
          spokenPrice.toStringAsFixed(0) +
          ' for ' +
          productName +
          ' differs from catalog price ₹' +
          catalogPrice.toStringAsFixed(0) +
          '. Verify before billing.';
    }

    return null;
  }

  static List<VoiceBillingLine> _mergeDuplicates(
    List<VoiceBillingLine> lines,
  ) {
    final merged = <VoiceBillingLine>[];

    for (final line in lines) {
      final idx = merged.indexWhere((existing) {
        final sameName =
            existing.name.trim().toLowerCase() == line.name.trim().toLowerCase();
        final sameUnit =
            existing.unit.trim().toLowerCase() == line.unit.trim().toLowerCase();
        final bothPriced = existing.price > 0 && line.price > 0;
        final samePrice = bothPriced
            ? (existing.price - line.price).abs() < 0.01
            : true;
        return sameName && sameUnit && samePrice;
      });

      if (idx < 0) {
        merged.add(line);
        continue;
      }

      final previous = merged[idx];
      final preferredPrice = line.price > 0 ? line.price : previous.price;
      final preferredSource =
          line.price > 0 ? line.priceSource : previous.priceSource;

      merged[idx] = VoiceBillingLine(
        name: previous.name,
        quantity: previous.quantity + line.quantity,
        unit: previous.unit.isNotEmpty ? previous.unit : line.unit,
        price: preferredPrice,
        confidence: math.max(previous.confidence, line.confidence),
        catalogMatched: previous.catalogMatched || line.catalogMatched,
        priceSource: preferredSource,
        barcode: previous.barcode ?? line.barcode,
        gst: previous.gst ?? line.gst,
        priceWarning: previous.priceWarning ?? line.priceWarning,
      );
    }

    return merged;
  }
}
