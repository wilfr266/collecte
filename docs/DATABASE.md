# Base de données TERENZA

## État et migrations

Le projet Supabase est lié localement au ref `aneccnzdxwyqveexqmap`. Selon la sortie CLI fournie le 2026-10-21, les six migrations ci-dessous ont été appliquées au projet distant et sont présentes dans les historiques local et distant. Cette vérification repose sur la sortie partagée; aucune connexion directe n'a été faite depuis cette session.

Migrations versionnées sous `supabase/migrations/` :

1. `20261021000100_identity_and_access.sql` : organisations, profils, rôles, permissions et déclencheur Auth.
2. `20261021000200_field_operations.sql` : zones, contribuables, établissements, obligations, missions, rendez-vous, collectes, notifications et audit.
3. `20261021000300_financial_operations.sql` : caisses, paiements, reçus, mouvements et rapprochements.
4. `20261021000400_access_helpers.sql` : fonctions de contrôle tenant/rôle.
5. `20261021000500_row_level_security.sql` : privilèges et RLS sur les 24 tables.
6. `20261021000600_server_operations.sql` : RPC d'affectation de rôles, collecte, paiement atomique et reçu.
7. `20261021000700_mobile_collection_flow.sql` : demande collecte/paiement atomique avec idempotence.
8. `20261021000800_appointment_lifecycle.sql` : transitions de rendez-vous et audit.
9. `20261021000900_cash_summary_and_reconciliation.sql` : solde serveur et rapprochement idempotent.
10. `20261021001000_active_user_access_hardening.sql` : contrôle du profil actif dans les helpers RLS.
11. `20261021001100_taxpayer_identity_kind.sql` : distinction personne physique/entreprise; les lignes historiques restent `unspecified` jusqu'à révision.
12. `20261021001200_visit_location.sql` : coordonnées facultatives de visite et RPC associée.
13. `20261021001300_offline_visit_submission.sql` : visite seule synchronisable sans créer de paiement.
14. `20261023000100_external_payment_lifecycle.sql` : colonnes nulles `payments.failure_reason` et `status_changed_at`, déclencheurs anti-doublon et d'immuabilité, cycle Mobile Money (`confirm_external_payment` révisée, `fail_external_payment`, `expire_stale_external_payments`). Voir `PAYMENTS.md`.
15. `20261024000100_client_role.sql` : rôle `client`, table `client_taxpayer_links`, politiques RLS de lecture client et RPC `link_client_taxpayer`, `unlink_client_taxpayer`, `client_payments`.

Les migrations 14 et 15 **ne sont pas appliquées au projet distant** : à examiner et valider avant `supabase db push`, dans cet ordre.

### Compatibilité

- Évolutions additives uniquement : aucune colonne supprimée ni renommée ; les nouvelles colonnes sont nulles pour les lignes historiques.
- Les signatures des RPC utilisées par les versions mobiles existantes (`record_collection_payment_request*`, `record_offline_visit`, `confirm_cash_payment`) sont inchangées. Une ancienne version qui exige le rôle `collector` refuse simplement un compte client.
- Le nouveau contrôle anti-doublon peut refuser (code `23505`) une seconde saisie identique en moins de 10 minutes, y compris depuis une ancienne version, qui affichera son message générique de doublon.
- Les droits sont toujours recalculés côté serveur (`has_role`, `has_permission`) ; le cache hors ligne du téléphone n'ouvre que la consultation locale et la mise en file de visites, jamais une opération financière.

Les tables couvrent `organizations`, `profiles`, `roles`, `permissions`, `user_roles`, `zones`, `taxpayers`, `establishments`, `activity_types`, `tax_types`, `financial_obligations`, `missions`, `mission_assignments`, `appointments`, `collections`, `collection_items`, `payments`, `receipts`, `cash_registers`, `cash_movements`, `cash_reconciliations`, `notifications`, `audit_logs`, ainsi que `role_permissions` pour la matrice d'accès.

## Relations structurantes

- Un contribuable est distinct de ses établissements.
- Une obligation lie contribuable, établissement, taxe et période.
- Une mission est une affectation terrain; une collecte est une visite et n'est pas un paiement.
- `collection_items` relie une collecte aux obligations concernées.
- Un paiement est créé en `pending`; sa confirmation met à jour l'obligation et crée les écritures correspondantes dans une transaction.
- Les clés étrangères composites empêchent les références inter-organisations.
- Les montants sont `numeric(14,0)` en `XOF`; aucune valeur financière n'utilise de flottant.
- Les suppressions sont généralement `RESTRICT`; l'historique financier et d'audit n'est pas effacé en cascade.

## Application en développement

Après révocation de tout identifiant partagé publiquement et authentification locale avec `npx supabase login`, depuis `collector/` :

```powershell
npx supabase link --project-ref aneccnzdxwyqveexqmap
npx supabase migration list
npx supabase start
npx supabase test db
npx supabase db push --dry-run
```

Les migrations 007–013 sont ajoutées localement après le déploiement initial; vérifie les tests et le dry-run, puis applique-les seulement après revue :

```powershell
npx supabase db push
npx supabase migration list
```

Ne passe pas de mot de passe PostgreSQL ou de token dans une commande, dans Flutter ou dans Git. Ne lance aucun reset sur une base contenant des données utiles.

## Provisionnement initial

Les comptes Auth démarrent `pending`, sans organisation ni rôle. La création de l'organisation, l'activation du profil et la promotion du premier admin sont réservées à une opération opérateur contrôlée.
