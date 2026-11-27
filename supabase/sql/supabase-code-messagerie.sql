-- =====================================================================
-- ORLEOO — code de remise en main propre : dans la messagerie du site, plus par SMS
-- Le code s'affiche en haut de la conversation, chez l'acheteur seulement
-- (table order_codes, lisible uniquement par l'acheteur). Aucun SMS n'est envoyé.
-- À lancer APRÈS supabase-sms-limites.sql. Peut être relancé sans risque.
-- (Pour réactiver les SMS plus tard : relancer la partie « SMS » de supabase-sms-limites.sql.)
-- =====================================================================
drop trigger if exists order_codes_sms on public.order_codes;
select 'Code de remise : messagerie du site (SMS désactivé)' as info;
