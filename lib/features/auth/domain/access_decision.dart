import 'user_profile.dart';
import 'user_role.dart';

/// Résultat unique du contrôle d'accès, consommé par le routeur et le gate.
///
/// Toute vérification incomplète ou en échec produit un état non accordé :
/// l'accès n'est jamais ouvert par défaut.
sealed class AccessDecision {
  const AccessDecision();
}

/// Supabase n'est pas configuré ou n'a pas pu être initialisé.
class AccessNotConfigured extends AccessDecision {
  const AccessNotConfigured({required this.configured});

  final bool configured;
}

class AccessSignedOut extends AccessDecision {
  const AccessSignedOut();
}

/// Profil ou rôles en cours de chargement.
class AccessChecking extends AccessDecision {
  const AccessChecking();
}

/// Profil ou autorisations impossibles à charger ; l'utilisateur peut
/// réessayer.
class AccessUnavailable extends AccessDecision {
  const AccessUnavailable(this.message);

  final String message;
}

enum AccessDenialReason {
  missingProfile,
  pending,
  suspended,
  disabled,
  unknownStatus,

  /// Profil actif sans organisation (rattachement requis).
  unassigned,

  /// Profil actif rattaché, sans rôle ouvrant un espace mobile.
  noMobileRole,
}

class AccessDenied extends AccessDecision {
  const AccessDenied(this.reason);

  final AccessDenialReason reason;
}

class AccessGranted extends AccessDecision {
  const AccessGranted({
    required this.roles,
    required this.spaces,
    this.offline = false,
  });

  final List<UserRole> roles;

  /// Espaces ouverts, triés par priorité ; jamais vide.
  final List<MobileSpace> spaces;

  /// Accès collecteur restreint issu du cache local (≤ 24 h).
  final bool offline;

  MobileSpace get primarySpace => spaces.first;

  String get homeRoute => offline ? '/offline' : primarySpace.homeRoute;

  bool canOpen(String path) => canAccessRoute(roles, path);
}

/// Règle d'accès en ligne : statut → rôles → organisation → espace.
///
/// [profile] et [roles] doivent provenir de Supabase ; aucune valeur par
/// défaut ne doit être injectée en cas d'échec de chargement.
AccessDecision resolveAccess({
  required UserProfile? profile,
  required List<UserRole> roles,
}) {
  if (profile == null) {
    return const AccessDenied(AccessDenialReason.missingProfile);
  }
  switch (profile.status) {
    case AccountStatus.pending:
      return const AccessDenied(AccessDenialReason.pending);
    case AccountStatus.suspended:
      return const AccessDenied(AccessDenialReason.suspended);
    case AccountStatus.disabled:
      return const AccessDenied(AccessDenialReason.disabled);
    case AccountStatus.unknown:
      return const AccessDenied(AccessDenialReason.unknownStatus);
    case AccountStatus.active:
      break;
  }
  // Seul le super-administrateur (rôle global) fonctionne sans organisation.
  if (profile.organizationId == null && !roles.contains(UserRole.superAdmin)) {
    return const AccessDenied(AccessDenialReason.unassigned);
  }
  final spaces = availableSpaces(roles);
  if (spaces.isEmpty) {
    return const AccessDenied(AccessDenialReason.noMobileRole);
  }
  return AccessGranted(roles: roles, spaces: spaces);
}

const _publicRoutes = {'/auth', '/forgot-password'};

/// Redirection centrale du routeur ; `null` laisse la navigation se faire.
///
/// Tout état autre que [AccessGranted] ramène sur `/auth`, où le gate
/// affiche l'écran correspondant (chargement, erreur, refus).
///
/// [recoveryPending] : une session ouverte par un lien de récupération est
/// dirigée vers `/reset-password` ; hors de ce cas l'écran est inaccessible.
String? accessRedirect(
  AccessDecision decision,
  String path, {
  bool recoveryPending = false,
}) {
  if (decision is AccessSignedOut || decision is AccessNotConfigured) {
    return _publicRoutes.contains(path) ? null : '/auth';
  }
  if (recoveryPending) {
    return path == '/reset-password' ? null : '/reset-password';
  }
  if (decision is AccessGranted) {
    if (_publicRoutes.contains(path) || !decision.canOpen(path)) {
      return decision.homeRoute;
    }
    return null;
  }
  return path == '/auth' ? null : '/auth';
}
