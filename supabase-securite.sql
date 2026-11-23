-- =====================================================================
-- ORLEOO — renforcement de la sécurité (audit complet)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS tous les autres scripts. (Peut être relancé sans risque.)
--
-- Corrige :
--  1. Annonces : date de publication non falsifiable, impossible de remettre
--     en vente un article déjà payé ou échangé, photos hébergées par Orleoo uniquement.
--  2. Profils : « membre depuis » non falsifiable, identifiant au bon format,
--     photo et bannière hébergées par Orleoo uniquement.
--  3. Anti-abus : limites de messages, conversations, signalements, achats,
--     échanges et annonces (contre le spam et le sabotage du catalogue).
--  4. Stockage : nombre de photos limité par compte.
--  5. Une fonction interne n'est plus appelable depuis le site.
-- =====================================================================

-- Vérification : les scripts précédents doivent avoir été lancés
do $$ begin
  if to_regclass('public.trades') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-mainpropre-echange.sql, puis relance ce script.';
  end if;
  if to_regprocedure('public.delete_my_account()') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-suppression-compte.sql, puis relance ce script.';
  end if;
end $$;

-- ---------- 1. ANNONCES ----------
create or replace function public.protect_listing()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  base text := 'https://htisbuqxnqdahtedgiiz.supabase.co/storage/v1/object/public/annonces/';
  n int;
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.status := 'active';
    -- anti-spam : 50 nouvelles annonces par jour maximum
    select count(*) into n from public.listings
     where seller_id = new.seller_id and created_at > now() - interval '1 day';
    if n >= 50 then raise exception 'Tu as publié beaucoup d’annonces aujourd’hui : réessaie demain'; end if;
  else
    new.created_at := old.created_at;            -- impossible de « remonter » une annonce en trichant sur la date
    if public.is_admin() then return new; end if;
    -- impossible de remettre en vente un article payé (Orleoo Pay) ou engagé dans un échange
    if new.status = 'active' and old.status <> 'active' and (
         exists (select 1 from public.orders o where o.listing_id = new.id and o.status <> 'cancelled')
      or exists (select 1 from public.trades t where (t.offered_listing = new.id or t.wanted_listing = new.id)
                   and t.status in ('accepted','problem','completed'))) then
      raise exception 'Cet article est lié à une vente ou un échange Orleoo Pay : il ne peut pas être remis en vente';
    end if;
  end if;
  -- photos : uniquement celles déposées sur Orleoo, dans le dossier du vendeur
  if tg_op = 'INSERT' or new.photos is distinct from old.photos then
    if exists (select 1 from unnest(new.photos) p where p not like base || new.seller_id::text || '/%' or p like '%..%' or p ~ '[\s"''<>]') then
      raise exception 'Photos invalides : ajoute-les depuis le formulaire Orleoo';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists listings_protect_core on public.listings;
create trigger listings_protect_core before insert or update on public.listings
  for each row execute function public.protect_listing();

-- ---------- 2. PROFILS ----------
create or replace function public.protect_profile()
returns trigger language plpgsql security definer set search_path = public as $$
declare base text := 'https://htisbuqxnqdahtedgiiz.supabase.co/storage/v1/object/public/avatars/' || new.id::text || '/';
begin
  if tg_op = 'INSERT' then
    -- identifiant créé à l'inscription : on retire les caractères non autorisés
    new.name := left(regexp_replace(coalesce(new.name, ''), '[^A-Za-z0-9._-]', '', 'g'), 20);
    if char_length(new.name) < 3 then new.name := 'membre_' || substr(new.id::text, 1, 6); end if;
    if exists (select 1 from public.profiles where lower(name) = lower(new.name)) then
      new.name := left(new.name, 15) || '_' || substr(new.id::text, 1, 4);
    end if;
    new.created_at := now();
    return new;
  end if;
  new.created_at := old.created_at;              -- « Membre depuis » non falsifiable
  if new.name is distinct from old.name and new.name !~ '^[A-Za-z0-9._-]{3,20}$' then
    raise exception 'Identifiant invalide : 3 à 20 caractères (lettres, chiffres, point, tiret)';
  end if;
  if new.avatar_url is distinct from old.avatar_url and new.avatar_url is not null
     and (new.avatar_url not like base || '%' or new.avatar_url like '%..%' or new.avatar_url ~ '[\s"''<>()]') then
    raise exception 'Photo de profil invalide';
  end if;
  if new.banner_url is distinct from old.banner_url and new.banner_url is not null
     and (new.banner_url not like base || '%' or new.banner_url like '%..%' or new.banner_url ~ '[\s"''<>()]') then
    raise exception 'Bannière invalide';
  end if;
  return new;
end $$;
drop trigger if exists profiles_protect_core on public.profiles;
create trigger profiles_protect_core before insert or update on public.profiles
  for each row execute function public.protect_profile();

