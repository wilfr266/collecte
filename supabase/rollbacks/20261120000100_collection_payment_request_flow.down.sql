-- Retour arrière manuel de 20261120000100_collection_payment_request_flow.sql.
-- Supabase n'exécute pas de migrations « down » : à appliquer à la main, après revue,
-- puis supprimer la ligne correspondante de supabase_migrations.schema_migrations.
--
-- Limite : les demandes déjà enregistrées sans obligation préalable restent rattachées à
-- l'obligation « Encaissement » du jour (données réelles, conservées). Les notifications
-- « Demande de paiement » déjà créées sont conservées ; seule la colonne `kind` disparaît,
-- ce qui impose de supprimer l'éventuel doublon (recipient_id, payment_id) avant de
-- recréer l'ancien index unique — la requête ci-dessous conserve la notification de
-- confirmation et détache la notification de demande de son paiement.

begin;

-- 4. payments_page : signature d'origine (copie de 20261029000100).
drop function public.payments_page(date, date, uuid, text, uuid, text, text, integer, integer, numeric, numeric);
-- Réappliquer ici le bloc « create function public.payments_page(...) » de
-- 20261029000100_payment_reporting.sql, puis :
-- revoke all on function public.payments_page(date, date, uuid, text, uuid, text, text, integer, integer) from public, anon;
-- grant execute on function public.payments_page(date, date, uuid, text, uuid, text, text, integer, integer) to authenticated;

-- 3. Récapitulatif serveur.
drop function public.payment_request_overview(uuid);

-- 2. record_collection_payment_request : réappliquer le corps d'origine de
-- 20261021000700_mobile_collection_flow.sql avec « create or replace function ».

-- 1. Notifications.
update public.notifications n
set payment_id = null
where n.kind = 'payment_requested'
  and exists (
    select 1 from public.notifications o
    where o.recipient_id = n.recipient_id and o.payment_id = n.payment_id and o.kind = 'payment_confirmed'
  );
drop index public.notifications_recipient_payment_kind_idx;
create unique index notifications_recipient_payment_idx
  on public.notifications (recipient_id, payment_id)
  where payment_id is not null;
-- Réappliquer ensuite notify_payment_confirmed() de 20261030000100_payment_notifications.sql
-- (cible ON CONFLICT (recipient_id, payment_id)), puis :
alter table public.notifications drop column kind;

commit;
