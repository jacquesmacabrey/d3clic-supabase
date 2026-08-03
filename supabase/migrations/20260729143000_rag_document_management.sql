begin;

alter table internal.rag_documents
  add column if not exists deactivated_at timestamptz;

alter table internal.rag_documents
  drop constraint if exists rag_documents_status_check;

alter table internal.rag_documents
  add constraint rag_documents_status_check
  check (
    status = any (
      array[
        'draft'::text,
        'processing'::text,
        'ready'::text,
        'active'::text,
        'inactive'::text,
        'obsolete'::text,
        'error'::text
      ]
    )
  );

alter table internal.rag_documents
  drop constraint if exists rag_documents_inactive_date_check;

alter table internal.rag_documents
  add constraint rag_documents_inactive_date_check
  check (status <> 'inactive' or deactivated_at is not null);

create or replace function server_api.list_rag_documents(
  p_auth_uid uuid
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
  v_documents jsonb;
begin
  if p_auth_uid is null then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'admin_unauthorized'
    );
  end if;

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

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'document_id', x.document_id,
        'document_key', x.document_key,
        'title', x.title,
        'category', x.category,
        'version_label', x.version_label,
        'effective_date', x.effective_date,
        'status', x.document_status,
        'original_file_name', x.original_file_name,
        'file_size_bytes', x.file_size_bytes,
        'page_count', x.page_count,
        'passage_count', x.passage_count,
        'error_message', x.error_message,
        'created_at', x.document_created_at,
        'updated_at', x.document_updated_at,
        'activated_at', x.activated_at,
        'deactivated_at', x.deactivated_at,
        'obsolete_at', x.obsolete_at,
        'latest_job', x.latest_job
      )
      order by x.document_created_at desc, x.document_id desc
    ),
    '[]'::jsonb
  )
  into v_documents
  from (
    select
      d.document_id,
      d.document_key,
      d.title,
      d.category,
      d.version_label,
      d.effective_date,
      d.status as document_status,
      d.original_file_name,
      d.file_size_bytes,
      d.page_count,
      case
        when pg_catalog.jsonb_typeof(
          d.extraction_metadata -> 'passage_count'
        ) = 'number'
        then (d.extraction_metadata ->> 'passage_count')::integer
        else null
      end as passage_count,
      d.error_message,
      d.created_at as document_created_at,
      d.updated_at as document_updated_at,
      d.activated_at,
      d.deactivated_at,
      d.obsolete_at,
      case
        when j.job_id is null then null
        else pg_catalog.jsonb_build_object(
          'job_id', j.job_id,
          'status', j.status,
          'stage', j.stage,
          'total_items', j.total_items,
          'processed_items', j.processed_items,
          'attempt_count', j.attempt_count,
          'max_attempts', j.max_attempts,
          'last_error_code', j.last_error_code,
          'last_error_message', j.last_error_message,
          'created_at', j.created_at,
          'updated_at', j.updated_at,
          'started_at', j.started_at,
          'finished_at', j.finished_at
        )
      end as latest_job
    from internal.rag_documents d
    left join lateral (
      select
        ij.job_id,
        ij.status,
        ij.stage,
        ij.total_items,
        ij.processed_items,
        ij.attempt_count,
        ij.max_attempts,
        ij.last_error_code,
        ij.last_error_message,
        ij.created_at,
        ij.updated_at,
        ij.started_at,
        ij.finished_at
      from internal.rag_ingestion_jobs ij
      where ij.document_id = d.document_id
        and ij.institution_id = v_institution_id
      order by ij.created_at desc, ij.job_id desc
      limit 1
    ) j on true
    where d.institution_id = v_institution_id
    order by d.created_at desc, d.document_id desc
    limit 500
  ) x;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'ok',
    'documents', v_documents
  );
end;
$$;

create or replace function server_api.activate_rag_document(
  p_auth_uid uuid,
  p_document_id uuid
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
  v_status text;
  v_storage_path text;
  v_extraction_method text;
  v_passage_count bigint;
  v_missing_embedding_count bigint;
  v_obsoleted_document_ids uuid[] := array[]::uuid[];
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

  select d.document_key
  into v_document_key
  from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_found'
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || v_document_key,
      0
    )
  );

  select d.document_key, d.status, d.storage_path, d.extraction_method
  into v_document_key, v_status, v_storage_path, v_extraction_method
  from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_found'
    );
  end if;

  if v_status = 'active' then
    return pg_catalog.jsonb_build_object(
      'success', true,
      'status_code', 'already_active',
      'document_id', p_document_id
    );
  end if;

  if v_status not in ('ready', 'inactive') then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_ready',
      'current_status', v_status
    );
  end if;

  if v_extraction_method is null
     or pg_catalog.btrim(v_extraction_method) = ''
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'extraction_incomplete'
    );
  end if;

  if exists (
    select 1
    from internal.rag_ingestion_jobs j
    where j.document_id = p_document_id
      and j.institution_id = v_institution_id
      and j.status in ('queued', 'running')
  ) then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'ingestion_in_progress'
    );
  end if;

  select
    pg_catalog.count(*),
    pg_catalog.count(*) filter (where p.embedding is null)
  into v_passage_count, v_missing_embedding_count
  from internal.rag_passages p
  where p.document_id = p_document_id
    and p.institution_id = v_institution_id;

  if v_passage_count = 0 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'no_passages'
    );
  end if;

  if v_missing_embedding_count > 0 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'embeddings_incomplete',
      'missing_embedding_count', v_missing_embedding_count
    );
  end if;

  if not exists (
    select 1
    from storage.objects o
    where o.bucket_id = 'rag-documents'
      and o.name = v_storage_path
  ) then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'source_file_missing'
    );
  end if;

  with obsoleted as (
    update internal.rag_documents d
    set
      status = 'obsolete',
      obsolete_at = v_now,
      deactivated_at = null
    where d.institution_id = v_institution_id
      and d.document_key = v_document_key
      and d.status = 'active'
      and d.document_id <> p_document_id
    returning d.document_id
  )
  select coalesce(
    pg_catalog.array_agg(
      obsoleted.document_id
      order by obsoleted.document_id
    ),
    array[]::uuid[]
  )
  into v_obsoleted_document_ids
  from obsoleted;

  update internal.rag_documents d
  set
    status = 'active',
    activated_at = v_now,
    deactivated_at = null,
    obsolete_at = null,
    error_message = null
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;

  insert into internal.security_log (
    event_type,
    user_uuid,
    institution_id,
    actor_admin_uuid,
    detail
  )
  values (
    'rag_document_activated',
    v_admin_user_uuid,
    v_institution_id,
    v_admin_user_uuid,
    pg_catalog.jsonb_build_object(
      'document_id', p_document_id,
      'document_key', v_document_key,
      'obsoleted_document_ids',
        pg_catalog.to_jsonb(v_obsoleted_document_ids)
    )
  );

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'activated',
    'document_id', p_document_id,
    'obsoleted_document_ids',
      pg_catalog.to_jsonb(v_obsoleted_document_ids)
  );
