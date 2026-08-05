/*
  Tests du cycle éditorial Onboarding.
  À exécuter après les migrations :
  - 20260805140000_onboarding_core_schema.sql
  - 20260805143000_onboarding_editorial_guardrails.sql

  Le test est transactionnel et ne conserve aucune donnée.
*/

begin;

insert into internal.institutions (institution_id, label)
values ('onboarding-test', 'Institution test Onboarding');

insert into internal.users (
  user_uuid,
  display_name,
  institution_id,
  active
)
values (
  '11111111-1111-4111-8111-111111111111'::uuid,
  'Test éditorial',
  'onboarding-test',
  true
);

insert into internal.onboarding_services (
  service_id,
  institution_id,
  service_key,
  name,
  address_text
)
values (
  '22222222-2222-4222-8222-222222222222'::uuid,
  'onboarding-test',
  'test-service',
  'Service test',
  'Adresse test'
);

-- Une nouvelle version doit toujours commencer en draft.
do $$
begin
  begin
    insert into internal.onboarding_content_blocks (
      institution_id,
      content_key,
      service_id,
      block_type,
      title,
      body_markdown,
      status,
      validated_by,
      validated_at,
      published_by,
      published_at
    ) values (
      'onboarding-test',
      'direct-published',
      '22222222-2222-4222-8222-222222222222'::uuid,
      'welcome',
      'Titre',
      'Contenu',
      'published',
      '11111111-1111-4111-8111-111111111111'::uuid,
      pg_catalog.now(),
      '11111111-1111-4111-8111-111111111111'::uuid,
      pg_catalog.now()
    );
    raise exception 'ÉCHEC : insertion directe published acceptée';
  exception
    when others then
      if sqlerrm = 'ÉCHEC : insertion directe published acceptée' then
        raise;
      end if;
  end;
end;
$$;

insert into internal.onboarding_content_blocks (
  content_block_id,
  institution_id,
  content_key,
  service_id,
  block_type,
  title,
  body_markdown,
  status,
  created_by
)
values (
  '33333333-3333-4333-8333-333333333333'::uuid,
  'onboarding-test',
  'workflow-ok',
  '22222222-2222-4222-8222-222222222222'::uuid,
  'welcome',
  'Bienvenue',
  'Contenu validable',
  'draft',
  '11111111-1111-4111-8111-111111111111'::uuid
);

-- draft -> validated doit être refusé.
do $$
begin
  begin
    update internal.onboarding_content_blocks
    set status = 'validated',
        validated_by = '11111111-1111-4111-8111-111111111111'::uuid,
        validated_at = pg_catalog.now()
    where content_block_id =
      '33333333-3333-4333-8333-333333333333'::uuid;
    raise exception 'ÉCHEC : transition draft -> validated acceptée';
  exception
    when others then
      if sqlerrm = 'ÉCHEC : transition draft -> validated acceptée' then
        raise;
      end if;
  end;
end;
$$;

-- draft -> published doit être refusé même si l'état final satisfait les CHECK.
do $$
begin
  begin
    update internal.onboarding_content_blocks
    set status = 'published',
        validated_by = '11111111-1111-4111-8111-111111111111'::uuid,
        validated_at = pg_catalog.now(),
        published_by = '11111111-1111-4111-8111-111111111111'::uuid,
        published_at = pg_catalog.now()
    where content_block_id =
      '33333333-3333-4333-8333-333333333333'::uuid;
    raise exception 'ÉCHEC : transition draft -> published acceptée';
  exception
    when others then
      if sqlerrm = 'ÉCHEC : transition draft -> published acceptée' then
        raise;
      end if;
  end;
end;
$$;

-- Parcours positif complet.
update internal.onboarding_content_blocks
set status = 'needs_review'
where content_block_id =
  '33333333-3333-4333-8333-333333333333'::uuid;

-- needs_review -> published doit également être refusé.
do $$
begin
  begin
    update internal.onboarding_content_blocks
    set status = 'published',
        validated_by = '11111111-1111-4111-8111-111111111111'::uuid,
        validated_at = pg_catalog.now(),
        published_by = '11111111-1111-4111-8111-111111111111'::uuid,
        published_at = pg_catalog.now()
    where content_block_id =
      '33333333-3333-4333-8333-333333333333'::uuid;
    raise exception
      'ÉCHEC : transition needs_review -> published acceptée';
  exception
    when others then
      if sqlerrm =
        'ÉCHEC : transition needs_review -> published acceptée'
      then
        raise;
      end if;
  end;
end;
$$;

update internal.onboarding_content_blocks
set status = 'validated',
    validated_by = '11111111-1111-4111-8111-111111111111'::uuid,
    validated_at = pg_catalog.now()
