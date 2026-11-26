-- =====================================================================
-- ORLEOO — abonnements Orleoo Pro / Max / Ultra (étape 1)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-securite.sql. (Peut être relancé sans risque.)
--
-- Tant que le paiement n'est pas branché, les abonnements sont en DÉMO
-- (demo = true) : aucun argent n'est encaissé.
--
-- Avantages gérés ici (impossibles à obtenir sans abonnement, même en trichant) :
--   • mises en avant offertes chaque mois : Pro 2 · Max 6 · Ultra 15 (48 h chacune)
--   • photos par annonce : gratuit 5 · Pro 8 · Max 12 · Ultra 20
--   • annonces épinglées sur la boutique : Max 3 · Ultra 10
--   • couleur de boutique : Ultra
--   • délai de rendez-vous en main propre prolongeable de : gratuit 7 j · Pro 10 j · Max 14 j · Ultra 21 j
-- =====================================================================

do $$ begin
  if to_regprocedure('public.protect_listing()') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-securite.sql, puis relance ce script.';
  end if;
end $$;

-- ---------- 1. Abonnements ----------
create table if not exists public.subscriptions (
  user_id              uuid primary key references public.profiles(id) on delete cascade,
  plan                 text not null check (plan in ('pro','max','ultra')),
  started_at           timestamptz not null default now(),
  current_period_start timestamptz not null default now(),
  current_period_end   timestamptz not null default now() + interval '30 days',
  cancel_at_period_end boolean not null default false,
  boosts_used          int not null default 0,
  demo                 boolean not null default true,
  updated_at           timestamptz not null default now()
);
alter table public.subscriptions enable row level security;
-- Le badge est public (comme sur un profil) ; aucune écriture directe : tout passe par les fonctions
drop policy if exists "abonnements : badges visibles" on public.subscriptions;
create policy "abonnements : badges visibles" on public.subscriptions for select using (true);

-- Formule active d'une personne ('' si aucune)
create or replace function public.plan_of(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select plan from public.subscriptions
                   where user_id = p_user and current_period_end > now()), '');
$$;

create or replace function public.plan_limit(p_plan text, p_what text)
returns int language sql immutable as $$
  select case p_what
    when 'boosts' then case p_plan when 'pro' then 2 when 'max' then 6 when 'ultra' then 15 else 0 end
    when 'photos' then case p_plan when 'pro' then 8 when 'max' then 12 when 'ultra' then 20 else 5 end
    when 'pins'   then case p_plan when 'max' then 3 when 'ultra' then 10 else 0 end
    when 'handoff_days' then case p_plan when 'pro' then 10 when 'max' then 14 when 'ultra' then 21 else 7 end
    else 0 end;
$$;

-- Renouvellement (démo) : une période de 30 jours recommence, les mises en avant se rechargent.
-- Un abonnement résilié s'arrête à la fin de sa période.
create or replace function public.settle_subscriptions()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.subscriptions where cancel_at_period_end and current_period_end <= now();
  update public.subscriptions
     set current_period_start = current_period_end,
         current_period_end = current_period_end + interval '30 days',
         boosts_used = 0, updated_at = now()
   where not cancel_at_period_end and current_period_end <= now() and demo;
end $$;

-- S'abonner ou changer de formule (DÉMO : sans paiement)
create or replace function public.subscribe_demo(p_plan text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); s record;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  if p_plan not in ('pro','max','ultra') then raise exception 'Formule inconnue'; end if;
  perform public.settle_subscriptions();
  select * into s from public.subscriptions where user_id = me for update;
  if s is null then
    insert into public.subscriptions (user_id, plan) values (me, p_plan);
  else
    -- changement de formule : on garde la période en cours, la résiliation éventuelle est annulée
    update public.subscriptions set plan = p_plan, cancel_at_period_end = false, updated_at = now() where user_id = me;
  end if;
  perform public.apply_plan_limits(me);
end $$;

-- Résilier (effet à la fin de la période payée) / reprendre
create or replace function public.cancel_subscription()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.subscriptions set cancel_at_period_end = true, updated_at = now() where user_id = auth.uid();
  if not found then raise exception 'Aucun abonnement en cours'; end if;
end $$;
create or replace function public.resume_subscription()
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.subscriptions set cancel_at_period_end = false, updated_at = now()
   where user_id = auth.uid() and current_period_end > now();
  if not found then raise exception 'Aucun abonnement à reprendre'; end if;
end $$;

-- ---------- 2. Mises en avant offertes ----------
create or replace function public.use_boost(p_listing uuid)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); s record; l record; until timestamptz;
begin
  perform public.settle_subscriptions();
  select * into s from public.subscriptions where user_id = me and current_period_end > now() for update;
  if s is null then raise exception 'Les mises en avant offertes sont réservées aux abonnés Orleoo Pro, Max et Ultra'; end if;
  if s.boosts_used >= public.plan_limit(s.plan, 'boosts') then
    raise exception 'Tu as utilisé tes % mises en avant du mois', public.plan_limit(s.plan, 'boosts');
  end if;
  select * into l from public.listings where id = p_listing for update;
  if l is null or l.seller_id <> me or l.status <> 'active' then raise exception 'Choisis une de tes annonces en ligne'; end if;
  until := greatest(coalesce(l.boosted_until, now()), now()) + interval '48 hours';
  perform set_config('revoo.sys', '1', true);   -- autorise ce changement précis
  update public.listings set boosted_until = until where id = p_listing;
  perform set_config('revoo.sys', '', true);
  update public.subscriptions set boosts_used = boosts_used + 1, updated_at = now() where user_id = me;
  return until;
