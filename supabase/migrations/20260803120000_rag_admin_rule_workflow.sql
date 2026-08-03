/*
  D3clic — RAG-10.7
  Administration, contrôle humain et cycle de vie des règles déterministes.

  Migration destinée au staging. Elle est additive pour les données métier et
  remplace uniquement les contraintes/fonctions de cycle de vie identifiées
  dans la conception RAG-10.7 v1.1.
*/

begin;

do $$
begin
  if pg_catalog.to_regclass('internal.rag_rule_sets') is null
     or pg_catalog.to_regclass('internal.rag_rule_template_versions') is null
     or pg_catalog.to_regclass('internal.rag_rule_sources') is null
     or pg_catalog.to_regprocedure(
       'server_api.check_backoffice_role(uuid,text)'
     ) is null
  then
    raise exception 'RAG-10.7 : socle RAG-10.6 incomplet';
  end if;
  if not exists (
    select 1 from internal.rag_rule_template_versions
    where template_version_id =
      'f0a00000-0000-4000-8000-000000000002'::uuid
      and template_key = 'fixed_duration_exceptional_leave_by_event'
      and status = 'published'
  ) then
    raise exception 'RAG-10.7 : gabarit RAG-10.6b absent';
  end if;
end;
$$;

-- 1. Révisions, rejets, filiation et concurrence
-- -------------------------------------------------------------------------

do $$
begin
  if exists (
    select 1 from internal.rag_rule_sets where status = 'rejected'
  ) then
    raise exception
      'RAG-10.7 : jeu rejected antérieur sans identité de rejet';
  end if;
  if exists (
    select 1
    from internal.rag_rule_sets
    where status in ('proposed', 'needs_attention', 'approved')
    group by institution_id, document_id, rule_key
    having pg_catalog.count(*) > 1
  ) then
    raise exception
      'RAG-10.7 : plusieurs brouillons ouverts pour la même règle';
  end if;
end;
$$;

alter table internal.rag_rule_sets
  add column revision_number bigint not null default 1,
  add column parent_rule_set_id uuid,
  add column replaces_rule_set_id uuid,
  add column rejection_reason_code text,
  add column rejection_note text,
  add column rejected_by uuid,
  add column rejected_at timestamptz;

alter table internal.rag_rule_sets
  drop constraint rag_rule_sets_document_key_unique,
  drop constraint rag_rule_sets_creation_origin_check,
  drop constraint rag_rule_sets_creator_origin_check,
  drop constraint rag_rule_sets_state_bundle_check;

