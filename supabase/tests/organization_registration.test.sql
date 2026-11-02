-- Accompagne la migration 20261025000100_organization_registration.sql.
-- Base locale uniquement (`npx supabase start` puis `npx supabase test db`), jamais en production.

begin;

select plan(20);

-- ── Données de test (propriétaire) ──────────────────────────────────────────

insert into public.organizations (id, name, code) values
  ('11000000-0000-0000-0000-00000000000a', 'Organisation existante', 'reg-existing');

insert into auth.users (id, email, email_confirmed_at) values
  ('21000000-0000-0000-0000-000000000001', 'requester@test.local', now()),
  ('21000000-0000-0000-0000-000000000002', 'requester-2@test.local', now()),
  ('21000000-0000-0000-0000-000000000003', 'superadmin@test.local', now()),
  ('21000000-0000-0000-0000-000000000004', 'admin-existing@test.local', now()),
  ('21000000-0000-0000-0000-000000000005', 'unconfirmed@test.local', null);

update public.profiles set status = 'active' where id = '21000000-0000-0000-0000-000000000003';
update public.profiles set status = 'active', organization_id = '11000000-0000-0000-0000-00000000000a'
where id = '21000000-0000-0000-0000-000000000004';
insert into public.user_roles (organization_id, user_id, role_key) values
  (null, '21000000-0000-0000-0000-000000000003', 'super_admin'),
  ('11000000-0000-0000-0000-00000000000a', '21000000-0000-0000-0000-000000000004', 'admin');

select ok(
  not has_table_privilege('authenticated', 'public.organization_registration_requests', 'INSERT')
    and not has_table_privilege('authenticated', 'public.organization_registration_requests', 'UPDATE'),
  'requests are written only through guarded RPCs'
);

-- ── Adresse non confirmée ───────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"21000000-0000-0000-0000-000000000005","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.submit_organization_registration('Non confirmée', 'non-confirmee')$$,
  '42501', null,
  'an account with an unconfirmed email cannot register an organization'
);

reset role;

-- ── Demandeur ───────────────────────────────────────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"21000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.submit_organization_registration('Org déjà prise', 'reg-existing')$$,
  '23505', null,
  'an existing organization code cannot be requested'
);

select lives_ok(
  $$select public.submit_organization_registration('Mairie de Test', 'Mairie-Test', '+22900000000', 'Demande de test')$$,
  'a pending account submits a registration request'
);

select is(
  (select organization_code from public.organization_registration_requests),
  'mairie-test',
  'the requester sees only its own request, with a normalized code'
);

select is(
  public.submit_organization_registration('Mairie de Test', 'mairie-test'),
  (select id from public.organization_registration_requests where status = 'pending'),
  'submitting the same request again returns the pending one (idempotent)'
);

select is(
  (select count(*)::int from public.organization_registration_requests),
  1,
  'a repeated submission creates no duplicate'
);

select throws_ok(
  $$select public.submit_organization_registration('Deuxième', 'autre-code')$$,
  '23505', null,
  'only one pending request per account'
);

select throws_ok(
  $$select public.approve_organization_registration((select id from public.organization_registration_requests limit 1))$$,
  '42501', null,
  'a requester cannot approve its own request'
);

-- ── Administrateur d'une autre organisation ─────────────────────────────────

reset role;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"21000000-0000-0000-0000-000000000004","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::int from public.organization_registration_requests),
  0,
  'an organization admin cannot read registration requests'
);

select throws_ok(
  $$select public.submit_organization_registration('Org parallèle', 'org-parallele')$$,
  '42501', null,
  'an active member of an organization cannot register another one'
);

-- ── Super-Admin ─────────────────────────────────────────────────────────────

reset role;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"21000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::int from public.organization_registration_requests where status = 'pending'),
  1,
  'the super administrator reads pending requests'
);

select lives_ok(
  $$select public.approve_organization_registration((select id from public.organization_registration_requests where status = 'pending'))$$,
  'the super administrator approves the request'
);

reset role;

select is(
  (select p.status::text || ':' || o.code
   from public.profiles p join public.organizations o on o.id = p.organization_id
   where p.id = '21000000-0000-0000-0000-000000000001'),
  'active:mairie-test',
  'approval creates the organization and activates the requester in it'
);

select ok(
  exists (
    select 1 from public.user_roles ur join public.organizations o on o.id = ur.organization_id
    where ur.user_id = '21000000-0000-0000-0000-000000000001' and ur.role_key = 'admin' and o.code = 'mairie-test'
  ),
  'the requester becomes administrator of the new organization only'
);

select ok(
  exists (select 1 from public.audit_logs where action = 'organization.registration_approved'),
  'the decision is written to the audit log'
);

-- Refus : motif obligatoire.
do $$ begin perform set_config('request.jwt.claims', '{"sub":"21000000-0000-0000-0000-000000000002","role":"authenticated"}', true); end $$;
set local role authenticated;
select public.submit_organization_registration('À refuser', 'a-refuser');
reset role;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"21000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.reject_organization_registration((select id from public.organization_registration_requests where status = 'pending'), 'non')$$,
  '22023', null,
  'a rejection requires a reason'
);

select lives_ok(
  $$select public.reject_organization_registration((select id from public.organization_registration_requests where status = 'pending'), 'Dossier incomplet')$$,
  'the super administrator rejects with a reason'
);

reset role;

select is(
  (select status::text || ':' || decision_reason from public.organization_registration_requests where organization_code = 'a-refuser'),
  'rejected:Dossier incomplet',
  'the rejection and its reason are recorded'
);

select ok(
  not exists (select 1 from public.user_roles where user_id = '21000000-0000-0000-0000-000000000002')
    and exists (select 1 from public.profiles where id = '21000000-0000-0000-0000-000000000002' and status = 'pending' and organization_id is null),
  'a rejected requester gets no role and stays pending without organization'
);

select * from finish();
rollback;