-- ---------- 3. ANTI-ABUS ----------
create index if not exists messages_sender_idx on public.messages (sender_id, created_at desc);
create index if not exists orders_buyer_created_idx on public.orders (buyer_id, created_at desc);
create index if not exists reports_listing_idx on public.reports (listing_id, created_at desc);

create or replace function public.rate_limit()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if tg_table_name = 'messages' then
    select count(*) into n from public.messages where sender_id = new.sender_id and created_at > now() - interval '10 minutes';
    if n >= 30 then raise exception 'Tu envoies beaucoup de messages : patiente quelques minutes'; end if;

  elsif tg_table_name = 'conversations' then
    select count(*) into n from public.conversations where buyer_id = new.buyer_id and created_at > now() - interval '1 day';
    if n >= 30 then raise exception 'Tu as contacté beaucoup de vendeurs aujourd’hui : réessaie demain'; end if;

  elsif tg_table_name = 'reports' then
    -- un nouveau signalement arrive TOUJOURS « à traiter » chez la modération
    new.status := 'nouveau';
    new.handled_at := null;
    new.created_at := now();
    if new.reporter_id is not null then
      select count(*) into n from public.reports where reporter_id = new.reporter_id and created_at > now() - interval '1 day';
      if n >= 20 then raise exception 'Tu as fait beaucoup de signalements aujourd’hui : réessaie demain'; end if;
    else
      select count(*) into n from public.reports where reporter_id is null and listing_id = new.listing_id and created_at > now() - interval '1 day';
      if n >= 3 then raise exception 'Cette annonce a déjà été signalée : la modération va l’examiner'; end if;
      select count(*) into n from public.reports where reporter_id is null and created_at > now() - interval '1 hour';
      if n >= 100 then raise exception 'Trop de signalements en ce moment : réessaie un peu plus tard'; end if;
    end if;

  elsif tg_table_name = 'orders' then
    select count(*) into n from public.orders where buyer_id = new.buyer_id and status in ('paid','shipped','problem');
    if n >= 10 then raise exception 'Tu as déjà 10 achats en cours : termine-en avant d’en commencer d’autres'; end if;
    select count(*) into n from public.orders where buyer_id = new.buyer_id and created_at > now() - interval '1 day';
    if n >= 30 then raise exception 'Tu as fait beaucoup d’achats aujourd’hui : réessaie demain'; end if;

  elsif tg_table_name = 'trades' then
    select count(*) into n from public.trades where proposer_id = new.proposer_id and status = 'proposed';
    if n >= 10 then raise exception 'Tu as déjà 10 propositions d’échange en attente'; end if;
    select count(*) into n from public.trades where proposer_id = new.proposer_id and created_at > now() - interval '1 day';
    if n >= 20 then raise exception 'Tu as proposé beaucoup d’échanges aujourd’hui : réessaie demain'; end if;
  end if;
  return new;
end $$;

drop trigger if exists messages_rate_limit on public.messages;
create trigger messages_rate_limit before insert on public.messages for each row execute function public.rate_limit();
drop trigger if exists conversations_rate_limit on public.conversations;
create trigger conversations_rate_limit before insert on public.conversations for each row execute function public.rate_limit();
drop trigger if exists reports_rate_limit on public.reports;
create trigger reports_rate_limit before insert on public.reports for each row execute function public.rate_limit();
drop trigger if exists orders_rate_limit on public.orders;
create trigger orders_rate_limit before insert on public.orders for each row execute function public.rate_limit();
drop trigger if exists trades_rate_limit on public.trades;
create trigger trades_rate_limit before insert on public.trades for each row execute function public.rate_limit();

-- ---------- 4. STOCKAGE : quota de fichiers par compte ----------
create or replace function public.my_file_count(p_bucket text)
returns int language sql stable security definer set search_path = public, storage as $$
  select count(*)::int from storage.objects
   where bucket_id = p_bucket and (storage.foldername(name))[1] = auth.uid()::text;
$$;
revoke execute on function public.my_file_count(text) from public, anon;
grant execute on function public.my_file_count(text) to authenticated;

drop policy if exists "photos : déposer dans son dossier" on storage.objects;
create policy "photos : déposer dans son dossier" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'annonces' and (storage.foldername(name))[1] = auth.uid()::text
              and name !~ '\.\.' and public.my_file_count('annonces') < 300);
drop policy if exists "avatar : déposer le sien" on storage.objects;
create policy "avatar : déposer le sien" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text
              and name !~ '\.\.' and public.my_file_count('avatars') < 30);

-- ---------- 5. Fonctions internes : plus appelables depuis le site ----------
revoke execute on function public.purchases_done(uuid) from public, anon, authenticated;
revoke execute on function public.protect_listing() from public, anon, authenticated;
revoke execute on function public.protect_profile() from public, anon, authenticated;
revoke execute on function public.rate_limit() from public, anon, authenticated;

-- ---------- Vérification ----------
-- Doit afficher « aucune » : toutes les tables du site sont protégées
select coalesce(string_agg(tablename, ', '), 'aucune') as tables_sans_protection
from pg_tables where schemaname = 'public' and not rowsecurity;
