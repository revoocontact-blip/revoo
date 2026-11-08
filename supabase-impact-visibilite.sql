-- =====================================================================
-- REVOO — compteur d'impact en temps réel + mise en avant des annonces
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- (Peut être relancé sans risque.)
--
-- COMPTEUR : à chaque article marqué « vendu », on ajoute une ESTIMATION
-- du CO2 émis pour fabriquer un vêtement neuf équivalent (valeurs basses,
-- d'après les ordres de grandeur publiés par l'ADEME). Si l'annonce est
-- remise en ligne, l'estimation est retirée.
--
-- MISE EN AVANT : la colonne boosted_until servira aux mises en avant
-- payantes (branchées avec le paiement). Personne ne peut la modifier
-- soi-même : seul un modérateur ou le serveur peut le faire.
-- =====================================================================

-- ---------- 1. Compteur global ----------
create table if not exists public.impact_stats (
  id          int primary key default 1 check (id = 1),
  co2_kg      numeric not null default 0,
  items       int not null default 0,
  updated_at  timestamptz not null default now()
);
insert into public.impact_stats (id) values (1) on conflict (id) do nothing;
alter table public.impact_stats enable row level security;
drop policy if exists "impact : lecture publique" on public.impact_stats;
create policy "impact : lecture publique" on public.impact_stats for select to anon, authenticated using (true);
-- (aucune règle d'écriture : seul le déclencheur ci-dessous peut le modifier)

-- ---------- 2. Estimation par type de vêtement (kg CO2e) ----------
-- Doit rester identique à la fonction impactKg() du site.
create or replace function public.impact_kg_for(p_title text)
returns numeric language plpgsql immutable as $$
declare t text := translate(lower(coalesce(p_title, '')), 'àâäéèêëîïôöùûüç', 'aaaeeeeiioouuuc');
begin
  if t ~ '(manteau|doudoune|parka|trench|caban)' then return 89; end if;
  if t ~ '(veste|blouson|blazer|perfecto|robe|combinaison|jean)' then return 25; end if;
  if t ~ '(pantalon|chino|jogging|legging|basket|sneaker|chaussure|botte|bottine|sandale|escarpin|mocassin|derby)' then return 20; end if;
  if t ~ '(pull|sweat|hoodie|gilet|cardigan|chemise|blouse)' then return 12; end if;
  return 6;
end $$;

alter table public.listings add column if not exists impact_kg numeric;

-- Les articles déjà vendus avant ce script sont comptés une seule fois (premier lancement seulement)
do $$
declare total numeric; n int;
begin
  if not exists (select 1 from pg_trigger where tgname = 'listings_track_impact') then
    select coalesce(sum(public.impact_kg_for(title)), 0), count(*) into total, n
      from public.listings where status = 'sold' and impact_kg is null;
    update public.listings set impact_kg = public.impact_kg_for(title) where status = 'sold' and impact_kg is null;
    update public.impact_stats set co2_kg = co2_kg + total, items = items + n, updated_at = now() where id = 1;
  end if;
end $$;

create or replace function public.track_impact()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'sold' and old.status is distinct from 'sold' then
    new.impact_kg := public.impact_kg_for(new.title);
    update public.impact_stats set co2_kg = co2_kg + new.impact_kg, items = items + 1, updated_at = now() where id = 1;
  elsif old.status = 'sold' and new.status = 'active' and old.impact_kg is not null then
    update public.impact_stats set co2_kg = greatest(0, co2_kg - old.impact_kg), items = greatest(0, items - 1), updated_at = now() where id = 1;
    new.impact_kg := null;
  else
    new.impact_kg := old.impact_kg;  -- personne ne peut le modifier à la main
  end if;
  return new;
end $$;
drop trigger if exists listings_track_impact on public.listings;
create trigger listings_track_impact before update on public.listings
  for each row execute function public.track_impact();

-- Temps réel : le site reçoit chaque mise à jour du compteur
do $$ begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'impact_stats') then
    alter publication supabase_realtime add table public.impact_stats;
  end if;
exception when others then raise notice 'Temps réel non activé : %', sqlerrm;
end $$;

-- ---------- 3. Mise en avant payante (préparation) ----------
alter table public.listings add column if not exists boosted_until timestamptz;
create or replace function public.protect_boost()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if not coalesce(public.is_admin(), false) then new.boosted_until := null; end if;
  elsif new.boosted_until is distinct from old.boosted_until and not coalesce(public.is_admin(), false) then
    new.boosted_until := old.boosted_until;
  end if;
  return new;
end $$;
drop trigger if exists listings_protect_boost on public.listings;
create trigger listings_protect_boost before insert or update on public.listings
  for each row execute function public.protect_boost();

-- Vérification : doit afficher une ligne avec 0 (ou le total déjà atteint)
select co2_kg, items from public.impact_stats;
