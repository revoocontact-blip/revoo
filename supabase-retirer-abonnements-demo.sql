-- =====================================================================
-- ORLEOO — retirer les abonnements de DÉMO (aucun argent réel n'a été payé)
-- À coller dans Supabase > SQL Editor > New query, puis « Run ».
-- Les comptes concernés repassent en formule gratuite : leurs épingles et
-- leur couleur de boutique sont retirées. Les annonces ne sont pas touchées.
-- =====================================================================
do $$
declare u uuid;
begin
  for u in delete from public.subscriptions where demo returning user_id loop
    perform public.apply_plan_limits(u);
  end loop;
end $$;

-- Vérification : doit afficher 0
select count(*) as abonnements_demo_restants from public.subscriptions where demo;
