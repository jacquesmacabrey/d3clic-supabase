/*
  Postconditions structurelles et comportementales de la lecture sécurisée.

  Le scénario est entièrement transactionnel : trois appareils synthétiques,
  deux institutions, plusieurs audiences et deux politiques de visibilité des
  coordonnées. Aucune donnée de test n'est conservée.
*/

begin;

do $structure$
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
$structure$;

insert into auth.users (
  id, aud, role, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at, is_anonymous
)
values
  ('92000000-0000-4000-8000-000000000001', 'authenticated', 'authenticated', '{}', '{}', pg_catalog.now(), pg_catalog.now(), true),
  ('92000000-0000-4000-8000-000000000002', 'authenticated', 'authenticated', '{}', '{}', pg_catalog.now(), pg_catalog.now(), true),
  ('92000000-0000-4000-8000-000000000003', 'authenticated', 'authenticated', '{}', '{}', pg_catalog.now(), pg_catalog.now(), true);

insert into internal.institutions (institution_id, label)
values
  ('onboarding-secure-test-a', 'Institution sécurisée A'),
  ('onboarding-secure-test-b', 'Institution sécurisée B');

insert into internal.users (user_uuid, display_name, institution_id, active)
values
  ('91000000-0000-4000-8000-000000000001', 'Lecteur A', 'onboarding-secure-test-a', true),
  ('91000000-0000-4000-8000-000000000002', 'Lecteur B', 'onboarding-secure-test-b', true),
  ('91000000-0000-4000-8000-000000000003', 'Sans accès', 'onboarding-secure-test-a', true);

insert into internal.devices (device_auth_uid, user_uuid, activated_at)
values
  ('92000000-0000-4000-8000-000000000001', '91000000-0000-4000-8000-000000000001', pg_catalog.now()),
  ('92000000-0000-4000-8000-000000000002', '91000000-0000-4000-8000-000000000002', pg_catalog.now()),
  ('92000000-0000-4000-8000-000000000003', '91000000-0000-4000-8000-000000000003', pg_catalog.now());

insert into internal.onboarding_access (
  user_uuid, institution_id, audience_type, expires_at
)
values
  ('91000000-0000-4000-8000-000000000001', 'onboarding-secure-test-a', 'collaborator', pg_catalog.now() + interval '1 month'),
  ('91000000-0000-4000-8000-000000000002', 'onboarding-secure-test-b', 'collaborator', pg_catalog.now() + interval '1 month');

insert into internal.onboarding_content_blocks (
  content_block_id, institution_id, content_key, audience_type,
  block_type, title, body_markdown, status, created_by
)
values
  ('93000000-0000-4000-8000-000000000001', 'onboarding-secure-test-a', 'a-global-published', null, 'welcome', 'Global A', 'Publié pour A', 'draft', '91000000-0000-4000-8000-000000000001'),
  ('93000000-0000-4000-8000-000000000002', 'onboarding-secure-test-a', 'a-collaborator-published', 'collaborator', 'welcome', 'Collaborateur A', 'Publié pour les collaborateurs', 'draft', '91000000-0000-4000-8000-000000000001'),
  ('93000000-0000-4000-8000-000000000003', 'onboarding-secure-test-a', 'a-apprentice-published', 'apprentice', 'welcome', 'Apprenti A', 'Publié pour les apprentis', 'draft', '91000000-0000-4000-8000-000000000001'),
  ('93000000-0000-4000-8000-000000000004', 'onboarding-secure-test-a', 'a-draft', null, 'welcome', 'Brouillon A', 'Ne doit jamais sortir', 'draft', '91000000-0000-4000-8000-000000000001'),
  ('93000000-0000-4000-8000-000000000005', 'onboarding-secure-test-b', 'b-global-published', null, 'welcome', 'Global B', 'Publié pour B', 'draft', '91000000-0000-4000-8000-000000000002');

insert into internal.onboarding_contacts (
  contact_id, institution_id, contact_key, audience_type,
  name, role_label, phone, email,
  phone_publicly_validated, email_publicly_validated,
  status, created_by
)
values
  ('94000000-0000-4000-8000-000000000001', 'onboarding-secure-test-a', 'a-contact-masked', null, 'Contact masqué', 'Service test', '+41 32 000 00 01', 'masked@example.invalid', false, false, 'draft', '91000000-0000-4000-8000-000000000001'),
  ('94000000-0000-4000-8000-000000000002', 'onboarding-secure-test-a', 'a-contact-visible', 'collaborator', 'Contact visible', 'Service test', '+41 32 000 00 02', 'visible@example.invalid', true, true, 'draft', '91000000-0000-4000-8000-000000000001'),
  ('94000000-0000-4000-8000-000000000003', 'onboarding-secure-test-b', 'b-contact-visible', null, 'Contact B', 'Service test', '+41 32 000 00 03', 'b@example.invalid', true, true, 'draft', '91000000-0000-4000-8000-000000000002');

