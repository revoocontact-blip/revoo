-- =====================================================================
-- ORLEOO — nouvelles rubriques : Électronique et Maison
-- À coller en entier dans Supabase > SQL Editor > New query, puis « Run ».
-- Peut être relancé sans risque.
-- =====================================================================
do $$ declare c record; begin
  for c in select conname from pg_constraint
            where conrelid = 'public.listings'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) ilike '%category%'
  loop execute format('alter table public.listings drop constraint %I', c.conname); end loop;
end $$;
alter table public.listings add constraint listings_category_check
  check (category in ('Femme','Homme','Enfant','Unisexe','Livres','Électronique','Maison'));

select 'Rubriques prêtes : Mode, Livres, Électronique, Maison' as info;
