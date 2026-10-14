import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../lib/cache_consistency_service.dart';
import '../lib/inventory_stock_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues(<String, Object>{});

  group('inventory product image cache reconciliation', () {
    test('keeps a locally uploaded image while its sync is pending', () {
      const localImage = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/';
      final local = <String, dynamic>{
        'id': 12,
        'product_name': 'Tamarind',
        'image_url': localImage,
        'sync_status': 'pending',
        'local_updated_at': '2026-10-14T10:00:00.000Z',
      };
      final staleServer = <String, dynamic>{
        'id': 12,
        'product_name': 'Tamarind',
        'image_url': null,
      };

      final merged = CacheConsistencyService.mergeRecord(local, staleServer);

      expect(merged['image_url'], localImage);
      expect(merged['sync_status'], 'pending');
      expect(merged['conflict_state'], 'local_pending');
    });

    test('preserves an uploaded image when API uses product_id instead of id', () {
      const localImage = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/';
      final merged = InventoryStockHelper.mergeApiWithLocalCache(
        [
          {
            'product_id': 12,
            'product_name': 'Tamarind',
            'image_url': null,
            'current_stock': 7,
          },
        ],
        [
          {
            'id': 12,
            'product_name': 'Tamarind',
            'image_url': localImage,
            'sync_status': 'pending',
            'local_updated_at': '2026-10-14T10:00:00.000Z',
          },
        ],
      );

      expect(merged, hasLength(1));
      expect(merged.single['id'], 12);
      expect(merged.single['image_url'], localImage);
      expect(merged.single['sync_status'], 'pending');
    });

    test('uses the server image after the local image update is acknowledged', () {
      const serverImage = 'https://images.example.test/tamarind.webp';
      final local = <String, dynamic>{
        'id': 12,
        'product_name': 'Tamarind',
        'image_url': serverImage,
        'sync_status': 'synced',
        'local_updated_at': '2026-10-14T10:00:00.000Z',
      };
      final server = <String, dynamic>{
        'id': 12,
        'product_name': 'Tamarind',
        'image_url': serverImage,
      };

      final merged = CacheConsistencyService.mergeRecord(local, server);

      expect(merged['image_url'], serverImage);
      expect(merged['conflict_state'], 'remote_wins');
    });
  });
}
