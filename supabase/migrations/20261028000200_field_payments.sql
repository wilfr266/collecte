-- Encaissements terrain sans montant dû préalable, vérification Mobile Money par l'admin,
-- historique et bilan d'un client.
-- Source de travail : Terenza Admin. Tests pgTAP : tests/field_payments.test.sql.
--
-- Décisions de l'organisation (2026-10-27) :
--   * espèces : le collecteur a l'argent en main → paiement confirmé et reçu émis immédiatement ;
--   * Mobile Money : aucun fournisseur intégré → paiement « en attente » avec opérateur et
--     référence, confirmé ou refusé par l'administrateur après vérification de son relevé
--     (action tracée), en attendant une vérification automatique ;
--   * aucun montant dû saisi à l'avance : le serveur crée, pour chaque encaissement, une
--     obligation « Encaissement » égale au montant. Les tables et les écrans existants
--     (payments, receipts, client_payments, rapports) restent cohérents, sans modification.

-- ── Encaissement par le collecteur ──────────────────────────────────────────

create function public.record_field_payment(
  p_establishment_id uuid,
  p_amount numeric(14, 0),
  p_method text,
  p_idempotency_key text,
  p_provider text default null,
  p_provider_reference text default null,
  p_notes text default null,
  p_latitude numeric(9, 6) default null,
  p_longitude numeric(9, 6) default null
)
returns table (payment_id uuid, payment_status public.payment_status, receipt_number text)
language plpgsql
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_organization_id uuid;
  v_taxpayer_id uuid;
  v_assignment_id uuid;
  v_tax_type_id uuid;
  v_obligation_id uuid;
  v_collection_id uuid;
  v_item_id uuid;
  v_payment_id uuid;
  v_receipt_number text;
  v_provider text := nullif(lower(btrim(p_provider)), '');
  v_reference text := nullif(btrim(p_provider_reference), '');
  v_existing record;
