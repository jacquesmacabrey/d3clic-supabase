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
