-- Accompagne la migration 20261102000100_performance_scalability.sql.
-- Base locale uniquement (`npx supabase start` puis `npx supabase test db`), jamais en production.
-- L'équivalence des politiques réécrites (mêmes lignes visibles par profil) est aussi couverte
-- par rls_access.test.sql et role_access_scenarios.test.sql.

begin;

select plan(16);

insert into public.organizations (id, name, code) values
  ('17000000-0000-0000-0000-00000000000a', 'Organisation A', 'perf-a'),
  ('17000000-0000-0000-0000-00000000000b', 'Organisation B', 'perf-b');

insert into auth.users (id, email, email_confirmed_at) values
  ('27000000-0000-0000-0000-000000000001', 'admin-a@test.local', now()),
  ('27000000-0000-0000-0000-000000000002', 'collector-a@test.local', now()),
  ('27000000-0000-0000-0000-000000000003', 'client-a@test.local', now()),
  ('27000000-0000-0000-0000-000000000004', 'collector-b@test.local', now()),
  ('27000000-0000-0000-0000-000000000005', 'super@test.local', now());

update public.profiles set status = 'active', organization_id = '17000000-0000-0000-0000-00000000000a'
where id in ('27000000-0000-0000-0000-000000000001', '27000000-0000-0000-0000-000000000002', '27000000-0000-0000-0000-000000000003');
update public.profiles set status = 'active', organization_id = '17000000-0000-0000-0000-00000000000b'
where id = '27000000-0000-0000-0000-000000000004';
update public.profiles set status = 'active' where id = '27000000-0000-0000-0000-000000000005';
insert into public.user_roles (organization_id, user_id, role_key) values
  ('17000000-0000-0000-0000-00000000000a', '27000000-0000-0000-0000-000000000001', 'admin'),
  ('17000000-0000-0000-0000-00000000000a', '27000000-0000-0000-0000-000000000002', 'collector'),
  ('17000000-0000-0000-0000-00000000000a', '27000000-0000-0000-0000-000000000003', 'client'),
  ('17000000-0000-0000-0000-00000000000b', '27000000-0000-0000-0000-000000000004', 'collector'),
  (null, '27000000-0000-0000-0000-000000000005', 'super_admin');

-- Zone 1 : mission active du collecteur A. Zone 2 : hors de ses missions.
insert into public.zones (id, organization_id, name, code) values
  ('37000000-0000-0000-0000-000000000001', '17000000-0000-0000-0000-00000000000a', 'Marché', 'marche'),
  ('37000000-0000-0000-0000-000000000002', '17000000-0000-0000-0000-00000000000a', 'Port', 'port'),
  ('37000000-0000-0000-0000-00000000000b', '17000000-0000-0000-0000-00000000000b', 'Gare', 'gare');
insert into public.taxpayers (id, organization_id, zone_id, legal_name, phone) values
  ('47000000-0000-0000-0000-000000000001', '17000000-0000-0000-0000-00000000000a', '37000000-0000-0000-0000-000000000001', 'Boutique Awa', '0700000001'),
  ('47000000-0000-0000-0000-000000000002', '17000000-0000-0000-0000-00000000000a', '37000000-0000-0000-0000-000000000001', 'Pharmacie 100%', '0700000002'),
  ('47000000-0000-0000-0000-000000000003', '17000000-0000-0000-0000-00000000000a', '37000000-0000-0000-0000-000000000002', 'Boutique du Port', '0700000003'),
  ('47000000-0000-0000-0000-00000000000b', '17000000-0000-0000-0000-00000000000b', '37000000-0000-0000-0000-00000000000b', 'Boutique Gare', '0700000004');
insert into public.establishments (id, organization_id, taxpayer_id, zone_id, name) values
  ('57000000-0000-0000-0000-000000000001', '17000000-0000-0000-0000-00000000000a', '47000000-0000-0000-0000-000000000001', '37000000-0000-0000-0000-000000000001', 'Étal Awa'),
  ('57000000-0000-0000-0000-000000000003', '17000000-0000-0000-0000-00000000000a', '47000000-0000-0000-0000-000000000003', '37000000-0000-0000-0000-000000000002', 'Étal du Port');
