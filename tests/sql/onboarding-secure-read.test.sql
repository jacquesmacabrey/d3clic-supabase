/* Postconditions de la lecture sécurisée Onboarding. */

begin;

do $$
begin
  if pg_catalog.to_regclass('internal.onboarding_access') is null then
    raise exception 'Test Onboarding : table onboarding_access absente';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'internal'
      and c.relname = 'onboarding_access'
      and c.relrowsecurity is true
      and c.relforcerowsecurity is true
  ) then
    raise exception 'Test Onboarding : RLS forcée absente sur onboarding_access';
  end if;

  if exists (
    select 1
    from information_schema.table_privileges p
    where p.table_schema = 'internal'
      and p.table_name = 'onboarding_access'
      and p.grantee in ('PUBLIC', 'anon', 'authenticated')
  ) then
    raise exception 'Test Onboarding : accès direct indésirable à onboarding_access';
  end if;

  if pg_catalog.to_regprocedure('server_api.read_onboarding_content(uuid)') is null
     or pg_catalog.to_regprocedure('public.onboarding_content_wrapper(uuid)') is null
  then
    raise exception 'Test Onboarding : fonction de lecture absente';
  end if;

  if has_function_privilege('anon', 'public.onboarding_content_wrapper(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.onboarding_content_wrapper(uuid)', 'EXECUTE')
  then
    raise exception 'Test Onboarding : wrapper exécutable directement par le client';
  end if;

  if not has_function_privilege('service_role', 'public.onboarding_content_wrapper(uuid)', 'EXECUTE') then
    raise exception 'Test Onboarding : wrapper indisponible pour l’Edge Function';
  end if;

  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'internal' and table_name = 'onboarding_contacts'
      and column_name = 'phone_publicly_validated'
  ) or not exists (
    select 1 from information_schema.columns
    where table_schema = 'internal' and table_name = 'onboarding_contacts'
      and column_name = 'email_publicly_validated'
  ) then
    raise exception 'Test Onboarding : indicateurs de validation des coordonnées absents';
  end if;
end;
$$;

rollback;
