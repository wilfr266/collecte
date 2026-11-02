import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/user_profile.dart';

/// Délai maximal d'une vérification d'accès (profil, rôles, permissions).
/// Au-delà, l'écran d'erreur propose de réessayer au lieu d'attendre
/// indéfiniment sur un réseau dégradé.
const authRequestTimeout = Duration(seconds: 15);

class AuthRepository {
  const AuthRepository(this._client);

  final SupabaseClient _client;

  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  User? get currentUser => _client.auth.currentUser;

  Future<void> signIn({required String email, required String password}) async {
    try {
      // Sans délai, un réseau qui ne répond pas bloque le bouton indéfiniment.
      await _client.auth
          .signInWithPassword(email: email.trim(), password: password)
          .timeout(authRequestTimeout);
      _log('[Auth] signInWithPassword réussi');
    } on AuthException catch (e) {
      _log(
        '[Auth] AuthException lors de signIn — '
        'statusCode=${e.statusCode} message="${e.message}"',
      );
      rethrow;
    } catch (e) {
      _log(
        '[Auth] Erreur inattendue lors de signIn — type=${e.runtimeType} detail=$e',
      );
      rethrow;
    }
  }

  Future<void> sendPasswordReset(String email) async {
    await _client.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: 'terenza://auth/reset-password',
    );
  }

  Future<void> updatePassword(String password) async {
    await _client.auth.updateUser(UserAttributes(password: password));
  }

  Future<void> signOut() => _client.auth.signOut();

  /// Seuls `display_name` et `phone` sont modifiables par l'utilisateur
  /// (privilège colonne + politique `profiles_update_self`). Statut,
  /// organisation et rôles restent hors de portée du client.
  Future<void> updateOwnContact({
    required String displayName,
    required String? phone,
  }) async {
    final user = currentUser;
    if (user == null) throw StateError('Aucun utilisateur connecté.');
    await _client
        .from('profiles')
        .update({'display_name': displayName.trim(), 'phone': phone})
        .eq('id', user.id);
  }

  Future<UserProfile?> loadCurrentProfile() async {
    final user = currentUser;
    if (user == null) {
      _log('[Auth] loadCurrentProfile — aucun utilisateur connecté');
      return null;
    }

    try {
      final data = await _client
          .from('profiles')
          .select('id, organization_id, display_name, phone, status')
          .eq('id', user.id)
          .maybeSingle()
          .timeout(authRequestTimeout);

      if (data == null) {
        _log(
          '[Auth] loadCurrentProfile — aucune ligne dans profiles pour uid=${user.id}. '
          'Le trigger handle_new_auth_user est-il déployé ?',
        );
        return null;
      }

      final profile = UserProfile.fromMap(data);
      _log(
        '[Auth] Profil chargé — status="${profile.status.key}" '
        'organizationId=${profile.organizationId}',
      );
      return profile;
    } catch (e) {
      _log(
        '[Auth] Erreur lors du chargement du profil — '
        'type=${e.runtimeType} detail=$e',
      );
      rethrow;
    }
  }
}

/// Journal de diagnostic limité aux builds de développement : aucune donnée
/// de compte ne doit apparaître dans les journaux d'un appareil en production.
void _log(String message) {
  if (kDebugMode) debugPrint(message);
}
