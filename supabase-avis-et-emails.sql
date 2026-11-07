-- =====================================================================
-- REVOO — avis sur les vendeurs + e-mails de commande
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- (À lancer après supabase-revoopay.sql et supabase-notifications.sql.
--  Peut être relancé sans risque.)
-- =====================================================================

-- ---------- 1. AVIS ----------
create table if not exists public.reviews (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null unique references public.orders(id) on delete cascade,
  seller_id   uuid not null references public.profiles(id) on delete cascade,
  buyer_id    uuid not null references public.profiles(id) on delete cascade,
  rating      int  not null check (rating between 1 and 5),
  comment     text check (char_length(comment) <= 500),
  demo        boolean not null default false,
  created_at  timestamptz not null default now()
);
create index if not exists reviews_seller_idx on public.reviews (seller_id, created_at desc);
alter table public.reviews enable row level security;

-- Les avis sont publics ; seule la modération peut en supprimer un
drop policy if exists "avis publics" on public.reviews;
create policy "avis publics" on public.reviews for select using (true);
drop policy if exists "modération : supprimer un avis" on public.reviews;
create policy "modération : supprimer un avis" on public.reviews for delete to authenticated using (public.is_admin());

-- Laisser un avis : uniquement l'acheteur, une seule fois, après réception
create or replace function public.leave_review(p_order uuid, p_rating int, p_comment text default null)
returns void language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select * into o from public.orders where id = p_order;
  if o is null or o.buyer_id <> auth.uid() then raise exception 'Commande introuvable'; end if;
  if o.status <> 'received' then raise exception 'Tu pourras laisser un avis après avoir confirmé la réception'; end if;
  if p_rating not between 1 and 5 then raise exception 'Choisis une note de 1 à 5 étoiles'; end if;
  insert into public.reviews (order_id, seller_id, buyer_id, rating, comment, demo)
  values (o.id, o.seller_id, o.buyer_id, p_rating, nullif(left(trim(coalesce(p_comment,'')), 500), ''), o.demo);
exception when unique_violation then
  raise exception 'Tu as déjà laissé un avis pour cette commande';
end $$;
revoke all on function public.leave_review(uuid,int,text) from public, anon;
grant execute on function public.leave_review(uuid,int,text) to authenticated;

-- ---------- 2. ENVOI D'E-MAIL (fonction commune, via l'API Brevo) ----------
create or replace function public.send_revoo_email(p_user uuid, p_subject text, p_text text, p_link text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare to_email text; api_key text; html text;
begin
  select email into to_email from auth.users where id = p_user;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  if to_email is null or api_key is null then return; end if;
  html := '<p>' || replace(replace(replace(replace(p_text, '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), chr(10), '<br>') || '</p>'
       || '<p><a href="' || p_link || '">' || p_link || '</a></p><p>À bientôt,<br>Revoo</p>';
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', api_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', 'Revoo', 'email', 'revoo.contact@gmail.com'),
      'to', jsonb_build_array(jsonb_build_object('email', to_email)),
      'subject', p_subject,
      'htmlContent', html,
      'textContent', p_text || chr(10) || chr(10) || p_link || chr(10) || chr(10) || 'À bientôt,' || chr(10) || 'Revoo'));
exception when others then
  raise warning 'e-mail non envoyé : %', sqlerrm;
end $$;
revoke all on function public.send_revoo_email(uuid,text,text,text) from public, anon, authenticated;

-- ---------- 3. E-MAILS AUTOMATIQUES DES COMMANDES ----------
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
        buyer || ' a signalé un problème sur sa commande' || tag || '. Revoo va examiner la situation. Tu peux échanger avec l’acheteur dans la messagerie.',
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

drop trigger if exists orders_email_notification on public.orders;
create trigger orders_email_notification after insert or update on public.orders
  for each row execute function public.notify_order_change();
