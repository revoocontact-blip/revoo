-- =====================================================================
-- REVOO — équipe (fondateur + admins) et outils de modération autonomes
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS tous les autres scripts. (Peut être relancé sans risque.)
--
-- ⚠️ AVANT DE LANCER : tout en bas, remplace TON_ADRESSE_EMAIL par l'adresse
--    du compte Revoo qui sera le compte FONDATEUR (crée-le d'abord sur le site).
--
-- Ce que ça ajoute :
--   • Fondateur : nomme et retire les admins, règle l'annonce du site,
--     peut mettre en pause les nouvelles annonces.
--   • Admins (et fondateur) : chercher un membre, l'avertir, le suspendre
--     (1, 7, 30 jours ou définitivement), lever une suspension, gérer une
--     liste de mots interdits, voir le tableau de bord et le journal.
--   • Fiche membre complète : compte, coordonnées, annonces, commandes, échanges,
--     avis, signalements, conversations (lecture journalisée), notes internes.
--   • Chaque action de l'équipe est inscrite dans un journal (y compris les
--     décisions sur les commandes, échanges et avis).
--   • Le membre averti ou suspendu le voit sur le site et reçoit un e-mail.
-- =====================================================================

do $$ begin
  if to_regclass('public.admins') is null or to_regprocedure('public.is_admin()') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-signalements.sql, puis relance ce script.';
  end if;
  if to_regprocedure('public.protect_listing()') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-securite.sql, puis relance ce script.';
  end if;
  if to_regclass('public.trades') is null or to_regclass('public.orders') is null then
    raise exception 'ÉTAPE MANQUANTE : lance d''abord supabase-revoopay.sql et supabase-mainpropre-echange.sql.';
  end if;
end $$;

-- ---------- 1. ÉQUIPE : rôles ----------
alter table public.admins add column if not exists role text not null default 'admin';
alter table public.admins add column if not exists added_by uuid references auth.users(id) on delete set null;
alter table public.admins add column if not exists added_at timestamptz not null default now();
alter table public.admins drop constraint if exists admins_role_check;
alter table public.admins add constraint admins_role_check check (role in ('fondateur','admin'));
create unique index if not exists admins_un_seul_fondateur on public.admins ((true)) where role = 'fondateur';

create or replace function public.is_founder()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid() and role = 'fondateur');
$$;

-- L'équipe voit l'équipe ; personne n'écrit directement dans la table (tout passe par les fonctions)
drop policy if exists "voir son statut admin" on public.admins;
drop policy if exists "équipe : visible par l'équipe" on public.admins;
create policy "équipe : visible par l'équipe" on public.admins
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

-- ---------- 2. JOURNAL DES ACTIONS ----------
create table if not exists public.mod_log (
  id             bigint generated always as identity primary key,
  actor_id       uuid references auth.users(id) on delete set null,
  action         text not null,
  target_user    uuid references auth.users(id) on delete set null,
  target_listing uuid,
  details        text check (char_length(details) <= 1000),
  created_at     timestamptz not null default now()
);
create index if not exists mod_log_created_idx on public.mod_log (created_at desc);
alter table public.mod_log enable row level security;
drop policy if exists "journal : visible par l'équipe" on public.mod_log;
create policy "journal : visible par l'équipe" on public.mod_log for select to authenticated using (public.is_admin());

create or replace function public.log_action(p_action text, p_user uuid, p_listing uuid, p_details text)
returns void language sql security definer set search_path = public as $$
  insert into public.mod_log (actor_id, action, target_user, target_listing, details)
  values (auth.uid(), p_action, p_user, p_listing, left(p_details, 1000));
$$;

-- Les retraits / remises en ligne d'annonces par l'équipe sont journalisés automatiquement
create or replace function public.log_listing_moderation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() and new.status is distinct from old.status then
    if new.status = 'removed' then
      perform public.log_action('Annonce retirée', new.seller_id, new.id, new.title);
    elsif old.status = 'removed' then
      perform public.log_action('Annonce remise en ligne', new.seller_id, new.id, new.title);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists listings_log_moderation on public.listings;