begin
  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = auth.uid() and p.status = 'active' and p.organization_id is not null;
  if v_organization_id is null
    or not public.has_role(v_organization_id, 'collector')
    or not public.has_permission(v_organization_id, 'payment.record') then
    raise exception using errcode = '42501', message = 'Active collector role and payment permission required';
  end if;

  if p_amount is null or p_amount <= 0 or p_amount > 100000000
    or p_method not in ('cash', 'mobile_money')
    or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'Invalid amount, method or idempotency key';
  end if;
  if p_method = 'mobile_money' and (
    v_provider is null or v_provider not in ('orange_money', 'mtn_momo', 'moov_money', 'wave', 'other')
    or v_reference is null or length(v_reference) not between 4 and 80) then
    raise exception using errcode = '22023', message = 'Mobile Money requires an operator and a transaction reference';
  end if;

  -- Relance avec la même clé (réseau coupé, double appui) : même réponse, aucun doublon.
  select pay.id, pay.status, pay.amount, pay.method, pay.recorded_by, c.establishment_id, r.receipt_number as receipt
  into v_existing
  from public.payments pay
  join public.collections c on c.id = pay.collection_id and c.organization_id = pay.organization_id
  left join public.receipts r on r.payment_id = pay.id and r.organization_id = pay.organization_id
  where pay.organization_id = v_organization_id and pay.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.amount = p_amount and v_existing.method = p_method and v_existing.recorded_by = auth.uid()
      and v_existing.establishment_id = p_establishment_id then
      return query select v_existing.id, v_existing.status, v_existing.receipt;
      return;
    end if;
    raise exception using errcode = '23505', message = 'Idempotency key was used for a different request';
  end if;

  -- Accès terrain : une affectation active du collecteur dans la zone de l'établissement.
  select ma.id, e.taxpayer_id into v_assignment_id, v_taxpayer_id
  from public.establishments e
  join public.missions m on m.zone_id = e.zone_id and m.organization_id = e.organization_id
  join public.mission_assignments ma on ma.mission_id = m.id and ma.organization_id = m.organization_id
  where e.id = p_establishment_id and e.organization_id = v_organization_id and e.is_active
    and ma.user_id = auth.uid() and m.status in ('assigned', 'in_progress')
  order by ma.assigned_at desc
  limit 1;
  if v_assignment_id is null
    or not public.can_create_collection(v_organization_id, v_assignment_id, p_establishment_id) then
    raise exception using errcode = '42501', message = 'Establishment is not in an active mission of this collector';
  end if;

  -- Double saisie probable (autre clé, mêmes valeurs, moins de 2 minutes).
  if exists (
    select 1 from public.payments pay
    join public.collections c on c.id = pay.collection_id and c.organization_id = pay.organization_id
    where pay.organization_id = v_organization_id and pay.recorded_by = auth.uid()
      and c.establishment_id = p_establishment_id and pay.amount = p_amount and pay.method = p_method
      and pay.created_at > now() - interval '2 minutes'
  ) then
    raise exception using errcode = '23505', message = 'A similar payment was recorded moments ago';
  end if;

  insert into public.tax_types (organization_id, code, label)
  values (v_organization_id, 'encaissement', 'Encaissement')
  on conflict (organization_id, code) do update set label = public.tax_types.label
  returning id into v_tax_type_id;

  insert into public.financial_obligations (
    organization_id, taxpayer_id, establishment_id, tax_type_id, period_start, period_end, due_date, amount_due
  ) values (
    v_organization_id, v_taxpayer_id, p_establishment_id, v_tax_type_id, current_date, current_date, current_date, p_amount
  ) returning id into v_obligation_id;

  insert into public.collections (
    organization_id, mission_assignment_id, establishment_id, collector_id, outcome, notes, status,
    visit_latitude, visit_longitude
  ) values (
    v_organization_id, v_assignment_id, p_establishment_id, auth.uid(), 'contacted', nullif(btrim(p_notes), ''), 'draft',
    case when p_latitude is not null and p_longitude is not null then p_latitude end,
    case when p_latitude is not null and p_longitude is not null then p_longitude end
  ) returning id into v_collection_id;

  insert into public.collection_items (organization_id, collection_id, obligation_id, amount_due_snapshot)
  values (v_organization_id, v_collection_id, v_obligation_id, p_amount)
  returning id into v_item_id;

  update public.collections set status = 'submitted' where id = v_collection_id;

  begin
    insert into public.payments (
      organization_id, collection_id, collection_item_id, amount, method, provider, provider_reference,
      idempotency_key, status, recorded_by
    ) values (
      v_organization_id, v_collection_id, v_item_id, p_amount, p_method,
      case when p_method = 'mobile_money' then v_provider end,
      case when p_method = 'mobile_money' then v_reference end,
      p_idempotency_key, 'pending', auth.uid()
    ) returning id into v_payment_id;
  exception when unique_violation then
    raise exception using errcode = '23505', message = 'This Mobile Money reference was already recorded';
  end;

  if p_method = 'cash' then
    update public.payments set status = 'confirmed', confirmed_at = now() where id = v_payment_id;
    update public.financial_obligations set amount_paid = p_amount, status = 'paid' where id = v_obligation_id;
    v_receipt_number := 'R-' || to_char(clock_timestamp(), 'YYYY') || '-'
      || lpad(nextval('public.receipt_number_seq')::text, 8, '0');
    insert into public.receipts (organization_id, payment_id, receipt_number)
    values (v_organization_id, v_payment_id, v_receipt_number);
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(),
    case when p_method = 'cash' then 'payment.confirmed.cash_collector' else 'payment.recorded.mobile_money' end,
    'payments', v_payment_id,
    jsonb_build_object('amount', p_amount, 'establishment_id', p_establishment_id, 'provider', v_provider, 'reference', v_reference));

  return query select v_payment_id, (select pay.status from public.payments pay where pay.id = v_payment_id), v_receipt_number;
end;
$$;

-- ── Vérification Mobile Money par l'administrateur ──────────────────────────

