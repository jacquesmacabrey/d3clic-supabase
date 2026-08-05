/*
  Postconditions du schéma Onboarding.
  À exécuter après la migration 20260805140000_onboarding_core_schema.sql.
  Le test ne conserve aucune donnée.
*/

begin;

do $$
declare
  v_table text;
  v_tables constant text[] := array[
    'onboarding_services',
    'onboarding_jobs',
    'onboarding_units',
    'onboarding_content_blocks',
    'onboarding_contacts',
    'onboarding_documents',
    'onboarding_faq_items',
    'onboarding_checklist_items'
  ];
begin
  foreach v_table in array v_tables loop
    if pg_catalog.to_regclass('internal.' || v_table) is null then
      raise exception 'Test Onboarding : table absente %', v_table;
    end if;

    if not exists (
      select 1
      from pg_catalog.pg_class c
      join pg_catalog.pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'internal'
        and c.relname = v_table
        and c.relrowsecurity is true
    ) then
      raise exception 'Test Onboarding : RLS désactivée sur %', v_table;
    end if;
  end loop;
end;
$$;

do $$
begin
  if exists (
    select 1
    from information_schema.table_privileges p
    where p.table_schema = 'internal'
      and pg_catalog.left(p.table_name, 11) = 'onboarding_'
      and p.grantee in ('PUBLIC', 'anon', 'authenticated')
  ) then
    raise exception
      'Test Onboarding : privilège direct indésirable sur une table interne';
  end if;

  if exists (
    select 1
    from information_schema.routine_privileges p
    where p.specific_schema = 'internal'
      and pg_catalog.left(p.routine_name, 11) = 'onboarding_'
      and p.grantee in ('PUBLIC', 'anon', 'authenticated')
  ) then
    raise exception
      'Test Onboarding : fonction interne encore exécutable publiquement';
  end if;
end;
$$;

do $$
declare
  v_table text;
  v_tables constant text[] := array[
    'onboarding_services',
    'onboarding_jobs',
    'onboarding_units',
    'onboarding_content_blocks',
    'onboarding_contacts',
    'onboarding_documents',
    'onboarding_faq_items',
    'onboarding_checklist_items'
  ];
begin
  foreach v_table in array v_tables loop
    if not exists (
      select 1
      from pg_catalog.pg_constraint c
      where c.conrelid = pg_catalog.to_regclass('internal.' || v_table)
        and c.contype = 'f'
        and c.confrelid = pg_catalog.to_regclass('internal.institutions')
    ) then
      raise exception
        'Test Onboarding : FK directe institution absente sur %', v_table;
    end if;
  end loop;
end;
$$;

do $$
declare
  v_constraint text;
  v_constraints constant text[] := array[
    'onboarding_content_blocks_service_scope_fk',
    'onboarding_content_blocks_job_scope_fk',
    'onboarding_content_blocks_unit_scope_fk',
    'onboarding_contacts_service_scope_fk',
    'onboarding_contacts_job_scope_fk',
    'onboarding_contacts_unit_scope_fk',
    'onboarding_documents_service_scope_fk',
    'onboarding_documents_job_scope_fk',
    'onboarding_documents_unit_scope_fk',
    'onboarding_faq_items_service_scope_fk',
    'onboarding_faq_items_job_scope_fk',
    'onboarding_faq_items_unit_scope_fk',
    'onboarding_checklist_items_service_scope_fk',
    'onboarding_checklist_items_job_scope_fk',
    'onboarding_checklist_items_unit_scope_fk'
  ];
begin
  foreach v_constraint in array v_constraints loop
    if not exists (
      select 1
      from pg_catalog.pg_constraint c
      where c.conname = v_constraint
        and c.contype = 'f'
    ) then
      raise exception
        'Test Onboarding : FK composite absente %', v_constraint;
    end if;
  end loop;
end;
$$;

do $$
declare
  v_constraint text;
  v_constraints constant text[] := array[
    'onboarding_content_blocks_target_check',
    'onboarding_contacts_target_check',
    'onboarding_documents_target_check',
    'onboarding_faq_items_target_check',
    'onboarding_checklist_items_target_check',
    'onboarding_documents_storage_path_check'
  ];
