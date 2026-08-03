/*
  D3clic — RAG-10.1 : test transactionnel de la migration générique
  Projet cible : Supabase STAGING uniquement
  Statut : À AUDITER — NE PAS EXÉCUTER AVANT VALIDATION

  Migration additive :
  - catalogue central versionné de gabarits ;
  - faits et conditions typés ;
  - rôle plateforme séparé ;
  - migration sans recréation de annual_leave_days ;
  - lecture fermée des règles exécutables et passages protégés ;
  - états proposed / needs_attention / approved / validated ;
  - maintien temporaire des colonnes historiques.
*/

begin;

-- ---------------------------------------------------------------------------
-- 0. Préconditions strictes
-- ---------------------------------------------------------------------------

do $$
declare
  v_unexpected_count bigint;
begin
  if to_regclass('internal.rag_rule_sets') is null
     or to_regclass('internal.rag_rules') is null
     or to_regclass('internal.rag_rule_condition_groups') is null
     or to_regclass('internal.rag_rule_conditions') is null
     or to_regclass('internal.rag_rule_sources') is null
     or to_regclass('internal.rag_documents') is null
     or to_regclass('internal.rag_passages') is null
     or to_regclass('internal.users') is null
     or to_regclass('internal.devices') is null
  then
    raise exception 'RAG-10.1 : socle RAG requis absent';
  end if;

  if to_regprocedure('server_api.check_backoffice_role(uuid,text)') is null
     or to_regprocedure(
       'public.get_validated_rag_rule_sets_wrapper(uuid,text,uuid[])'
     ) is null
  then
    raise exception 'RAG-10.1 : fonctions du moteur déterministe absentes';
  end if;

  if to_regclass('internal.rag_rule_templates') is not null
     or to_regclass('internal.rag_rule_template_versions') is not null
  then
    raise exception 'RAG-10.1 : catalogue de gabarits déjà présent';
  end if;

  select pg_catalog.count(*)
  into v_unexpected_count
  from internal.rag_rule_sets s
  where s.rule_key <> 'annual_leave_days'
     or s.aggregation_strategy <> 'maximum_applicable_entitlement'
     or s.result_unit <> 'days'
     or s.status not in ('draft', 'validated', 'invalidated');

  if v_unexpected_count <> 0 then
    raise exception
      'RAG-10.1 : % jeu(x) historique(s) incompatible(s)',
      v_unexpected_count;
  end if;

  select pg_catalog.count(*)
  into v_unexpected_count
  from internal.rag_rule_conditions c
  where c.fact_key not in ('age_years', 'service_years')
     or c.comparator not in ('>=', '<')
     or c.threshold_value is null
     or c.threshold_value < 0
     or c.threshold_value > 150;

  if v_unexpected_count <> 0 then
    raise exception
      'RAG-10.1 : % condition(s) historique(s) incompatible(s)',
      v_unexpected_count;
  end if;

  select pg_catalog.count(*)
  into v_unexpected_count
  from internal.rag_rule_sets s
  join internal.rag_documents d
    on d.document_id = s.document_id
   and d.institution_id = s.institution_id
  where s.status = 'validated'
    and (
      d.status <> 'active'
      or not exists (
        select 1
        from internal.rag_rules r
        where r.rule_set_id = s.rule_set_id
      )
      or exists (
        select 1
        from internal.rag_rules r
        where r.rule_set_id = s.rule_set_id
          and not exists (
            select 1
            from internal.rag_rule_sources src
            where src.rule_id = r.rule_id
              and src.rule_set_id = r.rule_set_id
          )
      )
    );

  if v_unexpected_count <> 0 then
    raise exception
      'RAG-10.1 : % jeu(x) validé(s) sans document actif ou source complète',
      v_unexpected_count;
  end if;
end;
$$;

-- Les anciens triggers ne doivent pas rétrograder la règle validée pendant
-- le backfill structurel. Ils sont recréés sous leur forme générique plus bas.
drop trigger if exists rag_rules_invalidate_rule_set
  on internal.rag_rules;
drop trigger if exists rag_rule_condition_groups_invalidate_rule_set
  on internal.rag_rule_condition_groups;
drop trigger if exists rag_rule_conditions_invalidate_rule_set
  on internal.rag_rule_conditions;
drop trigger if exists rag_rule_sources_invalidate_rule_set
  on internal.rag_rule_sources;
drop trigger if exists rag_documents_invalidate_numeric_rules
  on internal.rag_documents;
drop trigger if exists rag_passages_invalidate_numeric_rules
  on internal.rag_passages;

-- ---------------------------------------------------------------------------
-- 1. Registre technique et catalogue central
-- ---------------------------------------------------------------------------

create table internal.rag_rule_runtime_registry (
  key_type text not null,
  runtime_key text not null,
  description text not null,
  created_at timestamptz not null default pg_catalog.now(),

  constraint rag_rule_runtime_registry_pkey
    primary key (key_type, runtime_key),
  constraint rag_rule_runtime_registry_type_check
    check (
      key_type in (
        'intent_detector',
        'fact_extractor',
        'renderer',
        'aggregation_strategy'
      )
    ),
  constraint rag_rule_runtime_registry_key_check
    check (
      runtime_key ~ '^[a-z][a-z0-9_]{2,99}$'
      and runtime_key = pg_catalog.btrim(runtime_key)
    ),
  constraint rag_rule_runtime_registry_description_check
    check (
      pg_catalog.char_length(pg_catalog.btrim(description)) between 1 and 500
      and description = pg_catalog.btrim(description)
    )
);

insert into internal.rag_rule_runtime_registry (
  key_type,
  runtime_key,
  description
)
values
  (
    'intent_detector',
    'annual_leave_intent_v1',
    'Détection française des questions de vacances annuelles.'
  ),
  (
    'fact_extractor',
    'age_years_fr_v1',
    'Extraction française de l’âge en années.'
  ),
  (
    'fact_extractor',
    'service_years_fr_v1',
    'Extraction française de l’ancienneté dans la même institution.'
  ),
  (
    'renderer',
    'annual_leave_answer_fr_v1',
    'Rendu français déterministe du droit aux vacances.'
  ),
  (
    'aggregation_strategy',
    'maximum_applicable_entitlement',
    'Sélection de la valeur maximale applicable.'
  );

