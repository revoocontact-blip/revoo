-- =====================================================================
-- REVOO — profil : photo, identifiant unique, données privées
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- (Peut être relancé sans risque.)
--
-- PUBLIC  (table profiles)         : identifiant (colonne name), photo, bio,
--                                    ville SEULEMENT si la personne l'a choisi
-- PRIVÉ   (table profiles_private) : prénom, nom, ville — lisibles par la personne seule
-- =====================================================================

-- ---------- 1. Colonnes publiques ----------
alter table public.profiles add column if not exists avatar_url text check (char_length(avatar_url) <= 500);
alter table public.profiles add column if not exists city_public boolean not null default false;

-- ---------- 2. Données privées ----------
create table if not exists public.profiles_private (
  id          uuid primary key references public.profiles(id) on delete cascade default auth.uid(),
  first_name  text check (char_length(first_name) <= 50),
  last_name   text check (char_length(last_name) <= 50),
  city        text check (char_length(city) <= 40),
  updated_at  timestamptz not null default now()
);
alter table public.profiles_private enable row level security;
drop policy if exists "données privées : lire les siennes" on public.profiles_private;
create policy "données privées : lire les siennes" on public.profiles_private
  for select to authenticated using (id = auth.uid());
drop policy if exists "données privées : créer les siennes" on public.profiles_private;
create policy "données privées : créer les siennes" on public.profiles_private
  for insert to authenticated with check (id = auth.uid());
drop policy if exists "données privées : modifier les siennes" on public.profiles_private;
create policy "données privées : modifier les siennes" on public.profiles_private
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- Migration : les villes déjà saisies passent en privé
insert into public.profiles_private (id, city)
select id, city from public.profiles where city is not null
on conflict (id) do update set city = coalesce(public.profiles_private.city, excluded.city);
update public.profiles set city = null where city_public = false and city is not null;

-- ---------- 3. Identifiant unique (sans tenir compte des majuscules) ----------
-- Si deux comptes ont le même identifiant, le plus récent reçoit un suffixe
update public.profiles p set name = left(p.name, 25) || '_' || substr(p.id::text, 1, 4)
where exists (select 1 from public.profiles q where lower(q.name) = lower(p.name) and q.created_at < p.created_at);
create unique index if not exists profiles_name_unique on public.profiles (lower(name));

-- Vérifier qu'un identifiant est libre (utilisé à l'inscription)
create or replace function public.username_available(p_name text)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (select 1 from public.profiles where lower(name) = lower(trim(p_name)) and id <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid));
$$;
grant execute on function public.username_available(text) to anon, authenticated;

-- ---------- 4. Inscription : identifiant public, ville privée ----------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare uname text;
begin
  uname := left(coalesce(nullif(trim(new.raw_user_meta_data->>'name'), ''), split_part(new.email, '@', 1), 'membre'), 30);
  if exists (select 1 from public.profiles where lower(name) = lower(uname)) then
    uname := left(uname, 25) || '_' || substr(new.id::text, 1, 4);
  end if;
  insert into public.profiles (id, name) values (new.id, uname) on conflict (id) do nothing;
  insert into public.profiles_private (id, city)
  values (new.id, left(nullif(trim(new.raw_user_meta_data->>'city'), ''), 40))
  on conflict (id) do nothing;
  return new;
end $$;

-- ---------- 5. Photos de profil (stockage public, chacun dans son dossier) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
drop policy if exists "avatar : déposer le sien" on storage.objects;
create policy "avatar : déposer le sien" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "avatar : supprimer le sien" on storage.objects;
create policy "avatar : supprimer le sien" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