begin
  foreach v_constraint in array v_constraints loop
    if not exists (
      select 1
      from pg_catalog.pg_constraint c
      where c.conname = v_constraint
        and c.contype = 'c'
    ) then
      raise exception
        'Test Onboarding : contrainte CHECK absente %', v_constraint;
    end if;
  end loop;
end;
$$;

insert into internal.institutions (institution_id, label)
values
  ('onboarding-test-a', 'Onboarding Test A'),
  ('onboarding-test-b', 'Onboarding Test B');

insert into internal.onboarding_services (
  service_id,
  institution_id,
  service_key,
  name,
  address_text
)
values
  (
    'a1000000-0000-4000-8000-000000000001'::uuid,
    'onboarding-test-a',
    'service-a',
    'Service A',
    'Adresse A'
  ),
  (
    'b1000000-0000-4000-8000-000000000001'::uuid,
    'onboarding-test-b',
    'service-b',
    'Service B',
    'Adresse B'
  );

insert into internal.onboarding_jobs (
  job_id,
  institution_id,
  service_id,
  job_key,
  name
)
values (
  'a2000000-0000-4000-8000-000000000001'::uuid,
  'onboarding-test-a',
  'a1000000-0000-4000-8000-000000000001'::uuid,
  'job-a',
  'Métier A'
);

insert into internal.onboarding_units (
  unit_id,
  institution_id,
  service_id,
  unit_key,
  name
)
values (
  'a3000000-0000-4000-8000-000000000001'::uuid,
  'onboarding-test-a',
  'a1000000-0000-4000-8000-000000000001'::uuid,
  'unit-a',
  'Unité A'
);

do $$
begin
  begin
    insert into internal.onboarding_content_blocks (
      institution_id,
      content_key,
      version,
      job_id,
      block_type
    )
    values (
      'onboarding-test-a',
      'job-without-service',
      1,
      'a2000000-0000-4000-8000-000000000001'::uuid,
      'first_day'
    );

    raise exception
      'Test Onboarding : job_id sans service_id accepté';
  exception
    when check_violation then null;
  end;
end;
$$;

do $$
begin
  begin
    insert into internal.onboarding_content_blocks (
      institution_id,
      content_key,
      version,
      service_id,
      job_id,
      block_type
    )
    values (
      'onboarding-test-b',
      'cross-institution-job',
      1,
      'b1000000-0000-4000-8000-000000000001'::uuid,
      'a2000000-0000-4000-8000-000000000001'::uuid,
      'first_day'
    );

    raise exception
      'Test Onboarding : ciblage métier inter-institution accepté';
  exception
    when foreign_key_violation then null;
  end;
end;
$$;

do $$
begin
  begin
    insert into internal.onboarding_documents (
      institution_id,
      document_key,
      version,
      storage_path
    )
    values (
      'onboarding-test-a',
      'wrong-storage-prefix',
      1,
      'onboarding-test-b/documents/test.pdf'
    );

    raise exception
      'Test Onboarding : chemin Storage inter-institution accepté';
  exception
    when check_violation then null;
  end;
end;
$$;

do $$
begin
  begin
    insert into internal.onboarding_faq_items (
      institution_id,
      faq_key,
      version
    )
    values (
      'onboarding-test-unknown',
      'unknown-institution',
      1
    );

    raise exception
      'Test Onboarding : institution inexistante acceptée';
  exception
    when foreign_key_violation then null;
  end;
end;
$$;

do $$
declare
  v_index text;
  v_indexes constant text[] := array[
    'onboarding_content_blocks_published_unique',
    'onboarding_contacts_published_unique',
    'onboarding_documents_published_unique',
    'onboarding_faq_items_published_unique',
    'onboarding_checklist_items_published_unique'
  ];
begin
  foreach v_index in array v_indexes loop
    if pg_catalog.to_regclass('internal.' || v_index) is null then
      raise exception
        'Test Onboarding : index de publication absent %', v_index;
    end if;
  end loop;
end;
$$;

rollback;
