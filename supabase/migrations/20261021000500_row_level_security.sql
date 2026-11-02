create function public.can_create_collection(
  p_organization_id uuid,
  p_assignment_id uuid,
  p_establishment_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_role(p_organization_id, 'collector') and exists (
    select 1
    from public.mission_assignments ma
    join public.missions m
      on m.id = ma.mission_id and m.organization_id = ma.organization_id
    join public.establishments e
      on e.id = p_establishment_id and e.organization_id = ma.organization_id
    where ma.id = p_assignment_id
      and ma.organization_id = p_organization_id
      and ma.user_id = auth.uid()
      and m.zone_id = e.zone_id
      and m.status in ('assigned', 'in_progress')
  );
$$;

create function public.can_add_collection_item(
  p_organization_id uuid,
  p_collection_id uuid,
  p_obligation_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_role(p_organization_id, 'collector') and exists (
    select 1
    from public.collections c
    join public.financial_obligations fo
      on fo.organization_id = c.organization_id
      and fo.establishment_id = c.establishment_id
    where c.id = p_collection_id
      and c.organization_id = p_organization_id
      and c.collector_id = auth.uid()
      and c.status = 'draft'
      and fo.id = p_obligation_id
  );
$$;

revoke all on function public.can_create_collection(uuid, uuid, uuid) from public, anon;
revoke all on function public.can_add_collection_item(uuid, uuid, uuid) from public, anon;
grant execute on function public.can_create_collection(uuid, uuid, uuid) to authenticated;
grant execute on function public.can_add_collection_item(uuid, uuid, uuid) to authenticated;

revoke all on public.organizations, public.profiles, public.roles, public.permissions,
  public.role_permissions, public.user_roles, public.zones, public.taxpayers,
  public.activity_types, public.establishments, public.tax_types,
  public.financial_obligations, public.missions, public.mission_assignments,
  public.appointments, public.collections, public.collection_items, public.payments,
  public.receipts, public.cash_registers, public.cash_movements,
  public.cash_reconciliations, public.notifications, public.audit_logs
  from public, anon, authenticated;
revoke all on sequence public.audit_logs_id_seq from public, anon, authenticated;

grant select on public.roles, public.permissions, public.role_permissions,
  public.organizations, public.profiles, public.user_roles,
  public.zones, public.taxpayers, public.activity_types, public.establishments,
  public.tax_types, public.financial_obligations, public.missions,
  public.mission_assignments, public.appointments, public.collections,
  public.collection_items, public.payments, public.receipts, public.cash_registers,
  public.cash_movements, public.cash_reconciliations, public.notifications,
  public.audit_logs to authenticated;
grant update (display_name, phone) on public.profiles to authenticated;
grant insert on public.collections, public.collection_items to authenticated;
grant update (read_at) on public.notifications to authenticated;

alter table public.organizations enable row level security;
alter table public.profiles enable row level security;
alter table public.roles enable row level security;
alter table public.permissions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.user_roles enable row level security;
alter table public.zones enable row level security;
alter table public.taxpayers enable row level security;
alter table public.activity_types enable row level security;
alter table public.establishments enable row level security;
alter table public.tax_types enable row level security;
alter table public.financial_obligations enable row level security;
alter table public.missions enable row level security;
alter table public.mission_assignments enable row level security;
alter table public.appointments enable row level security;
alter table public.collections enable row level security;
alter table public.collection_items enable row level security;
alter table public.payments enable row level security;
alter table public.receipts enable row level security;
alter table public.cash_registers enable row level security;
alter table public.cash_movements enable row level security;
alter table public.cash_reconciliations enable row level security;
alter table public.notifications enable row level security;
alter table public.audit_logs enable row level security;

create policy roles_read_authenticated on public.roles
  for select to authenticated using (true);
create policy permissions_read_authenticated on public.permissions
  for select to authenticated using (true);
create policy role_permissions_read_authenticated on public.role_permissions
  for select to authenticated using (true);

create policy organizations_read_member on public.organizations
  for select to authenticated using (public.is_organization_member(id));

create policy profiles_read_scoped on public.profiles
  for select to authenticated using (
    id = auth.uid()
    or (organization_id is not null and public.has_permission(organization_id, 'profile.manage'))
  );
create policy profiles_update_self on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy user_roles_read_scoped on public.user_roles
  for select to authenticated using (
    user_id = auth.uid()
    or (organization_id is not null and public.has_permission(organization_id, 'profile.manage'))
    or public.has_role(null, 'super_admin')
  );

create policy zones_read_scoped on public.zones
  for select to authenticated using (public.can_access_zone(organization_id, id));
create policy taxpayers_read_scoped on public.taxpayers
  for select to authenticated using (public.can_access_zone(organization_id, zone_id));
create policy activity_types_read_member on public.activity_types
  for select to authenticated using (public.is_organization_member(organization_id));
create policy establishments_read_scoped on public.establishments
  for select to authenticated using (public.can_access_establishment(organization_id, id));
create policy tax_types_read_member on public.tax_types
  for select to authenticated using (public.is_organization_member(organization_id));

create policy financial_obligations_read_scoped on public.financial_obligations
  for select to authenticated using (
    public.has_permission(organization_id, 'finance.read')
    or public.can_access_establishment(organization_id, establishment_id)
  );

create policy missions_read_scoped on public.missions
  for select to authenticated using (public.can_access_mission(organization_id, id));
create policy mission_assignments_read_scoped on public.mission_assignments
  for select to authenticated using (
    (user_id = auth.uid() and public.has_role(organization_id, 'collector'))
    or public.can_access_mission(organization_id, mission_id)
  );
create policy appointments_read_scoped on public.appointments
  for select to authenticated using (
    (assigned_to = auth.uid() and public.is_organization_member(organization_id))
    or public.has_permission(organization_id, 'directory.read_all')
    or (
      public.has_role(organization_id, 'supervisor')
      and public.can_access_establishment(organization_id, establishment_id)
    )
  );

create policy collections_read_scoped on public.collections
  for select to authenticated using (public.can_access_collection(organization_id, id));
create policy collections_insert_assigned_draft on public.collections
  for insert to authenticated with check (
    collector_id = auth.uid()
    and status = 'draft'
    and public.can_create_collection(organization_id, mission_assignment_id, establishment_id)
  );

create policy collection_items_read_parent on public.collection_items
  for select to authenticated using (public.can_access_collection(organization_id, collection_id));
create policy collection_items_insert_matching_draft on public.collection_items
  for insert to authenticated with check (
    public.can_add_collection_item(organization_id, collection_id, obligation_id)
  );

create policy payments_read_scoped on public.payments
  for select to authenticated using (
    public.can_access_collection(organization_id, collection_id)
    or public.has_permission(organization_id, 'finance.read')
    or (cash_register_id is not null
      and public.can_access_cash_register(organization_id, cash_register_id))
  );
create policy receipts_read_scoped on public.receipts
  for select to authenticated using (
    exists (
      select 1 from public.payments p
      where p.id = payment_id
        and p.organization_id = receipts.organization_id
        and (
          public.can_access_collection(p.organization_id, p.collection_id)
          or public.has_permission(p.organization_id, 'finance.read')
          or (p.cash_register_id is not null
            and public.can_access_cash_register(p.organization_id, p.cash_register_id))
        )
    )
  );

create policy cash_registers_read_scoped on public.cash_registers
  for select to authenticated using (public.can_access_cash_register(organization_id, id));
create policy cash_movements_read_scoped on public.cash_movements
  for select to authenticated using (public.can_access_cash_register(organization_id, cash_register_id));
create policy cash_reconciliations_read_scoped on public.cash_reconciliations
  for select to authenticated using (public.can_access_cash_register(organization_id, cash_register_id));

create policy notifications_read_own on public.notifications
  for select to authenticated using (
    recipient_id = auth.uid() and public.is_organization_member(organization_id)
  );
create policy notifications_mark_read_own on public.notifications
  for update to authenticated using (
    recipient_id = auth.uid() and public.is_organization_member(organization_id)
  ) with check (
    recipient_id = auth.uid() and public.is_organization_member(organization_id)
  );

create policy audit_logs_read_authorized on public.audit_logs
  for select to authenticated using (
    (organization_id is not null and public.has_permission(organization_id, 'audit.read'))
    or (organization_id is null and public.has_role(null, 'super_admin'))
  );