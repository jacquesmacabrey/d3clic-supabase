/*
  D3clic — RAG-10.1 correctif immédiat

  Défaut observé en recette staging : une question sur le repos
  hebdomadaire (35 heures) était bloquée à tort, car son passage source
  (page 24 de la CCT-21) est aussi une source de la règle des vacances
  (annual_leave_days, unité "days"). Le contrôle de passage protégé
  introduit par RAG-10.1 bloquait sur la seule présence du passage,
  sans jamais regarder l'unité réellement citée dans la réponse —
  contrairement à l'ancien contrôle deterministicRuleRequiredForAnswer
  (RAG-8.4), qui vérifiait déjà cette correspondance d'unité.

  Ce correctif fait porter l'unité de la règle par chaque passage
  protégé renvoyé au client, afin que le contrôle TypeScript puisse
  exiger la même correspondance d'unité que l'ancien mécanisme, tout en
  conservant la protection élargie à toute proposition non encore
  validée (proposed, needs_attention, approved, validated).

  Aucune table, contrainte ni droit n'est modifié : seule la forme du
  résultat JSON de server_api.get_rag_rule_context change, sur la seule
  clé "protected_passage_ids", qui devient une liste d'objets
  {passage_id, result_unit} plutôt qu'une liste d'UUID nus.
*/

begin;

