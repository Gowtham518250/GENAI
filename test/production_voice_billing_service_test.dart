import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:retail_mind/product_catalog_service.dart';
import 'package:retail_mind/production_voice_billing_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProductCatalogService catalog;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    catalog = ProductCatalogService();
    await catalog.load([
      {
        'name': 'Rice',
        'price': 50,
        'unit': 'kg',
        'barcode': '890000000001',
        'gst_percent': 5,
      },
      {
        'name': 'Oil',
        'price': 100,
        'unit': 'L',
        'barcode': '890000000002',
        'gst_percent': 5,
      },
      {
        'name': 'Sugar',
        'price': 60,
        'unit': 'kg',
        'barcode': '890000000003',
        'gst_percent': 5,
      },
    ]);
  });

  test('parses multiple products in one spoken command', () async {
    final result = await ProductionVoiceBillingService.parse(
      transcript: '2 kg rice 50, 1 oil 100',
      localeCode: 'en-IN',
      catalogService: catalog,
      knownProducts: const [
        {'name': 'Rice', 'price': 50, 'unit': 'kg', 'barcode': '890000000001'},
        {'name': 'Oil', 'price': 100, 'unit': 'L', 'barcode': '890000000002'},
      ],
    );

    expect(result.lines, hasLength(2));
    expect(result.lines[0].name.toLowerCase(), 'rice');
    expect(result.lines[0].quantity, 2);
    expect(result.lines[0].price, 50);
    expect(result.lines[1].name.toLowerCase(), 'oil');
    expect(result.lines[1].quantity, 1);
    expect(result.lines[1].price, 100);
  });

  test('uses catalog price when the cashier does not speak a price', () async {
    final result = await ProductionVoiceBillingService.parse(
      transcript: 'sugar',
      localeCode: 'en-IN',
      catalogService: catalog,
      knownProducts: const [
        {'name': 'Sugar', 'price': 60, 'unit': 'kg', 'barcode': '890000000003'},
      ],
    );

    expect(result.lines, hasLength(1));
    expect(result.lines.single.name.toLowerCase(), 'sugar');
    expect(result.lines.single.price, 60);
    expect(result.lines.single.priceSource, 'catalog');
    expect(result.lines.single.barcode, '890000000003');
  });

  test('preserves an explicitly spoken price and warns on a large mismatch', () async {
    final result = await ProductionVoiceBillingService.parse(
      transcript: 'sugar 120',
      localeCode: 'en-IN',
      catalogService: catalog,
      knownProducts: const [
        {'name': 'Sugar', 'price': 60, 'unit': 'kg'},
      ],
    );

    expect(result.lines, hasLength(1));
    expect(result.lines.single.price, 120);
    expect(result.lines.single.priceSource, 'spoken');
    expect(result.lines.single.priceWarning, isNotNull);
    expect(result.warnings, isNotEmpty);
  });

  test('keeps missing price visible instead of silently inventing one', () async {
    final result = await ProductionVoiceBillingService.parse(
      transcript: '2 kg local rice',
      localeCode: 'en-IN',
      catalogService: catalog,
      knownProducts: const [],
    );

    expect(result.lines, hasLength(1));
    expect(result.lines.single.quantity, 2);
    expect(result.lines.single.price, 0);
    expect(result.lines.single.priceSource, 'missing');
    expect(result.lines.single.toMap()['price_missing'], isTrue);
  });

  test('merges genuine duplicate product lines', () async {
    final result = await ProductionVoiceBillingService.parse(
      transcript: 'rice 50 and rice 50',
      localeCode: 'en-IN',
      catalogService: catalog,
      knownProducts: const [
        {'name': 'Rice', 'price': 50, 'unit': 'kg'},
      ],
    );

    expect(result.lines, hasLength(1));
    expect(result.lines.single.quantity, 2);
    expect(result.lines.single.price, 50);
  });
}
