/// Rôles applicatifs — reflète exactement les clés de la table `public.roles`.
///
/// **Règle d'or** : ne jamais ajouter ou renommer un rôle ici sans avoir
/// d'abord exécuté la migration SQL correspondante dans Supabase.
///
/// Le rôle répond à la question « Que peut-il faire ? ».
/// Il ne dit rien sur l'état du compte (`profiles.status`).
enum UserRole {
  superAdmin('super_admin'),
  admin('admin'),
  supervisor('supervisor'),
  collector('collector'),
  cashier('cashier'),
  auditor('auditor'),
  direction('direction'),
  client('client');

  const UserRole(this.key);

  /// Clé stockée dans `public.roles.key` et `public.user_roles.role_key`.
  final String key;

  /// Résout une clé textuelle en [UserRole].
  ///
  /// Retourne `null` si la clé est inconnue plutôt que de lancer une
  /// exception — permet d'ignorer silencieusement les rôles futurs
  /// non encore pris en charge par cette version de l'application.
  static UserRole? fromKey(String key) => UserRole.values
      .cast<UserRole?>()
      .firstWhere((r) => r?.key == key, orElse: () => null);

  // ── Propriétés sémantiques ────────────────────────────────────────────────

  /// L'utilisateur dispose de droits d'administration (super_admin ou admin).
  bool get isAdmin => this == superAdmin || this == admin;

  /// Rôle global (`user_roles.organization_id` nul).
  bool get isGlobal => this == superAdmin;

  /// Libellé lisible en français, cohérent avec `public.roles.label`.
  String get label => switch (this) {
    superAdmin => 'Super administrateur',
    admin => 'Administrateur',
    supervisor => 'Superviseur',
    collector => 'Collecteur',
    cashier => 'Caissier',
    auditor => 'Auditeur',
    direction => 'Direction',
    client => 'Client',
  };

  /// Espace mobile ouvert par ce rôle.
  ///
  /// Les rôles de back-office (superviseur, caissier, auditeur, direction)
  /// n'ont pas d'espace mobile : ils utilisent l'administration web.
  MobileSpace? get mobileSpace => switch (this) {
    superAdmin || admin => MobileSpace.admin,
    collector => MobileSpace.collector,
    client => MobileSpace.client,
    _ => null,
  };
}

/// Espaces de navigation de l'application mobile.
///
/// L'ordre de déclaration fixe la priorité de la route d'accueil quand un
/// utilisateur cumule plusieurs rôles.
enum MobileSpace {
  admin('/admin', 'Administration'),
  collector('/dashboard', 'Espace collecteur'),
  client('/client', 'Espace client');

  const MobileSpace(this.homeRoute, this.label);

  final String homeRoute;
  final String label;

  /// Routes propres à l'espace ; les routes partagées (profil,
  /// notifications) sont listées dans [sharedRoutes].
  List<String> get routes => switch (this) {
    admin => const ['/admin'],
    collector => const [
      '/dashboard',
      '/offline',
      '/missions',
      '/zones',
      '/clients',
      '/search',
      '/agenda',
      '/collections',
      '/new-collection',
      '/receipts',
      '/transactions',
      '/cash',
    ],
    client => const ['/client'],
  };

  /// Routes accessibles à tout utilisateur disposant d'au moins un espace.
  static const sharedRoutes = ['/profile', '/notifications'];

  /// Espace auquel appartient [path], `null` pour une route partagée ou
  /// inconnue.
  static MobileSpace? forPath(String path) {
    for (final space in values) {
      if (space.routes.contains(path)) return space;
    }
    return null;
  }
}

// ── Utilitaires multi-rôles ──────────────────────────────────────────────────

/// Espaces mobiles ouverts par [roles], triés par priorité.
List<MobileSpace> availableSpaces(Iterable<UserRole> roles) {
  final spaces = roles.map((r) => r.mobileSpace).whereType<MobileSpace>();
  return MobileSpace.values.where(spaces.contains).toList();
}

/// Espace principal : administration > collecteur > client.
///
/// Retourne `null` si aucun rôle ne donne accès à l'application mobile.
MobileSpace? primarySpace(Iterable<UserRole> roles) {
  final spaces = availableSpaces(roles);
  return spaces.isEmpty ? null : spaces.first;
}

/// Retourne la route d'accueil à partir d'une liste de rôles résolus.
///
/// Retourne `null` si aucun rôle ne donne accès à l'application mobile.
String? primaryRoleDestination(Iterable<UserRole> roles) =>
    primarySpace(roles)?.homeRoute;

/// Indique si [roles] autorise l'ouverture de [path].
///
/// Contrôle d'interface uniquement : les politiques RLS restent la frontière
/// d'autorisation réelle.
bool canAccessRoute(Iterable<UserRole> roles, String path) {
  final spaces = availableSpaces(roles);
  if (spaces.isEmpty) return false;
  if (MobileSpace.sharedRoutes.contains(path)) return true;
  final space = MobileSpace.forPath(path);
  return space != null && spaces.contains(space);
}
