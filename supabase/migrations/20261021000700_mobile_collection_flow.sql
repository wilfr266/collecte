create function public.record_collection_payment_request(
  p_assignment_id uuid,
  p_establishment_id uuid,
  p_obligation_id uuid,
  p_amount numeric(14, 0),
  p_method text,
  p_idempotency_key text,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_remaining numeric(14, 0);
  v_collection_id uuid;
  v_collection_item_id uuid;
  v_payment_id uuid;
  v_existing record;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;

  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = auth.uid()
    and p.status = 'active'
    and p.organization_id is not null;

  if not found
    or not public.has_role(v_organization_id, 'collector')
    or not public.has_permission(v_organization_id, 'payment.record') then
    raise exception using errcode = '42501', message = 'Active collector role and payment permission required';
  end if;

  if p_amount is null or p_amount <= 0
    or p_method not in ('cash', 'mobile_money', 'bank_transfer', 'card', 'other')
    or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'Invalid amount, payment method or idempotency key';
  end if;

  select p.id, p.amount, p.method, p.recorded_by,
    c.mission_assignment_id, c.establishment_id, ci.obligation_id
  into v_existing
  from public.payments p
  join public.collections c
    on c.id = p.collection_id and c.organization_id = p.organization_id
  join public.collection_items ci
    on ci.id = p.collection_item_id and ci.collection_id = c.id
      and ci.organization_id = c.organization_id
  where p.organization_id = v_organization_id
    and p.idempotency_key = p_idempotency_key;

  if found then
    if v_existing.amount = p_amount
      and v_existing.method = p_method
      and v_existing.recorded_by = auth.uid()
      and v_existing.mission_assignment_id = p_assignment_id
      and v_existing.establishment_id = p_establishment_id
      and v_existing.obligation_id = p_obligation_id then
      return v_existing.id;
    end if;
    raise exception using errcode = '23505', message = 'Idempotency key was used for a different request';
  end if;

  if not public.can_create_collection(v_organization_id, p_assignment_id, p_establishment_id) then
    raise exception using errcode = '42501', message = 'Assignment or establishment is not accessible';
  end if;

  select fo.amount_due - fo.amount_paid into v_remaining
  from public.financial_obligations fo
  where fo.id = p_obligation_id
    and fo.organization_id = v_organization_id
    and fo.establishment_id = p_establishment_id
    and fo.status in ('open', 'partial')
  for update;

  if not found or v_remaining <= 0 or p_amount > v_remaining then
    raise exception using errcode = '22023', message = 'Payment exceeds the open obligation balance';
  end if;

  insert into public.collections (
    organization_id, mission_assignment_id, establishment_id,
    collector_id, outcome, notes, status
  ) values (
    v_organization_id, p_assignment_id, p_establishment_id,
    auth.uid(), 'contacted', nullif(btrim(p_notes), ''), 'draft'
  ) returning id into v_collection_id;

  insert into public.collection_items (
    organization_id, collection_id, obligation_id, amount_due_snapshot
  ) values (
    v_organization_id, v_collection_id, p_obligation_id, v_remaining
  ) returning id into v_collection_item_id;

  update public.collections
  set status = 'submitted'
  where id = v_collection_id;

  insert into public.payments (
    organization_id, collection_id, collection_item_id,
    amount, method, idempotency_key, status, recorded_by
  ) values (
    v_organization_id, v_collection_id, v_collection_item_id,
    p_amount, p_method, p_idempotency_key, 'pending', auth.uid()
  ) returning id into v_payment_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id)
  values
    (v_organization_id, auth.uid(), 'collection.submitted', 'collections', v_collection_id),
    (v_organization_id, auth.uid(), 'payment.requested', 'payments', v_payment_id);

  return v_payment_id;
end;
$$;

revoke all on function public.record_collection_payment_request(uuid, uuid, uuid, numeric, text, text, text)
  from public, anon;
grant execute on function public.record_collection_payment_request(uuid, uuid, uuid, numeric, text, text, text)
  to authenticated;