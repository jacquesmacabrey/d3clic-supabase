/*
  D3clic — RAG : règles numériques validées
  Projet cible : Supabase STAGING uniquement
  Statut : À AUDITER — NE PAS EXÉCUTER AVANT VALIDATION

  Objectif :
  - stocker les règles numériques sensibles sous forme relationnelle ;
  - rattacher chaque règle à une version précise d'un document et à ses passages ;
  - invalider automatiquement une validation après toute modification ;
  - rendre inutilisable une règle dès que son document n'est plus actif ;
  - fournir à l'Edge Function une lecture fermée, isolée par institution.

  Cette migration ne contient aucune règle métier ni donnée de test.
  Elle ne modifie pas encore rag-answer-question.
*/

begin;

-- ---------------------------------------------------------------------------
-- 0. Préconditions
-- ---------------------------------------------------------------------------

do $$
begin
  if to_regclass('internal.institutions') is null
     or to_regclass('internal.users') is null
     or to_regclass('internal.devices') is null
     or to_regclass('internal.rag_documents') is null
     or to_regclass('internal.rag_passages') is null
  then
    raise exception
      'Précondition manquante : socle D3clic ou tables documentaires RAG absents';
  end if;

  if to_regprocedure('server_api.check_backoffice_role(uuid,text)') is null then
    raise exception
      'Précondition manquante : server_api.check_backoffice_role(uuid,text)';
  end if;
end;
$$;

/*
  Permet aux sources de garantir par une FK composite qu'un passage appartient
  bien au document et à l'institution de la règle.
*/
create unique index if not exists rag_passages_identity_document_institution_idx
  on internal.rag_passages (passage_id, document_id, institution_id);

-- ---------------------------------------------------------------------------
-- 1. Jeux de règles
-- ---------------------------------------------------------------------------

create table internal.rag_rule_sets (
  rule_set_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  document_id uuid not null,
  rule_key text not null,

  /*
    Première stratégie volontairement limitée au cas validé des vacances.
    Une nouvelle stratégie métier exigera une migration et des tests propres.
  */
  aggregation_strategy text not null
    default 'maximum_applicable_entitlement',
  result_unit text not null default 'days',

  status text not null default 'draft',
  created_by uuid not null,
  validated_by uuid,
  validated_at timestamptz,
  invalidated_at timestamptz,
  invalidation_reason text,

  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),

  constraint rag_rule_sets_document_institution_fk
    foreign key (document_id, institution_id)
    references internal.rag_documents (document_id, institution_id)
    on update cascade
    on delete cascade,

  constraint rag_rule_sets_creator_institution_fk
    foreign key (created_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade
    on delete restrict,

  constraint rag_rule_sets_validator_institution_fk
    foreign key (validated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade
    on delete restrict,

  constraint rag_rule_sets_identity_unique
    unique (rule_set_id, document_id, institution_id),

  constraint rag_rule_sets_document_key_unique
    unique (institution_id, document_id, rule_key),

  constraint rag_rule_sets_key_check
    check (rule_key ~ '^[a-z][a-z0-9_]{2,99}$'),

  constraint rag_rule_sets_strategy_check
    check (aggregation_strategy = 'maximum_applicable_entitlement'),

  constraint rag_rule_sets_unit_check
    check (result_unit = 'days'),

  constraint rag_rule_sets_status_check
    check (status in ('draft', 'validated', 'invalidated')),

  constraint rag_rule_sets_validation_bundle_check
    check (
      (
        status = 'validated'
        and validated_by is not null
        and validated_at is not null
        and invalidated_at is null
        and invalidation_reason is null
      )
      or
      (
        status = 'draft'
        and validated_by is null
        and validated_at is null
        and invalidated_at is null
        and invalidation_reason is null
      )
      or
      (
        status = 'invalidated'
        and validated_by is null
        and validated_at is null
        and invalidated_at is not null
        and invalidation_reason is not null
      )
    ),

  constraint rag_rule_sets_invalidation_reason_check
    check (
      invalidation_reason is null
      or (
        invalidation_reason ~ '^[a-z0-9_]{1,100}$'
        and invalidation_reason = pg_catalog.btrim(invalidation_reason)
      )
    )
);

comment on table internal.rag_rule_sets is
  'Jeux de règles numériques validés, liés à une version documentaire précise.';

create index rag_rule_sets_institution_key_idx
  on internal.rag_rule_sets (institution_id, rule_key, status);

/*
  Comportement fermé : une institution ne peut jamais disposer de deux jeux
  validés pour le même domaine, même s'ils proviennent de documents différents.
  L'index reste la garantie finale en cas de validations concurrentes.
*/
create unique index rag_rule_sets_validated_institution_key_unique
  on internal.rag_rule_sets (institution_id, rule_key)
  where status = 'validated';

create index rag_rule_sets_document_idx
  on internal.rag_rule_sets (document_id, institution_id);

-- ---------------------------------------------------------------------------
-- 2. Résultats possibles
-- ---------------------------------------------------------------------------

create table internal.rag_rules (
  rule_id uuid primary key default gen_random_uuid(),
  rule_set_id uuid not null,
  document_id uuid not null,
  institution_id text not null,

  outcome_value integer not null,
  is_default boolean not null default false,
  display_order integer not null,
  label text not null,

  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),

  constraint rag_rules_rule_set_fk
    foreign key (rule_set_id, document_id, institution_id)
    references internal.rag_rule_sets (
      rule_set_id,
      document_id,
      institution_id
    )
    on update cascade
    on delete cascade,

  constraint rag_rules_identity_unique
    unique (
      rule_id,
      rule_set_id,
      document_id,
      institution_id
    ),

  constraint rag_rules_order_unique
    unique (rule_set_id, display_order),

  constraint rag_rules_outcome_check
    check (outcome_value between 0 and 10000),

  constraint rag_rules_order_check
    check (display_order between 0 and 1000),

  constraint rag_rules_label_check
    check (
      pg_catalog.char_length(pg_catalog.btrim(label)) between 1 and 250
      and label = pg_catalog.btrim(label)
    )
);

