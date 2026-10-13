import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/shop_logo_format.dart';

void main() {
  group('ShopLogoFormat.detect', () {
    test('recognizes PNG', () {
      final format = ShopLogoFormat.detect(
        Uint8List.fromList(<int>[
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00,
        ]),
      );

      expect(format?.extension, 'png');
      expect(format?.contentType.toString(), 'image/png');
    });

    test('recognizes JPEG', () {
      final format = ShopLogoFormat.detect(
        Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
      );

      expect(format?.extension, 'jpg');
      expect(format?.contentType.toString(), 'image/jpeg');
    });

    test('recognizes GIF and WebP', () {
      final gif = ShopLogoFormat.detect(
        Uint8List.fromList(<int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61]),
      );
      final webp = ShopLogoFormat.detect(
        Uint8List.fromList(<int>[
          0x52, 0x49, 0x46, 0x46, 0x00, 0x00, 0x00, 0x00,
          0x57, 0x45, 0x42, 0x50,
        ]),
      );

      expect(gif?.extension, 'gif');
      expect(gif?.contentType.toString(), 'image/gif');
      expect(webp?.extension, 'webp');
      expect(webp?.contentType.toString(), 'image/webp');
    });

    test('rejects empty and unsupported file signatures', () {
      expect(ShopLogoFormat.detect(Uint8List(0)), isNull);
      expect(
        ShopLogoFormat.detect(Uint8List.fromList(<int>[0x00, 0x01, 0x02])),
        isNull,
      );
    });
  });
}
