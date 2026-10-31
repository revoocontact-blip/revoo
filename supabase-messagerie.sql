-- =====================================================================
-- REVOO — messagerie entre acheteurs et vendeurs
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- (À lancer après supabase-revoo.sql. Peut être relancé sans risque.)
-- =====================================================================

-- ---------- 1. CONVERSATIONS (une par article et par acheteur) ----------
create table if not exists public.conversations (
  id               uuid primary key default gen_random_uuid(),
  listing_id       uuid references public.listings(id) on delete set null,
  buyer_id         uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  seller_id        uuid not null references public.profiles(id) on delete cascade,
  created_at       timestamptz not null default now(),
  last_message_at  timestamptz not null default now(),
  check (buyer_id <> seller_id),
  unique (listing_id, buyer_id)
);
create index if not exists conversations_buyer_idx  on public.conversations (buyer_id, last_message_at desc);
create index if not exists conversations_seller_idx on public.conversations (seller_id, last_message_at desc);

-- ---------- 2. MESSAGES ----------
create table if not exists public.messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations(id) on delete cascade,
  sender_id        uuid not null references public.profiles(id) on delete cascade default auth.uid(),
  body             text not null check (char_length(trim(body)) between 1 and 2000),
  created_at       timestamptz not null default now(),
  read_at          timestamptz
);
create index if not exists messages_conv_idx on public.messages (conversation_id, created_at);

-- Est-ce que l'utilisateur connecté participe à cette conversation ?
create or replace function public.is_participant(conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.conversations c
                 where c.id = conv and auth.uid() in (c.buyer_id, c.seller_id));
$$;

-- Met à jour la date du dernier message de la conversation
create or replace function public.touch_conversation()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations set last_message_at = new.created_at where id = new.conversation_id;
  return new;
end $$;
drop trigger if exists messages_touch_conversation on public.messages;
create trigger messages_touch_conversation after insert on public.messages
  for each row execute function public.touch_conversation();

-- ---------- 3. SÉCURITÉ ----------
alter table public.conversations enable row level security;
alter table public.messages      enable row level security;

-- Conversations : visibles uniquement par l'acheteur et le vendeur
drop policy if exists "voir mes conversations" on public.conversations;
create policy "voir mes conversations" on public.conversations
  for select to authenticated using (auth.uid() in (buyer_id, seller_id));

-- Un acheteur ouvre une conversation sur une annonce en ligne, avec le vrai vendeur de l'annonce
drop policy if exists "ouvrir une conversation" on public.conversations;
create policy "ouvrir une conversation" on public.conversations
  for insert to authenticated with check (
    auth.uid() = buyer_id
    and exists (select 1 from public.listings l
                where l.id = listing_id and l.seller_id = conversations.seller_id and l.status = 'active')
  );

-- Messages : lisibles et envoyés uniquement par les participants
drop policy if exists "lire les messages" on public.messages;
create policy "lire les messages" on public.messages
  for select to authenticated using (public.is_participant(conversation_id));
drop policy if exists "envoyer un message" on public.messages;
create policy "envoyer un message" on public.messages
  for insert to authenticated with check (auth.uid() = sender_id and public.is_participant(conversation_id));

-- Marquer comme lu : seulement les messages reçus, et seulement la colonne read_at
drop policy if exists "marquer comme lu" on public.messages;
create policy "marquer comme lu" on public.messages
  for update to authenticated
  using (public.is_participant(conversation_id) and sender_id <> auth.uid())
  with check (public.is_participant(conversation_id) and sender_id <> auth.uid());
revoke update on public.messages from authenticated, anon;
grant update (read_at) on public.messages to authenticated;

-- ---------- 4. TEMPS RÉEL (nouveaux messages affichés sans recharger) ----------
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; end $$;
