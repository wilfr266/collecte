# Contrats API

La lecture PostgREST est protégée par RLS. Les écritures autorisées passent par des politiques et RPC serveur. Aucun client ne peut confirmer un paiement par mutation directe.

RPC préparées par les migrations :

- `assign_user_role(user_id, organization_id, role_key)` : attribution limitée; rôle admin/super-admin réservé au super-admin.
- `add_collection_item(collection_id, obligation_id, notes)` : calcule le solde côté serveur pour une collecte brouillon.
- `submit_collection(collection_id)` : soumet une collecte non vide appartenant au collecteur.
- `create_payment_request(collection_item_id, amount, method, idempotency_key, cash_register_id)` : vérifie l'accès et le solde; crée une demande `pending` idempotente.
- `confirm_cash_payment(payment_id)` : transaction du caissier affecté à une caisse ouverte; crée mouvement et reçu.
- `confirm_external_payment_verified(payment_id, provider, provider_reference, amount, currency_code)` : `service_role` seulement (remplace `confirm_external_payment`, désormais non exécutable), après vérification du webhook par un serveur de confiance.
- `void_receipt(receipt_id, reason)` : annulation avec motif et audit.
- `record_collection_payment_request(assignment_id, establishment_id, obligation_id, amount, method, idempotency_key, notes)` : visite, obligation associée et paiement pending dans une transaction atomique. Depuis 20261120000100, `obligation_id` est facultatif : sans échéance, la demande est rattachée à l'obligation « Encaissement » du jour (comme `record_field_payment`) ; les comptes clients liés reçoivent une notification `payment_requested`.
- `payment_request_overview(payment_id)` : statut réel, client et nombre de comptes clients notifiés d'une demande ; réservé au collecteur déclarant et à `finance.read`.
- `payments_page(..., p_min_amount, p_max_amount)` : filtre par montant ; `total_confirmed_amount` et `total_pending_amount` portent sur toute la sélection filtrée.
- `start_appointment(appointment_id)`, `finish_appointment(appointment_id, result, notes)`, `reschedule_appointment(appointment_id, new_starts_at, reason)` : transitions réservées au collecteur affecté et auditées.
- `cash_register_summary(cash_register_id)` : soldes calculés côté serveur pour une caisse accessible.
- `submit_cash_reconciliation(cash_register_id, counted_amount, idempotency_key, notes)` : rapprochement et journalisation atomiques.
- `record_offline_visit(assignment_id, establishment_id, outcome, idempotency_key, notes, location...)` : synchronise une visite sans créer de paiement.
- `record_collection_payment_request_with_location(...)` : demande de paiement transactionnelle avec coordonnées facultatives, jamais confirmée par GPS.

Montants : `numeric(14,0)` en XOF. Les migrations 001–006 ont été appliquées selon la sortie CLI partagée. Les migrations 007–013 restent locales et doivent être testées/revues avant `db push`.
