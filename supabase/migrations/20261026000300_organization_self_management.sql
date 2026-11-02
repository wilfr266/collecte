-- Gestion autonome des collecteurs et des clients par l'administrateur d'organisation.
-- Source de travail : Terenza Admin. Tests pgTAP : tests/organization_self_management.test.sql.
--
-- Modèle existant réutilisé, aucune table ni politique modifiée :
--   membres  = profiles (organization_id, status) + user_roles ;
--   clients  = taxpayers (fiche métier, sans compte) + establishments (lieux de collecte),
--              compte client facultatif via client_taxpayer_links (link_client_taxpayer existant).
--
-- Règles communes :
--   * l'organisation n'est jamais prise du client : celle de l'appelant (son profil actif)
--     ou celle de la ligne visée, puis has_permission la vérifie ;
--   * rôles gérables par une organisation : collector, client (jamais admin ni super_admin) ;
--   * aucune action sur soi-même ; un administrateur n'est géré que par le Super-Admin ;
--   * chaque écriture est journalisée dans audit_logs.

insert into public.permissions (key, description) values
  ('directory.manage', 'Créer et modifier zones, contribuables et établissements')
on conflict (key) do nothing;
insert into public.role_permissions (role_key, permission_key) values ('admin', 'directory.manage')
on conflict do nothing;

-- Organisation du compte appelant (profil actif), sinon null.
create function public.caller_organization()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.organization_id from public.profiles p where p.id = auth.uid() and p.status = 'active';
$$;