create unique index rag_rules_one_default_per_set_idx
  on internal.rag_rules (rule_set_id)
  where is_default;

comment on table internal.rag_rules is
  'Résultats numériques possibles d’un jeu de règles. Une règle par défaut est obligatoire à la validation.';

-- ---------------------------------------------------------------------------
-- 3. Conditions en forme normale : groupes OR, conditions AND
-- ---------------------------------------------------------------------------

/*
  Une règle est satisfaite si au moins un groupe est satisfait.
  Dans un groupe, toutes les conditions doivent être satisfaites.

  Exemple "âge >= 50 OU ancienneté >= 15" :
  - groupe 1 : age_years >= 50
  - groupe 2 : service_years >= 15
*/
create table internal.rag_rule_condition_groups (
  condition_group_id uuid primary key default gen_random_uuid(),
  rule_id uuid not null,
  rule_set_id uuid not null,
  document_id uuid not null,
  institution_id text not null,
  display_order integer not null,

  constraint rag_rule_condition_groups_rule_fk
    foreign key (
      rule_id,
      rule_set_id,
      document_id,
      institution_id
    )
    references internal.rag_rules (
      rule_id,
      rule_set_id,
      document_id,
      institution_id
    )
    on update cascade
    on delete cascade,

  constraint rag_rule_condition_groups_identity_unique
    unique (
      condition_group_id,
      rule_id,
      rule_set_id,
      document_id,
      institution_id
    ),

  constraint rag_rule_condition_groups_order_unique
    unique (rule_id, display_order),

  constraint rag_rule_condition_groups_order_check
    check (display_order between 0 and 1000)
);

create table internal.rag_rule_conditions (
  condition_id uuid primary key default gen_random_uuid(),
  condition_group_id uuid not null,
  rule_id uuid not null,
  rule_set_id uuid not null,
  document_id uuid not null,
  institution_id text not null,

  fact_key text not null,
  comparator text not null,
  threshold_value integer not null,

  constraint rag_rule_conditions_group_fk
    foreign key (
      condition_group_id,
      rule_id,
      rule_set_id,
      document_id,
      institution_id
    )
    references internal.rag_rule_condition_groups (
      condition_group_id,
      rule_id,
      rule_set_id,
      document_id,
      institution_id
    )
    on update cascade
    on delete cascade,

  constraint rag_rule_conditions_unique
    unique (
      condition_group_id,
      fact_key,
      comparator,
      threshold_value
    ),

  constraint rag_rule_conditions_fact_check
    check (fact_key in ('age_years', 'service_years')),

  constraint rag_rule_conditions_comparator_check
    check (comparator in ('>=', '>', '<=', '<', '=')),

  constraint rag_rule_conditions_threshold_check
    check (threshold_value between 0 and 150)
);

comment on table internal.rag_rule_condition_groups is
  'Branches OR d’une règle. Toutes les conditions d’une branche sont combinées avec AND.';

comment on table internal.rag_rule_conditions is
  'Comparaisons déterministes autorisées pour l’âge et l’ancienneté.';

-- ---------------------------------------------------------------------------
-- 4. Sources obligatoires
-- ---------------------------------------------------------------------------