create table internal.rag_rule_templates (
  template_key text primary key,
  domain_key text not null,
  name_fr text not null,
  description_fr text not null,
  created_at timestamptz not null default pg_catalog.now(),

  constraint rag_rule_templates_key_check
    check (template_key ~ '^[a-z][a-z0-9_]{2,99}$'),
  constraint rag_rule_templates_domain_check
    check (domain_key ~ '^[a-z][a-z0-9_]{1,49}$'),
  constraint rag_rule_templates_name_check
    check (
      pg_catalog.char_length(pg_catalog.btrim(name_fr)) between 1 and 200
      and name_fr = pg_catalog.btrim(name_fr)
    ),
  constraint rag_rule_templates_description_check
    check (
      pg_catalog.char_length(pg_catalog.btrim(description_fr))
        between 1 and 2000
      and description_fr = pg_catalog.btrim(description_fr)
    )
);

create table internal.rag_rule_template_versions (
  template_version_id uuid primary key default gen_random_uuid(),
  template_key text not null,
  version_number integer not null,
  status text not null default 'draft',

  result_value_type text not null,
  result_integer_only boolean not null default false,
  result_minimum_number numeric(18,6),
  result_maximum_number numeric(18,6),
  result_unit text not null,
  aggregation_strategy text not null,
  intent_detector_key text not null,
  renderer_key text not null,
  clarification_message_fr text not null,

  published_by uuid,
  published_at timestamptz,
  retired_by uuid,
  retired_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),

  constraint rag_rule_template_versions_template_fk
    foreign key (template_key)
    references internal.rag_rule_templates (template_key)
    on update cascade
    on delete restrict,
  constraint rag_rule_template_versions_publisher_fk
    foreign key (published_by)
    references auth.users (id)
    on update cascade
    on delete restrict,
  constraint rag_rule_template_versions_retirer_fk
    foreign key (retired_by)
    references auth.users (id)
    on update cascade
    on delete restrict,
  constraint rag_rule_template_versions_number_unique
    unique (template_key, version_number),
  constraint rag_rule_template_versions_compatibility_unique
    unique (
      template_version_id,
      template_key,
      aggregation_strategy,
      result_unit
    ),
  constraint rag_rule_template_versions_number_check
    check (version_number between 1 and 100000),
  constraint rag_rule_template_versions_status_check
    check (status in ('draft', 'published', 'retired')),
  constraint rag_rule_template_versions_result_type_check
    check (result_value_type = 'number'),
  constraint rag_rule_template_versions_result_unit_check
    check (result_unit in ('days')),
  constraint rag_rule_template_versions_strategy_check
    check (
      aggregation_strategy in ('maximum_applicable_entitlement')
    ),
  constraint rag_rule_template_versions_runtime_key_check
    check (
      intent_detector_key ~ '^[a-z][a-z0-9_]{2,99}$'
      and renderer_key ~ '^[a-z][a-z0-9_]{2,99}$'
      and aggregation_strategy ~ '^[a-z][a-z0-9_]{2,99}$'
    ),
  constraint rag_rule_template_versions_result_bounds_check
    check (
      result_minimum_number is null
      or result_maximum_number is null
      or result_minimum_number <= result_maximum_number
    ),
  constraint rag_rule_template_versions_lifecycle_check
    check (
      (
        status = 'draft'
        and published_by is null
        and published_at is null
        and retired_by is null
        and retired_at is null
      )
      or
      (
        status = 'published'
        and published_at is not null
        and retired_by is null
        and retired_at is null
      )
      or
      (
        status = 'retired'
        and published_at is not null
        and retired_by is not null
        and retired_at is not null
      )
    ),
  constraint rag_rule_template_versions_clarification_check
    check (
      pg_catalog.char_length(pg_catalog.btrim(clarification_message_fr))
        between 1 and 1000
      and clarification_message_fr =
        pg_catalog.btrim(clarification_message_fr)
    )
);

create unique index rag_rule_template_versions_one_published_idx
  on internal.rag_rule_template_versions (template_key)
  where status = 'published';

create table internal.rag_rule_template_facts (
  template_version_id uuid not null,
  fact_key text not null,
  value_type text not null,
  extractor_key text not null,
  label_fr text not null,
  clarification_label_fr text not null,
  minimum_number numeric(18,6),
  maximum_number numeric(18,6),
  integer_only boolean not null default false,
  display_order integer not null,

  constraint rag_rule_template_facts_pkey
    primary key (template_version_id, fact_key),
  constraint rag_rule_template_facts_typed_unique
    unique (template_version_id, fact_key, value_type),
  constraint rag_rule_template_facts_version_fk
    foreign key (template_version_id)
    references internal.rag_rule_template_versions (template_version_id)
    on update cascade
    on delete cascade,
  constraint rag_rule_template_facts_key_check
    check (fact_key ~ '^[a-z][a-z0-9_]{2,99}$'),
  constraint rag_rule_template_facts_type_check
    check (value_type in ('number', 'category')),
  constraint rag_rule_template_facts_extractor_check
    check (extractor_key ~ '^[a-z][a-z0-9_]{2,99}$'),
  constraint rag_rule_template_facts_numeric_bundle_check
    check (
      (
        value_type = 'number'
        and (
          minimum_number is null
          or maximum_number is null
          or minimum_number <= maximum_number
        )
      )
      or
      (
        value_type = 'category'
        and minimum_number is null
        and maximum_number is null
        and integer_only is false
      )
    ),
  constraint rag_rule_template_facts_order_check
    check (display_order between 0 and 1000),
  constraint rag_rule_template_facts_labels_check
    check (
      pg_catalog.char_length(pg_catalog.btrim(label_fr)) between 1 and 200
      and label_fr = pg_catalog.btrim(label_fr)
      and pg_catalog.char_length(
        pg_catalog.btrim(clarification_label_fr)
      ) between 1 and 300
      and clarification_label_fr =
        pg_catalog.btrim(clarification_label_fr)
    )
);

create table internal.rag_rule_template_fact_values (
  template_version_id uuid not null,
  fact_key text not null,
  value_key text not null,
  label_fr text not null,
  display_order integer not null,

  constraint rag_rule_template_fact_values_pkey
    primary key (template_version_id, fact_key, value_key),
  constraint rag_rule_template_fact_values_fact_fk
    foreign key (template_version_id, fact_key)
    references internal.rag_rule_template_facts (
      template_version_id,
      fact_key
    )
    on update cascade
    on delete cascade,
  constraint rag_rule_template_fact_values_key_check
    check (value_key ~ '^[a-z][a-z0-9_]{0,99}$'),
  constraint rag_rule_template_fact_values_order_check
    check (display_order between 0 and 1000),
  constraint rag_rule_template_fact_values_label_check
    check (
      pg_catalog.char_length(pg_catalog.btrim(label_fr)) between 1 and 200
      and label_fr = pg_catalog.btrim(label_fr)
    )
);

