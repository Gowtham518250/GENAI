import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/language_detector.dart';

void main() {
  test('single Telugu product + price stays one item', () {
    final items = parseMultilingualVoiceInput(
      'పప్పు 200 రూపాయలు',
      sttLocaleHint: 'te-IN',
      catalog: const [],
    );

    expect(items, hasLength(1));
    expect(items.single.qty, 1.0);
    expect(items.single.price, 200.0);
    expect(items.single.name.toLowerCase(), 'dal');
  });

  test('multi-item speech still parses separately', () {
    final items = parseMultilingualVoiceInput(
      '2 kg rice 50, 1 oil 100',
      sttLocaleHint: 'en-IN',
      catalog: const [],
    );

    expect(items, hasLength(2));
    expect(items[0].qty, 2.0);
    expect(items[0].price, 50.0);
    expect(items[1].qty, 1.0);
    expect(items[1].price, 100.0);
  });
}