create table internal.rag_rule_sources (
  rule_id uuid not null,
  rule_set_id uuid not null,
  passage_id uuid not null,
  document_id uuid not null,
  institution_id text not null,

  constraint rag_rule_sources_pkey
    primary key (rule_id, passage_id),

  constraint rag_rule_sources_rule_fk
    foreign key (
      rule_id,
      rule_set_id,
      document_id,
      institution_id
    )
    references internal.rag_rules (
      rule_id,
      rule_set_id,
      document_id,
      institution_id
    )
    on update cascade
    on delete cascade,

  constraint rag_rule_sources_passage_fk
    foreign key (passage_id, document_id, institution_id)
    references internal.rag_passages (
      passage_id,
      document_id,
      institution_id
    )
    on update cascade
    on delete restrict
);

create index rag_rule_sources_passage_idx
  on internal.rag_rule_sources (
    passage_id,
    institution_id,
    rule_set_id
  );

comment on table internal.rag_rule_sources is
  'Passages documentaires validant chaque résultat numérique. Les identifiants restent internes au serveur.';

-- ---------------------------------------------------------------------------
-- 5. Invalidation automatique après modification
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
    status = 'draft',
    validated_by = null,
    validated_at = null,
    invalidated_at = null,
    invalidation_reason = null
  where s.rule_set_id = v_rule_set_id
    and s.status = 'validated';

  return case when tg_op = 'DELETE' then old else new end;
end;
$function$;

revoke all on function internal.invalidate_rag_rule_set_from_child()
  from public, anon, authenticated, service_role;

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
      validated_by = null,
      validated_at = null,
      invalidated_at = pg_catalog.now(),
      invalidation_reason = 'document_not_eligible'
    where s.document_id = new.document_id
      and s.institution_id = new.institution_id
      and s.status = 'validated';
  end if;

  return new;
end;
$function$;

revoke all on function internal.invalidate_rag_rules_from_document()
  from public, anon, authenticated, service_role;

create trigger rag_documents_invalidate_numeric_rules
after update of status on internal.rag_documents
for each row execute function internal.invalidate_rag_rules_from_document();

create or replace function internal.invalidate_rag_rules_from_passage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  update internal.rag_rule_sets s
  set
    status = 'draft',
    validated_by = null,
    validated_at = null,
    invalidated_at = null,
    invalidation_reason = null
  where s.status = 'validated'
    and exists (
      select 1
      from internal.rag_rule_sources rs
      where rs.rule_set_id = s.rule_set_id
        and rs.passage_id = new.passage_id
    );

  return new;
end;
$function$;

revoke all on function internal.invalidate_rag_rules_from_passage()
  from public, anon, authenticated, service_role;

create trigger rag_passages_invalidate_numeric_rules
after update of content, content_sha256, source_reference,
  page_start, page_end, section_title, article_reference
on internal.rag_passages
for each row execute function internal.invalidate_rag_rules_from_passage();

-- Mise à jour de updated_at avec la fonction déjà installée au Sprint RAG 1.
create trigger rag_rule_sets_set_updated_at
before update on internal.rag_rule_sets
for each row execute function internal.rag_set_updated_at();

create trigger rag_rules_set_updated_at
before update on internal.rag_rules
for each row execute function internal.rag_set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. Validation humaine atomique
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
  v_rule_count integer;
  v_default_count integer;
  v_invalid_rule_count integer;
  v_missing_source_count integer;
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

  select s.document_id, d.status
  into v_document_id, v_document_status
  from internal.rag_rule_sets s
  join internal.rag_documents d
    on d.document_id = s.document_id
   and d.institution_id = s.institution_id
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

  /*
    La règle par défaut ne doit avoir aucun groupe.
    Chaque autre règle doit avoir au moins un groupe, et chaque groupe au
    moins une condition.
  */
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
      from internal.rag_rule_sources rs
      where rs.rule_id = r.rule_id
        and rs.rule_set_id = r.rule_set_id
        and rs.document_id = r.document_id
        and rs.institution_id = r.institution_id
    );

  if v_missing_source_count <> 0 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'missing_rule_sources'
    );
  end if;

  update internal.rag_rule_sets s
  set
    status = 'validated',
    validated_by = v_admin_user_uuid,
    validated_at = pg_catalog.now(),
    invalidated_at = null,
    invalidation_reason = null
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'validated',
    'rule_set_id', p_rule_set_id,
    'document_id', v_document_id
  );
end;
$function$;

