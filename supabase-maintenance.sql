-- =====================================================================
-- REVOO — mode maintenance et pauses (fondateur)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-equipe.sql. (Peut être relancé sans risque.)
--
--   • Maintenance : le site affiche une page « en maintenance » (image +
--     message + heure de retour) à tous les visiteurs, sauf l'équipe.
--     Plus rien ne peut être publié, acheté, échangé ni écrit.
--   • Pauses séparées : nouvelles annonces / achats et échanges / messagerie.
--   Tout est bloqué aussi côté serveur : impossible de contourner.
-- =====================================================================

do $$ begin
  if to_regclass('public.site_settings') is null or to_regprocedure('public.is_founder()') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-equipe.sql, puis relance ce script.';
  end if;
end $$;

-- ---------- 1. Réglages ----------
alter table public.site_settings add column if not exists maintenance boolean not null default false;
alter table public.site_settings add column if not exists maintenance_title text check (char_length(maintenance_title) <= 80);
alter table public.site_settings add column if not exists maintenance_message text check (char_length(maintenance_message) <= 500);
alter table public.site_settings add column if not exists maintenance_image text check (char_length(maintenance_image) <= 500);
alter table public.site_settings add column if not exists maintenance_until timestamptz;
alter table public.site_settings add column if not exists pause_purchases boolean not null default false;
alter table public.site_settings add column if not exists pause_messages boolean not null default false;

-- ---------- 2. Blocage côté serveur ----------
create or replace function public.block_when_paused()
returns trigger language plpgsql security definer set search_path = public as $$
declare s record;
begin
  if public.is_admin() then return new; end if;
  select * into s from public.site_settings where id = 1;
  if s is null then return new; end if;
  if s.maintenance then
    raise exception 'Revoo est en maintenance%. Réessaie un peu plus tard.',
      case when s.maintenance_until is null then '' else ' jusqu’au ' || to_char(s.maintenance_until at time zone 'Europe/Paris', 'DD/MM à HH24:MI') end;
  end if;
  if tg_table_name = 'listings' and s.pause_listings then
    raise exception 'Les nouvelles annonces sont mises en pause quelques instants par l’équipe Revoo. Réessaie un peu plus tard.';
  end if;
  if tg_table_name in ('orders','trades') and s.pause_purchases then
    raise exception 'Les achats et les échanges sont mis en pause quelques instants par l’équipe Revoo. Réessaie un peu plus tard.';
  end if;
  if tg_table_name in ('messages','conversations') and s.pause_messages then
    raise exception 'La messagerie est mise en pause quelques instants par l’équipe Revoo. Réessaie un peu plus tard.';
  end if;
  return new;
end $$;
drop trigger if exists listings_pause on public.listings;
do $$ declare t text; begin
  foreach t in array array['listings','orders','trades','messages','conversations','reviews'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_site_guard', t);
    execute format('create trigger %I before insert on public.%I for each row execute function public.block_when_paused()', t || '_site_guard', t);
  end loop;
end $$;

-- ---------- 3. Commandes du fondateur ----------
create or replace function public.set_maintenance(p_on boolean, p_title text, p_message text, p_image text, p_until timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare base text := 'https://htisbuqxnqdahtedgiiz.supabase.co/storage/v1/object/public/avatars/' || auth.uid()::text || '/';
begin
  if not public.is_founder() then raise exception 'Réservé au fondateur'; end if;
  if p_image is not null and p_image <> '' and (p_image not like base || '%' or p_image like '%..%' or p_image ~ '[\s"''<>()]') then
    raise exception 'Image invalide : ajoute-la depuis la console';
  end if;
  update public.site_settings set
    maintenance = coalesce(p_on, false),
    maintenance_title = nullif(left(trim(coalesce(p_title, '')), 80), ''),
    maintenance_message = nullif(left(trim(coalesce(p_message, '')), 500), ''),
    maintenance_image = nullif(p_image, ''),
    maintenance_until = p_until,
    updated_by = auth.uid(), updated_at = now()
  where id = 1;
  perform public.log_action(case when p_on then 'Maintenance activée' else 'Maintenance désactivée' end, null, null,
    coalesce(nullif(trim(p_title), ''), '') || case when p_until is null then '' else ' · retour prévu ' || to_char(p_until at time zone 'Europe/Paris', 'DD/MM HH24:MI') end);
end $$;

create or replace function public.set_pauses(p_listings boolean, p_purchases boolean, p_messages boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_founder() then raise exception 'Réservé au fondateur'; end if;
  update public.site_settings set pause_listings = coalesce(p_listings, false), pause_purchases = coalesce(p_purchases, false),
    pause_messages = coalesce(p_messages, false), updated_by = auth.uid(), updated_at = now() where id = 1;
  perform public.log_action('Pauses modifiées', null, null,
    'annonces : ' || case when p_listings then 'pause' else 'ouvert' end
    || ' · achats et échanges : ' || case when p_purchases then 'pause' else 'ouvert' end
    || ' · messagerie : ' || case when p_messages then 'pause' else 'ouvert' end);
end $$;

revoke all on function public.block_when_paused() from public, anon, authenticated;
revoke all on function public.set_maintenance(boolean, text, text, text, timestamptz) from public, anon;
revoke all on function public.set_pauses(boolean, boolean, boolean) from public, anon;
grant execute on function public.set_maintenance(boolean, text, text, text, timestamptz) to authenticated;
grant execute on function public.set_pauses(boolean, boolean, boolean) to authenticated;

-- Vérification : doit afficher « non » trois fois (rien n'est en pause)
select case when maintenance then 'oui' else 'non' end as maintenance,
       case when pause_purchases then 'oui' else 'non' end as achats_en_pause,
       case when pause_messages then 'oui' else 'non' end as messagerie_en_pause
from public.site_settings where id = 1;
