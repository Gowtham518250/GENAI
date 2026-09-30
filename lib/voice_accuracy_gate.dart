import 'voice_nlp_engine.dart';

enum VoiceGateDecision { autoAccept, requiresConfirmation, reject }

class VoiceGateReason {
  final String code;
  final String message;
  const VoiceGateReason(this.code, this.message);
}

class VoiceGateResult {
  final VoiceGateDecision decision;
  final List<VoiceGateReason> reasons;
  const VoiceGateResult({required this.decision, this.reasons = const []});
  bool get isAccepted => decision == VoiceGateDecision.autoAccept;
  bool get requiresConfirmation => decision == VoiceGateDecision.requiresConfirmation;
  bool get isRejected => decision == VoiceGateDecision.reject;
}

class VoiceAccuracyGate {
  VoiceAccuracyGate._();
  static const double autoAcceptThreshold = 0.90;
  static const double confirmationThreshold = 0.72;

  static const Set<String> _supportedUnits = {
    'kg', 'g', 'mg', 'l', 'ml', 'pc', 'pack', 'packet', 'box', 'bottle',
    'jar', 'tin', 'bag', 'sachet', 'pouch', 'tube', 'dozen',
  };

  static const Set<String> _invalidNames = {
    'a', 'an', 'the', 'and', 'or', 'in', 'at', 'on', 'of', 'to',
    'price', 'cost', 'amount', 'total', 'rupee', 'rupees', 'rs', 'inr',
  };

  static VoiceGateResult evaluate(
    ParsedItemV2 item, {
    required List<Map<String, dynamic>> catalog,
  }) {
    final structural = validateManualFields(
      name: item.name, qty: item.qty, price: item.price, unit: item.unit,
    );
    if (structural.isNotEmpty) {
      return VoiceGateResult(decision: VoiceGateDecision.reject, reasons: structural);
    }

    final confidence = item.confidenceScore;
    if (confidence < confirmationThreshold) {
      return const VoiceGateResult(
        decision: VoiceGateDecision.reject,
        reasons: [VoiceGateReason('LOW_CONFIDENCE', 'Voice interpretation is below the safe confidence threshold.')],
      );
    }

    final matchName = item.catalogMatchName ?? item.name;
    final exactMatches = _exactCatalogMatches(matchName, catalog);
    final ambiguity = _findCatalogAmbiguity(matchName, catalog);

    if (ambiguity.isAmbiguous && exactMatches.length != 1) {
      return VoiceGateResult(
        decision: VoiceGateDecision.requiresConfirmation,
        reasons: [
          const VoiceGateReason('AMBIGUOUS_PRODUCT', 'Multiple catalog products are similarly matched. Confirm the product before billing.'),
          VoiceGateReason(
            'AMBIGUOUS_CANDIDATES',
            'Possible matches: ' + ambiguity.topName! + ' or ' + ambiguity.secondName! + '.',
          ),
        ],
      );
    }

    final deterministicCatalogMatch = exactMatches.length == 1;
    final catalogPrice = deterministicCatalogMatch
        ? double.tryParse(exactMatches.first['price']?.toString() ?? '')
        : null;

    if (confidence >= autoAcceptThreshold &&
        deterministicCatalogMatch &&
        (item.price > 0 || (catalogPrice ?? 0) == 0)) {
      return const VoiceGateResult(decision: VoiceGateDecision.autoAccept);
    }

    return const VoiceGateResult(
      decision: VoiceGateDecision.requiresConfirmation,
      reasons: [VoiceGateReason('REVIEW_REQUIRED', 'Please verify the detected product, quantity, and price.')],
    );
  }

