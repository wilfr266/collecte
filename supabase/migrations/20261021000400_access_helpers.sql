alter default privileges in schema public
  revoke all on tables from anon, authenticated;
alter default privileges in schema public
  revoke all on sequences from anon, authenticated;

create function public.has_role(p_organization_id uuid, p_role_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles p
    join public.user_roles ur on ur.user_id = p.id
    where p.id = auth.uid()
      and p.status = 'active'
      and ur.role_key = p_role_key
      and (
        (ur.organization_id = p_organization_id and p.organization_id = p_organization_id)
        or (ur.organization_id is null and ur.role_key = 'super_admin')
      )
  );
$$;

create function public.has_permission(p_organization_id uuid, p_permission_key text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_role(p_organization_id, 'super_admin') or exists (
    select 1
    from public.profiles p
    join public.user_roles ur on ur.user_id = p.id
    join public.role_permissions rp on rp.role_key = ur.role_key
    where p.id = auth.uid()
      and p.status = 'active'
      and p.organization_id = p_organization_id
      and ur.organization_id = p_organization_id
      and rp.permission_key = p_permission_key
  );
$$;

create function public.is_organization_member(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_role(p_organization_id, 'super_admin') or exists (
    select 1
    from public.profiles p
    join public.user_roles ur on ur.user_id = p.id
    where p.id = auth.uid()
      and p.status = 'active'
      and p.organization_id = p_organization_id
      and ur.organization_id = p_organization_id
  );
$$;

create function public.can_access_zone(p_organization_id uuid, p_zone_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_permission(p_organization_id, 'directory.read_all') or exists (
    select 1
    from public.zones z
    where z.id = p_zone_id
      and z.organization_id = p_organization_id
      and (
        (public.has_role(p_organization_id, 'supervisor') and z.supervisor_id = auth.uid())
        or (
          public.has_role(p_organization_id, 'collector')
          and exists (
            select 1
            from public.missions m
            join public.mission_assignments ma
              on ma.mission_id = m.id and ma.organization_id = m.organization_id
            where m.organization_id = p_organization_id
              and m.zone_id = z.id
              and ma.user_id = auth.uid()
              and m.status in ('assigned', 'in_progress')
          )
        )
      )
  );
$$;

create function public.can_access_establishment(p_organization_id uuid, p_establishment_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.establishments e
    where e.id = p_establishment_id
      and e.organization_id = p_organization_id
      and public.can_access_zone(p_organization_id, e.zone_id)
  );
$$;

create function public.can_access_mission(p_organization_id uuid, p_mission_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.missions m
    where m.id = p_mission_id
      and m.organization_id = p_organization_id
      and (
        public.has_permission(p_organization_id, 'mission.read_all')
        or public.can_access_zone(p_organization_id, m.zone_id)
        or exists (
          select 1
          from public.mission_assignments ma
          where ma.mission_id = m.id
            and ma.organization_id = m.organization_id
            and ma.user_id = auth.uid()
        )
      )
  );
$$;

create function public.can_access_collection(p_organization_id uuid, p_collection_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.collections c
    join public.establishments e
      on e.id = c.establishment_id and e.organization_id = c.organization_id
    where c.id = p_collection_id
      and c.organization_id = p_organization_id
      and (
        c.collector_id = auth.uid()
        or public.has_permission(p_organization_id, 'collection.read_all')
        or (
          public.has_role(p_organization_id, 'supervisor')
          and public.can_access_zone(p_organization_id, e.zone_id)
        )
      )
  );
$$;

create function public.can_access_cash_register(p_organization_id uuid, p_register_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.cash_registers cr
    where cr.id = p_register_id
      and cr.organization_id = p_organization_id
      and (
        (cr.assigned_cashier_id = auth.uid() and public.has_role(p_organization_id, 'cashier'))
        or (
          public.has_permission(p_organization_id, 'cash.read')
          and (
            public.has_role(p_organization_id, 'admin')
            or public.has_role(p_organization_id, 'auditor')
            or public.has_role(p_organization_id, 'direction')
            or public.has_role(p_organization_id, 'super_admin')
          )
        )
      )
  );
$$;

revoke all on function public.has_role(uuid, text) from public, anon;
revoke all on function public.has_permission(uuid, text) from public, anon;
revoke all on function public.is_organization_member(uuid) from public, anon;
revoke all on function public.can_access_zone(uuid, uuid) from public, anon;
revoke all on function public.can_access_establishment(uuid, uuid) from public, anon;
revoke all on function public.can_access_mission(uuid, uuid) from public, anon;
revoke all on function public.can_access_collection(uuid, uuid) from public, anon;
revoke all on function public.can_access_cash_register(uuid, uuid) from public, anon;

grant execute on function public.has_role(uuid, text) to authenticated;
grant execute on function public.has_permission(uuid, text) to authenticated;
grant execute on function public.is_organization_member(uuid) to authenticated;
grant execute on function public.can_access_zone(uuid, uuid) to authenticated;
grant execute on function public.can_access_establishment(uuid, uuid) to authenticated;
grant execute on function public.can_access_mission(uuid, uuid) to authenticated;
grant execute on function public.can_access_collection(uuid, uuid) to authenticated;
grant execute on function public.can_access_cash_register(uuid, uuid) to authenticated;