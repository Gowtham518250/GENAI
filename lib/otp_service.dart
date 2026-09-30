import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';

/// Backend-owned OTP generation, SMTP delivery and server-side verification.
///
/// The backend is used only after the user has locally verified the OTP to
/// obtain a short-lived, one-time password-reset authorization token.
class OTPService {
  static const _storage = FlutterSecureStorage();

  static const _kEmail = 'password_reset_email';
  static const _kOtpHash = 'password_reset_otp_hash';
  static const _kOtpCreatedAt = 'password_reset_otp_created_at';
  static const _kChallengeId = 'password_reset_challenge_id';
  static const _kRegistrationSecret = 'password_reset_registration_secret';
  static const _kResetToken = 'password_reset_reset_token';
  static const _kAttempts = 'password_reset_otp_attempts';

  // Owner verification OTP is intentionally independent from password reset.
  // It is generated, emailed, and verified locally on the device.
  static const _kOwnerEmail = 'owner_verification_email';
  static const _kOwnerOtpHash = 'owner_verification_otp_hash';
  static const _kOwnerOtpCreatedAt = 'owner_verification_otp_created_at';
  static const _kOwnerAttempts = 'owner_verification_otp_attempts';

  static const Duration _otpValidity = Duration(minutes: 10);
  static const int _maxLocalAttempts = 5;

  static String _generateSecureOTP() {
    return (Random.secure().nextInt(900000) + 100000).toString();
  }

  static String _hashOtp(String otp) {
    return sha256.convert(utf8.encode(otp)).toString();
  }

  static Future<void> _clearOtpOnly() async {
    await _storage.delete(key: _kOtpHash);
    await _storage.delete(key: _kOtpCreatedAt);
    await _storage.delete(key: _kAttempts);
  }

  static Future<void> clearResetState() async {
    for (final key in const [
      _kEmail,
      _kOtpHash,
      _kOtpCreatedAt,
      _kChallengeId,
      _kRegistrationSecret,
      _kResetToken,
      _kAttempts,
    ]) {
      await _storage.delete(key: key);
    }
  }

  static Future<void> _clearOwnerVerificationState() async {
    for (final key in const [
      _kOwnerEmail,
      _kOwnerOtpHash,
      _kOwnerOtpCreatedAt,
      _kOwnerAttempts,
    ]) {
      await _storage.delete(key: key);
    }
  }

