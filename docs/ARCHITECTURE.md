# Architecture TERENZA

## État phase 3

L'application est un client Flutter partagé Android/iOS pour les collecteurs. L'authentification Supabase PKCE, le profil, la navigation terrain et les parcours alimentés par RLS sont en cours d'intégration. Aucune donnée métier ne doit être simulée lorsque Supabase est configuré.

## Découpage

- `lib/app/` : composition de l'application, routes et navigation globale.
- `lib/core/` : configuration, erreurs communes, réseau, sécurité, thème et utilitaires.
- `lib/features/<feature>/` : modules organisés en `data`, `domain` et `presentation` quand leur périmètre sera défini.
- `lib/shared/widgets/` : composants UI transversaux.

Les repositories et services sont indépendants des widgets. L'interface dépend d'abstractions de données; une implémentation réseau réelle sera ajoutée avec le backend, sans simuler une connexion.

## État préparé

- Riverpod fournit l'injection et l'état UI; GoRouter gère les routes.
- `AppConfig` lit `APP_ENV`, `SUPABASE_URL` et `SUPABASE_PUBLISHABLE_KEY` via `--dart-define`.
- Supabase Auth utilise PKCE et un stockage session/verifier natif chiffré.
- Le dashboard, les missions, la recherche, l'agenda, les collectes, les reçus, la caisse et les notifications utilisent des appels Supabase ciblés.
- Les opérations de collecte/paiement et de caisse passent par des RPC transactionnelles; aucun secret privilégié ne se trouve dans Flutter.

## Structure des fonctionnalités

`auth`, `dashboard`, `contributors`, `establishments`, `zones`, `missions`, `agenda`, `collections`, `payments`, `receipts`, `cash`, `reports`, `notifications` et `profile`.

Les répertoires sans implémentation sont accompagnés d'un README de périmètre; ils ne représentent pas des fonctionnalités opérationnelles.

## Configuration

Les environnements et paramètres Supabase sont passés au démarrage via `--dart-define`. Seule la clé publishable est admissible côté client. Les politiques RLS restent la frontière d'accès; les états d'interface ne remplacent jamais l'autorisation serveur.

## Évolutions

Le cache hors-ligne, les formulaires de création/édition contribuable, l'intégration d'un fournisseur de paiement, PDF/partage de reçu, les pièces jointes et plusieurs parcours de supervision restent à faire. Voir [ROADMAP.md](ROADMAP.md).
