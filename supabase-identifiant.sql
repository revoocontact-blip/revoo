-- =====================================================================
-- REVOO — règle de changement d'identifiant
-- 2 changements maximum, 30 jours d'attente avant chacun (depuis l'inscription
-- ou depuis le dernier changement). Ensuite l'identifiant est définitif.
-- À coller dans Supabase > SQL Editor > New query, puis « Run ». (Peut être relancé.)
-- =====================================================================
alter table public.profiles add column if not exists username_changes int not null default 0;
alter table public.profiles add column if not exists username_changed_at timestamptz;

create or replace function public.enforce_username_rule()
returns trigger language plpgsql security definer set search_path = public as $$
declare next_ok timestamptz;
begin
  if new.name is distinct from old.name and not public.is_admin() then
    if old.username_changes >= 2 then
      raise exception 'Tu as déjà modifié ton identifiant 2 fois : il est maintenant définitif';
    end if;
    next_ok := coalesce(old.username_changed_at, old.created_at) + interval '30 days';
    if now() < next_ok then
      raise exception 'Tu pourras modifier ton identifiant à partir du %', to_char(next_ok at time zone 'Europe/Paris', 'DD/MM/YYYY');
    end if;
    new.username_changes := old.username_changes + 1;
    new.username_changed_at := now();
  else
    -- personne ne peut modifier ces compteurs à la main
    new.username_changes := old.username_changes;
    new.username_changed_at := old.username_changed_at;
  end if;
  return new;
end $$;

drop trigger if exists profiles_username_rule on public.profiles;
create trigger profiles_username_rule before update on public.profiles
  for each row execute function public.enforce_username_rule();