create table internal.rag_rule_template_fact_operators (
  template_version_id uuid not null,
  fact_key text not null,
  comparator text not null,

  constraint rag_rule_template_fact_operators_pkey
    primary key (template_version_id, fact_key, comparator),
  constraint rag_rule_template_fact_operators_fact_fk
    foreign key (template_version_id, fact_key)
    references internal.rag_rule_template_facts (
      template_version_id,
      fact_key
    )
    on update cascade
    on delete cascade,
  constraint rag_rule_template_fact_operators_comparator_check
    check (comparator in ('=', '!=', '<', '<=', '>', '>='))
);

create table internal.rag_rule_template_fact_constraints (
  template_version_id uuid not null,
  constraint_key text not null,
  left_fact_key text not null,
  comparator text not null,
  right_fact_key text not null,
  error_code text not null,

  constraint rag_rule_template_fact_constraints_pkey
    primary key (template_version_id, constraint_key),
  constraint rag_rule_template_fact_constraints_left_fk
    foreign key (template_version_id, left_fact_key)
    references internal.rag_rule_template_facts (
      template_version_id,
      fact_key
    )
    on update cascade
    on delete cascade,
  constraint rag_rule_template_fact_constraints_right_fk
    foreign key (template_version_id, right_fact_key)
    references internal.rag_rule_template_facts (
      template_version_id,
      fact_key
    )
    on update cascade
    on delete cascade,
  constraint rag_rule_template_fact_constraints_key_check
    check (constraint_key ~ '^[a-z][a-z0-9_]{2,99}$'),
  constraint rag_rule_template_fact_constraints_comparator_check
    check (comparator in ('=', '!=', '<', '<=', '>', '>=')),
  constraint rag_rule_template_fact_constraints_error_check
    check (error_code ~ '^[a-z][a-z0-9_]{2,99}$'),
  constraint rag_rule_template_fact_constraints_distinct_facts_check
    check (left_fact_key <> right_fact_key)
);

-- ---------------------------------------------------------------------------
-- 2. Administration plateforme séparée
-- ---------------------------------------------------------------------------

create table internal.platform_admins (
  auth_uid uuid not null,
  platform_role text not null,
  active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  deactivated_at timestamptz,

  constraint platform_admins_pkey
    primary key (auth_uid, platform_role),
  constraint platform_admins_auth_fk
    foreign key (auth_uid)
    references auth.users (id)
    on update cascade
    on delete restrict,
  constraint platform_admins_role_check
    check (platform_role in ('catalog_admin')),
  constraint platform_admins_lifecycle_check
    check (
      (active and deactivated_at is null)
      or (not active and deactivated_at is not null)
    )
);

create table internal.platform_security_log (
  id bigserial primary key,
  event_type text not null,
  actor_auth_uid uuid,
  template_key text,
  template_version_id uuid,
  detail jsonb,
  created_at timestamptz not null default pg_catalog.now(),

  constraint platform_security_log_event_check
    check (event_type ~ '^[a-z][a-z0-9_]{2,99}$')
);

create index platform_security_log_created_idx
  on internal.platform_security_log (created_at desc);

create or replace function server_api.check_platform_role(
  p_auth_uid uuid,
  p_required_role text default 'catalog_admin'
)
returns table (
  authorized boolean,
  auth_uid uuid,
  platform_role text
)
language sql
security definer
set search_path = ''
stable
as $function$
  select
    true,
    a.auth_uid,
    a.platform_role
  from internal.platform_admins a
  where a.auth_uid = p_auth_uid
    and a.platform_role = p_required_role
    and a.active is true
  limit 1;
$function$;

create or replace function server_api.get_rule_template_catalog(
  p_auth_uid uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $function$
declare
  v_authorized boolean;
  v_catalog jsonb;
begin
  select r.authorized
  into v_authorized
  from server_api.check_platform_role(p_auth_uid, 'catalog_admin') r
  limit 1;

  if coalesce(v_authorized, false) is not true then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'platform_unauthorized'
    );
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'template_key', t.template_key,
        'domain_key', t.domain_key,
        'name_fr', t.name_fr,
        'description_fr', t.description_fr,
        'versions', (
          select coalesce(
            pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'template_version_id', v.template_version_id,
                'version_number', v.version_number,
                'status', v.status,
                'published_at', v.published_at,
                'retired_at', v.retired_at
              )
              order by v.version_number
            ),
            '[]'::jsonb
          )
          from internal.rag_rule_template_versions v
          where v.template_key = t.template_key
        )
      )
      order by t.template_key
    ),
    '[]'::jsonb
  )
  into v_catalog
  from internal.rag_rule_templates t;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'ok',
    'templates', v_catalog
  );
end;
$function$;

create or replace function public.get_rule_template_catalog_wrapper(
  p_auth_uid uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select server_api.get_rule_template_catalog(p_auth_uid);
$function$;

-- Registre technique lisible uniquement par le service de déploiement.
create or replace function server_api.get_rag_rule_runtime_registry()
returns jsonb
language sql
security definer
set search_path = ''
stable
as $function$
  select pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'ok',
    'keys',
    coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'key_type', r.key_type,
          'runtime_key', r.runtime_key
        )
        order by r.key_type, r.runtime_key
      ),
      '[]'::jsonb
    )
  )
  from internal.rag_rule_runtime_registry r;
$function$;

create or replace function public.get_rag_rule_runtime_registry_wrapper()
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select server_api.get_rag_rule_runtime_registry();
$function$;

-- ---------------------------------------------------------------------------
-- 3. Gabarit annual_leave_days version 1
-- ---------------------------------------------------------------------------

insert into internal.rag_rule_templates (
  template_key,
  domain_key,
  name_fr,
  description_fr
)
values (
  'annual_leave_days',
  'leave',
  'Vacances annuelles',
  'Nombre de jours de vacances selon l’âge et l’ancienneté.'
);

insert into internal.rag_rule_template_versions (
  template_version_id,
  template_key,
  version_number,
  status,
  result_value_type,
  result_integer_only,
  result_minimum_number,
  result_maximum_number,
  result_unit,
  aggregation_strategy,
  intent_detector_key,
  renderer_key,
  clarification_message_fr,
  published_by,
  published_at
)
values (
  'f0a00000-0000-4000-8000-000000000001'::uuid,
  'annual_leave_days',
  1,
  'published',
  'number',
  true,
  0,
  10000,
  'days',
  'maximum_applicable_entitlement',
  'annual_leave_intent_v1',
  'annual_leave_answer_fr_v1',
  'J’ai besoin de ton âge et de ton nombre d’années de service dans la même institution pour déterminer ce droit.',
  null,
  pg_catalog.now()
);

