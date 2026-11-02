-- Accompagne la migration 20261029000100_payment_reporting.sql.
-- Base locale uniquement (`npx supabase start` puis `npx supabase test db`), jamais en production.

begin;

select plan(15);

-- Organisation A en UTC+1 pour tester les bornes de jour et de mois ; B pour l'isolation.
insert into public.organizations (id, name, code, timezone) values
  ('16000000-0000-0000-0000-00000000000a', 'Organisation A', 'rep-a', 'Africa/Lagos'),
  ('16000000-0000-0000-0000-00000000000b', 'Organisation B', 'rep-b', 'Africa/Abidjan');

insert into auth.users (id, email, email_confirmed_at) values
  ('26000000-0000-0000-0000-000000000001', 'admin-a@test.local', now()),
  ('26000000-0000-0000-0000-000000000002', 'collector-a@test.local', now()),
  ('26000000-0000-0000-0000-000000000003', 'client-a@test.local', now()),
  ('26000000-0000-0000-0000-000000000004', 'admin-b@test.local', now());

update public.profiles set status = 'active', organization_id = '16000000-0000-0000-0000-00000000000a'
where id in ('26000000-0000-0000-0000-000000000001', '26000000-0000-0000-0000-000000000002', '26000000-0000-0000-0000-000000000003');
update public.profiles set status = 'active', organization_id = '16000000-0000-0000-0000-00000000000b'
where id = '26000000-0000-0000-0000-000000000004';
insert into public.user_roles (organization_id, user_id, role_key) values
  ('16000000-0000-0000-0000-00000000000a', '26000000-0000-0000-0000-000000000001', 'admin'),
  ('16000000-0000-0000-0000-00000000000a', '26000000-0000-0000-0000-000000000002', 'collector'),
  ('16000000-0000-0000-0000-00000000000a', '26000000-0000-0000-0000-000000000003', 'client'),
  ('16000000-0000-0000-0000-00000000000b', '26000000-0000-0000-0000-000000000004', 'admin');

insert into public.zones (id, organization_id, name, code) values
  ('36000000-0000-0000-0000-00000000000a', '16000000-0000-0000-0000-00000000000a', 'Marché', 'marche');
insert into public.taxpayers (id, organization_id, zone_id, legal_name) values
  ('46000000-0000-0000-0000-000000000001', '16000000-0000-0000-0000-00000000000a', '36000000-0000-0000-0000-00000000000a', 'Boutique A'),
  ('46000000-0000-0000-0000-000000000002', '16000000-0000-0000-0000-00000000000a', '36000000-0000-0000-0000-00000000000a', 'Boutique B');
insert into public.establishments (id, organization_id, taxpayer_id, zone_id, name) values
  ('56000000-0000-0000-0000-000000000001', '16000000-0000-0000-0000-00000000000a', '46000000-0000-0000-0000-000000000001', '36000000-0000-0000-0000-00000000000a', 'Étal A'),
  ('56000000-0000-0000-0000-000000000002', '16000000-0000-0000-0000-00000000000a', '46000000-0000-0000-0000-000000000002', '36000000-0000-0000-0000-00000000000a', 'Étal B');
insert into public.missions (id, organization_id, zone_id, title, scheduled_for, status) values
  ('66000000-0000-0000-0000-000000000001', '16000000-0000-0000-0000-00000000000a', '36000000-0000-0000-0000-00000000000a', 'Tournée', '2026-03-01', 'assigned');
insert into public.mission_assignments (id, organization_id, mission_id, user_id) values
  ('76000000-0000-0000-0000-000000000001', '16000000-0000-0000-0000-00000000000a', '66000000-0000-0000-0000-000000000001', '26000000-0000-0000-0000-000000000002');
insert into public.client_taxpayer_links (organization_id, user_id, taxpayer_id) values
  ('16000000-0000-0000-0000-00000000000a', '26000000-0000-0000-0000-000000000003', '46000000-0000-0000-0000-000000000001');
insert into public.tax_types (id, organization_id, code, label) values
  ('86000000-0000-0000-0000-000000000001', '16000000-0000-0000-0000-00000000000a', 'encaissement', 'Encaissement');

