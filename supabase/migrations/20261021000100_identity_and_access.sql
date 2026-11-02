create type public.profile_status as enum ('pending', 'active', 'suspended', 'disabled');

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 2 and 160),
  code text not null unique check (code ~ '^[a-z0-9][a-z0-9-]{1,39}$'),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  organization_id uuid references public.organizations(id) on delete restrict,
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  phone text,
  status public.profile_status not null default 'pending',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, organization_id)
);

create table public.roles (
  key text primary key check (key ~ '^[a-z][a-z0-9_]*$'),
  label text not null,
  is_global boolean not null default false
);

create table public.permissions (
  key text primary key check (key ~ '^[a-z][a-z0-9_.]*$'),
  description text not null
);

create table public.role_permissions (
  role_key text not null references public.roles(key) on delete restrict,
  permission_key text not null references public.permissions(key) on delete restrict,
  primary key (role_key, permission_key)
);

create table public.user_roles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id) on delete restrict,
  user_id uuid not null references public.profiles(id) on delete restrict,
  role_key text not null references public.roles(key) on delete restrict,
  assigned_by uuid references public.profiles(id) on delete set null,
  assigned_at timestamptz not null default now(),
  check ((role_key = 'super_admin' and organization_id is null)
    or (role_key <> 'super_admin' and organization_id is not null))
);

create unique index user_roles_scope_user_role_idx
  on public.user_roles (
    coalesce(organization_id, '00000000-0000-0000-0000-000000000000'::uuid),
    user_id,
    role_key
  );

insert into public.roles (key, label, is_global) values
  ('super_admin', 'Super administrateur', true),
  ('admin', 'Administrateur', false),
  ('supervisor', 'Superviseur', false),
  ('collector', 'Collecteur', false),
  ('cashier', 'Caissier', false),
  ('auditor', 'Auditeur', false),
  ('direction', 'Direction', false);

insert into public.permissions (key, description) values
  ('directory.read_all', 'Lire le répertoire de l’organisation'),
  ('zone.supervise', 'Lire les zones supervisées'),
  ('mission.read_all', 'Lire les missions de l’organisation'),
  ('mission.assign', 'Affecter les missions'),
  ('collection.read_all', 'Lire les collectes de l’organisation'),
  ('payment.record', 'Enregistrer une demande de paiement'),
  ('cash.read', 'Lire les opérations de caisse autorisées'),
  ('cash.manage', 'Gérer les opérations de caisse'),
  ('finance.read', 'Lire les données financières'),
  ('audit.read', 'Lire les journaux d’audit'),
  ('profile.manage', 'Gérer les profils de l’organisation'),
  ('role.assign', 'Attribuer les rôles autorisés'),
  ('receipt.void', 'Annuler un reçu avec motif');

insert into public.role_permissions (role_key, permission_key)
select 'admin', key from public.permissions;

insert into public.role_permissions (role_key, permission_key) values
  ('supervisor', 'zone.supervise'),
  ('supervisor', 'mission.assign'),
  ('collector', 'payment.record'),
  ('cashier', 'payment.record'),
  ('cashier', 'cash.read'),
  ('cashier', 'cash.manage'),
  ('auditor', 'directory.read_all'),
  ('auditor', 'mission.read_all'),
  ('auditor', 'collection.read_all'),
  ('auditor', 'cash.read'),
  ('auditor', 'finance.read'),
  ('auditor', 'audit.read'),
  ('direction', 'directory.read_all'),
  ('direction', 'mission.read_all'),
  ('direction', 'collection.read_all'),
  ('direction', 'cash.read'),
  ('direction', 'finance.read');

create function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, status)
  values (
    new.id,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''),
      nullif(split_part(coalesce(new.email, ''), '@', 1), ''),
      'Utilisateur'
    ),
    'pending'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

revoke all on function public.handle_new_auth_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_auth_user();