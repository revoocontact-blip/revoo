-- =====================================================================
-- ORLEOO — la modération peut retirer les annonces de démonstration
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- Peut être relancé sans risque.
-- =====================================================================
alter table public.site_settings add column if not exists show_demo boolean not null default true;

create or replace function public.set_show_demo(p_show boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_perm('signalements');
  update public.site_settings set show_demo = coalesce(p_show, true), updated_by = auth.uid(), updated_at = now() where id = 1;
  perform public.log_action(case when p_show then 'Annonces de démonstration affichées' else 'Annonces de démonstration retirées' end, null, null, null);
end $$;
revoke all on function public.set_show_demo(boolean) from public, anon;
grant execute on function public.set_show_demo(boolean) to authenticated;

select 'Interrupteur des annonces de démonstration prêt' as info;
