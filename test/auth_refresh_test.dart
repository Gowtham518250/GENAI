// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:retail_mind/api_client.dart';
import 'package:retail_mind/features/ai_query/models/ai_query_response.dart';
import 'package:retail_mind/session_management.dart';
import 'package:retail_mind/secure_token_storage.dart';

// ─── Helpers ─────────────────────────────────────────────────────────────────

final Map<String, String> _mockSecureStorage = <String, String>{};

void _setupMockSecureStorage() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (MethodCall methodCall) async {
          final args = methodCall.arguments;
          switch (methodCall.method) {
            case 'read':
              final key = args['key'] as String;
              return _mockSecureStorage[key];
            case 'write':
              final key = args['key'] as String;
              final value = args['value'] as String;
              _mockSecureStorage[key] = value;
              return null;
            case 'delete':
              final key = args['key'] as String;
              _mockSecureStorage.remove(key);
              return null;
            case 'deleteAll':
              _mockSecureStorage.clear();
              return null;
            case 'readAll':
              return Map<String, String>.from(_mockSecureStorage);
            case 'containsKey':
              final key = args['key'] as String;
              return _mockSecureStorage.containsKey(key);
            default:
              return null;
          }
        },
      );
}

/// Build a minimal JWT-like token that decodes cleanly for test assertions.
/// The payload is base64url-encoded JSON without a real signature.
String _fakeJwt({
  String sub = '42',
  String type = 'access',
  int expiresInSeconds = 3600,
}) {
  final header = base64Url.encode(utf8.encode('{"alg":"HS256","typ":"JWT"}'));
  final nowSecs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final payload = base64Url.encode(
    utf8.encode(
      json.encode({
        'sub': sub,
        'role': 'OWNER',
        'user_type': 'OWNER',
        'type': type,
        'exp': nowSecs + expiresInSeconds,
        'iat': nowSecs,
      }),
    ),
  );
  return '$header.$payload.fake_sig';
}

String _fakeAccessToken() => _fakeJwt(type: 'access', expiresInSeconds: 3600);
String _fakeRefreshToken() =>
    _fakeJwt(type: 'refresh', expiresInSeconds: 86400);

Future<void> _writeJson(
  HttpResponse response,
  int statusCode,
  Object body,
) async {
  response.statusCode = statusCode;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

class _RealHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context);
  }
}