update internal.onboarding_content_blocks
set status = 'needs_review'
where content_key <> 'a-draft'
  and institution_id in ('onboarding-secure-test-a', 'onboarding-secure-test-b');

update internal.onboarding_contacts
set status = 'needs_review'
where institution_id in ('onboarding-secure-test-a', 'onboarding-secure-test-b');

update internal.onboarding_content_blocks
set status = 'validated',
    validated_by = case institution_id
      when 'onboarding-secure-test-a' then '91000000-0000-4000-8000-000000000001'::uuid
      else '91000000-0000-4000-8000-000000000002'::uuid
    end,
    validated_at = pg_catalog.now()
where status = 'needs_review'
  and institution_id in ('onboarding-secure-test-a', 'onboarding-secure-test-b');

update internal.onboarding_contacts
set status = 'validated',
    validated_by = case institution_id
      when 'onboarding-secure-test-a' then '91000000-0000-4000-8000-000000000001'::uuid
      else '91000000-0000-4000-8000-000000000002'::uuid
    end,
    validated_at = pg_catalog.now()
where status = 'needs_review'
  and institution_id in ('onboarding-secure-test-a', 'onboarding-secure-test-b');

update internal.onboarding_content_blocks
set status = 'published',
    published_by = validated_by,
    published_at = pg_catalog.now()
where status = 'validated'
  and institution_id in ('onboarding-secure-test-a', 'onboarding-secure-test-b');

update internal.onboarding_contacts
set status = 'published',
    published_by = validated_by,
    published_at = pg_catalog.now()
where status = 'validated'
  and institution_id in ('onboarding-secure-test-a', 'onboarding-secure-test-b');

do $behavior$
declare
  v_a jsonb;
  v_b jsonb;
  v_denied jsonb;
begin
  v_a := server_api.read_onboarding_content(
    '92000000-0000-4000-8000-000000000001'::uuid
  );
  v_b := server_api.read_onboarding_content(
    '92000000-0000-4000-8000-000000000002'::uuid
  );
  v_denied := server_api.read_onboarding_content(
    '92000000-0000-4000-8000-000000000003'::uuid
  );

  if v_denied->>'authorized' <> 'false'
     or v_denied->>'error' <> 'not_authorized'
  then
    raise exception 'Test Onboarding : appareil sans accès autorisé';
  end if;

  if v_a->>'authorized' <> 'true'
     or v_a #>> '{context,audience_type}' <> 'collaborator'
  then
    raise exception 'Test Onboarding : contexte A incorrect';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_a->'content') item
    where item->>'key' = 'a-global-published'
  ) or not exists (
    select 1 from jsonb_array_elements(v_a->'content') item
    where item->>'key' = 'a-collaborator-published'
  ) then
    raise exception 'Test Onboarding : contenu publié A manquant';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_a->'content') item
    where item->>'key' in ('a-draft', 'a-apprentice-published', 'b-global-published')
  ) then
    raise exception 'Test Onboarding : fuite brouillon, audience ou institution';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_a->'contacts') item
    where item->>'key' = 'a-contact-masked'
      and item->>'phone' is null
      and item->>'email' is null
  ) then
    raise exception 'Test Onboarding : coordonnées non validées exposées';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_a->'contacts') item
    where item->>'key' = 'a-contact-visible'
      and item->>'phone' = '+41 32 000 00 02'
      and item->>'email' = 'visible@example.invalid'
  ) then
    raise exception 'Test Onboarding : coordonnées validées masquées';
  end if;

  if v_b->>'authorized' <> 'true'
     or not exists (
       select 1 from jsonb_array_elements(v_b->'content') item
       where item->>'key' = 'b-global-published'
     )
     or exists (
       select 1 from jsonb_array_elements(v_b->'content') item
       where item->>'key' like 'a-%'
     )
  then
    raise exception 'Test Onboarding : isolement inter-institution incorrect';
  end if;
end;
$behavior$;

rollback;
