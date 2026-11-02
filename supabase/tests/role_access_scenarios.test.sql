-- Scénarios d'accès réels : chaque acteur est simulé par son JWT et le rôle
-- `authenticated` (RLS appliquée), le webhook par `service_role`. Le
-- propriétaire ne sert qu'à créer les données de test et à vérifier les
-- déclencheurs qui s'appliquent même à lui.
--
-- Tout est annulé par le rollback final. À exécuter sur une base locale
-- (`npx supabase start` puis `npx supabase test db`), jamais en production.

begin;

select plan(48);

-- ── Données de test (propriétaire) ──────────────────────────────────────────

insert into public.organizations (id, name, code) values
  ('10000000-0000-0000-0000-00000000000a', 'Organisation A', 'test-org-a'),
  ('10000000-0000-0000-0000-00000000000b', 'Organisation B', 'test-org-b');

-- Le déclencheur handle_new_auth_user crée chaque profil en `pending`.
insert into auth.users (id, email) values
  ('20000000-0000-0000-0000-000000000001', 'admin-a@test.local'),
  ('20000000-0000-0000-0000-000000000002', 'collector-a@test.local'),
  ('20000000-0000-0000-0000-000000000003', 'client-a1@test.local'),
  ('20000000-0000-0000-0000-000000000004', 'client-a2@test.local'),
  ('20000000-0000-0000-0000-000000000005', 'collector-b@test.local'),
  ('20000000-0000-0000-0000-000000000006', 'client-suspended@test.local'),
  ('20000000-0000-0000-0000-000000000007', 'cashier-a@test.local');

update public.profiles set status = 'active', organization_id = '10000000-0000-0000-0000-00000000000a'
where id in (
  '20000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
  '20000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000004',
  '20000000-0000-0000-0000-000000000007'
);
update public.profiles set status = 'active', organization_id = '10000000-0000-0000-0000-00000000000b'
where id = '20000000-0000-0000-0000-000000000005';
update public.profiles set status = 'suspended', organization_id = '10000000-0000-0000-0000-00000000000a'
where id = '20000000-0000-0000-0000-000000000006';

insert into public.user_roles (organization_id, user_id, role_key) values
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000001', 'admin'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000002', 'collector'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', 'client'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000004', 'client'),
  ('10000000-0000-0000-0000-00000000000b', '20000000-0000-0000-0000-000000000005', 'collector'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000006', 'client'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000007', 'cashier');