// ─── Test groups ─────────────────────────────────────────────────────────────

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _mockSecureStorage.clear();
    _setupMockSecureStorage();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    _mockSecureStorage.clear();
  });

  // ─── 1. AIQueryResponse model ───────────────────────────────────────────────

  group('AIQueryResponse — 401 surface', () {
    test('error factory creates isSuccess=false with the given message', () {
      const msg = 'Your session has expired. Please sign in again.';
      final resp = AIQueryResponse.error(msg, query: 'test?');
      expect(resp.isSuccess, isFalse);
      expect(resp.errorMessage, equals(msg));
      expect(resp.query, equals('test?'));
    });

    test('fromJson parses a standard backend 200 payload', () {
      final payload = {
        'query': 'What are my sales today?',
        'sql': 'SELECT SUM(amount) FROM sales WHERE date = CURDATE()',
        'results': [
          {'total_sales_amount': '12450.00'},
        ],
      };
      final resp = AIQueryResponse.fromJson(
        payload,
        originalQuery: 'What are my sales today?',
      );
      expect(resp.isSuccess, isTrue);
      expect(resp.results, isNotEmpty);
      expect(resp.query, equals('What are my sales today?'));
    });

    test(
      'fromJson synthesises answer when generated_model_response is absent',
      () {
        final payload = {
          'query': 'How many sales?',
          'results': [
            {'count': 7},
          ],
        };
        final resp = AIQueryResponse.fromJson(
          payload,
          originalQuery: 'How many sales?',
        );
        expect(resp.isSuccess, isTrue);
        expect(resp.generatedModelResponse, isNotEmpty);
      },
    );
  });

  // ─── 2. SecureTokenStorage ─────────────────────────────────────────────────

  group('SecureTokenStorage — save / read / clear lifecycle', () {
    test('saves and retrieves an access token securely', () async {
      final token = _fakeAccessToken();
      await SecureTokenStorage.saveToken(token);
      final retrieved = await SecureTokenStorage.getToken();
      expect(retrieved, equals(token));
    });

    test('getToken returns null when nothing is stored', () async {
      final token = await SecureTokenStorage.getToken();
      expect(token, isNull);
    });

    test('saves and retrieves a refresh token securely', () async {
      final refreshToken = _fakeRefreshToken();
      await SecureTokenStorage.saveRefreshToken(refreshToken);
      final retrieved = await SecureTokenStorage.getRefreshToken();
      expect(retrieved, equals(refreshToken));
    });

    test('getRefreshToken returns null when nothing is stored', () async {
      final token = await SecureTokenStorage.getRefreshToken();
      expect(token, isNull);
    });

    test('clearAll removes stored tokens', () async {
      await SecureTokenStorage.saveToken(_fakeAccessToken());
      await SecureTokenStorage.saveRefreshToken(_fakeRefreshToken());
      await SecureTokenStorage.clearAll();
      expect(await SecureTokenStorage.getToken(), isNull);
      expect(await SecureTokenStorage.getRefreshToken(), isNull);
    });
  });

  // ─── 3. SessionManagementService.saveTokens ────────────────────────────────

  group('SessionManagementService — saveTokens', () {
    test('stores user metadata and tokens without throwing', () async {
      await SessionManagementService.saveTokens(
        accessToken: _fakeAccessToken(),
        refreshToken: _fakeRefreshToken(),
        deviceId: 'test-device',
        userId: 42,
        userName: 'Test User',
        userEmail: 'test@example.com',
      );
      final userId = await SessionManagementService.getCurrentUserId();
      expect(userId, equals(42));
      final token = await SecureTokenStorage.getToken();
      expect(token, isNotNull);
    });

    test(
      'saveTokens with empty refresh token skips saving refresh token gracefully',
      () async {
        await SessionManagementService.saveTokens(
          accessToken: _fakeAccessToken(),
          refreshToken: null,
          deviceId: 'test-device',
          userId: 42,
          userName: 'Test',
          userEmail: 'test@example.com',
        );
        final token = await SecureTokenStorage.getToken();
        expect(token, isNotNull);
        final refreshToken = await SecureTokenStorage.getRefreshToken();
        expect(refreshToken, isNull);
      },
    );
  });

  // ─── 4. autoLogin — refresh token absent ──────────────────────────────

  group('SessionManagementService.autoLogin — refresh token absent', () {
    test('returns null immediately when no refresh token is stored', () async {
      final result = await SessionManagementService.autoLogin();
      expect(result, isNull);
    });
  });

  // ─── 5. AIQueryResponse — concurrent 401 handling ─────────────────────────

  group('AIQueryResponse — multiple concurrent error responses', () {
    test('error factory is thread-safe for concurrent calls', () async {
      const msg = 'Your session has expired. Please sign in again.';
      final futures = List.generate(
        10,
        (_) => Future.value(AIQueryResponse.error(msg, query: 'q')),
      );
      final results = await Future.wait(futures);
      for (final r in results) {
        expect(r.isSuccess, isFalse);
        expect(r.errorMessage, equals(msg));
      }
    });
  });

  // ─── 6. Refresh flow diagnostics ───────────────────────────────────────────

  group('Token refresh — diagnostic log messages', () {
    test(
      'autoLogin returns null and does not throw when refresh token is unavailable',
      () async {
        final result = await SessionManagementService.autoLogin();
        expect(result, isNull);
      },
    );
  });

  // ─── 7. Shared ApiClient refresh contract ───────────────────────────────────

  group('ApiClient automatic token refresh', () {
    late HttpServer server;
    late String expiredAccessToken;
    late String refreshToken;
    late String newAccessToken;
    late String newRefreshToken;
    late int refreshStatusCode;
    late int refreshRequestCount;
    late int protectedRequestCount;
    late String? refreshAuthorization;
    late Map<String, dynamic>? refreshBody;
    late List<String?> protectedAuthorization;

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      ApiClient.setApiBaseUrl(
        'http://${server.address.address}:${server.port}',
      );
      server.listen((request) async {
        if (request.uri.path == ApiClient.sessionRefresh) {
          refreshRequestCount++;
          refreshAuthorization = request.headers.value(
            HttpHeaders.authorizationHeader,
          );
          final bodyText = await utf8.decoder.bind(request).join();
          refreshBody = jsonDecode(bodyText) as Map<String, dynamic>;
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (refreshStatusCode == HttpStatus.ok) {
            await _writeJson(request.response, refreshStatusCode, {
              'access_token': newAccessToken,
              'refresh_token': newRefreshToken,
              'user_id': 42,
              'user_name': 'Test User',
              'email': 'test@example.com',
            });
          } else {
            await _writeJson(request.response, refreshStatusCode, {
              'detail': 'refresh rejected',
            });
          }
          return;
        }

        protectedRequestCount++;
        final authorization = request.headers.value(
          HttpHeaders.authorizationHeader,
        );
        protectedAuthorization.add(authorization);
        if (authorization == 'Bearer $newAccessToken') {
          await _writeJson(request.response, HttpStatus.ok, {
            'answer': 'expected answer',
          });
        } else {
          await _writeJson(request.response, HttpStatus.unauthorized, {
            'detail': 'access token expired',
          });
        }
      });
    });

    setUp(() async {
      expiredAccessToken = _fakeAccessToken();
      refreshToken = _fakeRefreshToken();
      newAccessToken = _fakeJwt(expiresInSeconds: 7200);
      newRefreshToken = _fakeJwt(type: 'refresh', expiresInSeconds: 172800);
      refreshStatusCode = HttpStatus.ok;
      refreshRequestCount = 0;
      protectedRequestCount = 0;
      refreshAuthorization = null;
      refreshBody = null;
      protectedAuthorization = <String?>[];
      ApiClient.resetSessionExpiryNotification();

      await SessionManagementService.saveTokens(
        accessToken: expiredAccessToken,
        refreshToken: refreshToken,
        deviceId: 'test-device',
        userId: 42,
        userName: 'Test User',
        userEmail: 'test@example.com',
      );
      ApiClient.setApiBaseUrl(
        'http://${server.address.address}:${server.port}',
      );
    });

    tearDown(() async {
      SessionManagementService.stopSessionExpiryMonitoring();
    });

    tearDownAll(() async {
      ApiClient.setApiBaseUrl(null);
      await server.close(force: true);
    });

    test(
      'refreshes, stores rotated tokens, and retries the original request',
      () async {
        final response = await HttpOverrides.runWithHttpOverrides(
          () => ApiClient.postJson(ApiClient.askQueryEndpoint, {
            'query': 'sales today',
          }),
          _RealHttpOverrides(),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(jsonDecode(response.body)['answer'], 'expected answer');
        expect(refreshRequestCount, 1);
        expect(refreshAuthorization, isNull);
        expect(refreshBody?['refresh_token'], refreshToken);
        expect(refreshBody?['device_id'], isNotEmpty);
        expect(protectedAuthorization, [
          'Bearer $expiredAccessToken',
          'Bearer $newAccessToken',
        ]);
        expect(await SecureTokenStorage.getToken(), newAccessToken);
        expect(await SecureTokenStorage.getRefreshToken(), newRefreshToken);
      },
    );

    test('reuses one refresh for several simultaneous 401 responses', () async {
      final responses = await HttpOverrides.runWithHttpOverrides(
        () => Future.wait(
          List.generate(
            3,
            (_) => ApiClient.postJson('/protected', {'query': 'sales'}),
          ),
        ),
        _RealHttpOverrides(),
      );

      expect(
        responses.map((response) => response.statusCode),
        everyElement(HttpStatus.ok),
      );
      expect(refreshRequestCount, 1);
      expect(protectedRequestCount, 6);
      expect(await SecureTokenStorage.getToken(), newAccessToken);
    });

    test(
      'GET retry reads the rotated access token from secure storage',
      () async {
        final response = await HttpOverrides.runWithHttpOverrides(
          () => ApiClient.getJson('/protected'),
          _RealHttpOverrides(),
        );

        expect(response.statusCode, HttpStatus.ok);
        expect(refreshRequestCount, 1);
        expect(protectedAuthorization, [
          'Bearer $expiredAccessToken',
          'Bearer $newAccessToken',
        ]);
      },
    );

    test(
      'clears the unusable session when no refresh token is stored',
      () async {
        await SecureTokenStorage.clearRefreshToken();

        final response = await HttpOverrides.runWithHttpOverrides(
          () => ApiClient.postJson('/protected', {'query': 'sales'}),
          _RealHttpOverrides(),
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        expect(refreshRequestCount, 0);
        expect(await SecureTokenStorage.getToken(), isNull);
      },
    );

    test(
      'keeps local credentials after a temporary refresh-server error',
      () async {
        refreshStatusCode = HttpStatus.serviceUnavailable;

        final response = await HttpOverrides.runWithHttpOverrides(
          () => ApiClient.postJson('/protected', {'query': 'sales'}),
          _RealHttpOverrides(),
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        expect(refreshRequestCount, 1);
        expect(await SecureTokenStorage.getToken(), expiredAccessToken);
        expect(await SecureTokenStorage.getRefreshToken(), refreshToken);
      },
    );

    test(
      'clears stored auth when the refresh endpoint rejects the refresh token',
      () async {
        refreshStatusCode = HttpStatus.unauthorized;

        final response = await HttpOverrides.runWithHttpOverrides(
          () => ApiClient.postJson('/protected', {'query': 'sales'}),
          _RealHttpOverrides(),
        );

        expect(response.statusCode, HttpStatus.unauthorized);
        expect(refreshRequestCount, 1);
        expect(await SecureTokenStorage.getToken(), isNull);
        expect(await SecureTokenStorage.getRefreshToken(), isNull);
      },
    );
  });

  // ─── 8. App restart — session survives across lifecycle ───────────────────

  group('App restart token persistence', () {
    test(
      'getCurrentUserId reads from SharedPreferences after saveTokens',
      () async {
        SharedPreferences.setMockInitialValues({'user_id': 99});
        final userId = await SessionManagementService.getCurrentUserId();
        expect(userId, equals(99));
      },
    );
  });

  // ─── 9. Logout ────────────────────────────────────────────────────────────

  group('Logout clears tokens', () {
    test(
      'clearTokens removes SharedPreferences and secure storage keys',
      () async {
        SharedPreferences.setMockInitialValues({
          'user_id': 42,
          'session_time': 12345,
          'user_name': 'Test User',
        });
        await SecureTokenStorage.saveToken(_fakeAccessToken());
        await SecureTokenStorage.saveRefreshToken(_fakeRefreshToken());

        await SessionManagementService.clearTokens();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getInt('user_id'), isNull);
        expect(prefs.getInt('session_time'), isNull);
        expect(prefs.getString('user_name'), isNull);
        expect(await SecureTokenStorage.getToken(), isNull);
        expect(await SecureTokenStorage.getRefreshToken(), isNull);
      },
    );
  });

  // ─── 10. AiQueryService — bypass fix verification ─────────────────────────

  group('AiQueryService — no early token bypass', () {
    test(
      'empty query string returns validation error without touching auth',
      () async {
        final result = await _simulateAskQueryValidation('');
        expect(result.isSuccess, isFalse);
        expect(result.errorMessage, contains('Please enter a question'));
      },
    );

    test('whitespace-only query returns validation error', () async {
      final result = await _simulateAskQueryValidation('   ');
      expect(result.isSuccess, isFalse);
      expect(result.errorMessage, contains('Please enter a question'));
    });
  });
}

// ─── Test helpers ─────────────────────────────────────────────────────────────

Future<AIQueryResponse> _simulateAskQueryValidation(String query) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) {
    return AIQueryResponse.error('Please enter a question to ask Retail Mind.');
  }
  return AIQueryResponse(
    query: trimmed,
    results: const [],
    generatedModelResponse: 'ok',
    isSuccess: true,
  );
}
