create sequence public.receipt_number_seq;
revoke all on sequence public.receipt_number_seq from public, anon, authenticated;

create function public.assign_user_role(
  p_user_id uuid,
  p_organization_id uuid,
  p_role_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_assignment_id uuid;
  v_actor_is_super_admin boolean := public.has_role(null, 'super_admin');
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;

  if p_role_key = 'super_admin' and not v_actor_is_super_admin then
    raise exception using errcode = '42501', message = 'Only a super administrator can assign this role';
  end if;

  if p_role_key = 'admin' and not v_actor_is_super_admin then
    raise exception using errcode = '42501', message = 'Only a super administrator can assign administrators';
  end if;

  if p_role_key not in ('admin', 'super_admin')
    and not public.has_permission(p_organization_id, 'role.assign') then
    raise exception using errcode = '42501', message = 'Missing role.assign permission';
  end if;

  if p_role_key = 'super_admin' then
    if p_organization_id is not null then
      raise exception using errcode = '22023', message = 'Global role cannot have an organization';
    end if;
  elsif p_organization_id is null then
    raise exception using errcode = '22023', message = 'Organization is required for this role';
  end if;

  if not exists (
    select 1 from public.profiles p
    where p.id = p_user_id
      and p.status = 'active'
      and (p_role_key = 'super_admin' or p.organization_id = p_organization_id)
  ) then
    raise exception using errcode = '22023', message = 'Target profile is not active in this organization';
  end if;

  insert into public.user_roles (organization_id, user_id, role_key, assigned_by)
  values (p_organization_id, p_user_id, p_role_key, auth.uid())
  on conflict do nothing
  returning id into v_assignment_id;

  if v_assignment_id is null then
    select ur.id into v_assignment_id
    from public.user_roles ur
    where ur.user_id = p_user_id
      and ur.role_key = p_role_key
      and ur.organization_id is not distinct from p_organization_id;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (p_organization_id, auth.uid(), 'role.assigned', 'user_roles', v_assignment_id,
    jsonb_build_object('target_user_id', p_user_id, 'role_key', p_role_key));

  return v_assignment_id;
end;
$$;

create function public.add_collection_item(
  p_collection_id uuid,
  p_obligation_id uuid,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item_id uuid;
  v_organization_id uuid;
  v_establishment_id uuid;
  v_remaining numeric(14, 0);
begin
  select c.organization_id, c.establishment_id
  into v_organization_id, v_establishment_id
  from public.collections c
  where c.id = p_collection_id
    and c.collector_id = auth.uid()
    and public.has_role(c.organization_id, 'collector')
    and c.status = 'draft';

  if not found then
    raise exception using errcode = '42501', message = 'Draft collection not found or not assigned to user';
  end if;

  select fo.amount_due - fo.amount_paid into v_remaining
  from public.financial_obligations fo
  where fo.id = p_obligation_id
    and fo.organization_id = v_organization_id
    and fo.establishment_id = v_establishment_id
    and fo.status in ('open', 'partial')
  for update;

  if not found or v_remaining <= 0 then
    raise exception using errcode = '22023', message = 'Open obligation not found for this establishment';
  end if;

  insert into public.collection_items (
    organization_id, collection_id, obligation_id, amount_due_snapshot, notes
  ) values (
    v_organization_id, p_collection_id, p_obligation_id, v_remaining, p_notes
  ) returning id into v_item_id;

  return v_item_id;
end;
$$;

create function public.submit_collection(p_collection_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
begin
  update public.collections c
  set status = 'submitted'
  where c.id = p_collection_id
    and c.collector_id = auth.uid()
    and public.has_role(c.organization_id, 'collector')
    and c.status = 'draft'
    and exists (
      select 1 from public.collection_items ci
      where ci.collection_id = c.id and ci.organization_id = c.organization_id
    )
  returning c.organization_id into v_organization_id;

  if not found then
    raise exception using errcode = '22023', message = 'Draft collection is empty, invalid or not owned by user';
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id)
  values (v_organization_id, auth.uid(), 'collection.submitted', 'collections', p_collection_id);
end;
$$;

create function public.create_payment_request(
  p_collection_item_id uuid,
  p_amount numeric(14, 0),
  p_method text,
  p_idempotency_key text,
  p_cash_register_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_collection_id uuid;
  v_obligation_id uuid;
  v_remaining numeric(14, 0);
  v_payment_id uuid;
  v_existing public.payments%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;

  if p_amount is null or p_amount <= 0 or p_method not in ('cash', 'mobile_money', 'bank_transfer', 'card', 'other') then
    raise exception using errcode = '22023', message = 'Invalid payment amount or method';
  end if;

  select ci.organization_id, ci.collection_id, ci.obligation_id
  into v_organization_id, v_collection_id, v_obligation_id
  from public.collection_items ci
  join public.collections c on c.id = ci.collection_id and c.organization_id = ci.organization_id
  where ci.id = p_collection_item_id
    and c.status in ('submitted', 'validated')
    and c.collector_id = auth.uid()
    and public.has_role(ci.organization_id, 'collector');

  if not found then
    raise exception using errcode = '42501', message = 'Collection item is not accessible for payment';
  end if;

  if not public.has_permission(v_organization_id, 'payment.record') then
    raise exception using errcode = '42501', message = 'Missing payment.record permission';
  end if;

  if p_cash_register_id is not null
    and not public.can_access_cash_register(v_organization_id, p_cash_register_id) then
    raise exception using errcode = '42501', message = 'Cash register is not accessible';
  end if;

  select * into v_existing
  from public.payments p
  where p.organization_id = v_organization_id
    and p.idempotency_key = p_idempotency_key;

  if found then
    if v_existing.collection_item_id = p_collection_item_id
      and v_existing.amount = p_amount
      and v_existing.method = p_method
      and v_existing.recorded_by = auth.uid() then
      return v_existing.id;
    end if;
    raise exception using errcode = '23505', message = 'Idempotency key was already used for a different request';
  end if;

  select fo.amount_due - fo.amount_paid into v_remaining
  from public.financial_obligations fo
  where fo.id = v_obligation_id
    and fo.organization_id = v_organization_id
    and fo.status in ('open', 'partial')
  for update;

  if not found or p_amount > v_remaining then
    raise exception using errcode = '22023', message = 'Payment exceeds the outstanding obligation';
  end if;

  insert into public.payments (
    organization_id, collection_id, collection_item_id, cash_register_id,
    amount, method, idempotency_key, recorded_by
  ) values (
    v_organization_id, v_collection_id, p_collection_item_id, p_cash_register_id,
    p_amount, p_method, p_idempotency_key, auth.uid()
  ) on conflict (organization_id, idempotency_key) do nothing
  returning id into v_payment_id;

  if v_payment_id is null then
    select p.id into v_payment_id
    from public.payments p
    where p.organization_id = v_organization_id
      and p.idempotency_key = p_idempotency_key
      and p.collection_item_id = p_collection_item_id
      and p.amount = p_amount
      and p.method = p_method
      and p.recorded_by = auth.uid();
    if v_payment_id is null then
      raise exception using errcode = '23505', message = 'Idempotency key conflict';
    end if;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id)
  values (v_organization_id, auth.uid(), 'payment.requested', 'payments', v_payment_id);

  return v_payment_id;
end;
$$;

create function public.confirm_cash_payment(p_payment_id uuid, p_cash_register_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
  v_obligation_id uuid;
  v_remaining numeric(14, 0);
  v_receipt_id uuid;
  v_receipt_number text;
begin
  select p.* into v_payment
  from public.payments p
  where p.id = p_payment_id
  for update;

  if not found or v_payment.status <> 'pending' or v_payment.method <> 'cash'
    or (v_payment.cash_register_id is not null and v_payment.cash_register_id <> p_cash_register_id) then
    raise exception using errcode = '22023', message = 'Pending cash payment with register required';
  end if;

  if not public.has_role(v_payment.organization_id, 'cashier')
    or not exists (
      select 1 from public.cash_registers cr
      where cr.id = p_cash_register_id
        and cr.organization_id = v_payment.organization_id
        and cr.assigned_cashier_id = auth.uid()
        and cr.status = 'open'
    ) then
    raise exception using errcode = '42501', message = 'Cashier is not assigned to an open register';
  end if;

  select ci.obligation_id into v_obligation_id
  from public.collection_items ci
  where ci.id = v_payment.collection_item_id
    and ci.collection_id = v_payment.collection_id
    and ci.organization_id = v_payment.organization_id;

  select fo.amount_due - fo.amount_paid into v_remaining
  from public.financial_obligations fo
  where fo.id = v_obligation_id
    and fo.organization_id = v_payment.organization_id
    and fo.status in ('open', 'partial')
  for update;

  if not found or v_payment.amount > v_remaining then
    raise exception using errcode = '22023', message = 'Payment exceeds remaining obligation';
  end if;

  update public.payments
  set status = 'confirmed', cash_register_id = p_cash_register_id, confirmed_at = now()
  where id = v_payment.id;

  update public.financial_obligations
  set amount_paid = amount_paid + v_payment.amount,
      status = case
        when amount_paid + v_payment.amount = amount_due then 'paid'
        else 'partial'
      end
  where id = v_obligation_id;

  insert into public.cash_movements (
    organization_id, cash_register_id, payment_id, movement_type,
    amount, idempotency_key, reference, actor_id
  ) values (
    v_payment.organization_id, p_cash_register_id, v_payment.id,
    'collection', v_payment.amount, 'payment:' || v_payment.id::text,
    v_payment.provider_reference, auth.uid()
  );

  v_receipt_number := 'R-' || to_char(clock_timestamp(), 'YYYY') || '-'
    || lpad(nextval('public.receipt_number_seq')::text, 8, '0');
  insert into public.receipts (organization_id, payment_id, receipt_number)
  values (v_payment.organization_id, v_payment.id, v_receipt_number)
  returning id into v_receipt_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id)
  values (v_payment.organization_id, auth.uid(), 'payment.confirmed.cash', 'payments', v_payment.id);

  return v_receipt_id;
end;
$$;

create function public.confirm_external_payment(
  p_payment_id uuid,
  p_provider text,
  p_provider_reference text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment public.payments%rowtype;
  v_obligation_id uuid;
  v_remaining numeric(14, 0);
  v_receipt_id uuid;
  v_receipt_number text;
begin
  if p_provider is null or length(btrim(p_provider)) = 0
    or p_provider_reference is null or length(btrim(p_provider_reference)) = 0 then
    raise exception using errcode = '22023', message = 'Provider and provider reference are required';
  end if;

  select p.* into v_payment
  from public.payments p
  where p.id = p_payment_id
  for update;

  if not found then
    raise exception using errcode = 'P0002', message = 'Payment not found';
  end if;

  if v_payment.status = 'confirmed'
    and v_payment.provider = p_provider
    and v_payment.provider_reference = p_provider_reference then
    select r.id into v_receipt_id from public.receipts r where r.payment_id = v_payment.id;
    return v_receipt_id;
  end if;

  if v_payment.status <> 'pending' or v_payment.method not in ('mobile_money', 'bank_transfer', 'card') then
    raise exception using errcode = '22023', message = 'Payment cannot be externally confirmed';
  end if;

  select ci.obligation_id into v_obligation_id
  from public.collection_items ci
  where ci.id = v_payment.collection_item_id
    and ci.collection_id = v_payment.collection_id
    and ci.organization_id = v_payment.organization_id;

  select fo.amount_due - fo.amount_paid into v_remaining
  from public.financial_obligations fo
  where fo.id = v_obligation_id
    and fo.organization_id = v_payment.organization_id
    and fo.status in ('open', 'partial')
  for update;

  if not found or v_payment.amount > v_remaining then
    raise exception using errcode = '22023', message = 'Payment exceeds remaining obligation';
  end if;

  update public.payments
  set status = 'confirmed',
      provider = p_provider,
      provider_reference = p_provider_reference,
      confirmed_at = now()
  where id = v_payment.id;

  update public.financial_obligations
  set amount_paid = amount_paid + v_payment.amount,
      status = case
        when amount_paid + v_payment.amount = amount_due then 'paid'
        else 'partial'
      end
  where id = v_obligation_id;

  v_receipt_number := 'R-' || to_char(clock_timestamp(), 'YYYY') || '-'
    || lpad(nextval('public.receipt_number_seq')::text, 8, '0');
  insert into public.receipts (organization_id, payment_id, receipt_number)
  values (v_payment.organization_id, v_payment.id, v_receipt_number)
  returning id into v_receipt_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_payment.organization_id, null, 'payment.confirmed.external', 'payments', v_payment.id,
    jsonb_build_object('provider', p_provider, 'provider_reference', p_provider_reference));

  return v_receipt_id;
end;
$$;

create function public.void_receipt(p_receipt_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
begin
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception using errcode = '22023', message = 'A reason of at least five characters is required';
  end if;

  update public.receipts r
  set status = 'voided', voided_at = now(), void_reason = btrim(p_reason)
  where r.id = p_receipt_id
    and r.status = 'issued'
    and public.has_permission(r.organization_id, 'receipt.void')
  returning r.organization_id into v_organization_id;

  if not found then
    raise exception using errcode = '42501', message = 'Receipt not found or not authorized';
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'receipt.voided', 'receipts', p_receipt_id,
    jsonb_build_object('reason', btrim(p_reason)));
end;
$$;

create function public.prevent_audit_log_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = '42501', message = 'Audit log entries are append-only';
end;
$$;

create trigger audit_logs_append_only
  before update or delete on public.audit_logs
  for each row execute function public.prevent_audit_log_mutation();

revoke all on function public.assign_user_role(uuid, uuid, text) from public, anon;
revoke all on function public.add_collection_item(uuid, uuid, text) from public, anon;
revoke all on function public.submit_collection(uuid) from public, anon;
revoke all on function public.create_payment_request(uuid, numeric, text, text, uuid) from public, anon;
revoke all on function public.confirm_cash_payment(uuid, uuid) from public, anon;
revoke all on function public.confirm_external_payment(uuid, text, text) from public, anon, authenticated;
revoke all on function public.void_receipt(uuid, text) from public, anon;
revoke all on function public.prevent_audit_log_mutation() from public, anon, authenticated;

grant execute on function public.assign_user_role(uuid, uuid, text) to authenticated;
grant execute on function public.add_collection_item(uuid, uuid, text) to authenticated;
grant execute on function public.submit_collection(uuid) to authenticated;
grant execute on function public.create_payment_request(uuid, numeric, text, text, uuid) to authenticated;
grant execute on function public.confirm_cash_payment(uuid, uuid) to authenticated;
grant execute on function public.confirm_external_payment(uuid, text, text) to service_role;
grant execute on function public.void_receipt(uuid, text) to authenticated;