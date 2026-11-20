-- =====================================================================
-- REVOO — « Supprimer mon compte » directement dans le site / l'application
-- (obligatoire pour l'App Store et Google Play, et prévu par le RGPD)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS tous les autres scripts. (Peut être relancé sans risque.)
--
-- Ce qui est SUPPRIMÉ : le compte de connexion, le profil (identifiant, photo,
-- bannière, bio), les données privées (prénom, nom, ville), les annonces, les
-- favoris, les adresses d'échange.
-- Ce qui est CONSERVÉ pour l'autre personne, sans lien avec le compte supprimé :
-- les ventes, achats, échanges, avis et conversations déjà faits, affichés
-- avec « Membre supprimé ». Personne ne perd son historique ni son argent.
-- =====================================================================

-- Vérification : les scripts précédents doivent avoir été lancés
do $$ begin
  if to_regclass('public.orders') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-revoopay.sql, puis relance ce script.';
  end if;
  if to_regclass('public.trades') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-mainpropre-echange.sql, puis relance ce script.';
  end if;
  if to_regclass('public.reviews') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-avis-et-emails.sql, puis relance ce script.';
  end if;
end $$;

-- ---------- 1. Garder l'historique de l'autre personne ----------
-- Les liens vers un compte supprimé deviennent « vides » au lieu d'effacer la ligne.
create or replace function public.revoo_set_null_fk(p_table text, p_column text, p_name text)
returns void language plpgsql as $$
declare c record;
begin
  for c in
    select con.conname from pg_constraint con
    join pg_attribute att on att.attrelid = con.conrelid and att.attnum = any(con.conkey)
    where con.contype = 'f' and con.conrelid = ('public.' || p_table)::regclass and att.attname = p_column
  loop
    execute format('alter table public.%I drop constraint %I', p_table, c.conname);
  end loop;
  execute format('alter table public.%I alter column %I drop not null', p_table, p_column);
  execute format('alter table public.%I add constraint %I foreign key (%I) references public.profiles(id) on delete set null',
                 p_table, p_name, p_column);
end $$;

select public.revoo_set_null_fk('orders',        'buyer_id',    'orders_buyer_id_fkey');
select public.revoo_set_null_fk('orders',        'seller_id',   'orders_seller_id_fkey');
select public.revoo_set_null_fk('reviews',       'buyer_id',    'reviews_buyer_id_fkey');
select public.revoo_set_null_fk('reviews',       'seller_id',   'reviews_seller_id_fkey');
select public.revoo_set_null_fk('trades',        'proposer_id', 'trades_proposer_id_fkey');
select public.revoo_set_null_fk('trades',        'receiver_id', 'trades_receiver_id_fkey');
select public.revoo_set_null_fk('conversations', 'buyer_id',    'conversations_buyer_id_fkey');
select public.revoo_set_null_fk('conversations', 'seller_id',   'conversations_seller_id_fkey');
select public.revoo_set_null_fk('messages',      'sender_id',   'messages_sender_id_fkey');
drop function public.revoo_set_null_fk(text, text, text);

-- Plus personne ne peut écrire à un membre supprimé (ses notifications ne partiraient nulle part)
create or replace function public.block_messages_to_deleted()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.conversations c where c.id = new.conversation_id
             and (c.buyer_id is null or c.seller_id is null)) then
    raise exception 'Ce membre a supprimé son compte : tu ne peux plus lui écrire';
  end if;
  return new;
end $$;
drop trigger if exists messages_block_deleted on public.messages;
create trigger messages_block_deleted before insert on public.messages
  for each row execute function public.block_messages_to_deleted();

-- ---------- 2. La suppression ----------
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); n int;
begin
  if me is null then raise exception 'Connexion requise'; end if;

  -- Rien ne doit être en cours : l'argent ou un colis de quelqu'un en dépend
  select count(*) into n from public.orders
   where me in (buyer_id, seller_id) and status in ('paid','shipped','problem');
  if n > 0 then
    raise exception 'Tu as % vente(s) ou achat(s) en cours : termine-les ou annule-les avant de supprimer ton compte', n;
  end if;
  select count(*) into n from public.trades
   where me in (proposer_id, receiver_id) and status in ('accepted','problem');
  if n > 0 then
    raise exception 'Tu as % échange(s) en cours : termine-les avant de supprimer ton compte', n;
  end if;

  -- Les propositions d'échange en attente tombent
  update public.trades set status = 'cancelled', updated_at = now()
   where me in (proposer_id, receiver_id) and status = 'proposed';

  -- Annonces (les ventes déjà faites restent chez l'acheteur, sans lien)
  delete from public.listings where seller_id = me;

  -- Le compte de connexion : supprime en cascade le profil, les données privées,
  -- les favoris et les adresses d'échange
  delete from auth.users where id = me;
end $$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
revoke all on function public.block_messages_to_deleted() from public, anon, authenticated;

-- Vérification : doit afficher « delete_my_account »
select proname from pg_proc where proname = 'delete_my_account';
