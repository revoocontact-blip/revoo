-- =====================================================================
-- ORLEOO — corrections de l'audit de sécurité (novembre 2026)
-- Peut être relancé sans risque.
-- =====================================================================

-- 1. Messages : le destinataire peut seulement marquer « lu », jamais modifier le texte
revoke update on public.messages from anon, authenticated;
grant update (read_at) on public.messages to authenticated;

-- 2. Fonctions réservées aux membres connectés : plus accessibles aux visiteurs anonymes
do $$ declare f text; begin
  foreach f in array array['mark_alerts_seen()','my_listing_stats()','my_referrals()','set_referrer(text)',
    'referral_top(integer)','waitlist_stats()','waitlist_top(integer)','start_checkout(jsonb,text,text,text,text)'] loop
    begin execute format('revoke execute on function public.%s from public, anon', f);
    exception when undefined_function then null; end;
  end loop;
end $$;

-- 3. Article réservé pendant un paiement en cours : le vendeur ne peut ni le remettre en vente, ni le supprimer
create or replace function public.guard_reserved_listing()
returns trigger language plpgsql security definer set search_path = public as $$
declare lid uuid := coalesce(old.id, new.id);
begin
  if public.is_admin() then return coalesce(new, old); end if;
  if exists (select 1 from public.checkouts c, jsonb_array_elements(c.items) x
             where c.status = 'en_attente' and (x->>'listing')::uuid = lid) then
    if tg_op = 'DELETE' then raise exception 'Cet article est en cours de paiement : il ne peut pas être supprimé pour l’instant.'; end if;
    if new.status is distinct from old.status then raise exception 'Cet article est en cours de paiement : réessaie dans quelques minutes.'; end if;
  end if;
  return coalesce(new, old);
end $$;
revoke all on function public.guard_reserved_listing() from public, anon, authenticated;
drop trigger if exists listings_guard_reserved on public.listings;
create trigger listings_guard_reserved before update or delete on public.listings
  for each row execute function public.guard_reserved_listing();

select 'Corrections de sécurité appliquées' as info;
