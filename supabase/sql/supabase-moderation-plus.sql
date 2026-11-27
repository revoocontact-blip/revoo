-- =====================================================================
-- ORLEOO — modération complète :
--   • signaler un membre (depuis une conversation) → file « Membres signalés »
--   • statistiques de modération (délais, décisions par membre de l'équipe)
--   • motif de signalement à jour (vêtements ET livres)
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-equipe.sql. Peut être relancé sans risque.
-- =====================================================================

-- ---------- 1. MOTIF « hors catégorie » à jour ----------
do $$ begin
  alter table public.reports drop constraint if exists reports_reason_check;
  alter table public.reports add constraint reports_reason_check check (reason in (
    'Article interdit ou dangereux','Contrefaçon','Arnaque ou fraude','Annonce trompeuse',
    'Contenu choquant ou inapproprié','Ce n’est pas un vêtement','Ni un vêtement ni un livre','Autre'));
exception when others then raise notice 'motifs : %', sqlerrm; end $$;

-- ---------- 2. SIGNALER UN MEMBRE ----------
create table if not exists public.member_reports (
  id              uuid primary key default gen_random_uuid(),
  reporter_id     uuid references public.profiles(id) on delete set null,
  reported_id     uuid not null references public.profiles(id) on delete cascade,
  conversation_id uuid references public.conversations(id) on delete set null,
  reason          text not null check (reason in ('Arnaque ou tentative de fraude','Paiement en dehors d’Orleoo','Insultes ou harcèlement','Faux profil ou usurpation','Spam','Autre')),
  details         text check (char_length(details) <= 1000),
  status          text not null default 'nouveau' check (status in ('nouveau','traité','rejeté')),
  handled_by      uuid references public.profiles(id) on delete set null,
  handled_at      timestamptz,
  created_at      timestamptz not null default now(),
  check (reporter_id is null or reporter_id <> reported_id)
);
create index if not exists member_reports_status_idx on public.member_reports (status, created_at desc);
create index if not exists member_reports_reported_idx on public.member_reports (reported_id);
alter table public.member_reports enable row level security;
drop policy if exists "signalements membres : équipe" on public.member_reports;
create policy "signalements membres : équipe" on public.member_reports for select to authenticated using (public.has_perm('signalements'));
revoke insert, update, delete on public.member_reports from anon, authenticated;

create or replace function public.report_member(p_member uuid, p_reason text, p_details text default null, p_conversation uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); d text := nullif(trim(coalesce(p_details, '')), ''); rid uuid;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  if p_member is null or p_member = me then raise exception 'Signalement impossible'; end if;
  if not exists (select 1 from public.profiles where id = p_member) then raise exception 'Membre introuvable'; end if;
  if p_conversation is not null and not exists (select 1 from public.conversations where id = p_conversation and me in (buyer_id, seller_id) and p_member in (buyer_id, seller_id)) then
    raise exception 'Conversation introuvable';
  end if;
  if exists (select 1 from public.member_reports where reporter_id = me and reported_id = p_member and status = 'nouveau') then
    raise exception 'Tu as déjà signalé ce membre : l’équipe s’en occupe';
  end if;
  if (select count(*) from public.member_reports where reporter_id = me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Tu as fait beaucoup de signalements aujourd’hui : réessaie demain';
  end if;
  insert into public.member_reports (reporter_id, reported_id, conversation_id, reason, details)
  values (me, p_member, p_conversation, p_reason, left(d, 1000)) returning id into rid;
  return rid;
end $$;
revoke all on function public.report_member(uuid, text, text, uuid) from public, anon;
grant execute on function public.report_member(uuid, text, text, uuid) to authenticated;

-- File de l'équipe (avec les noms, sans jamais exposer l'identité du signaleur au membre signalé)
create or replace function public.member_reports_list(p_status text default 'nouveau')
returns table (id uuid, reported_id uuid, reported_name text, reporter_name text, conversation_id uuid, reason text, details text,
               status text, created_at timestamptz, handled_at timestamptz, handled_by_name text, previous int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_perm('signalements');
  return query
  select r.id, r.reported_id, pr.name, rp.name, r.conversation_id, r.reason, r.details, r.status, r.created_at, r.handled_at, hb.name,
         (select count(*)::int from public.member_reports x where x.reported_id = r.reported_id and x.id <> r.id)
  from public.member_reports r
  left join public.profiles pr on pr.id = r.reported_id
  left join public.profiles rp on rp.id = r.reporter_id
  left join public.profiles hb on hb.id = r.handled_by
  where (p_status = 'tous' or (p_status = 'nouveau' and r.status = 'nouveau') or (p_status = 'traites' and r.status <> 'nouveau'))
  order by r.created_at desc limit 200;
end $$;
revoke all on function public.member_reports_list(text) from public, anon;
grant execute on function public.member_reports_list(text) to authenticated;

create or replace function public.handle_member_report(p_report uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  perform public.require_perm('signalements');
  if p_status not in ('traité','rejeté') then raise exception 'Décision inconnue'; end if;
  update public.member_reports set status = p_status, handled_by = auth.uid(), handled_at = now()
   where id = p_report and status = 'nouveau' returning * into r;
  if r is null then raise exception 'Ce signalement a déjà été traité'; end if;
  perform public.log_action(case when p_status = 'traité' then 'Signalement de membre traité' else 'Signalement de membre rejeté' end,
    r.reported_id, null, r.reason);
end $$;
revoke all on function public.handle_member_report(uuid, text) from public, anon;
grant execute on function public.handle_member_report(uuid, text) to authenticated;

-- ---------- 3. STATISTIQUES DE MODÉRATION ----------
create or replace function public.mod_stats(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d int := greatest(7, least(coalesce(p_days, 30), 180)); since timestamptz := now() - make_interval(days => d); res jsonb;
begin
  if not public.is_admin() then raise exception 'Réservé à l’équipe Orleoo'; end if;
  select jsonb_build_object(
    'jours', d,
    'annonces_recus',  (select count(*) from public.reports where created_at > since),
    'annonces_traites',(select count(*) from public.reports where created_at > since and status <> 'nouveau'),
    'annonces_attente',(select count(*) from public.reports where status = 'nouveau'),
    'annonces_delai_h',(select round(extract(epoch from avg(handled_at - created_at)) / 3600, 1) from public.reports where handled_at is not null and created_at > since),
    'membres_recus',   (select count(*) from public.member_reports where created_at > since),
    'membres_attente', (select count(*) from public.member_reports where status = 'nouveau'),
    'membres_delai_h', (select round(extract(epoch from avg(handled_at - created_at)) / 3600, 1) from public.member_reports where handled_at is not null and created_at > since),
    'plus_ancien_h',   (select round(extract(epoch from now() - min(t)) / 3600, 1) from (select created_at t from public.reports where status = 'nouveau' union all select created_at from public.member_reports where status = 'nouveau') x),
    'avertissements',  (select count(*) from public.mod_log where created_at > since and action ilike '%avert%'),
    'suspensions',     (select count(*) from public.mod_log where created_at > since and action ilike '%suspen%'),
    'retraits',        (select count(*) from public.mod_log where created_at > since and action ilike '%retir%'),
    'equipe', (select coalesce(jsonb_agg(x order by x.n desc), '[]'::jsonb) from (
        select coalesce(p.name, 'ancien membre') nom, count(*) n from public.mod_log l left join public.profiles p on p.id = l.actor_id
        where l.created_at > since and l.action not ilike 'Conversation consultée%' group by 1 order by 2 desc limit 10) x),
    'motifs', (select coalesce(jsonb_agg(x order by x.n desc), '[]'::jsonb) from (
        select reason motif, count(*) n from (select reason from public.reports where created_at > since union all select reason from public.member_reports where created_at > since) y group by 1 order by 2 desc limit 8) x)
  ) into res;
  return res;
end $$;
revoke all on function public.mod_stats(int) from public, anon;
grant execute on function public.mod_stats(int) to authenticated;

select 'Modération complète : signalement de membres, statistiques, motifs à jour' as info;
