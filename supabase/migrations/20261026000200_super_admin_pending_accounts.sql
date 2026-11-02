-- Comptes en attente visibles et activables par le Super-Admin.
-- Source de travail : Terenza Admin. Tests pgTAP : tests/super_admin_pending_accounts.test.sql.
--
-- Constat : un compte créé sans demande d'inscription (avant 20261025000100, ou si le
-- demandeur n'a pas terminé) est `pending` sans organisation. La politique
-- profiles_read_scoped le rend illisible, même pour le Super-Admin, qui ne peut donc
-- ni le voir ni l'activer.
--
-- Ajout, sans modifier aucune politique ni aucune table :
--   list_pending_accounts()            lecture réservée au Super-Admin (nom, email, confirmation).
--   create_organization_for_account()  le Super-Admin crée l'organisation d'un compte en
--                                      attente confirmé et le nomme administrateur, en une
--                                      transaction journalisée (comme une approbation).
-- Application mobile : non concernée (aucun objet existant modifié).

create function public.list_pending_accounts()
returns table (
  user_id uuid,
  display_name text,
  email text,
  email_confirmed_at timestamptz,
  created_at timestamptz,
  pending_request_id uuid
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not public.has_role(null, 'super_admin') then
    raise exception using errcode = '42501', message = 'Only a super administrator can list pending accounts';
  end if;

  return query
  select
    p.id,
    p.display_name,
    u.email::text,
    u.email_confirmed_at,
    p.created_at,
    (select r.id from public.organization_registration_requests r
      where r.requested_by = p.id and r.status = 'pending')
  from public.profiles p
  join auth.users u on u.id = p.id
  where p.status = 'pending' and p.organization_id is null
  order by p.created_at desc
  limit 500;
end;
$$;

create function public.create_organization_for_account(
  p_user_id uuid,
  p_organization_name text,
  p_organization_code text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := lower(btrim(coalesce(p_organization_code, '')));
  v_name text := btrim(coalesce(p_organization_name, ''));
  v_organization_id uuid;
  v_role_id uuid;
begin
  if not public.has_role(null, 'super_admin') then
    raise exception using errcode = '42501', message = 'Only a super administrator can create an organization for an account';
  end if;
  if p_user_id = auth.uid() then
    raise exception using errcode = '42501', message = 'A super administrator cannot target their own account';
  end if;

  -- Le compte doit être resté en attente, sans organisation.
  perform 1 from public.profiles p
  where p.id = p_user_id and p.status = 'pending' and p.organization_id is null
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'Account is not pending without organization';
  end if;

  if not exists (select 1 from auth.users u where u.id = p_user_id and u.email_confirmed_at is not null) then
    raise exception using errcode = '22023', message = 'Account email is not confirmed';
  end if;

  -- Une demande en cours se traite par approve_organization_registration (nom et code choisis par le demandeur).
  if exists (
    select 1 from public.organization_registration_requests r
    where r.requested_by = p_user_id and r.status = 'pending'
  ) then
    raise exception using errcode = '22023', message = 'Account has a pending registration request: approve it instead';
  end if;

  if exists (select 1 from public.organizations o where o.code = v_code) then
    raise exception using errcode = '23505', message = 'Organization code already taken';
  end if;

  insert into public.organizations (name, code, created_by)
  values (v_name, v_code, p_user_id)
  returning id into v_organization_id;

  update public.profiles
  set organization_id = v_organization_id, status = 'active', updated_at = now()
  where id = p_user_id;

  insert into public.user_roles (organization_id, user_id, role_key, assigned_by)
  values (v_organization_id, p_user_id, 'admin', auth.uid())
  returning id into v_role_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values
    (v_organization_id, auth.uid(), 'organization.created_for_account', 'organizations', v_organization_id,
      jsonb_build_object('account_id', p_user_id, 'organization_code', v_code)),
    (v_organization_id, auth.uid(), 'role.assigned', 'user_roles', v_role_id,
      jsonb_build_object('target_user_id', p_user_id, 'role_key', 'admin'));

  return v_organization_id;
end;
$$;

revoke all on function public.list_pending_accounts() from public, anon;
revoke all on function public.create_organization_for_account(uuid, text, text) from public, anon;
grant execute on function public.list_pending_accounts() to authenticated;
grant execute on function public.create_organization_for_account(uuid, text, text) to authenticated;
