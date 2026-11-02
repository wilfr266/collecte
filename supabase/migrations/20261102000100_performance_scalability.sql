-- Montée en charge (phase 1 de l'audit de capacité) : mêmes droits d'accès, coût réduit.
-- Source de travail : Terenza Admin. Tests pgTAP : tests/performance_scalability.test.sql.
-- Aucune donnée modifiée ; aucune table ajoutée.
--
-- Mesures sur banc local (PGlite, 10 000 paiements) avant → après :
--   liste des clients d'un collecteur 20,9 s → 64 ms ; paiements en attente 15,2 s → 11 ms ;
--   comptage des collectes 7,9 s → 8 ms ; liste REST des paiements 17,5 s → 13 ms.
-- Cause : les politiques appelaient une fonction SECURITY DEFINER par ligne lue
-- (can_access_zone, is_taxpayer_client, has_permission). Les ensembles autorisés de
-- l'appelant sont désormais calculés une fois par requête (`col in (select …)`), avec les
-- mêmes règles ; l'équivalence ligne à ligne est vérifiée par profil dans les tests.

-- ── 1. Fuseau de l'organisation ─────────────────────────────────────────────
-- Le parcours de pg_timezone_names coûtait ~150 ms par appel en production (requête la plus
-- chère de la base). Un fuseau inconnu fait échouer la conversion : même repli sur UTC.
create or replace function public.organization_timezone(p_organization_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_tz text;
begin
  select o.timezone into v_tz from public.organizations o where o.id = p_organization_id;
  perform now() at time zone v_tz;
  return coalesce(v_tz, 'UTC');
exception when others then
  return 'UTC';
end;
$$;

-- ── 2. Index manquant ───────────────────────────────────────────────────────
-- refresh_field_obligation et reverse_payment lisent les paiements par ligne de collecte.
create index if not exists payments_collection_item_idx
  on public.payments (organization_id, collection_item_id);

-- ── 3. Ensembles autorisés de l'appelant ────────────────────────────────────

-- Organisations où l'appelant (profil actif) détient la permission ; toutes pour le
-- Super-Administrateur. Mêmes règles que has_permission.
create or replace function public.my_permission_orgs(p_key text)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.organization_id
  from public.profiles p
  join public.user_roles ur on ur.user_id = p.id and ur.organization_id = p.organization_id
  join public.role_permissions rp on rp.role_key = ur.role_key and rp.permission_key = p_key
  where p.id = auth.uid() and p.status = 'active'
  union
  select o.id from public.organizations o where public.has_role(null, 'super_admin');
$$;

-- Zones lisibles : mêmes règles que can_access_zone (directory.read_all, superviseur de la
-- zone, collecteur affecté à une mission active de la zone). Les clés étrangères composites
-- (zone_id, organization_id) garantissent que la zone appartient à l'organisation de la ligne.
create or replace function public.my_zone_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select z.id from public.zones z
  where z.organization_id in (select public.my_permission_orgs('directory.read_all'))
  union
  select z.id from public.zones z
  where z.supervisor_id = auth.uid() and public.has_role(z.organization_id, 'supervisor')
  union
  select m.zone_id
  from public.missions m
  join public.mission_assignments ma on ma.mission_id = m.id and ma.organization_id = m.organization_id
  where ma.user_id = auth.uid() and m.status in ('assigned', 'in_progress')
    and public.has_role(m.organization_id, 'collector');
$$;

-- Fiches rattachées au compte client appelant : mêmes règles que is_taxpayer_client.
create or replace function public.my_client_taxpayer_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select l.taxpayer_id
  from public.client_taxpayer_links l
  where l.user_id = auth.uid() and public.has_role(l.organization_id, 'client');
$$;

revoke all on function public.my_permission_orgs(text) from public, anon;
revoke all on function public.my_zone_ids() from public, anon;
revoke all on function public.my_client_taxpayer_ids() from public, anon;
grant execute on function public.my_permission_orgs(text) to authenticated;
grant execute on function public.my_zone_ids() to authenticated;
grant execute on function public.my_client_taxpayer_ids() to authenticated;

-- ── 4. Politiques réécrites (même périmètre) ────────────────────────────────

drop policy if exists taxpayers_read_scoped on public.taxpayers;
create policy taxpayers_read_scoped on public.taxpayers
  for select to authenticated using (zone_id in (select public.my_zone_ids()));

drop policy if exists taxpayers_read_client on public.taxpayers;
create policy taxpayers_read_client on public.taxpayers
  for select to authenticated using (id in (select public.my_client_taxpayer_ids()));

drop policy if exists establishments_read_scoped on public.establishments;
create policy establishments_read_scoped on public.establishments
  for select to authenticated using (zone_id in (select public.my_zone_ids()));

drop policy if exists establishments_read_client on public.establishments;
create policy establishments_read_client on public.establishments
  for select to authenticated using (taxpayer_id in (select public.my_client_taxpayer_ids()));

drop policy if exists financial_obligations_read_scoped on public.financial_obligations;
create policy financial_obligations_read_scoped on public.financial_obligations
  for select to authenticated using (
    organization_id in (select public.my_permission_orgs('finance.read'))
    or establishment_id in (
      select e.id from public.establishments e where e.zone_id in (select public.my_zone_ids())
    )
  );

drop policy if exists financial_obligations_read_client on public.financial_obligations;
create policy financial_obligations_read_client on public.financial_obligations
  for select to authenticated using (taxpayer_id in (select public.my_client_taxpayer_ids()));

drop policy if exists payments_read_scoped on public.payments;
create policy payments_read_scoped on public.payments
  for select to authenticated using (
    organization_id in (select public.my_permission_orgs('finance.read'))
    or public.can_access_collection(organization_id, collection_id)
    or (cash_register_id is not null
      and public.can_access_cash_register(organization_id, cash_register_id))
  );

drop policy if exists collections_read_scoped on public.collections;
create policy collections_read_scoped on public.collections
  for select to authenticated using (
    organization_id in (select public.my_permission_orgs('collection.read_all'))
    or public.can_access_collection(organization_id, id)
  );

-- ── 5. Premier encaissement du jour en parallèle ────────────────────────────
-- Deux encaissements simultanés chez un même établissement, sans obligation du jour :
-- le second recevait une erreur d'unicité (financial_obligations_period_idx) au lieu de
-- rejoindre l'obligation créée par le premier. Seul ce bloc change dans la fonction.
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
  -- de la journée. Création sans conflit : si un encaissement parallèle l'a créée entre-temps,
  -- on attend sa validation puis on la rejoint (verrou de ligne).
  v_day := (now() at time zone public.organization_timezone(v_organization_id))::date;
  insert into public.financial_obligations (
    organization_id, taxpayer_id, establishment_id, tax_type_id, period_start, period_end, due_date, amount_due
  ) values (
    v_organization_id, v_taxpayer_id, p_establishment_id, v_tax_type_id, v_day, v_day, v_day, p_amount
  )
  on conflict (organization_id, establishment_id, tax_type_id, period_start, period_end) do nothing
  returning id into v_obligation_id;
  if v_obligation_id is null then
    select fo.id into v_obligation_id
    from public.financial_obligations fo
    where fo.organization_id = v_organization_id and fo.establishment_id = p_establishment_id
      and fo.tax_type_id = v_tax_type_id and fo.period_start = v_day and fo.period_end = v_day
    for update;
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

-- ── 6. Recherche terrain ────────────────────────────────────────────────────
-- Une requête au lieu de six, limitée à l'organisation de l'appelant ; RLS s'applique
-- (SECURITY INVOKER). Index trigrammes : « contient » sans parcours complet de la table.
create extension if not exists pg_trgm with schema extensions;

do $$
declare
  v_schema text;
begin
  select n.nspname into v_schema
  from pg_catalog.pg_extension x join pg_catalog.pg_namespace n on n.oid = x.extnamespace
  where x.extname = 'pg_trgm';
  execute format(
    'create index if not exists taxpayers_search_trgm_idx on public.taxpayers using gin ('
    || 'legal_name %1$I.gin_trgm_ops, taxpayer_number %1$I.gin_trgm_ops, phone %1$I.gin_trgm_ops, '
    || 'first_name %1$I.gin_trgm_ops, last_name %1$I.gin_trgm_ops)', v_schema);
  execute format(
    'create index if not exists establishments_search_trgm_idx on public.establishments using gin ('
    || 'name %1$I.gin_trgm_ops)', v_schema);
end;
$$;

create or replace function public.search_directory(
  p_query text,
  p_zone_id uuid default null,
  p_active_only boolean default true,
  p_limit integer default 40
)
returns table (
  kind text,
  id uuid,
  taxpayer_id uuid,
  name text,
  taxpayer_kind text,
  first_name text,
  last_name text,
  taxpayer_number text,
  phone text,
  address text,
  owner_name text,
  zone_id uuid,
  is_active boolean
)
language sql
stable
security invoker
set search_path = ''
as $$
  with params as (
    select p.organization_id as org,
      '%' || replace(replace(replace(btrim(p_query), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern,
      least(greatest(coalesce(p_limit, 40), 1), 100) as lim
    from public.profiles p
    where p.id = auth.uid() and p.organization_id is not null and length(btrim(coalesce(p_query, ''))) >= 2
  )
  (
    select 'taxpayer', t.id, t.id, t.legal_name, t.taxpayer_kind::text, t.first_name, t.last_name,
      t.taxpayer_number, t.phone, t.address, null::text, t.zone_id, t.is_active
    from public.taxpayers t, params
    where t.organization_id = params.org
      and (t.legal_name ilike params.pattern or t.taxpayer_number ilike params.pattern
        or t.phone ilike params.pattern or t.first_name ilike params.pattern or t.last_name ilike params.pattern)
      and (p_zone_id is null or t.zone_id = p_zone_id)
      and (not p_active_only or t.is_active)
    order by t.legal_name
    limit (select lim from params)
  )
  union all
  (
    select 'establishment', e.id, e.taxpayer_id, e.name, null, null, null,
      null, null, e.address, owner.legal_name, e.zone_id, e.is_active
    from public.establishments e
    cross join params
    left join public.taxpayers owner on owner.id = e.taxpayer_id and owner.organization_id = e.organization_id
    where e.organization_id = params.org
      and e.name ilike params.pattern
      and (p_zone_id is null or e.zone_id = p_zone_id)
      and (not p_active_only or e.is_active)
    order by e.name
    limit (select lim from params)
  );
$$;

revoke all on function public.search_directory(text, uuid, boolean, integer) from public, anon;
grant execute on function public.search_directory(text, uuid, boolean, integer) to authenticated;

-- ── 7. Agrégats du Super-Administrateur ─────────────────────────────────────
-- Remplace le téléchargement de jusqu'à 2 × 20 000 lignes à chaque actualisation du tableau
-- de bord global. Une ligne par organisation et statut de paiement, plus une ligne par
-- organisation pour le nombre de collectes (status nul). Bornes [p_from, p_to), nulles =
-- sans borne ; p_by_confirmation filtre sur confirmed_at au lieu de created_at.
create or replace function public.platform_activity(
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_organization_id uuid default null,
  p_by_confirmation boolean default false
)
returns table (organization_id uuid, status text, payments bigint, amount numeric, collections bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.has_role(null, 'super_admin') then
    raise exception using errcode = '42501', message = 'Super administrator role required';
  end if;

  return query
  select pay.organization_id, pay.status::text, count(*), sum(pay.amount), null::bigint
  from public.payments pay
  where (p_organization_id is null or pay.organization_id = p_organization_id)
    and (p_from is null or (case when p_by_confirmation then pay.confirmed_at else pay.created_at end) >= p_from)
    and (p_to is null or (case when p_by_confirmation then pay.confirmed_at else pay.created_at end) < p_to)
    and (not p_by_confirmation or pay.confirmed_at is not null)
  group by pay.organization_id, pay.status
  union all
  select c.organization_id, null, null, null, count(*)
  from public.collections c
  where not p_by_confirmation
    and (p_organization_id is null or c.organization_id = p_organization_id)
    and (p_from is null or c.visited_at >= p_from)
    and (p_to is null or c.visited_at < p_to)
  group by c.organization_id;
end;
$$;

revoke all on function public.platform_activity(timestamptz, timestamptz, uuid, boolean) from public, anon;
grant execute on function public.platform_activity(timestamptz, timestamptz, uuid, boolean) to authenticated;
