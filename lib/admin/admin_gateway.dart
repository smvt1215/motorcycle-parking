import 'package:supabase_flutter/supabase_flutter.dart';

class AdminAccess {
  const AdminAccess({
    this.userId,
    this.email,
    this.isAdmin = false,
    this.aal2 = false,
  });

  final String? userId;
  final String? email;
  final bool isAdmin;
  final bool aal2;
  bool get signedIn => userId != null;
}

/// The UI never receives a service role key. RLS remains the authority for data.
abstract class AdminGateway {
  AdminAccess get access;
  Stream<void> get changes;
  Future<void> signIn();
  Future<void> signOut();
  Future<List<Factor>> listFactors();
  Future<AuthMFAEnrollResponse> enroll({
    required FactorType type,
    required String name,
    String? phone,
  });
  Future<AuthMFAChallengeResponse> challenge(String factorId, FactorType type);
  Future<void> verify(String factorId, String challengeId, String code);
  Future<void> cancelEnrollment(String factorId);
  Future<int> pendingCount();
}

class SupabaseAdminGateway implements AdminGateway {
  SupabaseAdminGateway(this.client);
  final SupabaseClient client;

  @override
  AdminAccess get access {
    final session = client.auth.currentSession;
    return AdminAccess(
      userId: session?.user.id,
      email: session?.user.email,
      isAdmin: session?.user.appMetadata['role'] == 'admin',
      aal2:
          session != null &&
          client.auth.mfa.getAuthenticatorAssuranceLevel().currentLevel ==
              AuthenticatorAssuranceLevels.aal2,
    );
  }

  @override
  Stream<void> get changes => client.auth.onAuthStateChange.map((_) {});

  @override
  Future<void> signIn() async {
    final launched = await client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: Uri.base.replace(fragment: '', query: '').toString(),
    );
    if (!launched) throw StateError('OAuth could not open');
  }

  @override
  Future<void> signOut() => client.auth.signOut(scope: SignOutScope.local);

  @override
  Future<List<Factor>> listFactors() async =>
      (await client.auth.mfa.listFactors()).all;

  @override
  Future<AuthMFAEnrollResponse> enroll({
    required FactorType type,
    required String name,
    String? phone,
  }) => client.auth.mfa.enroll(
    factorType: type,
    friendlyName: name,
    issuer: type == FactorType.totp ? '停車指南管理' : null,
    phone: phone,
  );

  @override
  Future<AuthMFAChallengeResponse> challenge(
    String factorId,
    FactorType type,
  ) => client.auth.mfa.challenge(
    factorId: factorId,
    channel: type == FactorType.phone ? OtpChannel.sms : null,
  );

  @override
  Future<void> verify(String factorId, String challengeId, String code) async {
    await client.auth.mfa.verify(
      factorId: factorId,
      challengeId: challengeId,
      code: code,
    );
  }

  @override
  Future<void> cancelEnrollment(String factorId) async {
    await client.auth.mfa.unenroll(factorId);
  }

  @override
  Future<int> pendingCount() => client
      .from('moderation_queue')
      .count(CountOption.exact)
      .eq('status', 'pending');
}
