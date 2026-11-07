-- =====================================================================
-- REVOO — paramètres du profil : mode vacances
-- À coller dans Supabase > SQL Editor > New query, puis « Run ».
-- (Peut être relancé sans risque.)
-- =====================================================================
alter table public.profiles add column if not exists vacation boolean not null default false;
