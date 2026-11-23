-- Parcours « Nouvelle visite → Avec demande de paiement » (migration 20261120000100).
-- Acteurs simulés par leur JWT (RLS appliquée) ; tout est annulé par le rollback.
-- À exécuter en local : npx supabase start && npx supabase test db

begin;

select plan(25);

insert into public.organizations (id, name, code) values
  ('b1000000-0000-0000-0000-00000000000a', 'Organisation R', 'test-request-org-a'),
  ('b1000000-0000-0000-0000-00000000000b', 'Organisation S', 'test-request-org-b');

insert into auth.users (id, email) values
  ('b2000000-0000-0000-0000-000000000001', 'collector-r@test.local'),
  ('b2000000-0000-0000-0000-000000000002', 'client-r1@test.local'),
  ('b2000000-0000-0000-0000-000000000003', 'client-r2@test.local'),
  ('b2000000-0000-0000-0000-000000000004', 'admin-r@test.local'),
  ('b2000000-0000-0000-0000-000000000005', 'admin-s@test.local'),
  ('b2000000-0000-0000-0000-000000000006', 'collector-s@test.local');

update public.profiles set status = 'active', organization_id = 'b1000000-0000-0000-0000-00000000000a'
where id in ('b2000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000002',
             'b2000000-0000-0000-0000-000000000003', 'b2000000-0000-0000-0000-000000000004');
update public.profiles set status = 'active', organization_id = 'b1000000-0000-0000-0000-00000000000b'
where id in ('b2000000-0000-0000-0000-000000000005', 'b2000000-0000-0000-0000-000000000006');

insert into public.user_roles (organization_id, user_id, role_key) values
  ('b1000000-0000-0000-0000-00000000000a', 'b2000000-0000-0000-0000-000000000001', 'collector'),
  ('b1000000-0000-0000-0000-00000000000a', 'b2000000-0000-0000-0000-000000000002', 'client'),
  ('b1000000-0000-0000-0000-00000000000a', 'b2000000-0000-0000-0000-000000000003', 'client'),
  ('b1000000-0000-0000-0000-00000000000a', 'b2000000-0000-0000-0000-000000000004', 'admin'),
  ('b1000000-0000-0000-0000-00000000000b', 'b2000000-0000-0000-0000-000000000005', 'admin'),
  ('b1000000-0000-0000-0000-00000000000b', 'b2000000-0000-0000-0000-000000000006', 'collector');

insert into public.zones (id, organization_id, name, code) values
  ('b3000000-0000-0000-0000-00000000000a', 'b1000000-0000-0000-0000-00000000000a', 'Zone R', 'zr'),
  ('b3000000-0000-0000-0000-00000000000b', 'b1000000-0000-0000-0000-00000000000b', 'Zone S', 'zs');

insert into public.taxpayers (id, organization_id, zone_id, legal_name) values
  ('b4000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-00000000000a', 'b3000000-0000-0000-0000-00000000000a', 'Client R1'),
  ('b4000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-00000000000a', 'b3000000-0000-0000-0000-00000000000a', 'Client R2');

insert into public.establishments (id, organization_id, taxpayer_id, zone_id, name) values
  ('b5000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-00000000000a',
   'b4000000-0000-0000-0000-000000000001', 'b3000000-0000-0000-0000-00000000000a', 'Boutique R1');

insert into public.missions (id, organization_id, zone_id, title, scheduled_for, status) values
  ('b6000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-00000000000a',
   'b3000000-0000-0000-0000-00000000000a', 'Mission R', current_date, 'assigned'),
  ('b6000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-00000000000b',
   'b3000000-0000-0000-0000-00000000000b', 'Mission S', current_date, 'assigned');
insert into public.mission_assignments (id, organization_id, mission_id, user_id) values
  ('b7000000-0000-0000-0000-000000000001', 'b1000000-0000-0000-0000-00000000000a',
   'b6000000-0000-0000-0000-000000000001', 'b2000000-0000-0000-0000-000000000001'),
  ('b7000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-00000000000b',
   'b6000000-0000-0000-0000-000000000002', 'b2000000-0000-0000-0000-000000000006');

insert into public.client_taxpayer_links (organization_id, user_id, taxpayer_id) values
  ('b1000000-0000-0000-0000-00000000000a', 'b2000000-0000-0000-0000-000000000002', 'b4000000-0000-0000-0000-000000000001'),
  ('b1000000-0000-0000-0000-00000000000a', 'b2000000-0000-0000-0000-000000000003', 'b4000000-0000-0000-0000-000000000002');

-- ── Collecteur R : demande sans obligation préalable ────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.record_collection_payment_request('b7000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001', null, 0, 'cash', 'req-zero-0001')$$,
  '22023', null, 'a zero amount is refused');

select throws_ok(
  $$select public.record_collection_payment_request('b7000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001', null, -500, 'cash', 'req-neg-00001')$$,
  '22023', null, 'a negative amount is refused');

select lives_ok(
  $$select public.record_collection_payment_request('b7000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001', null, 7500, 'cash', 'req-cash-0001', 'Passage du matin')$$,
  'collector records a payment request without a pre-existing obligation');

select is(
  public.record_collection_payment_request('b7000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001', null, 7500, 'cash', 'req-cash-0001', 'Passage du matin'),
  (select p.id from public.payments p where p.idempotency_key = 'req-cash-0001'),
  'a retry with the same key returns the same payment');

