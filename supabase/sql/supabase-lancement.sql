-- =====================================================================
-- ORLEOO — lancement : liens suivis (d'où viennent les inscrits),
-- date d'ouverture des achats et liste e-mail des visiteurs
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-verrou-vitrine.sql. Peut être relancé sans risque.
-- =====================================================================

-- ---------- 1. LIENS SUIVIS ----------
-- Un lien suivi = l'adresse du site + ?src=nom (ex. ?src=insta-post-0312)
create table if not exists public.tracked_links (
  source     text primary key check (source ~ '^[a-z0-9-]{1,40}$'),
  label      text not null check (char_length(label) between 1 and 80),
  created_at timestamptz not null default now()
);
alter table public.tracked_links enable row level security;
drop policy if exists "liens suivis : équipe" on public.tracked_links;
create policy "liens suivis : équipe" on public.tracked_links for select to authenticated using (public.is_admin());
revoke insert, update, delete on public.tracked_links from anon, authenticated;

create table if not exists public.source_visits (
  source text not null check (source ~ '^[a-z0-9-]{1,40}$'),
  day    date not null default current_date,
  visits int  not null default 0,
  primary key (source, day)
);
alter table public.source_visits enable row level security;   -- lecture via source_stats seulement

create table if not exists public.signup_sources (
  user_id    uuid primary key references public.profiles(id) on delete cascade,
  source     text not null check (source ~ '^[a-z0-9-]{1,40}$'),
  created_at timestamptz not null default now()
);
alter table public.signup_sources enable row level security;   -- lecture via source_stats seulement

-- Une visite arrivée par un lien suivi (une fois par visiteur et par session, côté site)
create or replace function public.track_visit(p_src text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_src is null or p_src !~ '^[a-z0-9-]{1,40}$' then return; end if;
  if (select coalesce(sum(visits), 0) from public.source_visits where day = current_date) > 50000 then return; end if;   -- garde-fou
  insert into public.source_visits (source, day, visits) values (p_src, current_date, 1)
  on conflict (source, day) do update set visits = source_visits.visits + 1;
end $$;
grant execute on function public.track_visit(text) to anon, authenticated;

-- Juste après l'inscription : le lien par lequel la personne est arrivée
create or replace function public.set_signup_source(p_src text)
returns boolean language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); born timestamptz;
begin
  if me is null or p_src is null or p_src !~ '^[a-z0-9-]{1,40}$' then return false; end if;
  select created_at into born from public.profiles where id = me;
  if born is null or born < now() - interval '2 days' then return false; end if;   -- seulement les nouveaux comptes
  insert into public.signup_sources (user_id, source) values (me, p_src) on conflict do nothing;
  return true;
end $$;
revoke all on function public.set_signup_source(text) from public, anon;
grant execute on function public.set_signup_source(text) to authenticated;

-- Créer un lien suivi depuis le tableau de bord
create or replace function public.create_tracked_link(p_label text)
returns text language plpgsql security definer set search_path = public as $$
declare base text; src text; n int := 1;
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Orleoo'; end if;
  if coalesce(trim(p_label), '') = '' then raise exception 'Donne un nom au lien'; end if;
  base := left(trim(both '-' from regexp_replace(public.norm_txt(p_label), '[^a-z0-9]+', '-', 'g')), 36);
  if base = '' then base := 'lien'; end if;
  src := base;
  while exists (select 1 from public.tracked_links where source = src) loop n := n + 1; src := base || '-' || n; end loop;
  insert into public.tracked_links (source, label) values (src, left(trim(p_label), 80));
  return src;
end $$;
revoke all on function public.create_tracked_link(text) from public, anon;
grant execute on function public.create_tracked_link(text) to authenticated;

create or replace function public.delete_tracked_link(p_source text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Orleoo'; end if;
  delete from public.tracked_links where source = p_source;
end $$;
revoke all on function public.delete_tracked_link(text) from public, anon;
grant execute on function public.delete_tracked_link(text) to authenticated;

-- Chiffres par lien : visites, inscrits, vendeurs, vendeurs fondateurs, e-mails laissés
create or replace function public.source_stats()
returns table (source text, label text, visites bigint, inscrits bigint, vendeurs bigint, fondateurs bigint, emails bigint, cree_le timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Orleoo'; end if;
  return query
  with s as (
    select t.source from public.tracked_links t
    union select v.source from public.source_visits v
    union select u.source from public.signup_sources u)
  select s.source, coalesce(t.label, s.source),
    coalesce((select sum(v.visits) from public.source_visits v where v.source = s.source), 0)::bigint,
    (select count(*) from public.signup_sources u where u.source = s.source),
    (select count(*) from public.signup_sources u where u.source = s.source
       and exists (select 1 from public.listings l where l.seller_id = u.user_id and l.status in ('active','sold'))),
    (select count(*) from public.signup_sources u join public.founding_sellers f on f.user_id = u.user_id where u.source = s.source),
    (select count(*) from public.launch_emails e where e.source = s.source),
    t.created_at
  from s left join public.tracked_links t on t.source = s.source
  order by t.created_at desc nulls last, 4 desc;
end $$;
revoke all on function public.source_stats() from public, anon;
grant execute on function public.source_stats() to authenticated;

-- ---------- 2. DATE D'OUVERTURE ET LISTE E-MAIL DES VISITEURS ----------
alter table public.site_settings add column if not exists launch_at timestamptz;

create or replace function public.set_launch_date(p_at timestamptz)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Orleoo'; end if;
  if p_at is not null and p_at < now() then raise exception 'Choisis une date dans le futur'; end if;
  update public.site_settings set launch_at = p_at where id = 1;
end $$;
revoke all on function public.set_launch_date(timestamptz) from public, anon;
grant execute on function public.set_launch_date(timestamptz) to authenticated;

create table if not exists public.launch_emails (
  id              uuid primary key default gen_random_uuid(),
  email           text not null check (char_length(email) <= 200),
  source          text check (source ~ '^[a-z0-9-]{1,40}$'),
  token           uuid not null default gen_random_uuid() unique,
  created_at      timestamptz not null default now(),
  notified_at     timestamptz,
  unsubscribed_at timestamptz
);
create unique index if not exists launch_emails_email_idx on public.launch_emails (lower(email));
alter table public.launch_emails enable row level security;   -- aucune lecture depuis le site

-- Un visiteur sans compte laisse son e-mail (réponse identique s'il est déjà inscrit : rien ne fuit)
create or replace function public.subscribe_launch(p_email text, p_source text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare e text := lower(trim(coalesce(p_email, '')));
begin
  if e !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' or char_length(e) > 200 then raise exception 'Adresse e-mail invalide'; end if;
  if (select count(*) from public.launch_emails where created_at > now() - interval '1 hour') >= 300 then
    raise exception 'Trop de demandes en ce moment : réessaie dans un moment';
  end if;
  insert into public.launch_emails (email, source)
  values (e, case when p_source ~ '^[a-z0-9-]{1,40}$' then p_source end)
  on conflict ((lower(email))) do update set unsubscribed_at = null
    where public.launch_emails.notified_at is null;
  return true;
end $$;
grant execute on function public.subscribe_launch(text, text) to anon, authenticated;

create or replace function public.unsubscribe_launch(p_token uuid)
returns boolean language sql security definer set search_path = public as $$
  update public.launch_emails set unsubscribed_at = now() where token = p_token and unsubscribed_at is null returning true;
$$;
grant execute on function public.unsubscribe_launch(uuid) to anon, authenticated;

create or replace function public.launch_email_count()
returns int language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then return null; end if;
  return (select count(*) from public.launch_emails where unsubscribed_at is null);
end $$;
grant execute on function public.launch_email_count() to authenticated;

-- E-mail à une adresse sans compte (même expéditeur que les autres e-mails Orleoo)
create or replace function public.send_raw_email(p_email text, p_subject text, p_text text, p_link text, p_unsub text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare api_key text; html text; esc text;
begin
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  if p_email is null or api_key is null then return; end if;
  esc := replace(replace(replace(replace(p_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), chr(10), '<br>');
  html := '<p>' || esc || '</p><p><a href="' || p_link || '">' || p_link || '</a></p><p>À bientôt,<br>Orleoo</p>'
       || '<p style="color:#777;font-size:12px">Tu reçois cet e-mail car tu as demandé à être prévenu(e) de l’ouverture d’Orleoo. '
       || '<a href="' || p_unsub || '">Ne plus recevoir d’e-mail</a></p>';
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', api_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', 'Orleoo', 'email', 'orleoo.contact@gmail.com'),
      'to', jsonb_build_array(jsonb_build_object('email', p_email)),
      'subject', p_subject, 'htmlContent', html,
      'textContent', p_text || chr(10) || chr(10) || p_link || chr(10) || chr(10) || 'À bientôt,' || chr(10) || 'Orleoo'
                     || chr(10) || chr(10) || 'Ne plus recevoir d’e-mail : ' || p_unsub,
      'headers', jsonb_build_object('List-Unsubscribe', '<' || p_unsub || '>')));
exception when others then
  raise warning 'e-mail non envoyé : %', sqlerrm;
end $$;
revoke all on function public.send_raw_email(text, text, text, text, text) from public, anon, authenticated;

-- Le jour J (achats ouverts) : un e-mail à chaque adresse de la liste
create or replace function public.notify_launch_emails()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record; site text := 'https://revoocontact-blip.github.io/revoo/';
begin
  if new.achats_ouverts and not coalesce(old.achats_ouverts, false) then
    for r in select * from public.launch_emails where notified_at is null and unsubscribed_at is null loop
      perform public.send_raw_email(r.email, 'C’est ouvert : les achats démarrent sur Orleoo',
        'Orleoo est ouvert ! Tu peux maintenant acheter des vêtements et des livres de seconde main, avec un paiement protégé jusqu’à la réception.',
        site || coalesce('?src=' || r.source, '') || '#/catalogue', site || '#/desinscription/' || r.token);
      update public.launch_emails set notified_at = now() where id = r.id;
    end loop;
  end if;
  return new;
end $$;
revoke all on function public.notify_launch_emails() from public, anon, authenticated;
drop trigger if exists site_settings_launch_emails on public.site_settings;
create trigger site_settings_launch_emails after update of achats_ouverts on public.site_settings
  for each row execute function public.notify_launch_emails();

select 'Lancement prêt : liens suivis, date d’ouverture, liste e-mail' as info;
