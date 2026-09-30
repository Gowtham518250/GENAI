import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'email_sender_service.dart';

/// Frontend-owned OTP generation, Gmail delivery and local verification.
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

  static Future<int> getRemainingTime() async {
    return 0;
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

