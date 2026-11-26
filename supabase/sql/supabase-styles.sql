-- =====================================================================
-- ORLEOO — deux nouveaux styles : Sport et Bohème (6 styles au total)
-- À coller dans Supabase > SQL Editor > New query, puis « Run ». (Peut être relancé.)
-- =====================================================================
do $$ declare c record; begin
  for c in select conname from pg_constraint
            where conrelid = 'public.listings'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%style%Vintage%'
  loop execute format('alter table public.listings drop constraint %I', c.conname); end loop;
end $$;
alter table public.listings add constraint listings_style_check
  check (style in ('Vintage','Streetwear','Chic','Doux','Sport','Bohème'));

-- Vérification : doit afficher la nouvelle liste des styles
select pg_get_constraintdef(oid) as styles_autorises from pg_constraint where conname = 'listings_style_check';