end;
$$;

create or replace function server_api.deactivate_rag_document(
  p_auth_uid uuid,
  p_document_id uuid
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

  select d.document_key
  into v_document_key
  from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_found'
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || v_document_key,
      0
    )
  );

  select d.document_key, d.title, d.version_label, d.status
  into v_document_key, v_title, v_version_label, v_status
  from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_found'
    );
  end if;

  if v_status = 'inactive' then
    return pg_catalog.jsonb_build_object(
      'success', true,
      'status_code', 'already_inactive',
      'document_id', p_document_id
    );
  end if;

  if v_status <> 'active' then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_active',
      'current_status', v_status
    );
  end if;

  update internal.rag_documents d
  set
    status = 'inactive',
    deactivated_at = v_now,
    obsolete_at = null
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;

  insert into internal.security_log (
    event_type,
    user_uuid,
    institution_id,
    actor_admin_uuid,
    detail
  )
  values (
    'rag_document_deactivated',
    v_admin_user_uuid,
    v_institution_id,
    v_admin_user_uuid,
    pg_catalog.jsonb_build_object(
      'document_id', p_document_id,
      'document_key', v_document_key,
      'title', v_title,
      'version_label', v_version_label
    )
  );

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'deactivated',
    'document_id', p_document_id
  );
end;
$$;

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

  if coalesce(p_confirm_delete, false) is not true then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'delete_confirmation_required'
    );
  end if;

  select d.document_key
  into v_document_key
  from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_found'
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || v_document_key,
      0
    )
  );

  select
    d.document_key,
    d.title,
    d.version_label,
    d.status,
    d.storage_path
  into
    v_document_key,
    v_title,
    v_version_label,
    v_status,
    v_storage_path
  from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_not_found'
    );
  end if;

  if v_status = 'active'
     and coalesce(pg_catalog.btrim(p_confirmation_title), '') <> v_title
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'active_confirmation_required',
      'confirmation_title', v_title
    );
  end if;

  insert into internal.security_log (
    event_type,
    user_uuid,
    institution_id,
    actor_admin_uuid,
    detail
  )
  values (
    'rag_document_deleted',
    v_admin_user_uuid,
    v_institution_id,
    v_admin_user_uuid,
    pg_catalog.jsonb_build_object(
      'document_id', p_document_id,
      'document_key', v_document_key,
      'title', v_title,
      'version_label', v_version_label,
      'deleted_at', v_now
    )
  );

  delete from internal.rag_documents d
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'deleted',
    'document_id', p_document_id,
    'storage_path', v_storage_path,
    'deleted_status', v_status
  );
end;
$$;

create or replace function public.deactivate_rag_document_wrapper(
  p_auth_uid uuid,
  p_document_id uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select server_api.deactivate_rag_document(
    p_auth_uid,
    p_document_id
  );
$$;

create or replace function public.delete_rag_document_wrapper(
  p_auth_uid uuid,
  p_document_id uuid,
  p_confirm_delete boolean,
  p_confirmation_title text default null
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select server_api.delete_rag_document(
    p_auth_uid,
    p_document_id,
    p_confirm_delete,
    p_confirmation_title
  );
$$;

revoke all on function server_api.list_rag_documents(uuid) from public;
revoke all on function server_api.activate_rag_document(uuid, uuid) from public;
revoke all on function server_api.deactivate_rag_document(uuid, uuid) from public;
revoke all on function server_api.delete_rag_document(
  uuid,
  uuid,
  boolean,
  text
) from public;

revoke all on function public.deactivate_rag_document_wrapper(
  uuid,
  uuid
) from public;
grant execute on function public.deactivate_rag_document_wrapper(
  uuid,
  uuid
) to service_role;

revoke all on function public.delete_rag_document_wrapper(
  uuid,
  uuid,
  boolean,
  text
) from public;
grant execute on function public.delete_rag_document_wrapper(
  uuid,
  uuid,
  boolean,
  text
) to service_role;

comment on column internal.rag_documents.deactivated_at is
  'Date du retrait volontaire et réversible du document du corpus actif.';

comment on function server_api.deactivate_rag_document(uuid, uuid) is
  'Désactive réversiblement une version RAG active dans l’institution de l’admin.';

comment on function server_api.delete_rag_document(
  uuid,
  uuid,
  boolean,
  text
) is
  'Supprime les données RAG et conserve une trace minimale dans security_log.';

commit;
