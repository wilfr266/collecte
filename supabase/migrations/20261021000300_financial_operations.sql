create type public.payment_status as enum ('pending', 'confirmed', 'failed', 'reversed');
create type public.receipt_status as enum ('issued', 'voided');
create type public.cash_register_status as enum ('open', 'closed');
create type public.cash_movement_type as enum ('opening', 'collection', 'disbursement', 'adjustment', 'reversal');
create type public.cash_reconciliation_status as enum ('draft', 'submitted', 'approved', 'rejected');

create table public.cash_registers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code text not null,
  label text not null,
  assigned_cashier_id uuid,
  status public.cash_register_status not null default 'closed',
  opened_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, code),
  unique (id, organization_id),
  foreign key (assigned_cashier_id, organization_id)
    references public.profiles(id, organization_id) on delete restrict,
  check (status = 'closed' or (opened_at is not null and closed_at is null))
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  collection_id uuid not null,
  collection_item_id uuid not null,
  cash_register_id uuid,
  amount numeric(14, 0) not null check (amount > 0),
  currency_code text not null default 'XOF' check (currency_code = 'XOF'),
  method text not null check (method in ('cash', 'mobile_money', 'bank_transfer', 'card', 'other')),
  provider text,
  provider_reference text,
  idempotency_key text not null check (length(idempotency_key) between 8 and 128),
  status public.payment_status not null default 'pending',
  recorded_by uuid not null,
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (organization_id, idempotency_key),
  unique (id, organization_id),
  foreign key (collection_id, organization_id)
    references public.collections(id, organization_id) on delete restrict,
  foreign key (collection_item_id, collection_id, organization_id)
    references public.collection_items(id, collection_id, organization_id) on delete restrict,
  foreign key (cash_register_id, organization_id)
    references public.cash_registers(id, organization_id) on delete restrict,
  foreign key (recorded_by, organization_id)
    references public.profiles(id, organization_id) on delete restrict,
  check ((status = 'confirmed' and confirmed_at is not null)
    or (status <> 'confirmed' and confirmed_at is null))
);

create unique index payments_provider_reference_idx
  on public.payments (organization_id, provider, provider_reference)
  where provider_reference is not null;
create index payments_collection_time_idx
  on public.payments (organization_id, collection_id, created_at desc);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  payment_id uuid not null unique,
  receipt_number text not null,
  status public.receipt_status not null default 'issued',
  issued_at timestamptz not null default now(),
  voided_at timestamptz,
  void_reason text,
  unique (organization_id, receipt_number),
  foreign key (payment_id, organization_id)
    references public.payments(id, organization_id) on delete restrict,
  check ((status = 'issued' and voided_at is null and void_reason is null)
    or (status = 'voided' and voided_at is not null and void_reason is not null
      and length(btrim(void_reason)) > 0))
);

create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  cash_register_id uuid not null,
  payment_id uuid,
  movement_type public.cash_movement_type not null,
  amount numeric(14, 0) not null check (amount > 0),
  currency_code text not null default 'XOF' check (currency_code = 'XOF'),
  idempotency_key text not null,
  reference text,
  actor_id uuid,
  reverses_movement_id uuid,
  created_at timestamptz not null default now(),
  unique (organization_id, idempotency_key),
  unique (id, organization_id),
  foreign key (cash_register_id, organization_id)
    references public.cash_registers(id, organization_id) on delete restrict,
  foreign key (payment_id, organization_id)
    references public.payments(id, organization_id) on delete restrict,
  foreign key (actor_id, organization_id)
    references public.profiles(id, organization_id) on delete restrict,
  foreign key (reverses_movement_id, organization_id)
    references public.cash_movements(id, organization_id) on delete restrict
);

create unique index cash_movements_single_reversal_idx
  on public.cash_movements (reverses_movement_id)
  where reverses_movement_id is not null;
create index cash_movements_register_time_idx
  on public.cash_movements (organization_id, cash_register_id, created_at desc);

create table public.cash_reconciliations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  cash_register_id uuid not null,
  expected_amount numeric(14, 0) not null check (expected_amount >= 0),
  counted_amount numeric(14, 0) not null check (counted_amount >= 0),
  difference_amount numeric(14, 0) generated always as (counted_amount - expected_amount) stored,
  status public.cash_reconciliation_status not null default 'draft',
  prepared_by uuid not null,
  reviewed_by uuid,
  notes text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  foreign key (cash_register_id, organization_id)
    references public.cash_registers(id, organization_id) on delete restrict,
  foreign key (prepared_by, organization_id)
    references public.profiles(id, organization_id) on delete restrict,
  foreign key (reviewed_by, organization_id)
    references public.profiles(id, organization_id) on delete restrict,
  check ((status in ('draft', 'submitted') and reviewed_at is null)
    or (status in ('approved', 'rejected') and reviewed_at is not null))
);