create trigger listings_log_moderation after update on public.listings
  for each row execute function public.log_listing_moderation();

create or replace function public.log_report_moderation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if public.is_admin() and new.status is distinct from old.status and new.status <> 'nouveau' then
    perform public.log_action(case new.status when 'rejeté' then 'Signalement classé sans suite' else 'Signalement traité' end,
      (select seller_id from public.listings where id = new.listing_id), new.listing_id, new.reason);
  end if;
  return new;
end $$;
drop trigger if exists reports_log_moderation on public.reports;
create trigger reports_log_moderation after update on public.reports
  for each row execute function public.log_report_moderation();

-- ---------- 3. MESSAGES DE L'ÉQUIPE AUX MEMBRES (avertissements…) ----------
create table if not exists public.member_notices (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('avertissement','suspension','levee','info')),
  message    text not null check (char_length(message) between 3 and 1000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists member_notices_user_idx on public.member_notices (user_id, created_at desc);
alter table public.member_notices enable row level security;
drop policy if exists "messages équipe : les siens" on public.member_notices;
create policy "messages équipe : les siens" on public.member_notices
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

create or replace function public.mark_notices_read()
returns void language sql security definer set search_path = public as $$
  update public.member_notices set read_at = now() where user_id = auth.uid() and read_at is null;
$$;

-- E-mail (via Brevo, même clé que les autres e-mails). Ne bloque jamais l'action si l'envoi échoue.
create or replace function public.email_member(p_user uuid, p_subject text, p_text text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare to_email text; api_key text; safe text;
begin
  select email into to_email from auth.users where id = p_user;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  if to_email is null or api_key is null then return; end if;
  safe := replace(replace(replace(replace(p_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', api_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', 'Revoo', 'email', 'revoo.contact@gmail.com'),
      'to', jsonb_build_array(jsonb_build_object('email', to_email)),
      'subject', p_subject,
      'htmlContent', '<p>Bonjour,</p><p style="white-space:pre-line">' || safe || '</p><p>L’équipe Revoo</p>',
      'textContent', 'Bonjour,' || chr(10) || chr(10) || p_text || chr(10) || chr(10) || 'L’équipe Revoo'));
exception when others then
  raise warning 'e-mail non envoyé : %', sqlerrm;
end $$;

-- ---------- 4. SUSPENSIONS ----------
create table if not exists public.bans (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  reason     text not null check (char_length(reason) between 3 and 500),
  until      timestamptz,             -- vide = définitif
  banned_by  uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.bans enable row level security;
drop policy if exists "suspension : la sienne" on public.bans;
create policy "suspension : la sienne" on public.bans
  for select to authenticated using (user_id = auth.uid() or public.is_admin());

create or replace function public.is_banned(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bans where user_id = p_user and (until is null or until > now()));
$$;

-- Un compte suspendu ne peut plus publier, écrire, acheter, échanger ni laisser d'avis
create or replace function public.block_banned()
returns trigger language plpgsql security definer set search_path = public as $$
declare b record;
begin
  if auth.uid() is null or public.is_admin() then return new; end if;
  select * into b from public.bans where user_id = auth.uid() and (until is null or until > now());
  if b is not null then
    raise exception 'Ton compte est suspendu%. Motif : %',
      case when b.until is null then '' else ' jusqu’au ' || to_char(b.until at time zone 'Europe/Paris', 'DD/MM/YYYY à HH24:MI') end, b.reason;
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['listings','messages','conversations','orders','trades','reviews'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_block_banned', t);
    execute format('create trigger %I before insert on public.%I for each row execute function public.block_banned()', t || '_block_banned', t);
  end loop;
end $$;
drop trigger if exists listings_block_banned_upd on public.listings;
create trigger listings_block_banned_upd before update on public.listings
  for each row execute function public.block_banned();

create or replace function public.ban_member(p_user uuid, p_days int, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_until timestamptz; n int; who text;
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  if p_user = auth.uid() then raise exception 'Tu ne peux pas te suspendre toi-même'; end if;
  if exists (select 1 from public.admins where user_id = p_user) then
    raise exception 'Ce compte fait partie de l’équipe : le fondateur doit d’abord le retirer de l’équipe';
  end if;
  if p_reason is null or char_length(trim(p_reason)) < 3 then raise exception 'Indique le motif de la suspension'; end if;
  if p_days is not null and (p_days < 1 or p_days > 365) then raise exception 'Durée invalide'; end if;
  select name into who from public.profiles where id = p_user;
  if who is null then raise exception 'Membre introuvable'; end if;
  v_until := case when p_days is null then null else now() + make_interval(days => p_days) end;
  insert into public.bans (user_id, reason, until, banned_by) values (p_user, trim(p_reason), v_until, auth.uid())
  on conflict (user_id) do update set reason = excluded.reason, until = excluded.until, banned_by = excluded.banned_by, created_at = now();
  -- ses annonces en ligne sont retirées, ses propositions d'échange en attente tombent
  update public.listings set status = 'removed' where seller_id = p_user and status = 'active';
  get diagnostics n = row_count;
  update public.trades set status = 'cancelled', updated_at = now() where p_user in (proposer_id, receiver_id) and status = 'proposed';
  insert into public.member_notices (user_id, kind, message, created_by)
  values (p_user, 'suspension',
    'Ton compte est suspendu' || case when v_until is null then ' définitivement' else ' pendant ' || p_days || ' jour(s)' end
    || '. Motif : ' || trim(p_reason), auth.uid());
  perform public.log_action('Membre suspendu' || case when v_until is null then ' (définitif)' else ' (' || p_days || ' j)' end,
    p_user, null, trim(p_reason) || ' · ' || n || ' annonce(s) retirée(s)');
  perform public.email_member(p_user, 'Ton compte Revoo est suspendu',
    'Ton compte Revoo est suspendu' || case when v_until is null then ' définitivement' else ' jusqu’au ' || to_char(v_until at time zone 'Europe/Paris', 'DD/MM/YYYY') end
    || '.' || chr(10) || 'Motif : ' || trim(p_reason) || chr(10) || chr(10)
    || 'Tes achats et ventes déjà en cours restent protégés. Si tu penses qu’il s’agit d’une erreur, réponds à cet e-mail.');
end $$;

create or replace function public.unban_member(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  delete from public.bans where user_id = p_user;
  if not found then raise exception 'Ce membre n’est pas suspendu'; end if;
  insert into public.member_notices (user_id, kind, message, created_by)
  values (p_user, 'levee', 'Ta suspension est levée : tu peux de nouveau utiliser Revoo normalement. Tes anciennes annonces peuvent être remises en ligne par l’équipe sur demande.', auth.uid());
  perform public.log_action('Suspension levée', p_user, null, null);
  perform public.email_member(p_user, 'Ta suspension Revoo est levée', 'Ta suspension est levée : tu peux de nouveau utiliser Revoo normalement.');
end $$;

create or replace function public.warn_member(p_user uuid, p_message text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  if p_message is null or char_length(trim(p_message)) < 5 then raise exception 'Écris le message de l’avertissement'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'Membre introuvable'; end if;
  insert into public.member_notices (user_id, kind, message, created_by) values (p_user, 'avertissement', left(trim(p_message), 1000), auth.uid());
  perform public.log_action('Avertissement envoyé', p_user, null, left(trim(p_message), 300));
  perform public.email_member(p_user, 'Message de l’équipe Revoo', left(trim(p_message), 1000));
end $$;

-- ---------- 5. RECHERCHE DE MEMBRES ----------
create or replace function public.find_members(p_q text)
returns table (id uuid, name text, created_at timestamptz, listings_active int, listings_removed int, sales int,
               reports int, warnings int, banned_until timestamptz, banned boolean, ban_reason text, team_role text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  return query
  select p.id, p.name, p.created_at,
    (select count(*)::int from public.listings l where l.seller_id = p.id and l.status = 'active'),
    (select count(*)::int from public.listings l where l.seller_id = p.id and l.status = 'removed'),
    (select count(*)::int from public.orders o where o.seller_id = p.id and o.status = 'received'),
    (select count(*)::int from public.reports r join public.listings l on l.id = r.listing_id where l.seller_id = p.id),
    (select count(*)::int from public.member_notices n where n.user_id = p.id and n.kind = 'avertissement'),
    b.until, (b.user_id is not null and (b.until is null or b.until > now())), b.reason,
    (select a.role from public.admins a where a.user_id = p.id)
  from public.profiles p
  left join public.bans b on b.user_id = p.id
  where coalesce(trim(p_q), '') = '' or p.name ilike '%' || replace(replace(trim(p_q), '%', ''), '_', '\_') || '%'
  order by (b.user_id is not null) desc, p.created_at desc
  limit 40;
end $$;

-- ---------- 6. MOTS INTERDITS DANS LES ANNONCES ----------
create table if not exists public.banned_words (
  word       text primary key check (word ~ '^[a-z0-9àâäéèêëïîôöùûüç'' -]{2,40}$'),
  added_by   uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.banned_words enable row level security;
drop policy if exists "mots interdits : équipe" on public.banned_words;
create policy "mots interdits : équipe" on public.banned_words for select to authenticated using (public.is_admin());

create or replace function public.add_banned_word(p_word text)
returns void language plpgsql security definer set search_path = public as $$
declare w text := lower(trim(p_word));
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  if w !~ '^[a-z0-9àâäéèêëïîôöùûüç'' -]{2,40}$' then raise exception 'Mot invalide : 2 à 40 lettres, chiffres, espaces ou tirets'; end if;
  insert into public.banned_words (word, added_by) values (w, auth.uid()) on conflict do nothing;
  perform public.log_action('Mot interdit ajouté', null, null, w);
end $$;
create or replace function public.remove_banned_word(p_word text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  delete from public.banned_words where word = lower(trim(p_word));
  perform public.log_action('Mot interdit retiré', null, null, lower(trim(p_word)));
end $$;

create or replace function public.check_banned_words()
returns trigger language plpgsql security definer set search_path = public as $$
declare txt text; w text;
begin
  if public.is_admin() then return new; end if;
  if tg_op = 'UPDATE' and new.title is not distinct from old.title and new.description is not distinct from old.description
     and new.brand is not distinct from old.brand then return new; end if;
  txt := lower(coalesce(new.title, '') || ' ' || coalesce(new.description, '') || ' ' || coalesce(new.brand, ''));
  select word into w from public.banned_words where txt ~ ('\m' || word || '\M') limit 1;
  if w is not null then
    raise exception 'Ton annonce contient un mot non autorisé sur Revoo (« % »). Modifie-la puis réessaie.', w;
  end if;
  return new;
end $$;
drop trigger if exists listings_banned_words on public.listings;
create trigger listings_banned_words before insert or update on public.listings
  for each row execute function public.check_banned_words();

-- ---------- 7. RÉGLAGES DU SITE (fondateur) ----------
create table if not exists public.site_settings (
  id                 int primary key default 1 check (id = 1),
  announcement       text check (char_length(announcement) <= 300),
  announcement_level text not null default 'info' check (announcement_level in ('info','alerte')),
  pause_listings     boolean not null default false,
  updated_by         uuid references auth.users(id) on delete set null,
  updated_at         timestamptz not null default now()
);
insert into public.site_settings (id) values (1) on conflict do nothing;
alter table public.site_settings enable row level security;
drop policy if exists "réglages : lecture publique" on public.site_settings;
create policy "réglages : lecture publique" on public.site_settings for select to anon, authenticated using (true);

create or replace function public.set_site_settings(p_announcement text, p_level text, p_pause boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_founder() then raise exception 'Réservé au fondateur'; end if;
  if p_level not in ('info','alerte') then raise exception 'Niveau invalide'; end if;
  update public.site_settings set announcement = nullif(left(trim(coalesce(p_announcement, '')), 300), ''),
    announcement_level = p_level, pause_listings = coalesce(p_pause, false), updated_by = auth.uid(), updated_at = now() where id = 1;
  perform public.log_action('Réglages du site modifiés', null, null,
    'Annonce : ' || coalesce(nullif(trim(p_announcement), ''), '(aucune)') || ' · pause des annonces : ' || case when p_pause then 'oui' else 'non' end);
end $$;

create or replace function public.block_when_paused()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() and (select pause_listings from public.site_settings where id = 1) then
    raise exception 'Les nouvelles annonces sont mises en pause quelques instants par l’équipe Revoo. Réessaie un peu plus tard.';
  end if;
  return new;
end $$;
drop trigger if exists listings_pause on public.listings;
create trigger listings_pause before insert on public.listings for each row execute function public.block_when_paused();

-- ---------- 8. GESTION DE L'ÉQUIPE (fondateur) ----------
create or replace function public.team_list()
returns table (user_id uuid, name text, role text, added_at timestamptz, actions_30j int, last_action timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  return query
  select a.user_id, coalesce(p.name, '(compte supprimé)'), a.role, a.added_at,
    (select count(*)::int from public.mod_log m where m.actor_id = a.user_id and m.created_at > now() - interval '30 days'),
    (select max(m.created_at) from public.mod_log m where m.actor_id = a.user_id)
  from public.admins a left join public.profiles p on p.id = a.user_id
  order by (a.role = 'fondateur') desc, a.added_at;
end $$;

create or replace function public.team_add(p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare target uuid; n int;
begin
  if not public.is_founder() then raise exception 'Seul le fondateur peut ajouter un admin'; end if;
  select id into target from public.profiles where lower(name) = lower(trim(ltrim(p_name, '@')));
  if target is null then raise exception 'Aucun compte avec l’identifiant « % »', trim(p_name); end if;
  if exists (select 1 from public.admins where user_id = target) then raise exception 'Ce compte fait déjà partie de l’équipe'; end if;
  if public.is_banned(target) then raise exception 'Ce compte est suspendu'; end if;
  select count(*) into n from public.orders where target in (buyer_id, seller_id) and status in ('paid','shipped','problem');
  if n > 0 then raise exception 'Ce compte a des achats ou ventes en cours : utilise un compte dédié à l’équipe'; end if;
  insert into public.admins (user_id, role, added_by) values (target, 'admin', auth.uid());
  -- un compte d'équipe n'a pas d'annonces en ligne
  update public.listings set status = 'removed' where seller_id = target and status = 'active';
  perform public.log_action('Admin ajouté', target, null, trim(p_name));
end $$;

create or replace function public.team_remove(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_founder() then raise exception 'Seul le fondateur peut retirer un admin'; end if;
  if exists (select 1 from public.admins where user_id = p_user and role = 'fondateur') then
    raise exception 'Le compte fondateur ne peut pas être retiré';
  end if;
  delete from public.admins where user_id = p_user;
  if not found then raise exception 'Ce compte ne fait pas partie de l’équipe'; end if;
  perform public.log_action('Admin retiré', p_user, null, null);
end $$;

-- Désigner le fondateur : UNIQUEMENT depuis le SQL Editor de Supabase (jamais depuis le site)
create or replace function public.set_founder(p_email text)
returns text language plpgsql security definer set search_path = public, auth as $$
declare target uuid;
begin
  select id into target from auth.users where lower(email) = lower(trim(p_email));
  if target is null then
    return 'AUCUN COMPTE avec l''adresse ' || p_email || ' : crée d''abord ce compte sur le site, puis relance.';
  end if;
  update public.admins set role = 'admin' where role = 'fondateur' and user_id <> target;
  insert into public.admins (user_id, role) values (target, 'fondateur')
  on conflict (user_id) do update set role = 'fondateur';
  return 'OK : ' || p_email || ' est le compte fondateur.';
end $$;

-- ---------- 9. TABLEAU DE BORD ----------
create or replace function public.admin_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  return jsonb_build_object(
    'membres',            (select count(*) from public.profiles),
    'membres_7j',         (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    'annonces',           (select count(*) from public.listings where status = 'active'),
    'annonces_7j',        (select count(*) from public.listings where created_at > now() - interval '7 days'),
    'vendus',             (select count(*) from public.listings where status = 'sold'),
    'retirees',           (select count(*) from public.listings where status = 'removed'),
    'signalements',       (select count(*) from public.reports where status = 'nouveau'),
    'commandes_en_cours', (select count(*) from public.orders where status in ('paid','shipped')),
    'litiges',            (select count(*) from public.orders where status = 'problem') + (select count(*) from public.trades where status = 'problem'),
    'echanges',           (select count(*) from public.trades where status in ('accepted','completed')),
    'abonnes',            (select count(*) from public.subscriptions where current_period_end > now()),
    'suspendus',          (select count(*) from public.bans where until is null or until > now()));
exception when undefined_table then
  return jsonb_build_object('erreur', 'tables manquantes');
end $$;

-- ---------- 10. DROITS ----------
revoke all on function public.set_founder(text) from public, anon, authenticated;
revoke all on function public.log_action(text, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.email_member(uuid, text, text) from public, anon, authenticated;
revoke all on function public.block_banned() from public, anon, authenticated;
revoke all on function public.block_when_paused() from public, anon, authenticated;
revoke all on function public.check_banned_words() from public, anon, authenticated;
revoke all on function public.log_listing_moderation() from public, anon, authenticated;
revoke all on function public.log_report_moderation() from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array['ban_member(uuid,int,text)','unban_member(uuid)','warn_member(uuid,text)','find_members(text)',
    'add_banned_word(text)','remove_banned_word(text)','set_site_settings(text,text,boolean)','team_list()','team_add(text)',
    'team_remove(uuid)','admin_stats()','mark_notices_read()','is_founder()','is_banned(uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;


-- ---------- 10 bis. FICHE MEMBRE COMPLÈTE, CONVERSATIONS, NOTES INTERNES ----------
-- Notes internes : visibles uniquement par l'équipe (jamais par le membre)
create table if not exists public.member_notes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  author_id  uuid references auth.users(id) on delete set null,
  body       text not null check (char_length(body) between 2 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists member_notes_user_idx on public.member_notes (user_id, created_at desc);
alter table public.member_notes enable row level security;
drop policy if exists "notes : équipe" on public.member_notes;
create policy "notes : équipe" on public.member_notes for select to authenticated using (public.is_admin());

create or replace function public.add_member_note(p_user uuid, p_body text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  if p_body is null or char_length(trim(p_body)) < 2 then raise exception 'Écris la note'; end if;
  insert into public.member_notes (user_id, author_id, body) values (p_user, auth.uid(), left(trim(p_body), 1000));
  perform public.log_action('Note interne ajoutée', p_user, null, left(trim(p_body), 200));
end $$;

-- Tout ce qu'il faut savoir sur un membre, en un seul appel
create or replace function public.member_detail(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare r jsonb; nm text;
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  select name into nm from public.profiles where id = p_user;
  if nm is null then raise exception 'Membre introuvable'; end if;
  -- consultation journalisée (au plus une fois par heure et par membre)
  if not exists (select 1 from public.mod_log where actor_id = auth.uid() and target_user = p_user
                 and action = 'Fiche membre consultée' and created_at > now() - interval '1 hour') then
    perform public.log_action('Fiche membre consultée', p_user, null, null);
  end if;
  select jsonb_build_object(
    'profil', (select jsonb_build_object('id', p.id, 'name', p.name, 'bio', p.bio, 'created_at', p.created_at, 'avatar_url', p.avatar_url,
                 'vacation', p.vacation, 'username_changes', p.username_changes)
               from public.profiles p where p.id = p_user),
    'compte', (select jsonb_build_object('email', u.email, 'email_confirme', u.email_confirmed_at is not null,
                 'derniere_connexion', u.last_sign_in_at, 'inscrit_le', u.created_at)
               from auth.users u where u.id = p_user),
    'prive', (select jsonb_build_object('prenom', x.first_name, 'nom', x.last_name, 'ville', x.city)
              from public.profiles_private x where x.id = p_user),
    'abonnement', (select jsonb_build_object('plan', s.plan, 'fin', s.current_period_end, 'resilie', s.cancel_at_period_end, 'demo', s.demo)
                   from public.subscriptions s where s.user_id = p_user and s.current_period_end > now()),
    'suspension', (select jsonb_build_object('motif', b.reason, 'jusqu_au', b.until, 'depuis', b.created_at)
                   from public.bans b where b.user_id = p_user and (b.until is null or b.until > now())),
    'annonces', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'title', l.title, 'price', l.price, 'status', l.status,
                   'created_at', l.created_at, 'photo', l.photos[1]) order by l.created_at desc)
                 from (select * from public.listings where seller_id = p_user order by created_at desc limit 60) l), '[]'),
    'commandes', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'title', o.title, 'price', o.price, 'status', o.status,
                   'delivery', o.delivery, 'created_at', o.created_at, 'problem', o.problem, 'tracking', o.tracking, 'demo', o.demo,
                   'role', case when o.buyer_id = p_user then 'achat' else 'vente' end,
                   'autre_id', case when o.buyer_id = p_user then o.seller_id else o.buyer_id end,
                   'autre', (select name from public.profiles where id = case when o.buyer_id = p_user then o.seller_id else o.buyer_id end))
                   order by o.created_at desc)
                 from (select * from public.orders where p_user in (buyer_id, seller_id) order by created_at desc limit 60) o), '[]'),
    'echanges', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'status', t.status, 'created_at', t.created_at, 'topup', t.topup,
                   'donne', case when t.proposer_id = p_user then t.offered_title else t.wanted_title end,
                   'recoit', case when t.proposer_id = p_user then t.wanted_title else t.offered_title end,
                   'problem', t.problem,
                   'autre_id', case when t.proposer_id = p_user then t.receiver_id else t.proposer_id end,
                   'autre', (select name from public.profiles where id = case when t.proposer_id = p_user then t.receiver_id else t.proposer_id end))
                   order by t.created_at desc)
                 from (select * from public.trades where p_user in (proposer_id, receiver_id) order by created_at desc limit 40) t), '[]'),
    'signalements_recus', coalesce((select jsonb_agg(jsonb_build_object('reason', r.reason, 'details', r.details, 'status', r.status,
                   'created_at', r.created_at, 'listing', l.title) order by r.created_at desc)
                 from public.reports r join public.listings l on l.id = r.listing_id where l.seller_id = p_user), '[]'),
    'signalements_faits', (select count(*) from public.reports where reporter_id = p_user),
    'avis_recus', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'rating', v.rating, 'comment', v.comment, 'created_at', v.created_at,
                   'auteur', (select name from public.profiles where id = v.buyer_id)) order by v.created_at desc)
                 from public.reviews v where v.seller_id = p_user), '[]'),
    'note_moyenne', (select round(avg(rating)::numeric, 1) from public.reviews where seller_id = p_user),
    'conversations', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'created_at', c.created_at, 'last', c.last_message_at,
                   'listing', (select title from public.listings where id = c.listing_id),
                   'autre_id', case when c.buyer_id = p_user then c.seller_id else c.buyer_id end,
                   'autre', (select name from public.profiles where id = case when c.buyer_id = p_user then c.seller_id else c.buyer_id end),
                   'messages', (select count(*) from public.messages m where m.conversation_id = c.id)) order by c.last_message_at desc)
                 from (select * from public.conversations where p_user in (buyer_id, seller_id) order by last_message_at desc limit 40) c), '[]'),
    'messages_24h', (select count(*) from public.messages where sender_id = p_user and created_at > now() - interval '24 hours'),
    'messages_equipe', coalesce((select jsonb_agg(jsonb_build_object('kind', n.kind, 'message', n.message, 'created_at', n.created_at, 'lu', n.read_at is not null)
                   order by n.created_at desc) from public.member_notices n where n.user_id = p_user), '[]'),
    'notes', coalesce((select jsonb_agg(jsonb_build_object('body', x.body, 'created_at', x.created_at,
                   'auteur', (select name from public.profiles where id = x.author_id)) order by x.created_at desc)
                 from public.member_notes x where x.user_id = p_user), '[]'),
    'historique', coalesce((select jsonb_agg(jsonb_build_object('action', m.action, 'details', m.details, 'created_at', m.created_at,
                   'par', (select name from public.profiles where id = m.actor_id)) order by m.created_at desc)
                 from (select * from public.mod_log where target_user = p_user and action <> 'Fiche membre consultée' order by created_at desc limit 50) m), '[]')
  ) into r;
  return r;
end $$;

-- Lire une conversation (litige, arnaque signalée…). Chaque lecture est inscrite au journal.
create or replace function public.read_conversation(p_conv uuid)
returns table (sender text, sender_id uuid, body text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  select * into c from public.conversations where id = p_conv;
  if c is null then raise exception 'Conversation introuvable'; end if;
  perform public.log_action('Conversation consultée', c.seller_id, c.listing_id,
    'entre @' || coalesce((select name from public.profiles where id = c.buyer_id), '?') || ' et @' || coalesce((select name from public.profiles where id = c.seller_id), '?'));
  return query select coalesce(p.name, 'membre supprimé'), m.sender_id, m.body, m.created_at
    from public.messages m left join public.profiles p on p.id = m.sender_id
    where m.conversation_id = p_conv order by m.created_at limit 500;
end $$;

-- Conversation liée à une commande ou à un échange (pour trancher un litige)
create or replace function public.conversation_between(p_a uuid, p_b uuid)
returns uuid language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Revoo'; end if;
  return (select id from public.conversations
          where (buyer_id = p_a and seller_id = p_b) or (buyer_id = p_b and seller_id = p_a)
          order by last_message_at desc limit 1);
end $$;

-- Décisions sur les commandes, échanges et avis : journalisées automatiquement
create or replace function public.log_deal_moderation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then return coalesce(new, old); end if;
  if tg_table_name = 'orders' and new.status is distinct from old.status then
    perform public.log_action(case new.status when 'cancelled' then 'Commande annulée et remboursée' when 'received' then 'Litige clos en faveur du vendeur'
      else 'Commande : statut ' || new.status end, new.buyer_id, new.listing_id, new.title || ' · ' || new.price || ' €');
  elsif tg_table_name = 'trades' and new.status is distinct from old.status then
    perform public.log_action(case new.status when 'cancelled' then 'Échange annulé et remboursé' when 'completed' then 'Échange validé par l’équipe'
      else 'Échange : statut ' || new.status end, new.proposer_id, null, new.offered_title || ' ⇄ ' || new.wanted_title);
  elsif tg_table_name = 'reviews' and tg_op = 'DELETE' then
    perform public.log_action('Avis supprimé', old.seller_id, null, old.rating || '/5 · ' || coalesce(left(old.comment, 150), ''));
  end if;
  return coalesce(new, old);
end $$;
drop trigger if exists orders_log_moderation on public.orders;
create trigger orders_log_moderation after update on public.orders for each row execute function public.log_deal_moderation();
drop trigger if exists trades_log_moderation on public.trades;
create trigger trades_log_moderation after update on public.trades for each row execute function public.log_deal_moderation();
drop trigger if exists reviews_log_moderation on public.reviews;
create trigger reviews_log_moderation after delete on public.reviews for each row execute function public.log_deal_moderation();

revoke all on function public.log_deal_moderation() from public, anon, authenticated;
do $$ declare f text; begin
  foreach f in array array['add_member_note(uuid,text)','member_detail(uuid)','read_conversation(uuid)','conversation_between(uuid,uuid)'] loop
    execute 'revoke all on function public.' || f || ' from public, anon';
    execute 'grant execute on function public.' || f || ' to authenticated';
  end loop;
end $$;

-- ---------- 11. TON COMPTE FONDATEUR ----------
-- Remplace TON_ADRESSE_EMAIL par l'adresse de ton compte fondateur (gardes les guillemets).
select public.set_founder('TON_ADRESSE_EMAIL') as resultat;

-- Vérification : l'équipe actuelle
select a.role, u.email from public.admins a join auth.users u on u.id = a.user_id order by a.role desc;
select coalesce(string_agg(tablename, ', '), 'aucune') as tables_sans_protection
from pg_tables where schemaname = 'public' and not rowsecurity;
