# Sécurité

## Frontière client/serveur

Le mobile n'utilise qu'une URL Supabase et une clé publishable. Les autorisations reposent sur Auth, les permissions PostgreSQL et RLS. Aucune clé `service_role`, aucun mot de passe PostgreSQL ni token privé ne doivent être compilés dans l'application ou versionnés.

Tout credential publié dans une conversation ou un terminal partagé doit être révoqué/renouvelé. Évite de passer un token comme argument de commande, car il peut rester dans l'historique.

## Rôles et périmètres

- `super_admin` : rôle global, opérations privilégiées réservées à un canal opérateur.
- `admin` : administration de son organisation; attribution de ce rôle réservée au super-admin.
- `client` : contribuable; lecture limitée aux contribuables rattachés via `link_client_taxpayer` (permission `profile.manage`), aux établissements et obligations associés, et à l'historique de ses paiements (tous statuts, reçu si confirmé) via la RPC `client_payments`. Aucune permission d'organisation, aucun accès direct aux collectes, zones ou missions. Le client ne modifie que son nom d'affichage et son téléphone.
- `collector` : ne peut ni se rattacher à une organisation, ni modifier son statut ou ses rôles, ni s'affecter des missions (privilèges vérifiés par `supabase/tests/role_boundaries.test.sql`). L'option d'encaissement n'apparaît qu'avec `payment.record`, revérifiée par la RPC.
- `supervisor` : missions et données des zones supervisées.
- `collector` : affectations, établissements de ses missions, collectes et demandes de paiement; aucune confirmation financière.
- `cashier` : caisse affectée et confirmations espèces autorisées; pas de lecture générale des obligations.
- `auditor` : lecture financière et audit dans son organisation, sans mutation.
- `direction` : consultation organisationnelle, sans mutation.

Les 24 tables ont RLS. Les clients ne peuvent pas écrire directement les rôles ni les tables financières. Le profil Auth créé est `pending`; le client ne peut modifier que nom et téléphone. Les chemins du dashboard vérifient aussi rôle actif et organisation.

## Opérations sensibles

- `confirm_external_payment_verified` n'est exécutable que par `service_role` et vérifie montant, devise et transaction rattachée; une Edge Function doit vérifier la signature du fournisseur avant l'appel.
- `confirm_cash_payment` verrouille paiement et obligation, vérifie le caissier et la caisse ouverte, puis met à jour obligation, mouvement, reçu et audit dans une transaction.
- Les clés d'idempotence sont uniques par organisation; les références fournisseur sont uniques lorsqu'elles existent.
- Les reçus sont annulés avec motif et journalisation; les journaux d'audit sont append-only.

## Risques restant à traiter

- Les tests pgTAP sont écrits mais pas exécutés faute de PostgreSQL local/CLI disponible dans cette session.
- Ajouter des scénarios RLS multi-utilisateurs avec deux organisations et tous les rôles.
- Implémenter le webhook et sa vérification cryptographique, le provisionnement initial du super-admin, la révocation de rôles, les transitions d'échec/remboursement, le contrôle de débit et les règles de rétention.
- Les six migrations initiales ont été poussées le 2026-10-21 selon la sortie CLI fournie. Les tests pgTAP distants et les scénarios multi-rôles restent à exécuter.
- Les migrations 007–011 de phase 3 ne sont pas encore appliquées; les nouveaux écrans Agenda/Caisse/Collectes et la distinction contribuable ne fonctionneront complètement qu'après test et déploiement contrôlé.
- Le cache SQLite et l'outbox sont chiffrés par payload; les métadonnées structurelles restent visibles et un appareil compromis peut exposer la clé du coffre natif. Voir [OFFLINE_SYNC.md](OFFLINE_SYNC.md).
- Une autorisation offline repose sur le dernier profil/rôle cache inférieur à 24 h; un changement distant d'état pendant une coupure ne peut être connu avant reconnexion. Les transactions financières restent pending jusqu'au serveur.

## Audit mobile du 2026-10-27

Corrigé :
- Permission `INTERNET` absente du manifeste principal : un APK release installé ne pouvait pas joindre Supabase.
- Sauvegarde Android : `allowBackup=false` complété par `fullBackupContent=false` et `data_extraction_rules.xml` (Android 12+, cloud et transfert entre appareils), trafic en clair interdit.
- Journaux : les traces d'authentification ne sont émises qu'en debug (`kDebugMode`) et ne contiennent plus l'adresse e-mail.
- Récupération de mot de passe : l'événement `passwordRecovery` dirige vers `/reset-password` ; hors d'un lien de récupération, cet écran est inaccessible. Bouton d'annulation avec déconnexion.
- Signature release : lue depuis `android/key.properties` (exclu de git) ; à défaut, clé de debug réservée aux essais locaux.

Vérifié sans défaut : session et verifier PKCE dans `flutter_secure_storage` ; cache hors ligne chiffré AES-256-GCM, clé dans le stockage sécurisé, purgé à la déconnexion et expiré après 24 h ; seule la clé publishable est embarquée ; ATS iOS par défaut (HTTPS uniquement).

Reste à décider :
- Identifiant d'application `com.example.terenza` (Android et iOS) : à remplacer par l'identifiant officiel avant toute publication ; le changer crée une nouvelle application pour les magasins.
- Création du keystore de production et conservation hors dépôt.
