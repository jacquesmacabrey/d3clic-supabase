-- RAG-9.1: protect documents used by validated rules.

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

  perform rs.rule_set_id
  from internal.rag_rule_sets rs
  where rs.document_id = p_document_id
    and rs.institution_id = v_institution_id
  for update;

  if exists (
    select 1
    from internal.rag_rule_sets rs
    where rs.document_id = p_document_id
      and rs.institution_id = v_institution_id
      and rs.status = 'validated'
  ) then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_has_validated_rules'
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