insert into public.zones (id, organization_id, name, code) values
  ('30000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'Zone A', 'za'),
  ('30000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'Zone B', 'zb');

insert into public.taxpayers (id, organization_id, zone_id, legal_name) values
  ('40000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-00000000000a', 'Contribuable T1'),
  ('40000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-00000000000a', 'Contribuable T2'),
  ('40000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000b', '30000000-0000-0000-0000-00000000000b', 'Contribuable T3');

insert into public.establishments (id, organization_id, taxpayer_id, zone_id, name) values
  ('50000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-00000000000a', 'Établissement E1'),
  ('50000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-00000000000a', 'Établissement E2'),
  ('50000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000b', '40000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-00000000000b', 'Établissement E3');

insert into public.tax_types (id, organization_id, code, label) values
  ('60000000-0000-0000-0000-00000000000a', '10000000-0000-0000-0000-00000000000a', 'tsc', 'Taxe A'),
  ('60000000-0000-0000-0000-00000000000b', '10000000-0000-0000-0000-00000000000b', 'tsc', 'Taxe B');

insert into public.financial_obligations
  (id, organization_id, taxpayer_id, establishment_id, tax_type_id, period_start, period_end, due_date, amount_due)
values
  ('70000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-000000000001',
   '50000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-00000000000a', '2026-01-01', '2026-12-31', '2026-12-31', 10000),
  ('70000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-00000000000a', '40000000-0000-0000-0000-000000000002',
   '50000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-00000000000a', '2026-01-01', '2026-12-31', '2026-12-31', 5000),
  ('70000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-00000000000b', '40000000-0000-0000-0000-000000000003',
   '50000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-00000000000b', '2026-01-01', '2026-12-31', '2026-12-31', 7000);

insert into public.missions (id, organization_id, zone_id, title, scheduled_for, status) values
  ('80000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', '30000000-0000-0000-0000-00000000000a',
   'Mission A', current_date, 'assigned');
insert into public.mission_assignments (id, organization_id, mission_id, user_id) values
  ('81000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a',
   '80000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002');

insert into public.cash_registers (id, organization_id, code, label, assigned_cashier_id, status, opened_at) values
  ('90000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-00000000000a', 'c1', 'Caisse A',
   '20000000-0000-0000-0000-000000000007', 'open', now());

insert into public.client_taxpayer_links (organization_id, user_id, taxpayer_id) values
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000001'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000002'),
  ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000006', '40000000-0000-0000-0000-000000000001');

-- ── Collecteur A ────────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;

select lives_ok(
  $$select public.record_collection_payment_request(
    '81000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001',
    '70000000-0000-0000-0000-000000000001', 2000, 'cash', 'test-cash-0001')$$,
  'collector declares a cash payment on an assigned establishment'
);

select is(
  public.record_collection_payment_request(
    '81000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001',
    '70000000-0000-0000-0000-000000000001', 2000, 'cash', 'test-cash-0001'),
  (select id from public.payments where idempotency_key = 'test-cash-0001'),
  'retrying with the same idempotency key returns the same payment'
);

select throws_ok(
  $$select public.record_collection_payment_request(
    '81000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001',
    '70000000-0000-0000-0000-000000000001', 2000, 'cash', 'test-cash-0002')$$,
  '23505', null,
  'an identical pending payment with another key is rejected as a duplicate'
);

select lives_ok(
  $$select public.record_collection_payment_request(
    '81000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001',
    '70000000-0000-0000-0000-000000000001', 3000, 'mobile_money', 'test-mm-0001')$$,
  'collector declares a Mobile Money payment'
);

select is(
  (select status::text from public.payments where idempotency_key = 'test-mm-0001'),
  'pending',
  'a declared Mobile Money payment stays pending'
);

select throws_ok(
  $$select public.record_collection_payment_request(
    '81000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000003',
    '70000000-0000-0000-0000-000000000003', 1000, 'cash', 'test-cash-xorg')$$,
  '42501', null,
  'collector cannot record a payment for another organization'
);

select throws_ok(
  $$update public.payments set status = 'confirmed' where idempotency_key = 'test-mm-0001'$$,
  '42501', null,
  'collector cannot mark a payment as paid'
);

select throws_ok(
  $$update public.financial_obligations set amount_paid = amount_due$$,
  '42501', null,
  'collector cannot change a balance'
);

select throws_ok(
  $$select public.confirm_external_payment_verified(
    (select id from public.payments where idempotency_key = 'test-mm-0001'),
    'orange', 'OM-FAKE', 3000, 'XOF')$$,
  '42501', null,
  'collector cannot confirm a Mobile Money payment'
);

select throws_ok(
  $$insert into public.user_roles (organization_id, user_id, role_key)
    values ('10000000-0000-0000-0000-00000000000a', '20000000-0000-0000-0000-000000000002', 'admin')$$,
  '42501', null,
  'collector cannot grant a role to themself'
);

select throws_ok(
  $$update public.profiles set organization_id = '10000000-0000-0000-0000-00000000000b'
    where id = '20000000-0000-0000-0000-000000000002'$$,
  '42501', null,
  'collector cannot attach themself to another organization'
);

select is(
  (select count(*)::integer from public.financial_obligations
   where organization_id = '10000000-0000-0000-0000-00000000000b'),
  0,
  'collector sees no obligation of another organization'
);

select is(
  (select count(*)::integer from public.client_taxpayer_links),
  0,
  'collector cannot read client links'
);

reset role;

-- ── Client A1 (rattaché à T1) ───────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"20000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;

select results_eq(
  $$select id from public.taxpayers order by id$$,
  $$values ('40000000-0000-0000-0000-000000000001'::uuid)$$,
  'client A1 sees only their linked taxpayer'
);

select results_eq(
  $$select id from public.financial_obligations order by id$$,
  $$values ('70000000-0000-0000-0000-000000000001'::uuid)$$,
  'client A1 sees only their own obligations'
);

select is(
  (select count(*)::integer from public.client_payments(100)),
  2,
  'client A1 sees their two payments through client_payments'
);

select is(
  (select count(*)::integer from public.client_payments(100)
   where obligation_id <> '70000000-0000-0000-0000-000000000001'),
  0,
  'client_payments returns no payment of another obligation'
);

select is(
  (select count(*)::integer from public.payments),
  0,
  'client cannot read the payments table directly'
);

select is(
  (select count(*)::integer from public.collections),
  0,
  'client cannot read collector visits'
);

select throws_ok(
  $$update public.financial_obligations set amount_paid = amount_due
    where id = '70000000-0000-0000-0000-000000000001'$$,
  '42501', null,
  'client cannot change their balance'
);

select throws_ok(
  $$select public.link_client_taxpayer('20000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000002')$$,
  '42501', null,
  'client cannot link themself to another taxpayer'
);

select throws_ok(
  $$select public.fail_external_payment('00000000-0000-0000-0000-000000000000', 'orange', 'x', 'cancelled')$$,
  '42501', null,
  'client cannot change a payment status'
);

select throws_ok(
  $$update public.profiles set status = 'active' where id = '20000000-0000-0000-0000-000000000003'$$,
  '42501', null,
  'client cannot change their account status'
);

reset role;

-- ── Client A2 (rattaché à T2, même organisation) ────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"20000000-0000-0000-0000-000000000004","role":"authenticated"}', true); end $$;
set local role authenticated;

