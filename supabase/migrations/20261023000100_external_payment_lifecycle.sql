-- Cycle de vie des paiements externes (Mobile Money, virement, carte) et
-- garde-fous communs, sur la table `payments` existante.
--
-- Prérequis : 20261021000600 (payments, confirm_external_payment,
-- receipt_number_seq) et 20261021000700 (record_collection_payment_request,
-- qui verrouille l'obligation avant l'insertion).
--
-- Aucune nouvelle source de paiement : les statuts restent ceux de
-- `public.payment_status`. Seul le backend de confiance (`service_role`,
-- après vérification de la signature du fournisseur) fait évoluer un
-- paiement externe ; l'application mobile ne peut que le lire.

-- ── Colonnes additionnelles (nulles pour l'historique) ──────────────────────

alter table public.payments
  add column failure_reason text,
  add column status_changed_at timestamptz;

-- Toutes les lignes existantes ont failure_reason nul : la validation passe.
alter table public.payments
  add constraint payments_failure_reason_check check (
    failure_reason is null
    or (status = 'failed'
      and failure_reason in ('provider_failed', 'cancelled', 'timeout', 'late_success_needs_review'))
  );

create index payments_pending_external_idx
  on public.payments (created_at)
  where status = 'pending' and method in ('mobile_money', 'bank_transfer', 'card');

-- ── Garde-fous ──────────────────────────────────────────────────────────────

-- Les éléments constitutifs d'un paiement ne changent jamais après
-- création ; un paiement confirmé ne peut plus que rester confirmé ou être
-- marqué remboursé. S'applique aussi aux fonctions security definer.
-- `is distinct from` : comparaison sûre même si une colonne devenait
-- nullable lors d'une évolution future.
create function public.guard_payment_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.organization_id is distinct from old.organization_id
    or new.collection_id is distinct from old.collection_id
    or new.collection_item_id is distinct from old.collection_item_id
    or new.amount is distinct from old.amount
    or new.currency_code is distinct from old.currency_code
    or new.method is distinct from old.method
    or new.idempotency_key is distinct from old.idempotency_key
    or new.recorded_by is distinct from old.recorded_by
    or new.created_at is distinct from old.created_at then
    raise exception using errcode = '42501', message = 'Payment core fields are immutable';
  end if;

  if old.status = 'confirmed' and new.status not in ('confirmed', 'reversed') then
    raise exception using errcode = '42501', message = 'A confirmed payment cannot change status';
  end if;

  if old.status = 'confirmed'
    and (new.confirmed_at is distinct from old.confirmed_at
      or new.provider is distinct from old.provider
      or new.provider_reference is distinct from old.provider_reference
      or new.cash_register_id is distinct from old.cash_register_id) then
    raise exception using errcode = '42501', message = 'A confirmed payment cannot be edited';
  end if;

  if old.status = 'reversed' and new is distinct from old then
    raise exception using errcode = '42501', message = 'A reversed payment is final';
  end if;

  -- Horodatage commun à tous les chemins (y compris confirm_cash_payment).
  if new.status is distinct from old.status then
    new.status_changed_at := now();
  end if;

  return new;
end;
$$;

create trigger payments_guard_update
  before update on public.payments
  for each row execute function public.guard_payment_update();

-- Doublon probable : même collecteur, même obligation, même montant, même
-- mode, encore en attente, saisi depuis moins de 10 minutes avec une autre
-- clé d'idempotence. Les relances avec la même clé sont traitées en amont
-- par les RPC et ne déclenchent pas ce contrôle.
--
-- Concurrence : le verrou sur l'obligation sérialise deux insertions
-- simultanées pour la même obligation. En READ COMMITTED (défaut Supabase),
-- la requête de contrôle qui suit le verrou prend un nouvel instantané et
-- voit donc le paiement validé par la transaction concurrente. Les RPC
-- existantes verrouillent déjà cette ligne avant d'insérer : l'ordre des
-- verrous est identique, sans risque d'interblocage.
create function public.prevent_duplicate_payment_request()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_obligation_id uuid;
begin
  select ci.obligation_id into v_obligation_id
  from public.collection_items ci
  where ci.id = new.collection_item_id
    and ci.organization_id = new.organization_id;

  perform 1
  from public.financial_obligations fo
  where fo.id = v_obligation_id
    and fo.organization_id = new.organization_id
  for update;

  if exists (
    select 1
    from public.payments p
    join public.collection_items ci
      on ci.id = p.collection_item_id and ci.organization_id = p.organization_id
    where p.organization_id = new.organization_id
      and ci.obligation_id = v_obligation_id
      and p.recorded_by = new.recorded_by
      and p.amount = new.amount
      and p.method = new.method
      and p.status = 'pending'
      and p.created_at > now() - interval '10 minutes'
  ) then
    raise exception using errcode = '23505',
      message = 'A similar pending payment was recorded less than 10 minutes ago';
  end if;

  return new;
end;
$$;

create trigger payments_prevent_duplicate
  before insert on public.payments
  for each row execute function public.prevent_duplicate_payment_request();

revoke all on function public.guard_payment_update() from public, anon, authenticated;
revoke all on function public.prevent_duplicate_payment_request() from public, anon, authenticated;

-- ── Initiation par le prestataire ───────────────────────────────────────────

-- Le serveur d'intégration rattache la référence du prestataire au paiement
-- `pending` au moment de l'initiation. Seuls les paiements ainsi rattachés
-- sont soumis à l'expiration automatique : une déclaration Mobile Money
-- saisie par un collecteur sans intégration n'est jamais expirée.
create function public.register_external_payment_initiation(
  p_payment_id uuid,
  p_provider text,
  p_provider_reference text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
begin
  if p_provider is null or length(btrim(p_provider)) = 0
    or p_provider_reference is null or length(btrim(p_provider_reference)) = 0 then
    raise exception using errcode = '22023', message = 'Provider and provider reference are required';
  end if;

  select p.* into v_payment from public.payments p where p.id = p_payment_id for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;

  if v_payment.provider = btrim(p_provider)
    and v_payment.provider_reference = btrim(p_provider_reference) then
    return;
  end if;

  if v_payment.status <> 'pending'
    or v_payment.method not in ('mobile_money', 'bank_transfer', 'card')
    or v_payment.provider is not null then
    raise exception using errcode = '22023', message = 'Payment cannot be attached to a provider transaction';
  end if;

  update public.payments
  set provider = btrim(p_provider), provider_reference = btrim(p_provider_reference)
  where id = v_payment.id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_payment.organization_id, null, 'payment.initiated.external', 'payments', v_payment.id,
    jsonb_build_object('provider', btrim(p_provider), 'provider_reference', btrim(p_provider_reference)));
end;
$$;

-- ── Confirmation externe vérifiée ───────────────────────────────────────────

-- Remplace l'usage de confirm_external_payment(uuid, text, text), qui ne
-- contrôlait ni le montant ni la devise notifiés. L'ancienne fonction est
-- conservée (aucune suppression) mais n'est plus exécutable par service_role.
--
-- - le montant et la devise notifiés doivent égaler ceux du paiement ;
-- - si une référence a été rattachée à l'initiation, elle doit correspondre ;
-- - une notification tardive (paiement passé en `timeout`) peut encore
--   confirmer si le solde le permet, sinon le paiement passe en
--   `late_success_needs_review` pour traitement manuel ;
-- - une notification rejouée renvoie le reçu existant.
create function public.confirm_external_payment_verified(
  p_payment_id uuid,
  p_provider text,
  p_provider_reference text,
  p_amount numeric(14, 0),
  p_currency_code text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
  v_obligation_id uuid;
  v_remaining numeric(14, 0);
  v_receipt_id uuid;
  v_receipt_number text;
  v_is_late boolean;
begin
  if p_provider is null or length(btrim(p_provider)) = 0
    or p_provider_reference is null or length(btrim(p_provider_reference)) = 0 then
    raise exception using errcode = '22023', message = 'Provider and provider reference are required';
  end if;

  select p.* into v_payment
  from public.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;

  if p_amount is distinct from v_payment.amount
    or p_currency_code is distinct from v_payment.currency_code then
    raise exception using errcode = '22023', message = 'Notified amount or currency does not match the payment';
  end if;

  if v_payment.provider is not null
    and (v_payment.provider <> btrim(p_provider)
      or v_payment.provider_reference is distinct from btrim(p_provider_reference)) then
    raise exception using errcode = '22023', message = 'Provider transaction does not match the payment';
  end if;

  -- Notification rejouée : réponse idempotente.
  if v_payment.status = 'confirmed' then
    select r.id into v_receipt_id from public.receipts r where r.payment_id = v_payment.id;
    return v_receipt_id;
  end if;

  v_is_late := v_payment.status = 'failed' and v_payment.failure_reason = 'timeout';

  if v_payment.method not in ('mobile_money', 'bank_transfer', 'card')
    or not (v_payment.status = 'pending' or v_is_late) then
    raise exception using errcode = '22023', message = 'Payment cannot be externally confirmed';
  end if;

  select ci.obligation_id into v_obligation_id
  from public.collection_items ci
  where ci.id = v_payment.collection_item_id
    and ci.collection_id = v_payment.collection_id
    and ci.organization_id = v_payment.organization_id;

  select fo.amount_due - fo.amount_paid into v_remaining
  from public.financial_obligations fo
  where fo.id = v_obligation_id
    and fo.organization_id = v_payment.organization_id
    and fo.status in ('open', 'partial')
  for update;

  if not found or v_payment.amount > v_remaining then
    if v_is_late then
      update public.payments
      set failure_reason = 'late_success_needs_review',
          provider = btrim(p_provider),
          provider_reference = btrim(p_provider_reference)
      where id = v_payment.id;

      insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
      values (v_payment.organization_id, null, 'payment.late_success_needs_review', 'payments', v_payment.id,
        jsonb_build_object('provider', btrim(p_provider), 'provider_reference', btrim(p_provider_reference)));
      return null;
    end if;
    raise exception using errcode = '22023', message = 'Payment exceeds remaining obligation';
  end if;

  update public.payments
  set status = 'confirmed',
      provider = btrim(p_provider),
      provider_reference = btrim(p_provider_reference),
      failure_reason = null,
      confirmed_at = now()
  where id = v_payment.id;

  update public.financial_obligations
  set amount_paid = amount_paid + v_payment.amount,
      status = case
        when amount_paid + v_payment.amount = amount_due then 'paid'
        else 'partial'
      end
  where id = v_obligation_id;

  v_receipt_number := 'R-' || to_char(clock_timestamp(), 'YYYY') || '-'
    || lpad(nextval('public.receipt_number_seq')::text, 8, '0');
  insert into public.receipts (organization_id, payment_id, receipt_number)
  values (v_payment.organization_id, v_payment.id, v_receipt_number)
  returning id into v_receipt_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_payment.organization_id, null,
    case when v_is_late then 'payment.confirmed.external_late' else 'payment.confirmed.external' end,
    'payments', v_payment.id,
    jsonb_build_object('provider', btrim(p_provider), 'provider_reference', btrim(p_provider_reference),
      'amount', p_amount, 'currency_code', p_currency_code));

  return v_receipt_id;
end;
$$;

-- ── Échec, annulation, délai d'attente ──────────────────────────────────────

-- Échec ou annulation notifiés par le fournisseur. Idempotent. Un échec
-- reçu après confirmation, remboursement ou mise en vérification est ignoré
-- et tracé : il ne défait jamais un état plus avancé.
create function public.fail_external_payment(
  p_payment_id uuid,
  p_provider text,
  p_provider_reference text,
  p_reason text
)
returns public.payment_status
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
begin
  if p_reason is null or p_reason not in ('provider_failed', 'cancelled') then
    raise exception using errcode = '22023', message = 'Reason must be provider_failed or cancelled';
  end if;

  select p.* into v_payment
  from public.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;

  if v_payment.method not in ('mobile_money', 'bank_transfer', 'card') then
    raise exception using errcode = '22023', message = 'Only external payments can be failed by a provider';
  end if;

  if v_payment.provider is not null
    and (v_payment.provider <> btrim(p_provider)
      or v_payment.provider_reference is distinct from btrim(p_provider_reference)) then
    raise exception using errcode = '22023', message = 'Provider transaction does not match the payment';
  end if;

  if v_payment.status in ('confirmed', 'reversed')
    or v_payment.failure_reason = 'late_success_needs_review' then
    insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
    values (v_payment.organization_id, null, 'payment.failure_ignored', 'payments', v_payment.id,
      jsonb_build_object('provider', p_provider, 'provider_reference', p_provider_reference,
        'reason', p_reason, 'current_status', v_payment.status,
        'current_failure_reason', v_payment.failure_reason));
    return v_payment.status;
  end if;

  if v_payment.status = 'failed' and v_payment.failure_reason = p_reason then
    return v_payment.status;
  end if;

  -- pending, ou failed/timeout requalifié par le verdict du prestataire.
  update public.payments
  set status = 'failed',
      failure_reason = p_reason,
      provider = coalesce(provider, nullif(btrim(p_provider), '')),
      provider_reference = coalesce(provider_reference, nullif(btrim(p_provider_reference), ''))
  where id = v_payment.id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_payment.organization_id, null, 'payment.failed.external', 'payments', v_payment.id,
    jsonb_build_object('provider', p_provider, 'provider_reference', p_provider_reference, 'reason', p_reason));

  return 'failed';
