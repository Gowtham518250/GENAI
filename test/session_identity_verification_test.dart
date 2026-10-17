import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:retail_mind/session_management.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  group('persisted identity verification', () {
    test('verification survives subsequent checks for the same user and role', () async {
      await SessionManagementService.markIdentityVerified(
        userId: 42,
        role: 'OWNER',
      );

      expect(
        await SessionManagementService.isIdentityVerified(
          userId: 42,
          role: 'OWNER',
        ),
        isTrue,
      );
    });

    test('verification is isolated by user and role', () async {
      await SessionManagementService.markIdentityVerified(
        userId: 42,
        role: 'OWNER',
      );

      expect(
        await SessionManagementService.isIdentityVerified(
          userId: 43,
          role: 'OWNER',
        ),
        isFalse,
      );
      expect(
        await SessionManagementService.isIdentityVerified(
          userId: 42,
          role: 'STAFF',
        ),
        isFalse,
      );
    });

    test('clearing verification requires the user to verify again', () async {
      await SessionManagementService.markIdentityVerified(
        userId: 42,
        role: 'OWNER',
      );

      await SessionManagementService.clearIdentityVerification(userId: 42);

      expect(
        await SessionManagementService.isIdentityVerified(
          userId: 42,
          role: 'OWNER',
        ),
        isFalse,
      );
    });
  });
}
