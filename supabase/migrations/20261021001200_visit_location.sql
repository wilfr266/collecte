alter table public.collections
  add column visit_latitude numeric(9, 6),
  add column visit_longitude numeric(9, 6),
  add column location_accuracy_m numeric(8, 2),
  add column location_captured_at timestamptz,
  add constraint collections_location_pair_check check (
    (visit_latitude is null and visit_longitude is null
      and location_accuracy_m is null and location_captured_at is null)
    or (
      visit_latitude between -90 and 90
      and visit_longitude between -180 and 180
      and location_accuracy_m > 0
      and location_captured_at is not null
    )
  );

create function public.record_collection_payment_request_with_location(
  p_assignment_id uuid,
  p_establishment_id uuid,
  p_obligation_id uuid,
  p_amount numeric(14, 0),
  p_method text,
  p_idempotency_key text,
  p_notes text default null,
  p_latitude numeric(9, 6) default null,
  p_longitude numeric(9, 6) default null,
  p_accuracy_m numeric(8, 2) default null,
  p_location_captured_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payment_id uuid;
  v_collection_id uuid;
begin
  if (p_latitude is null) <> (p_longitude is null)
    or (p_latitude is not null and (
      p_latitude not between -90 and 90
      or p_longitude not between -180 and 180
      or p_accuracy_m is null or p_accuracy_m <= 0 or p_accuracy_m > 100
      or p_location_captured_at is null
      or p_location_captured_at > now() + interval '2 minutes'
    )) then
    raise exception using errcode = '22023', message = 'Invalid or stale visit location';
  end if;

  v_payment_id := public.record_collection_payment_request(
    p_assignment_id,
    p_establishment_id,
    p_obligation_id,
    p_amount,
    p_method,
    p_idempotency_key,
    p_notes
  );

  if p_latitude is not null then
    update public.collections c
    set visit_latitude = p_latitude,
        visit_longitude = p_longitude,
        location_accuracy_m = p_accuracy_m,
        location_captured_at = p_location_captured_at
    from public.payments p
    where p.id = v_payment_id
      and p.collection_id = c.id
      and p.organization_id = c.organization_id
      and c.collector_id = auth.uid();
  end if;

  return v_payment_id;
end;
$$;

revoke all on function public.record_collection_payment_request_with_location(
  uuid, uuid, uuid, numeric, text, text, text, numeric, numeric, numeric, timestamptz
) from public, anon;
grant execute on function public.record_collection_payment_request_with_location(
  uuid, uuid, uuid, numeric, text, text, text, numeric, numeric, numeric, timestamptz
) to authenticated;