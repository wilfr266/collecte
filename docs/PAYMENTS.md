# Paiements

## Source unique

Tous les paiements vivent dans `public.payments` (statuts `public.payment_status` : `pending`, `confirmed`, `failed`, `reversed`). Collecteur, caissier, rôles de lecture financière et client lisent la même ligne : RLS pour les rôles d'organisation, RPC `client_payments` pour le client. Aucun second circuit de paiement n'existe.

Chaque paiement identifie :

| Élément | Colonne / relation |
| --- | --- |
| Organisation | `payments.organization_id` |
| Client (contribuable) | `collection_id → collections.establishment_id → establishments.taxpayer_id` |
| Obligation | `collection_item_id → collection_items.obligation_id` |
| Collecteur déclarant | `payments.recorded_by` |
| Montant, mode, dates | `amount`, `method`, `created_at`, `confirmed_at`, `status_changed_at` |
| Références | `idempotency_key`, `provider_reference`, `receipts.receipt_number` |

## Espèces

1. Le collecteur (rôle `collector` + permission `payment.record`) déclare via `record_collection_payment_request` (écran Nouvelle visite → Avec demande de paiement) : paiement `pending`. Avec une échéance choisie, le montant est plafonné à son solde ; sans échéance (cas normal depuis la décision du 2026-10-27), la demande rejoint l'obligation « Encaissement » du jour de l'établissement et `refresh_field_obligation` recalcule son dû (en attente + confirmés) sans rien créditer.
2. Doublons : la même clé d'idempotence renvoie le paiement existant ; une autre clé pour la même obligation, le même montant, le même mode et le même collecteur, encore `pending` et saisie depuis moins de 10 minutes, est refusée (`payments_prevent_duplicate`). Le déclencheur verrouille l'obligation : deux saisies simultanées sont sérialisées (isolation READ COMMITTED).
3. Validation : un caissier affecté à une caisse ouverte appelle `confirm_cash_payment` → `confirmed`, mouvement de caisse, reçu, mise à jour du solde, audit.
4. Rapprochement : `cash_register_summary` et `submit_cash_reconciliation` (idempotent).

## Mobile Money, virement, carte

L'application mobile n'a aucun moyen de confirmer un paiement : la réponse de l'interface ou du SDK opérateur n'est qu'une indication. Seul un serveur de confiance utilisant `service_role`, **après vérification de la signature du fournisseur**, appelle :

| RPC (`service_role` uniquement) | Effet |
| --- | --- |
| `register_external_payment_initiation` | Rattache la transaction prestataire (`provider`, `provider_reference`) au paiement `pending` lors de l'initiation. |
| `confirm_external_payment_verified` | `pending` → `confirmed` (reçu, solde, audit) seulement si montant et devise notifiés égalent ceux du paiement et si la transaction rattachée correspond. Notification rejouée : renvoie le reçu existant. Notification tardive sur un paiement en `timeout` : confirme si le solde le permet, sinon `late_success_needs_review`. |
| `fail_external_payment` | `pending` (ou `timeout`) → `failed` (`provider_failed` / `cancelled`). Ignoré et tracé après confirmation, remboursement ou mise en vérification. |
| `expire_stale_external_payments` | Paiement initié auprès d'un prestataire et resté `pending` (24 h par défaut, minimum 15 min) → `failed` / `timeout`. Une déclaration de collecteur sans transaction rattachée n'est jamais expirée. |

`confirm_external_payment(uuid, text, text)` (sans contrôle de montant) est conservée mais n'est plus exécutable par `service_role`.

**Non implémenté (prérequis avant production)** : l'intégration d'un opérateur Mobile Money (initiation, Edge Function de webhook avec vérification cryptographique de la signature et protection contre le rejeu, puis appel de `confirm_external_payment_verified`), et la planification de `expire_stale_external_payments` (pg_cron non activé dans ce dépôt). Aucune intégration n'est simulée ; les paiements Mobile Money déclarés restent `pending` jusqu'à ce que ce serveur existe.

## Garde-fous

