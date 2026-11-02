-- Accompagne la migration 20261026000300_organization_self_management.sql.
-- Base locale uniquement (`npx supabase start` puis `npx supabase test db`), jamais en production.

begin;

select plan(22);

insert into public.organizations (id, name, code) values
  ('13000000-0000-0000-0000-00000000000a', 'Organisation A', 'self-a'),
  ('13000000-0000-0000-0000-00000000000b', 'Organisation B', 'self-b');

insert into auth.users (id, email, email_confirmed_at) values
  ('23000000-0000-0000-0000-000000000001', 'admin-a@test.local', now()),
  ('23000000-0000-0000-0000-000000000002', 'admin-b@test.local', now()),
  ('23000000-0000-0000-0000-000000000003', 'pending@test.local', now()),
  ('23000000-0000-0000-0000-000000000004', 'collector-b@test.local', now()),
  ('23000000-0000-0000-0000-000000000005', 'collector-a@test.local', now());

update public.profiles set status = 'active', organization_id = '13000000-0000-0000-0000-00000000000a'
where id in ('23000000-0000-0000-0000-000000000001', '23000000-0000-0000-0000-000000000005');
update public.profiles set status = 'active', organization_id = '13000000-0000-0000-0000-00000000000b'
where id in ('23000000-0000-0000-0000-000000000002', '23000000-0000-0000-0000-000000000004');
insert into public.user_roles (organization_id, user_id, role_key) values
  ('13000000-0000-0000-0000-00000000000a', '23000000-0000-0000-0000-000000000001', 'admin'),
  ('13000000-0000-0000-0000-00000000000b', '23000000-0000-0000-0000-000000000002', 'admin'),
  ('13000000-0000-0000-0000-00000000000b', '23000000-0000-0000-0000-000000000004', 'collector'),
  ('13000000-0000-0000-0000-00000000000a', '23000000-0000-0000-0000-000000000005', 'collector');

select ok(
  not has_function_privilege('authenticated', 'public.register_created_member(uuid, uuid, text, text)', 'execute'),
  'register_created_member is reserved to the server (service_role)'
);

-- ── Collecteur en attente : ne peut rien gérer ──────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"23000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;
select throws_ok(
  $$select public.attach_account_to_organization('pending@test.local', '23000000', 'collector')$$,
  '42501', null, 'a pending account cannot attach itself'
);
reset role;

-- ── Administrateur A ────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"23000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.attach_account_to_organization('pending@test.local', '99999999', 'collector')$$,
  'P0002', null, 'a wrong identifier does not find the account'
);
select throws_ok(
  $$select public.attach_account_to_organization('pending@test.local', '23000000-0000-0000-0000-000000000003', 'admin')$$,
  '42501', null, 'an organization cannot grant the admin role'
);
select throws_ok(
  $$select public.attach_account_to_organization('collector-b@test.local', '23000000-0000-0000-0000-000000000004', 'collector')$$,
  'P0002', null, 'a member of another organization cannot be attached'
);
select lives_ok(
  $$select public.attach_account_to_organization('Pending@Test.local', '23000000-0000-0000-0000-000000000003', 'collector')$$,
  'the admin attaches a pending account with email and identifier'
);
select throws_ok(
  $$select public.attach_account_to_organization('pending@test.local', '23000000-0000-0000-0000-000000000003', 'collector')$$,
  '23505', null, 'the same account cannot be attached twice'
);

reset role;
select is(
  (select p.status::text || ':' || p.organization_id::text || ':' || ur.role_key
   from public.profiles p join public.user_roles ur on ur.user_id = p.id
   where p.id = '23000000-0000-0000-0000-000000000003'),
  'active:13000000-0000-0000-0000-00000000000a:collector',
  'the attached account is active in organization A with the collector role'
);
do $$ begin perform set_config('request.jwt.claims', '{"sub":"23000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.set_member_status('23000000-0000-0000-0000-000000000004', 'suspended')$$,
  'P0002', null, 'an admin cannot suspend a member of another organization'
);
select throws_ok(
  $$select public.set_member_status('23000000-0000-0000-0000-000000000001', 'suspended')$$,
  '42501', null, 'an admin cannot suspend itself'
);
select lives_ok(
  $$select public.set_member_status('23000000-0000-0000-0000-000000000005', 'suspended')$$,
  'an admin suspends a collector of its organization'
);
select throws_ok(
  $$select public.revoke_member_role('23000000-0000-0000-0000-000000000004', 'collector')$$,
  'P0002', null, 'an admin cannot revoke a role in another organization'
);
select lives_ok(
  $$select public.revoke_member_role('23000000-0000-0000-0000-000000000003', 'collector')$$,
  'an admin revokes the collector role of its member'
);

-- Fiches clients.
select lives_ok(
  $$select public.save_zone(null, 'Centre', 'centre', true)$$,
  'an admin creates a zone in its organization'
);
select lives_ok(
  $$select public.save_taxpayer(null, (select id from public.zones where code = 'centre'), 'business', 'Boutique Test',
      null, null, 'NIF-001', '+22990000000', null, 'Rue 1', true)$$,
  'an admin creates a taxpayer without any Auth account'
);
select throws_ok(
  $$select public.save_taxpayer(null, (select id from public.zones where code = 'centre'), 'business', 'boutique test',
      null, null, null, '+22990000000', null, null, true)$$,
  '23505', null, 'a probable duplicate (same name and phone) is refused'
);
select throws_ok(
  $$select public.save_taxpayer(null, (select id from public.zones where code = 'centre'), 'business', 'Autre',
      null, null, 'NIF-001', null, null, null, true)$$,
  '23505', null, 'a duplicate taxpayer number is refused'
);
select lives_ok(
  $$select public.save_establishment(null, (select id from public.taxpayers where taxpayer_number = 'NIF-001'),
      (select id from public.zones where code = 'centre'), 'Boutique principale', null, true)$$,
  'an admin adds an establishment to the taxpayer'
);

reset role;

-- ── Administrateur B : aucun accès aux fiches de A ──────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"23000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::int from public.taxpayers where taxpayer_number = 'NIF-001'),
  0,
  'organization B cannot read the taxpayers of A'
);
select throws_ok(
  $$select public.save_taxpayer((select '00000000-0000-0000-0000-000000000000'::uuid), null, 'business', 'X')$$,
  'P0002', null, 'organization B cannot update a taxpayer outside its organization'
);

-- ── Collecteur : aucune gestion ─────────────────────────────────────────────

reset role;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"23000000-0000-0000-0000-000000000004","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.save_zone(null, 'Pirate', 'pirate', true)$$,
  '42501', null, 'a collector cannot create zones'
);
select throws_ok(
  $$select public.set_member_status('23000000-0000-0000-0000-000000000002', 'suspended')$$,
  '42501', null, 'a collector cannot change statuses'
);

select * from finish();
rollback;
