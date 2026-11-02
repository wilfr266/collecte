-- Publication Realtime des tables lues en direct par les applications.
--
-- Constat (2026-10-28) : la publication `supabase_realtime` ne contenait
-- aucune table ; les abonnements `postgres_changes` de Terenza Admin
-- (useLiveRefresh) et de l'application mobile (LiveRefresh) ne recevaient
-- donc rien et seule l'actualisation périodique fonctionnait.
--
-- Sécurité : Realtime applique RLS à chaque abonné `authenticated` ; un
-- client ne reçoit que les lignes qu'il a déjà le droit de lire (ex. les
-- obligations de ses contribuables rattachés). Aucun privilège n'est ajouté.
-- Les tables `payments`/`receipts` restent illisibles pour un client : il
-- est notifié via la mise à jour de `financial_obligations` à la
-- confirmation d'un paiement.
--
-- Idempotent : chaque table n'est ajoutée que si elle n'est pas déjà publiée.

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'financial_obligations',
    'client_taxpayer_links',
    'notifications',
    'payments',
    'receipts',
    'collections',
    'missions',
    'mission_assignments',
    'appointments',
    'profiles',
    'user_roles'
  ] loop
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = v_table
    ) then
      execute format('alter publication supabase_realtime add table public.%I', v_table);
    end if;
  end loop;
end
$$;
