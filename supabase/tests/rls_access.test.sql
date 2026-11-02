begin;

select plan(15);

select ok(
  (select count(*) = 24
   from information_schema.tables
   where table_schema = 'public'
     and table_name = any (array[
       'organizations', 'profiles', 'roles', 'permissions', 'user_roles',
       'role_permissions', 'zones', 'taxpayers', 'establishments',
       'activity_types', 'tax_types', 'financial_obligations', 'missions',
       'mission_assignments', 'appointments', 'collections', 'collection_items',
       'payments', 'receipts', 'cash_registers', 'cash_movements',
       'cash_reconciliations', 'notifications', 'audit_logs'
     ])),
  'all required and supporting tables exist'
);

select ok(
  (select count(*) = 24
   from pg_class c
   join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relkind = 'r'
     and c.relname = any (array[
       'organizations', 'profiles', 'roles', 'permissions', 'user_roles',
       'role_permissions', 'zones', 'taxpayers', 'establishments',
       'activity_types', 'tax_types', 'financial_obligations', 'missions',
       'mission_assignments', 'appointments', 'collections', 'collection_items',
       'payments', 'receipts', 'cash_registers', 'cash_movements',
       'cash_reconciliations', 'notifications', 'audit_logs'
     ])
     and c.relrowsecurity),
  'row level security is enabled on every exposed table'
);

select ok(
  not has_table_privilege('anon', 'public.payments', 'SELECT'),
  'anonymous users cannot read payments'
);

select ok(
  not has_table_privilege('authenticated', 'public.payments', 'INSERT')
    and not has_table_privilege('authenticated', 'public.payments', 'UPDATE'),
  'authenticated clients cannot write payment rows directly'
);

select ok(
  not has_table_privilege('authenticated', 'public.user_roles', 'INSERT')
    and not has_table_privilege('authenticated', 'public.user_roles', 'UPDATE'),
  'authenticated clients cannot grant themselves roles'
);

select ok(
  has_function_privilege('authenticated', 'public.confirm_cash_payment(uuid,uuid)', 'EXECUTE'),
  'cash confirmation is exposed only through its guarded server function'
);

select ok(
  has_function_privilege('authenticated', 'public.record_collection_payment_request(uuid,uuid,uuid,numeric,text,text,text)', 'EXECUTE'),
  'the collector flow is available through an atomic server RPC'
);

select ok(
  has_function_privilege('authenticated', 'public.record_offline_visit(uuid,uuid,text,text,text,numeric,numeric,numeric,timestamp with time zone)', 'EXECUTE'),
  'offline visit sync is available without creating a payment'
);

select ok(
  has_function_privilege('authenticated', 'public.start_appointment(uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.finish_appointment(uuid,text,text)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.reschedule_appointment(uuid,timestamp with time zone,text)', 'EXECUTE'),
  'appointment transitions are exposed through server RPCs'
);

select ok(
  has_function_privilege('authenticated', 'public.cash_register_summary(uuid)', 'EXECUTE')
    and has_function_privilege('authenticated', 'public.submit_cash_reconciliation(uuid,numeric,text,text)', 'EXECUTE'),
  'cash balances and reconciliations are mediated by server RPCs'
);

select ok(
  not has_table_privilege('authenticated', 'public.appointments', 'UPDATE'),
  'clients cannot directly change appointment transitions'
);

select ok(
  not has_table_privilege('authenticated', 'public.cash_movements', 'INSERT')
    and not has_table_privilege('authenticated', 'public.cash_movements', 'UPDATE'),
  'clients cannot directly create or rewrite cash movements'
);

select ok(
  not has_function_privilege('authenticated', 'public.confirm_external_payment_verified(uuid,text,text,numeric,text)', 'EXECUTE')
    and has_function_privilege('service_role', 'public.confirm_external_payment_verified(uuid,text,text,numeric,text)', 'EXECUTE'),
  'external confirmation is reserved for a trusted server webhook'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

select is(
  (select count(*)::integer from public.organizations),
  0,
  'an authenticated user without an active profile sees no organizations'
);

reset role;
select * from finish();
rollback;