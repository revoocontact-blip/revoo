-- 45. Messagerie : supprimer un de ses messages, masquer une conversation
-- Un message supprimé disparaît pour les deux membres (« Message supprimé »).
-- Le texte d'origine est gardé à part, lisible seulement par la modération (preuve en cas d'arnaque).

alter table public.messages add column if not exists deleted_at timestamptz;

create table if not exists public.deleted_messages (
  message_id uuid primary key references public.messages(id) on delete cascade,
  conversation_id uuid not null,
  sender_id uuid,
  body text not null,
  deleted_at timestamptz not null default now()
);
alter table public.deleted_messages enable row level security;   -- aucune règle : lisible seulement via les fonctions de modération
revoke all on public.deleted_messages from anon, authenticated;

create or replace function public.delete_message(p_msg uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m record;
begin
  if auth.uid() is null then raise exception 'Connecte-toi pour continuer'; end if;
  select * into m from public.messages where id = p_msg for update;
  if m is null or m.sender_id is distinct from auth.uid() then raise exception 'Tu ne peux supprimer que tes propres messages'; end if;
  if m.deleted_at is not null then return; end if;
  insert into public.deleted_messages(message_id, conversation_id, sender_id, body) values (m.id, m.conversation_id, m.sender_id, m.body)
    on conflict (message_id) do nothing;
  update public.messages set body = 'Message supprimé', deleted_at = now() where id = p_msg;
end $$;
revoke execute on function public.delete_message(uuid) from public, anon;
grant execute on function public.delete_message(uuid) to authenticated;

-- Masquer une conversation de sa liste (elle revient si un nouveau message arrive)
create table if not exists public.conversation_hidden (
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  hidden_at timestamptz not null default now(),
  primary key (user_id, conversation_id)
);
alter table public.conversation_hidden enable row level security;
drop policy if exists "voir mes conversations masquées" on public.conversation_hidden;
create policy "voir mes conversations masquées" on public.conversation_hidden for select to authenticated using (user_id = auth.uid());
revoke insert, update, delete on public.conversation_hidden from anon, authenticated;
grant select on public.conversation_hidden to authenticated;

create or replace function public.hide_conversation(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Connecte-toi pour continuer'; end if;
  if not exists (select 1 from public.conversations c where c.id = p_conv and auth.uid() in (c.buyer_id, c.seller_id)) then
    raise exception 'Conversation introuvable';
  end if;
  insert into public.conversation_hidden(user_id, conversation_id, hidden_at) values (auth.uid(), p_conv, now())
    on conflict (user_id, conversation_id) do update set hidden_at = now();
end $$;
revoke execute on function public.hide_conversation(uuid) from public, anon;
grant execute on function public.hide_conversation(uuid) to authenticated;

-- La modération voit le texte d'origine des messages supprimés
create or replace function public.read_conversation(p_conv uuid)
returns table(sender text, sender_id uuid, body text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  perform public.require_perm('conversations');
  select * into c from public.conversations where id = p_conv;
  if c is null then raise exception 'Conversation introuvable'; end if;
  perform public.log_action('Conversation consultée', c.seller_id, c.listing_id,
    'entre @' || coalesce((select name from public.profiles where id = c.buyer_id), '?') || ' et @' || coalesce((select name from public.profiles where id = c.seller_id), '?'));
  return query select coalesce(p.name, 'membre supprimé'), m.sender_id,
      case when m.deleted_at is not null then '[supprimé par son auteur le ' || to_char(m.deleted_at at time zone 'Europe/Paris', 'DD/MM HH24:MI') || '] ' || coalesce(d.body, '')
           else m.body end,
      m.created_at
    from public.messages m left join public.profiles p on p.id = m.sender_id
    left join public.deleted_messages d on d.message_id = m.id
    where m.conversation_id = p_conv order by m.created_at limit 500;
end $$;
