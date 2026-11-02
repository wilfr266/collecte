begin;

select plan(6);

select ok(
  not has_function_privilege('authenticated', 'public.confirm_external_payment_verified(uuid,text,text,numeric,text)', 'EXECUTE')
    and has_function_privilege('service_role', 'public.confirm_external_payment_verified(uuid,text,text,numeric,text)', 'EXECUTE')
    and not has_function_privilege('service_role', 'public.confirm_external_payment(uuid,text,text)', 'EXECUTE'),
  'only the trusted backend can confirm, and only with amount verification'
);

select ok(
  not has_function_privilege('authenticated', 'public.fail_external_payment(uuid,text,text,text)', 'EXECUTE')
    and not has_function_privilege('authenticated', 'public.expire_stale_external_payments(interval)', 'EXECUTE'),
  'mobile clients cannot fail or expire external payments'
);

select ok(
  not has_table_privilege('authenticated', 'public.payments', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.financial_obligations', 'UPDATE')
    and not has_table_privilege('authenticated', 'public.receipts', 'INSERT'),
  'no mobile user can edit a payment, a balance or issue a receipt'
);

select has_trigger('public', 'payments', 'payments_guard_update',
  'confirmed payments are protected by a database trigger');

select has_trigger('public', 'payments', 'payments_prevent_duplicate',
  'probable duplicate payment requests are rejected');

select has_column('public', 'payments', 'failure_reason',
  'payment failures keep their reason');

select * from finish();
rollback;
