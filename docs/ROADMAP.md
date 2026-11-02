# Feuille de route

## Phase 1 — Fondation technique

- [x] Organisation Flutter feature-first et configuration par environnement.
- [x] Navigation provisoire, Material 3 clair/sombre et écran français de démonstration.
- [x] Tests de configuration, de format monétaire et d'interface.
- [ ] Résoudre les packages et exécuter format, analyse, tests et build Android dans un terminal Flutter.
- [ ] Confirmer les licences Android et démarrer un appareil Android pour le test manuel.
- [ ] Vérifier la compilation iOS sur macOS/Xcode.
- [ ] Remplacer le bundle ID provisoire par l'identifiant officiel choisi par l'organisation.
- [ ] Vérifier l'état Git et créer un commit seulement après revue locale.

## Phase 2 — Backend et sécurité

- Valider les besoins métier et les frontières d'organisation avant de figer le schéma.
- Créer un projet Supabase de développement avec accès administrateur détenu par l'organisation.
- Concevoir migrations, rôles, permissions, Auth et politiques RLS; tester les accès autorisés et interdits.
- Connecter le client via URL et clé publishable uniquement; ne jamais embarquer `service_role`.
- Définir les transactions/idempotence pour paiements, reçus et mouvements de caisse.

## Phases ultérieures

- Parcours métier par rôle, synchronisation hors-ligne, back-office web partagé, observabilité et préparation à la publication.
- Le périmètre et les critères d'acceptation doivent être validés avant implémentation.

## Phase 3 — Application collecteur

- [x] Connexion, récupération, PKCE, stockage natif chiffré et contrôle profil/rôle.
- [x] Dashboard réel, missions affectées, recherche, notifications, reçus et caisse avec états réseau.
- [x] Demande collecte/paiement atomique avec idempotence; paiement affiché en attente jusqu'à confirmation serveur.
- [x] Agenda jour/semaine et transitions de rendez-vous via RPC.
- [ ] Exécuter `flutter pub get`, format, analyse, tests et builds Android/iOS.
- [ ] Exécuter pgTAP local, examiner les migrations 007–011 puis les appliquer au projet distant.
- [ ] Tester des comptes collecteur actif/suspendu, caissier, zones et accès croisés en deux organisations.
- [ ] Ajouter formulaires contribuable/établissement lorsque des RPC et permissions d'écriture sont validées.
- [ ] Ajouter cache hors-ligne chiffré, pièces jointes, PDF/partage de reçus et intégration d'un fournisseur externe réel.

## Phase 4 — Terrain et synchronisation

- [x] SQLite avec payloads AES-GCM, clé dans le coffre natif, cache missions/rendez-vous/établissements et outbox par compte.
- [x] États réseau/synchronisation, compteur pending, dernière synchronisation, backoff et état d'intervention requis.
- [x] Visite seule hors ligne; demande financière conservée chiffrée et jamais déclarée confirmée localement.
- [x] Localisation facultative foreground avec permissions/refus/précision et RPC serveur.
- [ ] `flutter pub get`, format, analyse et tous les tests (Flutter non exécuté depuis cette session).
- [ ] Exécuter tests FFI SQLite et pgTAP; pousser les migrations 012–013 après revue du dry-run.
- [ ] Tester redémarrage réel, expiration session, réponse après timeout, GPS et réseau instable sur Android/iOS.
- [ ] Valider la conservation GPS avec le responsable de traitement; aucune synchronisation continue en background n'est garantie.