insert into public.missions (id, organization_id, zone_id, title, scheduled_for, status) values
  ('67000000-0000-0000-0000-000000000001', '17000000-0000-0000-0000-00000000000a', '37000000-0000-0000-0000-000000000001', 'Tournée', current_date, 'assigned');
insert into public.mission_assignments (id, organization_id, mission_id, user_id) values
  ('77000000-0000-0000-0000-000000000001', '17000000-0000-0000-0000-00000000000a', '67000000-0000-0000-0000-000000000001', '27000000-0000-0000-0000-000000000002');
insert into public.client_taxpayer_links (organization_id, user_id, taxpayer_id) values
  ('17000000-0000-0000-0000-00000000000a', '27000000-0000-0000-0000-000000000003', '47000000-0000-0000-0000-000000000003');

select ok(
  exists (select 1 from pg_indexes where schemaname = 'public' and indexname = 'payments_collection_item_idx'),
  'payments are indexed by collection item'
);
select is(public.organization_timezone('17000000-0000-0000-0000-00000000000a'), 'Africa/Abidjan', 'organization timezone is returned');
select is(public.organization_timezone('17000000-0000-0000-0000-0000000000ff'), 'UTC', 'unknown organization falls back to UTC');

-- ── Collecteur A ────────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"27000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;

select results_eq(
  $$ select id::text from public.search_directory('boutique') order by 1 $$,
  $$ values ('47000000-0000-0000-0000-000000000001') $$,
  'collector search returns only clients of his mission zones, never another organization'
);
select results_eq(
  $$ select kind, owner_name from public.search_directory('awa') order by 1 $$,
  $$ values ('establishment', 'Boutique Awa'), ('taxpayer', null) $$,
  'search covers establishments and names their owner'
);
select results_eq(
  $$ select id::text from public.search_directory('0700000002') $$,
  $$ values ('47000000-0000-0000-0000-000000000002') $$,
  'search matches phone numbers'
);
select results_eq(
  $$ select id::text from public.search_directory('0%') $$,
  $$ values ('47000000-0000-0000-0000-000000000002') $$,
  'wildcards typed by the user are searched literally'
);
select is((select count(*) from public.search_directory('b')), 0::bigint, 'queries shorter than 2 characters return nothing');

-- Deux encaissements le même jour chez le même établissement partagent une obligation.
select lives_ok(
  $$ select * from public.record_field_payment('57000000-0000-0000-0000-000000000001', 1000, 'cash', 'perf-key-0001') $$,
  'first payment of the day is recorded'
);
select lives_ok(
  $$ select * from public.record_field_payment('57000000-0000-0000-0000-000000000001', 1500, 'cash', 'perf-key-0002') $$,
  'second payment of the day joins the same obligation'
);

select throws_ok(
  $$ select * from public.platform_activity() $$,
  '42501', null,
  'platform aggregates are refused to a collector'
);

-- ── Client A ────────────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"27000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;

select results_eq(
  $$ select id::text from public.search_directory('boutique') where kind = 'taxpayer' $$,
  $$ values ('47000000-0000-0000-0000-000000000003') $$,
  'client search returns only the linked client record'
);

-- ── Administrateur A ────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"27000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;

select is(
  (select count(*) from public.financial_obligations where establishment_id = '57000000-0000-0000-0000-000000000001'),
  1::bigint,
  'one obligation for the day holds both payments'
);
select is(
  (select amount_paid from public.financial_obligations where establishment_id = '57000000-0000-0000-0000-000000000001')::int,
  2500,
  'shared obligation is paid by both payments'
);

-- ── Super-Administrateur ────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"27000000-0000-0000-0000-000000000005","role":"authenticated"}', true); end $$;

select results_eq(
  $$ select status, payments, amount::int, collections from public.platform_activity(now() - interval '1 day', now() + interval '1 day', '17000000-0000-0000-0000-00000000000a') order by status nulls last $$,
  $$ values ('confirmed'::text, 2::bigint, 2500, null::bigint), (null, null, null, 2::bigint) $$,
  'platform aggregates count payments by status and collections per organization'
);
select is(
  (select sum(amount)::int from public.platform_activity(now() - interval '1 day', null, null, true) where status = 'confirmed'),
  2500,
  'confirmation basis sums confirmed payments'
);

select * from finish();
rollback;