- Aucun utilisateur mobile n'a de privilège `UPDATE` sur `payments`, `financial_obligations` ni `INSERT` sur `receipts` : le client ne peut ni modifier son solde ni confirmer son paiement.
- `payments_guard_update` (déclencheur, s'applique aussi aux fonctions `security definer`) : montant, mode, obligation, organisation, clé et déclarant sont immuables ; un paiement confirmé ne peut que rester confirmé ou passer `reversed` ; `reversed` est définitif.
- Toutes les transitions sont tracées dans `audit_logs` (append-only).
- Le remboursement (`reversed`) n'a pas encore de RPC : il nécessite une règle métier (contre-passation de caisse, réouverture du solde, annulation du reçu).

## Affichage mobile

`lib/features/payments/domain/payment_labels.dart` centralise les libellés : « En attente de l'opérateur », « En attente de validation caisse », « Confirmé », « Annulé », « Délai dépassé », « En vérification », « Remboursé ». Aucun reçu n'est affiché tant que le serveur n'a pas confirmé.

## Notification du client (migration 20261030000100)

- **Création** : déclencheur `payments_notify_confirmed` sur `payments`, uniquement quand un paiement atteint `confirmed` (espèces du collecteur, validation Mobile Money, caisse, prestataire). Destinataires : comptes clients actifs rattachés au contribuable du paiement (`client_taxpayer_links`).
- **Contenu** : « Paiement confirmé — Votre paiement de 5 000 FCFA a été confirmé le 28/10/2026 à 16 h 30. » Montant et heure réels, fuseau de l'organisation.
- **Doublons** : index unique `(recipient_id, payment_id)` ; une relance réseau ne recrée ni paiement (clé d'idempotence) ni notification.
- **Fiabilité** : un incident de notification est tracé (`audit_logs`, `notification.failed`) sans annuler la confirmation du paiement.
- **Lecture** : RLS `notifications_read_own` inchangée ; `payment_location` vérifie le périmètre avant d'ouvrir le paiement.

## Notification d'une demande de paiement (migration 20261120000100)

- **Création** : dans `record_collection_payment_request`, après l'enregistrement de la demande, pour chaque compte client actif lié au contribuable. Titre « Demande de paiement » ; corps : montant réel, mode prévu, date et heure dans le fuseau de l'organisation, et la mention que la demande sera marquée payée après confirmation.
- **Nature** : colonne `notifications.kind` (`general`, `payment_requested`, `payment_confirmed`) ; index unique `(recipient_id, payment_id, kind)`. Une demande puis sa confirmation produisent deux notifications distinctes, jamais de doublon (relance avec la même clé : retour anticipé, aucune nouvelle notification).
- **Fiabilité** : un incident est tracé (`notification.failed`, `kind = payment_requested`) sans annuler la demande.
- **Retour au collecteur** : `payment_request_overview` indique le nombre de comptes réellement notifiés ; l'application affiche « aucune notification » si le client n'a pas de compte Terenza lié. Aucun envoi push n'est effectué (voir ci-dessous).

## Alerte sur le téléphone

| État de l'application | Comportement |
| --- | --- |
| Ouverte | Notification système (bannière, son, vibration courte) + pastille sur « Alertes » |
| En arrière-plan récent | Idem tant que le système garde l'application active |
| Fermée ou arrêtée par le système | Notification visible à la prochaine ouverture, sans vibration : un envoi push (FCM/APNs) n'est pas configuré |

Le mode silencieux, le refus de permission (Android 13+, iOS) ou les réglages du système peuvent empêcher la vibration. Une alerte par notification (date de dernière alerte conservée sur l'appareil), au plus 3 à la fois.

## Historique mensuel

`payment_months` liste les mois ayant au moins un paiement avec leur bilan, selon les mêmes règles que `payment_summary` : date effective `collections.visited_at`, mois dans `organizations.timezone`, total = paiements `confirmed` uniquement, en attente et annulés comptés à part. Le collecteur et le client ouvrent le même écran (`ClientFinanceScreen`) : totaux identiques par construction.
