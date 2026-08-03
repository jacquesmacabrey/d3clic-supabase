/* RAG-10.7 — postconditions staging. Toutes les mutations sont annulées. */
begin;

do $$
declare
  v_missing text[];
begin
  select pg_catalog.array_agg(name) into v_missing
  from (values
    ('internal.rag_rule_audit_events'),
    ('internal.rag_rule_operation_receipts'),
    ('internal.rag_rule_template_source_signatures')
  ) required(name)
  where pg_catalog.to_regclass(name) is null;
  if v_missing is not null then
    raise exception 'Tables RAG-10.7 absentes : %', v_missing;
  end if;
end;
$$;

do $$
declare
  v_missing text[];
begin
  select pg_catalog.array_agg(name) into v_missing
  from (values
    ('public.list_rag_rule_sets_admin_wrapper(uuid,uuid,text,text[],boolean,text,integer)'),
    ('public.get_rag_rule_set_admin_wrapper(uuid,uuid)'),
    ('public.get_rag_rule_audit_admin_wrapper(uuid,uuid,text,integer)'),
    ('public.create_rag_rule_revision_wrapper(uuid,uuid)'),
    ('public.save_rag_rule_set_correction_wrapper(uuid,uuid,bigint,uuid,jsonb)'),
    ('public.confirm_rag_rule_set_wrapper(uuid,uuid,bigint,uuid,boolean)'),
    ('public.reject_rag_rule_set_wrapper(uuid,uuid,bigint,uuid,text,text)'),
    ('public.audit_rag_rule_simulation_wrapper(uuid,uuid,boolean,text,integer)')
  ) required(name)
  where pg_catalog.to_regprocedure(name) is null;
  if v_missing is not null then
    raise exception 'RPC RAG-10.7 absents : %', v_missing;
  end if;
end;
$$;

do $$
declare
  v_name text;
begin
  foreach v_name in array array[
    'public.list_rag_rule_sets_admin_wrapper(uuid,uuid,text,text[],boolean,text,integer)',
    'public.get_rag_rule_set_admin_wrapper(uuid,uuid)',
    'public.get_rag_rule_audit_admin_wrapper(uuid,uuid,text,integer)',
    'public.create_rag_rule_revision_wrapper(uuid,uuid)',
    'public.save_rag_rule_set_correction_wrapper(uuid,uuid,bigint,uuid,jsonb)',
    'public.confirm_rag_rule_set_wrapper(uuid,uuid,bigint,uuid,boolean)',
    'public.reject_rag_rule_set_wrapper(uuid,uuid,bigint,uuid,text,text)',
    'public.audit_rag_rule_simulation_wrapper(uuid,uuid,boolean,text,integer)'
  ] loop
    if pg_catalog.has_function_privilege('authenticated', v_name, 'EXECUTE')
       or pg_catalog.has_function_privilege('anon', v_name, 'EXECUTE') then
      raise exception 'RPC exposé au navigateur : %', v_name;
    end if;
    if not pg_catalog.has_function_privilege('service_role', v_name, 'EXECUTE') then
      raise exception 'RPC indisponible au service_role : %', v_name;
    end if;
  end loop;
  if pg_catalog.has_function_privilege(
    'service_role', 'public.validate_rag_rule_set_wrapper(uuid,uuid)', 'EXECUTE'
  ) then
    raise exception 'Ancien RPC de validation encore exécutable';
  end if;
end;
$$;

do $$
declare
  v_bad bigint;
  v_integrity jsonb;
  v_set_id uuid;
begin
  select pg_catalog.count(*) into v_bad
  from internal.rag_rule_sources src
  join internal.rag_passages p
    on p.passage_id = src.passage_id
   and p.document_id = src.document_id
   and p.institution_id = src.institution_id
  where src.passage_content_sha256 <> p.content_sha256;
  if v_bad <> 0 then
    raise exception '% empreintes de sources incohérentes', v_bad;
  end if;

  for v_set_id in
    select s.rule_set_id from internal.rag_rule_sets s
    where s.status = 'validated'
  loop
    v_integrity := internal.inspect_rag_rule_set_integrity(v_set_id);
    if (v_integrity->>'valid')::boolean is not true then
      raise exception 'Jeu validé invalide % : %', v_set_id,
        v_integrity->'blocking_issues';
    end if;
  end loop;
end;
$$;