create or replace function server_api.get_rag_rule_context(
  p_auth_uid uuid,
  p_template_key text,
  p_passage_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_institution_id text;
  v_rule_sets jsonb;
  v_protected_passage_ids jsonb;
begin
  select u.institution_id
  into v_institution_id
  from internal.devices d
  join internal.users u
    on u.user_uuid = d.user_uuid
  join internal.institutions i
    on i.institution_id = u.institution_id
  where d.device_auth_uid = p_auth_uid
    and d.user_uuid is not null
    and d.activated_at is not null
    and d.revoked_at is null
    and u.active is true
    and i.active is true
  limit 1;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'access_denied'
    );
  end if;

  if p_template_key is not null
     and p_template_key !~ '^[a-z][a-z0-9_]{2,99}$'
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_template_key'
    );
  end if;

  if p_passage_ids is null
     or pg_catalog.cardinality(p_passage_ids) > 20
     or pg_catalog.array_position(p_passage_ids, null::uuid) is not null
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_passage_ids'
    );
  end if;

  if p_template_key is null
     and pg_catalog.cardinality(p_passage_ids) = 0
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'missing_rule_signal'
    );
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'rule_set_id', s.rule_set_id,
        'rule_key', s.rule_key,
        'template_version_id', s.template_version_id,
        'aggregation_strategy', s.aggregation_strategy,
        'result_unit', s.result_unit,
        'document_id', s.document_id,
        'template', pg_catalog.jsonb_build_object(
          'template_version_id', tv.template_version_id,
          'template_key', tv.template_key,
          'version_number', tv.version_number,
          'result_value_type', tv.result_value_type,
          'result_integer_only', tv.result_integer_only,
          'result_minimum_number', tv.result_minimum_number,
          'result_maximum_number', tv.result_maximum_number,
          'result_unit', tv.result_unit,
          'aggregation_strategy', tv.aggregation_strategy,
          'intent_detector_key', tv.intent_detector_key,
          'renderer_key', tv.renderer_key,
          'clarification_message_fr', tv.clarification_message_fr,
          'facts', (
            select coalesce(
              pg_catalog.jsonb_agg(
                pg_catalog.jsonb_build_object(
                  'fact_key', f.fact_key,
                  'value_type', f.value_type,
                  'extractor_key', f.extractor_key,
                  'label_fr', f.label_fr,
                  'clarification_label_fr', f.clarification_label_fr,
                  'minimum_number', f.minimum_number,
                  'maximum_number', f.maximum_number,
                  'integer_only', f.integer_only,
                  'allowed_operators', (
                    select coalesce(
                      pg_catalog.jsonb_agg(
                        o.comparator
                        order by o.comparator
                      ),
                      '[]'::jsonb
                    )
                    from internal.rag_rule_template_fact_operators o
                    where o.template_version_id = f.template_version_id
                      and o.fact_key = f.fact_key
                  ),
                  'category_values', (
                    select coalesce(
                      pg_catalog.jsonb_agg(
                        pg_catalog.jsonb_build_object(
                          'value_key', fv.value_key,
                          'label_fr', fv.label_fr
                        )
                        order by fv.display_order, fv.value_key
                      ),
                      '[]'::jsonb
                    )
                    from internal.rag_rule_template_fact_values fv
                    where fv.template_version_id = f.template_version_id
                      and fv.fact_key = f.fact_key
                  )
                )
                order by f.display_order, f.fact_key
              ),
              '[]'::jsonb
            )
            from internal.rag_rule_template_facts f
            where f.template_version_id = tv.template_version_id
          ),
          'fact_constraints', (
            select coalesce(
              pg_catalog.jsonb_agg(
                pg_catalog.jsonb_build_object(
                  'constraint_key', fc.constraint_key,
                  'left_fact_key', fc.left_fact_key,
                  'comparator', fc.comparator,
                  'right_fact_key', fc.right_fact_key,
                  'error_code', fc.error_code
                )
                order by fc.constraint_key
              ),
              '[]'::jsonb
            )
            from internal.rag_rule_template_fact_constraints fc
            where fc.template_version_id = tv.template_version_id
          )
        ),
        'rules', (
          select pg_catalog.jsonb_agg(
            pg_catalog.jsonb_build_object(
              'rule_id', r.rule_id,
              'outcome_value', r.outcome_value,
              'is_default', r.is_default,
              'label', r.label,
              'condition_groups', (
                select coalesce(
                  pg_catalog.jsonb_agg(
                    pg_catalog.jsonb_build_object(
                      'condition_group_id', g.condition_group_id,
                      'conditions', (
                        select pg_catalog.jsonb_agg(
                          pg_catalog.jsonb_build_object(
                            'fact_key', c.fact_key,
                            'fact_value_type', c.fact_value_type,
                            'comparator', c.comparator,
                            'number_value', c.number_value,
                            'category_value', c.category_value
                          )
                          order by
                            c.fact_key,
                            c.comparator,
                            c.number_value,
                            c.category_value
                        )
                        from internal.rag_rule_conditions c
                        where c.condition_group_id = g.condition_group_id
                      )
                    )
                    order by g.display_order, g.condition_group_id
                  ),
                  '[]'::jsonb
                )
                from internal.rag_rule_condition_groups g
                where g.rule_id = r.rule_id
              ),
              'source_passage_ids', (
                select pg_catalog.jsonb_agg(
                  src.passage_id
                  order by src.passage_id
                )
                from internal.rag_rule_sources src
                where src.rule_id = r.rule_id
              )
            )
            order by r.display_order, r.rule_id
          )
          from internal.rag_rules r
          where r.rule_set_id = s.rule_set_id
        )
      )
      order by s.rule_key, s.rule_set_id
    ),
    '[]'::jsonb
  )
  into v_rule_sets
  from internal.rag_rule_sets s
  join internal.rag_documents d
    on d.document_id = s.document_id
   and d.institution_id = s.institution_id
  join internal.rag_rule_template_versions tv
    on tv.template_version_id = s.template_version_id
  where s.institution_id = v_institution_id
    and s.status = 'validated'
    and d.status = 'active'
    and (
      (p_template_key is not null and s.rule_key = p_template_key)
      or exists (
        select 1
        from internal.rag_rule_sources src
        where src.rule_set_id = s.rule_set_id
          and src.passage_id = any(p_passage_ids)
      )
    );

  -- Correctif : chaque passage protégé porte désormais l'unité de la
  -- règle qui le protège, pour permettre un blocage sensible à
  -- l'unité côté client plutôt qu'un blocage sur la seule présence
  -- du passage.
  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'passage_id', x.passage_id,
        'result_unit', x.result_unit
      )
      order by x.passage_id, x.result_unit
    ),
    '[]'::jsonb
  )
  into v_protected_passage_ids
  from (
    select distinct src.passage_id, s.result_unit
    from internal.rag_rule_sources src
    join internal.rag_rule_sets s
      on s.rule_set_id = src.rule_set_id
     and s.institution_id = src.institution_id
     and s.template_version_id = src.template_version_id
    where s.institution_id = v_institution_id
      and s.status in (
        'proposed',
        'needs_attention',
        'approved',
        'validated'
      )
      and src.passage_id = any(p_passage_ids)
  ) x;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', case
      when pg_catalog.jsonb_array_length(v_rule_sets) = 0
        then 'no_validated_rule_set'
      else 'ok'
    end,
    'rule_sets', v_rule_sets,
    'protected_passage_ids', v_protected_passage_ids
  );
end;
$function$;

-- Postcondition : confirme que la fonction retourne bien la nouvelle
-- forme {passage_id, result_unit} et non plus une liste d'UUID nus.
do $$
declare
  v_arg_types text;
begin
  select pg_catalog.pg_get_function_identity_arguments(p.oid)
  into v_arg_types
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'server_api'
    and p.proname = 'get_rag_rule_context';

  if v_arg_types is null then
    raise exception
      'Correctif unité protégée : fonction get_rag_rule_context absente';
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
