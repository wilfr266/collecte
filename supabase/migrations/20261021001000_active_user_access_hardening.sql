create or replace function public.can_access_mission(p_organization_id uuid, p_mission_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_organization_member(p_organization_id) and exists (
    select 1
    from public.missions m
    where m.id = p_mission_id
      and m.organization_id = p_organization_id
      and (
        public.has_permission(p_organization_id, 'mission.read_all')
        or public.can_access_zone(p_organization_id, m.zone_id)
        or (
          public.has_role(p_organization_id, 'collector')
          and exists (
            select 1
            from public.mission_assignments ma
            where ma.mission_id = m.id
              and ma.organization_id = m.organization_id
              and ma.user_id = auth.uid()
          )
        )
      )
  );
$$;

create or replace function public.can_access_collection(p_organization_id uuid, p_collection_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_organization_member(p_organization_id) and exists (
    select 1
    from public.collections c
    join public.establishments e
      on e.id = c.establishment_id and e.organization_id = c.organization_id
    where c.id = p_collection_id
      and c.organization_id = p_organization_id
      and (
        (c.collector_id = auth.uid() and public.has_role(p_organization_id, 'collector'))
        or public.has_permission(p_organization_id, 'collection.read_all')
        or (
          public.has_role(p_organization_id, 'supervisor')
          and public.can_access_zone(p_organization_id, e.zone_id)
        )
      )
  );
$$;

revoke all on function public.can_access_mission(uuid, uuid) from public, anon;
revoke all on function public.can_access_collection(uuid, uuid) from public, anon;
grant execute on function public.can_access_mission(uuid, uuid) to authenticated;
grant execute on function public.can_access_collection(uuid, uuid) to authenticated;