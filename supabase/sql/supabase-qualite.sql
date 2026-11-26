-- =====================================================================
-- ORLEOO — qualité des annonces : détection automatique des annonces
-- suspectes + « Coups de cœur de l'équipe »
-- Peut être relancé sans risque.
-- =====================================================================
alter table public.listings add column if not exists photo_hash text check (char_length(photo_hash) <= 64);
alter table public.listings add column if not exists staff_pick boolean not null default false;
create index if not exists listings_photo_hash_idx on public.listings (photo_hash) where photo_hash is not null;

-- Seule l'équipe peut mettre une annonce en « coup de cœur »
create or replace function public.protect_staff_pick()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('revoo.sys', true), '') = 'on' then return new; end if;
  if tg_op = 'INSERT' then new.staff_pick := false;
  elsif new.staff_pick is distinct from old.staff_pick then new.staff_pick := old.staff_pick; end if;
  return new;
end $$;
revoke all on function public.protect_staff_pick() from public, anon, authenticated;
drop trigger if exists listings_protect_pick on public.listings;
create trigger listings_protect_pick before insert or update on public.listings
  for each row execute function public.protect_staff_pick();

create or replace function public.set_staff_pick(p_listing uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_perm('signalements');
  perform set_config('revoo.sys', 'on', true);
  update public.listings set staff_pick = coalesce(p_on, false) where id = p_listing;
  perform public.log_action(case when p_on then 'Coup de cœur ajouté' else 'Coup de cœur retiré' end, null, p_listing, null);
end $$;
revoke all on function public.set_staff_pick(uuid, boolean) from public, anon;
grant execute on function public.set_staff_pick(uuid, boolean) to authenticated;

-- Détection automatique : l'annonce reste en ligne, mais un signalement arrive en modération
create or replace function public.flag_suspicious_listing()
returns trigger language plpgsql security definer set search_path = public as $$
declare med numeric; n int; why text[] := '{}';
begin
  select percentile_cont(0.5) within group (order by price), count(*) into med, n
  from public.listings where category = new.category and status = 'active' and id <> new.id;
  if n >= 5 and new.price < med * 0.25 then
    why := array_append(why, format('prix très bas (%s € alors que la moitié des annonces de la catégorie sont au-dessus de %s €)', new.price, round(med)));
  end if;
  if new.photo_hash is not null and exists (select 1 from public.listings
       where photo_hash = new.photo_hash and seller_id <> new.seller_id and id <> new.id) then
    why := array_append(why, 'photo déjà utilisée dans l’annonce d’un autre membre');
  end if;
  if (select count(*) from public.listings where seller_id = new.seller_id and created_at > now() - interval '1 hour') = 16 then
    why := array_append(why, 'plus de 15 annonces publiées en moins d’une heure');
  end if;
  if cardinality(why) > 0 then
    insert into public.reports (listing_id, reporter_id, reason, details, status)
    values (new.id, null, 'Autre', left('Détection automatique : ' || array_to_string(why, ' ; ') || '.', 1000), 'nouveau');
  end if;
  return new;
exception when others then
  raise warning 'détection non effectuée : %', sqlerrm;
  return new;
end $$;
revoke all on function public.flag_suspicious_listing() from public, anon, authenticated;
drop trigger if exists listings_flag_suspicious on public.listings;
create trigger listings_flag_suspicious after insert on public.listings
  for each row execute function public.flag_suspicious_listing();

select 'Qualité des annonces : détection et coups de cœur prêts' as info;
