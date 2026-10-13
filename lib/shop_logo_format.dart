import 'dart:typed_data';

import 'package:http_parser/http_parser.dart';

/// Supported formats accepted by the backend shop-logo upload endpoint.
class ShopLogoFormat {
  ShopLogoFormat({
    required this.extension,
    required this.contentType,
  });

  final String extension;
  final MediaType contentType;

  /// Detect the real format from file bytes instead of trusting the picker
  /// filename or assigning image/png to JPEG/WebP files.
  static ShopLogoFormat? detect(Uint8List bytes) {
    bool matches(List<int> signature) {
      if (bytes.length < signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[i] != signature[i]) return false;
      }
      return true;
    }

    if (matches(const <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return ShopLogoFormat(
        extension: 'png',
        contentType: MediaType('image', 'png'),
      );
    }

    if (matches(const <int>[0xFF, 0xD8, 0xFF])) {
      return ShopLogoFormat(
        extension: 'jpg',
        contentType: MediaType('image', 'jpeg'),
      );
    }

    if (matches(const <int>[0x47, 0x49, 0x46, 0x38, 0x37, 0x61]) ||
        matches(const <int>[0x47, 0x49, 0x46, 0x38, 0x39, 0x61])) {
      return ShopLogoFormat(
        extension: 'gif',
        contentType: MediaType('image', 'gif'),
      );
    }

    if (bytes.length >= 12 &&
        matches(const <int>[0x52, 0x49, 0x46, 0x46]) &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return ShopLogoFormat(
        extension: 'webp',
        contentType: MediaType('image', 'webp'),
      );
    }

    return null;
  }
}
