/*
  D3clic — Onboarding
  Index couvrants pour les clés étrangères du module.

  Les tables éditoriales sont peu volumineuses, mais ces index évitent les
  scans complets lors des contrôles de références, suppressions restreintes
  et mises à jour des clés parentes. La migration est additive et idempotente.
*/

begin;

create index if not exists onboarding_jobs_service_scope_fk_idx
  on internal.onboarding_jobs (service_id, institution_id);

create index if not exists onboarding_units_service_scope_fk_idx
  on internal.onboarding_units (service_id, institution_id);

do $indexes$
declare
  v_table text;
  v_actor_column text;
begin
  foreach v_table in array array[
    'onboarding_content_blocks',
    'onboarding_contacts',
    'onboarding_documents',
    'onboarding_faq_items',
    'onboarding_checklist_items'
  ]
  loop
    execute pg_catalog.format(
      'create index if not exists %I on internal.%I (service_id, institution_id)',
      v_table || '_service_scope_fk_idx',
      v_table
    );

    execute pg_catalog.format(
      'create index if not exists %I on internal.%I (job_id, institution_id, service_id)',
      v_table || '_job_scope_fk_idx',
      v_table
    );

    execute pg_catalog.format(
      'create index if not exists %I on internal.%I (unit_id, institution_id, service_id)',
      v_table || '_unit_scope_fk_idx',
      v_table
    );

    foreach v_actor_column in array array[
      'created_by',
      'updated_by',
      'validated_by',
      'published_by'
    ]
    loop
      execute pg_catalog.format(
        'create index if not exists %I on internal.%I (%I, institution_id)',
        v_table || '_' || v_actor_column || '_fk_idx',
        v_table,
        v_actor_column
      );
    end loop;
  end loop;
end;
$indexes$;

commit;
