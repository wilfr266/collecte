import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/supabase_client_provider.dart';
import '../../../core/network/offline_sync_manager.dart';
import '../data/auth_repository.dart';
import '../domain/access_decision.dart';
import '../domain/user_profile.dart';
import '../domain/user_role.dart';

// ── Repository & état d'authentification ─────────────────────────────────────

final authRepositoryProvider = Provider<AuthRepository?>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client == null ? null : AuthRepository(client);
});

final authStateProvider = StreamProvider<AuthState?>((ref) {
  final repository = ref.watch(authRepositoryProvider);
  if (repository == null) return const Stream.empty();
  return repository.authStateChanges;
});

// ── Profil & rôles ────────────────────────────────────────────────────────────

/// Identifiant de l'utilisateur connecté, recalculé à chaque événement Auth.
///
/// Un renouvellement de jeton conserve le même identifiant : les providers
/// dépendants ne sont alors pas rechargés. Une déconnexion ou un changement
/// de compte les réinitialise.
final currentUserIdProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider);
  return ref.watch(authRepositoryProvider)?.currentUser?.id;
});

/// Vrai entre l'ouverture d'un lien de récupération de mot de passe
/// (`AuthChangeEvent.passwordRecovery`) et l'enregistrement du nouveau mot
/// de passe. Le routeur force alors l'écran `/reset-password`.
class PasswordRecoveryNotifier extends Notifier<bool> {
  @override
  bool build() {
    ref.listen<AsyncValue<AuthState?>>(authStateProvider, (previous, next) {
      switch (next.valueOrNull?.event) {
        case AuthChangeEvent.passwordRecovery:
          state = true;
        case AuthChangeEvent.signedOut:
          state = false;
        default:
          break;
      }
    }, fireImmediately: true);
    return false;
  }

  void complete() => state = false;
}

final passwordRecoveryProvider =
    NotifierProvider<PasswordRecoveryNotifier, bool>(
      PasswordRecoveryNotifier.new,
    );

final currentProfileProvider = FutureProvider.autoDispose<UserProfile?>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return null;
  return ref.watch(authRepositoryProvider)?.loadCurrentProfile();
});

/// Retourne les clés de rôle effectives de l'utilisateur courant.
///
/// Reproduit la règle de `public.has_role` : un rôle d'organisation ne compte
/// que pour l'organisation du profil, le rôle global `super_admin` compte
/// sans organisation. Retourne `[]` si le profil est absent ou inactif.
final currentRoleKeysProvider = FutureProvider.autoDispose<List<String>>((
  ref,
) async {
  final client = ref.watch(supabaseClientProvider);
  final profile = await ref.watch(currentProfileProvider.future);
  if (client == null || profile == null || !profile.isActive) {
    return [];
  }

  try {
    final rows = await client
        .from('user_roles')
        .select('role_key, organization_id')
        .eq('user_id', profile.id)
        .timeout(authRequestTimeout);

    final keys = effectiveRoleKeys(rows, profile.organizationId);
    _log('[Auth] Rôles récupérés pour ${profile.id} : $keys');
    return keys;
  } catch (e) {
    _log(
      '[Auth] Erreur lors de la récupération des rôles — '
      'type=${e.runtimeType} detail=$e',
    );
    rethrow;
  }
});

/// Filtre les lignes `user_roles` selon l'organisation du profil.
@visibleForTesting
List<String> effectiveRoleKeys(
  List<Map<String, dynamic>> rows,
  String? organizationId,
) {
  final keys = <String>{};
  for (final row in rows) {
    final key = row['role_key'] as String;
    final rowOrganizationId = row['organization_id'] as String?;
    final isGlobal =
        rowOrganizationId == null && key == UserRole.superAdmin.key;
    if (isGlobal ||
        (organizationId != null && rowOrganizationId == organizationId)) {
      keys.add(key);
    }
  }
  return keys.toList();
}

/// Résout les clés brutes en valeurs [UserRole] typées.
///
/// Les clés inconnues (rôles futurs non pris en charge) sont ignorées
/// silencieusement — l'application ne plante pas si le backend évolue.
final resolvedRolesProvider = FutureProvider.autoDispose<List<UserRole>>((
  ref,
) async {
  final keys = await ref.watch(currentRoleKeysProvider.future);
  return keys.map(UserRole.fromKey).whereType<UserRole>().toList();
});

/// Permissions accordées par les rôles de l'utilisateur
/// (`public.role_permissions`).
///
/// Sert uniquement à masquer les fonctions non autorisées ; le serveur
/// revérifie chaque accès via `has_permission`. Le super-administrateur
/// dispose implicitement de toutes les permissions, comme côté SQL.
final currentPermissionsProvider = FutureProvider.autoDispose<Set<String>>((
  ref,
) async {
  final client = ref.watch(supabaseClientProvider);
  final keys = await ref.watch(currentRoleKeysProvider.future);
  if (client == null || keys.isEmpty) return {};

  final query = keys.contains(UserRole.superAdmin.key)
      ? client.from('permissions').select('key')
      : client
            .from('role_permissions')
            .select('key:permission_key')
            .inFilter('role_key', keys);
  final rows = await query.timeout(authRequestTimeout);
  return rows.map((row) => row['key'] as String).toSet();
});

// ── Accès hors ligne (collecteur) ────────────────────────────────────────────

class CachedCollectorAccess {
  const CachedCollectorAccess({
    required this.userId,
    required this.displayName,
    required this.organizationId,
    required this.cachedAt,
  });