alter table internal.rag_rule_sets
  add constraint rag_rule_sets_revision_positive_check
    check (revision_number > 0),
  add constraint rag_rule_sets_creation_origin_check
    check (
      creation_origin in (
        'manual_migration',
        'automatic_extraction',
        'reused_package',
        'admin_revision'
      )
    ),
  add constraint rag_rule_sets_creator_origin_check
    check (
      (
        creation_origin in ('manual_migration', 'admin_revision')
        and created_by is not null
      )
      or (
        creation_origin in ('automatic_extraction', 'reused_package')
        and created_by is null
      )
    ),
  add constraint rag_rule_sets_rejection_reason_check
    check (
      rejection_reason_code is null
      or rejection_reason_code in (
        'incorrect_values',
        'incorrect_or_insufficient_sources',
        'not_applicable_to_institution',
        'wrong_template',
        'other'
      )
    ),
  add constraint rag_rule_sets_rejection_note_check
    check (
      (
        rejection_reason_code = 'other'
        and pg_catalog.char_length(pg_catalog.btrim(rejection_note))
          between 1 and 500
      )
      or (
        rejection_reason_code is distinct from 'other'
        and rejection_note is null
      )
    ),
  add constraint rag_rule_sets_state_bundle_check
    check (
      (
        status in ('proposed', 'needs_attention')
        and approved_by is null and approved_at is null
        and validated_by is null and validated_at is null
        and invalidated_at is null and invalidation_reason is null
        and rejected_by is null and rejected_at is null
        and rejection_reason_code is null and rejection_note is null
      )
      or (
        status = 'approved'
        and approved_by is not null and approved_at is not null
        and validated_by is null and validated_at is null
        and invalidated_at is null and invalidation_reason is null
        and rejected_by is null and rejected_at is null
        and rejection_reason_code is null and rejection_note is null
      )
      or (
        status = 'validated'
        and approved_by is not null and approved_at is not null
        and validated_by is not null and validated_at is not null
        and invalidated_at is null and invalidation_reason is null
        and rejected_by is null and rejected_at is null
        and rejection_reason_code is null and rejection_note is null
      )
      or (
        status = 'rejected'
        and approved_by is null and approved_at is null
        and validated_by is null and validated_at is null
        and invalidated_at is null and invalidation_reason is null
        and rejected_by is not null and rejected_at is not null
        and rejection_reason_code is not null
      )
      or (
        status = 'invalidated'
        and approved_by is null and approved_at is null
        and validated_by is null and validated_at is null
        and invalidated_at is not null and invalidation_reason is not null
        and rejected_by is null and rejected_at is null
        and rejection_reason_code is null and rejection_note is null
      )
    ),
  add constraint rag_rule_sets_parent_same_scope_fk
    foreign key (
      parent_rule_set_id,
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
    on update cascade on delete cascade,
  add constraint rag_rule_sets_replaces_same_scope_fk
    foreign key (
      replaces_rule_set_id,
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
    on update cascade on delete cascade,
  add constraint rag_rule_sets_rejector_institution_fk
    foreign key (rejected_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  add constraint rag_rule_sets_revision_links_check
    check (
      (creation_origin = 'admin_revision'
       and parent_rule_set_id is not null
       and replaces_rule_set_id is not null)
      or
      (creation_origin <> 'admin_revision'
       and parent_rule_set_id is null
       and replaces_rule_set_id is null)
    );

create unique index rag_rule_sets_open_document_key_unique
  on internal.rag_rule_sets (institution_id, document_id, rule_key)
  where status in ('proposed', 'needs_attention', 'approved');

create unique index rag_rule_sets_open_parent_unique
  on internal.rag_rule_sets (parent_rule_set_id)
  where parent_rule_set_id is not null
    and status in ('proposed', 'needs_attention', 'approved');

create index rag_rule_sets_parent_idx
  on internal.rag_rule_sets (institution_id, parent_rule_set_id);

-- -------------------------------------------------------------------------
-- 2. Empreinte des sources et signatures catégorielles contrôlées
-- -------------------------------------------------------------------------

alter table internal.rag_rule_sources
  add column passage_content_sha256 text;

update internal.rag_rule_sources src
set passage_content_sha256 = p.content_sha256
from internal.rag_passages p
where p.passage_id = src.passage_id
  and p.document_id = src.document_id
  and p.institution_id = src.institution_id;

do $$
begin
  if exists (
    select 1 from internal.rag_rule_sources
    where passage_content_sha256 is null
  ) then
    raise exception 'RAG-10.7 : source sans empreinte de passage';
  end if;
end;
$$;

alter table internal.rag_rule_sources
  alter column passage_content_sha256 set not null,
  add constraint rag_rule_sources_sha256_check
    check (passage_content_sha256 ~ '^[0-9a-f]{64}$');

create table internal.rag_rule_template_source_signatures (
  template_version_id uuid not null,
  signature_key text not null,
  match_kind text not null,
  fact_key text,
  category_value text,
  required_any_terms text[] not null,
  forbidden_terms text[] not null default array[]::text[],
  created_at timestamptz not null default pg_catalog.now(),

  constraint rag_rule_template_source_signatures_pkey
    primary key (template_version_id, signature_key),
  constraint rag_rule_template_source_signatures_version_fk
    foreign key (template_version_id)
    references internal.rag_rule_template_versions (template_version_id)
    on update cascade on delete cascade,
  constraint rag_rule_template_source_signatures_category_fk
    foreign key (template_version_id, fact_key, category_value)
    references internal.rag_rule_template_fact_values (
      template_version_id, fact_key, value_key
    )
    on update cascade on delete cascade,
  constraint rag_rule_template_source_signatures_kind_check
    check (match_kind in ('category_value', 'default_rule')),
  constraint rag_rule_template_source_signatures_bundle_check
    check (
      (match_kind = 'category_value'
       and fact_key is not null and category_value is not null)
      or
      (match_kind = 'default_rule'
       and fact_key is null and category_value is null)
    ),
  constraint rag_rule_template_source_signatures_terms_check
    check (
      pg_catalog.cardinality(required_any_terms) between 1 and 50
      and pg_catalog.cardinality(forbidden_terms) <= 50
    )
);

insert into internal.rag_rule_template_source_signatures (
  template_version_id, signature_key, match_kind, fact_key, category_value,
  required_any_terms, forbidden_terms
)
values
  (
    'f0a00000-0000-4000-8000-000000000002', 'marriage',
    'category_value', 'leave_reason', 'marriage',
    array['mariage', 'partenariat'], array[]::text[]
  ),
  (
    'f0a00000-0000-4000-8000-000000000002', 'death_first_degree',
    'category_value', 'leave_reason', 'death_first_degree',
    array['père', 'mere', 'mère', 'conjoint', 'époux', 'epoux', 'épouse',
          'epouse', 'enfant', 'fils', 'fille'],
    array['beau-père', 'beau-pere', 'belle-mère', 'belle-mere',
          'grand-père', 'grand-pere', 'grand-mère', 'grand-mere',
          'petit-fils', 'petite-fille']
  ),
  (
    'f0a00000-0000-4000-8000-000000000002', 'death_second_degree',
    'category_value', 'leave_reason', 'death_second_degree',
    array['frère', 'frere', 'soeur', 'sœur', 'grand-père', 'grand-pere',
          'grand-mère', 'grand-mere', 'beau-frère', 'beau-frere',
          'belle-soeur', 'belle-sœur', 'beau-père', 'beau-pere',
          'belle-mère', 'belle-mere', 'petit-fils', 'petite-fille'],
    array[]::text[]
  ),
  (
    'f0a00000-0000-4000-8000-000000000002', 'moving_default',
    'default_rule', null, null,
    array['déménagement', 'demenagement'], array[]::text[]
  );

-- -------------------------------------------------------------------------
-- 3. Audit métier et reçus d'idempotence
-- -------------------------------------------------------------------------

create table internal.rag_rule_audit_events (
  audit_event_id bigserial primary key,
  institution_id text not null,
  rule_set_id uuid,
  document_id uuid,
  template_key text,
  template_version_id uuid,
  actor_user_uuid uuid,
  event_type text not null,
  old_status text,
  new_status text,
  reason_code text,
  change_summary jsonb not null default '{}'::jsonb,
  operation_id uuid,
  created_at timestamptz not null default pg_catalog.now(),

  constraint rag_rule_audit_events_type_check
    check (event_type ~ '^[a-z][a-z0-9_]{2,99}$'),
  constraint rag_rule_audit_events_summary_check
    check (pg_catalog.jsonb_typeof(change_summary) = 'object')
);

create index rag_rule_audit_events_institution_created_idx
  on internal.rag_rule_audit_events (
    institution_id, created_at desc, audit_event_id desc
  );
create index rag_rule_audit_events_rule_created_idx
  on internal.rag_rule_audit_events (
    institution_id, rule_set_id, created_at desc
  );
create index rag_rule_audit_events_type_created_idx
  on internal.rag_rule_audit_events (
    institution_id, event_type, created_at desc
  );

create table internal.rag_rule_operation_receipts (
  institution_id text not null,
  operation_id uuid not null,
  action text not null,
  request_payload jsonb not null,
  result jsonb not null,
  created_at timestamptz not null default pg_catalog.now(),
  constraint rag_rule_operation_receipts_pkey
    primary key (institution_id, operation_id),
  constraint rag_rule_operation_receipts_action_check
    check (action in ('save', 'confirm', 'reject')),
  constraint rag_rule_operation_receipts_json_check
    check (
      pg_catalog.jsonb_typeof(request_payload) = 'object'
      and pg_catalog.jsonb_typeof(result) = 'object'
    )
);

alter table internal.rag_rule_template_source_signatures
  enable row level security;
alter table internal.rag_rule_template_source_signatures
  force row level security;
alter table internal.rag_rule_audit_events enable row level security;
alter table internal.rag_rule_audit_events force row level security;
alter table internal.rag_rule_operation_receipts enable row level security;
alter table internal.rag_rule_operation_receipts force row level security;

revoke all on table internal.rag_rule_template_source_signatures
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_audit_events
  from public, anon, authenticated, service_role;
revoke all on sequence internal.rag_rule_audit_events_audit_event_id_seq
  from public, anon, authenticated, service_role;
revoke all on table internal.rag_rule_operation_receipts
  from public, anon, authenticated, service_role;

-- -------------------------------------------------------------------------
-- 4. Contrôle structurel autoritatif
-- -------------------------------------------------------------------------

create or replace function internal.inspect_rag_rule_set_integrity(
  p_rule_set_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_set internal.rag_rule_sets%rowtype;
  v_document_status text;
  v_template_status text;
  v_issues jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_rule record;
  v_value_text text;
  v_has_signature boolean;
  v_has_grounded_source boolean;
begin
  select s, d.status, tv.status
  into v_set, v_document_status, v_template_status
  from internal.rag_rule_sets s
  join internal.rag_documents d
    on d.document_id = s.document_id
   and d.institution_id = s.institution_id
  join internal.rag_rule_template_versions tv
    on tv.template_version_id = s.template_version_id
  where s.rule_set_id = p_rule_set_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'valid', false,
      'blocking_issues', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('code', 'rule_set_not_found')
      ),
      'warnings', v_warnings,
      'checked_revision_number', null
    );
  end if;

  if v_document_status not in ('ready', 'active') then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'document_not_eligible')
    );
  end if;
  if v_template_status not in ('published', 'retired') then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'template_not_executable')
    );
  end if;
  if not exists (
    select 1
    from internal.rag_rule_runtime_registry rr
    join internal.rag_rule_template_versions tv
      on tv.template_version_id = v_set.template_version_id
    where (rr.key_type, rr.runtime_key) in (
      ('intent_detector', tv.intent_detector_key),
      ('renderer', tv.renderer_key),
      ('aggregation_strategy', tv.aggregation_strategy)
    )
    group by tv.template_version_id
    having pg_catalog.count(*) = 3
  ) or exists (
    select 1
    from internal.rag_rule_template_facts f
    where f.template_version_id = v_set.template_version_id
      and not exists (
        select 1 from internal.rag_rule_runtime_registry rr
        where rr.key_type = 'fact_extractor'
          and rr.runtime_key = f.extractor_key
      )
  ) then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'runtime_registry_mismatch')
    );
  end if;

  if (select pg_catalog.count(*) from internal.rag_rules r
      where r.rule_set_id = p_rule_set_id) = 0
     or (select pg_catalog.count(*) from internal.rag_rules r
         where r.rule_set_id = p_rule_set_id and r.is_default) <> 1
  then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'invalid_default_rule_count')
    );
  end if;

  for v_rule in
    select r.*
    from internal.rag_rules r
    where r.rule_set_id = p_rule_set_id
    order by r.display_order, r.rule_id
  loop
    if (v_rule.is_default and exists (
      select 1 from internal.rag_rule_condition_groups g
      where g.rule_id = v_rule.rule_id
    )) or (not v_rule.is_default and not exists (
      select 1 from internal.rag_rule_condition_groups g
      where g.rule_id = v_rule.rule_id
    )) or exists (
      select 1
      from internal.rag_rule_condition_groups g
      where g.rule_id = v_rule.rule_id
        and not exists (
          select 1 from internal.rag_rule_conditions c
          where c.condition_group_id = g.condition_group_id
        )
    ) then
      v_issues := v_issues || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'code', 'invalid_rule_structure', 'rule_id', v_rule.rule_id
        )
      );
    end if;

    if not exists (
      select 1 from internal.rag_rule_sources src
      where src.rule_id = v_rule.rule_id
        and src.rule_set_id = p_rule_set_id
    ) then
      v_issues := v_issues || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'code', 'missing_rule_sources', 'rule_id', v_rule.rule_id
        )
      );
      continue;
    end if;

    if exists (
      select 1
      from internal.rag_rule_sources src
      join internal.rag_passages p
        on p.passage_id = src.passage_id
       and p.document_id = src.document_id
       and p.institution_id = src.institution_id
      where src.rule_id = v_rule.rule_id
        and src.rule_set_id = p_rule_set_id
        and src.passage_content_sha256 <> p.content_sha256
    ) then
      v_issues := v_issues || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'code', 'source_changed', 'rule_id', v_rule.rule_id
        )
      );
    end if;

    v_value_text := pg_catalog.regexp_replace(
      v_rule.outcome_value::text, '\.?0+$', ''
    );
    if v_value_text = '' then v_value_text := '0'; end if;

    select exists (
      select 1
      from internal.rag_rule_template_source_signatures sig
      where sig.template_version_id = v_set.template_version_id
        and (
          (sig.match_kind = 'default_rule' and v_rule.is_default)
          or (
            sig.match_kind = 'category_value'
            and exists (
              select 1
              from internal.rag_rule_conditions c
              where c.rule_id = v_rule.rule_id
                and c.fact_key = sig.fact_key
                and c.category_value = sig.category_value
            )
          )
        )
    ) into v_has_signature;

    select exists (
      select 1
      from internal.rag_rule_sources src
      join internal.rag_passages p
        on p.passage_id = src.passage_id
       and p.document_id = src.document_id
       and p.institution_id = src.institution_id
      where src.rule_id = v_rule.rule_id
        and src.rule_set_id = p_rule_set_id
        and p.content ~ (
          '(^|[^0-9])' || v_value_text || '([^0-9]|$)'
        )
        and (
          v_set.result_unit <> 'days'
          or pg_catalog.lower(p.content) ~ '(^|[^[:alpha:]])jours?([^[:alpha:]]|$)'
        )
        and (
          not v_has_signature
          or exists (
            select 1
            from internal.rag_rule_template_source_signatures sig
            where sig.template_version_id = v_set.template_version_id
              and (
                (sig.match_kind = 'default_rule' and v_rule.is_default)
                or (
                  sig.match_kind = 'category_value'
                  and exists (
                    select 1
                    from internal.rag_rule_conditions c
                    where c.rule_id = v_rule.rule_id
                      and c.fact_key = sig.fact_key
                      and c.category_value = sig.category_value
                  )
                )
              )
              and exists (
                select 1 from pg_catalog.unnest(sig.required_any_terms) term
                where pg_catalog.strpos(
                  pg_catalog.lower(p.content), pg_catalog.lower(term)
                ) > 0
              )
              and not exists (
                select 1 from pg_catalog.unnest(sig.forbidden_terms) term
                where pg_catalog.strpos(
                  pg_catalog.lower(p.content), pg_catalog.lower(term)
                ) > 0
              )
          )
        )
    ) into v_has_grounded_source;

    if not v_has_grounded_source then
      v_issues := v_issues || pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object(
          'code', case when v_has_signature
            then 'categorical_source_mismatch'
            else 'value_or_unit_not_in_source'
          end,
          'rule_id', v_rule.rule_id
        )
      );
    end if;
  end loop;

  if exists (
    select 1
    from internal.rag_rule_template_fact_constraints fc
    join internal.rag_rule_conditions left_c
      on left_c.template_version_id = fc.template_version_id
     and left_c.fact_key = fc.left_fact_key
    join internal.rag_rule_conditions right_c
      on right_c.condition_group_id = left_c.condition_group_id
     and right_c.fact_key = fc.right_fact_key
    where fc.template_version_id = v_set.template_version_id
      and left_c.rule_set_id = p_rule_set_id
      and left_c.number_value is not null
      and right_c.number_value is not null
      and case fc.comparator
        when '<=' then left_c.number_value > right_c.number_value
        when '<' then left_c.number_value >= right_c.number_value
        when '>=' then left_c.number_value < right_c.number_value
        when '>' then left_c.number_value <= right_c.number_value
        when '=' then left_c.number_value <> right_c.number_value
        when '!=' then left_c.number_value = right_c.number_value
      end
  ) then
    v_issues := v_issues || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('code', 'template_fact_constraint_failed')
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'valid', pg_catalog.jsonb_array_length(v_issues) = 0,
    'blocking_issues', v_issues,
    'warnings', v_warnings,
    'checked_revision_number', v_set.revision_number
  );