-- Paiements datés (heure effective = collections.visited_at), créés directement comme données de test.
create function pg_temp.pay(p_n int, p_establishment uuid, p_taxpayer uuid, p_at timestamptz, p_amount int, p_status public.payment_status)
returns uuid language plpgsql as $$
declare v_o uuid; v_c uuid; v_i uuid; v_p uuid;
begin
  insert into public.financial_obligations (organization_id, taxpayer_id, establishment_id, tax_type_id, period_start, period_end, due_date, amount_due)
  values ('16000000-0000-0000-0000-00000000000a', p_taxpayer, p_establishment, '86000000-0000-0000-0000-000000000001', p_at::date, p_at::date, p_at::date, p_amount)
  returning id into v_o;
  insert into public.collections (organization_id, mission_assignment_id, establishment_id, collector_id, visited_at, outcome, status)
  values ('16000000-0000-0000-0000-00000000000a', '76000000-0000-0000-0000-000000000001', p_establishment, '26000000-0000-0000-0000-000000000002', p_at, 'contacted', 'submitted')
  returning id into v_c;
  insert into public.collection_items (organization_id, collection_id, obligation_id, amount_due_snapshot)
  values ('16000000-0000-0000-0000-00000000000a', v_c, v_o, p_amount) returning id into v_i;
  insert into public.payments (organization_id, collection_id, collection_item_id, amount, method, idempotency_key, status, recorded_by, confirmed_at)
  values ('16000000-0000-0000-0000-00000000000a', v_c, v_i, p_amount, 'cash', 'test-key-' || p_n, p_status, '26000000-0000-0000-0000-000000000002',
    case when p_status = 'confirmed' then p_at end)
  returning id into v_p;
  return v_p;
end $$;

-- 31 mars 23:30 UTC = 1er avril 00:30 à Lagos (UTC+1) : appartient au mois d'avril.
select pg_temp.pay(1, '56000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000001', '2026-03-31 23:30+00', 1000, 'confirmed');
select pg_temp.pay(2, '56000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000001', '2026-04-10 10:00+00', 2000, 'confirmed');
select pg_temp.pay(3, '56000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000001', '2026-04-11 10:00+00', 5000, 'pending');
select pg_temp.pay(4, '56000000-0000-0000-0000-000000000001', '46000000-0000-0000-0000-000000000001', '2026-03-15 10:00+00', 700, 'confirmed');
select pg_temp.pay(5, '56000000-0000-0000-0000-000000000002', '46000000-0000-0000-0000-000000000002', '2026-04-12 10:00+00', 300, 'confirmed');

-- ── Administrateur A ────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"26000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (public.payment_summary('2026-04-01', '46000000-0000-0000-0000-000000000001') -> 'totals' ->> 'confirmed_amount')::int,
  3000,
  'April total includes the payment made at 00:30 local time on April 1st, excludes March and pending'
);
select is(
  (public.payment_summary('2026-04-01', '46000000-0000-0000-0000-000000000001') -> 'totals' ->> 'pending_amount')::int,
  5000,
  'pending amounts are reported separately'
);
select is(
  (public.payment_summary('2026-04-01', '46000000-0000-0000-0000-000000000001') -> 'previous' ->> 'confirmed_amount')::int,
  700,
  'the previous month is March in local time'
);
select is(
  (public.payment_summary('2026-04-01') -> 'totals' ->> 'clients_paid')::int,
  2,
  'organization summary counts distinct paying clients'
);
select is(
  (select count(*)::int from public.payments_page('2026-04-01', '2026-04-30', null, null, null, null, 'date_desc', 1, 0)),
  1,
  'a page of size 1 returns one row'
);
select is(
  (select total_count::int from public.payments_page('2026-04-01', '2026-04-30', null, null, null, null, 'date_desc', 1, 0)),
  4,
  'total_count covers the whole filtered selection, not the page'
);
select is(
  (select count(*)::int from public.payments_page('2026-04-01', '2026-04-30', null, 'confirmed')),
  3,
  'status filter is applied by the server'
);

select lives_ok(
  $$select public.reverse_payment((select p.id from public.payments p where p.idempotency_key = 'test-key-2'), 'Erreur de saisie')$$,
  'the admin cancels a confirmed payment with a reason'
);
select is(
  (public.payment_summary('2026-04-01', '46000000-0000-0000-0000-000000000001') -> 'totals' ->> 'confirmed_amount')::int,
  1000,
  'a cancelled payment leaves the confirmed total'
);
select is(
  (public.payment_summary('2026-04-01', '46000000-0000-0000-0000-000000000001') -> 'totals' ->> 'cancelled_amount')::int,
  2000,
  'a cancelled payment is reported separately'
);
reset role;

select ok(
  exists (select 1 from public.audit_logs where action = 'payment.reversed' and metadata ->> 'reason' = 'Erreur de saisie'),
  'the cancellation is audited with its reason'
);

-- ── Client A : uniquement sa fiche, sans nom de collecteur ──────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"26000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;
select is(
  (select count(*)::int from public.payments_page('2026-03-01', '2026-04-30', '46000000-0000-0000-0000-000000000001') where collector_name is null),
  4,
  'the client sees its payments without the collector identity'
);
select throws_ok(
  $$select * from public.payments_page('2026-03-01', '2026-04-30', '46000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'a client cannot read another client payments'
);
select throws_ok(
  $$select public.payment_summary('2026-04-01')$$,
  '42501', null, 'a client cannot read the organization summary'
);
reset role;

-- ── Administrateur B : rien de A ────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"26000000-0000-0000-0000-000000000004","role":"authenticated"}', true); end $$;
set local role authenticated;
select throws_ok(
  $$select public.payment_summary('2026-04-01', '46000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'another organization cannot read these payments'
);

select * from finish();
rollback;
