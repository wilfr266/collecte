-- Rôle « client » : un contribuable consulte ses propres obligations et reçus.
--
-- Prérequis : 20261023000100 (colonnes payments.failure_reason et
-- status_changed_at lues par client_payments).
--
-- Le rôle (user_roles) dit ce que le compte peut faire ; le statut
-- (profiles.status) reste vérifié par has_role pour chaque accès.
-- Un compte client ne voit que les contribuables auxquels un administrateur
-- l'a explicitement rattaché via link_client_taxpayer.

insert into public.roles (key, label, is_global) values
  ('client', 'Client', false)
on conflict (key) do nothing;

create table public.client_taxpayer_links (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null,
  taxpayer_id uuid not null,
  linked_by uuid references public.profiles(id) on delete set null,
  linked_at timestamptz not null default now(),
  unique (organization_id, user_id, taxpayer_id),
  foreign key (user_id, organization_id)
    references public.profiles(id, organization_id) on delete restrict,
  foreign key (taxpayer_id, organization_id)
    references public.taxpayers(id, organization_id) on delete restrict
);

create index client_taxpayer_links_user_idx
  on public.client_taxpayer_links (organization_id, user_id);

create function public.is_taxpayer_client(p_organization_id uuid, p_taxpayer_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.has_role(p_organization_id, 'client') and exists (
    select 1
    from public.client_taxpayer_links l
    where l.organization_id = p_organization_id
      and l.taxpayer_id = p_taxpayer_id
      and l.user_id = auth.uid()
  );
$$;

revoke all on function public.is_taxpayer_client(uuid, uuid) from public, anon;
grant execute on function public.is_taxpayer_client(uuid, uuid) to authenticated;

-- ── Privilèges et RLS ───────────────────────────────────────────────────────

revoke all on public.client_taxpayer_links from public, anon, authenticated;
grant select on public.client_taxpayer_links to authenticated;
alter table public.client_taxpayer_links enable row level security;

create policy client_taxpayer_links_read_scoped on public.client_taxpayer_links
  for select to authenticated using (
    (user_id = auth.uid() and public.has_role(organization_id, 'client'))
    or public.has_permission(organization_id, 'profile.manage')
  );

-- Politiques permissives supplémentaires : elles s'ajoutent (OR) aux
-- politiques existantes sans élargir les accès des autres rôles.
create policy taxpayers_read_client on public.taxpayers
  for select to authenticated using (public.is_taxpayer_client(organization_id, id));

create policy establishments_read_client on public.establishments
  for select to authenticated using (public.is_taxpayer_client(organization_id, taxpayer_id));

create policy financial_obligations_read_client on public.financial_obligations
  for select to authenticated using (public.is_taxpayer_client(organization_id, taxpayer_id));

-- Historique des paiements du client via une RPC dédiée : ouvrir
-- collections/payments en lecture directe exposerait les notes de visite et
-- les identifiants des collecteurs. Tous les statuts sont renvoyés pour que
-- le client suive ses transactions ; seul un paiement `confirmed` porte un
-- reçu et réduit le solde de l'obligation.
create function public.client_payments(p_limit integer default 50)
returns table (
  payment_id uuid,
  payment_status public.payment_status,
  failure_reason text,
  status_changed_at timestamptz,
  amount numeric,
  currency_code text,
  method text,
  provider text,
  provider_reference text,
  created_at timestamptz,
  confirmed_at timestamptz,
  taxpayer_id uuid,
  establishment_name text,
  obligation_id uuid,
  tax_type_label text,
  receipt_number text,
  receipt_status public.receipt_status
)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.status, p.failure_reason, p.status_changed_at, p.amount, p.currency_code, p.method, p.provider,
    p.provider_reference, p.created_at, p.confirmed_at, e.taxpayer_id, e.name,
    ci.obligation_id, tt.label, r.receipt_number, r.status
  from public.client_taxpayer_links l
  join public.establishments e
    on e.taxpayer_id = l.taxpayer_id and e.organization_id = l.organization_id
  join public.collections c
    on c.establishment_id = e.id and c.organization_id = e.organization_id
  join public.payments p
    on p.collection_id = c.id and p.organization_id = c.organization_id
  join public.collection_items ci
    on ci.id = p.collection_item_id and ci.organization_id = p.organization_id
  -- L'obligation doit appartenir au même contribuable et au même
  -- établissement que le lien : le schéma ne l'impose pas sur
  -- collection_items, seules les RPC d'écriture le vérifient.
  join public.financial_obligations fo
    on fo.id = ci.obligation_id and fo.organization_id = ci.organization_id
      and fo.taxpayer_id = l.taxpayer_id and fo.establishment_id = e.id
  join public.tax_types tt
    on tt.id = fo.tax_type_id and tt.organization_id = fo.organization_id
  left join public.receipts r
    on r.payment_id = p.id and r.organization_id = p.organization_id
  where l.user_id = auth.uid()
    and public.has_role(l.organization_id, 'client')
  order by p.created_at desc
  limit least(greatest(coalesce(p_limit, 50), 1), 200);
$$;

revoke all on function public.client_payments(integer) from public, anon;
grant execute on function public.client_payments(integer) to authenticated;

-- ── RPC de rattachement ─────────────────────────────────────────────────────

create function public.link_client_taxpayer(p_user_id uuid, p_taxpayer_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_link_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;

  select t.organization_id into v_organization_id
  from public.taxpayers t
  where t.id = p_taxpayer_id;

  if v_organization_id is null
    or not public.has_permission(v_organization_id, 'profile.manage') then
    raise exception using errcode = '42501', message = 'Missing profile.manage permission';
  end if;

  if not exists (
    select 1
    from public.profiles p
    join public.user_roles ur
      on ur.user_id = p.id and ur.organization_id = p.organization_id
    where p.id = p_user_id
      and p.status = 'active'
      and p.organization_id = v_organization_id
      and ur.role_key = 'client'
  ) then
    raise exception using errcode = '22023', message = 'Target profile is not an active client of this organization';
  end if;

  insert into public.client_taxpayer_links (organization_id, user_id, taxpayer_id, linked_by)
  values (v_organization_id, p_user_id, p_taxpayer_id, auth.uid())
  on conflict do nothing
  returning id into v_link_id;

  if v_link_id is null then
    select l.id into v_link_id
    from public.client_taxpayer_links l
    where l.organization_id = v_organization_id
      and l.user_id = p_user_id
      and l.taxpayer_id = p_taxpayer_id;
  end if;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_organization_id, auth.uid(), 'client.linked', 'client_taxpayer_links', v_link_id,
    jsonb_build_object('target_user_id', p_user_id, 'taxpayer_id', p_taxpayer_id));

  return v_link_id;
end;
$$;

create function public.unlink_client_taxpayer(p_link_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_link public.client_taxpayer_links%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required';
  end if;

  select * into v_link from public.client_taxpayer_links where id = p_link_id;

  if v_link.id is null
    or not public.has_permission(v_link.organization_id, 'profile.manage') then
    raise exception using errcode = '42501', message = 'Missing profile.manage permission';
  end if;

  delete from public.client_taxpayer_links where id = p_link_id;

  insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
  values (v_link.organization_id, auth.uid(), 'client.unlinked', 'client_taxpayer_links', v_link.id,
    jsonb_build_object('target_user_id', v_link.user_id, 'taxpayer_id', v_link.taxpayer_id));
end;
$$;

revoke all on function public.link_client_taxpayer(uuid, uuid) from public, anon;
revoke all on function public.unlink_client_taxpayer(uuid) from public, anon;
grant execute on function public.link_client_taxpayer(uuid, uuid) to authenticated;
grant execute on function public.unlink_client_taxpayer(uuid) to authenticated;