create function public.require_manager_organization(p_permission_key text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.caller_organization();
begin
  if auth.uid() is null or v_organization_id is null or not public.has_permission(v_organization_id, p_permission_key) then
    raise exception using errcode = '42501', message = format('Missing %s permission in an active organization', p_permission_key);
  end if;
  return v_organization_id;
end;
$$;

-- ── Membres ─────────────────────────────────────────────────────────────────

-- Rattache un compte existant en attente. L'identité est vérifiée par l'email ET
-- l'identifiant affiché sur l'écran d'attente (application mobile ou bureau) : seul le
-- titulaire du compte peut les transmettre. Réponse identique si l'un des deux est faux.
create function public.attach_account_to_organization(p_email text, p_identifier text, p_role_key text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.require_manager_organization('role.assign');
  v_identifier text := lower(btrim(coalesce(p_identifier, '')));
  v_user_id uuid;
  v_current_organization uuid;
  v_role_id uuid;
begin
  if not public.has_permission(v_organization_id, 'profile.manage') then
    raise exception using errcode = '42501', message = 'Missing profile.manage permission';
  end if;
  if p_role_key not in ('collector', 'client') then
    raise exception using errcode = '42501', message = 'Only collector and client roles can be granted here';
  end if;
  if length(v_identifier) < 8 then
    raise exception using errcode = '22023', message = 'Identifier must have at least 8 characters';
  end if;

  select p.id, p.organization_id into v_user_id, v_current_organization
  from public.profiles p
  join auth.users u on u.id = p.id
  where lower(u.email) = lower(btrim(coalesce(p_email, '')))
    and left(p.id::text, length(v_identifier)) = v_identifier
    and u.email_confirmed_at is not null
  for update of p;

  if v_user_id is not null and v_current_organization = v_organization_id then
    raise exception using errcode = '23505', message = 'Account already belongs to this organization';
  end if;
  if v_user_id is null or v_current_organization is not null
    or not exists (select 1 from public.profiles p where p.id = v_user_id and p.status = 'pending') then
    raise exception using errcode = 'P0002', message = 'No pending account matches this email and identifier';
  end if;

  update public.profiles
  set organization_id = v_organization_id, status = 'active', updated_at = now()
  where id = v_user_id;

  insert into public.user_roles (organization_id, user_id, role_key, assigned_by)
  values (v_organization_id, v_user_id, p_role_key, auth.uid())
  returning id into v_role_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'member.attached', 'profiles', v_user_id,
    jsonb_build_object('role_key', p_role_key, 'role_id', v_role_id));

  return v_user_id;
end;
$$;

-- Retire un rôle collector/client à un membre de l'organisation de l'appelant.
create function public.revoke_member_role(p_user_id uuid, p_role_key text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.require_manager_organization('role.assign');
  v_role_id uuid;
begin
  if p_role_key not in ('collector', 'client') then
    raise exception using errcode = '42501', message = 'Only collector and client roles can be revoked here';
  end if;
  if p_user_id = auth.uid() then
    raise exception using errcode = '42501', message = 'Cannot change your own roles';
  end if;

  delete from public.user_roles ur
  where ur.user_id = p_user_id and ur.organization_id = v_organization_id and ur.role_key = p_role_key
  returning ur.id into v_role_id;
  if v_role_id is null then
    raise exception using errcode = 'P0002', message = 'Role not found for this member';
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'role.revoked', 'user_roles', v_role_id,
    jsonb_build_object('target_user_id', p_user_id, 'role_key', p_role_key));
end;
$$;

-- Suspend ou réactive un membre (le compte Auth n'est jamais supprimé). Un compte
-- suspendu perd tout accès : has_role et has_permission exigent un profil actif.
create function public.set_member_status(p_user_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.require_manager_organization('profile.manage');
  v_previous public.profile_status;
begin
  if p_status not in ('active', 'suspended') then
    raise exception using errcode = '22023', message = 'Status must be active or suspended';
  end if;
  if p_user_id = auth.uid() then
    raise exception using errcode = '42501', message = 'Cannot change your own status';
  end if;
  if exists (
    select 1 from public.user_roles ur
    where ur.user_id = p_user_id and ur.role_key in ('admin', 'super_admin')
  ) then
    raise exception using errcode = '42501', message = 'Administrators are managed by the platform operator';
  end if;

  select p.status into v_previous from public.profiles p
  where p.id = p_user_id and p.organization_id = v_organization_id and p.status in ('active', 'suspended')
  for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'Member not found in this organization';
  end if;

  update public.profiles set status = p_status::public.profile_status, updated_at = now() where id = p_user_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'member.status_changed', 'profiles', p_user_id,
    jsonb_build_object('from', v_previous, 'to', p_status));
end;
$$;

-- Finalise un compte créé par l'Edge Function create-organization-member (clé service_role,
-- côté serveur uniquement). Réservée à service_role : les droits de l'acteur sont revérifiés
-- ici, sans auth.uid() (appel serveur).
create function public.register_created_member(p_actor_id uuid, p_user_id uuid, p_role_key text, p_phone text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_role_id uuid;
begin
  if p_role_key not in ('collector', 'client') then
    raise exception using errcode = '42501', message = 'Only collector and client roles can be granted here';
  end if;

  select p.organization_id into v_organization_id
  from public.profiles p
  where p.id = p_actor_id and p.status = 'active' and p.organization_id is not null
    and (
      select count(distinct rp.permission_key)
      from public.user_roles ur
      join public.role_permissions rp on rp.role_key = ur.role_key
      where ur.user_id = p.id and ur.organization_id = p.organization_id
        and rp.permission_key in ('profile.manage', 'role.assign')
    ) = 2;
  if v_organization_id is null then
    raise exception using errcode = '42501', message = 'Actor cannot manage members';
  end if;

  update public.profiles
  set organization_id = v_organization_id, status = 'active', updated_at = now(),
      phone = coalesce(nullif(btrim(p_phone), ''), phone)
  where id = p_user_id and status = 'pending' and organization_id is null;
  if not found then
    raise exception using errcode = '22023', message = 'Created account is not pending';
  end if;

  insert into public.user_roles (organization_id, user_id, role_key, assigned_by)
  values (v_organization_id, p_user_id, p_role_key, p_actor_id)
  returning id into v_role_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, p_actor_id, 'member.created', 'profiles', p_user_id,
    jsonb_build_object('role_key', p_role_key, 'role_id', v_role_id));

  return v_organization_id;
end;
$$;

-- ── Zones, contribuables (fiches clients) et établissements ─────────────────

create function public.save_zone(p_zone_id uuid, p_name text, p_code text, p_is_active boolean default true)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.require_manager_organization('directory.manage');
  -- Casse conservée : les codes existants peuvent contenir des majuscules.
  v_code text := btrim(coalesce(p_code, ''));
  v_zone_id uuid := p_zone_id;
begin
  if v_code !~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,39}$' then
    raise exception using errcode = '22023', message = 'Invalid zone code';
  end if;

  if v_zone_id is null then
    insert into public.zones (organization_id, name, code, is_active)
    values (v_organization_id, btrim(p_name), v_code, coalesce(p_is_active, true))
    returning id into v_zone_id;
  else
    update public.zones
    set name = btrim(p_name), code = v_code, is_active = coalesce(p_is_active, is_active)
    where id = v_zone_id and organization_id = v_organization_id;
    if not found then
      raise exception using errcode = 'P0002', message = 'Zone not found in this organization';
    end if;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), case when p_zone_id is null then 'zone.created' else 'zone.updated' end,
    'zones', v_zone_id, jsonb_build_object('code', v_code));
  return v_zone_id;
end;
$$;

