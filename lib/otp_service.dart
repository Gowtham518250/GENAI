import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

/// Backend-owned OTP service.
///
/// OTP generation, expiry, delivery and verification are handled by the
/// Retail Mind backend. SMTP credentials never live in the Flutter app.
class OTPService {
  static const _storage = FlutterSecureStorage();

  static const _kEmail = 'password_reset_email';
  static const _kOtpCreatedAt = 'password_reset_otp_created_at';
  static const _kChallengeId = 'password_reset_challenge_id';
  static const _kRegistrationSecret = 'password_reset_registration_secret';
  static const _kResetToken = 'password_reset_reset_token';
  static const _otpValidity = Duration(minutes: 10);

  static Future<void> _markOtpSent(String email) async {
    await _storage.write(key: _kEmail, value: email.trim().toLowerCase());
    await _storage.write(
      key: _kOtpCreatedAt,
      value: DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  static Future<void> _clearLocalOtpTimer() async {
    await _storage.delete(key: _kEmail);
    await _storage.delete(key: _kOtpCreatedAt);
  }

  static Future<void> clearResetState() async {
    for (final key in const [
      _kEmail,
      _kOtpCreatedAt,
      _kChallengeId,
      _kRegistrationSecret,
      _kResetToken,
    ]) {
      await _storage.delete(key: key);
    }
  }

  static Future<String?> getResetToken() async {
    return _storage.read(key: _kResetToken);
  }

  static Future<int> getRemainingTime() async {
    final createdAtRaw = await _storage.read(key: _kOtpCreatedAt);
    if (createdAtRaw == null) return 0;

    final createdAt = int.tryParse(createdAtRaw);
    if (createdAt == null) return 0;

    final elapsed = DateTime.now().millisecondsSinceEpoch - createdAt;
    final remaining = _otpValidity - Duration(milliseconds: elapsed);
    return remaining.isNegative ? 0 : remaining.inSeconds;
  }

  static Map<String, dynamic> _errorFromResponse(
    dynamic response,
    String fallback,
  ) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        return {
          'success': false,
          'message': decoded['detail']?.toString() ??
              decoded['message']?.toString() ??
              fallback,
        };
      }
    } catch (_) {}
    return {'success': false, 'message': fallback};
  }

  static Future<Map<String, dynamic>> sendOwnerVerificationOTP(
    String email, {
    String? title,
    String? bodyText,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      return {'success': false, 'message': 'Email is required'};
    }

    try {
      final response = await ApiClient.postJson(
        '/auth/send-owner-otp',
        {
          'email': normalizedEmail,
          'purpose': title ?? 'Owner Verification',
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _markOtpSent(normalizedEmail);
        return {
          'success': true,
          'message': 'Verification OTP sent. Check your email inbox and spam folder.',
        };
      }

      return _errorFromResponse(
        response,
        'Failed to send owner verification OTP.',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Owner verification OTP request failed: $e');
      }
      return {
        'success': false,
        'message': 'Unable to send verification OTP. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> verifyOwnerVerificationOTP(
    String email,
    String enteredOTP,
  ) async {
    final normalizedEmail = email.trim().toLowerCase();
    final code = enteredOTP.trim();

    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return {'success': false, 'message': 'OTP must be 6 digits'};
    }

    try {
      final response = await ApiClient.postJson(
        '/auth/verify-owner-otp',
        {
          'email': normalizedEmail,
          'otp': code,
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _clearLocalOtpTimer();
        return {
          'success': true,
          'message': 'Owner identity verified successfully.',
        };
      }

      return _errorFromResponse(
        response,
        'Invalid or expired owner verification OTP.',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Owner OTP verification failed: $e');
      return {
        'success': false,
        'message': 'Unable to verify the OTP. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> sendCustomerDeliveryOTP({
    required int orderId,
  }) async {
    try {
      final response = await ApiClient.postJson(
        '/store/owner/orders/$orderId/delivery-otp',
        {},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        return {
          'success': true,
          'message': decoded is Map
              ? (decoded['message']?.toString() ??
                  'Delivery OTP sent to the customer.')
              : 'Delivery OTP sent to the customer.',
          'email': decoded is Map ? decoded['email']?.toString() : null,
          'expires_in':
              decoded is Map ? decoded['expires_in'] : null,
        };
      }

      return _errorFromResponse(
        response,
        'Unable to send customer delivery OTP.',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Customer delivery OTP request failed: $e');
      }
      return {
        'success': false,
        'message': 'Unable to send customer delivery OTP. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> verifyCustomerDeliveryOTP({
    required int orderId,
    required String otp,
  }) async {
    final code = otp.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return {'success': false, 'message': 'OTP must be 6 digits'};
    }

    try {
      final response = await ApiClient.postJson(
        '/store/owner/orders/$orderId/action?action=DELIVER',
        {'customer_otp': code},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        return {
          'success': true,
          'message': decoded is Map
              ? (decoded['message']?.toString() ??
                  'Order marked as delivered.')
              : 'Order marked as delivered.',
        };
      }

      return _errorFromResponse(
        response,
        'Unable to verify customer delivery OTP.',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Customer delivery OTP verification failed: $e');
      }
      return {
        'success': false,
        'message': 'Unable to verify customer delivery OTP. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> resetWorkerPin({
    required String email,
    required String otp,
    required int workerId,
    required String newPin,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    try {
      final response = await ApiClient.postJson(
        '/auth/reset-worker-pin',
        {
          'email': normalizedEmail,
          'otp': otp.trim(),
          'worker_id': workerId,
          'new_pin': newPin.trim(),
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await clearResetState();
        return {
          'success': true,
          'message': 'Worker attendance PIN reset successfully.',
        };
      }

      return _errorFromResponse(
        response,
        'Unable to reset worker PIN.',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Worker PIN reset failed: $e');
      return {
        'success': false,
        'message': 'Unable to reset worker PIN. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> sendOTPToEmail(
    String email, {
    String? title,
    String? bodyText,
  }) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      return {'success': false, 'message': 'Email is required'};
    }

    try {
      final response = await ApiClient.postJson(
        '/auth/send-otp',
        {
          'email': normalizedEmail,
          'purpose': title ?? 'Verification',
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _markOtpSent(normalizedEmail);
        return {
          'success': true,
          'message': 'OTP sent. Check your email inbox and spam folder.',
        };
      }

      return _errorFromResponse(response, 'Failed to send OTP.');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ OTP request failed: $e');
      return {
        'success': false,
        'message': 'Unable to send OTP. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> verifyOTP(
    String email,
    String enteredOTP,
  ) async {
    final normalizedEmail = email.trim().toLowerCase();
    final code = enteredOTP.trim();

    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return {'success': false, 'message': 'OTP must be 6 digits'};
    }

    try {
      final response = await ApiClient.postJson(
        '/auth/verify-otp',
        {
          'email': normalizedEmail,
          'otp': code,
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _clearLocalOtpTimer();
        return {
          'success': true,
          'message': 'OTP verified successfully.',
        };
      }

      return _errorFromResponse(response, 'Invalid or expired OTP.');
    } catch (e) {
      if (kDebugMode) debugPrint('❌ OTP verification failed: $e');
      return {
        'success': false,
        'message': 'Unable to verify OTP. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> sendPasswordResetOTP(
    String email,
  ) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      return {'success': false, 'message': 'Email is required'};
    }

    try {
      final response = await ApiClient.postJson(
        '/auth/request-password-reset-otp',
        {'email': normalizedEmail},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        await _markOtpSent(normalizedEmail);
        return {
          'success': true,
          'message': 'OTP sent. Check your email inbox and spam folder.',
        };
      }

      return _errorFromResponse(
        response,
        'Failed to send reset OTP.',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('❌ Password-reset OTP request failed: $e');
      }
      return {
        'success': false,
        'message': 'Unable to send reset OTP. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> verifyPasswordResetOTP(
    String email,
    String enteredOTP,
  ) async {
    final normalizedEmail = email.trim().toLowerCase();
    final code = enteredOTP.trim();

    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      return {'success': false, 'message': 'OTP must be 6 digits'};
    }

    try {
      final response = await ApiClient.postJson(
        '/auth/check-reset-otp',
        {
          'email': normalizedEmail,
          'otp': code,
        },
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return {
          'success': true,
          'message': 'OTP verified successfully.',
        };
      }

      return _errorFromResponse(
        response,
        'Invalid or expired reset OTP.',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Reset OTP verification failed: $e');
      return {
        'success': false,
        'message': 'Unable to verify reset OTP. Please try again.',
      };
    }
  }

  static Future<Map<String, dynamic>> resendOTP(String email) {
    return sendOTPToEmail(
      email,
      title: 'Retail Mind Verification',
      bodyText:
          'A new verification code was requested. Use the latest OTP below.',
    );
  }
}