end;
$$;

revoke all on function internal.inspect_rag_rule_set_integrity(uuid)
  from public, anon, authenticated, service_role;

-- -------------------------------------------------------------------------
-- 5. Lectures administratives fermées
-- -------------------------------------------------------------------------

create or replace function server_api.list_rag_rule_sets_admin(
  p_auth_uid uuid,
  p_document_id uuid default null,
  p_template_key text default null,
  p_statuses text[] default null,
  p_action_required boolean default null,
  p_cursor text default null,
  p_limit integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_institution_id text;
  v_cursor_updated_at timestamptz;
  v_cursor_id uuid;
  v_rows jsonb;
  v_has_more boolean;
  v_next_cursor text;
begin
  select r.authorized, r.institution_id
  into v_authorized, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;
  if p_limit not between 1 and 100 then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'invalid_limit'
    );
  end if;
  if p_statuses is not null and exists (
    select 1 from pg_catalog.unnest(p_statuses) status
    where status not in (
      'proposed', 'needs_attention', 'approved',
      'validated', 'rejected', 'invalidated'
    )
  ) then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'invalid_statuses'
    );
  end if;
  if p_cursor is not null then
    begin
      v_cursor_updated_at := pg_catalog.split_part(
        pg_catalog.convert_from(pg_catalog.decode(p_cursor, 'base64'), 'UTF8'),
        '|', 1
      )::timestamptz;
      v_cursor_id := pg_catalog.split_part(
        pg_catalog.convert_from(pg_catalog.decode(p_cursor, 'base64'), 'UTF8'),
        '|', 2
      )::uuid;
    exception when others then
      return pg_catalog.jsonb_build_object(
        'success', false, 'status_code', 'invalid_cursor'
      );
    end;
  end if;

  with filtered as (
    select
      s.rule_set_id, s.document_id, s.rule_key as template_key,
      t.name_fr as template_name, s.status, s.revision_number,
      s.creation_origin, s.updated_at,
      d.title as document_title, d.version_label, d.status as document_status,
      case
        when s.status = 'proposed' then 'confirm_or_reject'
        when s.status = 'needs_attention' then 'correct_or_reject'
        when s.status = 'approved' then 'activate_document'
        when s.status = 'validated' then 'create_revision'
        else null
      end as action_required
    from internal.rag_rule_sets s
    join internal.rag_documents d
      on d.document_id = s.document_id
     and d.institution_id = s.institution_id
    join internal.rag_rule_templates t on t.template_key = s.rule_key
    where s.institution_id = v_institution_id
      and (p_document_id is null or s.document_id = p_document_id)
      and (p_template_key is null or s.rule_key = p_template_key)
      and (p_statuses is null or s.status = any(p_statuses))
      and (
        p_action_required is null
        or p_action_required = (s.status in (
          'proposed', 'needs_attention', 'approved', 'validated'
        ))
      )
      and (
        v_cursor_updated_at is null
        or (s.updated_at, s.rule_set_id) <
          (v_cursor_updated_at, v_cursor_id)
      )
    order by s.updated_at desc, s.rule_set_id desc
    limit p_limit + 1
  ), page as (
    select * from filtered
    order by updated_at desc, rule_set_id desc
    limit p_limit
  )
  select
    coalesce(pg_catalog.jsonb_agg(
      pg_catalog.to_jsonb(page) order by updated_at desc, rule_set_id desc
    ), '[]'::jsonb),
    (select pg_catalog.count(*) > p_limit from filtered),
    case when (select pg_catalog.count(*) > p_limit from filtered) then
      (select pg_catalog.encode(pg_catalog.convert_to(
        updated_at::text || '|' || rule_set_id::text, 'UTF8'
      ), 'base64') from page order by updated_at, rule_set_id limit 1)
    else null end
  into v_rows, v_has_more, v_next_cursor
  from page;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'listed',
    'rule_sets', v_rows,
    'has_more', coalesce(v_has_more, false),
    'next_cursor', v_next_cursor
  );
end;
$$;

create or replace function server_api.get_rag_rule_set_admin(
  p_auth_uid uuid,
  p_rule_set_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_institution_id text;
  v_set record;
  v_rule_set jsonb;
  v_integrity jsonb;
  v_actions jsonb;
begin
  select r.authorized, r.institution_id
  into v_authorized, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;

  select s.*, d.title as document_title, d.version_label,
    d.status as document_status, t.name_fr as template_name,
    tv.version_number, tv.status as template_status
  into v_set
  from internal.rag_rule_sets s
  join internal.rag_documents d
    on d.document_id = s.document_id
   and d.institution_id = s.institution_id
  join internal.rag_rule_template_versions tv
    on tv.template_version_id = s.template_version_id
  join internal.rag_rule_templates t on t.template_key = s.rule_key
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;

  select pg_catalog.jsonb_build_object(
    'rule_set_id', s.rule_set_id,
    'rule_key', s.rule_key,
    'template_version_id', s.template_version_id,
    'aggregation_strategy', s.aggregation_strategy,
    'result_unit', s.result_unit,
    'document_id', s.document_id,
    'status', s.status,
    'documentStatus', d.status,
    'document_status', d.status,
    'revision_number', s.revision_number,
    'creation_origin', s.creation_origin,
    'parent_rule_set_id', s.parent_rule_set_id,
    'replaces_rule_set_id', s.replaces_rule_set_id,
    'document_title', d.title,
    'document_version_label', d.version_label,
    'template_name', t.name_fr,
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
      'facts', coalesce((
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'fact_key', f.fact_key,
            'value_type', f.value_type,
            'extractor_key', f.extractor_key,
            'label_fr', f.label_fr,
            'clarification_label_fr', f.clarification_label_fr,
            'minimum_number', f.minimum_number,
            'maximum_number', f.maximum_number,
            'integer_only', f.integer_only,
            'allowed_operators', coalesce((
              select pg_catalog.jsonb_agg(o.comparator order by o.comparator)
              from internal.rag_rule_template_fact_operators o
              where o.template_version_id = f.template_version_id
                and o.fact_key = f.fact_key
            ), '[]'::jsonb),
            'category_values', coalesce((
              select pg_catalog.jsonb_agg(
                pg_catalog.jsonb_build_object(
                  'value_key', fv.value_key, 'label_fr', fv.label_fr
                ) order by fv.display_order, fv.value_key
              )
              from internal.rag_rule_template_fact_values fv
              where fv.template_version_id = f.template_version_id
                and fv.fact_key = f.fact_key
            ), '[]'::jsonb)
          ) order by f.display_order, f.fact_key
        )
        from internal.rag_rule_template_facts f
        where f.template_version_id = tv.template_version_id
      ), '[]'::jsonb),
      'fact_constraints', coalesce((
        select pg_catalog.jsonb_agg(
          pg_catalog.jsonb_build_object(
            'constraint_key', fc.constraint_key,
            'left_fact_key', fc.left_fact_key,
            'comparator', fc.comparator,
            'right_fact_key', fc.right_fact_key,
            'error_code', fc.error_code
          ) order by fc.constraint_key
        )
        from internal.rag_rule_template_fact_constraints fc
        where fc.template_version_id = tv.template_version_id
      ), '[]'::jsonb)
    ),
    'rules', coalesce((
      select pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'rule_id', rr.rule_id,
          'outcome_value', rr.outcome_value,
          'is_default', rr.is_default,
          'display_order', rr.display_order,
          'label', rr.label,
          'condition_groups', coalesce((
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'display_order', g.display_order,
                'conditions', coalesce((
                  select pg_catalog.jsonb_agg(
                    pg_catalog.jsonb_build_object(
                      'fact_key', c.fact_key,
                      'fact_label_fr', f.label_fr,
                      'comparator', c.comparator,
                      'fact_value_type', c.fact_value_type,
                      'number_value', c.number_value,
                      'category_value', c.category_value,
                      'category_label_fr', fv.label_fr
                    ) order by c.fact_key, c.condition_id
                  )
                  from internal.rag_rule_conditions c
                  join internal.rag_rule_template_facts f
                    on f.template_version_id = c.template_version_id
                   and f.fact_key = c.fact_key
                  left join internal.rag_rule_template_fact_values fv
                    on fv.template_version_id = c.template_version_id
                   and fv.fact_key = c.fact_key
                   and fv.value_key = c.category_value
                  where c.condition_group_id = g.condition_group_id
                ), '[]'::jsonb)
              ) order by g.display_order, g.condition_group_id
            )
            from internal.rag_rule_condition_groups g
            where g.rule_id = rr.rule_id
          ), '[]'::jsonb),
          'source_passage_ids', coalesce((
            select pg_catalog.jsonb_agg(src.passage_id order by src.passage_id)
            from internal.rag_rule_sources src
            where src.rule_id = rr.rule_id
          ), '[]'::jsonb),
          'sources', coalesce((
            select pg_catalog.jsonb_agg(
              pg_catalog.jsonb_build_object(
                'passage_id', p.passage_id,
                'content', p.content,
                'source_reference', p.source_reference,
                'page_start', p.page_start,
                'page_end', p.page_end,
                'section_title', p.section_title,
                'article_reference', p.article_reference,
                'content_sha256', p.content_sha256,
                'associated_content_sha256', src.passage_content_sha256
              ) order by p.page_start nulls last, p.chunk_index
            )
            from internal.rag_rule_sources src
            join internal.rag_passages p
              on p.passage_id = src.passage_id
             and p.document_id = src.document_id
             and p.institution_id = src.institution_id
            where src.rule_id = rr.rule_id
          ), '[]'::jsonb)
        ) order by rr.display_order, rr.rule_id
      )
      from internal.rag_rules rr
      where rr.rule_set_id = s.rule_set_id
    ), '[]'::jsonb)
  ) into v_rule_set
  from internal.rag_rule_sets s
  join internal.rag_documents d
    on d.document_id = s.document_id
   and d.institution_id = s.institution_id
  join internal.rag_rule_template_versions tv
    on tv.template_version_id = s.template_version_id
  join internal.rag_rule_templates t on t.template_key = s.rule_key
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id;

  v_integrity := internal.inspect_rag_rule_set_integrity(p_rule_set_id);
  v_actions := case v_set.status
    when 'proposed' then '["save","confirm","reject","simulate"]'::jsonb
    when 'needs_attention' then '["save","reject","simulate"]'::jsonb
    when 'approved' then '["save","reject","simulate"]'::jsonb
    when 'validated' then '["create_revision","simulate"]'::jsonb
    else '["simulate"]'::jsonb
  end;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'found',
    'persisted_status', v_set.status,
    'revision_number', v_set.revision_number,
    'rule_set', v_rule_set,
    'integrity', v_integrity,
    'allowed_actions', v_actions
  );
