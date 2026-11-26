-- =====================================================================
-- ORLEOO — notifications sur téléphone (web push)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-fidelite.sql. Peut être relancé sans risque.
--
-- Il faut aussi (une seule fois) :
--   • la fonction serveur « orleoo-push » (supabase/functions/orleoo-push), avec ses secrets
--     VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY et PUSH_HOOK_SECRET ;
--   • le même PUSH_HOOK_SECRET dans le coffre de la base :
--       select vault.create_secret('<le secret>', 'push_hook_secret');
--   (Les clés ne sont JAMAIS écrites dans ce fichier ni dans le site.)
-- =====================================================================

-- ---------- Téléphones / navigateurs abonnés ----------
create table if not exists public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  endpoint   text not null unique check (endpoint ~ '^https://' and char_length(endpoint) <= 1000),
  p256dh     text not null check (char_length(p256dh) <= 200),
  auth       text not null check (char_length(auth) <= 100),
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists "mes appareils : voir" on public.push_subscriptions;
create policy "mes appareils : voir" on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
drop policy if exists "mes appareils : ajouter" on public.push_subscriptions;
create policy "mes appareils : ajouter" on public.push_subscriptions for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "mes appareils : retirer" on public.push_subscriptions;
create policy "mes appareils : retirer" on public.push_subscriptions for delete to authenticated using (user_id = auth.uid());

create or replace function public.limit_push_subscriptions()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- un appareil réabonné change de propriétaire : on remplace l'ancien
  delete from public.push_subscriptions where endpoint = new.endpoint;
  if (select count(*) from public.push_subscriptions where user_id = new.user_id) >= 10 then
    delete from public.push_subscriptions where id = (select id from public.push_subscriptions where user_id = new.user_id order by created_at limit 1);
  end if;
  return new;
end $$;
revoke all on function public.limit_push_subscriptions() from public, anon, authenticated;
drop trigger if exists push_subscriptions_limit on public.push_subscriptions;
create trigger push_subscriptions_limit before insert on public.push_subscriptions
  for each row execute function public.limit_push_subscriptions();

-- ---------- Envoi (via la fonction serveur orleoo-push) ----------
create or replace function public.send_push(p_user uuid, p_title text, p_body text, p_url text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare hook text;
begin
  if p_user is null or not exists (select 1 from public.push_subscriptions where user_id = p_user) then return; end if;
  select decrypted_secret into hook from vault.decrypted_secrets where name = 'push_hook_secret' limit 1;
  if hook is null then return; end if;
  perform net.http_post(
    url := 'https://htisbuqxnqdahtedgiiz.supabase.co/functions/v1/orleoo-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-orleoo-hook', hook),
    body := jsonb_build_object('user_id', p_user, 'title', left(p_title, 80), 'body', left(p_body, 180), 'url', p_url));
exception when others then
  raise warning 'notification non envoyée : %', sqlerrm;
end $$;
revoke all on function public.send_push(uuid, text, text, text) from public, anon, authenticated;

-- Nouveau message → la personne qui le reçoit
create or replace function public.push_on_message()
returns trigger language plpgsql security definer set search_path = public as $$
declare c record; who text;
begin
  select * into c from public.conversations where id = new.conversation_id;
  if c is null then return new; end if;
  select name into who from public.profiles where id = new.sender_id;
  perform public.send_push(case when new.sender_id = c.buyer_id then c.seller_id else c.buyer_id end,
    'Message de @' || coalesce(who, 'membre'), left(new.body, 140), '#/messages/' || c.id);
  return new;
exception when others then return new;
end $$;
revoke all on function public.push_on_message() from public, anon, authenticated;
drop trigger if exists messages_push on public.messages;
create trigger messages_push after insert on public.messages for each row execute function public.push_on_message();

-- Baisse de prix sur un favori
create or replace function public.push_on_price_drop()
returns trigger language plpgsql security definer set search_path = public as $$
declare t text;
begin
  select title into t from public.listings where id = new.listing_id;
  perform public.send_push(new.user_id, 'Baisse de prix', '« ' || left(coalesce(t, 'Un favori'), 60) || ' » passe à ' || public.eur_txt(new.new_price), '#/article/' || new.listing_id);
  return new;
exception when others then return new;
end $$;
revoke all on function public.push_on_price_drop() from public, anon, authenticated;
drop trigger if exists price_drops_push on public.price_drops;
create trigger price_drops_push after insert on public.price_drops for each row execute function public.push_on_price_drop();

-- Nouvelle annonce pour une alerte de recherche
create or replace function public.push_on_alert_hit()
returns trigger language plpgsql security definer set search_path = public as $$
declare t text; pr numeric;
begin
  select title, price into t, pr from public.listings where id = new.listing_id;
  perform public.send_push(new.user_id, 'Nouvelle annonce pour ton alerte', left(coalesce(t, ''), 80) || ' · ' || public.eur_txt(pr), '#/article/' || new.listing_id);
  return new;
exception when others then return new;
end $$;
revoke all on function public.push_on_alert_hit() from public, anon, authenticated;
drop trigger if exists alert_hits_push on public.alert_hits;
create trigger alert_hits_push after insert on public.alert_hits for each row execute function public.push_on_alert_hit();

-- Nouvelle vente → le vendeur
create or replace function public.push_on_order()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.send_push(new.seller_id, 'Tu as vendu un article !', left(new.title, 80) || ' · ' || public.eur_txt(new.price), '#/compte/ventes');
  return new;
exception when others then return new;
end $$;
revoke all on function public.push_on_order() from public, anon, authenticated;
drop trigger if exists orders_push on public.orders;
create trigger orders_push after insert on public.orders for each row execute function public.push_on_order();

select 'Notifications sur téléphone prêtes (côté base)' as info;
