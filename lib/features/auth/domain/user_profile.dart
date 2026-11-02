/// Statut du compte — reflète exactement `public.profile_status`.
///
/// Le statut répond à « le compte est-il autorisé à fonctionner ? ». Il ne
/// dit rien des fonctions accessibles (voir `UserRole`).
///
/// Le schéma ne connaît ni `approved` ni `rejected` : un compte approuvé est
/// passé à `active` par un opérateur, et aucun statut ne distingue un refus
/// d'une désactivation. Ne pas introduire ces valeurs sans décision métier
/// et migration de l'enum.
enum AccountStatus {
  pending('pending'),
  active('active'),
  suspended('suspended'),
  disabled('disabled'),

  /// Valeur inconnue de cette version : traitée comme un refus d'accès.
  unknown('unknown');

  const AccountStatus(this.key);

  final String key;

  static AccountStatus fromKey(String? key) => AccountStatus.values.firstWhere(
    (status) => status.key == key && status != unknown,
    orElse: () => key == null ? pending : unknown,
  );

  String get label => switch (this) {
    pending => 'En attente',
    active => 'Actif',
    suspended => 'Suspendu',
    disabled => 'Désactivé',
    unknown => 'Statut inconnu',
  };
}

/// Profil commun à tous les rôles (`public.profiles`).
///
/// Les informations propres à un rôle (missions du collecteur, contribuables
/// du client…) sont chargées par chaque espace, jamais stockées ici.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.displayName,
    required this.status,
    this.organizationId,
    this.phone,
  });

  final String id;
  final String displayName;
  final AccountStatus status;
  final String? organizationId;
  final String? phone;

  bool get isActive => status == AccountStatus.active;

  factory UserProfile.fromMap(Map<String, dynamic> map) {
    return UserProfile(
      id: map['id'] as String,
      displayName: map['display_name'] as String? ?? 'Utilisateur',
      status: AccountStatus.fromKey(map['status'] as String?),
      organizationId: map['organization_id'] as String?,
      phone: map['phone'] as String?,
    );
  }
}
