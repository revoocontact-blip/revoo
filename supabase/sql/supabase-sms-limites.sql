-- =====================================================================
-- ORLEOO — code de remise en main propre par SMS + limite d'achats selon le membre
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-ajustements-2.sql. Peut être relancé sans risque.
-- Les SMS partent par Brevo (même clé que les e-mails, coffre « brevo_api_key ») :
-- il faut des crédits SMS sur le compte Brevo, et que la clé ait le droit « SMS ».
-- =====================================================================

-- ---------- 1. Numéro de mobile (données privées, format international +33…) ----------
alter table public.profiles_private add column if not exists phone text;
do $$ begin
  alter table public.profiles_private add constraint profiles_private_phone_check check (phone is null or phone ~ '^\+[1-9][0-9]{7,14}$');
exception when duplicate_object then null; end $$;

-- ---------- 2. Envoi d'un SMS ----------
create or replace function public.send_revoo_sms(p_user uuid, p_text text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare tel text; api_key text;
begin
  select phone into tel from public.profiles_private where id = p_user;
  select decrypted_secret into api_key from vault.decrypted_secrets where name = 'brevo_api_key' limit 1;
  if tel is null or api_key is null then return; end if;
  perform net.http_post(
    url := 'https://api.brevo.com/v3/transactionalSMS/sms',
    headers := jsonb_build_object('api-key', api_key, 'Content-Type', 'application/json', 'accept', 'application/json'),
    body := jsonb_build_object('sender', 'Orleoo', 'recipient', ltrim(tel, '+'), 'content', left(p_text, 300),
                               'type', 'transactional', 'unicodeEnabled', true, 'tag', 'code-main-propre'));
exception when others then
  raise warning 'SMS non envoyé : %', sqlerrm;
end $$;
revoke all on function public.send_revoo_sms(uuid, text) from public, anon, authenticated;

-- Un code de remise en main propre est créé → SMS à l'acheteur
create or replace function public.sms_handoff_code()
returns trigger language plpgsql security definer set search_path = public as $$
declare o record;
begin
  select buyer_id, title into o from public.orders where id = new.order_id;
  if o is null then return new; end if;
  perform public.send_revoo_sms(o.buyer_id,
    'Orleoo : ton code de remise en main propre pour « ' || left(o.title, 40) || ' » est ' || new.code
    || '. Donne-le au vendeur seulement une fois l’article vérifié.');
  return new;
exception when others then return new;
end $$;
revoke all on function public.sms_handoff_code() from public, anon, authenticated;
drop trigger if exists order_codes_sms on public.order_codes;
create trigger order_codes_sms after insert on public.order_codes for each row execute function public.sms_handoff_code();

-- ---------- 3. Achats en cours : la limite dépend du membre ----------
CREATE OR REPLACE FUNCTION public.rate_limit()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare n int; lim int;
begin
  if tg_table_name = 'messages' then
    select count(*) into n from public.messages where sender_id = new.sender_id and created_at > now() - interval '10 minutes';
    if n >= 30 then raise exception 'Tu envoies beaucoup de messages : patiente quelques minutes'; end if;

  elsif tg_table_name = 'conversations' then
    select count(*) into n from public.conversations where buyer_id = new.buyer_id and created_at > now() - interval '1 day';
    if n >= 30 then raise exception 'Tu as contacté beaucoup de vendeurs aujourd’hui : réessaie demain'; end if;

  elsif tg_table_name = 'reports' then
    if new.reporter_id is not null then
      select count(*) into n from public.reports where reporter_id = new.reporter_id and created_at > now() - interval '1 day';
      if n >= 20 then raise exception 'Tu as fait beaucoup de signalements aujourd’hui : réessaie demain'; end if;
    else
      select count(*) into n from public.reports where reporter_id is null and listing_id = new.listing_id and created_at > now() - interval '1 day';
      if n >= 3 then raise exception 'Cette annonce a déjà été signalée : la modération va l’examiner'; end if;
      select count(*) into n from public.reports where reporter_id is null and created_at > now() - interval '1 hour';
      if n >= 100 then raise exception 'Trop de signalements en ce moment : réessaie un peu plus tard'; end if;
    end if;

  elsif tg_table_name = 'orders' then
    select count(*) into n from public.orders where buyer_id = new.buyer_id and status in ('paid','shipped','problem');
    -- limite selon le membre : confiance (5 achats terminés, aucun litige) = sans limite ; abonné = 30 ; sinon 10
    lim := case
      when (select count(*) from public.orders where buyer_id = new.buyer_id and status = 'received') >= 5
           and not exists (select 1 from public.orders where buyer_id = new.buyer_id and status = 'problem') then null
      when public.plan_of(new.buyer_id) <> '' then 30
      else 10 end;
    if lim is not null and n >= lim then raise exception 'Tu as déjà % achats en cours : termine-en avant d’en commencer d’autres', lim; end if;
    select count(*) into n from public.orders where buyer_id = new.buyer_id and created_at > now() - interval '1 day';
    if n >= 30 then raise exception 'Tu as fait beaucoup d’achats aujourd’hui : réessaie demain'; end if;

  elsif tg_table_name = 'trades' then
    select count(*) into n from public.trades where proposer_id = new.proposer_id and status = 'proposed';
    if n >= 10 then raise exception 'Tu as déjà 10 propositions d’échange en attente'; end if;
    select count(*) into n from public.trades where proposer_id = new.proposer_id and created_at > now() - interval '1 day';
    if n >= 20 then raise exception 'Tu as proposé beaucoup d’échanges aujourd’hui : réessaie demain'; end if;
  end if;
  return new;
end $function$;

select 'SMS et limites prêts' as info;