insert into internal.rag_rule_template_facts (
  template_version_id,
  fact_key,
  value_type,
  extractor_key,
  label_fr,
  clarification_label_fr,
  minimum_number,
  maximum_number,
  integer_only,
  display_order
)
values
  (
    'f0a00000-0000-4000-8000-000000000001'::uuid,
    'age_years',
    'number',
    'age_years_fr_v1',
    'Âge',
    'ton âge',
    14,
    100,
    true,
    10
  ),
  (
    'f0a00000-0000-4000-8000-000000000001'::uuid,
    'service_years',
    'number',
    'service_years_fr_v1',
    'Ancienneté',
    'ton nombre d’années de service dans la même institution',
    0,
    80,
    true,
    20
  );

insert into internal.rag_rule_template_fact_operators (
  template_version_id,
  fact_key,
  comparator
)
values
  (
    'f0a00000-0000-4000-8000-000000000001'::uuid,
    'age_years',
    '<'
  ),
  (
    'f0a00000-0000-4000-8000-000000000001'::uuid,
    'age_years',
    '>='
  ),
  (
    'f0a00000-0000-4000-8000-000000000001'::uuid,
    'service_years',
    '>='
  );

insert into internal.rag_rule_template_fact_constraints (
  template_version_id,
  constraint_key,
  left_fact_key,
  comparator,
  right_fact_key,
  error_code
)
values (
  'f0a00000-0000-4000-8000-000000000001'::uuid,
  'service_not_greater_than_age',
  'service_years',
  '<=',
  'age_years',
  'impossible_question_facts'
);

-- ---------------------------------------------------------------------------
-- 4. Extension additive du modèle client
-- ---------------------------------------------------------------------------

alter table internal.rag_rule_sets
  add column template_version_id uuid,
  add column source_package_id uuid,
  add column creation_origin text,
  add column approved_by uuid,
  add column approved_at timestamptz;

alter table internal.rag_rules
  add column template_version_id uuid;

alter table internal.rag_rule_condition_groups
  add column template_version_id uuid;

alter table internal.rag_rule_conditions
  add column template_version_id uuid,
  add column fact_value_type text,
  add column number_value numeric(18,6),
  add column category_value text;

alter table internal.rag_rule_sources
  add column template_version_id uuid;

-- outcome_value et threshold_value deviennent des nombres génériques.
-- Les données historiques restent des entiers et l’ancienne Edge Function
-- continue donc à les lire pendant l’étape A.
alter table internal.rag_rules
  alter column outcome_value type numeric(18,6)
  using outcome_value::numeric(18,6);

alter table internal.rag_rule_conditions
  alter column threshold_value type numeric(18,6)
  using threshold_value::numeric(18,6),
  alter column threshold_value drop not null;

alter table internal.rag_rule_sets
  alter column created_by drop not null;

-- Suppression des anciens CHECK fermés, remplacés par le gabarit et les FK.
alter table internal.rag_rule_sets
  drop constraint rag_rule_sets_strategy_check,
  drop constraint rag_rule_sets_unit_check,
  drop constraint rag_rule_sets_status_check,
  drop constraint rag_rule_sets_validation_bundle_check;

alter table internal.rag_rule_conditions
  drop constraint rag_rule_conditions_fact_check,
  drop constraint rag_rule_conditions_comparator_check,
  drop constraint rag_rule_conditions_threshold_check,
  drop constraint rag_rule_conditions_unique;

-- Backfill sans recréer aucun identifiant.
update internal.rag_rule_sets s
set
  template_version_id =
    'f0a00000-0000-4000-8000-000000000001'::uuid,
  creation_origin = 'manual_migration',
  approved_by = case
    when s.status = 'validated' then s.validated_by
    else null
  end,
  approved_at = case
    when s.status = 'validated' then s.validated_at
    else null
  end,
  status = case
    when s.status = 'draft' then 'needs_attention'
    else s.status
  end
where s.rule_key = 'annual_leave_days';

update internal.rag_rules r
set template_version_id = s.template_version_id
from internal.rag_rule_sets s
where s.rule_set_id = r.rule_set_id;

update internal.rag_rule_condition_groups g
set template_version_id = r.template_version_id
from internal.rag_rules r
where r.rule_id = g.rule_id
  and r.rule_set_id = g.rule_set_id;

update internal.rag_rule_conditions c
set
  template_version_id = g.template_version_id,
  fact_value_type = 'number',
  number_value = c.threshold_value,
  category_value = null
from internal.rag_rule_condition_groups g
where g.condition_group_id = c.condition_group_id
  and g.rule_id = c.rule_id
  and g.rule_set_id = c.rule_set_id;

update internal.rag_rule_sources src
set template_version_id = r.template_version_id
from internal.rag_rules r
where r.rule_id = src.rule_id
  and r.rule_set_id = src.rule_set_id;

do $$
declare
  v_missing bigint;
begin
  select
    (select pg_catalog.count(*)
     from internal.rag_rule_sets
     where template_version_id is null
        or creation_origin is null)
    +
    (select pg_catalog.count(*)
     from internal.rag_rules
     where template_version_id is null)
    +
    (select pg_catalog.count(*)
     from internal.rag_rule_condition_groups
     where template_version_id is null)
    +
    (select pg_catalog.count(*)
     from internal.rag_rule_conditions
     where template_version_id is null
        or fact_value_type is null
        or number_value is null)
    +
    (select pg_catalog.count(*)
     from internal.rag_rule_sources
     where template_version_id is null)
  into v_missing;

  if v_missing <> 0 then
    raise exception
      'RAG-10.1 : backfill incomplet sur % ligne(s)',
      v_missing;
  end if;
end;
$$;

alter table internal.rag_rule_sets
  alter column template_version_id set not null,
  alter column creation_origin set not null;

alter table internal.rag_rules
  alter column template_version_id set not null;

alter table internal.rag_rule_condition_groups
  alter column template_version_id set not null;

alter table internal.rag_rule_conditions
  alter column template_version_id set not null,
  alter column fact_value_type set not null;

alter table internal.rag_rule_sources
  alter column template_version_id set not null;

-- ---------------------------------------------------------------------------
-- 5. Garanties structurelles composites
-- ---------------------------------------------------------------------------

