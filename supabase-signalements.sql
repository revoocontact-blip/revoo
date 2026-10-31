-- =====================================================================
-- REVOO — signalement d'annonces et modération
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- (À lancer après supabase-revoo.sql. Peut être relancé sans risque.)
--
-- ⚠️ AVANT DE LANCER : vérifie l'adresse e-mail tout en bas du script.
--    Ce doit être l'adresse de TON compte Revoo (celui qui modère).
-- =====================================================================

-- ---------- 1. MODÉRATEURS ----------
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.admins enable row level security;
drop policy if exists "voir son statut admin" on public.admins;
create policy "voir son statut admin" on public.admins
  for select to authenticated using (user_id = auth.uid());

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- ---------- 2. NOUVEAU STATUT D'ANNONCE : « removed » (retirée par la modération) ----------
alter table public.listings drop constraint if exists listings_status_check;
alter table public.listings add constraint listings_status_check check (status in ('active','sold','removed'));

-- Le modérateur voit et peut modifier toutes les annonces
drop policy if exists "modération : voir les annonces" on public.listings;
create policy "modération : voir les annonces" on public.listings
  for select to authenticated using (public.is_admin());
drop policy if exists "modération : modifier les annonces" on public.listings;
create policy "modération : modifier les annonces" on public.listings
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Un vendeur ne peut pas remettre en ligne une annonce retirée, ni retirer lui-même (réservé à la modération)
create or replace function public.protect_removed_status()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then
    if old.status = 'removed' then
      raise exception 'Annonce retirée par la modération';
    end if;
    if new.status = 'removed' then
      raise exception 'Statut réservé à la modération';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists listings_protect_removed on public.listings;
create trigger listings_protect_removed before update on public.listings
  for each row execute function public.protect_removed_status();

-- ---------- 3. SIGNALEMENTS ----------
create table if not exists public.reports (
  id            uuid primary key default gen_random_uuid(),
  listing_id    uuid not null references public.listings(id) on delete cascade,
  reporter_id   uuid references auth.users(id) on delete set null default auth.uid(),
  reason        text not null check (reason in (
                  'Article interdit ou dangereux','Contrefaçon','Arnaque ou fraude',
                  'Annonce trompeuse','Contenu choquant ou inapproprié',
                  'Ce n’est pas un vêtement','Autre')),
  details       text check (char_length(details) <= 1000),
  contact_email text check (char_length(contact_email) <= 200),
  status        text not null default 'nouveau' check (status in ('nouveau','traité','rejeté')),
  created_at    timestamptz not null default now(),
  handled_at    timestamptz
);
create unique index if not exists reports_once_per_user on public.reports (listing_id, reporter_id) where reporter_id is not null;
create index if not exists reports_status_idx on public.reports (status, created_at desc);
alter table public.reports enable row level security;

-- Tout le monde (même sans compte) peut signaler une annonce
drop policy if exists "signaler une annonce" on public.reports;
create policy "signaler une annonce" on public.reports
  for insert to anon, authenticated
  with check ((reporter_id is null and auth.uid() is null) or reporter_id = auth.uid());

-- Chacun voit ses propres signalements ; le modérateur les voit tous et peut les traiter
drop policy if exists "voir ses signalements" on public.reports;
create policy "voir ses signalements" on public.reports
  for select to authenticated using (reporter_id = auth.uid() or public.is_admin());
drop policy if exists "modération : traiter les signalements" on public.reports;
create policy "modération : traiter les signalements" on public.reports
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------- 4. TOI = MODÉRATEUR ----------
-- Remplace l'adresse ci-dessous par celle de TON compte Revoo si elle est différente.
insert into public.admins (user_id)
select id from auth.users where lower(email) = lower('revoo.contact@gmail.com')
on conflict do nothing;

-- Vérification : doit afficher ton adresse e-mail. Si la liste est vide, l'adresse ne correspond à aucun compte.
select u.email as moderateur from public.admins a join auth.users u on u.id = a.user_id;