/*
  Preuve négative dédiée au garde-fou catégoriel.

  Le passage « mariage » contient bien la valeur 3 et l'unité « jours ».
  Il est accepté pour la règle marriage, puis volontairement réutilisé comme
  source d'une règle death_first_degree ayant elle aussi le résultat 3 jours.
  Le seul défaut du second lien est donc la catégorie métier.
*/
do $$
declare
  v_template_version_id constant uuid :=
    'f0a00000-0000-4000-8000-000000000002'::uuid;
  v_institution_id text;
  v_admin_user_uuid uuid;
  v_document_id uuid := pg_catalog.gen_random_uuid();
  v_rule_set_id uuid := pg_catalog.gen_random_uuid();
  v_moving_passage_id uuid := pg_catalog.gen_random_uuid();
  v_marriage_passage_id uuid := pg_catalog.gen_random_uuid();
  v_default_rule_id uuid := pg_catalog.gen_random_uuid();
  v_marriage_rule_id uuid := pg_catalog.gen_random_uuid();
  v_mismatched_rule_id uuid := pg_catalog.gen_random_uuid();
  v_group_id uuid;
  v_moving_content constant text := 'Déménagement : 1 jour.';
  v_marriage_content constant text :=
    'Mariage ou partenariat enregistré : 3 jours.';
  v_moving_sha256 text;
  v_marriage_sha256 text;
  v_integrity jsonb;
  v_mismatch_count integer;
  v_other_issue_count integer;
begin
  select s.institution_id, u.user_uuid
  into v_institution_id, v_admin_user_uuid
  from internal.rag_rule_sets s
  join internal.users u on u.institution_id = s.institution_id
  where s.status = 'validated'
  order by s.created_at, u.user_uuid
  limit 1;

  if v_institution_id is null or v_admin_user_uuid is null then
    raise exception
      'Précondition de test absente : institution avec règle validée';
  end if;

  v_moving_sha256 := pg_catalog.md5(v_moving_content)
    || pg_catalog.md5('rag-10-7:' || v_moving_content);
  v_marriage_sha256 := pg_catalog.md5(v_marriage_content)
    || pg_catalog.md5('rag-10-7:' || v_marriage_content);

  insert into internal.rag_documents (
    document_id, institution_id, document_key, title, category,
    version_label, status, storage_path, original_file_name, mime_type,
    file_size_bytes, file_sha256, extraction_method, extraction_version,
    page_count, extraction_metadata, uploaded_by
  ) values (
    v_document_id, v_institution_id,
    'rag-10-7-categorical-test-' || pg_catalog.replace(
      v_document_id::text, '-', ''
    ),
    'Test transactionnel RAG-10.7', 'test', '1', 'ready',
    v_institution_id || '/rag-10-7-categorical-test-'
      || v_document_id::text || '.pdf',
    'rag-10-7-categorical-test.pdf', 'application/pdf', 1,
    pg_catalog.md5(v_document_id::text)
      || pg_catalog.md5('rag-10-7:' || v_document_id::text),
    'test_fixture', '1', 1,
    pg_catalog.jsonb_build_object('test_fixture', true),
    v_admin_user_uuid
  );

  insert into internal.rag_passages (
    passage_id, document_id, institution_id, chunk_index, content,
    content_sha256, page_start, page_end, source_reference, metadata
  ) values
    (
      v_moving_passage_id, v_document_id, v_institution_id, 0,
      v_moving_content, v_moving_sha256, 1, 1,
      'Fixture déménagement',
      pg_catalog.jsonb_build_object('test_fixture', true)
    ),
    (
      v_marriage_passage_id, v_document_id, v_institution_id, 1,
      v_marriage_content, v_marriage_sha256, 1, 1,
      'Fixture mariage',
      pg_catalog.jsonb_build_object('test_fixture', true)
    );

  insert into internal.rag_rule_sets (
    rule_set_id, institution_id, document_id, rule_key,
    aggregation_strategy, result_unit, status, created_by,
    template_version_id, creation_origin
  ) values (
    v_rule_set_id, v_institution_id, v_document_id,
    'fixed_duration_exceptional_leave_by_event',
    'maximum_applicable_entitlement', 'days', 'proposed',
    v_admin_user_uuid, v_template_version_id, 'manual_migration'
  );

  insert into internal.rag_rules (
    rule_id, rule_set_id, document_id, institution_id,
    template_version_id, outcome_value, is_default, display_order, label
  ) values
    (
      v_default_rule_id, v_rule_set_id, v_document_id, v_institution_id,
      v_template_version_id, 1, true, 10, 'Déménagement'
    ),
    (
      v_marriage_rule_id, v_rule_set_id, v_document_id, v_institution_id,
      v_template_version_id, 3, false, 20,
      'Mariage ou partenariat enregistré'
    ),
    (
      v_mismatched_rule_id, v_rule_set_id, v_document_id, v_institution_id,
      v_template_version_id, 3, false, 30, 'Décès, 1er degré'
    );

  insert into internal.rag_rule_sources (
    rule_id, rule_set_id, passage_id, document_id, institution_id,
    template_version_id, passage_content_sha256
  ) values
    (
      v_default_rule_id, v_rule_set_id, v_moving_passage_id,
      v_document_id, v_institution_id, v_template_version_id,
      v_moving_sha256
    ),
    (
      v_marriage_rule_id, v_rule_set_id, v_marriage_passage_id,
      v_document_id, v_institution_id, v_template_version_id,
      v_marriage_sha256
    ),
    (
      v_mismatched_rule_id, v_rule_set_id, v_marriage_passage_id,
      v_document_id, v_institution_id, v_template_version_id,
      v_marriage_sha256
    );

  v_group_id := pg_catalog.gen_random_uuid();
  insert into internal.rag_rule_condition_groups (
    condition_group_id, rule_id, rule_set_id, document_id,
    institution_id, template_version_id, display_order
  ) values (
    v_group_id, v_marriage_rule_id, v_rule_set_id, v_document_id,
    v_institution_id, v_template_version_id, 10
  );
  insert into internal.rag_rule_conditions (
    condition_group_id, rule_id, rule_set_id, document_id,
    institution_id, template_version_id, fact_key, comparator,
    fact_value_type, category_value
  ) values (
    v_group_id, v_marriage_rule_id, v_rule_set_id, v_document_id,
    v_institution_id, v_template_version_id, 'leave_reason', '=',
    'category', 'marriage'
  );

  v_group_id := pg_catalog.gen_random_uuid();
  insert into internal.rag_rule_condition_groups (
    condition_group_id, rule_id, rule_set_id, document_id,
    institution_id, template_version_id, display_order
  ) values (
    v_group_id, v_mismatched_rule_id, v_rule_set_id, v_document_id,
    v_institution_id, v_template_version_id, 10
  );
  insert into internal.rag_rule_conditions (
    condition_group_id, rule_id, rule_set_id, document_id,
    institution_id, template_version_id, fact_key, comparator,
    fact_value_type, category_value
  ) values (
    v_group_id, v_mismatched_rule_id, v_rule_set_id, v_document_id,
    v_institution_id, v_template_version_id, 'leave_reason', '=',
    'category', 'death_first_degree'
  );

  if v_marriage_content !~ '(^|[^0-9])3([^0-9]|$)'
     or pg_catalog.lower(v_marriage_content)
          !~ '(^|[^[:alpha:]])jours?([^[:alpha:]]|$)'
  then
    raise exception
      'Fixture invalide : la valeur 3 et l''unité jours doivent être présentes';
  end if;

  v_integrity := internal.inspect_rag_rule_set_integrity(v_rule_set_id);

  select pg_catalog.count(*) into v_mismatch_count
  from pg_catalog.jsonb_array_elements(
    v_integrity->'blocking_issues'
  ) issue
  where issue->>'code' = 'categorical_source_mismatch'
    and issue->>'rule_id' = v_mismatched_rule_id::text;

  select pg_catalog.count(*) into v_other_issue_count
  from pg_catalog.jsonb_array_elements(
    v_integrity->'blocking_issues'
  ) issue
  where not (
    issue->>'code' = 'categorical_source_mismatch'
    and issue->>'rule_id' = v_mismatched_rule_id::text
  );

  if (v_integrity->>'valid')::boolean is not false
     or v_mismatch_count <> 1
     or v_other_issue_count <> 0
  then
    raise exception
      'Garde-fou catégoriel non prouvé : %', v_integrity;
  end if;
