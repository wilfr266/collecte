-- Notification du client à la confirmation d'un paiement, liste des mois d'historique et
-- lien notification → paiement. Tests pgTAP : tests/payment_notifications.test.sql.
--
-- Constat : aucune fonction n'écrivait dans `notifications` ; un client n'était jamais
-- prévenu d'un paiement confirmé. La table existante est réutilisée (RLS
-- notifications_read_own inchangée : chacun ne lit que ses notifications), complétée
-- d'une référence au paiement pour empêcher les doublons et ouvrir son détail.
--
-- Déclenchement : uniquement lorsqu'un paiement atteint le statut `confirmed`, quel que
-- soit le chemin (espèces du collecteur via record_field_payment, validation Mobile Money
-- par l'administration, caisse, prestataire). Une relance réseau ne recrée ni paiement
-- (clé d'idempotence) ni notification (index unique destinataire + paiement).

-- ── Référence au paiement ──────────────────────────────────────────────────

alter table public.notifications
  add column payment_id uuid references public.payments(id) on delete restrict;

create unique index notifications_recipient_payment_idx
  on public.notifications (recipient_id, payment_id)
  where payment_id is not null;

-- ── Création à la confirmation ─────────────────────────────────────────────

create function public.notify_payment_confirmed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tz text;
  v_at timestamptz;
  v_body text;
begin
  if tg_op = 'UPDATE' and old.status = 'confirmed' then
    return new;
  end if;

  -- Un incident de notification ne doit jamais annuler la confirmation du paiement.
  begin
    v_tz := public.organization_timezone(new.organization_id);
    v_at := coalesce(new.confirmed_at, now());
    v_body := 'Votre paiement de '
      || replace(to_char(new.amount, 'FM999,999,999,990'), ',', ' ')
      || ' FCFA a été confirmé le ' || to_char(v_at at time zone v_tz, 'DD/MM/YYYY')
      || ' à ' || to_char(v_at at time zone v_tz, 'HH24 "h" MI') || '.';

    insert into public.notifications (organization_id, recipient_id, title, body, payment_id)
    select distinct new.organization_id, l.user_id, 'Paiement confirmé', v_body, new.id
    from public.collections c
    join public.establishments e
      on e.id = c.establishment_id and e.organization_id = c.organization_id
    join public.client_taxpayer_links l
      on l.taxpayer_id = e.taxpayer_id and l.organization_id = e.organization_id
    join public.profiles p
      on p.id = l.user_id and p.organization_id = l.organization_id and p.status = 'active'
    where c.id = new.collection_id and c.organization_id = new.organization_id
      and exists (
        select 1 from public.user_roles ur
        where ur.user_id = l.user_id and ur.organization_id = l.organization_id and ur.role_key = 'client'
      )
    on conflict (recipient_id, payment_id) where payment_id is not null do nothing;
  exception when others then
    insert into public.audit_logs (organization_id, actor_id, action, entity_table, entity_id, metadata)
    values (new.organization_id, null, 'notification.failed', 'payments', new.id,
      jsonb_build_object('sqlstate', sqlstate));
  end;

  return new;
end;
$$;

revoke all on function public.notify_payment_confirmed() from public, anon, authenticated;

create trigger payments_notify_confirmed
  after insert or update of status on public.payments
  for each row
  when (new.status = 'confirmed')
  execute function public.notify_payment_confirmed();

-- ── Mois disposant d'un historique ─────────────────────────────────────────
-- Mêmes règles que payment_summary : périmètre payment_access, date effective
-- collections.visited_at, mois calculé dans le fuseau de l'organisation, encaissé =
-- confirmed uniquement. Seuls les mois réellement concernés sont renvoyés.

create function public.payment_months(p_taxpayer_id uuid)
returns table (
  month date,
  confirmed_amount numeric,
  confirmed_count bigint,
  pending_amount numeric,
  pending_count bigint,
  cancelled_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_org uuid;
  v_tz text;
begin
  if p_taxpayer_id is null then
    raise exception using errcode = '22023', message = 'A taxpayer is required';
  end if;
  select a.organization_id into v_org from public.payment_access(p_taxpayer_id) a;
  v_tz := public.organization_timezone(v_org);

  return query
  select date_trunc('month', c.visited_at at time zone v_tz)::date as month,
    coalesce(sum(pay.amount) filter (where pay.status = 'confirmed'), 0),
    count(*) filter (where pay.status = 'confirmed'),
    coalesce(sum(pay.amount) filter (where pay.status = 'pending'), 0),
    count(*) filter (where pay.status = 'pending'),
    count(*) filter (where pay.status in ('failed', 'reversed'))
  from public.payments pay
  join public.collections c on c.id = pay.collection_id and c.organization_id = pay.organization_id
  join public.establishments e on e.id = c.establishment_id and e.organization_id = c.organization_id
  where pay.organization_id = v_org and e.taxpayer_id = p_taxpayer_id
  group by 1
  order by 1 desc
  limit 120;
end;
$$;

-- ── Notification → paiement ────────────────────────────────────────────────
-- Contribuable et mois du paiement, après contrôle du périmètre de l'appelant.

create function public.payment_location(p_payment_id uuid)
returns table (taxpayer_id uuid, taxpayer_name text, month date)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_taxpayer uuid;
  v_name text;
  v_org uuid;
  v_visited timestamptz;
begin
  select e.taxpayer_id, t.legal_name, pay.organization_id, c.visited_at
  into v_taxpayer, v_name, v_org, v_visited
  from public.payments pay
  join public.collections c on c.id = pay.collection_id and c.organization_id = pay.organization_id
  join public.establishments e on e.id = c.establishment_id and e.organization_id = c.organization_id
  join public.taxpayers t on t.id = e.taxpayer_id and t.organization_id = e.organization_id
  where pay.id = p_payment_id;

  if v_taxpayer is null then
    raise exception using errcode = '42501', message = 'Payment is not accessible';
  end if;
  -- Lève 42501 si l'appelant n'a aucun droit sur ce contribuable.
  perform 1 from public.payment_access(v_taxpayer);

  return query select v_taxpayer, v_name,
    date_trunc('month', v_visited at time zone public.organization_timezone(v_org))::date;
end;
$$;

revoke all on function public.payment_months(uuid) from public, anon;
revoke all on function public.payment_location(uuid) from public, anon;
grant execute on function public.payment_months(uuid) to authenticated;
grant execute on function public.payment_location(uuid) to authenticated;
