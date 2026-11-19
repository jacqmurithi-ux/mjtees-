-- DESTRUCTIVE: remove the former MJ application structures and business records.
-- Explicit preservation boundary: do not modify auth.users, auth.identities, auth.sessions, or Auth configuration.
do $$ declare r record; begin
  for r in select schemaname,viewname from pg_views where schemaname='public'
    and not exists(select 1 from pg_depend d where d.classid='pg_class'::regclass and d.objid=(quote_ident(schemaname)||'.'||quote_ident(viewname))::regclass and d.refclassid='pg_extension'::regclass and d.deptype='e')
  loop execute format('drop view if exists %I.%I cascade',r.schemaname,r.viewname); end loop;
  for r in select schemaname,matviewname from pg_matviews where schemaname='public'
    and not exists(select 1 from pg_depend d where d.classid='pg_class'::regclass and d.objid=(quote_ident(schemaname)||'.'||quote_ident(matviewname))::regclass and d.refclassid='pg_extension'::regclass and d.deptype='e')
  loop execute format('drop materialized view if exists %I.%I cascade',r.schemaname,r.matviewname); end loop;
  for r in select tablename from pg_tables p where schemaname='public'
    and not exists(select 1 from pg_depend d where d.classid='pg_class'::regclass and d.objid=(quote_ident(p.schemaname)||'.'||quote_ident(p.tablename))::regclass and d.refclassid='pg_extension'::regclass and d.deptype='e')
  loop execute format('drop table if exists public.%I cascade',r.tablename); end loop;
  for r in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind in('f','p')
    and not exists(select 1 from pg_depend d where d.classid='pg_proc'::regclass and d.objid=p.oid and d.refclassid='pg_extension'::regclass and d.deptype='e')
  loop execute format('drop routine if exists %s cascade',r.signature); end loop;
  for r in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind='S'
    and not exists(select 1 from pg_depend d where d.classid='pg_class'::regclass and d.objid=c.oid and d.refclassid='pg_extension'::regclass and d.deptype='e')
  loop execute format('drop sequence if exists public.%I cascade',r.relname); end loop;
  for r in select t.typname from pg_type t join pg_namespace n on n.oid=t.typnamespace
    where n.nspname='public' and t.typtype in('e','d')
    and not exists(select 1 from pg_depend d where d.classid='pg_type'::regclass and d.objid=t.oid and d.refclassid='pg_extension'::regclass and d.deptype='e')
  loop execute format('drop type if exists public.%I cascade',r.typname); end loop;
end $$;
-- The previous private schema was dedicated to the former MJ application.
drop schema if exists private cascade;
create schema private;
-- Delete the old app's private website uploads only.
delete from storage.objects where bucket_id='website-media';
delete from storage.buckets where id='website-media';
