-- Accompagne la migration 20261028000200_field_payments.sql.
-- Base locale uniquement (`npx supabase start` puis `npx supabase test db`), jamais en production.

begin;

select plan(18);

insert into public.organizations (id, name, code) values
  ('15000000-0000-0000-0000-00000000000a', 'Organisation A', 'pay-a');

insert into auth.users (id, email, email_confirmed_at) values
  ('25000000-0000-0000-0000-000000000001', 'admin@test.local', now()),
  ('25000000-0000-0000-0000-000000000002', 'collector@test.local', now()),
  ('25000000-0000-0000-0000-000000000003', 'client@test.local', now()),
  ('25000000-0000-0000-0000-000000000004', 'other-collector@test.local', now());

update public.profiles set status = 'active', organization_id = '15000000-0000-0000-0000-00000000000a'
where id in ('25000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000002',
             '25000000-0000-0000-0000-000000000003', '25000000-0000-0000-0000-000000000004');
insert into public.user_roles (organization_id, user_id, role_key) values
  ('15000000-0000-0000-0000-00000000000a', '25000000-0000-0000-0000-000000000001', 'admin'),
  ('15000000-0000-0000-0000-00000000000a', '25000000-0000-0000-0000-000000000002', 'collector'),
  ('15000000-0000-0000-0000-00000000000a', '25000000-0000-0000-0000-000000000003', 'client'),
  ('15000000-0000-0000-0000-00000000000a', '25000000-0000-0000-0000-000000000004', 'collector');

insert into public.zones (id, organization_id, name, code) values
  ('35000000-0000-0000-0000-00000000000a', '15000000-0000-0000-0000-00000000000a', 'Marché', 'marche');
insert into public.taxpayers (id, organization_id, zone_id, legal_name) values
  ('45000000-0000-0000-0000-000000000001', '15000000-0000-0000-0000-00000000000a', '35000000-0000-0000-0000-00000000000a', 'Boutique');
insert into public.establishments (id, organization_id, taxpayer_id, zone_id, name) values
  ('55000000-0000-0000-0000-000000000001', '15000000-0000-0000-0000-00000000000a', '45000000-0000-0000-0000-000000000001',
   '35000000-0000-0000-0000-00000000000a', 'Étal 12');
insert into public.missions (id, organization_id, zone_id, title, scheduled_for, status) values
  ('65000000-0000-0000-0000-000000000001', '15000000-0000-0000-0000-00000000000a', '35000000-0000-0000-0000-00000000000a',
   'Tournée', current_date, 'assigned');
insert into public.mission_assignments (organization_id, mission_id, user_id) values
  ('15000000-0000-0000-0000-00000000000a', '65000000-0000-0000-0000-000000000001', '25000000-0000-0000-0000-000000000002');
insert into public.client_taxpayer_links (organization_id, user_id, taxpayer_id) values
  ('15000000-0000-0000-0000-00000000000a', '25000000-0000-0000-0000-000000000003', '45000000-0000-0000-0000-000000000001');

-- ── Collecteur affecté ──────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"25000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select payment_status::text || ':' || (receipt_number is not null)::text
   from public.record_field_payment('55000000-0000-0000-0000-000000000001', 2500, 'cash', 'cash-key-0001')),
  'confirmed:true',
  'a cash payment is confirmed immediately with a receipt'
);
select is(
  (select payment_status::text from public.record_field_payment('55000000-0000-0000-0000-000000000001', 2500, 'cash', 'cash-key-0001')),
  'confirmed',
  'retrying with the same idempotency key returns the same payment'
);
select throws_ok(
  $$select * from public.record_field_payment('55000000-0000-0000-0000-000000000001', 2500, 'cash', 'cash-key-0002')$$,
  '23505', null, 'a similar payment moments later with another key is refused'
);
select is(
  (select payment_status::text from public.record_field_payment('55000000-0000-0000-0000-000000000001', 400, 'cash', 'cash-key-0003')),
  'confirmed',
  'a second cash payment the same day at the same establishment is accepted'
);
select throws_ok(
  $$select * from public.record_field_payment('55000000-0000-0000-0000-000000000001', 1000, 'mobile_money', 'mm-key-0001')$$,
  '22023', null, 'Mobile Money requires an operator and a reference'
);
select is(
  (select payment_status::text || ':' || coalesce(receipt_number, 'none')
   from public.record_field_payment('55000000-0000-0000-0000-000000000001', 1000, 'mobile_money', 'mm-key-0001', 'orange_money', 'OM123456')),
  'pending:none',
  'a Mobile Money payment stays pending without receipt'
);
select throws_ok(
  $$select * from public.record_field_payment('55000000-0000-0000-0000-000000000001', 1500, 'mobile_money', 'mm-key-0002', 'orange_money', 'OM123456')$$,
  '23505', null, 'a Mobile Money reference cannot be reused'
);
select throws_ok(
  $$select public.review_mobile_money_payment((select id from public.payments where method = 'mobile_money'), true)$$,
  '42501', null, 'a collector cannot confirm a Mobile Money payment'
);
select is(
  (select count(*)::int from public.taxpayer_payments('45000000-0000-0000-0000-000000000001', current_date, current_date)),
  3,
  'the assigned collector reads the client history'
);
reset role;

-- ── Collecteur non affecté ──────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"25000000-0000-0000-0000-000000000004","role":"authenticated"}', true); end $$;
set local role authenticated;
select throws_ok(
  $$select * from public.record_field_payment('55000000-0000-0000-0000-000000000001', 500, 'cash', 'cash-key-0099')$$,
  '42501', null, 'a collector without mission in the zone cannot record payments'
);
select throws_ok(
  $$select * from public.taxpayer_payments('45000000-0000-0000-0000-000000000001', current_date, current_date)$$,
  '42501', null, 'a collector without mission in the zone cannot read the client history'
);
reset role;

-- ── Client ──────────────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"25000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;
select is(
  (select count(*)::int from public.taxpayer_payments('45000000-0000-0000-0000-000000000001', current_date, current_date)),
  3,
  'the linked client reads its history'
);
select is(
  (select count(*)::int from public.client_payments(50)),
  3,
  'the existing client_payments RPC shows the field payments too'
);
reset role;

-- ── Administrateur ──────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"25000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;
select throws_ok(
  $$select public.review_mobile_money_payment((select id from public.payments where method = 'mobile_money'), false, 'non')$$,
  '22023', null, 'a rejection requires a reason'
);
select isnt(
  public.review_mobile_money_payment((select id from public.payments where method = 'mobile_money'), true),
  null,
  'the admin confirms a verified Mobile Money payment and gets a receipt number'
);
select throws_ok(
  $$select public.review_mobile_money_payment((select id from public.payments where method = 'mobile_money'), true)$$,
  '22023', null, 'a payment cannot be reviewed twice'
);
reset role;

select is(
  (select sum(amount)::int from public.payments where status = 'confirmed'),
  3900,
  'all payments are now confirmed (total 3 900)'
);
select is(
  (select amount_due::int || '/' || amount_paid::int || ':' || status from public.financial_obligations),
  '3900/3900:paid',
  'one shared daily obligation, recomputed from its payments'
);

select * from finish();
rollback;