create function public.review_mobile_money_payment(p_payment_id uuid, p_approve boolean, p_reason text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
  v_obligation_id uuid;
  v_receipt_number text;
begin
  select pay.* into v_payment from public.payments pay where pay.id = p_payment_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;
  if not public.has_permission(v_payment.organization_id, 'cash.manage')
    or public.caller_organization() is distinct from v_payment.organization_id then
    raise exception using errcode = '42501', message = 'Only the organization administrator can review this payment';
  end if;
  if v_payment.status <> 'pending' or v_payment.method <> 'mobile_money' or v_payment.provider_reference is null then
    raise exception using errcode = '22023', message = 'Only a pending Mobile Money payment with a reference can be reviewed';
  end if;
  if v_payment.recorded_by = auth.uid() then
    raise exception using errcode = '42501', message = 'A payment cannot be reviewed by the person who recorded it';
  end if;

  select ci.obligation_id into v_obligation_id
  from public.collection_items ci
  where ci.id = v_payment.collection_item_id and ci.organization_id = v_payment.organization_id;

  if p_approve then
    update public.payments set status = 'confirmed', confirmed_at = now() where id = v_payment.id;
    update public.financial_obligations
    set amount_paid = amount_paid + v_payment.amount,
        status = case when amount_paid + v_payment.amount >= amount_due then 'paid' else 'partial' end
    where id = v_obligation_id and status in ('open', 'partial') and amount_paid + v_payment.amount <= amount_due;
    if not found then
      raise exception using errcode = '22023', message = 'Payment exceeds the remaining obligation';
    end if;
    v_receipt_number := 'R-' || to_char(clock_timestamp(), 'YYYY') || '-'
      || lpad(nextval('public.receipt_number_seq')::text, 8, '0');
    insert into public.receipts (organization_id, payment_id, receipt_number)
    values (v_payment.organization_id, v_payment.id, v_receipt_number);
  else
    if p_reason is null or length(btrim(p_reason)) < 5 then
      raise exception using errcode = '22023', message = 'A reason of at least five characters is required';
    end if;
    update public.payments set status = 'failed', failure_reason = 'provider_failed' where id = v_payment.id;
    -- Obligation créée pour cet encaissement uniquement : annulée avec lui.
    update public.financial_obligations fo set status = 'cancelled'
    from public.tax_types tt
    where fo.id = v_obligation_id and tt.id = fo.tax_type_id and tt.code = 'encaissement' and fo.amount_paid = 0;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_payment.organization_id, auth.uid(),
    case when p_approve then 'payment.confirmed.manual_verification' else 'payment.rejected.manual_verification' end,
    'payments', v_payment.id,
    jsonb_build_object('provider', v_payment.provider, 'reference', v_payment.provider_reference, 'reason', nullif(btrim(p_reason), '')));

  return v_receipt_number;
end;
$$;

-- ── Historique et bilan d'un client ─────────────────────────────────────────
-- Lisible par l'administration (finance.read), par un collecteur ayant accès à la zone du
-- client (mission active) et par le titulaire d'un compte client lié à la fiche.

create function public.taxpayer_payments(p_taxpayer_id uuid, p_from date, p_to date)
returns table (
  payment_id uuid,
  payment_status public.payment_status,
  failure_reason text,
  amount numeric,
  method text,
  provider text,
  provider_reference text,
  created_at timestamptz,
  confirmed_at timestamptz,
  establishment_name text,
  collector_name text,
  receipt_number text,
  receipt_status public.receipt_status
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_organization_id uuid;
  v_zone_id uuid;
begin
  select t.organization_id, t.zone_id into v_organization_id, v_zone_id
  from public.taxpayers t where t.id = p_taxpayer_id;
  if v_organization_id is null or not (
    public.has_permission(v_organization_id, 'finance.read')
    or public.can_access_zone(v_organization_id, v_zone_id)
    or public.is_taxpayer_client(v_organization_id, p_taxpayer_id)
  ) then
    raise exception using errcode = '42501', message = 'Taxpayer payments are not accessible';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then
    raise exception using errcode = '22023', message = 'Invalid period';
  end if;

  return query
  select pay.id, pay.status, pay.failure_reason, pay.amount, pay.method, pay.provider, pay.provider_reference,
    pay.created_at, pay.confirmed_at, e.name, pr.display_name, r.receipt_number, r.status
  from public.establishments e
  join public.collections c on c.establishment_id = e.id and c.organization_id = e.organization_id
  join public.payments pay on pay.collection_id = c.id and pay.organization_id = c.organization_id
  left join public.profiles pr on pr.id = pay.recorded_by
  left join public.receipts r on r.payment_id = pay.id and r.organization_id = pay.organization_id
  where e.taxpayer_id = p_taxpayer_id and e.organization_id = v_organization_id
    and pay.created_at >= p_from::timestamptz and pay.created_at < (p_to + 1)::timestamptz
  order by pay.created_at desc
  limit 1000;
end;
$$;

revoke all on function public.record_field_payment(uuid, numeric, text, text, text, text, text, numeric, numeric) from public, anon;
revoke all on function public.review_mobile_money_payment(uuid, boolean, text) from public, anon;
revoke all on function public.taxpayer_payments(uuid, date, date) from public, anon;
grant execute on function public.record_field_payment(uuid, numeric, text, text, text, text, text, numeric, numeric) to authenticated;
grant execute on function public.review_mobile_money_payment(uuid, boolean, text) to authenticated;
grant execute on function public.taxpayer_payments(uuid, date, date) to authenticated;
