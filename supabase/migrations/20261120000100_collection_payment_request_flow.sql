-- Parcours « Nouvelle visite → Avec demande de paiement » : demande sans obligation
-- préalable, notification du client à l'enregistrement de la demande, récapitulatif
-- serveur pour le collecteur et filtre par montant pour l'administration.
-- Tests pgTAP : tests/collection_payment_request_flow.test.sql.
-- Retour arrière : rollbacks/20261120000100_collection_payment_request_flow.down.sql.
--
-- Constat : depuis la décision du 2026-10-27 (20261028000200), l'organisation ne saisit
-- plus de montant dû à l'avance. record_collection_payment_request exigeait pourtant une
-- obligation ouverte existante : la liste « Obligation ouverte » de l'application restait
-- vide et le bouton « Vérifier la demande » ne s'activait jamais.
--
-- Correctif : p_obligation_id devient facultatif (même signature, aucune version mobile
-- cassée). Sans obligation, le serveur rattache la demande à l'obligation « Encaissement »
-- du jour de l'établissement, exactement comme record_field_payment, puis recalcule son
-- dû (en attente + confirmés) avec refresh_field_obligation. La demande reste `pending` :
-- aucun encaissement n'est crédité avant la confirmation existante (caisse, vérification).

-- ── 1. Notifications : nature de la notification ───────────────────────────
-- Une même demande peut produire deux notifications distinctes pour un client :
-- « demande enregistrée » puis « paiement confirmé ». L'index d'unicité inclut donc la
-- nature ; les notifications existantes liées à un paiement sont toutes des confirmations.

alter table public.notifications
  add column kind text not null default 'general'
    check (kind in ('general', 'payment_requested', 'payment_confirmed'));

update public.notifications set kind = 'payment_confirmed' where payment_id is not null;

drop index public.notifications_recipient_payment_idx;
create unique index notifications_recipient_payment_kind_idx
  on public.notifications (recipient_id, payment_id, kind)
  where payment_id is not null;

-- Seule la cible ON CONFLICT et la nature changent.
create or replace function public.notify_payment_confirmed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_at timestamptz;
  v_body text;
begin
  if tg_op = 'UPDATE' and old.status = 'confirmed' then
    return new;
  end if;

  -- Un incident de notification ne doit jamais annuler la confirmation du paiement.
  begin
    v_tz := public.organization_timezone(new.organization_id);
    v_at := coalesce(new.confirmed_at, now());
    v_body := 'Votre paiement de '
      || replace(to_char(new.amount, 'FM999,999,999,990'), ',', ' ')
      || ' FCFA a été confirmé le ' || to_char(v_at at time zone v_tz, 'DD/MM/YYYY')
      || ' à ' || to_char(v_at at time zone v_tz, 'HH24 "h" MI') || '.';

    insert into public.notifications (organization_id, recipient_id, title, body, payment_id, kind)
    select distinct new.organization_id, l.user_id, 'Paiement confirmé', v_body, new.id, 'payment_confirmed'
    from public.collections c
    join public.establishments e
      on e.id = c.establishment_id and e.organization_id = c.organization_id
    join public.client_taxpayer_links l
      on l.taxpayer_id = e.taxpayer_id and l.organization_id = e.organization_id
    join public.profiles p
      on p.id = l.user_id and p.organization_id = l.organization_id and p.status = 'active'
    where c.id = new.collection_id and c.organization_id = new.organization_id
      and exists (
        select 1 from public.user_roles ur
        where ur.user_id = l.user_id and ur.organization_id = l.organization_id and ur.role_key = 'client'
      )
    on conflict (recipient_id, payment_id, kind) where payment_id is not null do nothing;
  exception when others then
    insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
    values (new.organization_id, null, 'notification.failed', 'payments', new.id,
      jsonb_build_object('sqlstate', sqlstate));
  end;

  return new;
end;
$$;

revoke all on function public.notify_payment_confirmed() from public, anon, authenticated;

-- ── 2. Demande de paiement du collecteur ───────────────────────────────────