end;
$$;

create or replace function server_api.get_rag_rule_audit_admin(
  p_auth_uid uuid,
  p_rule_set_id uuid default null,
  p_cursor text default null,
  p_limit integer default 25
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_institution_id text;
  v_cursor_id bigint;
  v_events jsonb;
  v_has_more boolean;
  v_next_cursor text;
begin
  select r.authorized, r.institution_id
  into v_authorized, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;
  if p_limit not between 1 and 100 then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'invalid_limit'
    );
  end if;
  if p_rule_set_id is not null and not exists (
    select 1 from internal.rag_rule_sets s
    where s.rule_set_id = p_rule_set_id
      and s.institution_id = v_institution_id
  ) and not exists (
    select 1 from internal.rag_rule_audit_events e
    where e.rule_set_id = p_rule_set_id
      and e.institution_id = v_institution_id
  ) then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;
  if p_cursor is not null then
    begin v_cursor_id := p_cursor::bigint;
    exception when others then
      return pg_catalog.jsonb_build_object(
        'success', false, 'status_code', 'invalid_cursor'
      );
    end;
  end if;

  with filtered as (
    select e.audit_event_id, e.rule_set_id, e.document_id, e.template_key,
      e.event_type, e.old_status, e.new_status, e.reason_code,
      e.change_summary, e.operation_id, e.created_at,
      u.display_name as actor_display_name
    from internal.rag_rule_audit_events e
    left join internal.users u
      on u.user_uuid = e.actor_user_uuid
     and u.institution_id = e.institution_id
    where e.institution_id = v_institution_id
      and (p_rule_set_id is null or e.rule_set_id = p_rule_set_id)
      and (v_cursor_id is null or e.audit_event_id < v_cursor_id)
    order by e.audit_event_id desc
    limit p_limit + 1
  ), page as (
    select * from filtered order by audit_event_id desc limit p_limit
  )
  select
    coalesce(pg_catalog.jsonb_agg(
      pg_catalog.to_jsonb(page) order by audit_event_id desc
    ), '[]'::jsonb),
    (select pg_catalog.count(*) > p_limit from filtered),
    case when (select pg_catalog.count(*) > p_limit from filtered)
      then (select audit_event_id::text from page
            order by audit_event_id limit 1)
      else null end
  into v_events, v_has_more, v_next_cursor
  from page;

  return pg_catalog.jsonb_build_object(
    'success', true, 'status_code', 'listed',
    'events', v_events, 'has_more', coalesce(v_has_more, false),
    'next_cursor', v_next_cursor
  );
end;
$$;

-- -------------------------------------------------------------------------
-- 6. Mutations transactionnelles
-- -------------------------------------------------------------------------

create or replace function internal.check_rag_rule_operation_receipt(
  p_institution_id text,
  p_operation_id uuid,
  p_action text,
  p_request_payload jsonb
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select case
    when r.operation_id is null then
      pg_catalog.jsonb_build_object('found', false)
    when r.action = p_action and r.request_payload = p_request_payload then
      pg_catalog.jsonb_build_object('found', true, 'result', r.result)
    else
      pg_catalog.jsonb_build_object('found', true, 'conflict', true)
  end
  from (select 1) one
  left join internal.rag_rule_operation_receipts r
    on r.institution_id = p_institution_id
   and r.operation_id = p_operation_id;
$$;

revoke all on function internal.check_rag_rule_operation_receipt(
  text, uuid, text, jsonb
) from public, anon, authenticated, service_role;

create or replace function server_api.create_rag_rule_revision(
  p_auth_uid uuid,
  p_rule_set_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_parent internal.rag_rule_sets%rowtype;
  v_revision_id uuid;
  v_existing_id uuid;
  v_rule record;
  v_group record;
  v_new_rule_id uuid;
  v_new_group_id uuid;
begin
  select r.authorized, r.user_uuid, r.institution_id
  into v_authorized, v_admin_user_uuid, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_admin_user_uuid is null or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;

  select s into v_parent
  from internal.rag_rule_sets s
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;
  if v_parent.status <> 'validated' then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'status_conflict'
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || v_parent.rule_key, 0
    )
  );
  select s into v_parent
  from internal.rag_rule_sets s
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id
  for update;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;
  if v_parent.status <> 'validated' then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'status_conflict'
    );
  end if;
  select s.rule_set_id into v_existing_id
  from internal.rag_rule_sets s
  where s.parent_rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id
    and s.status in ('proposed', 'needs_attention', 'approved')
  limit 1;
  if v_existing_id is not null then
    return pg_catalog.jsonb_build_object(
      'success', true, 'status_code', 'revision_already_open',
      'rule_set_id', v_existing_id
    );
  end if;

  insert into internal.rag_rule_sets (
    institution_id, document_id, rule_key, aggregation_strategy,
    result_unit, status, created_by, template_version_id, creation_origin,
    revision_number, parent_rule_set_id, replaces_rule_set_id
  ) values (
    v_parent.institution_id, v_parent.document_id, v_parent.rule_key,
    v_parent.aggregation_strategy, v_parent.result_unit, 'proposed',
    v_admin_user_uuid, v_parent.template_version_id, 'admin_revision',
    1, v_parent.rule_set_id, v_parent.rule_set_id
  ) returning rule_set_id into v_revision_id;

  for v_rule in
    select * from internal.rag_rules r
    where r.rule_set_id = p_rule_set_id
    order by r.display_order, r.rule_id
  loop
    v_new_rule_id := pg_catalog.gen_random_uuid();
    insert into internal.rag_rules (
      rule_id, rule_set_id, document_id, institution_id,
      template_version_id, outcome_value, is_default, display_order, label
    ) values (
      v_new_rule_id, v_revision_id, v_parent.document_id,
      v_parent.institution_id, v_parent.template_version_id,
      v_rule.outcome_value, v_rule.is_default,
      v_rule.display_order, v_rule.label
    );

    for v_group in
      select * from internal.rag_rule_condition_groups g
      where g.rule_id = v_rule.rule_id
      order by g.display_order, g.condition_group_id
    loop
      v_new_group_id := pg_catalog.gen_random_uuid();
      insert into internal.rag_rule_condition_groups (
        condition_group_id, rule_id, rule_set_id, document_id,
        institution_id, template_version_id, display_order
      ) values (
        v_new_group_id, v_new_rule_id, v_revision_id,
        v_parent.document_id, v_parent.institution_id,
        v_parent.template_version_id, v_group.display_order
      );
      insert into internal.rag_rule_conditions (
        condition_id, condition_group_id, rule_id, rule_set_id,
        document_id, institution_id, template_version_id,
        fact_key, comparator, threshold_value, fact_value_type,
        number_value, category_value
      )
      select pg_catalog.gen_random_uuid(), v_new_group_id, v_new_rule_id,
        v_revision_id, v_parent.document_id, v_parent.institution_id,
        v_parent.template_version_id, c.fact_key, c.comparator,
        c.threshold_value, c.fact_value_type, c.number_value, c.category_value
      from internal.rag_rule_conditions c
      where c.condition_group_id = v_group.condition_group_id;
    end loop;

    insert into internal.rag_rule_sources (
      rule_id, rule_set_id, passage_id, document_id, institution_id,
      template_version_id, passage_content_sha256
    )
    select v_new_rule_id, v_revision_id, src.passage_id,
      v_parent.document_id, v_parent.institution_id,
      v_parent.template_version_id, src.passage_content_sha256
    from internal.rag_rule_sources src
    where src.rule_id = v_rule.rule_id;
  end loop;

  insert into internal.rag_rule_audit_events (
    institution_id, rule_set_id, document_id, template_key,
    template_version_id, actor_user_uuid, event_type,
    old_status, new_status, change_summary
  ) values (
    v_institution_id, v_revision_id, v_parent.document_id,
    v_parent.rule_key, v_parent.template_version_id, v_admin_user_uuid,
    'rag_rule_revision_created', v_parent.status, 'proposed',
    pg_catalog.jsonb_build_object('parent_rule_set_id', p_rule_set_id)
  );

  return pg_catalog.jsonb_build_object(
    'success', true, 'status_code', 'revision_created',
    'rule_set_id', v_revision_id, 'revision_number', 1,
    'parent_rule_set_id', p_rule_set_id
  );
