-- Accompagne la migration 20261026000200_super_admin_pending_accounts.sql.
-- Base locale uniquement (`npx supabase start` puis `npx supabase test db`), jamais en production.

begin;

select plan(11);

insert into public.organizations (id, name, code) values
  ('12000000-0000-0000-0000-00000000000a', 'Organisation existante', 'acct-existing');

insert into auth.users (id, email, email_confirmed_at) values
  ('22000000-0000-0000-0000-000000000001', 'pending@test.local', now()),
  ('22000000-0000-0000-0000-000000000002', 'unconfirmed@test.local', null),
  ('22000000-0000-0000-0000-000000000003', 'superadmin@test.local', now()),
  ('22000000-0000-0000-0000-000000000004', 'admin@test.local', now());

update public.profiles set status = 'active' where id = '22000000-0000-0000-0000-000000000003';
update public.profiles set status = 'active', organization_id = '12000000-0000-0000-0000-00000000000a'
where id = '22000000-0000-0000-0000-000000000004';
insert into public.user_roles (organization_id, user_id, role_key) values
  (null, '22000000-0000-0000-0000-000000000003', 'super_admin'),
  ('12000000-0000-0000-0000-00000000000a', '22000000-0000-0000-0000-000000000004', 'admin');

-- ── Administrateur d'organisation : aucun accès ─────────────────────────────

do $$ begin perform set_config('request.jwt.claims', '{"sub":"22000000-0000-0000-0000-000000000004","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok($$select * from public.list_pending_accounts()$$, '42501', null, 'an organization admin cannot list pending accounts');
select throws_ok(
  $$select public.create_organization_for_account('22000000-0000-0000-0000-000000000001', 'Org pirate', 'org-pirate')$$,
  '42501', null, 'an organization admin cannot create an organization for an account'
);

-- ── Compte en attente : ne peut pas s'activer lui-même ──────────────────────

reset role;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"22000000-0000-0000-0000-000000000001","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.create_organization_for_account('22000000-0000-0000-0000-000000000001', 'Moi', 'moi-meme')$$,
  '42501', null, 'a pending account cannot activate itself'
);

-- ── Super-Admin ─────────────────────────────────────────────────────────────

reset role;
do $$ begin perform set_config('request.jwt.claims', '{"sub":"22000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;

select is(
  (select count(*)::int from public.list_pending_accounts()),
  2,
  'the super administrator lists pending accounts without organization'
);

select is(
  (select email from public.list_pending_accounts() where user_id = '22000000-0000-0000-0000-000000000001'),
  'pending@test.local',
  'the listing includes the account email'
);

select throws_ok(
  $$select public.create_organization_for_account('22000000-0000-0000-0000-000000000002', 'Non confirmée', 'non-confirmee')$$,
  '22023', null, 'an unconfirmed account cannot be activated'
);

select throws_ok(
  $$select public.create_organization_for_account('22000000-0000-0000-0000-000000000001', 'Doublon', 'acct-existing')$$,
  '23505', null, 'an existing organization code is refused'
);

select lives_ok(
  $$select public.create_organization_for_account('22000000-0000-0000-0000-000000000001', 'Mairie Compte', 'Mairie-Compte')$$,
  'the super administrator creates the organization for a confirmed pending account'
);

reset role;

select is(
  (select p.status::text || ':' || o.code from public.profiles p join public.organizations o on o.id = p.organization_id
   where p.id = '22000000-0000-0000-0000-000000000001'),
  'active:mairie-compte',
  'the account is activated in the new organization'
);

select ok(
  exists (
    select 1 from public.user_roles ur join public.organizations o on o.id = ur.organization_id
    where ur.user_id = '22000000-0000-0000-0000-000000000001' and ur.role_key = 'admin' and o.code = 'mairie-compte'
  )
  and exists (select 1 from public.audit_logs where action = 'organization.created_for_account'),
  'the account becomes administrator and the action is audited'
);

do $$ begin perform set_config('request.jwt.claims', '{"sub":"22000000-0000-0000-0000-000000000003","role":"authenticated"}', true); end $$;
set local role authenticated;

select throws_ok(
  $$select public.create_organization_for_account('22000000-0000-0000-0000-000000000001', 'Encore', 'encore')$$,
  '22023', null, 'an already activated account cannot be activated twice'
);

select * from finish();
rollback;
