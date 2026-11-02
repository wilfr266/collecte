begin;

select plan(5);

select ok(
  has_column_privilege('authenticated', 'public.profiles', 'display_name', 'UPDATE')
    and has_column_privilege('authenticated', 'public.profiles', 'phone', 'UPDATE'),
  'users can update their display name and phone'
);

select ok(
  not has_column_privilege('authenticated', 'public.profiles', 'organization_id', 'UPDATE')
    and not has_column_privilege('authenticated', 'public.profiles', 'status', 'UPDATE'),
  'users cannot attach themselves to an organization or change their status'
);

select ok(
  not has_table_privilege('authenticated', 'public.user_roles', 'INSERT')
    and not has_table_privilege('authenticated', 'public.user_roles', 'DELETE'),
  'users cannot change their own roles'
);

select ok(
  not has_table_privilege('authenticated', 'public.mission_assignments', 'INSERT')
    and not has_table_privilege('authenticated', 'public.mission_assignments', 'UPDATE'),
  'collectors cannot assign missions to themselves'
);

select ok(
  not has_table_privilege('authenticated', 'public.taxpayers', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.financial_obligations', 'UPDATE'),
  'clients cannot edit taxpayer records or balances'
);

select * from finish();
rollback;