create function public.save_taxpayer(
  p_taxpayer_id uuid,
  p_zone_id uuid,
  p_kind public.taxpayer_kind,
  p_legal_name text,
  p_first_name text default null,
  p_last_name text default null,
  p_taxpayer_number text default null,
  p_phone text default null,
  p_email text default null,
  p_address text default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.require_manager_organization('directory.manage');
  v_first text := nullif(btrim(p_first_name), '');
  v_last text := nullif(btrim(p_last_name), '');
  v_name text := nullif(btrim(p_legal_name), '');
  v_number text := nullif(btrim(p_taxpayer_number), '');
  v_phone text := nullif(btrim(p_phone), '');
  v_taxpayer_id uuid := p_taxpayer_id;
begin
  if p_kind = 'individual' then
    v_name := coalesce(v_name, btrim(concat_ws(' ', v_first, v_last)));
  end if;

  -- Doublon probable : même nom et même téléphone dans l'organisation.
  if v_phone is not null and exists (
    select 1 from public.taxpayers t
    where t.organization_id = v_organization_id and lower(t.legal_name) = lower(v_name) and t.phone = v_phone
      and t.id is distinct from p_taxpayer_id
  ) then
    raise exception using errcode = '23505', message = 'A taxpayer with this name and phone already exists';
  end if;

  if v_taxpayer_id is null then
    insert into public.taxpayers (
      organization_id, zone_id, taxpayer_kind, legal_name, first_name, last_name,
      taxpayer_number, phone, email, address, is_active
    ) values (
      v_organization_id, p_zone_id, p_kind, v_name, v_first, v_last,
      v_number, v_phone, nullif(btrim(p_email), ''), nullif(btrim(p_address), ''), coalesce(p_is_active, true)
    ) returning id into v_taxpayer_id;
  else
    update public.taxpayers
    set zone_id = p_zone_id, taxpayer_kind = p_kind, legal_name = v_name, first_name = v_first, last_name = v_last,
        taxpayer_number = v_number, phone = v_phone, email = nullif(btrim(p_email), ''),
        address = nullif(btrim(p_address), ''), is_active = coalesce(p_is_active, is_active)
    where id = v_taxpayer_id and organization_id = v_organization_id;
    if not found then
      raise exception using errcode = 'P0002', message = 'Taxpayer not found in this organization';
    end if;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), case when p_taxpayer_id is null then 'taxpayer.created' else 'taxpayer.updated' end,
    'taxpayers', v_taxpayer_id, jsonb_build_object('taxpayer_number', v_number));
  return v_taxpayer_id;
end;
$$;

create function public.save_establishment(
  p_establishment_id uuid,
  p_taxpayer_id uuid,
  p_zone_id uuid,
  p_name text,
  p_address text default null,
  p_is_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid := public.require_manager_organization('directory.manage');
  v_establishment_id uuid := p_establishment_id;
begin
  -- Clés composites : contribuable et zone doivent appartenir à la même organisation.
  if v_establishment_id is null then
    insert into public.establishments (organization_id, taxpayer_id, zone_id, name, address, is_active)
    values (v_organization_id, p_taxpayer_id, p_zone_id, btrim(p_name), nullif(btrim(p_address), ''), coalesce(p_is_active, true))
    returning id into v_establishment_id;
  else
    update public.establishments
    set zone_id = p_zone_id, name = btrim(p_name), address = nullif(btrim(p_address), ''), is_active = coalesce(p_is_active, is_active)
    where id = v_establishment_id and organization_id = v_organization_id and taxpayer_id = p_taxpayer_id;
    if not found then
      raise exception using errcode = 'P0002', message = 'Establishment not found in this organization';
    end if;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), case when p_establishment_id is null then 'establishment.created' else 'establishment.updated' end,
    'establishments', v_establishment_id, jsonb_build_object('taxpayer_id', p_taxpayer_id));
  return v_establishment_id;
end;
$$;

-- ── Droits d'exécution ──────────────────────────────────────────────────────

revoke all on function public.caller_organization() from public, anon, authenticated;
revoke all on function public.require_manager_organization(text) from public, anon, authenticated;
revoke all on function public.attach_account_to_organization(text, text, text) from public, anon;
revoke all on function public.revoke_member_role(uuid, text) from public, anon;
revoke all on function public.set_member_status(uuid, text) from public, anon;
revoke all on function public.register_created_member(uuid, uuid, text, text) from public, anon, authenticated;
revoke all on function public.save_zone(uuid, text, text, boolean) from public, anon;
revoke all on function public.save_taxpayer(uuid, uuid, public.taxpayer_kind, text, text, text, text, text, text, text, boolean) from public, anon;
revoke all on function public.save_establishment(uuid, uuid, uuid, text, text, boolean) from public, anon;

grant execute on function public.attach_account_to_organization(text, text, text) to authenticated;
grant execute on function public.revoke_member_role(uuid, text) to authenticated;
grant execute on function public.set_member_status(uuid, text) to authenticated;
grant execute on function public.register_created_member(uuid, uuid, text, text) to service_role;
grant execute on function public.save_zone(uuid, text, text, boolean) to authenticated;
grant execute on function public.save_taxpayer(uuid, uuid, public.taxpayer_kind, text, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.save_establishment(uuid, uuid, uuid, text, text, boolean) to authenticated;