end $$;

-- La mise en avant ne peut toujours pas être modifiée « à la main »
create or replace function public.protect_boost()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('revoo.sys', true), '') = '1' or coalesce(public.is_admin(), false) then return new; end if;
  if tg_op = 'INSERT' then new.boosted_until := null;
  elsif new.boosted_until is distinct from old.boosted_until then new.boosted_until := old.boosted_until;
  end if;
  return new;
end $$;

-- ---------- 3. Photos, épinglage, couleur de boutique ----------
-- La limite de photos dépend maintenant de la formule (5 à 20)
do $$ declare c record; begin
  for c in select conname from pg_constraint
            where conrelid = 'public.listings'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%cardinality(photos)%'
  loop execute format('alter table public.listings drop constraint %I', c.conname); end loop;
end $$;
alter table public.listings add constraint listings_photos_count check (cardinality(photos) between 1 and 20);
alter table public.listings add column if not exists pinned boolean not null default false;
alter table public.profiles add column if not exists accent text
  check (accent in ('nuit','ciel','sauge','terracotta','lavande','sable'));

create or replace function public.check_plan_perks()
returns trigger language plpgsql security definer set search_path = public as $$
declare p text; n int;
begin
  if tg_table_name = 'listings' then
    p := public.plan_of(new.seller_id);
    if cardinality(new.photos) > public.plan_limit(p, 'photos')
       and (tg_op = 'INSERT' or cardinality(new.photos) > cardinality(old.photos)) then
      raise exception 'Ta formule permet % photos par annonce', public.plan_limit(p, 'photos');
    end if;
    if new.pinned and (tg_op = 'INSERT' or not old.pinned) then
      select count(*) into n from public.listings where seller_id = new.seller_id and pinned and id <> new.id;
      if n >= public.plan_limit(p, 'pins') then
        raise exception 'Ta formule permet % annonce(s) épinglée(s)', public.plan_limit(p, 'pins');
      end if;
    end if;
  else  -- profiles
    if new.accent is distinct from old.accent and new.accent is not null and public.plan_of(new.id) <> 'ultra' then
      raise exception 'La couleur de boutique est réservée à Orleoo Ultra';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists listings_plan_perks on public.listings;
create trigger listings_plan_perks before insert or update on public.listings
  for each row execute function public.check_plan_perks();
drop trigger if exists profiles_plan_perks on public.profiles;
create trigger profiles_plan_perks before update on public.profiles
  for each row execute function public.check_plan_perks();

-- Quand une formule baisse ou s'arrête : on retire ce qui dépasse (épingles, couleur)
create or replace function public.apply_plan_limits(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p text := public.plan_of(p_user); keep int := public.plan_limit(p, 'pins');
begin
  update public.listings set pinned = false
   where seller_id = p_user and pinned
     and id not in (select id from public.listings where seller_id = p_user and pinned order by updated_at desc limit keep);
  if p <> 'ultra' then update public.profiles set accent = null where id = p_user and accent is not null; end if;
end $$;

-- ---------- 4. Délai de main propre selon la formule ----------
create or replace function public.extend_handoff(p_order uuid, p_days int)
returns void language plpgsql security definer set search_path = public as $$
declare o record; lim int := public.plan_limit(public.plan_of(auth.uid()), 'handoff_days');
begin
  select * into o from public.orders where id = p_order for update;
  if o is null or auth.uid() not in (o.buyer_id, o.seller_id) or o.delivery <> 'main_propre' or o.status <> 'paid' then
    raise exception 'Action impossible sur cette commande';
  end if;
  if p_days is null or p_days < 1 or p_days > lim then raise exception 'Choisis entre 1 et % jours', lim; end if;
  if o.handoff_extended + p_days > lim then
    raise exception 'Le délai ne peut être prolongé que de % jours au total (il reste % jour(s))', lim, greatest(0, lim - o.handoff_extended);
  end if;
  if o.handoff_deadline <= now() then raise exception 'Le délai est déjà dépassé'; end if;
  update public.orders set handoff_deadline = handoff_deadline + make_interval(days => p_days),
    handoff_extended = handoff_extended + p_days, updated_at = now() where id = p_order;
end $$;

-- ---------- 5. Droits ----------
revoke all on function public.subscribe_demo(text) from public, anon;
revoke all on function public.cancel_subscription() from public, anon;
revoke all on function public.resume_subscription() from public, anon;
revoke all on function public.use_boost(uuid) from public, anon;
revoke all on function public.settle_subscriptions() from public, anon;
grant execute on function public.subscribe_demo(text) to authenticated;
grant execute on function public.cancel_subscription() to authenticated;
grant execute on function public.resume_subscription() to authenticated;
grant execute on function public.use_boost(uuid) to authenticated;
grant execute on function public.settle_subscriptions() to authenticated;
revoke execute on function public.apply_plan_limits(uuid) from public, anon, authenticated;
revoke execute on function public.check_plan_perks() from public, anon, authenticated;
revoke execute on function public.protect_boost() from public, anon, authenticated;

-- Vérification : doit afficher « aucune »
select coalesce(string_agg(tablename, ', '), 'aucune') as tables_sans_protection
from pg_tables where schemaname = 'public' and not rowsecurity;
