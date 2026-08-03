/*
  D3clic — RAG-10.6b
  Deuxième gabarit générique : congé exceptionnel à durée fixe selon motif
  (fait catégoriel), limité aux lettres a-d de l'art. 4.12.2 de la CCT-21.

  Ce script crée :
  1. Le gabarit et sa version publiée (niveau plateforme) ;
  2. Le fait catégoriel leave_reason, ses valeurs et son opérateur ;
  3. Le jeu de règles pour la CCT-21 actuellement active, directement
     validé (le document est déjà `active`, pas de transition à gérer).

  Aucune table ni contrainte n'est modifiée : uniquement de nouvelles
  lignes de données, cohérentes avec le schéma déjà posé par RAG-10.1.
*/

begin;

do $$
declare
  v_template_version_id uuid := 'f0a00000-0000-4000-8000-000000000002';
  v_publisher_auth_id uuid := '1a4b888d-bcf9-47b5-8761-7057987cb5ab';
  v_document_id uuid := '0980913d-a008-44c4-9839-1ade77168656';
  v_institution_id text;
  v_created_by uuid;
  v_new_rule_set_id uuid;
  v_rule_default uuid;
  v_rule_marriage uuid;
  v_rule_death2 uuid;
  v_rule_death1 uuid;
  v_group uuid;
  v_passage_marriage uuid := '16bf1867-1978-4ea3-9877-a7307fa3521d';
  v_passage_death1 uuid := 'cb5c30a2-69cf-4bd3-a978-97c0c5a951b0';
  v_passage_death2 uuid := '19c2e593-75c1-4a41-a515-94459fbb779f';
  v_passage_moving uuid := 'c90f2599-49af-49b6-b9ad-7b1305d94676';
  v_check_defaults integer;
  v_check_conditional_groups integer;
