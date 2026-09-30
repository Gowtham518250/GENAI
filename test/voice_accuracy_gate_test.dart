import 'package:flutter_test/flutter_test.dart';

import '../lib/voice_accuracy_gate.dart';
import '../lib/voice_nlp_engine.dart';

ParsedItemV2 makeItem({
  required double confidence,
  String name = 'Tata Salt',
  String? catalogMatchName = 'Tata Salt',
  double qty = 1,
  double price = 30,
  String unit = 'kg',
}) {
  return ParsedItemV2(
    name: name,
    qty: qty,
    unit: unit,
    price: price,
    catalogMatchName: catalogMatchName,
    confidence: ConfidenceDetail(
      nameScore: confidence,
      qtyScore: confidence,
      priceScore: confidence,
      patternBonus: 0.10,
      catalogBonus: 0.15,
    ),
  );
}

void main() {
  final catalog = <Map<String, dynamic>>[
    {'name': 'Tata Salt', 'price': 30, 'unit': 'kg'},
    {'name': 'Aashirvaad Salt', 'price': 32, 'unit': 'kg'},
    {'name': 'Sugar', 'price': 50, 'unit': 'kg'},
  ];

  group('VoiceAccuracyGate', () {
    test('auto accepts deterministic high confidence catalog match', () {
      final result = VoiceAccuracyGate.evaluate(
        makeItem(confidence: 0.95),
        catalog: catalog,
      );
      expect(result.decision, VoiceGateDecision.autoAccept);
    });

    test('requires confirmation for ambiguous product', () {
      final result = VoiceAccuracyGate.evaluate(
        makeItem(confidence: 0.95, name: 'Salt', catalogMatchName: null),
        catalog: catalog,
      );
      expect(result.decision, VoiceGateDecision.requiresConfirmation);
      expect(result.reasons.map((e) => e.code), contains('AMBIGUOUS_PRODUCT'));
    });

    test('rejects low confidence', () {
      final result = VoiceAccuracyGate.evaluate(
        makeItem(confidence: 0.50, name: 'Unknown Product', catalogMatchName: null),
        catalog: catalog,
      );
      expect(result.decision, VoiceGateDecision.reject);
      expect(result.reasons.map((e) => e.code), contains('LOW_CONFIDENCE'));
    });

    test('never auto accepts without exact catalog identity', () {
      final result = VoiceAccuracyGate.evaluate(
        makeItem(confidence: 0.99, name: 'Salt', catalogMatchName: 'Salt'),
        catalog: catalog,
      );
      expect(result.decision, VoiceGateDecision.requiresConfirmation);
    });

    test('rejects invalid quantity', () {
      final result = VoiceAccuracyGate.evaluate(
        makeItem(confidence: 0.99, qty: 0),
        catalog: catalog,
      );
      expect(result.decision, VoiceGateDecision.reject);
      expect(result.reasons.map((e) => e.code), contains('INVALID_QUANTITY'));
    });

    test('manual validation accepts valid fields', () {
      expect(
        VoiceAccuracyGate.validateManualFields(
          name: 'Tata Salt', qty: 2, price: 60, unit: 'kg',
        ),
        isEmpty,
      );
    });

    test('manual validation rejects unsupported unit', () {
      final errors = VoiceAccuracyGate.validateManualFields(
        name: 'Tata Salt', qty: 2, price: 60, unit: 'unknown',
      );
      expect(errors.map((e) => e.code), contains('INVALID_UNIT'));
    });
  });
}