where content_block_id =
  '33333333-3333-4333-8333-333333333333'::uuid;

update internal.onboarding_content_blocks
set status = 'published',
    published_by = '11111111-1111-4111-8111-111111111111'::uuid,
    published_at = pg_catalog.now()
where content_block_id =
  '33333333-3333-4333-8333-333333333333'::uuid;

do $$
begin
  if not exists (
    select 1
    from internal.onboarding_content_blocks
    where content_block_id =
      '33333333-3333-4333-8333-333333333333'::uuid
      and status = 'published'
      and validated_by is not null
      and validated_at is not null
      and published_by is not null
      and published_at is not null
  ) then
    raise exception 'ÉCHEC : parcours éditorial positif incomplet';
  end if;
end;
$$;

-- display_order est une métadonnée administrative modifiable sans version.
update internal.onboarding_content_blocks
set display_order = 25
where content_block_id =
  '33333333-3333-4333-8333-333333333333'::uuid;

-- Le contenu métier publié reste immuable.
do $$
begin
  begin
    update internal.onboarding_content_blocks
    set title = 'Titre modifié après publication'
    where content_block_id =
      '33333333-3333-4333-8333-333333333333'::uuid;
    raise exception 'ÉCHEC : modification métier publiée acceptée';
  exception
    when others then
      if sqlerrm = 'ÉCHEC : modification métier publiée acceptée' then
        raise;
      end if;
  end;
end;
$$;

-- Archivage autorisé et désactivation automatique.
update internal.onboarding_content_blocks
set status = 'archived'
where content_block_id =
  '33333333-3333-4333-8333-333333333333'::uuid;

do $$
begin
  if not exists (
    select 1
    from internal.onboarding_content_blocks
    where content_block_id =
      '33333333-3333-4333-8333-333333333333'::uuid
      and status = 'archived'
      and active is false
      and archived_at is not null
  ) then
    raise exception 'ÉCHEC : archivage incomplet';
  end if;
end;
$$;

-- Une version archivée est immuable.
do $$
begin
  begin
    update internal.onboarding_content_blocks
    set display_order = 30
    where content_block_id =
      '33333333-3333-4333-8333-333333333333'::uuid;
    raise exception 'ÉCHEC : version archivée modifiable';
  exception
    when others then
      if sqlerrm = 'ÉCHEC : version archivée modifiable' then
        raise;
      end if;
  end;
end;
$$;

-- Retour validated -> draft : métadonnées de validation réinitialisées.
insert into internal.onboarding_content_blocks (
  content_block_id,
  institution_id,
  content_key,
  service_id,
  block_type,
  title,
  body_markdown,
  status
)
values (
  '44444444-4444-4444-8444-444444444444'::uuid,
  'onboarding-test',
  'return-draft',
  '22222222-2222-4222-8222-222222222222'::uuid,
  'welcome',
  'Deuxième contenu',
  'Contenu à reprendre',
  'draft'
);

update internal.onboarding_content_blocks
set status = 'needs_review'
where content_block_id =
  '44444444-4444-4444-8444-444444444444'::uuid;

update internal.onboarding_content_blocks
set status = 'validated',
    validated_by = '11111111-1111-4111-8111-111111111111'::uuid,
    validated_at = pg_catalog.now()
where content_block_id =
  '44444444-4444-4444-8444-444444444444'::uuid;

update internal.onboarding_content_blocks
set status = 'draft'
where content_block_id =
  '44444444-4444-4444-8444-444444444444'::uuid;

do $$
begin
  if not exists (
    select 1
    from internal.onboarding_content_blocks
    where content_block_id =
      '44444444-4444-4444-8444-444444444444'::uuid
      and status = 'draft'
      and validated_by is null
      and validated_at is null
      and published_by is null
      and published_at is null
      and archived_at is null
  ) then
    raise exception
      'ÉCHEC : retour en brouillon sans remise à zéro éditoriale';
  end if;
end;
$$;

-- FORCE RLS doit être actif sur les huit tables.
do $$
declare
  v_missing text;
begin
  select pg_catalog.string_agg(c.relname, ', ' order by c.relname)
  into v_missing
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'internal'
    and c.relname = any(array[
      'onboarding_services',
      'onboarding_jobs',
      'onboarding_units',
      'onboarding_content_blocks',
      'onboarding_contacts',
      'onboarding_documents',
      'onboarding_faq_items',
      'onboarding_checklist_items'
    ])
    and c.relforcerowsecurity is not true;

  if v_missing is not null then
    raise exception 'ÉCHEC : FORCE RLS absent sur %', v_missing;
  end if;
end;
$$;

rollback;
