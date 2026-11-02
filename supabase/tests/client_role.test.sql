begin;

select plan(7);

select ok(
  exists (select 1 from public.roles where key = 'client' and not is_global),
  'the client role exists and is scoped to an organization'
);

select ok(
  (select c.relrowsecurity
   from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'client_taxpayer_links'),
  'row level security is enabled on client_taxpayer_links'
);

select ok(
  not has_table_privilege('anon', 'public.client_taxpayer_links', 'SELECT'),
  'anonymous users cannot read client links'
);

select ok(
  not has_table_privilege('authenticated', 'public.client_taxpayer_links', 'INSERT')
    and not has_table_privilege('authenticated', 'public.client_taxpayer_links', 'DELETE'),
  'clients cannot link themselves to a taxpayer directly'
);

select ok(
  has_function_privilege('authenticated', 'public.link_client_taxpayer(uuid,uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.unlink_client_taxpayer(uuid)', 'EXECUTE'),
  'client links are managed through guarded server RPCs'
);

select ok(
  not exists (
    select 1 from public.role_permissions where role_key = 'client'
  ),
  'the client role carries no organization-wide permission'
);

select ok(
  has_function_privilege('authenticated', 'public.client_payments(integer)', 'EXECUTE')
    and not has_function_privilege('anon', 'public.client_payments(integer)', 'EXECUTE'),
  'client payment history is exposed only through a scoped server RPC'
);

select * from finish();
rollback;
