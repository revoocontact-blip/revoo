-- =====================================================================
-- ORLEOO — mode vitrine : liste « Me prévenir » à l'ouverture des achats
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- Peut être relancé sans risque.
-- =====================================================================
create table if not exists public.launch_waitlist (
  user_id    uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  listing_id uuid not null references public.listings(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id)
);
alter table public.launch_waitlist enable row level security;

drop policy if exists "je m'inscris" on public.launch_waitlist;
create policy "je m'inscris" on public.launch_waitlist
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "je vois mes demandes" on public.launch_waitlist;
create policy "je vois mes demandes" on public.launch_waitlist
  for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists "je retire une demande" on public.launch_waitlist;
create policy "je retire une demande" on public.launch_waitlist
  for delete to authenticated using (user_id = auth.uid());

-- Pour l'équipe : combien de personnes attendent chaque annonce
create or replace function public.waitlist_stats()
returns table (membres bigint, demandes bigint) language sql stable security definer set search_path = public as $$
  select count(distinct user_id), count(*) from public.launch_waitlist where public.is_admin();
$$;
grant execute on function public.waitlist_stats() to authenticated;

select 'Mode vitrine prêt : liste « Me prévenir » créée' as info;
