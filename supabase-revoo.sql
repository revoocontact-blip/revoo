-- =====================================================================
-- REVOO — base de données Supabase
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- Le script peut être relancé sans risque (il ne supprime aucune donnée).
-- =====================================================================

-- ---------- 1. PROFILS (un par compte) ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  name        text not null check (char_length(name) between 2 and 30),
  city        text check (char_length(city) <= 40),
  bio         text check (char_length(bio) <= 300),
  created_at  timestamptz not null default now()
);

-- Création automatique du profil à l'inscription
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name, city)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1), 'Membre'), 30),
    left(nullif(trim(new.raw_user_meta_data->>'city'), ''), 40)
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 2. ANNONCES ----------
create table if not exists public.listings (
  id           uuid primary key default gen_random_uuid(),
  seller_id    uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  title        text not null check (char_length(title) between 3 and 60),
  description  text not null check (char_length(description) between 10 and 1000),
  category     text not null check (category in ('Femme','Homme','Enfant','Unisexe')),
  brand        text not null check (char_length(brand) between 1 and 40),
  size         text not null check (char_length(size) between 1 and 10),
  condition    text not null check (condition in ('Neuf avec étiquette','Très bon état','Bon état','Satisfaisant')),
  style        text check (style in ('Vintage','Streetwear','Chic','Doux')),
  price        numeric(10,2) not null check (price >= 1 and price <= 10000),
  photos       text[] not null default '{}' check (cardinality(photos) between 1 and 5),
  status       text not null default 'active' check (status in ('active','sold')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists listings_created_idx on public.listings (created_at desc);
create index if not exists listings_seller_idx on public.listings (seller_id);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;
drop trigger if exists listings_touch on public.listings;
create trigger listings_touch before update on public.listings
  for each row execute function public.touch_updated_at();

-- ---------- 3. FAVORIS ----------
create table if not exists public.favorites (
  user_id     uuid not null references auth.users(id) on delete cascade default auth.uid(),
  listing_id  uuid not null references public.listings(id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, listing_id)
);

-- ---------- 4. SÉCURITÉ (Row Level Security) ----------
alter table public.profiles  enable row level security;
alter table public.listings  enable row level security;
alter table public.favorites enable row level security;

-- Profils : visibles par tous (prénom, ville, présentation), modifiables par leur propriétaire
drop policy if exists "profils lisibles" on public.profiles;
create policy "profils lisibles" on public.profiles for select using (true);
drop policy if exists "profil modifiable par son propriétaire" on public.profiles;
create policy "profil modifiable par son propriétaire" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- Annonces : tout le monde voit les annonces en ligne ; le vendeur voit aussi les siennes vendues
drop policy if exists "annonces lisibles" on public.listings;
create policy "annonces lisibles" on public.listings
  for select using (status = 'active' or auth.uid() = seller_id);
drop policy if exists "créer ses annonces" on public.listings;
create policy "créer ses annonces" on public.listings
  for insert to authenticated with check (auth.uid() = seller_id);
drop policy if exists "modifier ses annonces" on public.listings;
create policy "modifier ses annonces" on public.listings
  for update to authenticated using (auth.uid() = seller_id) with check (auth.uid() = seller_id);
drop policy if exists "supprimer ses annonces" on public.listings;
create policy "supprimer ses annonces" on public.listings
  for delete to authenticated using (auth.uid() = seller_id);

-- Favoris : chacun ne voit et ne gère que les siens
drop policy if exists "mes favoris" on public.favorites;
create policy "mes favoris" on public.favorites
  for all to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- ---------- 5. PHOTOS (stockage) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('annonces', 'annonces', true, 2097152, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;

-- Chacun ne peut déposer / supprimer des photos que dans son propre dossier (identifiant du compte)
drop policy if exists "photos : déposer dans son dossier" on storage.objects;
create policy "photos : déposer dans son dossier" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'annonces' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "photos : supprimer dans son dossier" on storage.objects;
create policy "photos : supprimer dans son dossier" on storage.objects
  for delete to authenticated
  using (bucket_id = 'annonces' and (storage.foldername(name))[1] = auth.uid()::text);
