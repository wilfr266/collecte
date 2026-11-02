-- Accompagne la migration 20261027000100_collector_client_follow_up.sql.
-- Base locale uniquement (`npx supabase start` puis `npx supabase test db`), jamais en production.

begin;

select plan(12);

insert into public.organizations (id, name, code) values
  ('14000000-0000-0000-0000-00000000000a', 'Organisation A', 'follow-a'),
  ('14000000-0000-0000-0000-00000000000b', 'Organisation B', 'follow-b');

insert into auth.users (id, email, email_confirmed_at) values
  ('24000000-0000-0000-0000-000000000001', 'admin-a@test.local', now()),
  ('24000000-0000-0000-0000-000000000002', 'collector-a@test.local', now()),
  ('24000000-0000-0000-0000-000000000003', 'admin-b@test.local', now()),
  ('24000000-0000-0000-0000-000000000004', 'client-a@test.local', now());

update public.profiles set status = 'active', organization_id = '14000000-0000-0000-0000-00000000000a'
where id in ('24000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002', '24000000-0000-0000-0000-000000000004');
update public.profiles set status = 'active', organization_id = '14000000-0000-0000-0000-00000000000b'
where id = '24000000-0000-0000-0000-000000000003';
insert into public.user_roles (organization_id, user_id, role_key) values
  ('14000000-0000-0000-0000-00000000000a', '24000000-0000-0000-0000-000000000001', 'admin'),
  ('14000000-0000-0000-0000-00000000000a', '24000000-0000-0000-0000-000000000002', 'collector'),
  ('14000000-0000-0000-0000-00000000000a', '24000000-0000-0000-0000-000000000004', 'client'),
  ('14000000-0000-0000-0000-00000000000b', '24000000-0000-0000-0000-000000000003', 'admin');

insert into public.zones (id, organization_id, name, code) values
  ('34000000-0000-0000-0000-00000000000a', '14000000-0000-0000-0000-00000000000a', 'Centre', 'centre');
insert into public.taxpayers (id, organization_id, zone_id, legal_name) values
  ('44000000-0000-0000-0000-000000000001', '14000000-0000-0000-0000-00000000000a', '34000000-0000-0000-0000-00000000000a', 'Boutique suivie');
insert into public.establishments (id, organization_id, taxpayer_id, zone_id, name) values
  ('54000000-0000-0000-0000-000000000001', '14000000-0000-0000-0000-00000000000a', '44000000-0000-0000-0000-000000000001',
   '34000000-0000-0000-0000-00000000000a', 'Boutique principale');

-- ── Collecteur : ne voit pas le client avant affectation ────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"24000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;
select is((select count(*)::int from public.taxpayers), 0, 'a collector sees no client before being assigned');
select throws_ok(
  $$select public.assign_collector_to_taxpayer('44000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002')$$,
  '42501', null, 'a collector cannot assign itself'
);
reset role;

-- ── Administrateur B : aucune action sur A ──────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"24000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;
select throws_ok(
  $$select public.assign_collector_to_taxpayer('44000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002')$$,
  'P0002', null, 'another organization cannot assign collectors to this client'
);
reset role;

-- ── Administrateur A ────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"24000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;
select throws_ok(
  $$select public.assign_collector_to_taxpayer('44000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000004')$$,
  '22023', null, 'only an active collector can follow a client'
);
select lives_ok(
  $$select public.assign_collector_to_taxpayer('44000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002')$$,
  'the admin assigns a collector to a client'
);
select is(
  public.assign_collector_to_taxpayer('44000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002'),
  (select id from public.taxpayer_collectors),
  'a repeated assignment returns the existing follow-up (no duplicate)'
);
select is((select count(*)::int from public.taxpayer_collectors), 1, 'exactly one follow-up row');
reset role;

select ok(
  exists (
    select 1 from public.mission_assignments ma join public.missions m on m.id = ma.mission_id
    where ma.user_id = '24000000-0000-0000-0000-000000000002' and m.zone_id = '34000000-0000-0000-0000-00000000000a'
      and m.status = 'assigned'
  ),
  'the collector is assigned to an active mission of the client zone'
);

-- ── Collecteur : voit maintenant le client et son établissement (modèle mobile) ──

do $$ begin perform set_config('request.jwt.claims', '{"sub":"24000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;
select is((select count(*)::int from public.taxpayers), 1, 'the assigned collector sees the client');
select is((select count(*)::int from public.establishments), 1, 'the assigned collector sees the client establishment');
reset role;

-- ── Retrait ─────────────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"24000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;
select lives_ok(
  $$select public.unassign_collector_from_taxpayer('44000000-0000-0000-0000-000000000001', '24000000-0000-0000-0000-000000000002')$$,
  'the admin removes the follow-up'
);
reset role;
select ok(
  not exists (select 1 from public.mission_assignments where user_id = '24000000-0000-0000-0000-000000000002')
    and not exists (select 1 from public.taxpayer_collectors),
  'without other followed clients nor collections, the mission assignment is removed too'
);

select * from finish();
rollback;
