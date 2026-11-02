alter table public.cash_movements
  add column direction smallint not null default 1 check (direction in (-1, 1));

update public.cash_movements cm
set direction = case
  when cm.movement_type = 'disbursement' then -1
  when cm.movement_type = 'reversal' then -coalesce(original.direction, 1)
  else 1
end
from public.cash_movements original
where cm.reverses_movement_id = original.id
  and cm.movement_type = 'reversal';

update public.cash_movements
set direction = -1
where movement_type = 'disbursement';

alter table public.cash_reconciliations
  add column idempotency_key text;

create unique index cash_reconciliations_idempotency_idx
  on public.cash_reconciliations (organization_id, idempotency_key)
  where idempotency_key is not null;

create function public.cash_register_summary(p_cash_register_id uuid)
returns table (
  opening_balance numeric(14, 0),
  collections_total numeric(14, 0),
  disbursements_total numeric(14, 0),
  adjustments_net numeric(14, 0),
  theoretical_balance numeric(14, 0)
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
begin
  select cr.organization_id into v_organization_id
  from public.cash_registers cr
  where cr.id = p_cash_register_id;

  if not found or not public.can_access_cash_register(v_organization_id, p_cash_register_id) then
    raise exception using errcode = '42501', message = 'Cash register not accessible';
  end if;

  return query
  select
    coalesce(sum(cm.amount * cm.direction) filter (where cm.movement_type = 'opening'), 0)::numeric(14, 0),
    coalesce(sum(cm.amount * cm.direction) filter (where cm.movement_type = 'collection'), 0)::numeric(14, 0),
    coalesce(-sum(cm.amount * cm.direction) filter (where cm.movement_type = 'disbursement'), 0)::numeric(14, 0),
    coalesce(sum(cm.amount * cm.direction) filter (where cm.movement_type in ('adjustment', 'reversal')), 0)::numeric(14, 0),
    coalesce(sum(cm.amount * cm.direction), 0)::numeric(14, 0)
  from public.cash_movements cm
  where cm.cash_register_id = p_cash_register_id
    and cm.organization_id = v_organization_id;
end;
$$;

create function public.submit_cash_reconciliation(
  p_cash_register_id uuid,
  p_counted_amount numeric(14, 0),
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
  v_expected_amount numeric(14, 0);
  v_difference numeric(14, 0);
  v_reconciliation_id uuid;
  v_existing public.cash_reconciliations%rowtype;
begin
  if auth.uid() is null or p_counted_amount is null or p_counted_amount < 0
    or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128 then
    raise exception using errcode = '22023', message = 'Invalid reconciliation input';
  end if;

  select cr.organization_id into v_organization_id
  from public.cash_registers cr
  where cr.id = p_cash_register_id
  for update;

  if not found or not public.has_permission(v_organization_id, 'cash.manage')
    or not public.can_access_cash_register(v_organization_id, p_cash_register_id) then
    raise exception using errcode = '42501', message = 'Cash register not accessible';
  end if;

  select * into v_existing
  from public.cash_reconciliations r
  where r.organization_id = v_organization_id
    and r.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.cash_register_id = p_cash_register_id
      and v_existing.counted_amount = p_counted_amount
      and v_existing.prepared_by = auth.uid() then
      return v_existing.id;
    end if;
    raise exception using errcode = '23505', message = 'Idempotency key already used';
  end if;

  select coalesce(sum(cm.amount * cm.direction), 0)::numeric(14, 0)
  into v_expected_amount
  from public.cash_movements cm
  where cm.organization_id = v_organization_id
    and cm.cash_register_id = p_cash_register_id;

  v_difference := p_counted_amount - v_expected_amount;
  if v_difference <> 0 and length(btrim(coalesce(p_notes, ''))) < 5 then
    raise exception using errcode = '22023', message = 'A reason is required when cash differs';
  end if;

  insert into public.cash_reconciliations (
    organization_id, cash_register_id, expected_amount, counted_amount,
    status, prepared_by, notes, idempotency_key
  ) values (
    v_organization_id, p_cash_register_id, v_expected_amount, p_counted_amount,
    'submitted', auth.uid(), nullif(btrim(p_notes), ''), p_idempotency_key
  ) returning id into v_reconciliation_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'cash.reconciliation.submitted',
    'cash_reconciliations', v_reconciliation_id,
    jsonb_build_object('difference_amount', v_difference));

  return v_reconciliation_id;
end;
$$;

revoke all on function public.cash_register_summary(uuid) from public, anon;
revoke all on function public.submit_cash_reconciliation(uuid, numeric, text, text) from public, anon;
grant execute on function public.cash_register_summary(uuid) to authenticated;
grant execute on function public.submit_cash_reconciliation(uuid, numeric, text, text) to authenticated;