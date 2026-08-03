/*
  RAG-10.1 — contrôles SQL post-migration
  Lecture et mutations transactionnelles annulées à la fin.
  À exécuter uniquement après audit de la migration principale.
*/

begin;

do $$
declare
  v_missing text[];
begin
  select pg_catalog.array_agg(required.object_name)
  into v_missing
  from (
    values
      ('internal.rag_rule_runtime_registry'),
      ('internal.rag_rule_templates'),
      ('internal.rag_rule_template_versions'),
      ('internal.rag_rule_template_facts'),
      ('internal.rag_rule_template_fact_values'),
      ('internal.rag_rule_template_fact_operators'),
      ('internal.rag_rule_template_fact_constraints'),
      ('internal.platform_admins'),
      ('internal.platform_security_log')
  ) required(object_name)
  where pg_catalog.to_regclass(required.object_name) is null;

  if v_missing is not null then
    raise exception 'Tables absentes : %', v_missing;
  end if;
end;
$$;

do $$
declare
  v_count bigint;
begin
  select pg_catalog.count(*)
  into v_count
  from internal.rag_rule_template_versions v
  where v.template_key = 'annual_leave_days'
    and v.version_number = 1
    and v.status = 'published'
    and v.result_unit = 'days'
    and v.aggregation_strategy = 'maximum_applicable_entitlement';
  if v_count <> 1 then
    raise exception 'Gabarit annual_leave_days v1 invalide';
  end if;

  select pg_catalog.count(*)
  into v_count
  from internal.rag_rule_template_facts f
  where f.template_version_id =
    'f0a00000-0000-4000-8000-000000000001'::uuid
    and (
      (f.fact_key = 'age_years' and f.minimum_number = 14
        and f.maximum_number = 100 and f.integer_only)
      or
      (f.fact_key = 'service_years' and f.minimum_number = 0
        and f.maximum_number = 80 and f.integer_only)
    );
  if v_count <> 2 then
    raise exception 'Faits du gabarit vacances incomplets';
  end if;
end;
$$;

do $$
declare
  v_bad bigint;
begin
  select pg_catalog.count(*)
  into v_bad
  from internal.rag_rule_sets s
  where s.rule_key = 'annual_leave_days'
    and (
      s.template_version_id <>
        'f0a00000-0000-4000-8000-000000000001'::uuid
      or s.creation_origin <> 'manual_migration'
      or (
        s.status = 'validated'
        and (
          s.approved_by is distinct from s.validated_by
          or s.approved_at is distinct from s.validated_at
        )
      )
    );
  if v_bad <> 0 then
    raise exception '% jeux de règles mal migrés', v_bad;
  end if;

  select pg_catalog.count(*)
  into v_bad
  from internal.rag_rule_conditions c
  where c.fact_value_type <> 'number'
     or c.number_value is distinct from c.threshold_value
     or c.category_value is not null;
  if v_bad <> 0 then
    raise exception '% conditions historiques mal migrées', v_bad;
  end if;

  select pg_catalog.count(*)
  into v_bad
  from internal.rag_rule_sets s
  where s.source_package_id is not null;
  if v_bad <> 0 then
    raise exception 'source_package_id doit rester nul en RAG-10.1';
  end if;
end;
$$;

do $$
declare
  v_bad bigint;
begin
  select pg_catalog.count(*)
  into v_bad
  from internal.rag_rules r
  join internal.rag_rule_sets s
    on s.rule_set_id = r.rule_set_id
  where r.template_version_id <> s.template_version_id;
  if v_bad <> 0 then
    raise exception 'Incohérence gabarit au niveau règle';
  end if;

  select pg_catalog.count(*)
  into v_bad
  from internal.rag_rule_condition_groups g
  join internal.rag_rules r
    on r.rule_id = g.rule_id
   and r.rule_set_id = g.rule_set_id
  where g.template_version_id <> r.template_version_id;
  if v_bad <> 0 then
    raise exception 'Incohérence gabarit au niveau groupe';
  end if;

  select pg_catalog.count(*)
  into v_bad
  from internal.rag_rule_conditions c
  join internal.rag_rule_condition_groups g
    on g.condition_group_id = c.condition_group_id
   and g.rule_id = c.rule_id
   and g.rule_set_id = c.rule_set_id
  where c.template_version_id <> g.template_version_id;
  if v_bad <> 0 then
    raise exception 'Incohérence gabarit au niveau condition';
  end if;

  select pg_catalog.count(*)
  into v_bad
  from internal.rag_rule_sources src
  join internal.rag_rule_sets s
    on s.rule_set_id = src.rule_set_id
  where src.template_version_id <> s.template_version_id;
  if v_bad <> 0 then
    raise exception 'Incohérence gabarit au niveau source';
  end if;
