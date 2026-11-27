-- =====================================================================
-- ORLEOO — prêt entre membres
-- Règles :
--   • le prêteur active le prêt sur son annonce et choisit les durées possibles (3, 7, 14 ou 30 jours) ;
--   • il fixe le prix du prêt (au moins 1 €, au plus le prix de l'article) ;
--   • il fixe la caution (au moins 1 €, au plus le prix de l'article) : bloquée pendant le prêt, rendue au retour ;
--   • remise en main propre ou par colis ;
--   • l'emprunteur fait une demande, le prêteur l'accepte ou la refuse.
-- Le paiement du prêt et de la caution se fera sur Orleoo à l'ouverture des paiements :
-- avant cela, une demande acceptée reste « en attente du paiement ».
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- À lancer APRÈS supabase-offres-lots.sql. Peut être relancé sans risque.
-- =====================================================================

-- ---------- 1. PRÊT SUR L'ANNONCE ----------
alter table public.listings add column if not exists lend_on      boolean not null default false;
alter table public.listings add column if not exists lend_price   numeric(10,2);
alter table public.listings add column if not exists lend_deposit numeric(10,2);
alter table public.listings add column if not exists lend_days    smallint[] not null default '{}';

create or replace function public.listing_lend_check()
returns trigger language plpgsql set search_path = public as $$
begin
  if not new.lend_on then return new; end if;
  -- prix baissé sous le prix du prêt ou la caution : on les ramène au prix de l'article
  if tg_op = 'UPDATE' and new.price < old.price and new.lend_price is not distinct from old.lend_price and new.lend_deposit is not distinct from old.lend_deposit then
    new.lend_price := least(new.lend_price, new.price); new.lend_deposit := least(new.lend_deposit, new.price);
  end if;
  if new.lend_price is null or new.lend_price < 1 or new.lend_price > new.price then
    raise exception 'Le prix du prêt doit être entre 1 € et le prix de l’article';
  end if;
  if new.lend_deposit is null or new.lend_deposit < 1 or new.lend_deposit > new.price then
    raise exception 'La caution doit être entre 1 € et le prix de l’article';
  end if;
  if cardinality(new.lend_days) = 0 or not (new.lend_days <@ array[3,7,14,30]::smallint[]) then
    raise exception 'Choisis au moins une durée de prêt : 3, 7, 14 ou 30 jours';
  end if;
  new.lend_price := round(new.lend_price, 2); new.lend_deposit := round(new.lend_deposit, 2);
  return new;
end $$;
drop trigger if exists listings_lend_check on public.listings;
create trigger listings_lend_check before insert or update on public.listings
  for each row execute function public.listing_lend_check();

-- ---------- 2. DEMANDES DE PRÊT ----------
create table if not exists public.loans (
  id          uuid primary key default gen_random_uuid(),
  listing_id  uuid not null references public.listings(id) on delete cascade,
  borrower_id uuid not null references public.profiles(id) on delete cascade,
  lender_id   uuid not null references public.profiles(id) on delete cascade,
  days        smallint not null check (days in (3,7,14,30)),
  delivery    text not null check (delivery in ('main_propre','colis')),
  price       numeric(10,2) not null check (price >= 1),     -- figé au moment de la demande
  deposit     numeric(10,2) not null check (deposit >= 1),   -- figée au moment de la demande
  note        text check (char_length(note) <= 500),
  status      text not null default 'demandee'
              check (status in ('demandee','acceptee','refusee','annulee','en_cours','rendu','litige','terminee')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check (borrower_id <> lender_id)
);
create index if not exists loans_borrower_idx on public.loans (borrower_id, created_at desc);
create index if not exists loans_lender_idx on public.loans (lender_id, created_at desc);
create index if not exists loans_listing_idx on public.loans (listing_id, status);
alter table public.loans enable row level security;
drop policy if exists "prêts : voir les miens" on public.loans;
create policy "prêts : voir les miens" on public.loans for select to authenticated
  using (auth.uid() in (borrower_id, lender_id) or public.is_admin());
revoke insert, update, delete on public.loans from anon, authenticated;   -- tout passe par les fonctions

-- Message automatique dans la conversation emprunteur / prêteur
create or replace function public.loan_message(o public.loans, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare conv uuid;
begin
  insert into public.conversations (listing_id, buyer_id, seller_id)
  values (o.listing_id, o.borrower_id, o.lender_id) on conflict (listing_id, buyer_id) do nothing;
  select id into conv from public.conversations where listing_id = o.listing_id and buyer_id = o.borrower_id;
  insert into public.messages (conversation_id, sender_id, body) values (conv, auth.uid(), p_text);
exception when others then
  raise warning 'message de prêt non envoyé : %', sqlerrm;
end $$;
revoke all on function public.loan_message(public.loans, text) from public, anon, authenticated;

-- L'emprunteur fait une demande
create or replace function public.request_loan(p_listing uuid, p_days int, p_delivery text, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); l record; o public.loans; vac boolean; n text := nullif(trim(coalesce(p_note, '')), '');
begin
  if me is null then raise exception 'Connexion requise'; end if;
  select * into l from public.listings where id = p_listing;
  if l is null or l.status <> 'active' or not l.lend_on then raise exception 'Cet article n’est pas disponible au prêt'; end if;
  if l.seller_id = me then raise exception 'Tu ne peux pas emprunter ton propre article'; end if;
  if public.is_blocked(me, l.seller_id) then raise exception 'Membre indisponible.'; end if;
  select vacation into vac from public.profiles where id = l.seller_id;
  if coalesce(vac, false) then raise exception 'Ce membre est en vacances : réessaie à son retour'; end if;
  if not (p_days::smallint = any(l.lend_days)) then raise exception 'Cette durée n’est pas proposée pour cet article'; end if;
  if p_delivery not in ('main_propre','colis') then raise exception 'Choisis main propre ou colis'; end if;
  if n is not null and char_length(n) > 500 then raise exception 'Ton message est trop long (500 caractères au plus)'; end if;
  if n is not null and public.off_platform_reason(n) is not null then
    raise exception 'Pas de numéro, d’e-mail ni de moyen de paiement extérieur dans ton message : tout se fait sur Orleoo';
  end if;
  if exists (select 1 from public.loans where listing_id = l.id and borrower_id = me and status in ('demandee','acceptee','en_cours')) then
    raise exception 'Tu as déjà une demande en cours pour cet article';
  end if;
  if (select count(*) from public.loans where borrower_id = me and created_at > now() - interval '1 day') >= 10 then
    raise exception 'Tu as fait beaucoup de demandes aujourd’hui : réessaie demain';
  end if;
  insert into public.loans (listing_id, borrower_id, lender_id, days, delivery, price, deposit, note)
  values (l.id, me, l.seller_id, p_days, p_delivery, l.lend_price, l.lend_deposit, n) returning * into o;
  perform public.loan_message(o, 'Demande de prêt pour « ' || left(l.title, 80) || ' » : ' || p_days || ' jours, '
    || case when p_delivery = 'colis' then 'par colis' else 'en main propre' end
    || ', prêt ' || public.eur_txt(l.lend_price) || ' + caution ' || public.eur_txt(l.lend_deposit) || ' (rendue au retour).'
    || coalesce(' Message : « ' || n || ' ».', '') || ' Réponds depuis Mon compte › Prêts.');
  return o.id;
end $$;
revoke all on function public.request_loan(uuid, int, text, text) from public, anon;
grant execute on function public.request_loan(uuid, int, text, text) to authenticated;

-- Répondre : 'accepter' / 'refuser' (prêteur), 'annuler' (emprunteur, tant que rien n'est payé)
create or replace function public.respond_loan(p_loan uuid, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o public.loans; l record;
begin
  if me is null then raise exception 'Connexion requise'; end if;
  select * into o from public.loans where id = p_loan for update;
  if o is null or me not in (o.borrower_id, o.lender_id) then raise exception 'Demande introuvable'; end if;
  select * into l from public.listings where id = o.listing_id;
  if p_action = 'annuler' then
    if me <> o.borrower_id or o.status not in ('demandee','acceptee') then raise exception 'Action impossible'; end if;
    update public.loans set status = 'annulee', updated_at = now() where id = o.id;
    perform public.loan_message(o, 'J’ai annulé ma demande de prêt.');
    return;
  end if;
  if me <> o.lender_id or o.status <> 'demandee' then raise exception 'Cette demande n’attend plus de réponse'; end if;
  if p_action = 'refuser' then
    update public.loans set status = 'refusee', updated_at = now() where id = o.id;
    perform public.loan_message(o, 'Demande de prêt refusée.');
    return;
  end if;
  if p_action = 'accepter' then
    if l is null or l.status <> 'active' then raise exception 'Cet article n’est plus disponible'; end if;
    update public.loans set status = 'acceptee', updated_at = now() where id = o.id;
    perform public.loan_message(o, 'Demande de prêt acceptée ! Le paiement du prêt (' || public.eur_txt(o.price)
      || ') et de la caution (' || public.eur_txt(o.deposit) || ') se fera sur Orleoo'
      || case when public.achats_ouverts() then '.' else ' dès l’ouverture des paiements.' end);
    return;
  end if;
  raise exception 'Action inconnue';
end $$;
revoke all on function public.respond_loan(uuid, text) from public, anon;
grant execute on function public.respond_loan(uuid, text) to authenticated;

-- Article vendu, retiré ou plus prêté : les demandes pas encore commencées tombent
create or replace function public.listing_close_loans()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (new.status <> 'active' and old.status = 'active') or (old.lend_on and not new.lend_on) then
    update public.loans set status = 'annulee', updated_at = now()
     where listing_id = new.id and status in ('demandee','acceptee');
  end if;
  return new;
end $$;
revoke all on function public.listing_close_loans() from public, anon, authenticated;
drop trigger if exists listings_close_loans on public.listings;
create trigger listings_close_loans after update of status, lend_on on public.listings
  for each row execute function public.listing_close_loans();

-- Blocage : les demandes entre les deux membres tombent, et aucune nouvelle ne passe
create or replace function public.blocks_close_loans()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.loans set status = 'annulee', updated_at = now()
   where status in ('demandee','acceptee')
     and ((borrower_id = new.blocker_id and lender_id = new.blocked_id) or (borrower_id = new.blocked_id and lender_id = new.blocker_id));
  return new;
end $$;
revoke all on function public.blocks_close_loans() from public, anon, authenticated;
drop trigger if exists blocks_close_loans on public.blocks;
create trigger blocks_close_loans after insert on public.blocks for each row execute function public.blocks_close_loans();

select 'Prêt entre membres prêt (demandes et réponses ; paiement à l''ouverture)' as info;
