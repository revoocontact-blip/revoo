-- =====================================================================
-- ORLEOO — nouvelle adresse d'expédition des e-mails : orleoo.contact@gmail.com
-- AVANT de lancer ce script : ajoute et valide cette adresse dans Brevo
--   (Brevo > Expéditeurs, domaines et IP dédiées > Expéditeurs > Ajouter un expéditeur).
-- Puis colle ce script dans Supabase > SQL Editor > New query, et « Run ».
-- =====================================================================

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

select 'E-mails envoyés depuis orleoo.contact@gmail.com' as info;
