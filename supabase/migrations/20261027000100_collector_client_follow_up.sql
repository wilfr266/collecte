-- Suivi d'un client (contribuable) par un collecteur, décidé par l'administrateur d'organisation.
-- Source de travail : Terenza Admin. Tests pgTAP : tests/collector_client_follow_up.test.sql.
--
-- Modèle mobile existant (inchangé) : un collecteur voit et visite les établissements d'une zone
-- s'il est affecté à une mission active (assigned / in_progress) de cette zone
-- (can_access_zone, can_access_establishment, collections.mission_assignment_id).
--
-- assign_collector_to_taxpayer :
--   1. réutilise une mission active de la zone du client, ou crée la mission « Suivi des clients » ;
--   2. affecte le collecteur à cette mission (mission_assignments, sans doublon) ;
--   3. enregistre le lien explicite client ↔ collecteur (taxpayer_collectors), affiché dans
--      Terenza Admin et lisible par le collecteur concerné.
-- unassign_collector_from_taxpayer retire le lien ; l'affectation à la mission n'est retirée que
-- si plus aucun client suivi n'en dépend et qu'aucune collecte ne la référence.
-- Application mobile : non modifiée ; elle voit le client via la mission, comme aujourd'hui.

create table public.taxpayer_collectors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  taxpayer_id uuid not null,
  collector_id uuid not null,
  mission_assignment_id uuid not null,
  assigned_by uuid references public.profiles(id) on delete set null,
  assigned_at timestamptz not null default now(),
  unique (taxpayer_id, collector_id),
  foreign key (taxpayer_id, organization_id)
    references public.taxpayers(id, organization_id) on delete restrict,
  foreign key (collector_id, organization_id)
    references public.profiles(id, organization_id) on delete restrict,
  foreign key (mission_assignment_id, organization_id)
    references public.mission_assignments(id, organization_id) on delete restrict
);

create index taxpayer_collectors_collector_idx on public.taxpayer_collectors (organization_id, collector_id);

revoke all on public.taxpayer_collectors from public, anon, authenticated;
grant select on public.taxpayer_collectors to authenticated;
alter table public.taxpayer_collectors enable row level security;

create policy taxpayer_collectors_read_scoped on public.taxpayer_collectors
  for select to authenticated using (
    public.has_permission(organization_id, 'directory.read_all') or collector_id = auth.uid()
  );

create function public.assign_collector_to_taxpayer(p_taxpayer_id uuid, p_collector_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.require_manager_organization('mission.assign');
  v_zone_id uuid;
  v_zone_name text;
  v_mission_id uuid;
  v_assignment_id uuid;
  v_link_id uuid;
begin
  select t.zone_id, z.name into v_zone_id, v_zone_name
  from public.taxpayers t
  join public.zones z on z.id = t.zone_id and z.organization_id = t.organization_id
  where t.id = p_taxpayer_id and t.organization_id = v_organization_id;
  if v_zone_id is null then
    raise exception using errcode = 'P0002', message = 'Taxpayer not found in this organization';
  end if;

  if not exists (
    select 1 from public.profiles p
    join public.user_roles ur on ur.user_id = p.id and ur.organization_id = p.organization_id
    where p.id = p_collector_id and p.organization_id = v_organization_id
      and p.status = 'active' and ur.role_key = 'collector'
  ) then
    raise exception using errcode = '22023', message = 'Target is not an active collector of this organization';
  end if;

  -- Idempotent : un suivi existant est renvoyé tel quel.
  select tc.id into v_link_id
  from public.taxpayer_collectors tc
  where tc.taxpayer_id = p_taxpayer_id and tc.collector_id = p_collector_id;
  if v_link_id is not null then
    return v_link_id;
  end if;

  -- Mission active de la zone déjà suivie par ce collecteur, sinon toute mission active de la zone,
  -- sinon nouvelle mission de suivi.
  select m.id into v_mission_id
  from public.missions m
  left join public.mission_assignments ma
    on ma.mission_id = m.id and ma.user_id = p_collector_id
  where m.organization_id = v_organization_id and m.zone_id = v_zone_id
    and m.status in ('assigned', 'in_progress')
  order by (ma.id is not null) desc, m.created_at
  limit 1;

  if v_mission_id is null then
    insert into public.missions (organization_id, zone_id, title, scheduled_for, status, created_by)
    values (v_organization_id, v_zone_id, left('Suivi des clients · ' || v_zone_name, 160), current_date, 'assigned', auth.uid())
    returning id into v_mission_id;

    insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
    values (v_organization_id, auth.uid(), 'mission.created', 'missions', v_mission_id,
      jsonb_build_object('zone_id', v_zone_id, 'reason', 'collector_follow_up'));
  end if;

  insert into public.mission_assignments (organization_id, mission_id, user_id, assigned_by)
  values (v_organization_id, v_mission_id, p_collector_id, auth.uid())
  on conflict (mission_id, user_id) do nothing
  returning id into v_assignment_id;
  if v_assignment_id is null then
    select ma.id into v_assignment_id
    from public.mission_assignments ma
    where ma.mission_id = v_mission_id and ma.user_id = p_collector_id;
  end if;

  insert into public.taxpayer_collectors (organization_id, taxpayer_id, collector_id, mission_assignment_id, assigned_by)
  values (v_organization_id, p_taxpayer_id, p_collector_id, v_assignment_id, auth.uid())
  returning id into v_link_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'taxpayer.collector_assigned', 'taxpayer_collectors', v_link_id,
    jsonb_build_object('taxpayer_id', p_taxpayer_id, 'collector_id', p_collector_id, 'mission_id', v_mission_id));

  return v_link_id;
end;
$$;

create function public.unassign_collector_from_taxpayer(p_taxpayer_id uuid, p_collector_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.require_manager_organization('mission.assign');
  v_link_id uuid;
  v_assignment_id uuid;
begin
  delete from public.taxpayer_collectors tc
  where tc.taxpayer_id = p_taxpayer_id and tc.collector_id = p_collector_id and tc.organization_id = v_organization_id
  returning tc.id, tc.mission_assignment_id into v_link_id, v_assignment_id;
  if v_link_id is null then
    raise exception using errcode = 'P0002', message = 'Follow-up not found in this organization';
  end if;

  -- L'affectation reste si d'autres clients suivis en dépendent ou si des collectes la référencent.
  if not exists (select 1 from public.taxpayer_collectors tc where tc.mission_assignment_id = v_assignment_id)
    and not exists (select 1 from public.collections c where c.mission_assignment_id = v_assignment_id) then
    delete from public.mission_assignments where id = v_assignment_id;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'taxpayer.collector_unassigned', 'taxpayer_collectors', v_link_id,
    jsonb_build_object('taxpayer_id', p_taxpayer_id, 'collector_id', p_collector_id));
end;
$$;

revoke all on function public.assign_collector_to_taxpayer(uuid, uuid) from public, anon;
revoke all on function public.unassign_collector_from_taxpayer(uuid, uuid) from public, anon;
grant execute on function public.assign_collector_to_taxpayer(uuid, uuid) to authenticated;
grant execute on function public.unassign_collector_from_taxpayer(uuid, uuid) to authenticated;
