# Backlog de fondation

## À faire avant validation complète de la phase 1

- Exécuter `flutter pub get`, `dart format lib test`, `flutter analyze`, `flutter test` et `flutter build apk --debug`.
- Confirmer que les licences Android sont acceptées et valider l'écran sur un émulateur/appareil.
- Faire compiler le projet iOS sur une machine macOS avec Xcode.
- Choisir un identifiant de bundle officiel et vérifier les métadonnées des plateformes.
- Vérifier l'initialisation du dépôt Git local et créer un commit après revue.

## Hors phase 1

- Authentification réelle et gestion des rôles.
- Migrations PostgreSQL, RLS, API et projet Supabase.
- Parcours de collecte/paiement, reçus, caisse, notifications et rapports.
- Persistance sécurisée et synchronisation hors-ligne.

## Phase 3 — Vérifications et compléments

- Exécuter `flutter pub get`, `dart format lib test`, `flutter analyze` et `flutter test`.
- Tester connexion/récupération sur appareils Android et iOS avec comptes de rôle actif, suspendu et sans rôle.
- Exécuter `npx supabase start` puis `npx supabase test db`; examiner les migrations 007–010 et faire un dry-run avant push.
- Tester la requête de recherche, l’agenda, la collecte idempotente et la caisse avec des jeux de test par organisation.
- Définir les autorisations serveur pour créer/modifier contribuables et établissements avant d'ajouter ces formulaires.
- Ajouter cache hors-ligne chiffré et stratégie de synchronisation/reprise durable après fermeture de l'application.
- Ajouter génération/partage de PDF et webhook de paiement seulement avec fournisseurs et spécifications validés.

## Phase 4 — Vérifications restantes

- Exécuter `flutter pub get`, `dart format lib test`, `flutter analyze` et `flutter test`.
- Vérifier le test `offline_store_test.dart` avec SQLite FFI et corriger toute erreur de plateforme.
- Revoir les migrations 012–013, exécuter `npx supabase test db`, `npx supabase db push --dry-run`, puis appliquer explicitement.
- Tester session expirée, état Auth suspendu, accès cache de 24 h, changement de compte, cache expiré et outbox après redémarrage téléphone.
- Tester réponse perdue après commit, double tap, clé d'idempotence dupliquée, tentative maximale et opérateur `needsAttention`.
- Tester permission GPS refusée, GPS désactivé, précision >100 m, position GPS conservée hors ligne puis synchronisée.
- Faire les tests Android sur appareil et iOS sur un Mac/Xcode; les tâches background ne sont pas une garantie.