exception when unique_violation then
  select s.rule_set_id into v_existing_id
  from internal.rag_rule_sets s
  where s.parent_rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id
    and s.status in ('proposed', 'needs_attention', 'approved')
  limit 1;
  if v_existing_id is not null then
    return pg_catalog.jsonb_build_object(
      'success', true, 'status_code', 'revision_already_open',
      'rule_set_id', v_existing_id
    );
  end if;
  raise;
end;
$$;

create or replace function server_api.save_rag_rule_set_correction(
  p_auth_uid uuid,
  p_rule_set_id uuid,
  p_expected_revision_number bigint,
  p_operation_id uuid,
  p_rules jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_set internal.rag_rule_sets%rowtype;
  v_old_status text;
  v_request jsonb;
  v_receipt jsonb;
  v_result jsonb;
  v_integrity jsonb;
  v_final_status text;
  v_rule_item record;
  v_group_item record;
  v_condition_item record;
  v_source_item record;
  v_rule jsonb;
  v_group jsonb;
  v_condition jsonb;
  v_rule_id uuid;
  v_group_id uuid;
  v_source_count integer;
begin
  select r.authorized, r.user_uuid, r.institution_id
  into v_authorized, v_admin_user_uuid, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_admin_user_uuid is null or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;
  if p_rules is null
     or pg_catalog.jsonb_typeof(p_rules) <> 'array'
     or pg_catalog.jsonb_array_length(p_rules) not between 1 and 100
     or p_expected_revision_number is null
     or p_expected_revision_number < 1
     or p_operation_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'invalid_rule_structure'
    );
  end if;

  v_request := pg_catalog.jsonb_build_object(
    'rule_set_id', p_rule_set_id,
    'expected_revision_number', p_expected_revision_number,
    'rules', p_rules
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || p_operation_id::text, 0
    )
  );
  v_receipt := internal.check_rag_rule_operation_receipt(
    v_institution_id, p_operation_id, 'save', v_request
  );
  if (v_receipt->>'found')::boolean then
    if coalesce((v_receipt->>'conflict')::boolean, false) then
      return pg_catalog.jsonb_build_object(
        'success', false, 'status_code', 'idempotency_conflict'
      );
    end if;
    return v_receipt->'result';
  end if;

  select s into v_set
  from internal.rag_rule_sets s
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id
  for update;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;
  if v_set.status not in ('proposed', 'needs_attention', 'approved') then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', case when v_set.status = 'validated'
        then 'validated_rule_immutable' else 'status_conflict' end
    );
  end if;
  if v_set.revision_number <> p_expected_revision_number then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'revision_conflict',
      'current_revision_number', v_set.revision_number
    );
  end if;
  v_old_status := v_set.status;

  begin
    delete from internal.rag_rules r where r.rule_set_id = p_rule_set_id;

    for v_rule_item in
      select value, ordinality
      from pg_catalog.jsonb_array_elements(p_rules) with ordinality
    loop
      v_rule := v_rule_item.value;
      if pg_catalog.jsonb_typeof(v_rule) <> 'object'
         or pg_catalog.jsonb_typeof(v_rule->'condition_groups') <> 'array'
         or pg_catalog.jsonb_typeof(v_rule->'source_passage_ids') <> 'array'
         or pg_catalog.jsonb_array_length(v_rule->'source_passage_ids')
              not between 1 and 20
      then
        raise exception 'invalid_rule_structure';
      end if;
      v_rule_id := pg_catalog.gen_random_uuid();
      insert into internal.rag_rules (
        rule_id, rule_set_id, document_id, institution_id,
        template_version_id, outcome_value, is_default, display_order, label
      ) values (
        v_rule_id, p_rule_set_id, v_set.document_id, v_set.institution_id,
        v_set.template_version_id, (v_rule->>'outcome_value')::numeric,
        (v_rule->>'is_default')::boolean,
        (v_rule->>'display_order')::integer,
        pg_catalog.btrim(v_rule->>'label')
      );

      for v_group_item in
        select value, ordinality
        from pg_catalog.jsonb_array_elements(v_rule->'condition_groups')
          with ordinality
      loop
        v_group := v_group_item.value;
        if pg_catalog.jsonb_typeof(v_group) <> 'object'
           or pg_catalog.jsonb_typeof(v_group->'conditions') <> 'array'
           or pg_catalog.jsonb_array_length(v_group->'conditions')
                not between 1 and 20
        then raise exception 'invalid_condition_group'; end if;
        v_group_id := pg_catalog.gen_random_uuid();
        insert into internal.rag_rule_condition_groups (
          condition_group_id, rule_id, rule_set_id, document_id,
          institution_id, template_version_id, display_order
        ) values (
          v_group_id, v_rule_id, p_rule_set_id, v_set.document_id,
          v_set.institution_id, v_set.template_version_id,
          (v_group->>'display_order')::integer
        );

        for v_condition_item in
          select value, ordinality
          from pg_catalog.jsonb_array_elements(v_group->'conditions')
            with ordinality
        loop
          v_condition := v_condition_item.value;
          insert into internal.rag_rule_conditions (
            condition_id, condition_group_id, rule_id, rule_set_id,
            document_id, institution_id, template_version_id,
            fact_key, comparator, threshold_value, fact_value_type,
            number_value, category_value
          ) values (
            pg_catalog.gen_random_uuid(), v_group_id, v_rule_id,
            p_rule_set_id, v_set.document_id, v_set.institution_id,
            v_set.template_version_id, v_condition->>'fact_key',
            v_condition->>'comparator',
            case when v_condition->>'fact_value_type' = 'number'
              then (v_condition->>'number_value')::numeric else null end,
            v_condition->>'fact_value_type',
            case when v_condition->>'fact_value_type' = 'number'
              then (v_condition->>'number_value')::numeric else null end,
            case when v_condition->>'fact_value_type' = 'category'
              then v_condition->>'category_value' else null end
          );
        end loop;
      end loop;

      v_source_count := 0;
      for v_source_item in
        select value from pg_catalog.jsonb_array_elements_text(
          v_rule->'source_passage_ids'
        )
      loop
        insert into internal.rag_rule_sources (
          rule_id, rule_set_id, passage_id, document_id, institution_id,
          template_version_id, passage_content_sha256
        )
        select v_rule_id, p_rule_set_id, p.passage_id, p.document_id,
          p.institution_id, v_set.template_version_id, p.content_sha256
        from internal.rag_passages p
        where p.passage_id = v_source_item.value::uuid
          and p.document_id = v_set.document_id
          and p.institution_id = v_set.institution_id;
        get diagnostics v_source_count = row_count;
        if v_source_count <> 1 then
          raise exception 'invalid_source_passage';
        end if;
      end loop;
    end loop;

    if (select pg_catalog.count(*) from internal.rag_rules r
        where r.rule_set_id = p_rule_set_id and r.is_default) <> 1 then
      raise exception 'invalid_default_rule_count';
    end if;
  exception when others then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'invalid_rule_structure'
    );
  end;

  v_integrity := internal.inspect_rag_rule_set_integrity(p_rule_set_id);
  v_final_status := case when (v_integrity->>'valid')::boolean
    then 'proposed' else 'needs_attention' end;

  update internal.rag_rule_sets s
  set status = v_final_status,
      approved_by = null, approved_at = null,
      validated_by = null, validated_at = null,
      invalidated_at = null, invalidation_reason = null,
      rejected_by = null, rejected_at = null,
      rejection_reason_code = null, rejection_note = null,
      revision_number = revision_number + 1
  where s.rule_set_id = p_rule_set_id;

  v_result := pg_catalog.jsonb_build_object(
    'success', true, 'status_code', 'saved',
    'rule_set_id', p_rule_set_id,
    'status', v_final_status,
    'revision_number', v_set.revision_number + 1,
    'integrity', v_integrity
  );
  insert into internal.rag_rule_audit_events (
    institution_id, rule_set_id, document_id, template_key,
    template_version_id, actor_user_uuid, event_type,
    old_status, new_status, change_summary, operation_id
  ) values (
    v_institution_id, p_rule_set_id, v_set.document_id, v_set.rule_key,
    v_set.template_version_id, v_admin_user_uuid, 'rag_rule_corrected',
    v_old_status, v_final_status,
    pg_catalog.jsonb_build_object(
      'rule_count', pg_catalog.jsonb_array_length(p_rules),
      'approval_cancelled', v_old_status = 'approved'
    ), p_operation_id
  );
  insert into internal.rag_rule_operation_receipts (
    institution_id, operation_id, action, request_payload, result
  ) values (v_institution_id, p_operation_id, 'save', v_request, v_result);
  return v_result;