end;
$$;

do $$
declare
  v_rule_id uuid;
  v_blocked boolean := false;
begin
  select r.rule_id into v_rule_id
  from internal.rag_rules r
  join internal.rag_rule_sets s on s.rule_set_id = r.rule_set_id
  where s.status = 'validated' limit 1;
  if v_rule_id is null then
    raise exception 'Aucune règle validée pour tester l’immuabilité';
  end if;
  begin
    update internal.rag_rules set label = label where rule_id = v_rule_id;
  exception when sqlstate 'P0001' then
    v_blocked := sqlerrm = 'validated_rule_immutable';
  end;
  if not v_blocked then
    raise exception 'Une règle validée a pu être modifiée';
  end if;
end;
$$;

do $$
declare
  v_bad bigint;
begin
  select pg_catalog.count(*) into v_bad
  from (
    select institution_id, rule_key
    from internal.rag_rule_sets where status = 'validated'
    group by institution_id, rule_key having pg_catalog.count(*) > 1
  ) duplicates;
  if v_bad <> 0 then
    raise exception 'Unicité des règles actives violée';
  end if;
  select pg_catalog.count(*) into v_bad
  from (
    select institution_id, document_id, rule_key
    from internal.rag_rule_sets
    where status in ('proposed', 'needs_attention', 'approved')
    group by institution_id, document_id, rule_key
    having pg_catalog.count(*) > 1
  ) duplicates;
  if v_bad <> 0 then
    raise exception 'Plusieurs brouillons ouverts pour la même règle';
  end if;
end;
$$;

rollback;