end;
$$;

-- Passe en `timeout` les paiements externes initiés auprès d'un prestataire
-- (provider renseigné) restés `pending` trop longtemps. À planifier côté
-- serveur ; une notification de succès ultérieure reste traitée par
-- confirm_external_payment_verified.
create function public.expire_stale_external_payments(
  p_older_than interval default interval '24 hours'
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if p_older_than is null or p_older_than < interval '15 minutes' then
    raise exception using errcode = '22023', message = 'Timeout must be at least 15 minutes';
  end if;

  with expired as (
    update public.payments p
    set status = 'failed', failure_reason = 'timeout'
    where p.status = 'pending'
      and p.method in ('mobile_money', 'bank_transfer', 'card')
      and p.provider is not null
      and p.created_at < now() - p_older_than
    returning p.id, p.organization_id
  ), logged as (
    insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
    select e.organization_id, null, 'payment.failed.timeout', 'payments', e.id,
      jsonb_build_object('older_than', p_older_than::text)
    from expired e
    returning 1
  )
  select count(*) into v_count from logged;

  return v_count;
end;
$$;

revoke all on function public.register_external_payment_initiation(uuid, text, text) from public, anon, authenticated;
revoke all on function public.confirm_external_payment_verified(uuid, text, text, numeric, text) from public, anon, authenticated;
revoke all on function public.fail_external_payment(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.expire_stale_external_payments(interval) from public, anon, authenticated;
grant execute on function public.register_external_payment_initiation(uuid, text, text) to service_role;
grant execute on function public.confirm_external_payment_verified(uuid, text, text, numeric, text) to service_role;
grant execute on function public.fail_external_payment(uuid, text, text, text) to service_role;
grant execute on function public.expire_stale_external_payments(interval) to service_role;

-- L'ancienne confirmation sans contrôle de montant n'est plus appelable
-- (aucun appelant n'existe dans le dépôt). Réversible par un simple grant.
revoke execute on function public.confirm_external_payment(uuid, text, text) from service_role;