end;
$$;

do $$
declare
  v_missing text[];
begin
  select pg_catalog.array_agg(required.constraint_name)
  into v_missing
  from (
    values
      ('rag_rule_template_versions_compatibility_unique'),
      ('rag_rule_sets_rule_template_unique'),
      ('rag_rules_rule_template_unique'),
      ('rag_rule_condition_groups_template_unique'),
      ('rag_rule_conditions_group_template_fk'),
      ('rag_rule_sources_set_template_fk')
  ) required(constraint_name)
  where not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conname = required.constraint_name
  );
  if v_missing is not null then
    raise exception 'Contraintes composites absentes : %', v_missing;
  end if;
end;
$$;

do $$
declare
  v_bad bigint;
begin
  select pg_catalog.count(*)
  into v_bad
  from pg_catalog.pg_tables t
  where t.schemaname = 'internal'
    and t.tablename in (
      'rag_rule_runtime_registry',
      'rag_rule_templates',
      'rag_rule_template_versions',
      'rag_rule_template_facts',
      'rag_rule_template_fact_values',
      'rag_rule_template_fact_operators',
      'rag_rule_template_fact_constraints',
      'platform_admins',
      'platform_security_log'
    )
    and (not t.rowsecurity or not t.forcerowsecurity);
  if v_bad <> 0 then
    raise exception '% tables sans RLS forcée', v_bad;
  end if;
end;
$$;

do $$
begin
  if pg_catalog.to_regprocedure(
    'public.get_validated_rag_rule_sets_wrapper(uuid,text,uuid[])'
  ) is null then
    raise exception 'Ancien RPC retiré trop tôt';
  end if;
  if pg_catalog.to_regprocedure(
    'public.get_rag_rule_context_wrapper(uuid,text,uuid[])'
  ) is null then
    raise exception 'Nouveau RPC absent';
  end if;
  if pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_rag_rule_context_wrapper(uuid,text,uuid[])',
    'EXECUTE'
  ) then
    raise exception 'authenticated peut exécuter le nouveau RPC';
  end if;
  if not pg_catalog.has_function_privilege(
    'service_role',
    'public.get_rag_rule_context_wrapper(uuid,text,uuid[])',
    'EXECUTE'
  ) then
    raise exception 'service_role ne peut pas exécuter le nouveau RPC';
  end if;
end;
$$;

do $$
declare
  v_duplicate bigint;
begin
  select pg_catalog.count(*)
  into v_duplicate
  from (
    select s.institution_id, s.rule_key
    from internal.rag_rule_sets s
    where s.status = 'validated'
    group by s.institution_id, s.rule_key
    having pg_catalog.count(*) > 1
  ) x;
  if v_duplicate <> 0 then
    raise exception 'Plusieurs règles validées pour un même gabarit';
  end if;
end;
$$;

-- Une mutation d’enfant doit rétrograder approved/validated. Le bloc est
-- volontairement annulé par l’exception interne, puis par le ROLLBACK final.
do $$
declare
  v_rule_id uuid;
  v_rule_set_id uuid;
  v_original_status text;
  v_new_status text;
begin
  select r.rule_id, r.rule_set_id, s.status
  into v_rule_id, v_rule_set_id, v_original_status
  from internal.rag_rules r
  join internal.rag_rule_sets s on s.rule_set_id = r.rule_set_id
  where s.status = 'validated'
  order by r.rule_id
  limit 1;

  if v_rule_id is not null then
    update internal.rag_rules
    set label = label
    where rule_id = v_rule_id;

    select s.status
    into v_new_status
    from internal.rag_rule_sets s
    where s.rule_set_id = v_rule_set_id;

    if v_new_status <> 'needs_attention' then
      raise exception
        'Mutation enfant : attendu needs_attention, obtenu %',
        v_new_status;
    end if;

    raise exception using
      errcode = 'P0001',
      message = 'rag_10_1_expected_subtransaction_rollback';
  end if;
exception
  when raise_exception then
    if sqlerrm <> 'rag_10_1_expected_subtransaction_rollback' then
      raise;
    end if;
end;
$$;

rollback;