begin
  -- Réutilise l'identité admin déjà validée pour annual_leave_days,
  -- plutôt que de deviner la correspondance auth.users -> internal.users.
  select s.institution_id, s.created_by
    into v_institution_id, v_created_by
  from internal.rag_rule_sets s
  where s.rule_key = 'annual_leave_days' and s.status = 'validated';

  if v_institution_id is null then
    raise exception 'Jeu annual_leave_days validé introuvable — identité admin indisponible';
  end if;

  -- 1. Gabarit (niveau plateforme, jamais propre à une institution)
  insert into internal.rag_rule_templates (
    template_key, domain_key, name_fr, description_fr
  ) values (
    'fixed_duration_exceptional_leave_by_event',
    'leave',
    'Congé exceptionnel à durée fixe selon motif',
    'Congés exceptionnels dont la durée est fixe et déterminée uniquement par le motif de la demande (mariage, décès, déménagement), sans seuil numérique.'
  )
  on conflict (template_key) do nothing;

  insert into internal.rag_rule_template_versions (
    template_version_id, template_key, version_number, status,
    result_value_type, result_integer_only,
    result_minimum_number, result_maximum_number, result_unit,
    aggregation_strategy, intent_detector_key, renderer_key,
    clarification_message_fr, published_by, published_at
  ) values (
    v_template_version_id, 'fixed_duration_exceptional_leave_by_event', 1,
    'published',
    'number', true, 0, 30, 'days',
    'maximum_applicable_entitlement',
    'exceptional_leave_intent_v1', 'exceptional_leave_answer_fr_v1',
    'De quel motif de congé exceptionnel s''agit-il : mariage ou partenariat enregistré, décès d''un parent au premier degré, décès d''un parent au deuxième degré, ou déménagement ?',
    v_publisher_auth_id, pg_catalog.now()
  );

  -- 2. Fait catégoriel leave_reason
  insert into internal.rag_rule_template_facts (
    template_version_id, fact_key, value_type, extractor_key,
    label_fr, clarification_label_fr,
    minimum_number, maximum_number, integer_only, display_order
  ) values (
    v_template_version_id, 'leave_reason', 'category', 'leave_reason_fr_v1',
    'Motif du congé', 'le motif exact de ta demande',
    null, null, false, 10
  );

  insert into internal.rag_rule_template_fact_values (
    template_version_id, fact_key, value_key, label_fr, display_order
  ) values
    (v_template_version_id, 'leave_reason', 'marriage', 'Mariage ou partenariat enregistré', 10),
    (v_template_version_id, 'leave_reason', 'death_first_degree', 'Décès, 1er degré', 20),
    (v_template_version_id, 'leave_reason', 'death_second_degree', 'Décès, 2e degré', 30),
    (v_template_version_id, 'leave_reason', 'moving', 'Déménagement', 40);

  insert into internal.rag_rule_template_fact_operators (
    template_version_id, fact_key, comparator
  ) values (v_template_version_id, 'leave_reason', '=');

  -- 3. Jeu de règles pour la CCT-21 active
  insert into internal.rag_rule_sets (
    institution_id, document_id, rule_key, aggregation_strategy, result_unit,
    status, created_by, template_version_id, creation_origin
  ) values (
    v_institution_id, v_document_id,
    'fixed_duration_exceptional_leave_by_event',
    'maximum_applicable_entitlement', 'days',
    'proposed', v_created_by, v_template_version_id, 'manual_migration'
  )
  returning rule_set_id into v_new_rule_set_id;

  -- Règle par défaut : déménagement, 1 jour
  insert into internal.rag_rules (
    rule_set_id, document_id, institution_id, template_version_id,
    outcome_value, is_default, display_order, label
  ) values (
    v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id,
    1, true, 10, 'Déménagement'
  ) returning rule_id into v_rule_default;

  insert into internal.rag_rule_sources (rule_id, rule_set_id, passage_id, document_id, institution_id, template_version_id)
  values (v_rule_default, v_new_rule_set_id, v_passage_moving, v_document_id, v_institution_id, v_template_version_id);

  -- Règle mariage : 3 jours
  insert into internal.rag_rules (
    rule_set_id, document_id, institution_id, template_version_id,
    outcome_value, is_default, display_order, label
  ) values (
    v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id,
    3, false, 20, 'Mariage ou partenariat enregistré'
  ) returning rule_id into v_rule_marriage;

  insert into internal.rag_rule_sources (rule_id, rule_set_id, passage_id, document_id, institution_id, template_version_id)
  values (v_rule_marriage, v_new_rule_set_id, v_passage_marriage, v_document_id, v_institution_id, v_template_version_id);

  insert into internal.rag_rule_condition_groups (rule_id, rule_set_id, document_id, institution_id, template_version_id, display_order)
  values (v_rule_marriage, v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id, 10)
  returning condition_group_id into v_group;
  insert into internal.rag_rule_conditions (condition_group_id, rule_id, rule_set_id, document_id, institution_id, template_version_id, fact_key, comparator, fact_value_type, category_value)
  values (v_group, v_rule_marriage, v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id, 'leave_reason', '=', 'category', 'marriage');

  -- Règle décès, 2e degré : 2 jours
  insert into internal.rag_rules (
    rule_set_id, document_id, institution_id, template_version_id,
    outcome_value, is_default, display_order, label
  ) values (
    v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id,
    2, false, 30, 'Décès, 2e degré'
  ) returning rule_id into v_rule_death2;

  insert into internal.rag_rule_sources (rule_id, rule_set_id, passage_id, document_id, institution_id, template_version_id)
  values (v_rule_death2, v_new_rule_set_id, v_passage_death2, v_document_id, v_institution_id, v_template_version_id);

  insert into internal.rag_rule_condition_groups (rule_id, rule_set_id, document_id, institution_id, template_version_id, display_order)
  values (v_rule_death2, v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id, 10)
  returning condition_group_id into v_group;
  insert into internal.rag_rule_conditions (condition_group_id, rule_id, rule_set_id, document_id, institution_id, template_version_id, fact_key, comparator, fact_value_type, category_value)
  values (v_group, v_rule_death2, v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id, 'leave_reason', '=', 'category', 'death_second_degree');

  -- Règle décès, 1er degré : 5 jours
  insert into internal.rag_rules (
    rule_set_id, document_id, institution_id, template_version_id,
    outcome_value, is_default, display_order, label
  ) values (
    v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id,
    5, false, 40, 'Décès, 1er degré'
  ) returning rule_id into v_rule_death1;

  insert into internal.rag_rule_sources (rule_id, rule_set_id, passage_id, document_id, institution_id, template_version_id)
  values (v_rule_death1, v_new_rule_set_id, v_passage_death1, v_document_id, v_institution_id, v_template_version_id);

  insert into internal.rag_rule_condition_groups (rule_id, rule_set_id, document_id, institution_id, template_version_id, display_order)
  values (v_rule_death1, v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id, 10)
  returning condition_group_id into v_group;
  insert into internal.rag_rule_conditions (condition_group_id, rule_id, rule_set_id, document_id, institution_id, template_version_id, fact_key, comparator, fact_value_type, category_value)
  values (v_group, v_rule_death1, v_new_rule_set_id, v_document_id, v_institution_id, v_template_version_id, 'leave_reason', '=', 'category', 'death_first_degree');

  -- Vérifications avant de considérer la structure prête
  select count(*) into v_check_defaults from internal.rag_rules where rule_set_id = v_new_rule_set_id and is_default;
  select count(*) into v_check_conditional_groups
    from internal.rag_rule_condition_groups g
    where g.rule_set_id = v_new_rule_set_id
      and exists (select 1 from internal.rag_rule_conditions c where c.condition_group_id = g.condition_group_id);

  if v_check_defaults <> 1 or v_check_conditional_groups <> 3 then
    raise exception 'Structure incorrecte : défauts=%, groupes conditionnels=%',
      v_check_defaults, v_check_conditional_groups;
  end if;

  raise notice 'Gabarit publié (%) et jeu de règles créé (%) avec succès',
    v_template_version_id, v_new_rule_set_id;
end;
$$;

commit;

-- Récupère l'identifiant du nouveau jeu pour l'approuver/valider ensuite
select rule_set_id, status, created_at
from internal.rag_rule_sets
where document_id = '0980913d-a008-44c4-9839-1ade77168656'
  and rule_key = 'fixed_duration_exceptional_leave_by_event'
order by created_at desc
limit 1;