create or replace function public.record_collection_payment_request(
  p_assignment_id uuid,
  p_establishment_id uuid,
  p_obligation_id uuid,
  p_amount numeric(14, 0),
  p_method text,
  p_idempotency_key text,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_taxpayer_id uuid;
  v_obligation_id uuid;
  v_snapshot numeric(14, 0);
  v_field_obligation boolean := false;
  v_tax_type_id uuid;
  v_day date;
  v_collection_id uuid;
  v_collection_item_id uuid;
  v_payment_id uuid;
  v_existing record;
  v_tz text;
  v_body text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;

  -- Organisation : uniquement celle du profil authentifié, jamais une valeur de l'appelant.
  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = auth.uid()
    and p.status = 'active'
    and p.organization_id is not null;

  if not found
    or not public.has_role(v_organization_id, 'collector')
    or not public.has_permission(v_organization_id, 'payment.record') then
    raise exception using errcode = '42501', message = 'Active collector role and payment permission required';
  end if;

  if p_amount is null or p_amount <= 0 or p_amount > 100000000
    or p_method not in ('cash', 'mobile_money', 'bank_transfer', 'card', 'other')
    or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'Invalid amount, payment method or idempotency key';
  end if;

  -- Relance avec la même clé (réseau coupé, double appui) : même paiement, aucun doublon,
  -- aucune seconde notification.
  select p.id, p.amount, p.method, p.recorded_by,
    c.mission_assignment_id, c.establishment_id, ci.obligation_id
  into v_existing
  from public.payments p
  join public.collections c
    on c.id = p.collection_id and c.organization_id = p.organization_id
  join public.collection_items ci
    on ci.id = p.collection_item_id and ci.collection_id = c.id
      and ci.organization_id = c.organization_id
  where p.organization_id = v_organization_id
    and p.idempotency_key = p_idempotency_key;

  if found then
    if v_existing.amount = p_amount
      and v_existing.method = p_method
      and v_existing.recorded_by = auth.uid()
      and v_existing.mission_assignment_id = p_assignment_id
      and v_existing.establishment_id = p_establishment_id
      and (p_obligation_id is null or v_existing.obligation_id = p_obligation_id) then
      return v_existing.id;
    end if;
    raise exception using errcode = '23505', message = 'Idempotency key was used for a different request';
  end if;

  -- Affectation active du collecteur, dans la zone de l'établissement, même organisation.
  if not public.can_create_collection(v_organization_id, p_assignment_id, p_establishment_id) then
    raise exception using errcode = '42501', message = 'Assignment or establishment is not accessible';
  end if;

  select e.taxpayer_id into v_taxpayer_id
  from public.establishments e
  where e.id = p_establishment_id
    and e.organization_id = v_organization_id
    and e.is_active;
  if v_taxpayer_id is null then
    raise exception using errcode = '42501', message = 'Assignment or establishment is not accessible';
  end if;

  if p_obligation_id is not null then
    -- Obligation existante choisie par le collecteur : montant plafonné au solde.
    select fo.amount_due - fo.amount_paid into v_snapshot
    from public.financial_obligations fo
    where fo.id = p_obligation_id
      and fo.organization_id = v_organization_id
      and fo.establishment_id = p_establishment_id
      and fo.status in ('open', 'partial')
    for update;

    if not found or v_snapshot <= 0 or p_amount > v_snapshot then
      raise exception using errcode = '22023', message = 'Payment exceeds the open obligation balance';
    end if;
    v_obligation_id := p_obligation_id;
  else
    -- Aucun montant dû saisi à l'avance : obligation « Encaissement » du jour, partagée
    -- avec record_field_payment. Création sans conflit, sinon verrou et rattachement.
    v_field_obligation := true;
    v_snapshot := p_amount;

    insert into public.tax_types (organization_id, code, label)
    values (v_organization_id, 'encaissement', 'Encaissement')
    on conflict (organization_id, code) do update set label = public.tax_types.label
    returning id into v_tax_type_id;

    v_day := (now() at time zone public.organization_timezone(v_organization_id))::date;
    insert into public.financial_obligations (
      organization_id, taxpayer_id, establishment_id, tax_type_id,
      period_start, period_end, due_date, amount_due
    ) values (
      v_organization_id, v_taxpayer_id, p_establishment_id, v_tax_type_id,
      v_day, v_day, v_day, p_amount
    )
    on conflict (organization_id, establishment_id, tax_type_id, period_start, period_end) do nothing
    returning id into v_obligation_id;

    if v_obligation_id is null then
      select fo.id into v_obligation_id
      from public.financial_obligations fo
      where fo.organization_id = v_organization_id and fo.establishment_id = p_establishment_id
        and fo.tax_type_id = v_tax_type_id and fo.period_start = v_day and fo.period_end = v_day
      for update;
    end if;
  end if;

  insert into public.collections (
    organization_id, mission_assignment_id, establishment_id,
    collector_id, outcome, notes, status
  ) values (
    v_organization_id, p_assignment_id, p_establishment_id,
    auth.uid(), 'contacted', nullif(btrim(p_notes), ''), 'draft'
  ) returning id into v_collection_id;

  insert into public.collection_items (
    organization_id, collection_id, obligation_id, amount_due_snapshot
  ) values (
    v_organization_id, v_collection_id, v_obligation_id, v_snapshot
  ) returning id into v_collection_item_id;

  update public.collections
  set status = 'submitted'
  where id = v_collection_id;

  -- payments_prevent_duplicate refuse une saisie identique encore en attente (10 min).
  insert into public.payments (
    organization_id, collection_id, collection_item_id,
    amount, method, idempotency_key, status, recorded_by
  ) values (
    v_organization_id, v_collection_id, v_collection_item_id,
    p_amount, p_method, p_idempotency_key, 'pending', auth.uid()
  ) returning id into v_payment_id;

  if v_field_obligation then
    -- Dû = en attente + confirmés ; payé = confirmés. Rien n'est crédité ici.
    perform public.refresh_field_obligation(v_obligation_id);
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values
    (v_organization_id, auth.uid(), 'collection.submitted', 'collections', v_collection_id, '{}'::jsonb),
    (v_organization_id, auth.uid(), 'payment.requested', 'payments', v_payment_id,
      jsonb_build_object('amount', p_amount, 'method', p_method, 'establishment_id', p_establishment_id,
        'taxpayer_id', v_taxpayer_id, 'obligation_id', v_obligation_id,
        'obligation_source', case when v_field_obligation then 'field_daily' else 'existing' end));

  -- Notification persistée des comptes clients actifs liés au contribuable. Un incident
  -- est tracé sans annuler la demande (même règle que notify_payment_confirmed).
  begin
    v_tz := public.organization_timezone(v_organization_id);
    v_body := 'Une demande de paiement de '
      || replace(to_char(p_amount, 'FM999,999,999,990'), ',', ' ') || ' FCFA ('
      || case p_method
           when 'cash' then 'espèces'
           when 'mobile_money' then 'Mobile Money'
           when 'bank_transfer' then 'virement'
           when 'card' then 'carte'
           else 'autre moyen'
         end
      || ') a été enregistrée par votre collecteur le '
      || to_char(now() at time zone v_tz, 'DD/MM/YYYY') || ' à '
      || to_char(now() at time zone v_tz, 'HH24 "h" MI')
      || '. Elle sera marquée payée après confirmation. Consultez votre historique pour voir les détails.';

    insert into public.notifications (organization_id, recipient_id, title, body, payment_id, kind)
    select distinct v_organization_id, l.user_id, 'Demande de paiement', v_body, v_payment_id, 'payment_requested'
    from public.client_taxpayer_links l
    join public.profiles p
      on p.id = l.user_id and p.organization_id = l.organization_id and p.status = 'active'
    where l.organization_id = v_organization_id
      and l.taxpayer_id = v_taxpayer_id
      and exists (
        select 1 from public.user_roles ur
        where ur.user_id = l.user_id and ur.organization_id = l.organization_id and ur.role_key = 'client'
      )
    on conflict (recipient_id, payment_id, kind) where payment_id is not null do nothing;
  exception when others then
    insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
    values (v_organization_id, null, 'notification.failed', 'payments', v_payment_id,
      jsonb_build_object('sqlstate', sqlstate, 'kind', 'payment_requested'));
  end;

  return v_payment_id;
end;
$$;

revoke all on function public.record_collection_payment_request(uuid, uuid, uuid, numeric, text, text, text)
  from public, anon;
grant execute on function public.record_collection_payment_request(uuid, uuid, uuid, numeric, text, text, text)
  to authenticated;

-- ── 3. Récapitulatif serveur d'une demande ─────────────────────────────────
-- Lu par l'application après l'enregistrement : statut réel, client et nombre de comptes
-- clients effectivement notifiés (l'application n'affirme rien qu'elle n'a pas vérifié).
-- Réservé au collecteur déclarant et à l'administration financière de l'organisation.

create function public.payment_request_overview(p_payment_id uuid)
returns table (
  payment_id uuid,
  payment_status public.payment_status,
  amount numeric,
  method text,
  created_at timestamptz,
  taxpayer_name text,
  establishment_name text,
  notified_clients integer
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_org uuid;
  v_recorded_by uuid;
begin
  select pay.organization_id, pay.recorded_by into v_org, v_recorded_by
  from public.payments pay where pay.id = p_payment_id;

  if v_org is null or not (
    (v_recorded_by = auth.uid() and public.caller_organization() = v_org)
    or public.has_permission(v_org, 'finance.read')
  ) then
    raise exception using errcode = '42501', message = 'Payment is not accessible';
  end if;

  return query
  select pay.id, pay.status, pay.amount, pay.method, pay.created_at, t.legal_name, e.name,
    (select count(*)::integer from public.notifications n
     where n.payment_id = pay.id and n.organization_id = pay.organization_id
       and n.kind = 'payment_requested')
  from public.payments pay
  join public.collections c on c.id = pay.collection_id and c.organization_id = pay.organization_id
  join public.establishments e on e.id = c.establishment_id and e.organization_id = c.organization_id
  join public.taxpayers t on t.id = e.taxpayer_id and t.organization_id = e.organization_id
  where pay.id = p_payment_id;
end;
$$;

revoke all on function public.payment_request_overview(uuid) from public, anon;
grant execute on function public.payment_request_overview(uuid) to authenticated;

-- ── 4. Historique de l'administration : filtre par montant et totaux filtrés ─
-- Paramètres ajoutés en fin de liste avec valeur par défaut : les appels nommés existants
-- (application mobile, Terenza Admin) restent valides. Les totaux portent sur toute la
-- sélection filtrée, jamais sur la seule page renvoyée.

drop function public.payments_page(date, date, uuid, text, uuid, text, text, integer, integer);

create function public.payments_page(
  p_from date,
  p_to date,
  p_taxpayer_id uuid default null,
  p_status text default null,
  p_collector_id uuid default null,
  p_search text default null,
  p_sort text default 'date_desc',
  p_limit integer default 50,
  p_offset integer default 0,
  p_min_amount numeric default null,
  p_max_amount numeric default null
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
  total_count bigint,
  total_confirmed_amount numeric,
  total_pending_amount numeric
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
  if (p_min_amount is not null and p_min_amount < 0)
    or (p_max_amount is not null and p_max_amount < 0)
    or (p_min_amount is not null and p_max_amount is not null and p_max_amount < p_min_amount) then
    raise exception using errcode = '22023', message = 'Invalid amount range';
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
    count(*) over (),
    coalesce(sum(pay.amount) filter (where pay.status = 'confirmed') over (), 0),
    coalesce(sum(pay.amount) filter (where pay.status = 'pending') over (), 0)
  from public.payments pay
  join public.collections c on c.id = pay.collection_id and c.organization_id = pay.organization_id
  join public.establishments e on e.id = c.establishment_id and e.organization_id = c.organization_id
  join public.taxpayers t on t.id = e.taxpayer_id and t.organization_id = e.organization_id
  left join public.profiles pr on pr.id = pay.recorded_by
  left join public.receipts r on r.payment_id = pay.id and r.organization_id = pay.organization_id
  where pay.organization_id = v_org
    and (p_taxpayer_id is null or t.id = p_taxpayer_id)
    and (p_collector_id is null or pay.recorded_by = p_collector_id)
    and (p_min_amount is null or pay.amount >= p_min_amount)
    and (p_max_amount is null or pay.amount <= p_max_amount)
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

revoke all on function public.payments_page(date, date, uuid, text, uuid, text, text, integer, integer, numeric, numeric)
  from public, anon;
grant execute on function public.payments_page(date, date, uuid, text, uuid, text, text, integer, integer, numeric, numeric)
  to authenticated;
