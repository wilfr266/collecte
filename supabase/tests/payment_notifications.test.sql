-- Notification de paiement confirmé, mois d'historique et cohérence client/collecteur.
-- Acteurs simulés par leur JWT (RLS appliquée) ; tout est annulé par le rollback.
-- À exécuter en local : npx supabase start && npx supabase test db

begin;

select plan(12);

insert into public.organizations (id, name, code) values
  ('a1000000-0000-0000-0000-00000000000a', 'Organisation N', 'test-notif-org');

insert into auth.users (id, email) values
  ('a2000000-0000-0000-0000-000000000001', 'collector-n@test.local'),
  ('a2000000-0000-0000-0000-000000000002', 'client-n1@test.local'),
  ('a2000000-0000-0000-0000-000000000003', 'client-n2@test.local');

update public.profiles set status = 'active', organization_id = 'a1000000-0000-0000-0000-00000000000a'
where id in ('a2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002',
             'a2000000-0000-0000-0000-000000000003');

insert into public.user_roles (organization_id, user_id, role_key) values
  ('a1000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000001', 'collector'),
  ('a1000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000002', 'client'),
  ('a1000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000003', 'client');

insert into public.zones (id, organization_id, name, code) values
  ('a3000000-0000-0000-0000-00000000000a', 'a1000000-0000-0000-0000-00000000000a', 'Zone N', 'zn');

insert into public.taxpayers (id, organization_id, zone_id, legal_name) values
  ('a4000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a', 'a3000000-0000-0000-0000-00000000000a', 'Client N1'),
  ('a4000000-0000-0000-0000-000000000002', 'a1000000-0000-0000-0000-00000000000a', 'a3000000-0000-0000-0000-00000000000a', 'Client N2');

insert into public.establishments (id, organization_id, taxpayer_id, zone_id, name) values
  ('a5000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a',
   'a4000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-00000000000a', 'Boutique N1');

insert into public.missions (id, organization_id, zone_id, title, scheduled_for, status) values
  ('a6000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-00000000000a',
   'a3000000-0000-0000-0000-00000000000a', 'Mission N', current_date, 'assigned');
insert into public.mission_assignments (organization_id, mission_id, user_id) values
  ('a1000000-0000-0000-0000-00000000000a', 'a6000000-0000-0000-0000-000000000001',
   'a2000000-0000-0000-0000-000000000001');

insert into public.client_taxpayer_links (organization_id, user_id, taxpayer_id) values
  ('a1000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000002', 'a4000000-0000-0000-0000-000000000001'),
  ('a1000000-0000-0000-0000-00000000000a', 'a2000000-0000-0000-0000-000000000003', 'a4000000-0000-0000-0000-000000000002');

-- ── Collecteur : encaissement en espèces (confirmé immédiatement) ────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;

select lives_ok(
  $$select * from public.record_field_payment('a5000000-0000-0000-0000-000000000001', 5000, 'cash', 'notif-cash-0001')$$,
  'collector records a cash payment'
);

select lives_ok(
  $$select * from public.record_field_payment('a5000000-0000-0000-0000-000000000001', 5000, 'cash', 'notif-cash-0001')$$,
  'a network retry with the same key is accepted'
);

select lives_ok(
  $$select * from public.record_field_payment('a5000000-0000-0000-0000-000000000001', 1000, 'mobile_money', 'notif-mm-0001', 'orange_money', 'OM-NOTIF-1')$$,
  'collector records a Mobile Money payment (pending)'
);

select is(
  (select confirmed_amount::integer from public.payment_months('a4000000-0000-0000-0000-000000000001') limit 1),
  5000,
  'collector month total counts the confirmed payment only'
);

reset role;

select is(
  (select count(*)::integer from public.payments p
   join public.collections c on c.id = p.collection_id
   where c.establishment_id = 'a5000000-0000-0000-0000-000000000001'),
  2,
  'the retry created no second payment'
);

-- ── Client N1 : notification et bilan ───────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::integer from public.notifications where payment_id is not null),
  1,
  'the client receives exactly one notification for the confirmed payment'
);

select ok(
  (select title = 'Paiement confirmé' and body like 'Votre paiement de 5 000 FCFA a été confirmé le %'
   from public.notifications where payment_id is not null),
  'the notification states the real amount, date and time'
);

select is(
  (select confirmed_amount::integer from public.payment_months('a4000000-0000-0000-0000-000000000001') limit 1),
  5000,
  'client and collector see the same month total'
);

select is(
  (select pending_count::integer from public.payment_months('a4000000-0000-0000-0000-000000000001') limit 1),
  1,
  'the pending Mobile Money payment is reported separately'
);

select is(
  (select taxpayer_id from public.payment_location(
    (select payment_id from public.notifications where payment_id is not null))),
  'a4000000-0000-0000-0000-000000000001'::uuid,
  'the notification opens the payment of the right client'
);

reset role;

-- ── Client N2 : aucun accès aux paiements de N1 ─────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"a2000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::integer from public.notifications),
  0,
  'another client of the same organization receives nothing'
);

select throws_ok(
  $$select * from public.payment_months('a4000000-0000-0000-0000-000000000001')$$,
  '42501', null,
  'another client cannot read the months of client N1'
);

reset role;

select * from finish();
rollback;
