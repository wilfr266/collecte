alter type public.appointment_status add value 'in_progress';

alter table public.appointments
  add column started_at timestamptz,
  add column completed_at timestamptz;

create function public.start_appointment(p_appointment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
begin
  update public.appointments a
  set status = 'in_progress', started_at = now()
  where a.id = p_appointment_id
    and a.assigned_to = auth.uid()
    and a.status = 'scheduled'
    and public.has_role(a.organization_id, 'collector')
  returning a.organization_id into v_organization_id;

  if not found then
    raise exception using errcode = '42501', message = 'Appointment not available to this collector';
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id)
  values (v_organization_id, auth.uid(), 'appointment.started', 'appointments', p_appointment_id);
end;
$$;

create function public.finish_appointment(
  p_appointment_id uuid,
  p_result text,
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_status public.appointment_status;
begin
  if p_result not in ('completed', 'missed', 'cancelled') then
    raise exception using errcode = '22023', message = 'Unsupported appointment result';
  end if;
  if p_result in ('missed', 'cancelled') and length(btrim(coalesce(p_notes, ''))) < 5 then
    raise exception using errcode = '22023', message = 'A reason of at least five characters is required';
  end if;

  v_status := p_result::public.appointment_status;
  update public.appointments a
  set status = v_status,
      notes = coalesce(nullif(btrim(p_notes), ''), a.notes),
      completed_at = now()
  where a.id = p_appointment_id
    and a.assigned_to = auth.uid()
    and a.status in ('in_progress', 'scheduled')
    and public.has_role(a.organization_id, 'collector')
  returning a.organization_id into v_organization_id;

  if not found then
    raise exception using errcode = '42501', message = 'Appointment not available to this collector';
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'appointment.finished', 'appointments', p_appointment_id,
    jsonb_build_object('result', p_result, 'notes', p_notes));
end;
$$;

create function public.reschedule_appointment(
  p_appointment_id uuid,
  p_new_starts_at timestamptz,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
begin
  if p_new_starts_at is null or p_new_starts_at <= now()
    or length(btrim(coalesce(p_reason, ''))) < 5 then
    raise exception using errcode = '22023', message = 'Future date and reason are required';
  end if;

  update public.appointments a
  set starts_at = p_new_starts_at,
      notes = concat_ws(E'\n', nullif(a.notes, ''), 'Report : ' || btrim(p_reason))
  where a.id = p_appointment_id
    and a.assigned_to = auth.uid()
    and a.status = 'scheduled'
    and public.has_role(a.organization_id, 'collector')
  returning a.organization_id into v_organization_id;

  if not found then
    raise exception using errcode = '42501', message = 'Appointment not available to this collector';
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'appointment.rescheduled', 'appointments', p_appointment_id,
    jsonb_build_object('new_starts_at', p_new_starts_at, 'reason', btrim(p_reason)));
end;
$$;

revoke all on function public.start_appointment(uuid) from public, anon;
revoke all on function public.finish_appointment(uuid, text, text) from public, anon;
revoke all on function public.reschedule_appointment(uuid, timestamptz, text) from public, anon;
grant execute on function public.start_appointment(uuid) to authenticated;
grant execute on function public.finish_appointment(uuid, text, text) to authenticated;
grant execute on function public.reschedule_appointment(uuid, timestamptz, text) to authenticated;