  final String userId;
  final String displayName;
  final String organizationId;
  final DateTime cachedAt;
}

/// Vérifie le cache offline pour un accès collecteur récent (≤ 24 h).
///
/// Utilisé uniquement en mode hors ligne ; ne remplace pas la vérification
/// en ligne effectuée par [currentRoleKeysProvider].
final cachedCollectorAccessProvider =
    FutureProvider.autoDispose<CachedCollectorAccess?>((ref) async {
      final repository = ref.watch(authRepositoryProvider);
      final user = repository?.currentUser;
      final store = ref.watch(offlineStoreProvider);
      if (user == null || store == null) return null;

      final records = await store.cachedRecordsForUser(
        category: 'profile',
        userId: user.id,
      );
      if (records.isEmpty) return null;
      final record = records.first;
      final cachedAt = DateTime.tryParse(record['_cached_at'] as String? ?? '');
      if (cachedAt == null ||
          DateTime.now().difference(cachedAt.toLocal()) >
              const Duration(hours: 24)) {
        return null;
      }
      final roleKeys = (record['role_keys'] as List<dynamic>? ?? [])
          .cast<String>();
      if (record['status'] != AccountStatus.active.key ||
          !roleKeys.contains(UserRole.collector.key)) {
        return null;
      }
      final organizationId = record['organization_id'] as String?;
      if (organizationId == null) return null;

      return CachedCollectorAccess(
        userId: user.id,
        displayName: record['display_name'] as String? ?? 'Collecteur',
        organizationId: organizationId,
        cachedAt: cachedAt,
      );
    });

// ── Décision d'accès centralisée ─────────────────────────────────────────────

/// Combine configuration, session, profil et rôles en une [AccessDecision].
///
/// Pendant une actualisation, la dernière valeur connue est conservée pour
/// éviter de renvoyer l'utilisateur vers l'écran de chargement. Une erreur
/// réseau n'ouvre l'espace collecteur que si un accès vérifié de moins de
/// 24 h est en cache ; sinon l'accès reste fermé.
final accessDecisionProvider = Provider.autoDispose<AccessDecision>((ref) {
  final client = ref.watch(supabaseClientProvider);
  if (client == null) {
    return AccessNotConfigured(
      configured: ref.watch(appConfigProvider).hasSupabaseConfiguration,
    );
  }
  if (ref.watch(currentUserIdProvider) == null) return const AccessSignedOut();

  final profile = ref.watch(currentProfileProvider);
  if (profile.hasError) {
    return _offlineFallback(
      ref,
      describeAccessLoadError(profile.error!, subject: 'votre profil'),
    );
  }
  if (!profile.hasValue) return const AccessChecking();

  final value = profile.value;
  if (value == null || !value.isActive) {
    return resolveAccess(profile: value, roles: const []);
  }

  final roles = ref.watch(resolvedRolesProvider);
  if (roles.hasError) {
    return _offlineFallback(
      ref,
      describeAccessLoadError(roles.error!, subject: 'les rôles du compte'),
    );
  }
  if (!roles.hasValue) return const AccessChecking();
  return resolveAccess(profile: value, roles: roles.value!);
});

/// Message d'échec de chargement après une authentification réussie.
///
/// Distingue réseau, session expirée et refus serveur (RLS/privilèges) :
/// aucun de ces cas n'est un problème de mot de passe.
@visibleForTesting
String describeAccessLoadError(Object error, {required String subject}) {
  _log('[Auth] Échec de chargement de $subject : $error');
  if (error is PostgrestException) {
    if (error.code == '42501' || error.code == '42P01') {
      return 'Votre compte n’a pas accès à $subject. Contactez votre administrateur.';
    }
    if (error.code == 'PGRST301' || error.code == 'PGRST303') {
      return 'Votre session a expiré. Reconnectez-vous.';
    }
    return 'Impossible de charger $subject pour le moment. Réessayez dans quelques instants.';
  }
  if (error is AuthException) {
    return 'Votre session a expiré. Reconnectez-vous.';
  }
  return 'Impossible de charger $subject. Vérifiez votre connexion Internet puis réessayez.';
}

AccessDecision _offlineFallback(Ref ref, String message) {
  final syncStatus = ref.watch(offlineSyncSnapshotProvider).valueOrNull?.status;
  final networkDown =
      syncStatus == SyncStatus.offline ||
      syncStatus == SyncStatus.unstable ||
      syncStatus == SyncStatus.failed;
  if (!networkDown) return AccessUnavailable(message);
  final cached = ref.watch(cachedCollectorAccessProvider);
  if (cached.isLoading) return const AccessChecking();
  if (cached.valueOrNull == null) {
    return const AccessUnavailable(
      'Aucun accès hors ligne récent. Reconnectez-vous pour vérifier les droits.',
    );
  }
  return const AccessGranted(
    roles: [UserRole.collector],
    spaces: [MobileSpace.collector],
    offline: true,
  );
}

/// Relance toutes les vérifications d'accès (bouton « Réessayer »).
void retryAccessCheck(WidgetRef ref) {
  ref.invalidate(currentProfileProvider);
  ref.invalidate(currentRoleKeysProvider);
  ref.invalidate(cachedCollectorAccessProvider);
}

/// Journal de diagnostic limité aux builds de développement : aucune donnée
/// de compte ne doit apparaître dans les journaux d'un appareil en production.
void _log(String message) {
  if (kDebugMode) debugPrint(message);
}
