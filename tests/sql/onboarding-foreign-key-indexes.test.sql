/*
  D3clic — Onboarding
  Vérifie que chaque clé étrangère du module possède un index couvrant valide.
*/

begin;

do $test$
declare
  v_missing text;
begin
  with missing_foreign_keys as (
    select
      n.nspname as schema_name,
      c.relname as table_name,
      con.conname as constraint_name,
      con.conkey
    from pg_catalog.pg_constraint con
    join pg_catalog.pg_class c
      on c.oid = con.conrelid
    join pg_catalog.pg_namespace n
      on n.oid = c.relnamespace
    where con.contype = 'f'
      and n.nspname = 'internal'
      and c.relname like 'onboarding_%'
      and not exists (
        select 1
        from pg_catalog.pg_index idx
        where idx.indrelid = con.conrelid
          and idx.indisvalid
          and idx.indisready
          and idx.indpred is null
          and idx.indnkeyatts >= pg_catalog.cardinality(con.conkey)
          and (idx.indkey::smallint[])[0:pg_catalog.cardinality(con.conkey) - 1]
              = con.conkey
      )
  )
  select pg_catalog.string_agg(
           pg_catalog.format('%I.%I (%I)', schema_name, table_name, constraint_name),
           ', '
           order by table_name, constraint_name
         )
    into v_missing
  from missing_foreign_keys;

  if v_missing is not null then
    raise exception
      'Onboarding : clés étrangères sans index couvrant : %',
      v_missing;
  end if;
end;
$test$;

rollback;
