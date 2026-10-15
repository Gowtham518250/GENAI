import 'package:flutter_test/flutter_test.dart';
import 'package:retail_mind/startup_route_policy.dart';

void main() {
  group('startup role verification policy', () {
    test('shows boot screen while session state is being resolved', () {
      expect(
        resolveStartupRoute(
          booting: true,
          authenticated: false,
          role: null,
          shopDetailsRequired: false,
          identityVerified: false,
          staffMode: false,
        ),
        '/_boot',
      );
    });

    test('unauthenticated user must log in', () {
      expect(
        resolveStartupRoute(
          booting: false,
          authenticated: false,
          role: 'OWNER',
          shopDetailsRequired: false,
          identityVerified: false,
          staffMode: false,
        ),
        '/login',
      );
    });

    test('a persisted owner token alone does not bypass owner verification', () {
      expect(
        resolveStartupRoute(
          booting: false,
          authenticated: true,
          role: 'OWNER',
          shopDetailsRequired: false,
          identityVerified: false,
          staffMode: false,
        ),
        '/identity-verification',
      );
    });

    test('a staff mode saved on disk does not bypass staff PIN after restart', () {
      expect(
        resolveStartupRoute(
          booting: false,
          authenticated: true,
          role: 'OWNER',
          shopDetailsRequired: false,
          identityVerified: false,
          staffMode: true,
        ),
        '/identity-verification',
      );
    });

    test('verified owner can open dashboard in the same process', () {
      expect(
        resolveStartupRoute(
          booting: false,
          authenticated: true,
          role: 'OWNER',
          shopDetailsRequired: false,
          identityVerified: true,
          staffMode: false,
        ),
        '/dashboard',
      );
    });

    test('verified staff can open restricted dashboard in the same process', () {
      expect(
        resolveStartupRoute(
          booting: false,
          authenticated: true,
          role: 'OWNER',
          shopDetailsRequired: false,
          identityVerified: true,
          staffMode: true,
        ),
        '/dashboard',
      );
    });

    test('customer flow does not receive owner/staff identity gate', () {
      expect(
        resolveStartupRoute(
          booting: false,
          authenticated: true,
          role: 'CUSTOMER',
          shopDetailsRequired: false,
          identityVerified: false,
          staffMode: false,
        ),
        '/customer-marketplace',
      );
    });

    test('unknown role fails closed to verification instead of dashboard', () {
      expect(
        resolveStartupRoute(
          booting: false,
          authenticated: true,
          role: '',
          shopDetailsRequired: false,
          identityVerified: false,
          staffMode: false,
        ),
        '/identity-verification',
      );
    });
  });
}