  static List<VoiceGateReason> validateManualFields({
    required String name, required double qty, required double price, required String unit,
  }) {
    final reasons = <VoiceGateReason>[];
    final normalizedName = _normalize(name);
    final normalizedUnit = _normalize(unit);
    if (normalizedName.length < 2 || _invalidNames.contains(normalizedName)) {
      reasons.add(const VoiceGateReason('INVALID_PRODUCT_NAME', 'Product name is not a valid sellable product.'));
    }
    if (!qty.isFinite || qty <= 0 || qty > 500) {
      reasons.add(const VoiceGateReason('INVALID_QUANTITY', 'Quantity must be greater than 0 and no more than 500.'));
    }
    if (!price.isFinite || price < 0 || price > 1000000) {
      reasons.add(const VoiceGateReason('INVALID_PRICE', 'Price must be between 0 and 1,000,000.'));
    }
    if (!_supportedUnits.contains(normalizedUnit)) {
      reasons.add(VoiceGateReason('INVALID_UNIT', 'Unit "' + unit + '" is not supported for billing.'));
    }
    return reasons;
  }

  static List<Map<String, dynamic>> _exactCatalogMatches(String name, List<Map<String, dynamic>> catalog) {
    final key = _normalize(name);
    return catalog.where((product) {
      final candidate = _normalize((product['name'] ?? product['product_name'] ?? '').toString());
      return candidate == key;
    }).toList();
  }

  static _Ambiguity _findCatalogAmbiguity(String name, List<Map<String, dynamic>> catalog) {
    final query = _normalize(name);
    if (query.length < 2) return const _Ambiguity.none();
    final scores = <_CatalogScore>[];
    for (final product in catalog) {
      final candidate = (product['name'] ?? product['product_name'] ?? '').toString();
      final normalized = _normalize(candidate);
      if (normalized.isEmpty) continue;
      scores.add(_CatalogScore(candidate, _similarity(query, normalized)));
    }
    scores.sort((a, b) => b.score.compareTo(a.score));
    if (scores.length < 2) return const _Ambiguity.none();
    final first = scores[0];
    final second = scores[1];
    final ambiguous = first.score >= 0.72 &&
        second.score >= 0.72 &&
        (first.score - second.score).abs() <= 0.08 &&
        _normalize(first.name) != query;
    return ambiguous ? _Ambiguity(first.name, second.name) : const _Ambiguity.none();
  }

  static String _normalize(String input) => input
      .trim().toLowerCase()
      .replaceAll(RegExp(r'[\u200C\u200D]'), '')
      .replaceAll(RegExp(r'[^a-z0-9\u0900-\u0D7F]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static double _similarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.isEmpty || b.isEmpty) return 0.0;
    final token = _tokenJaccard(a, b);
    final bigram = _bigramDice(a, b);
    return token > bigram ? token : bigram;
  }

  static double _tokenJaccard(String a, String b) {
    final aa = a.split(' ').where((e) => e.isNotEmpty).toSet();
    final bb = b.split(' ').where((e) => e.isNotEmpty).toSet();
    if (aa.isEmpty || bb.isEmpty) return 0.0;
    return aa.intersection(bb).length / aa.union(bb).length;
  }

  static double _bigramDice(String a, String b) {
    final ar = a.runes.toList();
    final br = b.runes.toList();
    if (ar.length < 2 || br.length < 2) return 0.0;
    final aa = <String>{};
    final bb = <String>{};
    for (var i = 0; i < ar.length - 1; i++) { aa.add(String.fromCharCodes([ar[i], ar[i + 1]])); }
    for (var i = 0; i < br.length - 1; i++) { bb.add(String.fromCharCodes([br[i], br[i + 1]])); }
    return (2 * aa.intersection(bb).length) / (aa.length + bb.length);
  }
}

class _CatalogScore {
  final String name;
  final double score;
  const _CatalogScore(this.name, this.score);
}

class _Ambiguity {
  final String? topName;
  final String? secondName;
  const _Ambiguity(this.topName, this.secondName);
  const _Ambiguity.none() : topName = null, secondName = null;
  bool get isAmbiguous => topName != null && secondName != null;
}