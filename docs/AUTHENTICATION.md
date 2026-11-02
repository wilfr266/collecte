# Authentification

Supabase Auth est initialisé en PKCE à partir de la configuration d'environnement. L'application fournit connexion email/mot de passe, déconnexion, récupération et réinitialisation du mot de passe. Le SDK renouvelle les sessions; session et verifier PKCE sont stockés dans `flutter_secure_storage` via des adaptateurs `LocalStorage`/`GotrueAsyncStorage`.

Un déclencheur crée un profil `pending` sans rôle ni organisation; un opérateur doit l'activer et l'affecter.

## Statut et rôles

Le statut (`profiles.status`) dit si le compte peut fonctionner; le rôle (`user_roles.role_key`) dit ce qu'il peut faire. Le gate vérifie dans l'ordre : profil `active`, rôles effectifs, rattachement à une organisation (sauf `super_admin`, rôle global), puis ouvre l'espace mobile principal :

| Rôle | Espace mobile | Route d'accueil |
| --- | --- | --- |
| `super_admin`, `admin` | Administration (consultation, fonctions filtrées par `role_permissions`) | `/admin` |
| `collector` | Espace collecteur (terrain, collectes, caisse) | `/dashboard` |
| `client` | Espace client (obligations et reçus confirmés des contribuables rattachés) | `/client` |
| `supervisor`, `cashier`, `auditor`, `direction` | Aucun — back-office web | — |

Priorité en cas de cumul : administration > collecteur > client; le profil permet de basculer entre espaces. Comme `public.has_role`, un rôle d'organisation ne compte que pour l'organisation du profil.

## Routage centralisé

- `UserProfile` (`domain/user_profile.dart`) remplace `CollectorProfile` : profil commun à tous les rôles, sans donnée propre à un espace.
- `resolveAccess` (`domain/access_decision.dart`, fonction pure testée) produit une `AccessDecision` : `AccessNotConfigured`, `AccessSignedOut`, `AccessChecking`, `AccessUnavailable` (erreur + réessai), `AccessDenied` (motif) ou `AccessGranted` (rôles, espaces, mode hors ligne).
- `accessDecisionProvider` combine session, profil, rôles et réseau. `currentUserIdProvider` réinitialise profil et rôles à la déconnexion ou au changement de compte, pas au simple renouvellement de jeton; une actualisation conserve la dernière valeur connue.
- `accessRedirect` est l'unique redirection du `GoRouter`, rafraîchi à chaque changement de décision. Tout état autre que `AccessGranted` ramène sur `/auth`; une route d'un autre espace renvoie à l'accueil du rôle. L'accès n'est jamais ouvert par défaut.
- Hors ligne, seul un accès `collector` vérifié depuis moins de 24 h ouvre l'espace collecteur (`/offline`).

| Situation | Écran |
| --- | --- |
| `pending` | Compte en attente d'approbation, « Vérifier à nouveau » |
| `suspended` / `disabled` | Écran adapté, déconnexion seulement |
| Statut inconnu | Refus (mise à jour requise) |
| Actif sans organisation | Rattachement requis : email et identifiant copiable à transmettre |
| Sans rôle mobile | Refus contrôlé |
| Profil/rôles non chargés | Erreur explicite, « Réessayer » |

## Statuts

`public.profile_status` ne contient que `pending`, `active`, `suspended`, `disabled`. Il n'existe ni `approved` ni `rejected` : l'approbation consiste à passer le compte à `active`, et aucun statut ne distingue un refus d'une désactivation. Toute valeur inconnue (dont `approved`/`rejected`) est refusée par l'application. Ajouter ces statuts exige une décision métier et une migration de l'enum et des helpers `has_role`/`has_permission`.

La connexion par identifiant métier n'est pas activée : elle nécessite une décision produit et une résolution serveur qui ne révèle pas l'existence d'un compte.

La connexion appelle Supabase Auth réellement. Elle doit encore être validée sur Android/iOS avec des comptes de test actifs; une session authentifiée n'a pas été testée depuis cette session.

Le statut `pending`, `suspended` ou `disabled` bloque l'accès aux données même si un JWT existe; les fonctions de sécurité vérifient l'état actif du profil. Les rôles ne sont jamais fournis par les métadonnées client.

Passer `SUPABASE_URL` et `SUPABASE_PUBLISHABLE_KEY` au lancement/build via `--dart-define`. Configurer l'URL de redirection `terenza://auth/reset-password` dans Supabase Auth et vérifier le lien entrant Android/iOS. Une clé publishable peut être embarquée; aucun secret privilégié ne le peut. Le mot de passe PostgreSQL reste réservé aux opérateurs.
