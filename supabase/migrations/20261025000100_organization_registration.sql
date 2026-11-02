-- Inscription des organisations (demandes, approbation et refus par le Super-Admin).
-- Source de travail : Terenza Admin, supabase-proposals/. Tests pgTAP : tests/organization_registration.test.sql.
--
-- Prérequis : 20261021000100 (organizations, profiles, user_roles, trigger
-- handle_new_auth_user), 20261021000400 (has_role).
--
-- Parcours :
--   1. Le demandeur crée un compte Auth : profil `pending`, sans organisation.
--      Il confirme son adresse (lien ou code reçu par email).
--   2. Il dépose une demande (submit_organization_registration), idempotente.
--   3. Le Super-Admin l'approuve (crée l'organisation, active le demandeur,
--      lui attribue le rôle admin, en une transaction) ou la refuse avec motif.
-- Aucune table existante n'est modifiée ; aucune donnée n'est supprimée.

create type public.organization_registration_status as enum ('pending', 'approved', 'rejected', 'cancelled');

create table public.organization_registration_requests (
  id uuid primary key default gen_random_uuid(),
  requested_by uuid not null references public.profiles(id) on delete restrict,
  organization_name text not null check (length(btrim(organization_name)) between 2 and 160),
  organization_code text not null check (organization_code ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  contact_phone text check (contact_phone is null or length(btrim(contact_phone)) between 6 and 30),
  message text check (message is null or length(message) <= 1000),
  status public.organization_registration_status not null default 'pending',
  decided_by uuid references public.profiles(id) on delete set null,
  decided_at timestamptz,
  decision_reason text,
  organization_id uuid references public.organizations(id) on delete restrict,
  created_at timestamptz not null default now(),
  check (
    (status = 'pending' and decided_at is null and decided_by is null and organization_id is null)
    or (status = 'cancelled' and decided_at is not null and organization_id is null)
    or (status = 'approved' and decided_at is not null and decided_by is not null and organization_id is not null)
    or (status = 'rejected' and decided_at is not null and decided_by is not null and organization_id is null
      and length(btrim(coalesce(decision_reason, ''))) >= 5)
  )
);

-- Une seule demande en cours par compte, et un code réservé par une seule demande en cours.
create unique index organization_registration_one_pending_per_user_idx
  on public.organization_registration_requests (requested_by) where status = 'pending';
create unique index organization_registration_pending_code_idx
  on public.organization_registration_requests (organization_code) where status = 'pending';
create index organization_registration_status_time_idx
  on public.organization_registration_requests (status, created_at desc);

revoke all on public.organization_registration_requests from public, anon, authenticated;
grant select on public.organization_registration_requests to authenticated;
alter table public.organization_registration_requests enable row level security;

create policy organization_registration_read_scoped on public.organization_registration_requests
  for select to authenticated using (
    requested_by = auth.uid() or public.has_role(null, 'super_admin')
  );

-- ── Dépôt par le demandeur ──────────────────────────────────────────────────

create function public.submit_organization_registration(
  p_organization_name text,
  p_organization_code text,
  p_contact_phone text default null,
  p_message text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_code text := lower(btrim(coalesce(p_organization_code, '')));
  v_request_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;

  -- Seul un compte en attente, non rattaché, peut demander une organisation.
  if not exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.status = 'pending' and p.organization_id is null
  ) then
    raise exception using errcode = '42501', message = 'Only a pending account without organization can register one';
  end if;

  -- Le compte Auth seul ne suffit pas : l'adresse doit être confirmée.
  if not exists (select 1 from auth.users u where u.id = auth.uid() and u.email_confirmed_at is not null) then
    raise exception using errcode = '42501', message = 'Email address must be confirmed before registering an organization';
  end if;

  -- Idempotence : un nouvel envoi de la même demande (double clic, nouvelle tentative
  -- après une coupure réseau) renvoie la demande en cours au lieu d'en créer une autre.
  select r.id into v_request_id
  from public.organization_registration_requests r
  where r.requested_by = auth.uid() and r.status = 'pending' and r.organization_code = v_code;
  if found then
    return v_request_id;
  end if;

  if exists (select 1 from public.organizations o where o.code = v_code) then
    raise exception using errcode = '23505', message = 'Organization code already taken';
  end if;

  begin
    insert into public.organization_registration_requests (
      requested_by, organization_name, organization_code, contact_phone, message
    ) values (
      auth.uid(), btrim(p_organization_name), v_code,
      nullif(btrim(p_contact_phone), ''), nullif(btrim(p_message), '')
    ) returning id into v_request_id;
  exception when unique_violation then
    raise exception using errcode = '23505', message = 'A pending request already exists for this account or code';
  end;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (null, auth.uid(), 'organization.registration_submitted', 'organization_registration_requests', v_request_id,
    jsonb_build_object('organization_code', v_code));

  return v_request_id;
end;
$$;

create function public.cancel_organization_registration(p_request_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.organization_registration_requests r
  set status = 'cancelled', decided_at = now()
  where r.id = p_request_id and r.requested_by = auth.uid() and r.status = 'pending';

  if not found then
    raise exception using errcode = '42501', message = 'Pending request not found for this account';
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id)
  values (null, auth.uid(), 'organization.registration_cancelled', 'organization_registration_requests', p_request_id);
end;
$$;

-- ── Décision du Super-Admin ─────────────────────────────────────────────────

create function public.approve_organization_registration(p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.organization_registration_requests%rowtype;
  v_organization_id uuid;
  v_role_id uuid;
begin
  if not public.has_role(null, 'super_admin') then
    raise exception using errcode = '42501', message = 'Only a super administrator can approve a registration';
  end if;

  select * into v_request
  from public.organization_registration_requests r
  where r.id = p_request_id
  for update;

  if not found or v_request.status <> 'pending' then
    raise exception using errcode = '22023', message = 'Pending registration request not found';
  end if;

  -- Le demandeur doit être resté en attente et sans organisation.
  perform 1 from public.profiles p
  where p.id = v_request.requested_by and p.status = 'pending' and p.organization_id is null
  for update;
  if not found then
    raise exception using errcode = '22023', message = 'Requester is no longer eligible';
  end if;

  if exists (select 1 from public.organizations o where o.code = v_request.organization_code) then
    raise exception using errcode = '23505', message = 'Organization code already taken';
  end if;

  insert into public.organizations (name, code, created_by)
  values (v_request.organization_name, v_request.organization_code, v_request.requested_by)
  returning id into v_organization_id;

  update public.profiles
  set organization_id = v_organization_id, status = 'active', updated_at = now()
  where id = v_request.requested_by;

  insert into public.user_roles (organization_id, user_id, role_key, assigned_by)
  values (v_organization_id, v_request.requested_by, 'admin', auth.uid())
  returning id into v_role_id;

  update public.organization_registration_requests
  set status = 'approved', decided_by = auth.uid(), decided_at = now(), organization_id = v_organization_id
  where id = v_request.id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values
    (v_organization_id, auth.uid(), 'organization.registration_approved', 'organizations', v_organization_id,
      jsonb_build_object('request_id', v_request.id, 'requested_by', v_request.requested_by)),
    (v_organization_id, auth.uid(), 'role.assigned', 'user_roles', v_role_id,
      jsonb_build_object('target_user_id', v_request.requested_by, 'role_key', 'admin'));

  return v_organization_id;
end;
$$;

create function public.reject_organization_registration(p_request_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_role(null, 'super_admin') then
    raise exception using errcode = '42501', message = 'Only a super administrator can reject a registration';
  end if;
  if p_reason is null or length(btrim(p_reason)) < 5 then
    raise exception using errcode = '22023', message = 'A reason of at least five characters is required';
  end if;

  update public.organization_registration_requests r
  set status = 'rejected', decided_by = auth.uid(), decided_at = now(), decision_reason = btrim(p_reason)
  where r.id = p_request_id and r.status = 'pending';

  if not found then
    raise exception using errcode = '22023', message = 'Pending registration request not found';
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (null, auth.uid(), 'organization.registration_rejected', 'organization_registration_requests', p_request_id,
    jsonb_build_object('reason', btrim(p_reason)));
end;
$$;

revoke all on function public.submit_organization_registration(text, text, text, text) from public, anon;
revoke all on function public.cancel_organization_registration(uuid) from public, anon;
revoke all on function public.approve_organization_registration(uuid) from public, anon;
revoke all on function public.reject_organization_registration(uuid, text) from public, anon;
grant execute on function public.submit_organization_registration(text, text, text, text) to authenticated;
grant execute on function public.cancel_organization_registration(uuid) to authenticated;
grant execute on function public.approve_organization_registration(uuid) to authenticated;
grant execute on function public.reject_organization_registration(uuid, text) to authenticated;
