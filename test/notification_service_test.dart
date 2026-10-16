import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/notification_service.dart';

void main() {
  group('NotificationService ID allocation', () {
    test('closely spaced notifications receive distinct valid Android IDs', () {
      final ids = List<int>.generate(
        100,
        (_) => NotificationService.allocateNotificationIdForTesting(),
      );

      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.every((id) => id > 0 && id <= 0x7fffffff), isTrue);
    });
  });
}
