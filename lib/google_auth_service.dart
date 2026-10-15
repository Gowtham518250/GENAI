import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'api_client.dart';
import 'local_storage_service.dart';
import 'secure_token_storage.dart';
import 'session_management.dart';
import 'user_data_clear_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Result of a Google Sign-In attempt.
class GoogleSignInResult {
  final bool success;
  final bool isNewUser;
  final String? token;
  final String? email;
  final String? name;
  final String? photoUrl;
  final String? error;

  const GoogleSignInResult({
    required this.success,
    this.isNewUser = false,
    this.token,
    this.email,
    this.name,
    this.photoUrl,
    this.error,
  });
}

class GoogleAuthService {
  // Load Google OAuth Client ID from environment - never hardcode
  static const String _googleClientId = String.fromEnvironment(
    'GOOGLE_OAUTH_CLIENT_ID',
    defaultValue: '', // Set to the Google Web OAuth client ID at build time.
  );

  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: ['email', 'profile'],
    serverClientId: _googleClientId.isNotEmpty ? _googleClientId : null,
  );

  /// Sign in with Google and exchange the verified Google ID token for a Retail Mind session.
  ///
  /// The Google ID token is verified by the backend. Profile data sent by the
  /// client is only for display and must never be treated as proof of identity.
  static Future<GoogleSignInResult> signIn() async {
    try {
      final GoogleSignInAccount? account = await _googleSignIn.signIn();
      if (account == null) {
        return const GoogleSignInResult(
          success: false,
          error: 'Google sign-in was cancelled.',
        );
      }

      final GoogleSignInAuthentication auth = await account.authentication;
      final String? idToken = auth.idToken;
      final String email = account.email.trim();
      final String name = (account.displayName ?? '').trim();
      final String? photoUrl = account.photoUrl;

      if (idToken == null || idToken.trim().isEmpty) {
        return GoogleSignInResult(
          success: false,
          error: _googleClientId.isEmpty
              ? 'Google sign-in is not configured. Add the real Web OAuth client ID to GOOGLE_OAUTH_CLIENT_ID and verify the Android Firebase configuration.'
              : 'Google did not return an ID token. Check the Web OAuth client ID and Android SHA-1/SHA-256 configuration.',
        );
      }

      if (email.isEmpty) {
        return const GoogleSignInResult(
          success: false,
          error: 'Google did not provide an email address. Please try another account.',
        );
      }

      if (kDebugMode) {
        debugPrint('Google account selected; exchanging ID token with Retail Mind backend.');
      }

      final response = await ApiClient.postJson('/auth/google', {
        'google_token': idToken,
        // These fields are display hints only. The backend must use the
        // claims from the verified ID token as the identity source.
        'email': email,
        'name': name,
        'photo_url': photoUrl ?? '',
      });

      if (response.statusCode != 200) {
        var message = response.statusCode == 404
            ? 'Google authentication is not available on the Retail Mind backend yet.'
            : 'Retail Mind could not authenticate this Google account (HTTP ${response.statusCode}).';

        try {
          final dynamic decoded = json.decode(response.body);
          if (decoded is Map) {
            final detail = decoded['detail'] ?? decoded['message'];
            if (detail is String && detail.trim().isNotEmpty) {
              message = detail.trim();
            }
          }
        } catch (_) {
          // Keep the safe status-based message if the response is not JSON.
        }

        if (kDebugMode) {
          debugPrint('Retail Mind Google authentication rejected with HTTP ${response.statusCode}.');
        }
        return GoogleSignInResult(success: false, error: message);
      }

      final dynamic decoded = json.decode(response.body);
      if (decoded is! Map) {
        return const GoogleSignInResult(
          success: false,
          error: 'Retail Mind returned an invalid authentication response.',
        );
      }
      final data = Map<String, dynamic>.from(decoded);
      final String? token =
          (data['access_token'] ?? data['token'])?.toString();
      if (token == null || token.trim().isEmpty) {
        return const GoogleSignInResult(
          success: false,
          error: 'Retail Mind did not return a session token. Please try again.',
        );
      }

      final returnedName =
          (data['username'] ?? data['user_name'] ?? name).toString().trim();
      final returnedEmail = (data['email'] ?? email).toString().trim();
      final userId = int.tryParse(
            (data['user_id'] ?? data['id'] ?? '').toString(),
          ) ??
          0;
      final role =
          (data['role'] ?? data['user_type'] ?? 'OWNER').toString();

      // Clear stale data only after the backend has verified the Google token
      // and issued a Retail Mind session.
      await UserDataClearService.clearAllUserData();
      await LocalStorageService.clearOrphanSalesBoxes();

      final deviceId = await SessionManagementService.getDeviceId();
      await SessionManagementService.initializeSession(
        userId: userId,
        accessToken: token,
        refreshToken: data['refresh_token']?.toString(),
        userName: returnedName,
        userEmail: returnedEmail,
        role: role,
        deviceId: deviceId,
      );

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_name', returnedName);
      await prefs.setString('email', returnedEmail);

      final dynamic profile = data['shop_profile'];
      final dynamic profileShopName =
          profile is Map ? profile['shop_name'] : null;
      final shopName = data['shop_name'] ?? profileShopName;
      if (shopName != null && shopName.toString().trim().isNotEmpty) {
        await prefs.setString('shop_name', shopName.toString());
      }

      return GoogleSignInResult(
        success: true,
        isNewUser: data['is_new_user'] == true,
        token: token,
        email: returnedEmail,
        name: returnedName,
        photoUrl: photoUrl,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Retail Mind Google sign-in exception: $e');
      }
      return const GoogleSignInResult(
        success: false,
        error: 'Google sign-in failed. Check your connection and Google OAuth configuration, then try again.',
      );
    }
  }

  /// Sign out from Google
  static Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
  }

  /// Check if a user is currently signed in via Google
  static Future<bool> isSignedIn() async {
    return _googleSignIn.isSignedIn();
  }
}