select throws_ok(
  $$select public.record_collection_payment_request('b7000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001', null, 7500, 'cash', 'req-cash-0002')$$,
  '23505', null, 'an identical request with another key (double tap) is refused');

select is(
  (select payment_status::text from public.payment_request_overview(
    (select p.id from public.payments p where p.idempotency_key = 'req-cash-0001'))),
  'pending', 'the request is pending, never confirmed by its creation');

select is(
  (select notified_clients from public.payment_request_overview(
    (select p.id from public.payments p where p.idempotency_key = 'req-cash-0001'))),
  1, 'the overview reports the linked client account actually notified');

select is(
  (select taxpayer_name from public.payment_request_overview(
    (select p.id from public.payments p where p.idempotency_key = 'req-cash-0001'))),
  'Client R1', 'the overview names the client derived from the establishment');

reset role;

select is(
  (select count(*)::integer from public.payments p
   join public.collections c on c.id = p.collection_id
   where c.establishment_id = 'b5000000-0000-0000-0000-000000000001'),
  1, 'retry and double tap created no second payment');

select ok(
  (select p.organization_id = 'b1000000-0000-0000-0000-00000000000a'
      and p.recorded_by = 'b2000000-0000-0000-0000-000000000001'
      and p.amount = 7500 and p.currency_code = 'XOF'
   from public.payments p where p.idempotency_key = 'req-cash-0001'),
  'organization, collector, amount and currency come from the server');

select ok(
  (select fo.amount_due = 7500 and fo.amount_paid = 0 and fo.status = 'open'
   from public.payments p
   join public.collection_items ci on ci.id = p.collection_item_id
   join public.financial_obligations fo on fo.id = ci.obligation_id
   where p.idempotency_key = 'req-cash-0001'),
  'the daily obligation counts the request as due, nothing as paid');

select is(
  (select count(*)::integer from public.audit_logs
   where action = 'payment.requested'
     and entity_id = (select p.id from public.payments p where p.idempotency_key = 'req-cash-0001')),
  1, 'the request is audited once');

-- ── Collecteur S : autre organisation ───────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000006","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.record_collection_payment_request('b7000000-0000-0000-0000-000000000001',
    'b5000000-0000-0000-0000-000000000001', null, 1000, 'cash', 'req-cross-001')$$,
  '42501', null, 'a collector of another organization cannot use an assignment of organization R');

select throws_ok(
  $$select * from public.payment_request_overview(
    (select p.id from public.payments p limit 1))$$,
  '42501', null, 'a collector of another organization cannot read the overview');

reset role;

-- ── Client R1 : notification de la demande ─────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::integer from public.notifications where kind = 'payment_requested'),
  1, 'the client receives exactly one request notification');

select ok(
  (select title = 'Demande de paiement'
      and body like 'Une demande de paiement de 7 500 FCFA (espèces) a été enregistrée par votre collecteur le %'
      and read_at is null
   from public.notifications where kind = 'payment_requested'),
  'the notification states the real amount, is unread and does not claim a payment');

select is(
  (select pending_count::integer from public.payment_months('b4000000-0000-0000-0000-000000000001') limit 1),
  1, 'the client history lists the request as pending');

select is(
  (select confirmed_amount::integer from public.payment_months('b4000000-0000-0000-0000-000000000001') limit 1),
  0, 'the pending request is not counted as collected');

reset role;

-- ── Client R2 : rien ────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;

select is((select count(*)::integer from public.notifications), 0,
  'another client of the same organization receives nothing');

reset role;

-- ── Administration R : visibilité, totaux et filtre montant ────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000004","role":"authenticated"}', true); end $$;
set local role authenticated;

select ok(
  (select taxpayer_name = 'Client R1' and collector_id = 'b2000000-0000-0000-0000-000000000001'
      and payment_status = 'pending' and total_pending_amount = 7500 and total_confirmed_amount = 0
   from public.payments_page(current_date - 1, current_date + 1)),
  'the organization administration sees the request with client, collector and server totals');

select is(
  (select count(*)::integer from public.payments_page(current_date - 1, current_date + 1,
    p_min_amount => 8000)),
  0, 'the amount filter excludes smaller requests');

select is(
  (select count(*)::integer from public.payments_page(current_date - 1, current_date + 1,
    p_collector_id => 'b2000000-0000-0000-0000-000000000001', p_min_amount => 7500, p_max_amount => 7500)),
  1, 'collector and amount filters combine');

reset role;

-- ── Administration S : aucune visibilité ───────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000005","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::integer from public.payments_page(current_date - 1, current_date + 1)),
  0, 'another organization administration sees no request of organization R');

reset role;

-- ── Confirmation ultérieure : les deux notifications coexistent ────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"b2000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;
select lives_ok(
  $$select * from public.record_field_payment('b5000000-0000-0000-0000-000000000001', 2000, 'cash', 'req-field-0001')$$,
  'a cash collection the same day joins the same daily obligation');
reset role;

select is(
  (select count(*)::integer from public.notifications
   where recipient_id = 'b2000000-0000-0000-0000-000000000002' and kind = 'payment_confirmed'),
  1, 'a confirmed payment still notifies the client after the index change');

select * from finish();
rollback;