select results_eq(
  $$select id from public.taxpayers order by id$$,
  $$values ('40000000-0000-0000-0000-000000000002'::uuid)$$,
  'client A2 does not see T1 although both are in the same organization'
);

select is(
  (select count(*)::integer from public.client_payments(100)),
  0,
  'client A2 does not see T1 payments'
);

reset role;

-- ── Client suspendu (rattaché à T1) ─────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"20000000-0000-0000-0000-000000000006","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::integer from public.taxpayers),
  0,
  'a suspended client sees no taxpayer despite an existing link'
);

select is(
  (select count(*)::integer from public.client_payments(100)),
  0,
  'a suspended client sees no payment'
);

reset role;

-- ── Administrateur A ────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"20000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::integer from public.profiles
   where organization_id = '10000000-0000-0000-0000-00000000000b'),
  0,
  'admin A does not see profiles of organization B'
);

select ok(
  (select count(*) from public.payments) >= 2,
  'admin A reads the same payment rows (finance.read)'
);

select lives_ok(
  $$select public.link_client_taxpayer('20000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000001')$$,
  'admin A links a client of their organization to a taxpayer'
);

select throws_ok(
  $$select public.link_client_taxpayer('20000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000003')$$,
  '42501', null,
  'admin A cannot link a taxpayer of organization B'
);

select throws_ok(
  $$select public.link_client_taxpayer('20000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000001')$$,
  '22023', null,
  'admin A cannot link an account that has no client role'
);

select throws_ok(
  $$select public.confirm_external_payment_verified(
    (select id from public.payments where idempotency_key = 'test-mm-0001'),
    'orange', 'OM-1', 3000, 'XOF')$$,
  '42501', null,
  'even an admin cannot confirm an external payment from the app'
);

reset role;

-- ── Caissier A : validation espèces ─────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"20000000-0000-0000-0000-000000000007","role":"authenticated"}', true); end $$;
set local role authenticated;

select isnt(
  public.confirm_cash_payment(
    (select id from public.payments where idempotency_key = 'test-cash-0001'),
    '90000000-0000-0000-0000-000000000001'),
  null,
  'cashier confirms the cash payment at an open register and gets a receipt'
);

reset role;

select ok(
  (select status = 'confirmed' and status_changed_at is not null
   from public.payments where idempotency_key = 'test-cash-0001'),
  'cash confirmation is timestamped by the guard trigger'
);

-- ── Webhook prestataire (service_role) ──────────────────────────────────────

set local role service_role;

