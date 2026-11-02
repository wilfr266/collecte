create type public.taxpayer_kind as enum ('individual', 'business', 'unspecified');

alter table public.taxpayers
  add column taxpayer_kind public.taxpayer_kind not null default 'unspecified',
  add column first_name text,
  add column last_name text,
  add constraint taxpayers_individual_name_check check (
    taxpayer_kind <> 'individual'
    or (
      first_name is not null and length(btrim(first_name)) > 0
      and last_name is not null and length(btrim(last_name)) > 0
    )
  );

comment on column public.taxpayers.taxpayer_kind is
  'individual/business for classified taxpayers; unspecified preserves historical rows until reviewed';