end;
$$;

create or replace function server_api.confirm_rag_rule_set(
  p_auth_uid uuid,
  p_rule_set_id uuid,
  p_expected_revision_number bigint,
  p_operation_id uuid,
  p_confirmation boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_set internal.rag_rule_sets%rowtype;
  v_document_status text;
  v_integrity jsonb;
  v_active_id uuid;
  v_target_status text;
  v_request jsonb;
  v_receipt jsonb;
  v_result jsonb;
  v_now timestamptz := pg_catalog.now();
begin
  select r.authorized, r.user_uuid, r.institution_id
  into v_authorized, v_admin_user_uuid, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_admin_user_uuid is null or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;
  if coalesce(p_confirmation, false) is not true then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'confirmation_required'
    );
  end if;
  if p_expected_revision_number is null
     or p_expected_revision_number < 1 or p_operation_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'invalid_request'
    );
  end if;
  v_request := pg_catalog.jsonb_build_object(
    'rule_set_id', p_rule_set_id,
    'expected_revision_number', p_expected_revision_number,
    'confirmation', true
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || p_operation_id::text, 0
    )
  );
  v_receipt := internal.check_rag_rule_operation_receipt(
    v_institution_id, p_operation_id, 'confirm', v_request
  );
  if (v_receipt->>'found')::boolean then
    if coalesce((v_receipt->>'conflict')::boolean, false) then
      return pg_catalog.jsonb_build_object(
        'success', false, 'status_code', 'idempotency_conflict'
      );
    end if;
    return v_receipt->'result';
  end if;

  select s into v_set
  from internal.rag_rule_sets s
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || v_set.rule_key, 0
    )
  );
  perform 1 from internal.rag_documents d
  where d.document_id = v_set.document_id
    and d.institution_id = v_institution_id for update;
  select s into v_set
  from internal.rag_rule_sets s
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;

  if v_set.status <> 'proposed' then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'status_conflict'
    );
  end if;
  if v_set.revision_number <> p_expected_revision_number then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'revision_conflict',
      'current_revision_number', v_set.revision_number
    );
  end if;
  select d.status into v_document_status
  from internal.rag_documents d
  where d.document_id = v_set.document_id
    and d.institution_id = v_institution_id;
  if v_document_status not in ('ready', 'active') then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'document_not_eligible'
    );
  end if;

  perform r.rule_id from internal.rag_rules r
    where r.rule_set_id = p_rule_set_id order by r.rule_id for update;
  perform g.condition_group_id from internal.rag_rule_condition_groups g
    where g.rule_set_id = p_rule_set_id
    order by g.condition_group_id for update;
  perform c.condition_id from internal.rag_rule_conditions c
    where c.rule_set_id = p_rule_set_id order by c.condition_id for update;
  perform src.passage_id from internal.rag_rule_sources src
    where src.rule_set_id = p_rule_set_id order by src.passage_id for update;

  v_integrity := internal.inspect_rag_rule_set_integrity(p_rule_set_id);
  if (v_integrity->>'valid')::boolean is not true then
    insert into internal.rag_rule_audit_events (
      institution_id, rule_set_id, document_id, template_key,
      template_version_id, actor_user_uuid, event_type,
      old_status, new_status, reason_code, change_summary, operation_id
    ) values (
      v_institution_id, p_rule_set_id, v_set.document_id, v_set.rule_key,
      v_set.template_version_id, v_admin_user_uuid,
      'rag_rule_precheck_failed', v_set.status, v_set.status,
      'integrity_check_failed',
      pg_catalog.jsonb_build_object(
        'blocking_issue_codes', coalesce((
          select pg_catalog.jsonb_agg(issue->>'code')
          from pg_catalog.jsonb_array_elements(
            v_integrity->'blocking_issues'
          ) issue
        ), '[]'::jsonb)
      ), p_operation_id
    );
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'integrity_check_failed',
      'blocking_issues', v_integrity->'blocking_issues'
    );
  end if;

  if v_document_status = 'ready' then
    v_target_status := 'approved';
  else
    select s.rule_set_id into v_active_id
    from internal.rag_rule_sets s
    where s.institution_id = v_institution_id
      and s.rule_key = v_set.rule_key
      and s.status = 'validated'
      and s.rule_set_id <> p_rule_set_id
    for update;
    if v_active_id is not null
       and v_set.replaces_rule_set_id is distinct from v_active_id then
      return pg_catalog.jsonb_build_object(
        'success', false, 'status_code', 'validated_rule_conflict'
      );
    end if;
    if v_active_id is not null then
      update internal.rag_rule_sets s
      set status = 'invalidated', approved_by = null, approved_at = null,
          validated_by = null, validated_at = null,
          invalidated_at = v_now, invalidation_reason = 'replaced_by_revision',
          rejected_by = null, rejected_at = null,
          rejection_reason_code = null, rejection_note = null,
          revision_number = revision_number + 1
      where s.rule_set_id = v_active_id;
      insert into internal.rag_rule_audit_events (
        institution_id, rule_set_id, document_id, template_key,
        template_version_id, actor_user_uuid, event_type,
        old_status, new_status, reason_code, change_summary, operation_id
      )
      select v_institution_id, s.rule_set_id, s.document_id, s.rule_key,
        s.template_version_id, v_admin_user_uuid, 'rag_rule_replaced',
        'validated', 'invalidated', 'replaced_by_revision',
        pg_catalog.jsonb_build_object('replacement_rule_set_id', p_rule_set_id),
        p_operation_id
      from internal.rag_rule_sets s where s.rule_set_id = v_active_id;
    end if;
    v_target_status := 'validated';
  end if;

  update internal.rag_rule_sets s
  set status = v_target_status,
      approved_by = v_admin_user_uuid, approved_at = v_now,
      validated_by = case when v_target_status = 'validated'
        then v_admin_user_uuid else null end,
      validated_at = case when v_target_status = 'validated'
        then v_now else null end,
      invalidated_at = null, invalidation_reason = null,
      rejected_by = null, rejected_at = null,
      rejection_reason_code = null, rejection_note = null,
      revision_number = revision_number + 1
  where s.rule_set_id = p_rule_set_id;

  insert into internal.rag_rule_audit_events (
    institution_id, rule_set_id, document_id, template_key,
    template_version_id, actor_user_uuid, event_type,
    old_status, new_status, change_summary, operation_id
  ) values (
    v_institution_id, p_rule_set_id, v_set.document_id, v_set.rule_key,
    v_set.template_version_id, v_admin_user_uuid,
    case when v_target_status = 'validated'
      then 'rag_rule_validated' else 'rag_rule_approved' end,
    v_set.status, v_target_status,
    pg_catalog.jsonb_build_object('document_status', v_document_status),
    p_operation_id
  );
  v_result := pg_catalog.jsonb_build_object(
    'success', true, 'status_code', v_target_status,
    'rule_set_id', p_rule_set_id,
    'revision_number', v_set.revision_number + 1,
    'replaced_rule_set_id', v_active_id
  );
  insert into internal.rag_rule_operation_receipts (
    institution_id, operation_id, action, request_payload, result
  ) values (v_institution_id, p_operation_id, 'confirm', v_request, v_result);
  return v_result;
end;
$$;

create or replace function server_api.reject_rag_rule_set(
  p_auth_uid uuid,
  p_rule_set_id uuid,
  p_expected_revision_number bigint,
  p_operation_id uuid,
  p_reason_code text,
  p_rejection_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_set internal.rag_rule_sets%rowtype;
  v_request jsonb;
  v_receipt jsonb;
  v_result jsonb;
  v_note text := nullif(pg_catalog.btrim(p_rejection_note), '');
begin
  select r.authorized, r.user_uuid, r.institution_id
  into v_authorized, v_admin_user_uuid, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_admin_user_uuid is null or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;
  if p_reason_code is null or p_reason_code not in (
    'incorrect_values', 'incorrect_or_insufficient_sources',
    'not_applicable_to_institution', 'wrong_template', 'other'
  ) or (p_reason_code = 'other' and (
    v_note is null or pg_catalog.char_length(v_note) > 500
  )) or (p_reason_code <> 'other' and p_rejection_note is not null)
     or p_expected_revision_number is null
     or p_expected_revision_number < 1 or p_operation_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'invalid_rejection_reason'
    );
  end if;
  v_request := pg_catalog.jsonb_build_object(
    'rule_set_id', p_rule_set_id,
    'expected_revision_number', p_expected_revision_number,
    'reason_code', p_reason_code, 'rejection_note', v_note
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || p_operation_id::text, 0
    )
  );
  v_receipt := internal.check_rag_rule_operation_receipt(
    v_institution_id, p_operation_id, 'reject', v_request
  );
  if (v_receipt->>'found')::boolean then
    if coalesce((v_receipt->>'conflict')::boolean, false) then
      return pg_catalog.jsonb_build_object(
        'success', false, 'status_code', 'idempotency_conflict'
      );
    end if;
    return v_receipt->'result';
  end if;

  select s into v_set
  from internal.rag_rule_sets s
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id for update;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;
  if v_set.status not in ('proposed', 'needs_attention', 'approved') then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'status_conflict'
    );
  end if;
  if v_set.revision_number <> p_expected_revision_number then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'revision_conflict',
      'current_revision_number', v_set.revision_number
    );
  end if;

  update internal.rag_rule_sets s
  set status = 'rejected',
      approved_by = null, approved_at = null,
      validated_by = null, validated_at = null,
      invalidated_at = null, invalidation_reason = null,
      rejected_by = v_admin_user_uuid, rejected_at = pg_catalog.now(),
      rejection_reason_code = p_reason_code, rejection_note = v_note,
      revision_number = revision_number + 1
  where s.rule_set_id = p_rule_set_id;
  insert into internal.rag_rule_audit_events (
    institution_id, rule_set_id, document_id, template_key,
    template_version_id, actor_user_uuid, event_type,
    old_status, new_status, reason_code, change_summary, operation_id
  ) values (
    v_institution_id, p_rule_set_id, v_set.document_id, v_set.rule_key,
    v_set.template_version_id, v_admin_user_uuid, 'rag_rule_rejected',
    v_set.status, 'rejected', p_reason_code,
    pg_catalog.jsonb_build_object('had_note', v_note is not null),
    p_operation_id
  );
  v_result := pg_catalog.jsonb_build_object(
    'success', true, 'status_code', 'rejected',
    'rule_set_id', p_rule_set_id,
    'revision_number', v_set.revision_number + 1
  );
  insert into internal.rag_rule_operation_receipts (
    institution_id, operation_id, action, request_payload, result
  ) values (v_institution_id, p_operation_id, 'reject', v_request, v_result);
  return v_result;