alter table internal.rag_rule_sets
  add constraint rag_rule_sets_template_compatibility_fk
    foreign key (
      template_version_id,
      rule_key,
      aggregation_strategy,
      result_unit
    )
    references internal.rag_rule_template_versions (
      template_version_id,
      template_key,
      aggregation_strategy,
      result_unit
    )
    on update cascade
    on delete restrict,
  add constraint rag_rule_sets_rule_template_unique
    unique (rule_set_id, template_version_id),
  add constraint rag_rule_sets_identity_template_unique
    unique (
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    ),
  add constraint rag_rule_sets_creation_origin_check
    check (
      creation_origin in (
        'manual_migration',
        'automatic_extraction',
        'reused_package'
      )
    ),
  add constraint rag_rule_sets_creator_origin_check
    check (
      (creation_origin = 'manual_migration' and created_by is not null)
      or (
        creation_origin in ('automatic_extraction', 'reused_package')
        and created_by is null
      )
    ),
  add constraint rag_rule_sets_status_check
    check (
      status in (
        'proposed',
        'needs_attention',
        'approved',
        'validated',
        'rejected',
        'invalidated'
      )
    ),
  add constraint rag_rule_sets_state_bundle_check
    check (
      (
        status in ('proposed', 'needs_attention', 'rejected')
        and approved_by is null
        and approved_at is null
        and validated_by is null
        and validated_at is null
        and invalidated_at is null
        and invalidation_reason is null
      )
      or
      (
        status = 'approved'
        and approved_by is not null
        and approved_at is not null
        and validated_by is null
        and validated_at is null
        and invalidated_at is null
        and invalidation_reason is null
      )
      or
      (
        status = 'validated'
        and approved_by is not null
        and approved_at is not null
        and validated_by is not null
        and validated_at is not null
        and invalidated_at is null
        and invalidation_reason is null
      )
      or
      (
        status = 'invalidated'
        and approved_by is null
        and approved_at is null
        and validated_by is null
        and validated_at is null
        and invalidated_at is not null
        and invalidation_reason is not null
      )
    ),
  add constraint rag_rule_sets_source_package_reserved_check
    check (source_package_id is null),
  add constraint rag_rule_sets_approver_institution_fk
    foreign key (approved_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade
    on delete restrict;

alter table internal.rag_rules
  add constraint rag_rules_rule_template_unique
    unique (rule_id, rule_set_id, template_version_id),
  add constraint rag_rules_identity_template_unique
    unique (
      rule_id,
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    ),
  add constraint rag_rules_rule_set_template_fk
    foreign key (
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    )
    references internal.rag_rule_sets (
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    )
    on update cascade
    on delete cascade;

alter table internal.rag_rule_condition_groups
  add constraint rag_rule_condition_groups_template_unique
    unique (
      condition_group_id,
      rule_id,
      rule_set_id,
      template_version_id
    ),
  add constraint rag_rule_condition_groups_identity_template_unique
    unique (
      condition_group_id,
      rule_id,
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    ),
  add constraint rag_rule_condition_groups_rule_template_fk
    foreign key (
      rule_id,
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    )
    references internal.rag_rules (
      rule_id,
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    )
    on update cascade
    on delete cascade;

alter table internal.rag_rule_conditions
  add constraint rag_rule_conditions_group_template_fk
    foreign key (
      condition_group_id,
      rule_id,
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    )
    references internal.rag_rule_condition_groups (
      condition_group_id,
      rule_id,
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    )
    on update cascade
    on delete cascade,
  add constraint rag_rule_conditions_fact_type_fk
    foreign key (
      template_version_id,
      fact_key,
      fact_value_type
    )
    references internal.rag_rule_template_facts (
      template_version_id,
      fact_key,
      value_type
    )
    on update cascade
    on delete restrict,
  add constraint rag_rule_conditions_operator_fk
    foreign key (
      template_version_id,
      fact_key,
      comparator
    )
    references internal.rag_rule_template_fact_operators (
      template_version_id,
      fact_key,
      comparator
    )
    on update cascade
    on delete restrict,
  add constraint rag_rule_conditions_category_value_fk
    foreign key (
      template_version_id,
      fact_key,
      category_value
    )
    references internal.rag_rule_template_fact_values (
      template_version_id,
      fact_key,
      value_key
    )
    on update cascade
    on delete restrict,
  add constraint rag_rule_conditions_typed_value_check
    check (
      (
        fact_value_type = 'number'
        and number_value is not null
        and category_value is null
        and threshold_value = number_value
      )
      or
      (
        fact_value_type = 'category'
        and number_value is null
        and category_value is not null
        and threshold_value is null
      )
    ),
  add constraint rag_rule_conditions_unique
    unique nulls not distinct (
      condition_group_id,
      fact_key,
      comparator,
      number_value,
      category_value
    );

alter table internal.rag_rule_sources
  add constraint rag_rule_sources_set_template_fk
    foreign key (rule_set_id, template_version_id)
    references internal.rag_rule_sets (
      rule_set_id,
      template_version_id
    )
    on update cascade
    on delete cascade,
  add constraint rag_rule_sources_rule_template_fk
    foreign key (
      rule_id,
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    )
    references internal.rag_rules (
      rule_id,
      rule_set_id,
      document_id,
      institution_id,
      template_version_id
    )
    on update cascade
    on delete cascade;

-- ---------------------------------------------------------------------------
-- 6. Validations serveur identiques pour IA et corrections humaines
-- ---------------------------------------------------------------------------

create or replace function internal.validate_rag_template_runtime_keys()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not exists (
    select 1
    from internal.rag_rule_runtime_registry r
    where r.key_type = 'intent_detector'
      and r.runtime_key = new.intent_detector_key
  ) then
    raise exception
      'runtime intent detector inconnu : %',
      new.intent_detector_key;
  end if;

  if not exists (
    select 1
    from internal.rag_rule_runtime_registry r
    where r.key_type = 'renderer'
      and r.runtime_key = new.renderer_key
  ) then
    raise exception 'runtime renderer inconnu : %', new.renderer_key;
  end if;

  if not exists (
    select 1
    from internal.rag_rule_runtime_registry r
    where r.key_type = 'aggregation_strategy'
      and r.runtime_key = new.aggregation_strategy
  ) then
    raise exception
      'runtime aggregation strategy inconnue : %',
      new.aggregation_strategy;
  end if;

  return new;
end;
$function$;

create trigger rag_rule_template_versions_validate_runtime
before insert or update of intent_detector_key, renderer_key,
  aggregation_strategy
on internal.rag_rule_template_versions
for each row execute function internal.validate_rag_template_runtime_keys();

create or replace function internal.validate_rag_template_fact_runtime()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if not exists (
    select 1
    from internal.rag_rule_runtime_registry r
    where r.key_type = 'fact_extractor'
      and r.runtime_key = new.extractor_key
  ) then
    raise exception 'runtime fact extractor inconnu : %', new.extractor_key;
  end if;
  return new;
end;
$function$;

create trigger rag_rule_template_facts_validate_runtime
before insert or update of extractor_key
on internal.rag_rule_template_facts
for each row execute function internal.validate_rag_template_fact_runtime();

create or replace function internal.prevent_published_rag_template_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if old.status = 'retired' and new is distinct from old then
    raise exception
      'Une version de gabarit publiée ou retirée est immuable';
  end if;

  if old.status = 'published'
     and not (
       new.status = 'retired'
       and new.template_version_id = old.template_version_id
       and new.template_key = old.template_key
       and new.version_number = old.version_number
       and new.result_value_type = old.result_value_type
       and new.result_integer_only = old.result_integer_only
       and new.result_minimum_number
         is not distinct from old.result_minimum_number
       and new.result_maximum_number
         is not distinct from old.result_maximum_number
       and new.result_unit = old.result_unit
       and new.aggregation_strategy = old.aggregation_strategy
       and new.intent_detector_key = old.intent_detector_key
       and new.renderer_key = old.renderer_key
       and new.clarification_message_fr = old.clarification_message_fr
       and new.published_by is not distinct from old.published_by
       and new.published_at is not distinct from old.published_at
       and new.created_at is not distinct from old.created_at
       and new.retired_at is not null
     )
  then
    raise exception
      'Une version publiée ne peut être que retirée sans autre modification';
  end if;
  return new;
end;
$function$;

create trigger rag_rule_template_versions_immutable
before update on internal.rag_rule_template_versions
for each row execute function
  internal.prevent_published_rag_template_mutation();

create trigger rag_rule_template_versions_set_updated_at
before update on internal.rag_rule_template_versions
for each row execute function internal.rag_set_updated_at();

create or replace function internal.prevent_published_template_child_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_template_version_id uuid;
  v_status text;
begin
  v_template_version_id := case
    when tg_op = 'DELETE' then old.template_version_id
    else new.template_version_id
  end;

  select v.status
  into v_status
  from internal.rag_rule_template_versions v
  where v.template_version_id = v_template_version_id;

  if v_status in ('published', 'retired') then
    raise exception
      'Le contenu d’une version publiée ou retirée est immuable';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$function$;

create trigger rag_rule_template_facts_immutable
before insert or update or delete
on internal.rag_rule_template_facts
for each row execute function
  internal.prevent_published_template_child_mutation();

create trigger rag_rule_template_fact_values_immutable
before insert or update or delete
on internal.rag_rule_template_fact_values
for each row execute function
  internal.prevent_published_template_child_mutation();

create trigger rag_rule_template_fact_operators_immutable
before insert or update or delete
on internal.rag_rule_template_fact_operators
for each row execute function
  internal.prevent_published_template_child_mutation();

create trigger rag_rule_template_fact_constraints_immutable
before insert or update or delete
on internal.rag_rule_template_fact_constraints
for each row execute function
  internal.prevent_published_template_child_mutation();

create or replace function internal.protect_rag_runtime_registry_key()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if (
    old.key_type = 'intent_detector'
    and exists (
      select 1
      from internal.rag_rule_template_versions v
      where v.intent_detector_key = old.runtime_key
    )
  ) or (
    old.key_type = 'renderer'
    and exists (
      select 1
      from internal.rag_rule_template_versions v
      where v.renderer_key = old.runtime_key
    )
  ) or (
    old.key_type = 'aggregation_strategy'
    and exists (
      select 1
      from internal.rag_rule_template_versions v
      where v.aggregation_strategy = old.runtime_key
    )
  ) or (
    old.key_type = 'fact_extractor'
    and exists (
      select 1
      from internal.rag_rule_template_facts f
      where f.extractor_key = old.runtime_key
    )
  ) then
    raise exception
      'Clé runtime encore référencée : %/%',
      old.key_type,
      old.runtime_key;
  end if;
  return old;
end;
$function$;

create trigger rag_rule_runtime_registry_protect_delete
before delete on internal.rag_rule_runtime_registry
for each row execute function internal.protect_rag_runtime_registry_key();

create or replace function internal.validate_rag_rule_condition_typed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_value_type text;
  v_minimum numeric(18,6);
  v_maximum numeric(18,6);
  v_integer_only boolean;
begin
  select
    f.value_type,
    f.minimum_number,
    f.maximum_number,
    f.integer_only
  into
    v_value_type,
    v_minimum,
    v_maximum,
    v_integer_only
  from internal.rag_rule_template_facts f
  where f.template_version_id = new.template_version_id
    and f.fact_key = new.fact_key;

  if not found or v_value_type <> new.fact_value_type then
    raise exception 'Fait absent ou type incohérent';
  end if;

  if new.fact_value_type = 'number' then
    if new.number_value is null
       or (v_minimum is not null and new.number_value < v_minimum)
       or (v_maximum is not null and new.number_value > v_maximum)
       or (
         v_integer_only
         and new.number_value <> pg_catalog.trunc(new.number_value)
       )
    then
      raise exception 'Valeur numérique hors contrat du gabarit';
    end if;
  elsif new.fact_value_type = 'category' then
    if new.category_value is null
       or not exists (
         select 1
         from internal.rag_rule_template_fact_values fv
         where fv.template_version_id = new.template_version_id
           and fv.fact_key = new.fact_key
           and fv.value_key = new.category_value
       )
    then
      raise exception 'Valeur catégorielle hors contrat du gabarit';
    end if;
  else
    raise exception 'Type de fait inconnu';
  end if;

  return new;
end;
$function$;

create trigger rag_rule_conditions_validate_typed
before insert or update of template_version_id, fact_key, fact_value_type,
  comparator, number_value, category_value, threshold_value
on internal.rag_rule_conditions
for each row execute function internal.validate_rag_rule_condition_typed();

create or replace function internal.validate_rag_rule_outcome_typed()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_value_type text;
  v_integer_only boolean;
  v_minimum numeric(18,6);
  v_maximum numeric(18,6);
begin
  select
    v.result_value_type,
    v.result_integer_only,
    v.result_minimum_number,
    v.result_maximum_number
  into
    v_value_type,
    v_integer_only,
    v_minimum,
    v_maximum
  from internal.rag_rule_template_versions v
  where v.template_version_id = new.template_version_id;

  if not found or v_value_type <> 'number' then
    raise exception 'Type de résultat non pris en charge';
  end if;
  if (v_minimum is not null and new.outcome_value < v_minimum)
     or (v_maximum is not null and new.outcome_value > v_maximum)
     or (
       v_integer_only
       and new.outcome_value <> pg_catalog.trunc(new.outcome_value)
     )
  then
    raise exception 'Résultat hors contrat du gabarit';
  end if;

  return new;
end;
$function$;

create trigger rag_rules_validate_typed_outcome
before insert or update of template_version_id, outcome_value
on internal.rag_rules
for each row execute function internal.validate_rag_rule_outcome_typed();

-- ---------------------------------------------------------------------------
-- 7. Cycle de vie générique
-- ---------------------------------------------------------------------------

create or replace function internal.invalidate_rag_rule_set_from_child()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_rule_set_id uuid;
begin
  v_rule_set_id := case
    when tg_op = 'DELETE' then old.rule_set_id
    else new.rule_set_id
  end;

  update internal.rag_rule_sets s
  set
    status = 'needs_attention',
    approved_by = null,
    approved_at = null,
    validated_by = null,
    validated_at = null,
    invalidated_at = null,
    invalidation_reason = null
  where s.rule_set_id = v_rule_set_id
    and s.status in ('approved', 'validated');

  return case when tg_op = 'DELETE' then old else new end;
end;
$function$;

create trigger rag_rules_invalidate_rule_set
after insert or update or delete on internal.rag_rules
for each row execute function internal.invalidate_rag_rule_set_from_child();

create trigger rag_rule_condition_groups_invalidate_rule_set
after insert or update or delete on internal.rag_rule_condition_groups
for each row execute function internal.invalidate_rag_rule_set_from_child();

create trigger rag_rule_conditions_invalidate_rule_set
after insert or update or delete on internal.rag_rule_conditions
for each row execute function internal.invalidate_rag_rule_set_from_child();

create trigger rag_rule_sources_invalidate_rule_set
after insert or update or delete on internal.rag_rule_sources
for each row execute function internal.invalidate_rag_rule_set_from_child();

create or replace function internal.invalidate_rag_rules_from_document()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.status not in ('ready', 'active')
     and old.status is distinct from new.status
  then
    update internal.rag_rule_sets s
    set
      status = 'invalidated',
      approved_by = null,
      approved_at = null,
      validated_by = null,
      validated_at = null,
      invalidated_at = pg_catalog.now(),
      invalidation_reason = 'document_not_eligible'
    where s.document_id = new.document_id
      and s.institution_id = new.institution_id
      and s.status in (
        'proposed',
        'needs_attention',
        'approved',
        'validated'
      );
  end if;

  return new;
end;
$function$;

create trigger rag_documents_invalidate_numeric_rules
after update of status on internal.rag_documents
for each row execute function internal.invalidate_rag_rules_from_document();

create or replace function internal.promote_approved_rag_rules_on_activation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if new.status = 'active'
     and old.status is distinct from new.status
  then
    update internal.rag_rule_sets s
    set
      status = 'validated',
      validated_by = s.approved_by,
      validated_at = pg_catalog.now(),
      invalidated_at = null,
      invalidation_reason = null
    where s.document_id = new.document_id
      and s.institution_id = new.institution_id
      and s.status = 'approved';
  end if;
  return new;
end;
$function$;

create trigger rag_documents_promote_approved_rules
after update of status on internal.rag_documents
for each row execute function
  internal.promote_approved_rag_rules_on_activation();

create or replace function internal.invalidate_rag_rules_from_passage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update internal.rag_rule_sets s
  set
    status = 'needs_attention',
    approved_by = null,
    approved_at = null,
    validated_by = null,
    validated_at = null,
    invalidated_at = null,
    invalidation_reason = null
  where s.status in ('approved', 'validated')
    and exists (
      select 1
      from internal.rag_rule_sources src
      where src.rule_set_id = s.rule_set_id
        and src.passage_id = new.passage_id
    );

  return new;
end;
$function$;

create trigger rag_passages_invalidate_numeric_rules
after update of content, content_sha256, source_reference,
  page_start, page_end, section_title, article_reference
on internal.rag_passages
for each row execute function internal.invalidate_rag_rules_from_passage();

-- ---------------------------------------------------------------------------
-- 8. Approbation / validation humaine atomique
-- ---------------------------------------------------------------------------

create or replace function server_api.validate_rag_rule_set(
  p_auth_uid uuid,
  p_rule_set_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_document_id uuid;
  v_document_status text;
  v_template_status text;
  v_rule_count integer;
  v_default_count integer;
  v_invalid_rule_count integer;
  v_missing_source_count integer;
  v_target_status text;
  v_now timestamptz := pg_catalog.now();
begin
  select r.authorized, r.user_uuid, r.institution_id
  into v_authorized, v_admin_user_uuid, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r
  limit 1;

  if coalesce(v_authorized, false) is not true
     or v_admin_user_uuid is null
     or v_institution_id is null
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'admin_unauthorized'
    );
  end if;

  select
    s.document_id,
    d.status,
    tv.status
  into
    v_document_id,
    v_document_status,
    v_template_status
  from internal.rag_rule_sets s
  join internal.rag_documents d
    on d.document_id = s.document_id
   and d.institution_id = s.institution_id
  join internal.rag_rule_template_versions tv
    on tv.template_version_id = s.template_version_id
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id
  for update of s;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'rule_set_not_found'
    );
  end if;

  if v_document_status not in ('ready', 'active') then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_eligible'
    );
  end if;

  if v_template_status not in ('published', 'retired') then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'template_not_executable'
    );
  end if;

  select
    pg_catalog.count(*)::integer,
    pg_catalog.count(*) filter (where r.is_default)::integer
  into v_rule_count, v_default_count
  from internal.rag_rules r
  where r.rule_set_id = p_rule_set_id;

  if v_rule_count = 0 or v_default_count <> 1 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_rule_structure'
    );
  end if;

  select pg_catalog.count(*)::integer
  into v_invalid_rule_count
  from internal.rag_rules r
  where r.rule_set_id = p_rule_set_id
    and (
      (
        r.is_default
        and exists (
          select 1
          from internal.rag_rule_condition_groups g
          where g.rule_id = r.rule_id
        )
      )
      or
      (
        not r.is_default
        and not exists (
          select 1
          from internal.rag_rule_condition_groups g
          where g.rule_id = r.rule_id
        )
      )
      or exists (
        select 1
        from internal.rag_rule_condition_groups g
        where g.rule_id = r.rule_id
          and not exists (
            select 1
            from internal.rag_rule_conditions c
            where c.condition_group_id = g.condition_group_id
          )
      )
    );

  if v_invalid_rule_count <> 0 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_rule_structure'
    );
  end if;

  select pg_catalog.count(*)::integer
  into v_missing_source_count
  from internal.rag_rules r
  where r.rule_set_id = p_rule_set_id
    and not exists (
      select 1
      from internal.rag_rule_sources src
      where src.rule_id = r.rule_id
        and src.rule_set_id = r.rule_set_id
        and src.document_id = r.document_id
        and src.institution_id = r.institution_id
        and src.template_version_id = r.template_version_id
    );

  if v_missing_source_count <> 0 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'missing_rule_sources'
    );
  end if;

  v_target_status := case
    when v_document_status = 'active' then 'validated'
    else 'approved'
  end;

  update internal.rag_rule_sets s
  set
    status = v_target_status,
    approved_by = v_admin_user_uuid,
    approved_at = v_now,
    validated_by = case
      when v_target_status = 'validated' then v_admin_user_uuid
      else null
    end,
    validated_at = case
      when v_target_status = 'validated' then v_now
      else null
    end,
    invalidated_at = null,
    invalidation_reason = null
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id;

  insert into internal.security_log (
    event_type,
    user_uuid,
    institution_id,
    actor_admin_uuid,
    detail
  )
  values (
    case
      when v_target_status = 'validated'
        then 'rag_rule_set_validated'
      else 'rag_rule_set_approved'
    end,
    v_admin_user_uuid,
    v_institution_id,
    v_admin_user_uuid,
    pg_catalog.jsonb_build_object(
      'rule_set_id', p_rule_set_id,
      'document_id', v_document_id
    )
  );

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', v_target_status,
    'rule_set_id', p_rule_set_id,
    'document_id', v_document_id
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 9. Lecture fermée du contexte déterministe
-- ---------------------------------------------------------------------------

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

  select coalesce(
    pg_catalog.jsonb_agg(x.passage_id order by x.passage_id),
    '[]'::jsonb
  )
  into v_protected_passage_ids
  from (
    select distinct src.passage_id
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

create or replace function public.get_rag_rule_context_wrapper(
  p_auth_uid uuid,
  p_template_key text,
  p_passage_ids uuid[]
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select server_api.get_rag_rule_context(
    p_auth_uid,
    p_template_key,
    p_passage_ids
  );
$function$;

-- ---------------------------------------------------------------------------
-- 10. RLS, droits et frontières d’autorisation
-- ---------------------------------------------------------------------------

alter table internal.rag_rule_runtime_registry
  enable row level security;
alter table internal.rag_rule_runtime_registry
  force row level security;
alter table internal.rag_rule_templates
  enable row level security;
alter table internal.rag_rule_templates
  force row level security;
alter table internal.rag_rule_template_versions
  enable row level security;
alter table internal.rag_rule_template_versions
  force row level security;
alter table internal.rag_rule_template_facts
  enable row level security;
alter table internal.rag_rule_template_facts
  force row level security;
alter table internal.rag_rule_template_fact_values
  enable row level security;
alter table internal.rag_rule_template_fact_values
  force row level security;
alter table internal.rag_rule_template_fact_operators
  enable row level security;
alter table internal.rag_rule_template_fact_operators
  force row level security;
alter table internal.rag_rule_template_fact_constraints
  enable row level security;
alter table internal.rag_rule_template_fact_constraints
  force row level security;
alter table internal.platform_admins
  enable row level security;
alter table internal.platform_admins
  force row level security;
alter table internal.platform_security_log
  enable row level security;
alter table internal.platform_security_log
  force row level security;

revoke all on table internal.rag_rule_runtime_registry
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_templates
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_template_versions
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_template_facts
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_template_fact_values
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_template_fact_operators
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_template_fact_constraints
  from public, anon, authenticated, service_role;
revoke all on table internal.platform_admins
  from public, anon, authenticated, service_role;
revoke all on table internal.platform_security_log
  from public, anon, authenticated, service_role;
revoke all on sequence internal.platform_security_log_id_seq
  from public, anon, authenticated, service_role;

revoke all on function
  internal.validate_rag_template_runtime_keys()
  from public, anon, authenticated, service_role;
revoke all on function
  internal.validate_rag_template_fact_runtime()
  from public, anon, authenticated, service_role;
revoke all on function
  internal.prevent_published_rag_template_mutation()
  from public, anon, authenticated, service_role;
revoke all on function
  internal.prevent_published_template_child_mutation()
  from public, anon, authenticated, service_role;
revoke all on function
  internal.protect_rag_runtime_registry_key()
  from public, anon, authenticated, service_role;
revoke all on function
  internal.validate_rag_rule_condition_typed()
  from public, anon, authenticated, service_role;
revoke all on function
  internal.validate_rag_rule_outcome_typed()
  from public, anon, authenticated, service_role;
revoke all on function
  internal.promote_approved_rag_rules_on_activation()
  from public, anon, authenticated, service_role;

revoke all on function
  server_api.check_platform_role(uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function
  server_api.get_rule_template_catalog(uuid)
  from public, anon, authenticated, service_role;
revoke all on function
  server_api.get_rag_rule_runtime_registry()
  from public, anon, authenticated, service_role;
revoke all on function
  server_api.get_rag_rule_context(uuid, text, uuid[])
  from public, anon, authenticated, service_role;

revoke all on function
  public.get_rule_template_catalog_wrapper(uuid)
  from public, anon, authenticated;
grant execute on function
  public.get_rule_template_catalog_wrapper(uuid)
  to service_role;

revoke all on function
  public.get_rag_rule_runtime_registry_wrapper()
  from public, anon, authenticated;
grant execute on function
  public.get_rag_rule_runtime_registry_wrapper()
  to service_role;

revoke all on function
  public.get_rag_rule_context_wrapper(uuid, text, uuid[])
  from public, anon, authenticated;
grant execute on function
  public.get_rag_rule_context_wrapper(uuid, text, uuid[])
  to service_role;

-- Le wrapper historique reste disponible pendant le déploiement progressif.
revoke all on function
  public.get_validated_rag_rule_sets_wrapper(uuid, text, uuid[])
  from public, anon, authenticated;
grant execute on function
  public.get_validated_rag_rule_sets_wrapper(uuid, text, uuid[])
  to service_role;

-- ---------------------------------------------------------------------------
-- 11. Postconditions de migration
-- ---------------------------------------------------------------------------

do $$
declare
  v_error_count bigint;
begin
  if not exists (
    select 1
    from internal.rag_rule_template_versions v
    where v.template_version_id =
      'f0a00000-0000-4000-8000-000000000001'::uuid
      and v.template_key = 'annual_leave_days'
      and v.version_number = 1
      and v.status = 'published'
  ) then
    raise exception 'RAG-10.1 : gabarit vacances non publié';
  end if;

  select pg_catalog.count(*)
  into v_error_count
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

  if v_error_count <> 0 then
    raise exception
      'RAG-10.1 : % jeu(x) vacances mal migré(s)',
      v_error_count;
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint c
    where c.conname =
      'rag_rule_template_versions_compatibility_unique'
      and c.contype = 'u'
  ) then
    raise exception
      'RAG-10.1 : contrainte UNIQUE de compatibilité absente';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_indexes i
    where i.schemaname = 'internal'
      and i.indexname =
        'rag_rule_sets_validated_institution_key_unique'
  ) then
    raise exception
      'RAG-10.1 : unicité des règles validées absente';
  end if;
end;
$$;

notify pgrst, 'reload schema';

rollback;

-- Contrôles de lecture complémentaires dans :
-- tests/sql/rag-10-1-foundation.test.sql
