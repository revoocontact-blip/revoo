-- =====================================================================
-- ORLEOO — badge « Vendeur fondateur »
-- Les 100 premiers membres qui ont 5 annonces publiées (en ligne ou vendues)
-- gagnent le badge à vie, avec leur numéro (n°1 à n°100).
-- Attribution automatique par le serveur : impossible à tricher depuis le site.
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- Peut être relancé sans risque.
-- =====================================================================
create table if not exists public.founding_sellers (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  rank       int not null unique check (rank between 1 and 100),
  awarded_at timestamptz not null default now()
);
alter table public.founding_sellers enable row level security;
drop policy if exists "vendeurs fondateurs : publics" on public.founding_sellers;
create policy "vendeurs fondateurs : publics" on public.founding_sellers for select using (true);
revoke insert, update, delete on public.founding_sellers from anon, authenticated;

-- Places restantes (affichées sur le site)
create or replace function public.founding_places()
returns int language sql stable security definer set search_path = public as $$
  select greatest(0, 100 - (select count(*)::int from public.founding_sellers));
$$;
grant execute on function public.founding_places() to anon, authenticated;

-- Attribution dès la 5e annonce publiée
create or replace function public.award_founding_seller()
returns trigger language plpgsql security definer set search_path = public as $$
declare n int; r int;
begin
  if new.status not in ('active','sold') then return new; end if;
  if exists (select 1 from public.founding_sellers where user_id = new.seller_id) then return new; end if;
  if (select count(*) from public.listings where seller_id = new.seller_id and status in ('active','sold')) < 5 then return new; end if;
  perform pg_advisory_xact_lock(hashtext('orleoo_founding_sellers'));   -- jamais plus de 100, même en même temps
  select count(*), coalesce(max(rank), 0) into n, r from public.founding_sellers;
  if n >= 100 or r >= 100 then return new; end if;
  insert into public.founding_sellers (user_id, rank) values (new.seller_id, r + 1) on conflict do nothing;
  begin
    perform public.send_revoo_email(new.seller_id,
      'Tu es Vendeur fondateur n°' || (r + 1) || ' d’Orleoo',
      'Bravo ! Avec tes 5 annonces, tu fais partie des 100 premiers vendeurs d’Orleoo. Ton badge « Vendeur fondateur n°' || (r + 1) || ' » est à toi pour toujours : il s’affiche sur ton profil et sur tes annonces.',
      'https://revoocontact-blip.github.io/revoo/#/compte/annonces');
  exception when others then null;
  end;
  return new;
exception when others then
  raise warning 'badge vendeur fondateur non attribué : %', sqlerrm;
  return new;
end $$;
revoke all on function public.award_founding_seller() from public, anon, authenticated;
drop trigger if exists listings_award_founding on public.listings;
create trigger listings_award_founding after insert or update of status on public.listings
  for each row execute function public.award_founding_seller();

-- Rattrapage : membres qui ont déjà 5 annonces (dans l'ordre où ils ont atteint la 5e)
insert into public.founding_sellers (user_id, rank, awarded_at)
select seller_id, (select coalesce(max(rank), 0) from public.founding_sellers) + row_number() over (order by fifth), fifth
from (
  select seller_id, (array_agg(created_at order by created_at))[5] as fifth
  from public.listings where status in ('active','sold')
  group by seller_id having count(*) >= 5
) x
where not exists (select 1 from public.founding_sellers f where f.user_id = x.seller_id)
order by fifth
limit greatest(0, 100 - (select count(*) from public.founding_sellers))
on conflict do nothing;

select 'Vendeurs fondateurs : ' || (select count(*) from public.founding_sellers) || ' badge(s), '
       || public.founding_places() || ' place(s) restante(s)' as info;