select throws_ok(
  $$select public.confirm_external_payment_verified(
    (select id from public.payments where idempotency_key = 'test-mm-0001'),
    'orange', 'OM-1', 1, 'XOF')$$,
  '22023', null,
  'a notification with a different amount is rejected'
);

select isnt(
  public.confirm_external_payment_verified(
    (select id from public.payments where idempotency_key = 'test-mm-0001'),
    'orange', 'OM-1', 3000, 'XOF'),
  null,
  'a verified notification confirms the payment and issues a receipt'
);

select is(
  public.confirm_external_payment_verified(
    (select id from public.payments where idempotency_key = 'test-mm-0001'),
    'orange', 'OM-1', 3000, 'XOF'),
  (select r.id from public.receipts r join public.payments p on p.id = r.payment_id
   where p.idempotency_key = 'test-mm-0001'),
  'a replayed notification returns the same receipt'
);

select is(
  (select amount_paid::integer from public.financial_obligations
   where id = '70000000-0000-0000-0000-000000000001'),
  5000,
  'the balance includes the confirmed cash and Mobile Money payments only once'
);

select is(
  public.fail_external_payment(
    (select id from public.payments where idempotency_key = 'test-mm-0001'),
    'orange', 'OM-1', 'provider_failed')::text,
  'confirmed',
  'a failure arriving after confirmation is ignored'
);

reset role;

-- Délai d'attente puis notification tardive.
do $$ begin perform set_config('request.jwt.claims', '{"sub":"20000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;
do $$
begin
  perform public.record_collection_payment_request(
    '81000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002',
    '70000000-0000-0000-0000-000000000002', 1000, 'mobile_money', 'test-mm-0002');
  perform public.record_collection_payment_request(
    '81000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002',
    '70000000-0000-0000-0000-000000000002', 500, 'mobile_money', 'test-mm-0003');
end
$$;
reset role;

set local role service_role;
do $$
begin
  perform public.register_external_payment_initiation(
    (select id from public.payments where idempotency_key = 'test-mm-0002'), 'orange', 'OM-2');
end
$$;
reset role;

-- Vieillissement artificiel : created_at est immuable, le garde-fou est
-- suspendu le temps de cette seule mise à jour de test.
alter table public.payments disable trigger payments_guard_update;
update public.payments set created_at = now() - interval '2 days'
where idempotency_key in ('test-mm-0002', 'test-mm-0003');
alter table public.payments enable trigger payments_guard_update;

set local role service_role;

select throws_ok(
  $$select public.expire_stale_external_payments(interval '1 minute')$$,
  '22023', null,
  'an unreasonably short timeout is refused'
);

select is(
  public.expire_stale_external_payments(interval '24 hours'),
  1,
  'only the payment initiated with a provider is expired'
);

select is(
  (select status::text || '/' || coalesce(failure_reason, '') from public.payments
   where idempotency_key = 'test-mm-0003'),
  'pending/',
  'a collector declaration without provider transaction is never expired'
);

select throws_ok(
  $$select public.confirm_external_payment_verified(
    (select id from public.payments where idempotency_key = 'test-mm-0002'),
    'orange', 'OM-OTHER', 1000, 'XOF')$$,
  '22023', null,
  'a notification for another provider transaction is rejected'
);

select isnt(
  public.confirm_external_payment_verified(
    (select id from public.payments where idempotency_key = 'test-mm-0002'),
    'orange', 'OM-2', 1000, 'XOF'),
  null,
  'a late verified notification issues a receipt'
);

select is(
  (select status::text from public.payments where idempotency_key = 'test-mm-0002'),
  'confirmed',
  'a late notification after a timeout confirms the payment'
);

reset role;

-- ── Garde-fous applicables même au propriétaire ─────────────────────────────

select throws_ok(
  $$update public.payments set amount = 1 where idempotency_key = 'test-mm-0001'$$,
  '42501', null,
  'the amount of a payment is immutable'
);

select throws_ok(
  $$update public.payments set status = 'pending', confirmed_at = null
    where idempotency_key = 'test-mm-0001'$$,
  '42501', null,
  'a confirmed payment cannot go back to pending'
);

select * from finish();
rollback;