  /// Owner identity verification only.
  ///
  /// This path intentionally does NOT call any password-reset or backend OTP
  /// endpoint. The app generates the code locally and sends it through the
  /// configured Gmail SMTP sender.
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
        return {
          'success': true,
          'message': 'Verification OTP sent. Check your email inbox and spam folder.',
        };
      }

      try {
        final decoded = jsonDecode(response.body);
        return {
          'success': false,
          'message': decoded is Map
              ? (decoded['detail']?.toString() ??
                  decoded['message']?.toString() ??
                  'Failed to send verification OTP.')
              : 'Failed to send verification OTP.',
        };
      } catch (_) {
        return {'success': false, 'message': 'Failed to send verification OTP.'};
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Owner verification OTP request failed: $e');
      return {
        'success': false,
        'message': 'Unable to send verification OTP. Please try again.',
      };
    }
  }

  /// Verify the owner OTP on the backend.
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
        return {
          'success': true,
          'message': 'Owner identity verified successfully.',
        };
      }

      try {
        final decoded = jsonDecode(response.body);
        return {
          'success': false,
          'message': decoded is Map
              ? (decoded['detail']?.toString() ??
                  decoded['message']?.toString() ??
                  'Invalid or expired verification OTP.')
              : 'Invalid or expired verification OTP.',
        };
      } catch (_) {
        return {'success': false, 'message': 'Invalid or expired verification OTP.'};
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Owner OTP verification failed: $e');
      return {
        'success': false,
        'message': 'Unable to verify the OTP. Please try again.',
      };
    }
  }

  /// Request a generic verification OTP from the backend.
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
        return {
          'success': true,
          'message': 'OTP sent. Check your email inbox and spam folder.',
        };
      }

      try {
        final decoded = jsonDecode(response.body);
        return {
          'success': false,
          'message': decoded is Map
              ? (decoded['detail']?.toString() ??
                  decoded['message']?.toString() ??
                  'Failed to send OTP.')
              : 'Failed to send OTP.',
        };
      } catch (_) {
        return {'success': false, 'message': 'Failed to send OTP.'};
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ OTP request failed: $e');
      return {
        'success': false,
        'message': 'Unable to send OTP. Please try again.',
      };
    }
  }

  /// Verify a generic verification OTP on the backend.
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
        return {'success': true, 'message': 'OTP verified successfully.'};
      }

      try {
        final decoded = jsonDecode(response.body);
        return {
          'success': false,
          'message': decoded is Map
              ? (decoded['detail']?.toString() ??
                  decoded['message']?.toString() ??
                  'Invalid or expired OTP.')
              : 'Invalid or expired OTP.',
        };
      } catch (_) {
        return {'success': false, 'message': 'Invalid or expired OTP.'};
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ OTP verification failed: $e');
      return {
        'success': false,
        'message': 'Unable to verify OTP. Please try again.',
      };
    }
  }

  /// Send a password-reset OTP using backend SMTP delivery.
  static Future<Map<String, dynamic>> sendPasswordResetOTP(String email) async {
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
        return {'success': true, 'message': 'OTP sent. Check your email inbox and spam folder.'};
      }

      try {
        final decoded = jsonDecode(response.body);
        return {
          'success': false,
          'message': decoded is Map
              ? (decoded['detail']?.toString() ?? decoded['message']?.toString() ?? 'Failed to send reset OTP.')
              : 'Failed to send reset OTP.',
        };
      } catch (_) {
        return {'success': false, 'message': 'Failed to send reset OTP.'};
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Password-reset OTP request failed: $e');
      return {'success': false, 'message': 'Unable to send reset OTP. Please try again.'};
    }
  }

  /// Validate a password-reset OTP without consuming it.
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
        {'email': normalizedEmail, 'otp': code},
      );

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return {'success': true, 'message': 'OTP verified successfully.'};
      }

      try {
        final decoded = jsonDecode(response.body);
        return {
          'success': false,
          'message': decoded is Map
              ? (decoded['detail']?.toString() ??
                  decoded['message']?.toString() ??
                  'Invalid or expired reset OTP.')
              : 'Invalid or expired reset OTP.',
        };
      } catch (_) {
        return {'success': false, 'message': 'Invalid or expired reset OTP.'};
      }
    } catch (e) {
      if (kDebugMode) debugPrint('❌ Reset OTP verification failed: $e');
      return {'success': false, 'message': 'Unable to verify reset OTP. Please try again.'};
    }
  }

  static Future<Map<String, dynamic>> resendOTP(String email) {
    return sendOTPToEmail(
      email,
      title: 'Retail Mind Verification',
      bodyText: 'A new verification code was requested. Use the latest OTP below.',
    );
  }

  static Future<bool> _hasStoredResetToken() async {
    final token = await _storage.read(key: _kResetToken);
    return token != null && token.isNotEmpty;
  }

  static Future<String?> getResetToken() async {
    return _storage.read(key: _kResetToken);
  }

  static Future<Map<String, dynamic>> resendOTP(String email) async {
    return sendOTPToEmail(
      email,
      title: '🔄 Retail Mind Password Reset',
      bodyText: 'A new password-reset code was requested. Use the OTP below and confirm the secure email link.',
    );
  }

  static Future<int> getRemainingTime() async {
    final createdAtRaw = await _storage.read(key: _kOtpCreatedAt);
    if (createdAtRaw == null) return 0;
    final createdAt = int.tryParse(createdAtRaw);
    if (createdAt == null) return 0;
    final remaining = _otpValidity - Duration(milliseconds: DateTime.now().millisecondsSinceEpoch - createdAt);
    return remaining.isNegative ? 0 : remaining.inSeconds;
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