end;
$$;

create or replace function server_api.audit_rag_rule_simulation(
  p_auth_uid uuid,
  p_rule_set_id uuid,
  p_success boolean,
  p_result_code text,
  p_recognized_fact_count integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_set internal.rag_rule_sets%rowtype;
begin
  select r.authorized, r.user_uuid, r.institution_id
  into v_authorized, v_admin_user_uuid, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_admin_user_uuid is null or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;
  select s into v_set from internal.rag_rule_sets s
  where s.rule_set_id = p_rule_set_id
    and s.institution_id = v_institution_id;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'rule_set_not_found'
    );
  end if;
  insert into internal.rag_rule_audit_events (
    institution_id, rule_set_id, document_id, template_key,
    template_version_id, actor_user_uuid, event_type,
    old_status, new_status, reason_code, change_summary
  ) values (
    v_institution_id, p_rule_set_id, v_set.document_id, v_set.rule_key,
    v_set.template_version_id, v_admin_user_uuid, 'rag_rule_simulated',
    v_set.status, v_set.status, p_result_code,
    pg_catalog.jsonb_build_object(
      'success', p_success,
      'recognized_fact_count', greatest(
        0, least(coalesce(p_recognized_fact_count, 0), 50)
      )
    )
  );
  return pg_catalog.jsonb_build_object(
    'success', true, 'status_code', 'recorded'
  );
end;
$$;

-- -------------------------------------------------------------------------
-- 7. Défense en profondeur et activation documentaire
-- -------------------------------------------------------------------------

create or replace function internal.invalidate_rag_rule_set_from_child()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rule_set_id uuid;
  v_status text;
begin
  v_rule_set_id := case when tg_op = 'DELETE'
    then old.rule_set_id else new.rule_set_id end;
  select s.status into v_status
  from internal.rag_rule_sets s
  where s.rule_set_id = v_rule_set_id for update;
  if v_status = 'validated' then
    raise exception using errcode = 'P0001',
      message = 'validated_rule_immutable';
  end if;
  if v_status in ('rejected', 'invalidated') then
    raise exception using errcode = 'P0001', message = 'rule_set_immutable';
  end if;
  if v_status = 'approved' then
    update internal.rag_rule_sets s
    set status = 'needs_attention',
        approved_by = null, approved_at = null,
        validated_by = null, validated_at = null,
        invalidated_at = null, invalidation_reason = null,
        rejected_by = null, rejected_at = null,
        rejection_reason_code = null, rejection_note = null
    where s.rule_set_id = v_rule_set_id;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function internal.protect_rag_rule_source_passage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from internal.rag_rule_sources src
    join internal.rag_rule_sets s on s.rule_set_id = src.rule_set_id
    where src.passage_id = old.passage_id
      and s.status in ('approved', 'validated')
  ) then
    raise exception using errcode = 'P0001',
      message = 'protected_rule_source_immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists rag_passages_invalidate_numeric_rules
  on internal.rag_passages;
create trigger rag_passages_protect_rule_sources
before update of content, content_sha256, source_reference,
  page_start, page_end, section_title, article_reference
on internal.rag_passages
for each row execute function internal.protect_rag_rule_source_passage();

create or replace function internal.promote_approved_rag_rules_on_activation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_set record;
  v_integrity jsonb;
  v_now timestamptz := pg_catalog.now();
begin
  if new.status <> 'active' or old.status is not distinct from new.status then
    return new;
  end if;
  for v_set in
    select s.*
    from internal.rag_rule_sets s
    where s.document_id = new.document_id
      and s.institution_id = new.institution_id
      and s.status = 'approved'
    order by s.rule_set_id
    for update
  loop
    perform r.rule_id from internal.rag_rules r
      where r.rule_set_id = v_set.rule_set_id order by r.rule_id for update;
    perform g.condition_group_id from internal.rag_rule_condition_groups g
      where g.rule_set_id = v_set.rule_set_id
      order by g.condition_group_id for update;
    perform c.condition_id from internal.rag_rule_conditions c
      where c.rule_set_id = v_set.rule_set_id
      order by c.condition_id for update;
    perform src.passage_id from internal.rag_rule_sources src
      where src.rule_set_id = v_set.rule_set_id
      order by src.passage_id for update;

    v_integrity := internal.inspect_rag_rule_set_integrity(v_set.rule_set_id);
    if (v_integrity->>'valid')::boolean is not true then
      raise exception using errcode = 'P0001',
        message = 'rag_rule_activation_integrity_failed',
        detail = v_set.rule_set_id::text;
    end if;
    if exists (
      select 1 from internal.rag_rule_sets active_set
      where active_set.institution_id = new.institution_id
        and active_set.rule_key = v_set.rule_key
        and active_set.status = 'validated'
        and active_set.rule_set_id <> v_set.rule_set_id
    ) then
      raise exception using errcode = 'P0001',
        message = 'rag_rule_activation_conflict',
        detail = v_set.rule_set_id::text;
    end if;

    update internal.rag_rule_sets s
    set status = 'validated', validated_by = s.approved_by,
        validated_at = v_now, invalidated_at = null,
        invalidation_reason = null, revision_number = revision_number + 1
    where s.rule_set_id = v_set.rule_set_id;
    insert into internal.rag_rule_audit_events (
      institution_id, rule_set_id, document_id, template_key,
      template_version_id, actor_user_uuid, event_type,
      old_status, new_status, change_summary
    ) values (
      new.institution_id, v_set.rule_set_id, new.document_id, v_set.rule_key,
      v_set.template_version_id, v_set.approved_by,
      'rag_rule_validated', 'approved', 'validated',
      pg_catalog.jsonb_build_object('promotion', 'document_activation')
    );
  end loop;
  return new;
end;
$$;

create or replace function internal.invalidate_rag_rules_from_document()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_set record;
begin
  if new.status not in ('ready', 'active')
     and old.status is distinct from new.status then
    for v_set in
      select s.* from internal.rag_rule_sets s
      where s.document_id = new.document_id
        and s.institution_id = new.institution_id
        and s.status in (
          'proposed', 'needs_attention', 'approved', 'validated'
        )
      order by s.rule_set_id for update
    loop
      update internal.rag_rule_sets s
      set status = 'invalidated', approved_by = null, approved_at = null,
          validated_by = null, validated_at = null,
          invalidated_at = pg_catalog.now(),
          invalidation_reason = 'document_not_eligible',
          rejected_by = null, rejected_at = null,
          rejection_reason_code = null, rejection_note = null,
          revision_number = revision_number + 1
      where s.rule_set_id = v_set.rule_set_id;
      insert into internal.rag_rule_audit_events (
        institution_id, rule_set_id, document_id, template_key,
        template_version_id, event_type, old_status, new_status,
        reason_code, change_summary
      ) values (
        new.institution_id, v_set.rule_set_id, new.document_id,
        v_set.rule_key, v_set.template_version_id,
        'rag_rule_invalidated', v_set.status, 'invalidated',
        'document_not_eligible',
        pg_catalog.jsonb_build_object('document_status', new.status)
      );
    end loop;
  end if;
  return new;
end;
$$;

create or replace function internal.protect_rag_document_with_open_rules()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from internal.rag_rule_sets s
    where s.document_id = old.document_id
      and s.institution_id = old.institution_id
      and s.status in (
        'proposed', 'needs_attention', 'approved', 'validated'
      )
  ) then
    raise exception using errcode = 'P0001',
      message = 'document_has_protected_rules';
  end if;
  return old;
end;
$$;

create trigger rag_documents_protect_open_rules
before delete on internal.rag_documents
for each row execute function internal.protect_rag_document_with_open_rules();

