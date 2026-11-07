import 'package:motorcycle_parking/data/auth_flow.dart';

/// Records the hashed nonce of each panel; each queue gives the next result
/// (a [NativeCredential], or an [Object] to throw).
class FakeNativeIdentity implements NativeIdentity {
  final appleNonces = <String>[];
  final googleNonces = <String>[];
  final appleResults = <Object>[];
  final googleResults = <Object>[];

  Future<NativeCredential> _next(List<Object> queue, String token) async {
    final Object next = queue.isEmpty
        ? NativeCredential(idToken: token)
        : queue.removeAt(0);
    if (next is NativeCredential) return next;
    throw next;
  }

  @override
  Future<NativeCredential> apple(String hashedNonce) {
    appleNonces.add(hashedNonce);
    return _next(appleResults, 'apple-id-token');
  }

  @override
  Future<NativeCredential> google(String hashedNonce) {
    googleNonces.add(hashedNonce);
    return _next(googleResults, 'google-id-token');
  }
}
