create type public.mission_status as enum ('draft', 'assigned', 'in_progress', 'completed', 'cancelled');
create type public.appointment_status as enum ('scheduled', 'completed', 'missed', 'cancelled');
create type public.collection_status as enum ('draft', 'submitted', 'validated', 'rejected', 'cancelled');

create table public.zones (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  parent_zone_id uuid,
  supervisor_id uuid,
  name text not null check (length(btrim(name)) between 1 and 120),
  code text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, code),
  unique (id, organization_id),
  foreign key (parent_zone_id, organization_id)
    references public.zones(id, organization_id) on delete restrict,
  foreign key (supervisor_id, organization_id)
    references public.profiles(id, organization_id) on delete restrict
);

create table public.taxpayers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  zone_id uuid not null,
  taxpayer_number text,
  legal_name text not null check (length(btrim(legal_name)) between 1 and 200),
  phone text,
  email text,
  address text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (zone_id, organization_id)
    references public.zones(id, organization_id) on delete restrict
);

create unique index taxpayers_org_number_idx
  on public.taxpayers (organization_id, taxpayer_number)
  where taxpayer_number is not null;

create table public.activity_types (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code text not null,
  label text not null,
  is_active boolean not null default true,
  unique (organization_id, code),
  unique (id, organization_id)
);

create table public.establishments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  taxpayer_id uuid not null,
  zone_id uuid not null,
  activity_type_id uuid,
  name text not null check (length(btrim(name)) between 1 and 200),
  address text,
  latitude numeric(9, 6),
  longitude numeric(9, 6),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (id, organization_id),
  unique (id, organization_id, taxpayer_id),
  foreign key (taxpayer_id, organization_id)
    references public.taxpayers(id, organization_id) on delete restrict,
  foreign key (zone_id, organization_id)
    references public.zones(id, organization_id) on delete restrict,
  foreign key (activity_type_id, organization_id)
    references public.activity_types(id, organization_id) on delete restrict,
  check (latitude is null or latitude between -90 and 90),
  check (longitude is null or longitude between -180 and 180)
);

create table public.tax_types (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code text not null,
  label text not null,
  currency_code text not null default 'XOF' check (currency_code = 'XOF'),
  is_active boolean not null default true,
  unique (organization_id, code),
  unique (id, organization_id)
);

create table public.financial_obligations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  taxpayer_id uuid not null,
  establishment_id uuid not null,
  tax_type_id uuid not null,
  period_start date not null,
  period_end date not null,
  due_date date not null,
  amount_due numeric(14, 0) not null check (amount_due > 0),
  amount_paid numeric(14, 0) not null default 0 check (amount_paid >= 0),
  currency_code text not null default 'XOF' check (currency_code = 'XOF'),
  status text not null default 'open' check (status in ('open', 'partial', 'paid', 'cancelled')),
  created_at timestamptz not null default now(),
  unique (id, organization_id),
  check (period_end >= period_start),
  check (amount_paid <= amount_due),
  foreign key (taxpayer_id, organization_id)
    references public.taxpayers(id, organization_id) on delete restrict,
  foreign key (establishment_id, organization_id, taxpayer_id)
    references public.establishments(id, organization_id, taxpayer_id) on delete restrict,
  foreign key (tax_type_id, organization_id)
    references public.tax_types(id, organization_id) on delete restrict
);

create unique index financial_obligations_period_idx
  on public.financial_obligations (organization_id, establishment_id, tax_type_id, period_start, period_end);
create index financial_obligations_due_idx
  on public.financial_obligations (organization_id, establishment_id, status, due_date);

create table public.missions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  zone_id uuid not null,
  title text not null check (length(btrim(title)) between 1 and 160),
  scheduled_for date not null,
  status public.mission_status not null default 'draft',
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (zone_id, organization_id)
    references public.zones(id, organization_id) on delete restrict,
  foreign key (created_by, organization_id)
    references public.profiles(id, organization_id) on delete restrict
);

create table public.mission_assignments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  mission_id uuid not null,
  user_id uuid not null,
  assigned_by uuid,
  assigned_at timestamptz not null default now(),
  unique (mission_id, user_id),
  unique (id, organization_id),
  foreign key (mission_id, organization_id)
    references public.missions(id, organization_id) on delete restrict,
  foreign key (user_id, organization_id)
    references public.profiles(id, organization_id) on delete restrict,
  foreign key (assigned_by, organization_id)
    references public.profiles(id, organization_id) on delete restrict
);

create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  establishment_id uuid not null,
  assigned_to uuid,
  starts_at timestamptz not null,
  status public.appointment_status not null default 'scheduled',
  notes text,
  created_at timestamptz not null default now(),
  foreign key (establishment_id, organization_id)
    references public.establishments(id, organization_id) on delete restrict,
  foreign key (assigned_to, organization_id)
    references public.profiles(id, organization_id) on delete restrict
);

create table public.collections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  mission_assignment_id uuid,
  establishment_id uuid not null,
  collector_id uuid not null,
  visited_at timestamptz not null default now(),
  outcome text not null check (outcome in ('contacted', 'unavailable', 'refused', 'follow_up')),
  notes text,
  status public.collection_status not null default 'draft',
  created_at timestamptz not null default now(),
  unique (id, organization_id),
  foreign key (establishment_id, organization_id)
    references public.establishments(id, organization_id) on delete restrict,
  foreign key (mission_assignment_id, organization_id)
    references public.mission_assignments(id, organization_id) on delete restrict,
  foreign key (collector_id, organization_id)
    references public.profiles(id, organization_id) on delete restrict
);

create table public.collection_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  collection_id uuid not null,
  obligation_id uuid not null,
  amount_due_snapshot numeric(14, 0) not null check (amount_due_snapshot > 0),
  currency_code text not null default 'XOF' check (currency_code = 'XOF'),
  notes text,
  created_at timestamptz not null default now(),
  unique (collection_id, obligation_id),
  unique (id, collection_id, organization_id),
  foreign key (collection_id, organization_id)
    references public.collections(id, organization_id) on delete restrict,
  foreign key (obligation_id, organization_id)
    references public.financial_obligations(id, organization_id) on delete restrict
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  recipient_id uuid not null,
  title text not null check (length(btrim(title)) between 1 and 160),
  body text not null check (length(btrim(body)) between 1 and 2000),
  read_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (recipient_id, organization_id)
    references public.profiles(id, organization_id) on delete cascade
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  organization_id uuid references public.organizations(id) on delete restrict,
  actor_id uuid references public.profiles(id) on delete set null,
  action text not null,
  entity_table text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index zones_org_supervisor_idx on public.zones (organization_id, supervisor_id);
create index taxpayers_org_zone_idx on public.taxpayers (organization_id, zone_id);
create index establishments_org_zone_idx on public.establishments (organization_id, zone_id);
create index establishments_taxpayer_idx on public.establishments (organization_id, taxpayer_id);
create index missions_org_zone_date_idx on public.missions (organization_id, zone_id, scheduled_for);
create index mission_assignments_user_idx on public.mission_assignments (organization_id, user_id);
create index appointments_assignee_time_idx on public.appointments (organization_id, assigned_to, starts_at);
create index collections_collector_time_idx on public.collections (organization_id, collector_id, visited_at desc);
create index collection_items_obligation_idx on public.collection_items (organization_id, obligation_id);
create index notifications_recipient_unread_idx
  on public.notifications (recipient_id, created_at desc) where read_at is null;
create index audit_logs_org_time_idx on public.audit_logs (organization_id, created_at desc);