create or replace function server_api.delete_rag_document(
  p_auth_uid uuid,
  p_document_id uuid,
  p_confirm_delete boolean,
  p_confirmation_title text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_document_key text;
  v_title text;
  v_version_label text;
  v_status text;
  v_storage_path text;
begin
  select r.authorized, r.user_uuid, r.institution_id
  into v_authorized, v_admin_user_uuid, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r limit 1;
  if coalesce(v_authorized, false) is not true
     or v_admin_user_uuid is null or v_institution_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'admin_unauthorized'
    );
  end if;
  if coalesce(p_confirm_delete, false) is not true then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'delete_confirmation_required'
    );
  end if;
  select d.document_key into v_document_key
  from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'document_not_found'
    );
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || v_document_key, 0
    )
  );
  select d.document_key, d.title, d.version_label, d.status, d.storage_path
  into v_document_key, v_title, v_version_label, v_status, v_storage_path
  from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id for update;
  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'document_not_found'
    );
  end if;
  if v_status = 'processing' or exists (
    select 1 from internal.rag_ingestion_jobs j
    where j.document_id = p_document_id
      and j.institution_id = v_institution_id
      and j.status in ('queued', 'running')
  ) then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'ingestion_in_progress'
    );
  end if;
  perform s.rule_set_id from internal.rag_rule_sets s
  where s.document_id = p_document_id
    and s.institution_id = v_institution_id
  order by s.rule_set_id for update;
  if exists (
    select 1 from internal.rag_rule_sets s
    where s.document_id = p_document_id
      and s.institution_id = v_institution_id
      and s.status in (
        'proposed', 'needs_attention', 'approved', 'validated'
      )
  ) then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'document_has_protected_rules'
    );
  end if;
  if v_status = 'active'
     and coalesce(pg_catalog.btrim(p_confirmation_title), '') <> v_title then
    return pg_catalog.jsonb_build_object(
      'success', false, 'status_code', 'active_confirmation_required',
      'confirmation_title', v_title
    );
  end if;
  insert into internal.security_log (
    event_type, user_uuid, institution_id, actor_admin_uuid, detail
  ) values (
    'rag_document_deleted', v_admin_user_uuid, v_institution_id,
    v_admin_user_uuid, pg_catalog.jsonb_build_object(
      'document_id', p_document_id, 'document_key', v_document_key,
      'title', v_title, 'version_label', v_version_label,
      'deleted_at', pg_catalog.now()
    )
  );
  delete from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;
  return pg_catalog.jsonb_build_object(
    'success', true, 'status_code', 'deleted',
    'document_id', p_document_id, 'storage_path', v_storage_path,
    'deleted_status', v_status
  );
end;
$$;

-- -------------------------------------------------------------------------
-- 8. Wrappers PostgREST réservés au service_role
-- -------------------------------------------------------------------------

create or replace function public.list_rag_rule_sets_admin_wrapper(
  p_auth_uid uuid,
  p_document_id uuid default null,
  p_template_key text default null,
  p_statuses text[] default null,
  p_action_required boolean default null,
  p_cursor text default null,
  p_limit integer default 25
) returns jsonb language sql security definer set search_path = '' as $$
  select server_api.list_rag_rule_sets_admin(
    p_auth_uid, p_document_id, p_template_key, p_statuses,
    p_action_required, p_cursor, p_limit
  );
$$;

create or replace function public.get_rag_rule_set_admin_wrapper(
  p_auth_uid uuid, p_rule_set_id uuid
) returns jsonb language sql security definer set search_path = '' as $$
  select server_api.get_rag_rule_set_admin(p_auth_uid, p_rule_set_id);
$$;

create or replace function public.get_rag_rule_audit_admin_wrapper(
  p_auth_uid uuid, p_rule_set_id uuid default null,
  p_cursor text default null, p_limit integer default 25
) returns jsonb language sql security definer set search_path = '' as $$
  select server_api.get_rag_rule_audit_admin(
    p_auth_uid, p_rule_set_id, p_cursor, p_limit
  );
$$;

create or replace function public.create_rag_rule_revision_wrapper(
  p_auth_uid uuid, p_rule_set_id uuid
) returns jsonb language sql security definer set search_path = '' as $$
  select server_api.create_rag_rule_revision(p_auth_uid, p_rule_set_id);
$$;

create or replace function public.save_rag_rule_set_correction_wrapper(
  p_auth_uid uuid, p_rule_set_id uuid,
  p_expected_revision_number bigint, p_operation_id uuid, p_rules jsonb
) returns jsonb language sql security definer set search_path = '' as $$
  select server_api.save_rag_rule_set_correction(
    p_auth_uid, p_rule_set_id, p_expected_revision_number,
    p_operation_id, p_rules
  );
$$;

create or replace function public.confirm_rag_rule_set_wrapper(
  p_auth_uid uuid, p_rule_set_id uuid,
  p_expected_revision_number bigint, p_operation_id uuid,
  p_confirmation boolean
) returns jsonb language sql security definer set search_path = '' as $$
  select server_api.confirm_rag_rule_set(
    p_auth_uid, p_rule_set_id, p_expected_revision_number,
    p_operation_id, p_confirmation
  );
$$;

create or replace function public.reject_rag_rule_set_wrapper(
  p_auth_uid uuid, p_rule_set_id uuid,
  p_expected_revision_number bigint, p_operation_id uuid,
  p_reason_code text, p_rejection_note text default null
) returns jsonb language sql security definer set search_path = '' as $$
  select server_api.reject_rag_rule_set(
    p_auth_uid, p_rule_set_id, p_expected_revision_number,
    p_operation_id, p_reason_code, p_rejection_note
  );
$$;

create or replace function public.audit_rag_rule_simulation_wrapper(
  p_auth_uid uuid, p_rule_set_id uuid, p_success boolean,
  p_result_code text, p_recognized_fact_count integer
) returns jsonb language sql security definer set search_path = '' as $$
  select server_api.audit_rag_rule_simulation(
    p_auth_uid, p_rule_set_id, p_success,
    p_result_code, p_recognized_fact_count
  );
$$;

revoke all on function server_api.list_rag_rule_sets_admin(
  uuid, uuid, text, text[], boolean, text, integer
) from public, anon, authenticated, service_role;
revoke all on function server_api.get_rag_rule_set_admin(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function server_api.get_rag_rule_audit_admin(
  uuid, uuid, text, integer
) from public, anon, authenticated, service_role;
revoke all on function server_api.create_rag_rule_revision(uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function server_api.save_rag_rule_set_correction(
  uuid, uuid, bigint, uuid, jsonb
) from public, anon, authenticated, service_role;
revoke all on function server_api.confirm_rag_rule_set(
  uuid, uuid, bigint, uuid, boolean
) from public, anon, authenticated, service_role;
revoke all on function server_api.reject_rag_rule_set(
  uuid, uuid, bigint, uuid, text, text
) from public, anon, authenticated, service_role;
revoke all on function server_api.audit_rag_rule_simulation(
  uuid, uuid, boolean, text, integer
) from public, anon, authenticated, service_role;

revoke all on function public.list_rag_rule_sets_admin_wrapper(
  uuid, uuid, text, text[], boolean, text, integer
) from public, anon, authenticated;
grant execute on function public.list_rag_rule_sets_admin_wrapper(
  uuid, uuid, text, text[], boolean, text, integer
) to service_role;
revoke all on function public.get_rag_rule_set_admin_wrapper(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.get_rag_rule_set_admin_wrapper(uuid, uuid)
  to service_role;
revoke all on function public.get_rag_rule_audit_admin_wrapper(
  uuid, uuid, text, integer
) from public, anon, authenticated;
grant execute on function public.get_rag_rule_audit_admin_wrapper(
  uuid, uuid, text, integer
) to service_role;
revoke all on function public.create_rag_rule_revision_wrapper(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.create_rag_rule_revision_wrapper(uuid, uuid)
  to service_role;
revoke all on function public.save_rag_rule_set_correction_wrapper(
  uuid, uuid, bigint, uuid, jsonb
) from public, anon, authenticated;
grant execute on function public.save_rag_rule_set_correction_wrapper(
  uuid, uuid, bigint, uuid, jsonb
) to service_role;
revoke all on function public.confirm_rag_rule_set_wrapper(
  uuid, uuid, bigint, uuid, boolean
) from public, anon, authenticated;
grant execute on function public.confirm_rag_rule_set_wrapper(
  uuid, uuid, bigint, uuid, boolean
) to service_role;
revoke all on function public.reject_rag_rule_set_wrapper(
  uuid, uuid, bigint, uuid, text, text
) from public, anon, authenticated;
grant execute on function public.reject_rag_rule_set_wrapper(
  uuid, uuid, bigint, uuid, text, text
) to service_role;
revoke all on function public.audit_rag_rule_simulation_wrapper(
  uuid, uuid, boolean, text, integer
) from public, anon, authenticated;
grant execute on function public.audit_rag_rule_simulation_wrapper(
  uuid, uuid, boolean, text, integer
) to service_role;

-- L'ancien point d'entrée de validation ne doit plus contourner le contrôle
-- de révision, l'idempotence et l'audit RAG-10.7.
revoke execute on function public.validate_rag_rule_set_wrapper(uuid, uuid)
  from service_role;

comment on table internal.rag_rule_audit_events is
  'Journal métier RAG-10.7. Conservation pendant la relation contractuelle puis dix ans; purge institutionnelle contrôlée et journalisée à documenter avant production.';
comment on table internal.rag_rule_operation_receipts is
  'Reçus techniques d’idempotence, supprimables après 90 jours; distincts du journal métier.';

do $$
begin
  if exists (
    select 1
    from internal.rag_rule_sets s
    where s.status = 'validated'
    group by s.institution_id, s.rule_key having pg_catalog.count(*) > 1
  ) or exists (
    select 1 from internal.rag_rule_sources src
    where src.passage_content_sha256 is null
  ) then
    raise exception 'RAG-10.7 : postcondition de migration non respectée';
  end if;
end;
$$;






-- -------------------------------------------------------------------------

commit;