create or replace function public.validate_rag_rule_set_wrapper(
  p_auth_uid uuid,
  p_rule_set_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select server_api.validate_rag_rule_set(
    p_auth_uid,
    p_rule_set_id
  );
$function$;

-- ---------------------------------------------------------------------------
-- 7. Lecture fermée pour l'Edge Function
-- ---------------------------------------------------------------------------

create or replace function server_api.get_validated_rag_rule_sets(
  p_auth_uid uuid,
  p_rule_key text,
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

  if p_rule_key is not null
     and p_rule_key !~ '^[a-z][a-z0-9_]{2,99}$'
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_rule_key'
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

  if p_rule_key is null
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
        'aggregation_strategy', s.aggregation_strategy,
        'result_unit', s.result_unit,
        'document_id', s.document_id,
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
                            'comparator', c.comparator,
                            'threshold_value', c.threshold_value
                          )
                          order by c.fact_key, c.comparator, c.threshold_value
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
                  rs.passage_id
                  order by rs.passage_id
                )
                from internal.rag_rule_sources rs
                where rs.rule_id = r.rule_id
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
  where s.institution_id = v_institution_id
    and s.status = 'validated'
    and d.status = 'active'
    and (
      (p_rule_key is not null and s.rule_key = p_rule_key)
      or exists (
        select 1
        from internal.rag_rule_sources rs
        where rs.rule_set_id = s.rule_set_id
          and rs.passage_id = any(p_passage_ids)
      )
    );

  if pg_catalog.jsonb_array_length(v_rule_sets) = 0 then
    return pg_catalog.jsonb_build_object(
      'success', true,
      'status_code', 'no_validated_rule_set',
      'rule_sets', '[]'::jsonb
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'ok',
    'rule_sets', v_rule_sets
  );
end;
$function$;

create or replace function public.get_validated_rag_rule_sets_wrapper(
  p_auth_uid uuid,
  p_rule_key text,
  p_passage_ids uuid[]
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select server_api.get_validated_rag_rule_sets(
    p_auth_uid,
    p_rule_key,
    p_passage_ids
  );
$function$;

-- ---------------------------------------------------------------------------
-- 8. RLS et droits
-- ---------------------------------------------------------------------------

alter table internal.rag_rule_sets enable row level security;
alter table internal.rag_rule_sets force row level security;
alter table internal.rag_rules enable row level security;
alter table internal.rag_rules force row level security;
alter table internal.rag_rule_condition_groups enable row level security;
alter table internal.rag_rule_condition_groups force row level security;
alter table internal.rag_rule_conditions enable row level security;
alter table internal.rag_rule_conditions force row level security;
alter table internal.rag_rule_sources enable row level security;
alter table internal.rag_rule_sources force row level security;

revoke all on table internal.rag_rule_sets
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rules
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_condition_groups
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_conditions
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_sources
  from public, anon, authenticated, service_role;

revoke all on function server_api.validate_rag_rule_set(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.validate_rag_rule_set_wrapper(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.validate_rag_rule_set_wrapper(uuid, uuid)
  to service_role;

revoke all on function server_api.get_validated_rag_rule_sets(
  uuid,
  text,
  uuid[]
) from public, anon, authenticated, service_role;
revoke all on function public.get_validated_rag_rule_sets_wrapper(
  uuid,
  text,
  uuid[]
) from public, anon, authenticated;
grant execute on function public.get_validated_rag_rule_sets_wrapper(
  uuid,
  text,
  uuid[]
) to service_role;

notify pgrst, 'reload schema';

commit;

-- ---------------------------------------------------------------------------
-- 9. Contrôles en lecture seule à lancer séparément après installation
-- ---------------------------------------------------------------------------

/*
select
  tablename,
  rowsecurity
from pg_catalog.pg_tables
where schemaname = 'internal'
  and tablename in (
    'rag_rule_sets',
    'rag_rules',
    'rag_rule_condition_groups',
    'rag_rule_conditions',
    'rag_rule_sources'
  )
order by tablename;

select
  to_regprocedure(
    'public.validate_rag_rule_set_wrapper(uuid,uuid)'
  ) is not null as validation_wrapper,
  to_regprocedure(
    'public.get_validated_rag_rule_sets_wrapper(uuid,text,uuid[])'
  ) is not null as read_wrapper,
  has_function_privilege(
    'service_role',
    'public.get_validated_rag_rule_sets_wrapper(uuid,text,uuid[])',
    'EXECUTE'
  ) as service_role_read,
  has_function_privilege(
    'authenticated',
    'public.get_validated_rag_rule_sets_wrapper(uuid,text,uuid[])',
    'EXECUTE'
  ) is false as authenticated_cannot_read;

-- Appel fonctionnel réel du wrapper à travers un appareil actif.
-- Résultat attendu : success=true et status_code=no_validated_rule_set.
-- Si aucun appareil actif n'existe, la requête ne renvoie simplement aucune ligne.
select public.get_validated_rag_rule_sets_wrapper(
  active_device.device_auth_uid,
  'post_install_probe',
  array[]::uuid[]
)
from (
  select d.device_auth_uid
  from internal.devices d
  join internal.users u
    on u.user_uuid = d.user_uuid
  join internal.institutions i
    on i.institution_id = u.institution_id
  where d.user_uuid is not null
    and d.activated_at is not null
    and d.revoked_at is null
    and u.active is true
    and i.active is true
  order by d.activated_at desc
  limit 1
) active_device;
*/
