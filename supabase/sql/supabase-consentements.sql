-- =====================================================================
-- ORLEOO — cases à cocher de l'inscription
--   • conditions d'utilisation + confidentialité (obligatoire) : date d'acceptation enregistrée
--   • e-mails « nouveautés et actualités » (facultatif) : active ou non l'e-mail du lundi
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-hebdo.sql. Peut être relancé sans risque.
-- =====================================================================
alter table public.profiles_private add column if not exists cgu_accepted_at timestamptz;
alter table public.profiles_private add column if not exists news_optin_at timestamptz;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare uname text; meta jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
        news boolean := coalesce(meta->>'news', '') = 'true';
begin
  uname := left(coalesce(nullif(trim(meta->>'name'), ''), split_part(new.email, '@', 1), 'membre'), 30);
  if exists (select 1 from public.profiles where lower(name) = lower(uname)) then
    uname := left(uname, 25) || '_' || substr(new.id::text, 1, 4);
  end if;
  insert into public.profiles (id, name, notify_digest) values (new.id, uname, news) on conflict (id) do nothing;
  insert into public.profiles_private (id, city, cgu_accepted_at, news_optin_at)
  values (new.id, left(nullif(trim(meta->>'city'), ''), 40),
          case when meta->>'cgu' = 'true' then now() end,
          case when news then now() end)
  on conflict (id) do nothing;
  return new;
end $$;

select 'Cases à cocher de l''inscription prêtes' as info;
