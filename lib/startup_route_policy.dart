/// Determines where a cold app launch may begin.
///
/// A persisted access token establishes a session, not the identity of the
/// person currently holding a shared device. Owner and staff access must pass
/// the process-local role verification again after an app/tab restart.
String resolveStartupRoute({
  required bool booting,
  required bool authenticated,
  required String? role,
  required bool shopDetailsRequired,
  required bool identityVerified,
  required bool staffMode,
}) {
  if (booting) return '/_boot';
  if (!authenticated) return '/login';

  final normalizedRole = (role ?? '').trim().toUpperCase();
  if (normalizedRole == 'CUSTOMER') return '/customer-marketplace';

  // Never infer OWNER from a missing role or a persisted token alone.
  if (!identityVerified) return '/identity-verification';

  if (shopDetailsRequired) return '/shop-details';
  if (staffMode) return '/dashboard';
  if (normalizedRole == 'WORKER') return '/attendance';
  if (normalizedRole == 'OWNER') return '/dashboard';

  // A valid token with an unknown/empty role must fail closed.
  return '/identity-verification';
}
