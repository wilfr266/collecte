alter table public.collections
  add column idempotency_key text;

create unique index collections_org_idempotency_idx
  on public.collections (organization_id, idempotency_key)
  where idempotency_key is not null;

create function public.record_offline_visit(
  p_assignment_id uuid,
  p_establishment_id uuid,
  p_outcome text,
  p_idempotency_key text,
  p_visited_at timestamptz,
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
  v_organization_id uuid;
  v_collection_id uuid;
  v_existing public.collections%rowtype;
begin
  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = auth.uid()
    and p.status = 'active'
    and p.organization_id is not null;

  if not found or not public.has_role(v_organization_id, 'collector') then
    raise exception using errcode = '42501', message = 'Active collector role required';
  end if;
  if p_outcome not in ('contacted', 'unavailable', 'refused', 'follow_up')
    or p_idempotency_key is null or length(p_idempotency_key) not between 8 and 128
    or p_visited_at is null
    or p_visited_at > now() + interval '5 minutes'
    or p_visited_at < now() - interval '30 days' then
    raise exception using errcode = '22023', message = 'Invalid visit input';
  end if;
  if (p_latitude is null) <> (p_longitude is null)
    or (p_latitude is not null and (
      p_latitude not between -90 and 90
      or p_longitude not between -180 and 180
      or p_accuracy_m is null or p_accuracy_m <= 0 or p_accuracy_m > 100
      or p_location_captured_at is null
      or p_location_captured_at > now() + interval '2 minutes'
    )) then
    raise exception using errcode = '22023', message = 'Invalid visit location';
  end if;

  select * into v_existing
  from public.collections c
  where c.organization_id = v_organization_id
    and c.idempotency_key = p_idempotency_key;
  if found then
    if v_existing.collector_id = auth.uid()
      and v_existing.mission_assignment_id = p_assignment_id
      and v_existing.establishment_id = p_establishment_id
      and v_existing.outcome = p_outcome then
      return v_existing.id;
    end if;
    raise exception using errcode = '23505', message = 'Visit idempotency key conflict';
  end if;

  if not public.can_create_collection(v_organization_id, p_assignment_id, p_establishment_id) then
    raise exception using errcode = '42501', message = 'Assignment or establishment is not accessible';
  end if;

  insert into public.collections (
    organization_id, mission_assignment_id, establishment_id, collector_id,
    outcome, notes, status, idempotency_key, visited_at,
    visit_latitude, visit_longitude, location_accuracy_m, location_captured_at
  ) values (
    v_organization_id, p_assignment_id, p_establishment_id, auth.uid(),
    p_outcome, nullif(btrim(p_notes), ''), 'submitted', p_idempotency_key, p_visited_at,
    p_latitude, p_longitude, p_accuracy_m, p_location_captured_at
  ) returning id into v_collection_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id)
  values (v_organization_id, auth.uid(), 'collection.offline_visit_synced', 'collections', v_collection_id);

  return v_collection_id;
end;
$$;

revoke all on function public.record_offline_visit(uuid, uuid, text, text, timestamptz, text, numeric, numeric, numeric, timestamptz)
  from public, anon;
grant execute on function public.record_offline_visit(uuid, uuid, text, text, timestamptz, text, numeric, numeric, numeric, timestamptz)
  to authenticated;