-- =====================================================================
-- REVOO — bannière du profil public
-- À coller dans Supabase > SQL Editor > New query, puis « Run ». (Peut être relancé.)
-- Les images sont rangées dans le stockage « avatars » (dossier de chaque membre).
-- =====================================================================
alter table public.profiles add column if not exists banner_url text check (char_length(banner_url) <= 500);
update storage.buckets set file_size_limit = 2097152 where id = 'avatars';
