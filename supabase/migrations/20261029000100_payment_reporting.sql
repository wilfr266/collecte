-- Suivi des encaissements : fuseau métier, annulation tracée d'un paiement confirmé,
-- totaux et historiques calculés par le serveur (jamais à partir d'une page chargée).
-- Source de travail : Terenza Admin. Tests pgTAP : tests/payment_reporting.test.sql.
--
-- Règles de calcul (identiques pour le collecteur, le client et l'administration) :
--   * source unique : payments ← collections (visited_at = date effective) ← establishments
--     ← taxpayers ; aucune autre table de paiements, aucun total stocké ;
--   * date effective = collections.visited_at (heure de l'encaissement sur le terrain), et non
--     payments.created_at ; jour et mois calculés dans organizations.timezone ;
--   * encaissé = statut confirmed uniquement ; en attente (pending) et annulé/rejeté
--     (failed, reversed) sont comptés à part, jamais additionnés à l'encaissé.

-- ── Correctif : plusieurs encaissements par jour et par établissement ──────
-- financial_obligations_period_idx (organisation, établissement, type, période) n'autorise
-- qu'une obligation par jour : la création d'une obligation par encaissement
-- (20261028000200) refusait donc le 2e encaissement de la journée chez un même client.
-- Désormais : une obligation « Encaissement » par établissement et par jour, dont le dû et
-- le payé sont recalculés à partir de ses paiements (en attente + confirmés / confirmés).

create function public.refresh_field_obligation(p_obligation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_due numeric(14, 0);
  v_paid numeric(14, 0);
begin
  select coalesce(sum(pay.amount) filter (where pay.status in ('pending', 'confirmed')), 0),
         coalesce(sum(pay.amount) filter (where pay.status = 'confirmed'), 0)
  into v_due, v_paid
  from public.collection_items ci
  join public.payments pay on pay.collection_item_id = ci.id and pay.organization_id = ci.organization_id
  where ci.obligation_id = p_obligation_id;

  if v_due = 0 then
    -- Tous les paiements de la journée sont annulés ou refusés (amount_due doit rester > 0).
    update public.financial_obligations set amount_paid = 0, status = 'cancelled' where id = p_obligation_id;
  else
    update public.financial_obligations
    set amount_due = v_due, amount_paid = v_paid,
        status = case when v_paid = v_due then 'paid' when v_paid = 0 then 'open' else 'partial' end
    where id = p_obligation_id;
  end if;
end;
$$;

create or replace function public.record_field_payment(
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
  v_day date;
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

  -- Obligation « Encaissement » du jour (fuseau de l'organisation), partagée par les encaissements
  -- de la journée ; son dû est relevé avant l'insertion de la ligne, puis recalculé.
  v_day := (now() at time zone public.organization_timezone(v_organization_id))::date;
  select fo.id into v_obligation_id
  from public.financial_obligations fo
  where fo.organization_id = v_organization_id and fo.establishment_id = p_establishment_id
    and fo.tax_type_id = v_tax_type_id and fo.period_start = v_day and fo.period_end = v_day
  for update;
  if v_obligation_id is null then
    insert into public.financial_obligations (
      organization_id, taxpayer_id, establishment_id, tax_type_id, period_start, period_end, due_date, amount_due
    ) values (
      v_organization_id, v_taxpayer_id, p_establishment_id, v_tax_type_id, v_day, v_day, v_day, p_amount
    ) returning id into v_obligation_id;
  else
    update public.financial_obligations
    set amount_due = case when status = 'cancelled' then p_amount else amount_due + p_amount end,
        amount_paid = case when status = 'cancelled' then 0 else amount_paid end,
        status = 'partial'
    where id = v_obligation_id;
  end if;

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
    v_receipt_number := 'R-' || to_char(clock_timestamp(), 'YYYY') || '-'
      || lpad(nextval('public.receipt_number_seq')::text, 8, '0');
    insert into public.receipts (organization_id, payment_id, receipt_number)
    values (v_organization_id, v_payment_id, v_receipt_number);
  end if;

  perform public.refresh_field_obligation(v_obligation_id);

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(),
    case when p_method = 'cash' then 'payment.confirmed.cash_collector' else 'payment.recorded.mobile_money' end,
    'payments', v_payment_id,
    jsonb_build_object('amount', p_amount, 'establishment_id', p_establishment_id, 'provider', v_provider, 'reference', v_reference));

  return query select v_payment_id, (select pay.status from public.payments pay where pay.id = v_payment_id), v_receipt_number;
end;
$$;

create or replace function public.review_mobile_money_payment(p_payment_id uuid, p_approve boolean, p_reason text default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
  v_obligation_id uuid;
  v_is_field_payment boolean;
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

  select ci.obligation_id, tt.code = 'encaissement' into v_obligation_id, v_is_field_payment
  from public.collection_items ci
  join public.financial_obligations fo on fo.id = ci.obligation_id and fo.organization_id = ci.organization_id
  join public.tax_types tt on tt.id = fo.tax_type_id and tt.organization_id = fo.organization_id
  where ci.id = v_payment.collection_item_id and ci.organization_id = v_payment.organization_id;

  if p_approve then
    update public.payments set status = 'confirmed', confirmed_at = now() where id = v_payment.id;
    if v_is_field_payment then
      perform public.refresh_field_obligation(v_obligation_id);
    else
      update public.financial_obligations
      set amount_paid = amount_paid + v_payment.amount,
          status = case when amount_paid + v_payment.amount >= amount_due then 'paid' else 'partial' end
      where id = v_obligation_id and status in ('open', 'partial') and amount_paid + v_payment.amount <= amount_due;
      if not found then
        raise exception using errcode = '22023', message = 'Payment exceeds the remaining obligation';
      end if;
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
    if v_is_field_payment then
      perform public.refresh_field_obligation(v_obligation_id);
    end if;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_payment.organization_id, auth.uid(),
    case when p_approve then 'payment.confirmed.manual_verification' else 'payment.rejected.manual_verification' end,
    'payments', v_payment.id,
    jsonb_build_object('provider', v_payment.provider, 'reference', v_payment.provider_reference, 'reason', nullif(btrim(p_reason), '')));

  return v_receipt_number;
end;
$$;

-- ── Fuseau horaire métier ───────────────────────────────────────────────────

alter table public.organizations
  add column timezone text not null default 'Africa/Abidjan';

comment on column public.organizations.timezone is
  'Fuseau IANA des journées et des mois de l''organisation (rapports, bilans). Défaut : Africa/Abidjan (UTC+0).';

-- Fuseau effectif : celui de l'organisation s'il est reconnu par PostgreSQL, sinon UTC.
create function public.organization_timezone(p_organization_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select o.timezone from public.organizations o
     where o.id = p_organization_id
       and exists (select 1 from pg_catalog.pg_timezone_names tz where tz.name = o.timezone)),
    'UTC');
$$;

-- ── Annulation d'un paiement confirmé ───────────────────────────────────────
-- Correction d'un défaut existant : payments_check imposait confirmed_at nul pour tout statut
-- autre que confirmed, alors que guard_payment_update interdit de modifier confirmed_at d'un
-- paiement confirmé : l'état « reversed » était inatteignable. Un paiement annulé garde sa
-- date de confirmation d'origine (trace).

alter table public.payments drop constraint payments_check;
alter table public.payments add constraint payments_confirmed_at_check check (
  (status in ('confirmed', 'reversed') and confirmed_at is not null)
  or (status in ('pending', 'failed') and confirmed_at is null)
);

create function public.reverse_payment(p_payment_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
  v_obligation_id uuid;
  v_is_field_payment boolean;
  v_movement_id uuid;
begin
  select pay.* into v_payment from public.payments pay where pay.id = p_payment_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;
  if public.caller_organization() is distinct from v_payment.organization_id
    or not public.has_permission(v_payment.organization_id, 'cash.manage') then
    raise exception using errcode = '42501', message = 'Only the organization administrator can cancel a payment';
  end if;
  if v_payment.status <> 'confirmed' then
    raise exception using errcode = '22023', message = 'Only a confirmed payment can be cancelled';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception using errcode = '22023', message = 'A reason of at least five characters is required';
  end if;

  update public.payments set status = 'reversed' where id = v_payment.id;

  update public.receipts
  set status = 'voided', voided_at = now(), void_reason = btrim(p_reason)
  where payment_id = v_payment.id and organization_id = v_payment.organization_id and status = 'issued';

  select ci.obligation_id, tt.code = 'encaissement' into v_obligation_id, v_is_field_payment
  from public.collection_items ci
  join public.financial_obligations fo on fo.id = ci.obligation_id and fo.organization_id = ci.organization_id
  join public.tax_types tt on tt.id = fo.tax_type_id and tt.organization_id = fo.organization_id
  where ci.id = v_payment.collection_item_id and ci.organization_id = v_payment.organization_id;

  if v_is_field_payment then
    perform public.refresh_field_obligation(v_obligation_id);
  else
    update public.financial_obligations fo
    set amount_paid = greatest(fo.amount_paid - v_payment.amount, 0),
        status = case when fo.amount_paid - v_payment.amount <= 0 then 'open' else 'partial' end
    where fo.id = v_obligation_id;
  end if;

  -- Paiement passé par une caisse : mouvement inverse, la caisse reste juste.
  if v_payment.cash_register_id is not null then
    select cm.id into v_movement_id
    from public.cash_movements cm
    where cm.payment_id = v_payment.id and cm.movement_type = 'collection'
    limit 1;
    insert into public.cash_movements (
      organization_id, cash_register_id, payment_id, movement_type, amount, idempotency_key,
      reference, actor_id, reverses_movement_id
    ) values (
      v_payment.organization_id, v_payment.cash_register_id, v_payment.id, 'reversal', v_payment.amount,
      'reversal:' || v_payment.id::text, btrim(p_reason), auth.uid(), v_movement_id
    );
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_payment.organization_id, auth.uid(), 'payment.reversed', 'payments', v_payment.id,
    jsonb_build_object('amount', v_payment.amount, 'method', v_payment.method, 'reason', btrim(p_reason)));
end;
$$;

-- ── Périmètre de lecture des encaissements ──────────────────────────────────
-- 'admin'     : finance.read dans l'organisation de l'appelant (toute l'organisation) ;
-- 'collector' : client d'une zone où le collecteur a une mission active ;
-- 'client'    : compte client lié à la fiche (auth.uid() vérifié côté serveur).
-- Lève 42501 si aucun périmètre ne s'applique.

create function public.payment_access(p_taxpayer_id uuid, out organization_id uuid, out access text)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_zone_id uuid;
begin
  if p_taxpayer_id is null then
    organization_id := public.caller_organization();
    if organization_id is not null and public.has_permission(organization_id, 'finance.read') then
      access := 'admin';
      return;
    end if;
  else
    select t.organization_id, t.zone_id into organization_id, v_zone_id
    from public.taxpayers t where t.id = p_taxpayer_id;
    if organization_id is not null then
      if public.has_permission(organization_id, 'finance.read') then
        access := 'admin';
      elsif public.can_access_zone(organization_id, v_zone_id) then
        access := 'collector';
      elsif public.is_taxpayer_client(organization_id, p_taxpayer_id) then
        access := 'client';
      end if;
      if access is not null then
        return;
      end if;
    end if;
  end if;
  raise exception using errcode = '42501', message = 'Payments are not accessible';
end;
$$;

-- ── Totaux calculés par le serveur ──────────────────────────────────────────

create function public.payment_summary(
  p_month date,
  p_taxpayer_id uuid default null,
  p_collector_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org uuid;
  v_access text;
  v_tz text;
  v_month date := date_trunc('month', coalesce(p_month, current_date))::date;
  v_next date;
  v_prev date;
  v_today date;
  v_result jsonb;
begin
  select a.organization_id, a.access into v_org, v_access from public.payment_access(p_taxpayer_id) a;
  if p_collector_id is not null and v_access <> 'admin' then
    raise exception using errcode = '42501', message = 'Collector filter is reserved to the administration';
  end if;
  v_tz := public.organization_timezone(v_org);
  v_next := (v_month + interval '1 month')::date;
  v_prev := (v_month - interval '1 month')::date;
  v_today := (now() at time zone v_tz)::date;

  with scoped as (
    select pay.amount, pay.method, pay.status, pay.recorded_by, e.taxpayer_id, c.visited_at,
      (c.visited_at at time zone v_tz)::date as day
    from public.payments pay
    join public.collections c on c.id = pay.collection_id and c.organization_id = pay.organization_id
    join public.establishments e on e.id = c.establishment_id and e.organization_id = c.organization_id
    where pay.organization_id = v_org
      and (p_taxpayer_id is null or e.taxpayer_id = p_taxpayer_id)
      and (p_collector_id is null or pay.recorded_by = p_collector_id)
  ),
  month_rows as (
    select * from scoped
    where visited_at >= (v_month::timestamp at time zone v_tz) and visited_at < (v_next::timestamp at time zone v_tz)
  ),
  prev_rows as (
    select * from scoped
    where visited_at >= (v_prev::timestamp at time zone v_tz) and visited_at < (v_month::timestamp at time zone v_tz)
  ),
  today_rows as (
    select * from scoped
    where visited_at >= (v_today::timestamp at time zone v_tz) and visited_at < ((v_today + 1)::timestamp at time zone v_tz)
  )
  select jsonb_build_object(
    'timezone', v_tz,
    'month', v_month,
    'today', jsonb_build_object(
      'date', v_today,
      'confirmed_amount', (select coalesce(sum(amount), 0) from today_rows where status = 'confirmed'),
      'confirmed_count', (select count(*) from today_rows where status = 'confirmed')
    ),
    'totals', (
      select jsonb_build_object(
        'confirmed_amount', coalesce(sum(amount) filter (where status = 'confirmed'), 0),
        'confirmed_count', count(*) filter (where status = 'confirmed'),
        'cash_amount', coalesce(sum(amount) filter (where status = 'confirmed' and method = 'cash'), 0),
        'mobile_money_amount', coalesce(sum(amount) filter (where status = 'confirmed' and method = 'mobile_money'), 0),
        'pending_amount', coalesce(sum(amount) filter (where status = 'pending'), 0),
        'pending_count', count(*) filter (where status = 'pending'),
        'cancelled_amount', coalesce(sum(amount) filter (where status in ('failed', 'reversed')), 0),
        'cancelled_count', count(*) filter (where status in ('failed', 'reversed')),
        'clients_paid', count(distinct taxpayer_id) filter (where status = 'confirmed')
      ) from month_rows
    ),
    'previous', (
      select jsonb_build_object(
        'month', v_prev,
        'confirmed_amount', coalesce(sum(amount) filter (where status = 'confirmed'), 0),
        'confirmed_count', count(*) filter (where status = 'confirmed')
      ) from prev_rows
    ),
    'by_day', coalesce((
      select jsonb_agg(jsonb_build_object('day', day, 'confirmed_amount', amount, 'confirmed_count', n) order by day)
      from (select day, sum(amount) as amount, count(*) as n from month_rows where status = 'confirmed' group by day) d
    ), '[]'::jsonb),
    'by_collector', case when v_access = 'admin' then coalesce((
      select jsonb_agg(jsonb_build_object('collector_id', g.recorded_by, 'name', pr.display_name,
        'confirmed_amount', g.amount, 'confirmed_count', g.n) order by g.amount desc)
      from (select recorded_by, sum(amount) as amount, count(*) as n from month_rows where status = 'confirmed' group by recorded_by) g
      left join public.profiles pr on pr.id = g.recorded_by
    ), '[]'::jsonb) end,
    'by_client', case when v_access = 'admin' and p_taxpayer_id is null then coalesce((
      select jsonb_agg(jsonb_build_object('taxpayer_id', g.taxpayer_id, 'name', t.legal_name,
        'confirmed_amount', g.amount, 'confirmed_count', g.n) order by g.amount desc)
      from (select taxpayer_id, sum(amount) as amount, count(*) as n from month_rows where status = 'confirmed' group by taxpayer_id) g
      left join public.taxpayers t on t.id = g.taxpayer_id
    ), '[]'::jsonb) end,
    'last_payment', (
      select jsonb_build_object('paid_at', visited_at, 'amount', amount, 'method', method, 'status', status)
      from scoped order by visited_at desc limit 1
    )
  ) into v_result;

  return v_result;
end;
$$;

-- ── Historique paginé et filtré ─────────────────────────────────────────────
-- total_count porte sur toute la sélection filtrée (et non sur la page renvoyée).
-- p_status : confirmed | pending | cancelled (failed + reversed) | null (tous).

create function public.payments_page(
  p_from date,
  p_to date,
  p_taxpayer_id uuid default null,
  p_status text default null,
  p_collector_id uuid default null,
  p_search text default null,
  p_sort text default 'date_desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  payment_id uuid,
  paid_at timestamptz,
  created_at timestamptz,
  confirmed_at timestamptz,
  status_changed_at timestamptz,
  amount numeric,
  method text,
  provider text,
  provider_reference text,
  payment_status public.payment_status,
  failure_reason text,
  taxpayer_id uuid,
  taxpayer_name text,
  establishment_name text,
  collector_id uuid,
  collector_name text,
  receipt_number text,
  receipt_status public.receipt_status,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_org uuid;
  v_access text;
  v_tz text;
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
begin
  select a.organization_id, a.access into v_org, v_access from public.payment_access(p_taxpayer_id) a;
  if p_collector_id is not null and v_access <> 'admin' then
    raise exception using errcode = '42501', message = 'Collector filter is reserved to the administration';
  end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 400 then
    raise exception using errcode = '22023', message = 'Invalid period';
  end if;
  if p_status is not null and p_status not in ('confirmed', 'pending', 'cancelled') then
    raise exception using errcode = '22023', message = 'Invalid status filter';
  end if;
  v_tz := public.organization_timezone(v_org);
  -- Jokers neutralisés : la recherche reste littérale.
  v_search := replace(replace(replace(v_search, '\', '\\'), '%', '\%'), '_', '\_');

  return query
  select pay.id, c.visited_at, pay.created_at, pay.confirmed_at, pay.status_changed_at, pay.amount, pay.method,
    pay.provider, pay.provider_reference, pay.status, pay.failure_reason, t.id, t.legal_name, e.name,
    -- Le client ne voit pas qui a encaissé (donnée interne).
    case when v_access = 'client' then null else pay.recorded_by end,
    case when v_access = 'client' then null else pr.display_name end,
    r.receipt_number, r.status,
    count(*) over ()
  from public.payments pay
  join public.collections c on c.id = pay.collection_id and c.organization_id = pay.organization_id
  join public.establishments e on e.id = c.establishment_id and e.organization_id = c.organization_id
  join public.taxpayers t on t.id = e.taxpayer_id and t.organization_id = e.organization_id
  left join public.profiles pr on pr.id = pay.recorded_by
  left join public.receipts r on r.payment_id = pay.id and r.organization_id = pay.organization_id
  where pay.organization_id = v_org
    and (p_taxpayer_id is null or t.id = p_taxpayer_id)
    and (p_collector_id is null or pay.recorded_by = p_collector_id)
    and c.visited_at >= (p_from::timestamp at time zone v_tz)
    and c.visited_at < ((p_to + 1)::timestamp at time zone v_tz)
    and (p_status is null
      or (p_status = 'confirmed' and pay.status = 'confirmed')
      or (p_status = 'pending' and pay.status = 'pending')
      or (p_status = 'cancelled' and pay.status in ('failed', 'reversed')))
    and (v_search is null
      or pay.provider_reference ilike '%' || v_search || '%'
      or r.receipt_number ilike '%' || v_search || '%'
      or pay.id::text ilike v_search || '%'
      or (v_access = 'admin' and t.legal_name ilike '%' || v_search || '%'))
  order by
    case when p_sort = 'amount_desc' then pay.amount end desc nulls last,
    case when p_sort = 'amount_asc' then pay.amount end asc nulls last,
    case when p_sort = 'date_asc' then c.visited_at end asc nulls last,
    c.visited_at desc,
    pay.id
  limit least(greatest(coalesce(p_limit, 50), 1), 200)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$$;

-- ── Index des recherches fréquentes ─────────────────────────────────────────

create index collections_org_visited_idx on public.collections (organization_id, visited_at desc);
create index collections_org_establishment_visited_idx
  on public.collections (organization_id, establishment_id, visited_at desc);
create index payments_org_status_idx on public.payments (organization_id, status);
create index payments_org_recorded_by_idx on public.payments (organization_id, recorded_by);

-- ── Droits d'exécution ──────────────────────────────────────────────────────

revoke all on function public.refresh_field_obligation(uuid) from public, anon, authenticated;
revoke all on function public.organization_timezone(uuid) from public, anon, authenticated;
revoke all on function public.payment_access(uuid) from public, anon, authenticated;
revoke all on function public.reverse_payment(uuid, text) from public, anon;
revoke all on function public.payment_summary(date, uuid, uuid) from public, anon;
revoke all on function public.payments_page(date, date, uuid, text, uuid, text, text, integer, integer) from public, anon;
grant execute on function public.reverse_payment(uuid, text) to authenticated;
grant execute on function public.payment_summary(date, uuid, uuid) to authenticated;
grant execute on function public.payments_page(date, date, uuid, text, uuid, text, text, integer, integer) to authenticated;
