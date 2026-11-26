-- =====================================================================
-- ORLEOO — nouveau nom + catégorie Livres
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS tous les autres scripts. (Peut être relancé sans risque.)
--
--   1. Les annonces peuvent être dans la catégorie « Livres ».
--   2. Les e-mails et messages du site disent « Orleoo » au lieu de « Revoo ».
-- =====================================================================

-- ---------- 1. Catégorie Livres ----------
do $$ declare c record; begin
  for c in select conname from pg_constraint
            where conrelid = 'public.listings'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%category%'
  loop execute format('alter table public.listings drop constraint %I', c.conname); end loop;
end $$;
alter table public.listings add constraint listings_category_check
  check (category in ('Femme','Homme','Enfant','Unisexe','Livres'));

-- ---------- 2. Textes « Orleoo » (e-mails, messages d'erreur) ----------

-- (depuis supabase-notifications.sql)
create or replace function public.notify_new_message()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare
  conv        record;
  recipient   uuid;
  to_email    text;
  wants       boolean;
  sender_name text;
  item_title  text;
  api_key     text;
  preview     text;
  link        text;
  site        constant text := 'https://revoocontact-blip.github.io/revoo/';
begin
  select * into conv from public.conversations where id = new.conversation_id;
  if conv is null then return new; end if;
  recipient := case when new.sender_id = conv.buyer_id then conv.seller_id else conv.buyer_id end;

  -- Le destinataire veut-il ces e-mails ?
  select notify_messages into wants from public.profiles where id = recipient;
  if not coalesce(wants, true) then return new; end if;

  -- Anti-spam : déjà prévenu il y a moins de 30 minutes pour cette conversation ?
  if exists (select 1 from public.message_notifications
             where conversation_id = conv.id and recipient_id = recipient
               and last_sent_at > now() - interval '30 minutes') then
    return new;
  end if;

  select email into to_email from auth.users where id = recipient;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  if to_email is null or api_key is null then return new; end if;

  select name into sender_name from public.profiles where id = new.sender_id;
  select title into item_title from public.listings where id = conv.listing_id;

  -- Aperçu du message, protégé contre le HTML
  preview := left(new.body, 300);
  preview := replace(replace(replace(replace(preview, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;');
  if char_length(new.body) > 300 then preview := preview || '…'; end if;
  sender_name := replace(replace(replace(coalesce(sender_name, 'Un membre'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  item_title  := replace(replace(replace(coalesce(item_title, 'une annonce'), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
  link := site || '#/messages/' || conv.id;

  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', api_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', 'Orleoo', 'email', 'orleoo.contact@gmail.com'),
      'to', jsonb_build_array(jsonb_build_object('email', to_email)),
      'subject', coalesce((select name from public.profiles where id = new.sender_id), 'Un membre') || ' t’a envoyé un message',
      -- Version sobre (comme un e-mail personnel) : meilleure chance d'arriver dans « Principale »
      'htmlContent',
        '<p>Bonjour,</p>'
        || '<p>' || sender_name || ' t’a envoyé un message à propos de « ' || item_title || ' » :</p>'
        || '<blockquote style="margin:0 0 0 8px;padding-left:12px;border-left:3px solid #A8C4D8;white-space:pre-line">' || preview || '</blockquote>'
        || '<p>Pour lui répondre : <a href="' || link || '">' || link || '</a></p>'
        || '<p>À bientôt,<br>Orleoo</p>'
        || '<p style="font-size:12px;color:#777">Tu peux désactiver ces e-mails dans Mon compte, rubrique Profil.</p>',
      'textContent',
        'Bonjour,' || chr(10) || chr(10)
        || coalesce((select name from public.profiles where id = new.sender_id), 'Un membre') || ' t’a envoyé un message à propos de « '
        || coalesce((select title from public.listings where id = conv.listing_id), 'une annonce') || ' » :' || chr(10) || chr(10)
        || '« ' || left(new.body, 300) || case when char_length(new.body) > 300 then '…' else '' end || ' »' || chr(10) || chr(10)
        || 'Pour lui répondre : ' || link || chr(10) || chr(10)
        || 'À bientôt,' || chr(10) || 'Orleoo' || chr(10) || chr(10)
        || 'Tu peux désactiver ces e-mails dans Mon compte, rubrique Profil.'
    )
  );

  insert into public.message_notifications (conversation_id, recipient_id, last_sent_at)
  values (conv.id, recipient, now())
  on conflict (conversation_id, recipient_id) do update set last_sent_at = excluded.last_sent_at;

  return new;
exception when others then
  -- Un problème d'e-mail ne doit jamais empêcher l'envoi du message
  raise warning 'notification e-mail non envoyée : %', sqlerrm;
  return new;
end $$;

-- (depuis supabase-avis-et-emails.sql)
create or replace function public.send_revoo_email(p_user uuid, p_subject text, p_text text, p_link text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare to_email text; api_key text; html text;
begin
  select email into to_email from auth.users where id = p_user;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  if to_email is null or api_key is null then return; end if;
  html := '<p>' || replace(replace(replace(replace(p_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), chr(10), '<br>') || '</p>'
       || '<p><a href="' || p_link || '">' || p_link || '</a></p><p>À bientôt,<br>Orleoo</p>';
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', api_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', 'Orleoo', 'email', 'orleoo.contact@gmail.com'),
      'to', jsonb_build_array(jsonb_build_object('email', to_email)),
      'subject', p_subject,
      'htmlContent', html,
      'textContent', p_text || chr(10) || chr(10) || p_link || chr(10) || chr(10) || 'À bientôt,' || chr(10) || 'Orleoo'));
exception when others then
  raise warning 'e-mail non envoyé : %', sqlerrm;
end $$;

-- (depuis supabase-avis-et-emails.sql)
create or replace function public.notify_order_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  site  constant text := 'https://revoocontact-blip.github.io/revoo/';
  tag   text := case when new.demo then ' (commande de démonstration, aucun paiement)' else '' end;
  buyer text := coalesce((select name from public.profiles where id = new.buyer_id), 'Un membre');
begin
  if tg_op = 'INSERT' then
    perform public.send_revoo_email(new.seller_id,
      'Tu as vendu « ' || new.title || ' » !',
      'Bonne nouvelle : ' || buyer || ' a acheté « ' || new.title || ' »' || tag || '.' || chr(10) || chr(10)
      || case when new.delivery = 'colis'
              then 'Envoie l’article par colis avec suivi, puis indique-le dans Mon compte, rubrique Mes ventes.'
              else 'Convenez d’un rendez-vous dans la messagerie pour la remise en main propre.' end,
      site || '#/compte/ventes');
  elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'shipped' then
      perform public.send_revoo_email(new.buyer_id,
        case when new.delivery = 'colis' then 'Ton article a été envoyé' else 'Ton article a été remis' end,
        '« ' || new.title || ' » ' || case when new.delivery = 'colis' then 'est en route' else 'est indiqué comme remis' end || tag || '.'
        || case when new.tracking is not null then chr(10) || 'Numéro de suivi : ' || new.tracking else '' end || chr(10) || chr(10)
        || 'Quand tu l’as reçu et qu’il te convient, confirme la réception dans Mon compte, rubrique Mes achats. En cas de problème, signale-le avant de confirmer.',
        site || '#/compte/achats');
    elsif new.status = 'received' then
      perform public.send_revoo_email(new.seller_id,
        'Vente terminée : « ' || new.title || ' »',
        buyer || ' a confirmé la bonne réception de « ' || new.title || ' »' || tag || '. Le montant de la vente est disponible dans ton porte-monnaie.',
        site || '#/compte/portemonnaie');
    elsif new.status = 'problem' then
      perform public.send_revoo_email(new.seller_id,
        'Un problème a été signalé sur « ' || new.title || ' »',
        buyer || ' a signalé un problème sur sa commande' || tag || '. Orleoo va examiner la situation. Tu peux échanger avec l’acheteur dans la messagerie.',
        site || '#/compte/ventes');
    elsif new.status = 'cancelled' then
      perform public.send_revoo_email(new.buyer_id,
        'Commande annulée : « ' || new.title || ' »',
        'Ta commande de « ' || new.title || ' » a été annulée' || tag || '. Si tu avais payé, tu seras remboursé.',
        site || '#/compte/achats');
    end if;
  end if;
  return new;
exception when others then
  raise warning 'e-mail de commande non envoyé : %', sqlerrm;
  return new;
end $$;

-- (depuis supabase-securite.sql)
create or replace function public.protect_listing()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  base text := 'https://htisbuqxnqdahtedgiiz.supabase.co/storage/v1/object/public/annonces/';
  n int;
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.status := 'active';
    -- anti-spam : 50 nouvelles annonces par jour maximum
    select count(*) into n from public.listings
     where seller_id = new.seller_id and created_at > now() - interval '1 day';
    if n >= 50 then raise exception 'Tu as publié beaucoup d’annonces aujourd’hui : réessaie demain'; end if;
  else
    new.created_at := old.created_at;            -- impossible de « remonter » une annonce en trichant sur la date
    if public.is_admin() then return new; end if;
    -- impossible de remettre en vente un article payé (Orleoo Pay) ou engagé dans un échange
    if new.status = 'active' and old.status <> 'active' and (
         exists (select 1 from public.orders o where o.listing_id = new.id and o.status <> 'cancelled')
      or exists (select 1 from public.trades t where (t.offered_listing = new.id or t.wanted_listing = new.id)
                   and t.status in ('accepted','problem','completed'))) then
      raise exception 'Cet article est lié à une vente ou un échange Orleoo Pay : il ne peut pas être remis en vente';
    end if;
  end if;
  -- photos : uniquement celles déposées sur Orleoo, dans le dossier du vendeur
  if tg_op = 'INSERT' or new.photos is distinct from old.photos then
    if exists (select 1 from unnest(new.photos) p where p not like base || new.seller_id::text || '/%' or p like '%..%' or p ~ '[\s"''<>]') then
      raise exception 'Photos invalides : ajoute-les depuis le formulaire Orleoo';
    end if;
  end if;
  return new;
end $$;

-- (depuis supabase-abonnements.sql)
create or replace function public.use_boost(p_listing uuid)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); s record; l record; until timestamptz;
begin
  perform public.settle_subscriptions();
  select * into s from public.subscriptions where user_id = me and current_period_end > now() for update;
  if s is null then raise exception 'Les mises en avant offertes sont réservées aux abonnés Orleoo Pro, Max et Ultra'; end if;
  if s.boosts_used >= public.plan_limit(s.plan, 'boosts') then
    raise exception 'Tu as utilisé tes % mises en avant du mois', public.plan_limit(s.plan, 'boosts');
  end if;
  select * into l from public.listings where id = p_listing for update;
  if l is null or l.seller_id <> me or l.status <> 'active' then raise exception 'Choisis une de tes annonces en ligne'; end if;
  until := greatest(coalesce(l.boosted_until, now()), now()) + interval '48 hours';
  perform set_config('revoo.sys', '1', true);   -- autorise ce changement précis
  update public.listings set boosted_until = until where id = p_listing;
  perform set_config('revoo.sys', '', true);
  update public.subscriptions set boosts_used = boosts_used + 1, updated_at = now() where user_id = me;
  return until;
end $$;

-- (depuis supabase-abonnements.sql)
create or replace function public.check_plan_perks()
returns trigger language plpgsql security definer set search_path = public as $$
declare p text; n int;
begin
  if tg_table_name = 'listings' then
    p := public.plan_of(new.seller_id);
    if cardinality(new.photos) > public.plan_limit(p, 'photos')
       and (tg_op = 'INSERT' or cardinality(new.photos) > cardinality(old.photos)) then
      raise exception 'Ta formule permet % photos par annonce', public.plan_limit(p, 'photos');
    end if;
    if new.pinned and (tg_op = 'INSERT' or not old.pinned) then
      select count(*) into n from public.listings where seller_id = new.seller_id and pinned and id <> new.id;
      if n >= public.plan_limit(p, 'pins') then
        raise exception 'Ta formule permet % annonce(s) épinglée(s)', public.plan_limit(p, 'pins');
      end if;
    end if;
  else  -- profiles
    if new.accent is distinct from old.accent and new.accent is not null and public.plan_of(new.id) <> 'ultra' then
      raise exception 'La couleur de boutique est réservée à Orleoo Ultra';
    end if;
  end if;
  return new;
end $$;

-- (depuis supabase-equipe.sql)
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
      'sender', jsonb_build_object('name', 'Orleoo', 'email', 'orleoo.contact@gmail.com'),
      'to', jsonb_build_array(jsonb_build_object('email', to_email)),
      'subject', p_subject,
      'htmlContent', '<p>Bonjour,</p><p style="white-space:pre-line">' || safe || '</p><p>L’équipe Orleoo</p>',
      'textContent', 'Bonjour,' || chr(10) || chr(10) || p_text || chr(10) || chr(10) || 'L’équipe Orleoo'));
exception when others then
  raise warning 'e-mail non envoyé : %', sqlerrm;
end $$;

-- (depuis supabase-equipe.sql)
create or replace function public.ban_member(p_user uuid, p_days int, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_until timestamptz; n int; who text;
begin
  perform public.require_perm('suspendre');
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
  perform set_config('revoo.sys', '1', true);
  update public.listings set status = 'removed' where seller_id = p_user and status = 'active';
  get diagnostics n = row_count;
  perform set_config('revoo.sys', '', true);
  update public.trades set status = 'cancelled', updated_at = now() where p_user in (proposer_id, receiver_id) and status = 'proposed';
  insert into public.member_notices (user_id, kind, message, created_by)
  values (p_user, 'suspension',
    'Ton compte est suspendu' || case when v_until is null then ' définitivement' else ' pendant ' || p_days || ' jour(s)' end
    || '. Motif : ' || trim(p_reason), auth.uid());
  perform public.log_action('Membre suspendu' || case when v_until is null then ' (définitif)' else ' (' || p_days || ' j)' end,
    p_user, null, trim(p_reason) || ' · ' || n || ' annonce(s) retirée(s)');
  perform public.email_member(p_user, 'Ton compte Orleoo est suspendu',
    'Ton compte Orleoo est suspendu' || case when v_until is null then ' définitivement' else ' jusqu’au ' || to_char(v_until at time zone 'Europe/Paris', 'DD/MM/YYYY') end
    || '.' || chr(10) || 'Motif : ' || trim(p_reason) || chr(10) || chr(10)
    || 'Tes achats et ventes déjà en cours restent protégés. Si tu penses qu’il s’agit d’une erreur, réponds à cet e-mail.');
end $$;

-- (depuis supabase-equipe.sql)
create or replace function public.unban_member(p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_perm('suspendre');
  delete from public.bans where user_id = p_user;
  if not found then raise exception 'Ce membre n’est pas suspendu'; end if;
  insert into public.member_notices (user_id, kind, message, created_by)
  values (p_user, 'levee', 'Ta suspension est levée : tu peux de nouveau utiliser Orleoo normalement. Tes anciennes annonces peuvent être remises en ligne par l’équipe sur demande.', auth.uid());
  perform public.log_action('Suspension levée', p_user, null, null);
  perform public.email_member(p_user, 'Ta suspension Orleoo est levée', 'Ta suspension est levée : tu peux de nouveau utiliser Orleoo normalement.');
end $$;

-- (depuis supabase-equipe.sql)
create or replace function public.warn_member(p_user uuid, p_message text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_perm('avertir');
  if p_message is null or char_length(trim(p_message)) < 5 then raise exception 'Écris le message de l’avertissement'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'Membre introuvable'; end if;
  insert into public.member_notices (user_id, kind, message, created_by) values (p_user, 'avertissement', left(trim(p_message), 1000), auth.uid());
  perform public.log_action('Avertissement envoyé', p_user, null, left(trim(p_message), 300));
  perform public.email_member(p_user, 'Message de l’équipe Orleoo', left(trim(p_message), 1000));
end $$;

-- (depuis supabase-equipe.sql)
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
    raise exception 'Ton annonce contient un mot non autorisé sur Orleoo (« % »). Modifie-la puis réessaie.', w;
  end if;
  return new;
end $$;

-- (depuis supabase-equipe.sql)
create or replace function public.block_when_paused()
returns trigger language plpgsql security definer set search_path = public as $$
declare s record;
begin
  if public.is_admin() then return new; end if;
  select * into s from public.site_settings where id = 1;
  if s is null then return new; end if;
  if s.maintenance then
    raise exception 'Orleoo est en maintenance%. Réessaie un peu plus tard.',
      case when s.maintenance_until is null then '' else ' jusqu’au ' || to_char(s.maintenance_until at time zone 'Europe/Paris', 'DD/MM à HH24:MI') end;
  end if;
  if tg_table_name = 'listings' and s.pause_listings then
    raise exception 'Les nouvelles annonces sont mises en pause quelques instants par l’équipe Orleoo. Réessaie un peu plus tard.';
  end if;
  if tg_table_name in ('orders','trades') and s.pause_purchases then
    raise exception 'Les achats et les échanges sont mis en pause quelques instants par l’équipe Orleoo. Réessaie un peu plus tard.';
  end if;
  if tg_table_name in ('messages','conversations') and s.pause_messages then
    raise exception 'La messagerie est mise en pause quelques instants par l’équipe Orleoo. Réessaie un peu plus tard.';
  end if;
  return new;
end $$;



-- (depuis supabase-equipe.sql)
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public, auth as $$
declare me uuid := auth.uid(); n int;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  if exists (select 1 from public.admins where user_id = me) then
    raise exception 'Les comptes de l’équipe Orleoo ne peuvent pas être supprimés';
  end if;
  select count(*) into n from public.orders where me in (buyer_id, seller_id) and status in ('paid','shipped','problem');
  if n > 0 then raise exception 'Tu as % vente(s) ou achat(s) en cours : termine-les ou annule-les avant de supprimer ton compte', n; end if;
  select count(*) into n from public.trades where me in (proposer_id, receiver_id) and status in ('accepted','problem');
  if n > 0 then raise exception 'Tu as % échange(s) en cours : termine-les avant de supprimer ton compte', n; end if;
  update public.trades set status = 'cancelled', updated_at = now() where me in (proposer_id, receiver_id) and status = 'proposed';
  delete from public.listings where seller_id = me;
  delete from auth.users where id = me;
end $$;

-- (depuis supabase-equipe.sql)
create or replace function public.gift_subscription(p_user uuid, p_plan text, p_days int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_founder() then raise exception 'Réservé au fondateur'; end if;
  if p_plan not in ('pro','max','ultra') then raise exception 'Formule inconnue'; end if;
  if p_days is null or p_days < 1 or p_days > 365 then raise exception 'Durée : 1 à 365 jours'; end if;
  if not exists (select 1 from public.profiles where id = p_user) then raise exception 'Membre introuvable'; end if;
  insert into public.subscriptions (user_id, plan, current_period_start, current_period_end, cancel_at_period_end, demo)
  values (p_user, p_plan, now(), now() + make_interval(days => p_days), true, true)
  on conflict (user_id) do update set plan = excluded.plan, current_period_start = now(),
    current_period_end = greatest(public.subscriptions.current_period_end, now()) + make_interval(days => p_days),
    cancel_at_period_end = true, boosts_used = 0, updated_at = now();
  insert into public.member_notices (user_id, kind, message, created_by)
  values (p_user, 'info', 'Cadeau de l’équipe Orleoo : Orleoo ' || initcap(p_plan) || ' t’est offert pendant ' || p_days || ' jour(s). Profite bien de tes avantages !', auth.uid());
  perform public.log_action('Abonnement offert', p_user, null, 'Orleoo ' || initcap(p_plan) || ' · ' || p_days || ' j');
end $$;


-- Vérification : doit afficher « Livres acceptés »
select case when pg_get_constraintdef(oid) like '%Livres%' then 'Livres acceptés' else 'PROBLÈME' end as categorie
from pg_constraint where conname = 'listings_category_check';
