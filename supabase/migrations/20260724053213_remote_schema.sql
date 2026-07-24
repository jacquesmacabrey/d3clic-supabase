


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "api";


ALTER SCHEMA "api" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "internal";


ALTER SCHEMA "internal" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE SCHEMA IF NOT EXISTS "server_api";


ALTER SCHEMA "server_api" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "internal"."current_device_and_user_ok"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from internal.devices d
    join internal.users u on u.user_uuid = d.user_uuid
    join internal.institutions i on i.institution_id = u.institution_id
    where auth.uid() is not null
      and d.device_auth_uid = auth.uid()
      and d.user_uuid is not null
      and d.activated_at is not null
      and d.revoked_at is null
      and u.active = true
      and i.active = true
  );
$$;


ALTER FUNCTION "internal"."current_device_and_user_ok"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "internal"."current_user_has_channel"("p_institution_id" "text", "p_channel_id" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    internal.current_device_and_user_ok()
    and exists (
      select 1
      from internal.devices d
      join internal.users u on u.user_uuid = d.user_uuid
      join internal.channels c
        on c.institution_id = u.institution_id
       and c.channel_id = p_channel_id
      join internal.user_channel_memberships m
        on m.user_uuid = u.user_uuid
       and m.institution_id = u.institution_id
       and m.channel_id = p_channel_id
      where d.device_auth_uid = auth.uid()
        and u.institution_id = p_institution_id
        and c.enabled = true
    );
$$;


ALTER FUNCTION "internal"."current_user_has_channel"("p_institution_id" "text", "p_channel_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "internal"."current_user_has_role"("p_role" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    coalesce(
      p_role in ('cadre', 'admin', 'admin_readonly'),
      false
    )
    and internal.current_device_and_user_ok()
    and exists (
      select 1
      from internal.devices d
      join internal.user_roles r on r.user_uuid = d.user_uuid
      where d.device_auth_uid = auth.uid()
        and r.role = p_role
    );
$$;


ALTER FUNCTION "internal"."current_user_has_role"("p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "internal"."current_user_matches"("p_user_uuid" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select
    p_user_uuid is not null
    and internal.current_device_and_user_ok()
    and exists (
      select 1
      from internal.devices d
      where d.device_auth_uid = auth.uid()
        and d.user_uuid = p_user_uuid
    );
$$;


ALTER FUNCTION "internal"."current_user_matches"("p_user_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "internal"."rag_set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  new.updated_at := now();
  return new;
end;
$$;


ALTER FUNCTION "internal"."rag_set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."activate_device_wrapper"("p_device_auth_uid" "uuid", "p_token_hash" "text", "p_method" "text", "p_ip_hash" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  select server_api.activate_device(p_device_auth_uid, p_token_hash, p_method, p_ip_hash);
$$;


ALTER FUNCTION "public"."activate_device_wrapper"("p_device_auth_uid" "uuid", "p_token_hash" "text", "p_method" "text", "p_ip_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."activate_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.activate_rag_document(
    p_auth_uid,
    p_document_id
  );
$$;


ALTER FUNCTION "public"."activate_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."activate_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid") IS 'Wrapper service_role de l’activation atomique d’un document RAG.';



CREATE OR REPLACE FUNCTION "public"."append_rag_passage_batch_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_passages" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.append_rag_passage_batch(
    p_auth_uid,
    p_job_id,
    p_worker_id,
    p_passages
  );
$$;


ALTER FUNCTION "public"."append_rag_passage_batch_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_passages" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_backoffice_request_wrapper"("p_request_id" "uuid", "p_institution_id" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text" DEFAULT NULL::"text", "p_existing_user_uuid" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select server_api.approve_backoffice_request(
    p_request_id,
    p_institution_id,
    p_display_name,
    p_channel_ids,
    p_confirmed_goodbarber_user_id,
    p_existing_user_uuid
  );
$$;


ALTER FUNCTION "public"."approve_backoffice_request_wrapper"("p_request_id" "uuid", "p_institution_id" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_device_activation_request_wrapper"("p_request_id" "uuid", "p_approval_token_hash" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text" DEFAULT NULL::"text", "p_existing_user_uuid" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  select server_api.approve_device_activation_request(
    p_request_id,
    p_approval_token_hash,
    p_display_name,
    p_channel_ids,
    p_confirmed_goodbarber_user_id,
    p_existing_user_uuid
  );
$$;


ALTER FUNCTION "public"."approve_device_activation_request_wrapper"("p_request_id" "uuid", "p_approval_token_hash" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_device_activation_request_wrapper"("p_request_id" "uuid", "p_device_auth_uid" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  select server_api.cancel_device_activation_request(
    p_request_id,
    p_device_auth_uid,
    p_reason
  );
$$;


ALTER FUNCTION "public"."cancel_device_activation_request_wrapper"("p_request_id" "uuid", "p_device_auth_uid" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_backoffice_role_wrapper"("p_auth_uid" "uuid", "p_required_role" "text" DEFAULT 'admin'::"text") RETURNS TABLE("authorized" boolean, "user_uuid" "uuid", "institution_id" "text", "display_name" "text", "role" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select * from server_api.check_backoffice_role(p_auth_uid, p_required_role);
$$;


ALTER FUNCTION "public"."check_backoffice_role_wrapper"("p_auth_uid" "uuid", "p_required_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_extraction_method" "text", "p_extraction_version" "text", "p_page_count" integer, "p_extraction_metadata" "jsonb") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.complete_rag_ingestion(
    p_auth_uid,
    p_job_id,
    p_worker_id,
    p_extraction_method,
    p_extraction_version,
    p_page_count,
    p_extraction_metadata
  );
$$;


ALTER FUNCTION "public"."complete_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_extraction_method" "text", "p_extraction_version" "text", "p_page_count" integer, "p_extraction_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_device_activation_request_wrapper"("p_device_auth_uid" "uuid", "p_institution_id" "text", "p_suggested_display_name" "text", "p_suggested_email" "text", "p_suggested_goodbarber_user_id" "text", "p_suggested_groups" "jsonb", "p_approval_token_hash" "text", "p_ip_hash" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  select server_api.create_device_activation_request(
    p_device_auth_uid,
    p_institution_id,
    p_suggested_display_name,
    p_suggested_email,
    p_suggested_goodbarber_user_id,
    p_suggested_groups,
    p_approval_token_hash,
    p_ip_hash
  );
$$;


ALTER FUNCTION "public"."create_device_activation_request_wrapper"("p_device_auth_uid" "uuid", "p_institution_id" "text", "p_suggested_display_name" "text", "p_suggested_email" "text", "p_suggested_goodbarber_user_id" "text", "p_suggested_groups" "jsonb", "p_approval_token_hash" "text", "p_ip_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_chat_message"("p_message_id" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.delete_chat_message(
    p_message_id
  );
$$;


ALTER FUNCTION "public"."delete_chat_message"("p_message_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."edit_chat_message"("p_message_id" "uuid", "p_body" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.edit_chat_message(
    p_message_id,
    p_body
  );
$$;


ALTER FUNCTION "public"."edit_chat_message"("p_message_id" "uuid", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fail_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_error_code" "text", "p_error_message" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.fail_rag_ingestion(
    p_auth_uid,
    p_job_id,
    p_worker_id,
    p_error_code,
    p_error_message
  );
$$;


ALTER FUNCTION "public"."fail_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_error_code" "text", "p_error_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_backoffice_dashboard_wrapper"("p_institution_id" "text") RETURNS TABLE("user_uuid" "uuid", "display_name" "text", "active" boolean, "goodbarber_user_id" "text", "created_at" timestamp with time zone, "channels" "text"[], "device_count" bigint, "last_seen_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select * from server_api.get_backoffice_dashboard(p_institution_id);
$$;


ALTER FUNCTION "public"."get_backoffice_dashboard_wrapper"("p_institution_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_backoffice_pending_requests_wrapper"("p_institution_id" "text") RETURNS TABLE("request_id" "uuid", "suggested_display_name" "text", "suggested_email" "text", "suggested_goodbarber_user_id" "text", "suggested_groups" "jsonb", "created_at" timestamp with time zone, "expires_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select * from server_api.get_backoffice_pending_requests(p_institution_id);
$$;


ALTER FUNCTION "public"."get_backoffice_pending_requests_wrapper"("p_institution_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_backoffice_request_detail_wrapper"("p_request_id" "uuid", "p_institution_id" "text") RETURNS TABLE("request_id" "uuid", "suggested_display_name" "text", "suggested_email" "text", "suggested_goodbarber_user_id" "text", "suggested_groups" "jsonb", "created_at" timestamp with time zone, "expires_at" timestamp with time zone, "channels" "jsonb", "existing_users" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select * from server_api.get_backoffice_request_detail(p_request_id, p_institution_id);
$$;


ALTER FUNCTION "public"."get_backoffice_request_detail_wrapper"("p_request_id" "uuid", "p_institution_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_chat_context"() RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.get_chat_context();
$$;


ALTER FUNCTION "public"."get_chat_context"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_device_activation_request_for_approval_wrapper"("p_request_id" "uuid", "p_approval_token_hash" "text") RETURNS "jsonb"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  select server_api.get_device_activation_request_for_approval(
    p_request_id,
    p_approval_token_hash
  );
$$;


ALTER FUNCTION "public"."get_device_activation_request_for_approval_wrapper"("p_request_id" "uuid", "p_approval_token_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_rag_documents_wrapper"("p_auth_uid" "uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.list_rag_documents(p_auth_uid);
$$;


ALTER FUNCTION "public"."list_rag_documents_wrapper"("p_auth_uid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."list_rag_documents_wrapper"("p_auth_uid" "uuid") IS 'Wrapper backend de consultation RAG, rÃ©servÃ© Ã  service_role.';



CREATE OR REPLACE FUNCTION "public"."mark_chat_channel_read"("p_group_id" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.mark_chat_channel_read(
    p_group_id
  );
$$;


ALTER FUNCTION "public"."mark_chat_channel_read"("p_group_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pin_chat_message"("p_message_id" "uuid", "p_duration_code" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.pin_chat_message(
    p_message_id,
    p_duration_code
  );
$$;


ALTER FUNCTION "public"."pin_chat_message"("p_message_id" "uuid", "p_duration_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."proto_device_is_active"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from public.proto_devices d
    join public.proto_people p on p.user_uuid = d.user_uuid
    where d.device_auth_uid = auth.uid()
      and d.activated = true
      and d.revoked_at is null
      and p.active = true
  );
$$;


ALTER FUNCTION "public"."proto_device_is_active"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_document_key" "text", "p_title" "text", "p_category" "text", "p_version_label" "text", "p_effective_date" "date", "p_storage_path" "text", "p_original_file_name" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_file_sha256" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.register_rag_document(
    p_auth_uid,
    p_document_id,
    p_document_key,
    p_title,
    p_category,
    p_version_label,
    p_effective_date,
    p_storage_path,
    p_original_file_name,
    p_mime_type,
    p_file_size_bytes,
    p_file_sha256
  );
$$;


ALTER FUNCTION "public"."register_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_document_key" "text", "p_title" "text", "p_category" "text", "p_version_label" "text", "p_effective_date" "date", "p_storage_path" "text", "p_original_file_name" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_file_sha256" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_chat_message"("p_group_id" "text", "p_body" "text", "p_reply_to_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.send_chat_message(
    p_group_id,
    p_body,
    p_reply_to_id
  );
$$;


ALTER FUNCTION "public"."send_chat_message"("p_group_id" "text", "p_body" "text", "p_reply_to_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_rag_ingestion_plan_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_total_items" integer) RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.set_rag_ingestion_plan(
    p_auth_uid,
    p_job_id,
    p_worker_id,
    p_total_items
  );
$$;


ALTER FUNCTION "public"."set_rag_ingestion_plan_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_total_items" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."start_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_worker_id" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.start_rag_ingestion(
    p_auth_uid,
    p_document_id,
    p_worker_id
  );
$$;


ALTER FUNCTION "public"."start_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_worker_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."toggle_chat_reaction"("p_message_id" "uuid", "p_emoji" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.toggle_chat_reaction(
    p_message_id,
    p_emoji
  );
$$;


ALTER FUNCTION "public"."toggle_chat_reaction"("p_message_id" "uuid", "p_emoji" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unpin_chat_message"("p_group_id" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select server_api.unpin_chat_message(
    p_group_id
  );
$$;


ALTER FUNCTION "public"."unpin_chat_message"("p_group_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."activate_device"("p_device_auth_uid" "uuid", "p_token_hash" "text", "p_method" "text", "p_ip_hash" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  c_device_limit constant int := 5;
  c_token_limit  constant int := 10;
  c_ip_limit     constant int := 20;

  v_window_start timestamptz :=
    to_timestamp(floor(extract(epoch from now()) / 600) * 600);

  v_rl_count int;

  v_is_anonymous boolean;
  v_device_row internal.devices%rowtype;
  v_token_row internal.activation_tokens%rowtype;

  v_user_active boolean;
  v_institution_active boolean;
  v_institution_id text;
begin

  -- ----------------------------------------------------------
  -- Validation des paramètres
  -- ----------------------------------------------------------
  if p_device_auth_uid is null
     or p_token_hash is null
     or p_method is null
     or p_method not in ('qr', 'manual_code', 'mcp')
     or p_token_hash !~ '^[0-9a-f]{64}$'
     or (
       p_ip_hash is not null
       and p_ip_hash !~ '^[0-9a-f]{64}$'
     )
  then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      jsonb_build_object(
        'status_code',
        'invalid_params'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'invalid_params'
    );
  end if;


  -- ----------------------------------------------------------
  -- Rate limiting par appareil
  -- Limite : 5 tentatives par fenêtre de 10 minutes
  -- ----------------------------------------------------------
  insert into internal.rate_limits (
    subject_type,
    subject_id,
    window_start,
    count,
    updated_at
  )
  values (
    'activation',
    'device:' || p_device_auth_uid::text,
    v_window_start,
    1,
    now()
  )
  on conflict (
    subject_type,
    subject_id,
    window_start
  )
  do update
  set
    count = internal.rate_limits.count + 1,
    updated_at = now()
  returning count into v_rl_count;

  if v_rl_count > c_device_limit then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      jsonb_build_object(
        'status_code',
        'rate_limited',
        'scope',
        'device'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'rate_limited'
    );
  end if;


  -- ----------------------------------------------------------
  -- Rate limiting par jeton
  -- Limite : 10 tentatives par fenêtre de 10 minutes
  -- ----------------------------------------------------------
  insert into internal.rate_limits (
    subject_type,
    subject_id,
    window_start,
    count,
    updated_at
  )
  values (
    'activation',
    'token:' || p_token_hash,
    v_window_start,
    1,
    now()
  )
  on conflict (
    subject_type,
    subject_id,
    window_start
  )
  do update
  set
    count = internal.rate_limits.count + 1,
    updated_at = now()
  returning count into v_rl_count;

  if v_rl_count > c_token_limit then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      jsonb_build_object(
        'status_code',
        'rate_limited',
        'scope',
        'token'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'rate_limited'
    );
  end if;


  -- ----------------------------------------------------------
  -- Rate limiting par IP hachée
  -- Limite : 20 tentatives par fenêtre de 10 minutes
  -- ----------------------------------------------------------
  if p_ip_hash is not null then
    insert into internal.rate_limits (
      subject_type,
      subject_id,
      window_start,
      count,
      updated_at
    )
    values (
      'activation',
      'ip:' || p_ip_hash,
      v_window_start,
      1,
      now()
    )
    on conflict (
      subject_type,
      subject_id,
      window_start
    )
    do update
    set
      count = internal.rate_limits.count + 1,
      updated_at = now()
    returning count into v_rl_count;

    if v_rl_count > c_ip_limit then
      insert into internal.security_log (
        event_type,
        device_auth_uid,
        detail
      )
      values (
        'activation_failed',
        p_device_auth_uid,
        jsonb_build_object(
          'status_code',
          'rate_limited',
          'scope',
          'ip'
        )
      );

      return jsonb_build_object(
        'success',
        false,
        'status_code',
        'rate_limited'
      );
    end if;
  end if;


  -- ----------------------------------------------------------
  -- Vérification du compte Supabase Auth
  -- ----------------------------------------------------------
  select u.is_anonymous
  into v_is_anonymous
  from auth.users u
  where u.id = p_device_auth_uid;

  if not found then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      jsonb_build_object(
        'status_code',
        'auth_uid_unknown'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'auth_uid_unknown'
    );
  end if;

  if v_is_anonymous is not true then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      jsonb_build_object(
        'status_code',
        'device_not_anonymous'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'device_not_anonymous'
    );
  end if;


  -- ----------------------------------------------------------
  -- Verrouillage de l’appareil
  -- Le verrou fonctionne même si la ligne devices n’existe pas
  -- encore.
  -- ----------------------------------------------------------
  perform pg_advisory_xact_lock(
    hashtextextended(
      'activate_device:' || p_device_auth_uid::text,
      0
    )
  );

  select d.*
  into v_device_row
  from internal.devices d
  where d.device_auth_uid = p_device_auth_uid
  for update;

  if found then

    if v_device_row.revoked_at is not null then
      insert into internal.security_log (
        event_type,
        device_auth_uid,
        detail
      )
      values (
        'activation_failed',
        p_device_auth_uid,
        jsonb_build_object(
          'status_code',
          'device_revoked'
        )
      );

      return jsonb_build_object(
        'success',
        false,
        'status_code',
        'device_revoked'
      );
    end if;

    if v_device_row.activated_at is not null then
      insert into internal.security_log (
        event_type,
        device_auth_uid,
        detail
      )
      values (
        'activation_failed',
        p_device_auth_uid,
        jsonb_build_object(
          'status_code',
          'device_already_activated'
        )
      );

      return jsonb_build_object(
        'success',
        false,
        'status_code',
        'device_already_activated'
      );
    end if;

    if v_device_row.user_uuid is not null then
      insert into internal.security_log (
        event_type,
        device_auth_uid,
        detail
      )
      values (
        'activation_failed',
        p_device_auth_uid,
        jsonb_build_object(
          'status_code',
          'device_state_invalid'
        )
      );

      return jsonb_build_object(
        'success',
        false,
        'status_code',
        'device_state_invalid'
      );
    end if;

  end if;


  -- ----------------------------------------------------------
  -- Recherche et verrouillage du jeton
  -- ----------------------------------------------------------
  select t.*
  into v_token_row
  from internal.activation_tokens t
  where t.token_hash = p_token_hash
    and t.method = p_method
  for update;

  if not found then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      jsonb_build_object(
        'status_code',
        'token_not_found'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'token_not_found'
    );
  end if;


  if v_token_row.consumed_at is not null then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      user_uuid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      v_token_row.user_uuid,
      jsonb_build_object(
        'status_code',
        'token_already_consumed'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'token_already_consumed'
    );
  end if;


  if v_token_row.invalidated_at is not null then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      user_uuid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      v_token_row.user_uuid,
      jsonb_build_object(
        'status_code',
        'token_invalidated'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'token_invalidated'
    );
  end if;


  if v_token_row.expires_at <= now() then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      user_uuid,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      v_token_row.user_uuid,
      jsonb_build_object(
        'status_code',
        'token_expired'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'token_expired'
    );
  end if;


  -- ----------------------------------------------------------
  -- Vérification de l’utilisateur et de son institution
  -- ----------------------------------------------------------
  select
    u.active,
    u.institution_id,
    i.active
  into
    v_user_active,
    v_institution_id,
    v_institution_active
  from internal.users u
  join internal.institutions i
    on i.institution_id = u.institution_id
  where u.user_uuid = v_token_row.user_uuid;


  if v_user_active is not true then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      user_uuid,
      institution_id,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      v_token_row.user_uuid,
      v_institution_id,
      jsonb_build_object(
        'status_code',
        'user_inactive'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'user_inactive'
    );
  end if;


  if v_institution_active is not true then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      user_uuid,
      institution_id,
      detail
    )
    values (
      'activation_failed',
      p_device_auth_uid,
      v_token_row.user_uuid,
      v_institution_id,
      jsonb_build_object(
        'status_code',
        'institution_inactive'
      )
    );

    return jsonb_build_object(
      'success',
      false,
      'status_code',
      'institution_inactive'
    );
  end if;


  -- ----------------------------------------------------------
  -- Création ou activation de l’appareil
  -- ----------------------------------------------------------
  if v_device_row.device_auth_uid is null then

    insert into internal.devices (
      device_auth_uid,
      user_uuid,
      activated_at
    )
    values (
      p_device_auth_uid,
      v_token_row.user_uuid,
      now()
    );

  else

    update internal.devices
    set
      user_uuid = v_token_row.user_uuid,
      activated_at = now()
    where device_auth_uid = p_device_auth_uid;

  end if;


  -- ----------------------------------------------------------
  -- Consommation définitive du jeton
  -- ----------------------------------------------------------
  update internal.activation_tokens
  set
    consumed_at = now(),
    consumed_by_device_auth_uid = p_device_auth_uid
  where id = v_token_row.id;


  -- ----------------------------------------------------------
  -- Journal de succès
  -- ----------------------------------------------------------
  insert into internal.security_log (
    event_type,
    device_auth_uid,
    user_uuid,
    institution_id,
    detail
  )
  values (
    'activation_success',
    p_device_auth_uid,
    v_token_row.user_uuid,
    v_institution_id,
    jsonb_build_object(
      'status_code',
      'success',
      'method',
      p_method
    )
  );


  return jsonb_build_object(
    'success',
    true,
    'status_code',
    'success',
    'device_auth_uid',
    p_device_auth_uid,
    'user_uuid',
    v_token_row.user_uuid,
    'institution_id',
    v_institution_id
  );

end;
$_$;


ALTER FUNCTION "server_api"."activate_device"("p_device_auth_uid" "uuid", "p_token_hash" "text", "p_method" "text", "p_ip_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."activate_rag_document"("p_auth_uid" "uuid", "p_document_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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
  -- L'identité du back-office est obtenue à partir du JWT vérifié par
  -- l'Edge Function. L'institution n'est jamais fournie comme paramètre.
  select
    r.authorized,
    r.user_uuid,
    r.institution_id
  into
    v_authorized,
    v_admin_user_uuid,
    v_institution_id
  from server_api.check_backoffice_role(
    p_auth_uid,
    'admin'
  ) r
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

  -- Première lecture sans verrou pour connaître la clé documentaire.
  -- Le filtre institutionnel évite de révéler l'existence d'un document
  -- appartenant à une autre institution.
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

  /*
    Sérialise toutes les activations concernant le même document logique.
    Le verrou est transactionnel et automatiquement libéré au commit/rollback.
    Il évite qu'une activation concurrente laisse deux versions actives ou
    provoque une course autour de l'index unique partiel.
  */
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_institution_id || E'\x1f' || v_document_key,
      0
    )
  );

  -- Relire et verrouiller la version cible après acquisition du verrou logique.
  select
    d.document_key,
    d.status,
    d.storage_path,
    d.extraction_method
  into
    v_document_key,
    v_status,
    v_storage_path,
    v_extraction_method
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

  -- Idempotence : répéter le même appel n'altère pas l'état ni le journal.
  if v_status = 'active' then
    return pg_catalog.jsonb_build_object(
      'success', true,
      'status_code', 'already_active',
      'document_id', p_document_id
    );
  end if;

  if v_status <> 'ready' then
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
  into
    v_passage_count,
    v_missing_embedding_count
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

  -- La ligne documentaire ne doit pas pouvoir être activée si son fichier
  -- source n'existe plus physiquement dans le bucket privé.
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

  -- L'ancienne version active devient obsolète avant l'activation de la
  -- nouvelle. Toute erreur ultérieure annule les deux mises à jour.
  with obsoleted as (
    update internal.rag_documents d
    set
      status = 'obsolete',
      obsolete_at = v_now
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


ALTER FUNCTION "server_api"."activate_rag_document"("p_auth_uid" "uuid", "p_document_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "server_api"."activate_rag_document"("p_auth_uid" "uuid", "p_document_id" "uuid") IS 'Active atomiquement une version RAG après contrôle admin et complétude.';



CREATE OR REPLACE FUNCTION "server_api"."append_rag_passage_batch"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_passages" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_authorized boolean;
  v_institution_id text;
  v_job internal.rag_ingestion_jobs%rowtype;
  v_batch_size integer;
  v_processed_items integer;
begin
  select r.authorized, r.institution_id
  into v_authorized, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r
  limit 1;

  if coalesce(v_authorized, false) is not true
     or v_institution_id is null
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'admin_unauthorized'
    );
  end if;

  if p_passages is null or pg_catalog.jsonb_typeof(p_passages) <> 'array' then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_passage_batch'
    );
  end if;

  v_batch_size := pg_catalog.jsonb_array_length(p_passages);
  if v_batch_size < 1 or v_batch_size > 32 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_passage_batch_size'
    );
  end if;

  select j.*
  into v_job
  from internal.rag_ingestion_jobs j
  where j.job_id = p_job_id
    and j.institution_id = v_institution_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_found'
    );
  end if;

  if v_job.status <> 'running'
     or v_job.stage <> 'embedding'
     or v_job.worker_id <> p_worker_id
     or v_job.total_items is null
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_owned'
    );
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(p_passages) as x(
      chunk_index integer,
      content text,
      content_sha256 text,
      page_start integer,
      page_end integer,
      section_title text,
      article_reference text,
      source_reference text,
      embedding text,
      metadata jsonb
    )
    where x.chunk_index is null
       or x.chunk_index < 0
       or x.chunk_index >= v_job.total_items
       or x.embedding is null
  ) then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_passage_index'
    );
  end if;

  insert into internal.rag_passages (
    document_id,
    institution_id,
    chunk_index,
    content,
    content_sha256,
    token_count,
    page_start,
    page_end,
    section_title,
    article_reference,
    source_reference,
    embedding,
    embedding_model,
    embedding_dimensions,
    embedded_at,
    metadata
  )
  select
    v_job.document_id,
    v_institution_id,
    x.chunk_index,
    x.content,
    x.content_sha256,
    null,
    x.page_start,
    x.page_end,
    x.section_title,
    x.article_reference,
    x.source_reference,
    x.embedding::extensions.vector(1536),
    'Qwen/Qwen3-Embedding-8B',
    1536,
    pg_catalog.now(),
    coalesce(x.metadata, '{}'::jsonb)
  from pg_catalog.jsonb_to_recordset(p_passages) as x(
    chunk_index integer,
    content text,
    content_sha256 text,
    page_start integer,
    page_end integer,
    section_title text,
    article_reference text,
    source_reference text,
    embedding text,
    metadata jsonb
  )
  on conflict (document_id, chunk_index)
  do update set
    content = excluded.content,
    content_sha256 = excluded.content_sha256,
    token_count = excluded.token_count,
    page_start = excluded.page_start,
    page_end = excluded.page_end,
    section_title = excluded.section_title,
    article_reference = excluded.article_reference,
    source_reference = excluded.source_reference,
    embedding = excluded.embedding,
    embedding_model = excluded.embedding_model,
    embedding_dimensions = excluded.embedding_dimensions,
    embedded_at = excluded.embedded_at,
    metadata = excluded.metadata;

  select pg_catalog.count(*)::integer
  into v_processed_items
  from internal.rag_passages p
  where p.document_id = v_job.document_id
    and p.institution_id = v_institution_id;

  update internal.rag_ingestion_jobs j
  set
    processed_items = v_processed_items,
    locked_at = pg_catalog.now()
  where j.job_id = p_job_id;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'batch_saved',
    'processed_items', v_processed_items,
    'total_items', v_job.total_items
  );
end;
$$;


ALTER FUNCTION "server_api"."append_rag_passage_batch"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_passages" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."approve_backoffice_request"("p_request_id" "uuid", "p_institution_id" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text" DEFAULT NULL::"text", "p_existing_user_uuid" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
declare
  v_token_hash text;
  v_result jsonb;
begin
  select approval_token_hash
    into v_token_hash
    from internal.device_activation_requests
   where request_id = p_request_id
     and institution_id = p_institution_id
     and status = 'pending';

  if v_token_hash is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'request_not_pending'
    );
  end if;

  select to_jsonb(t.*) into v_result
  from server_api.approve_device_activation_request(
    p_request_id,
    v_token_hash,
    p_display_name,
    p_channel_ids,
    p_confirmed_goodbarber_user_id,
    p_existing_user_uuid
  ) t;

  return v_result;
end;
$$;


ALTER FUNCTION "server_api"."approve_backoffice_request"("p_request_id" "uuid", "p_institution_id" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."approve_device_activation_request"("p_request_id" "uuid", "p_approval_token_hash" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text" DEFAULT NULL::"text", "p_existing_user_uuid" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_request internal.device_activation_requests%rowtype;
  v_device internal.devices%rowtype;
  v_existing_user internal.users%rowtype;

  v_user_uuid uuid;
  v_display_name text;
  v_goodbarber_user_id text;

  v_channel_ids text[];
  v_invalid_channel_count integer;
  v_final_channels jsonb;

  v_auth_is_anonymous boolean;
  v_institution_active boolean;

  v_conflicting_user_uuid uuid;
  v_mode text;
begin

  -- ----------------------------------------------------------
  -- 1. Validation générale
  -- ----------------------------------------------------------

  if p_request_id is null
     or p_approval_token_hash is null
     or p_approval_token_hash !~ '^[0-9a-f]{64}$'
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_link'
    );
  end if;

  v_display_name := nullif(trim(p_display_name), '');

  v_goodbarber_user_id :=
    nullif(trim(p_confirmed_goodbarber_user_id), '');

  if v_display_name is not null
     and length(v_display_name) > 150
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_display_name'
    );
  end if;

  if v_goodbarber_user_id is not null
     and length(v_goodbarber_user_id) > 250
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_goodbarber_user_id'
    );
  end if;


  -- ----------------------------------------------------------
  -- 2. Verrouillage et validation du lien
  -- ----------------------------------------------------------

  select r.*
  into v_request
  from internal.device_activation_requests r
  where r.request_id = p_request_id
    and r.approval_token_hash = p_approval_token_hash
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_link'
    );
  end if;

  if v_request.status = 'pending'
     and v_request.expires_at <= now()
  then
    update internal.device_activation_requests
    set
      status = 'expired',
      decided_at = now(),
      decision_detail =
        coalesce(decision_detail, '{}'::jsonb)
        || jsonb_build_object('reason', 'link_expired')
    where request_id = v_request.request_id;

    insert into internal.security_log (
      event_type,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'device_activation_request_expired',
      v_request.device_auth_uid,
      v_request.institution_id,
      jsonb_build_object(
        'request_id', v_request.request_id
      )
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'expired'
    );
  end if;

  if v_request.status <> 'pending' then
    return jsonb_build_object(
      'success', false,
      'status_code', 'request_not_pending',
      'request_status', v_request.status
    );
  end if;


  -- ----------------------------------------------------------
  -- 3. Vérification de l'institution et du compte Auth
  -- ----------------------------------------------------------

  select i.active
  into v_institution_active
  from internal.institutions i
  where i.institution_id = v_request.institution_id;

  if not found or v_institution_active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'institution_inactive'
    );
  end if;

  select u.is_anonymous
  into v_auth_is_anonymous
  from auth.users u
  where u.id = v_request.device_auth_uid;

  if not found or v_auth_is_anonymous is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'anonymous_device_missing'
    );
  end if;


  -- ----------------------------------------------------------
  -- 4. Vérification de l'appareil
  -- ----------------------------------------------------------

  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_request.device_auth_uid
  for update;

  if found then
    if v_device.revoked_at is not null then
      return jsonb_build_object(
        'success', false,
        'status_code', 'device_revoked'
      );
    end if;

    if v_device.user_uuid is not null
       or v_device.activated_at is not null
    then
      return jsonb_build_object(
        'success', false,
        'status_code', 'device_already_activated'
      );
    end if;
  end if;


  -- ----------------------------------------------------------
  -- 5. Nouveau collaborateur
  -- ----------------------------------------------------------

  if p_existing_user_uuid is null then
    v_mode := 'new_user';

    if v_display_name is null then
      return jsonb_build_object(
        'success', false,
        'status_code', 'display_name_required'
      );
    end if;

    -- Nettoyage et dédoublonnage des canaux reçus.
    select coalesce(
      array_agg(distinct trim(t.channel_id)),
      array[]::text[]
    )
    into v_channel_ids
    from unnest(
      coalesce(p_channel_ids, array[]::text[])
    ) as t(channel_id)
    where trim(t.channel_id) <> '';

    -- Le canal Institution est obligatoire.
    if not ('all' = any(v_channel_ids)) then
      v_channel_ids := array_append(v_channel_ids, 'all');
    end if;

    if cardinality(v_channel_ids) > 50 then
      return jsonb_build_object(
        'success', false,
        'status_code', 'too_many_channels'
      );
    end if;

    select count(*)
    into v_invalid_channel_count
    from unnest(v_channel_ids) as selected(channel_id)
    left join internal.channels c
      on c.institution_id = v_request.institution_id
     and c.channel_id = selected.channel_id
     and c.enabled is true
    where c.channel_id is null;

    if v_invalid_channel_count > 0 then
      return jsonb_build_object(
        'success', false,
        'status_code', 'invalid_channel_selection'
      );
    end if;

    -- Un identifiant GoodBarber confirmé ne peut appartenir
    -- qu'à une seule personne dans l'institution.
    if v_goodbarber_user_id is not null then
      select u.user_uuid
      into v_conflicting_user_uuid
      from internal.users u
      where u.institution_id = v_request.institution_id
        and u.goodbarber_user_id = v_goodbarber_user_id
      limit 1;

      if found then
        return jsonb_build_object(
          'success', false,
          'status_code', 'goodbarber_user_already_exists',
          'existing_user_uuid', v_conflicting_user_uuid
        );
      end if;
    end if;

    begin
      insert into internal.users (
        display_name,
        active,
        institution_id,
        goodbarber_user_id
      )
      values (
        v_display_name,
        true,
        v_request.institution_id,
        v_goodbarber_user_id
      )
      returning user_uuid into v_user_uuid;

    exception
      when unique_violation then
        select u.user_uuid
        into v_conflicting_user_uuid
        from internal.users u
        where u.institution_id = v_request.institution_id
          and u.goodbarber_user_id = v_goodbarber_user_id
        limit 1;

        return jsonb_build_object(
          'success', false,
          'status_code', 'goodbarber_user_already_exists',
          'existing_user_uuid', v_conflicting_user_uuid
        );
    end;

    insert into internal.user_channel_memberships (
      user_uuid,
      institution_id,
      channel_id,
      granted_by
    )
    select
      v_user_uuid,
      v_request.institution_id,
      selected.channel_id,
      null
    from unnest(v_channel_ids) as selected(channel_id)
    on conflict do nothing;


  -- ----------------------------------------------------------
  -- 6. Collaborateur existant
  -- ----------------------------------------------------------

  else
    v_mode := 'existing_user';

    select u.*
    into v_existing_user
    from internal.users u
    where u.user_uuid = p_existing_user_uuid
      and u.institution_id = v_request.institution_id
    for update;

    if not found then
      return jsonb_build_object(
        'success', false,
        'status_code', 'existing_user_not_found'
      );
    end if;

    if v_existing_user.active is not true then
      return jsonb_build_object(
        'success', false,
        'status_code', 'existing_user_inactive'
      );
    end if;

    v_user_uuid := v_existing_user.user_uuid;
    v_display_name := v_existing_user.display_name;

    if v_goodbarber_user_id is not null then
      if v_existing_user.goodbarber_user_id is not null
         and v_existing_user.goodbarber_user_id
             <> v_goodbarber_user_id
      then
        return jsonb_build_object(
          'success', false,
          'status_code', 'goodbarber_user_id_mismatch'
        );
      end if;

      select u.user_uuid
      into v_conflicting_user_uuid
      from internal.users u
      where u.institution_id = v_request.institution_id
        and u.goodbarber_user_id = v_goodbarber_user_id
        and u.user_uuid <> v_user_uuid
      limit 1;

      if found then
        return jsonb_build_object(
          'success', false,
          'status_code', 'goodbarber_user_already_exists',
          'existing_user_uuid', v_conflicting_user_uuid
        );
      end if;

      if v_existing_user.goodbarber_user_id is null then
        update internal.users
        set goodbarber_user_id = v_goodbarber_user_id
        where user_uuid = v_user_uuid;
      end if;
    end if;

    -- Le collaborateur conserve ses canaux existants.
    -- On garantit seulement son accès au canal Institution.
    insert into internal.user_channel_memberships (
      user_uuid,
      institution_id,
      channel_id,
      granted_by
    )
    values (
      v_user_uuid,
      v_request.institution_id,
      'all',
      null
    )
    on conflict do nothing;
  end if;


  -- ----------------------------------------------------------
  -- 7. Activation de l'appareil
  -- ----------------------------------------------------------

  if v_device.device_auth_uid is null then
    insert into internal.devices (
      device_auth_uid,
      user_uuid,
      activated_at,
      last_seen_at
    )
    values (
      v_request.device_auth_uid,
      v_user_uuid,
      now(),
      now()
    );
  else
    update internal.devices
    set
      user_uuid = v_user_uuid,
      activated_at = now(),
      last_seen_at = now()
    where device_auth_uid = v_request.device_auth_uid;
  end if;


  -- ----------------------------------------------------------
  -- 8. Consommation définitive de la demande
  -- ----------------------------------------------------------

  update internal.device_activation_requests
  set
    status = 'approved',
    decided_at = now(),
    approved_user_uuid = v_user_uuid,
    decision_detail = jsonb_build_object(
      'mode', v_mode,
      'confirmed_display_name', v_display_name,
      'confirmed_goodbarber_user_id', v_goodbarber_user_id
    )
  where request_id = v_request.request_id;


  -- ----------------------------------------------------------
  -- 9. Canaux finaux et journalisation
  -- ----------------------------------------------------------

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'channel_id', c.channel_id,
        'label', c.label
      )
      order by
        case when c.channel_id = 'all' then 0 else 1 end,
        lower(c.label)
    ),
    '[]'::jsonb
  )
  into v_final_channels
  from internal.user_channel_memberships m
  join internal.channels c
    on c.institution_id = m.institution_id
   and c.channel_id = m.channel_id
  where m.user_uuid = v_user_uuid
    and m.institution_id = v_request.institution_id
    and c.enabled is true;

  insert into internal.security_log (
    event_type,
    user_uuid,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'device_activation_approved',
    v_user_uuid,
    v_request.device_auth_uid,
    v_request.institution_id,
    jsonb_build_object(
      'request_id', v_request.request_id,
      'mode', v_mode,
      'channels', v_final_channels
    )
  );

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',

    'request_id', v_request.request_id,
    'user_uuid', v_user_uuid,
    'display_name', v_display_name,
    'mode', v_mode,
    'channels', v_final_channels
  );
end;
$_$;


ALTER FUNCTION "server_api"."approve_device_activation_request"("p_request_id" "uuid", "p_approval_token_hash" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."cancel_device_activation_request"("p_request_id" "uuid", "p_device_auth_uid" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_request internal.device_activation_requests%rowtype;
  v_reason text;
begin
  v_reason := left(
    coalesce(nullif(trim(p_reason), ''), 'server_cancellation'),
    100
  );

  select r.*
  into v_request
  from internal.device_activation_requests r
  where r.request_id = p_request_id
    and r.device_auth_uid = p_device_auth_uid
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'request_not_found'
    );
  end if;

  if v_request.status <> 'pending' then
    return jsonb_build_object(
      'success', false,
      'status_code', 'request_not_pending',
      'request_status', v_request.status
    );
  end if;

  update internal.device_activation_requests
  set
    status = 'cancelled',
    decided_at = now(),
    decision_detail =
      coalesce(decision_detail, '{}'::jsonb)
      || jsonb_build_object('reason', v_reason)
  where request_id = v_request.request_id;

  insert into internal.security_log (
    event_type,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'device_activation_request_cancelled',
    v_request.device_auth_uid,
    v_request.institution_id,
    jsonb_build_object(
      'request_id', v_request.request_id,
      'reason', v_reason
    )
  );

  return jsonb_build_object(
    'success', true,
    'status_code', 'success'
  );
end;
$$;


ALTER FUNCTION "server_api"."cancel_device_activation_request"("p_request_id" "uuid", "p_device_auth_uid" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."check_backoffice_role"("p_auth_uid" "uuid", "p_required_role" "text" DEFAULT 'admin'::"text") RETURNS TABLE("authorized" boolean, "user_uuid" "uuid", "institution_id" "text", "display_name" "text", "role" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select
    (r.role is not null) as authorized,
    i.user_uuid,
    i.institution_id,
    i.display_name,
    r.role
  from server_api.get_backoffice_identity(p_auth_uid) i
  left join internal.user_roles r
    on r.user_uuid = i.user_uuid
   and r.role = p_required_role
$$;


ALTER FUNCTION "server_api"."check_backoffice_role"("p_auth_uid" "uuid", "p_required_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."complete_rag_ingestion"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_extraction_method" "text", "p_extraction_version" "text", "p_page_count" integer, "p_extraction_metadata" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_job internal.rag_ingestion_jobs%rowtype;
  v_actual_count integer;
  v_missing_embeddings integer;
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

  select j.*
  into v_job
  from internal.rag_ingestion_jobs j
  where j.job_id = p_job_id
    and j.institution_id = v_institution_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_found'
    );
  end if;

  if v_job.status <> 'running'
     or v_job.stage <> 'embedding'
     or v_job.worker_id <> p_worker_id
     or v_job.total_items is null
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_owned'
    );
  end if;

  select
    pg_catalog.count(*)::integer,
    pg_catalog.count(*) filter (where p.embedding is null)::integer
  into v_actual_count, v_missing_embeddings
  from internal.rag_passages p
  where p.document_id = v_job.document_id
    and p.institution_id = v_institution_id;

  if v_actual_count <> v_job.total_items or v_missing_embeddings <> 0 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'ingestion_incomplete',
      'actual_count', v_actual_count,
      'expected_count', v_job.total_items,
      'missing_embeddings', v_missing_embeddings
    );
  end if;

  if p_extraction_method is null
     or pg_catalog.btrim(p_extraction_method) = ''
     or pg_catalog.char_length(p_extraction_method) > 50
     or p_extraction_version is null
     or pg_catalog.btrim(p_extraction_version) = ''
     or pg_catalog.char_length(p_extraction_version) > 50
     or (p_page_count is not null and p_page_count not between 1 and 250)
     or p_extraction_metadata is null
     or pg_catalog.jsonb_typeof(p_extraction_metadata) <> 'object'
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_extraction_metadata'
    );
  end if;

  update internal.rag_documents d
  set
    status = 'ready',
    extraction_method = p_extraction_method,
    extraction_version = p_extraction_version,
    page_count = p_page_count,
    extraction_metadata =
      coalesce(p_extraction_metadata, '{}'::jsonb),
    error_message = null
  where d.document_id = v_job.document_id
    and d.institution_id = v_institution_id
    and d.status = 'processing';

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_document_state'
    );
  end if;

  update internal.rag_ingestion_jobs j
  set
    status = 'succeeded',
    stage = 'completed',
    processed_items = v_actual_count,
    worker_id = null,
    locked_at = null,
    finished_at = v_now
  where j.job_id = p_job_id;

  insert into internal.security_log (
    event_type,
    user_uuid,
    institution_id,
    actor_admin_uuid,
    detail
  )
  values (
    'rag_document_ingested',
    null,
    v_institution_id,
    v_admin_user_uuid,
    pg_catalog.jsonb_build_object(
      'document_id', v_job.document_id,
      'job_id', p_job_id,
      'passage_count', v_actual_count,
      'extraction_method', p_extraction_method
    )
  );

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'ready',
    'document_id', v_job.document_id,
    'job_id', p_job_id,
    'passage_count', v_actual_count
  );
end;
$$;


ALTER FUNCTION "server_api"."complete_rag_ingestion"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_extraction_method" "text", "p_extraction_version" "text", "p_page_count" integer, "p_extraction_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."create_device_activation_request"("p_device_auth_uid" "uuid", "p_institution_id" "text", "p_suggested_display_name" "text", "p_suggested_email" "text", "p_suggested_goodbarber_user_id" "text", "p_suggested_groups" "jsonb", "p_approval_token_hash" "text", "p_ip_hash" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  -- Durée de validité du lien envoyé à l'administrateur
  c_link_lifetime constant interval := interval '24 hours';

  -- Limites par fenêtre d'une heure
  c_device_limit     constant integer := 3;
  c_ip_limit         constant integer := 30;
  c_institution_limit constant integer := 300;

  v_window_start timestamptz := date_trunc('hour', now());
  v_rate_count integer;

  v_is_anonymous boolean;

  v_institution_label text;
  v_institution_active boolean;
  v_admin_email text;

  v_device internal.devices%rowtype;

  v_request_id uuid;
  v_expires_at timestamptz := now() + c_link_lifetime;
begin

  -- ----------------------------------------------------------
  -- 1. Validation des paramètres
  -- ----------------------------------------------------------

  if p_device_auth_uid is null
     or p_institution_id is null
     or length(trim(p_institution_id)) not between 1 and 100
     or p_suggested_display_name is null
     or length(trim(p_suggested_display_name)) not between 1 and 150
     or (
       p_suggested_email is not null
       and length(trim(p_suggested_email)) > 320
     )
     or (
       p_suggested_goodbarber_user_id is not null
       and length(trim(p_suggested_goodbarber_user_id)) > 250
     )
     or jsonb_typeof(coalesce(p_suggested_groups, '[]'::jsonb)) <> 'array'
     or octet_length(coalesce(p_suggested_groups, '[]'::jsonb)::text) > 8192
     or p_approval_token_hash is null
     or p_approval_token_hash !~ '^[0-9a-f]{64}$'
     or (
       p_ip_hash is not null
       and p_ip_hash !~ '^[0-9a-f]{64}$'
     )
  then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'device_activation_request_failed',
      p_device_auth_uid,
      p_institution_id,
      jsonb_build_object('status_code', 'invalid_params')
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_params'
    );
  end if;


  -- ----------------------------------------------------------
  -- 2. Limite : 3 demandes par appareil et par heure
  -- ----------------------------------------------------------

  insert into internal.rate_limits (
    subject_type,
    subject_id,
    window_start,
    count,
    updated_at
  )
  values (
    'activation',
    'request-device:' || p_device_auth_uid::text,
    v_window_start,
    1,
    now()
  )
  on conflict (
    subject_type,
    subject_id,
    window_start
  )
  do update
  set
    count = internal.rate_limits.count + 1,
    updated_at = now()
  returning count into v_rate_count;

  if v_rate_count > c_device_limit then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'device_activation_request_failed',
      p_device_auth_uid,
      p_institution_id,
      jsonb_build_object(
        'status_code', 'rate_limited',
        'scope', 'device'
      )
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'rate_limited'
    );
  end if;


  -- ----------------------------------------------------------
  -- 3. Limite par IP hachée
  -- ----------------------------------------------------------

  if p_ip_hash is not null then
    insert into internal.rate_limits (
      subject_type,
      subject_id,
      window_start,
      count,
      updated_at
    )
    values (
      'activation',
      'request-ip:' || p_ip_hash,
      v_window_start,
      1,
      now()
    )
    on conflict (
      subject_type,
      subject_id,
      window_start
    )
    do update
    set
      count = internal.rate_limits.count + 1,
      updated_at = now()
    returning count into v_rate_count;

    if v_rate_count > c_ip_limit then
      insert into internal.security_log (
        event_type,
        device_auth_uid,
        institution_id,
        detail
      )
      values (
        'device_activation_request_failed',
        p_device_auth_uid,
        p_institution_id,
        jsonb_build_object(
          'status_code', 'rate_limited',
          'scope', 'ip'
        )
      );

      return jsonb_build_object(
        'success', false,
        'status_code', 'rate_limited'
      );
    end if;
  end if;


  -- ----------------------------------------------------------
  -- 4. Limite par institution
  -- ----------------------------------------------------------

  insert into internal.rate_limits (
    subject_type,
    subject_id,
    window_start,
    count,
    updated_at
  )
  values (
    'activation',
    'request-institution:' || trim(p_institution_id),
    v_window_start,
    1,
    now()
  )
  on conflict (
    subject_type,
    subject_id,
    window_start
  )
  do update
  set
    count = internal.rate_limits.count + 1,
    updated_at = now()
  returning count into v_rate_count;

  if v_rate_count > c_institution_limit then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'device_activation_request_failed',
      p_device_auth_uid,
      p_institution_id,
      jsonb_build_object(
        'status_code', 'rate_limited',
        'scope', 'institution'
      )
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'rate_limited'
    );
  end if;


  -- ----------------------------------------------------------
  -- 5. Vérification du compte Supabase Anonymous Auth
  -- ----------------------------------------------------------

  select u.is_anonymous
  into v_is_anonymous
  from auth.users u
  where u.id = p_device_auth_uid;

  if not found then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'device_activation_request_failed',
      p_device_auth_uid,
      p_institution_id,
      jsonb_build_object('status_code', 'auth_uid_unknown')
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'auth_uid_unknown'
    );
  end if;

  if v_is_anonymous is not true then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'device_activation_request_failed',
      p_device_auth_uid,
      p_institution_id,
      jsonb_build_object('status_code', 'device_not_anonymous')
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'device_not_anonymous'
    );
  end if;


  -- ----------------------------------------------------------
  -- 6. Vérification de l'institution et de son adresse admin
  -- ----------------------------------------------------------

  select
    i.label,
    i.active,
    i.activation_admin_email
  into
    v_institution_label,
    v_institution_active,
    v_admin_email
  from internal.institutions i
  where i.institution_id = trim(p_institution_id);

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'institution_unknown'
    );
  end if;

  if v_institution_active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'institution_inactive'
    );
  end if;

  if v_admin_email is null or length(trim(v_admin_email)) < 3 then
    insert into internal.security_log (
      event_type,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'device_activation_request_failed',
      p_device_auth_uid,
      p_institution_id,
      jsonb_build_object('status_code', 'admin_email_missing')
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'admin_email_missing'
    );
  end if;


  -- ----------------------------------------------------------
  -- 7. Verrou transactionnel propre à l'appareil
  -- ----------------------------------------------------------

  perform pg_advisory_xact_lock(
    hashtextextended(
      'device_activation_request:' || p_device_auth_uid::text,
      0
    )
  );


  -- ----------------------------------------------------------
  -- 8. Vérification de l'état actuel de l'appareil
  -- ----------------------------------------------------------

  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = p_device_auth_uid
  for update;

  if found then
    if v_device.revoked_at is not null then
      return jsonb_build_object(
        'success', false,
        'status_code', 'device_revoked'
      );
    end if;

    if v_device.activated_at is not null
       or v_device.user_uuid is not null
    then
      return jsonb_build_object(
        'success', false,
        'status_code', 'device_already_activated'
      );
    end if;
  end if;


  -- ----------------------------------------------------------
  -- 9. Expiration automatique des anciennes demandes
  -- ----------------------------------------------------------

  update internal.device_activation_requests
  set
    status = 'expired',
    decided_at = now(),
    decision_detail = coalesce(decision_detail, '{}'::jsonb)
      || jsonb_build_object('reason', 'automatic_expiration')
  where device_auth_uid = p_device_auth_uid
    and status = 'pending'
    and expires_at <= now();


  -- ----------------------------------------------------------
  -- 10. Une nouvelle demande invalide le lien précédent
  -- ----------------------------------------------------------

  update internal.device_activation_requests
  set
    status = 'cancelled',
    decided_at = now(),
    decision_detail = coalesce(decision_detail, '{}'::jsonb)
      || jsonb_build_object('reason', 'superseded_by_new_request')
  where device_auth_uid = p_device_auth_uid
    and status = 'pending';


  -- ----------------------------------------------------------
  -- 11. Création de la nouvelle demande
  -- ----------------------------------------------------------

  insert into internal.device_activation_requests (
    institution_id,
    device_auth_uid,
    suggested_display_name,
    suggested_email,
    suggested_goodbarber_user_id,
    suggested_groups,
    approval_token_hash,
    status,
    expires_at
  )
  values (
    trim(p_institution_id),
    p_device_auth_uid,
    trim(p_suggested_display_name),
    nullif(trim(p_suggested_email), ''),
    nullif(trim(p_suggested_goodbarber_user_id), ''),
    coalesce(p_suggested_groups, '[]'::jsonb),
    p_approval_token_hash,
    'pending',
    v_expires_at
  )
  returning request_id into v_request_id;


  -- ----------------------------------------------------------
  -- 12. Journalisation
  -- ----------------------------------------------------------

  insert into internal.security_log (
    event_type,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'device_activation_requested',
    p_device_auth_uid,
    trim(p_institution_id),
    jsonb_build_object(
      'request_id', v_request_id,
      'expires_at', v_expires_at,
      'has_suggested_email', p_suggested_email is not null,
      'suggested_groups_count',
        jsonb_array_length(coalesce(p_suggested_groups, '[]'::jsonb))
    )
  );


  -- Réponse destinée uniquement à l'Edge Function service_role.
  return jsonb_build_object(
    'success', true,
    'status_code', 'success',
    'request_id', v_request_id,
    'expires_at', v_expires_at,
    'institution_id', trim(p_institution_id),
    'institution_label', v_institution_label,
    'admin_email', trim(v_admin_email)
  );

end;
$_$;


ALTER FUNCTION "server_api"."create_device_activation_request"("p_device_auth_uid" "uuid", "p_institution_id" "text", "p_suggested_display_name" "text", "p_suggested_email" "text", "p_suggested_goodbarber_user_id" "text", "p_suggested_groups" "jsonb", "p_approval_token_hash" "text", "p_ip_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."delete_chat_message"("p_message_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_uid uuid;
  v_device internal.devices%rowtype;
  v_user internal.users%rowtype;
  v_message public.gb_78487711_chat_messages%rowtype;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'authentication_required'
    );
  end if;

  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_unknown'
    );
  end if;

  if v_device.revoked_at is not null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_revoked'
    );
  end if;

  if v_device.activated_at is null
     or v_device.user_uuid is null
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_not_activated'
    );
  end if;

  select u.*
  into v_user
  from internal.users u
  where u.user_uuid = v_device.user_uuid;

  if not found or v_user.active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_inactive'
    );
  end if;

  select m.*
  into v_message
  from public.gb_78487711_chat_messages m
  where m.id = p_message_id
    and m.institution_id = v_user.institution_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_not_found'
    );
  end if;

  if v_message.author_user_uuid
     is distinct from v_user.user_uuid
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'not_message_author'
    );
  end if;

  if v_message.deleted is true then
    return jsonb_build_object(
      'success', true,
      'status_code', 'already_deleted'
    );
  end if;

  if not exists (
    select 1
    from internal.channels c
    join internal.user_channel_memberships membership
      on membership.institution_id = c.institution_id
     and membership.channel_id = c.channel_id
    where c.institution_id = v_user.institution_id
      and c.channel_id = v_message.group_id
      and c.enabled is true
      and membership.user_uuid = v_user.user_uuid
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_access_denied'
    );
  end if;

  /*
   * Retire les réactions attachées au message.
   */
  delete from public.gb_78487711_chat_reactions
  where message_id = v_message.id
    and institution_id = v_message.institution_id;

  /*
   * Désépingle le message s’il était épinglé.
   */
  update public.gb_78487711_chat_pins
  set
    message_id = null,
    pinned_by_user_id = null,
    pinned_by_user_uuid = null,
    pinned_at = null,
    pinned_until = null
  where institution_id = v_message.institution_id
    and group_id = v_message.group_id
    and message_id = v_message.id;

  /*
   * Le contenu supprimé ne doit pas rester visible
   * dans les aperçus des réponses.
   */
  update public.gb_78487711_chat_messages
  set reply_to_body = 'Message supprimé'
  where reply_to_id = v_message.id
    and institution_id = v_message.institution_id
    and group_id = v_message.group_id;

  /*
   * Suppression logique avec effacement réel du contenu.
   */
  update public.gb_78487711_chat_messages
  set
    body = '',
    edited = false,
    deleted = true,
    deleted_at = now()
  where id = v_message.id
  returning *
  into v_message;

  update internal.devices
  set last_seen_at = now()
  where device_auth_uid = v_auth_uid;

  insert into internal.security_log (
    event_type,
    user_uuid,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'chat_message_deleted',
    v_user.user_uuid,
    v_auth_uid,
    v_user.institution_id,
    jsonb_build_object(
      'message_id', v_message.id,
      'channel_id', v_message.group_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',
    'message_id', v_message.id,
    'deleted_at', v_message.deleted_at
  );
end;
$$;


ALTER FUNCTION "server_api"."delete_chat_message"("p_message_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."edit_chat_message"("p_message_id" "uuid", "p_body" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_uid uuid;
  v_device internal.devices%rowtype;
  v_user internal.users%rowtype;
  v_message public.gb_78487711_chat_messages%rowtype;
  v_body text;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'authentication_required'
    );
  end if;

  v_body := btrim(
    replace(
      replace(coalesce(p_body, ''), E'\r\n', E'\n'),
      E'\r',
      E'\n'
    )
  );

  if length(v_body) < 1 then
    return jsonb_build_object(
      'success', false,
      'status_code', 'empty_message'
    );
  end if;

  if length(v_body) > 4000 then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_too_long',
      'maximum_length', 4000
    );
  end if;

  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_unknown'
    );
  end if;

  if v_device.revoked_at is not null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_revoked'
    );
  end if;

  if v_device.activated_at is null
     or v_device.user_uuid is null
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_not_activated'
    );
  end if;

  select u.*
  into v_user
  from internal.users u
  where u.user_uuid = v_device.user_uuid;

  if not found or v_user.active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_inactive'
    );
  end if;

  select m.*
  into v_message
  from public.gb_78487711_chat_messages m
  where m.id = p_message_id
    and m.institution_id = v_user.institution_id
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_not_found'
    );
  end if;

  if v_message.author_user_uuid
     is distinct from v_user.user_uuid
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'not_message_author'
    );
  end if;

  if v_message.deleted is true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_deleted'
    );
  end if;

  if not exists (
    select 1
    from internal.channels c
    join internal.user_channel_memberships membership
      on membership.institution_id = c.institution_id
     and membership.channel_id = c.channel_id
    where c.institution_id = v_user.institution_id
      and c.channel_id = v_message.group_id
      and c.enabled is true
      and membership.user_uuid = v_user.user_uuid
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_access_denied'
    );
  end if;

  if v_message.body = v_body then
    return jsonb_build_object(
      'success', true,
      'status_code', 'unchanged',
      'message', to_jsonb(v_message)
    );
  end if;

  update public.gb_78487711_chat_messages
  set
    body = v_body,
    edited = true
  where id = v_message.id
  returning *
  into v_message;

  /*
   * Met à jour l’aperçu du message dans les réponses
   * déjà envoyées.
   */
  update public.gb_78487711_chat_messages
  set reply_to_body = v_body
  where reply_to_id = v_message.id
    and institution_id = v_message.institution_id
    and group_id = v_message.group_id
    and deleted is not true;

  update internal.devices
  set last_seen_at = now()
  where device_auth_uid = v_auth_uid;

  insert into internal.security_log (
    event_type,
    user_uuid,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'chat_message_edited',
    v_user.user_uuid,
    v_auth_uid,
    v_user.institution_id,
    jsonb_build_object(
      'message_id', v_message.id,
      'channel_id', v_message.group_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',
    'message', to_jsonb(v_message)
  );
end;
$$;


ALTER FUNCTION "server_api"."edit_chat_message"("p_message_id" "uuid", "p_body" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."fail_rag_ingestion"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_error_code" "text", "p_error_message" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_job internal.rag_ingestion_jobs%rowtype;
  v_error_code text;
  v_error_message text;
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

  select j.*
  into v_job
  from internal.rag_ingestion_jobs j
  where j.job_id = p_job_id
    and j.institution_id = v_institution_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_found'
    );
  end if;

  if v_job.status = 'failed' then
    return pg_catalog.jsonb_build_object(
      'success', true,
      'status_code', 'already_failed'
    );
  end if;

  if v_job.status <> 'running' or v_job.worker_id <> p_worker_id then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_owned'
    );
  end if;

  v_error_code := pg_catalog.left(
    coalesce(nullif(p_error_code, ''), 'unknown_error'),
    120
  );
  v_error_message := pg_catalog.left(
    coalesce(
      nullif(p_error_message, ''),
      'Traitement interrompu.'
    ),
    1000
  );

  update internal.rag_ingestion_jobs j
  set
    status = 'failed',
    last_error_code = v_error_code,
    last_error_message = v_error_message,
    worker_id = null,
    locked_at = null,
    finished_at = pg_catalog.now()
  where j.job_id = p_job_id;

  update internal.rag_documents d
  set
    status = 'error',
    error_message = v_error_message
  where d.document_id = v_job.document_id
    and d.institution_id = v_institution_id;

  insert into internal.security_log (
    event_type,
    user_uuid,
    institution_id,
    actor_admin_uuid,
    detail
  )
  values (
    'rag_document_ingestion_failed',
    null,
    v_institution_id,
    v_admin_user_uuid,
    pg_catalog.jsonb_build_object(
      'document_id', v_job.document_id,
      'job_id', p_job_id,
      'error_code', v_error_code
    )
  );

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'failed'
  );
end;
$$;


ALTER FUNCTION "server_api"."fail_rag_ingestion"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_error_code" "text", "p_error_message" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."get_backoffice_dashboard"("p_institution_id" "text") RETURNS TABLE("user_uuid" "uuid", "display_name" "text", "active" boolean, "goodbarber_user_id" "text", "created_at" timestamp with time zone, "channels" "text"[], "device_count" bigint, "last_seen_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select
    u.user_uuid,
    u.display_name,
    u.active,
    u.goodbarber_user_id,
    u.created_at,
    coalesce(
      array_agg(distinct c.label order by c.label) filter (where c.label is not null),
      array[]::text[]
    ) as channels,
    count(distinct d.device_auth_uid) filter (where d.revoked_at is null) as device_count,
    max(d.last_seen_at) as last_seen_at
  from internal.users u
  left join internal.user_channel_memberships m
    on m.user_uuid = u.user_uuid
   and m.institution_id = u.institution_id
  left join internal.channels c
    on c.channel_id = m.channel_id
   and c.institution_id = m.institution_id
  left join internal.devices d
    on d.user_uuid = u.user_uuid
  where u.institution_id = p_institution_id
  group by u.user_uuid, u.display_name, u.active, u.goodbarber_user_id, u.created_at
  order by u.display_name;
$$;


ALTER FUNCTION "server_api"."get_backoffice_dashboard"("p_institution_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."get_backoffice_identity"("p_auth_uid" "uuid") RETURNS TABLE("user_uuid" "uuid", "institution_id" "text", "display_name" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select
    u.user_uuid,
    u.institution_id,
    u.display_name
  from internal.backoffice_auth_links l
  join internal.users u
    on u.user_uuid = l.user_uuid
   and u.institution_id = l.institution_id
  where l.backoffice_auth_uid = p_auth_uid
    and l.revoked_at is null
    and u.active is true
  limit 1;
$$;


ALTER FUNCTION "server_api"."get_backoffice_identity"("p_auth_uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."get_backoffice_pending_requests"("p_institution_id" "text") RETURNS TABLE("request_id" "uuid", "suggested_display_name" "text", "suggested_email" "text", "suggested_goodbarber_user_id" "text", "suggested_groups" "jsonb", "created_at" timestamp with time zone, "expires_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select
    r.request_id,
    r.suggested_display_name,
    r.suggested_email,
    r.suggested_goodbarber_user_id,
    r.suggested_groups,
    r.created_at,
    r.expires_at
  from internal.device_activation_requests r
  where r.institution_id = p_institution_id
    and r.status = 'pending'
    and r.expires_at > now()
  order by r.created_at desc;
$$;


ALTER FUNCTION "server_api"."get_backoffice_pending_requests"("p_institution_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."get_backoffice_request_detail"("p_request_id" "uuid", "p_institution_id" "text") RETURNS TABLE("request_id" "uuid", "suggested_display_name" "text", "suggested_email" "text", "suggested_goodbarber_user_id" "text", "suggested_groups" "jsonb", "created_at" timestamp with time zone, "expires_at" timestamp with time zone, "channels" "jsonb", "existing_users" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'internal', 'pg_temp'
    AS $$
  select
    r.request_id,
    r.suggested_display_name,
    r.suggested_email,
    r.suggested_goodbarber_user_id,
    r.suggested_groups,
    r.created_at,
    r.expires_at,
    (
      select coalesce(jsonb_agg(jsonb_build_object(
        'channel_id', c.channel_id,
        'label', c.label
      ) order by c.label), '[]'::jsonb)
      from internal.channels c
      where c.institution_id = p_institution_id
        and c.enabled is true
    ) as channels,
    (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_uuid', u.user_uuid,
        'display_name', u.display_name,
        'goodbarber_user_id', u.goodbarber_user_id
      ) order by u.display_name), '[]'::jsonb)
      from internal.users u
      where u.institution_id = p_institution_id
        and u.active is true
    ) as existing_users
  from internal.device_activation_requests r
  where r.request_id = p_request_id
    and r.institution_id = p_institution_id
    and r.status = 'pending';
$$;


ALTER FUNCTION "server_api"."get_backoffice_request_detail"("p_request_id" "uuid", "p_institution_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."get_chat_context"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_uid uuid;
  v_device internal.devices%rowtype;
  v_user internal.users%rowtype;
  v_pending internal.device_activation_requests%rowtype;
  v_channels jsonb := '[]'::jsonb;
  v_can_pin boolean := false;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'authentication_required'
    );
  end if;

  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_auth_uid;

  if not found then
    select r.*
    into v_pending
    from internal.device_activation_requests r
    where r.device_auth_uid = v_auth_uid
      and r.status = 'pending'
      and r.expires_at > now()
    order by r.created_at desc
    limit 1;

    if found then
      return jsonb_build_object(
        'success', true,
        'status_code', 'pending_activation',
        'request_id', v_pending.request_id,
        'expires_at', v_pending.expires_at
      );
    end if;

    return jsonb_build_object(
      'success', true,
      'status_code', 'activation_required'
    );
  end if;

  if v_device.revoked_at is not null then
    return jsonb_build_object(
      'success', true,
      'status_code', 'device_revoked',
      'revoked_reason', v_device.revoked_reason
    );
  end if;

  if v_device.activated_at is null
     or v_device.user_uuid is null
  then
    select r.*
    into v_pending
    from internal.device_activation_requests r
    where r.device_auth_uid = v_auth_uid
      and r.status = 'pending'
      and r.expires_at > now()
    order by r.created_at desc
    limit 1;

    if found then
      return jsonb_build_object(
        'success', true,
        'status_code', 'pending_activation',
        'request_id', v_pending.request_id,
        'expires_at', v_pending.expires_at
      );
    end if;

    return jsonb_build_object(
      'success', true,
      'status_code', 'activation_required'
    );
  end if;

  select u.*
  into v_user
  from internal.users u
  where u.user_uuid = v_device.user_uuid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_unknown'
    );
  end if;

  if v_user.active is not true then
    return jsonb_build_object(
      'success', true,
      'status_code', 'user_inactive',
      'user_uuid', v_user.user_uuid,
      'display_name', v_user.display_name,
      'institution_id', v_user.institution_id
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', c.channel_id,
        'label', c.label
      )
      order by
        case c.channel_id
          when 'all' then 0
          when 'cadres' then 1
          when 'soins' then 2
          when 'intendance' then 3
          when 'animation' then 4
          when 'cuisine' then 5
          when 'administration' then 6
          when 'technique' then 7
          when 'cerisiers' then 8
          when 'codi' then 9
          else 100
        end,
        c.label
    ),
    '[]'::jsonb
  )
  into v_channels
  from internal.user_channel_memberships m
  join internal.channels c
    on c.institution_id = m.institution_id
   and c.channel_id = m.channel_id
  where m.user_uuid = v_user.user_uuid
    and m.institution_id = v_user.institution_id
    and c.enabled is true;

  select exists (
    select 1
    from internal.user_channel_memberships m
    join internal.channels c
      on c.institution_id = m.institution_id
     and c.channel_id = m.channel_id
    where m.user_uuid = v_user.user_uuid
      and m.institution_id = v_user.institution_id
      and m.channel_id = 'cadres'
      and c.enabled is true
  )
  into v_can_pin;

  update internal.devices
  set last_seen_at = now()
  where device_auth_uid = v_auth_uid;

  return jsonb_build_object(
    'success', true,
    'status_code', 'active',
    'device_auth_uid', v_auth_uid,
    'user_uuid', v_user.user_uuid,
    'display_name', v_user.display_name,
    'institution_id', v_user.institution_id,
    'channels', v_channels,
    'can_pin', v_can_pin
  );
end;
$$;


ALTER FUNCTION "server_api"."get_chat_context"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."get_device_activation_request_for_approval"("p_request_id" "uuid", "p_approval_token_hash" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_request internal.device_activation_requests%rowtype;
  v_institution_label text;
  v_channels jsonb;
  v_existing_users jsonb;
begin
  if p_request_id is null
     or p_approval_token_hash is null
     or p_approval_token_hash !~ '^[0-9a-f]{64}$'
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_link'
    );
  end if;

  select r.*
  into v_request
  from internal.device_activation_requests r
  where r.request_id = p_request_id
    and r.approval_token_hash = p_approval_token_hash
  for update;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_link'
    );
  end if;

  if v_request.status = 'pending'
     and v_request.expires_at <= now()
  then
    update internal.device_activation_requests
    set
      status = 'expired',
      decided_at = now(),
      decision_detail =
        coalesce(decision_detail, '{}'::jsonb)
        || jsonb_build_object('reason', 'link_expired')
    where request_id = v_request.request_id;

    insert into internal.security_log (
      event_type,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'device_activation_request_expired',
      v_request.device_auth_uid,
      v_request.institution_id,
      jsonb_build_object(
        'request_id', v_request.request_id
      )
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'expired'
    );
  end if;

  if v_request.status <> 'pending' then
    return jsonb_build_object(
      'success', false,
      'status_code', 'request_not_pending',
      'request_status', v_request.status
    );
  end if;

  select i.label
  into v_institution_label
  from internal.institutions i
  where i.institution_id = v_request.institution_id
    and i.active is true;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'institution_inactive'
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'channel_id', c.channel_id,
        'label', c.label
      )
      order by
        case when c.channel_id = 'all' then 0 else 1 end,
        lower(c.label)
    ),
    '[]'::jsonb
  )
  into v_channels
  from internal.channels c
  where c.institution_id = v_request.institution_id
    and c.enabled is true;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_uuid', u.user_uuid,
        'display_name', u.display_name,
        'goodbarber_user_id', u.goodbarber_user_id
      )
      order by lower(u.display_name), u.user_uuid
    ),
    '[]'::jsonb
  )
  into v_existing_users
  from internal.users u
  where u.institution_id = v_request.institution_id
    and u.active is true;

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',

    'request_id', v_request.request_id,
    'institution_id', v_request.institution_id,
    'institution_label', v_institution_label,

    'suggested_display_name',
      v_request.suggested_display_name,

    'suggested_email',
      v_request.suggested_email,

    'suggested_goodbarber_user_id',
      v_request.suggested_goodbarber_user_id,

    'suggested_groups',
      v_request.suggested_groups,

    'created_at', v_request.created_at,
    'expires_at', v_request.expires_at,

    'channels', v_channels,
    'existing_users', v_existing_users
  );
end;
$_$;


ALTER FUNCTION "server_api"."get_device_activation_request_for_approval"("p_request_id" "uuid", "p_approval_token_hash" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."list_rag_documents"("p_auth_uid" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
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

  select
    r.authorized,
    r.user_uuid,
    r.institution_id
  into
    v_authorized,
    v_admin_user_uuid,
    v_institution_id
  from server_api.check_backoffice_role(
    p_auth_uid,
    'admin'
  ) r
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


ALTER FUNCTION "server_api"."list_rag_documents"("p_auth_uid" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "server_api"."list_rag_documents"("p_auth_uid" "uuid") IS 'Liste les mÃ©tadonnÃ©es RAG de la seule institution de l''admin authentifiÃ©.';



CREATE OR REPLACE FUNCTION "server_api"."mark_chat_channel_read"("p_group_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_uid uuid;

  v_device internal.devices%rowtype;
  v_user internal.users%rowtype;
  v_channel internal.channels%rowtype;
  v_read public.gb_78487711_chat_reads%rowtype;

  v_group_id text;
  v_legacy_user_id text;
  v_read_at timestamptz;
begin
  /*
   * Identité provenant exclusivement du JWT Supabase.
   */
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'authentication_required'
    );
  end if;

  v_group_id := lower(
    btrim(coalesce(p_group_id, ''))
  );

  if length(v_group_id) < 1
     or length(v_group_id) > 100
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_channel'
    );
  end if;

  /*
   * Vérification de l’appareil.
   */
  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_unknown'
    );
  end if;

  if v_device.revoked_at is not null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_revoked'
    );
  end if;

  if v_device.activated_at is null
     or v_device.user_uuid is null
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_not_activated'
    );
  end if;

  /*
   * Vérification du collaborateur.
   */
  select u.*
  into v_user
  from internal.users u
  where u.user_uuid = v_device.user_uuid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_unknown'
    );
  end if;

  if v_user.active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_inactive'
    );
  end if;

  /*
   * Vérification du canal.
   */
  select c.*
  into v_channel
  from internal.channels c
  where c.institution_id = v_user.institution_id
    and c.channel_id = v_group_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_unknown'
    );
  end if;

  if v_channel.enabled is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_disabled'
    );
  end if;

  /*
   * Vérification de l’appartenance réelle au canal.
   */
  if not exists (
    select 1
    from internal.user_channel_memberships membership
    where membership.user_uuid = v_user.user_uuid
      and membership.institution_id = v_user.institution_id
      and membership.channel_id = v_group_id
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_access_denied'
    );
  end if;

  /*
   * Compatibilité temporaire avec le HTML GoodBarber.
   */
  v_legacy_user_id := coalesce(
    nullif(btrim(v_user.goodbarber_user_id), ''),
    v_user.user_uuid::text
  );

  /*
   * Empêche deux appareils de la même personne
   * de modifier simultanément le même état de lecture.
   */
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_user.user_uuid::text || ':' || v_group_id,
      78487713
    )
  );

  v_read_at := clock_timestamp();

  /*
   * Recherche prioritaire de la ligne liée à la vraie
   * identité interne.
   */
  select r.*
  into v_read
  from public.gb_78487711_chat_reads r
  where r.institution_id = v_user.institution_id
    and r.group_id = v_group_id
    and r.user_uuid = v_user.user_uuid
  for update;

  if found then
    update public.gb_78487711_chat_reads
    set
      user_id = v_legacy_user_id,
      last_read_at = greatest(
        last_read_at,
        v_read_at
      ),
      updated_at = v_read_at
    where institution_id = v_read.institution_id
      and user_id = v_read.user_id
      and group_id = v_read.group_id
    returning *
    into v_read;

    /*
     * Nettoyage éventuel d’une ancienne ligne héritée
     * ne contenant pas encore user_uuid.
     */
    delete from public.gb_78487711_chat_reads
    where institution_id = v_user.institution_id
      and group_id = v_group_id
      and user_uuid is null
      and user_id = v_legacy_user_id;

  else
    /*
     * Recherche d’une ancienne ligne basée uniquement
     * sur l’identifiant GoodBarber.
     */
    select r.*
    into v_read
    from public.gb_78487711_chat_reads r
    where r.institution_id = v_user.institution_id
      and r.group_id = v_group_id
      and r.user_id = v_legacy_user_id
    for update;

    if found then
      update public.gb_78487711_chat_reads
      set
        user_uuid = v_user.user_uuid,
        last_read_at = greatest(
          last_read_at,
          v_read_at
        ),
        updated_at = v_read_at
      where institution_id = v_read.institution_id
        and user_id = v_read.user_id
        and group_id = v_read.group_id
      returning *
      into v_read;

    else
      insert into public.gb_78487711_chat_reads (
        user_id,
        group_id,
        last_read_at,
        updated_at,
        institution_id,
        user_uuid
      )
      values (
        v_legacy_user_id,
        v_group_id,
        v_read_at,
        v_read_at,
        v_user.institution_id,
        v_user.user_uuid
      )
      returning *
      into v_read;
    end if;
  end if;

  update internal.devices
  set last_seen_at = v_read_at
  where device_auth_uid = v_auth_uid;

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',
    'institution_id', v_read.institution_id,
    'group_id', v_read.group_id,
    'user_uuid', v_read.user_uuid,
    'last_read_at', v_read.last_read_at
  );
end;
$$;


ALTER FUNCTION "server_api"."mark_chat_channel_read"("p_group_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."pin_chat_message"("p_message_id" "uuid", "p_duration_code" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_uid uuid;

  v_device internal.devices%rowtype;
  v_user internal.users%rowtype;
  v_message public.gb_78487711_chat_messages%rowtype;
  v_pin public.gb_78487711_chat_pins%rowtype;

  v_interval interval;
  v_now timestamptz;
  v_legacy_user_id text;
begin
  /*
   * Identité issue exclusivement du JWT Supabase.
   */
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'authentication_required'
    );
  end if;

  /*
   * La durée est choisie parmi les quatre valeurs
   * prévues par l’interface.
   */
  v_interval := case btrim(coalesce(p_duration_code, ''))
    when '1h' then interval '1 hour'
    when '4h' then interval '4 hours'
    when '1j' then interval '1 day'
    when '3j' then interval '3 days'
    else null
  end;

  if v_interval is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_duration',
      'allowed_durations',
      jsonb_build_array('1h', '4h', '1j', '3j')
    );
  end if;

  /*
   * Vérification de l’appareil.
   */
  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_unknown'
    );
  end if;

  if v_device.revoked_at is not null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_revoked'
    );
  end if;

  if v_device.activated_at is null
     or v_device.user_uuid is null
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_not_activated'
    );
  end if;

  /*
   * Vérification du collaborateur.
   */
  select u.*
  into v_user
  from internal.users u
  where u.user_uuid = v_device.user_uuid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_unknown'
    );
  end if;

  if v_user.active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_inactive'
    );
  end if;

  /*
   * Seuls les collaborateurs appartenant réellement
   * au canal Cadres peuvent épingler.
   */
  if not exists (
    select 1
    from internal.user_channel_memberships membership
    join internal.channels channel
      on channel.institution_id = membership.institution_id
     and channel.channel_id = membership.channel_id
    where membership.user_uuid = v_user.user_uuid
      and membership.institution_id = v_user.institution_id
      and membership.channel_id = 'cadres'
      and channel.enabled is true
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'cadre_required'
    );
  end if;

  /*
   * Le message doit appartenir à la même institution.
   */
  select m.*
  into v_message
  from public.gb_78487711_chat_messages m
  where m.id = p_message_id
    and m.institution_id = v_user.institution_id
  for key share;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_not_found'
    );
  end if;

  if v_message.deleted is true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_deleted'
    );
  end if;

  /*
   * Le Cadre doit aussi avoir accès au canal du message.
   */
  if not exists (
    select 1
    from internal.user_channel_memberships membership
    join internal.channels channel
      on channel.institution_id = membership.institution_id
     and channel.channel_id = membership.channel_id
    where membership.user_uuid = v_user.user_uuid
      and membership.institution_id = v_user.institution_id
      and membership.channel_id = v_message.group_id
      and channel.enabled is true
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_access_denied'
    );
  end if;

  /*
   * Verrou par institution et canal pour éviter deux
   * épinglages simultanés contradictoires.
   */
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_user.institution_id || ':' || v_message.group_id,
      78487714
    )
  );

  v_now := clock_timestamp();

  v_legacy_user_id := coalesce(
    nullif(btrim(v_user.goodbarber_user_id), ''),
    v_user.user_uuid::text
  );

  /*
   * Un seul pin par canal.
   * Un nouvel épinglage remplace immédiatement l’ancien.
   */
  insert into public.gb_78487711_chat_pins (
    institution_id,
    group_id,
    message_id,
    pinned_by_user_id,
    pinned_by_user_uuid,
    pinned_at,
    pinned_until
  )
  values (
    v_user.institution_id,
    v_message.group_id,
    v_message.id,
    v_legacy_user_id,
    v_user.user_uuid,
    v_now,
    v_now + v_interval
  )
  on conflict (institution_id, group_id)
  do update set
    message_id = excluded.message_id,
    pinned_by_user_id = excluded.pinned_by_user_id,
    pinned_by_user_uuid = excluded.pinned_by_user_uuid,
    pinned_at = excluded.pinned_at,
    pinned_until = excluded.pinned_until
  returning *
  into v_pin;

  update internal.devices
  set last_seen_at = v_now
  where device_auth_uid = v_auth_uid;

  insert into internal.security_log (
    event_type,
    user_uuid,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'chat_message_pinned',
    v_user.user_uuid,
    v_auth_uid,
    v_user.institution_id,
    jsonb_build_object(
      'message_id', v_message.id,
      'channel_id', v_message.group_id,
      'duration_code', p_duration_code,
      'pinned_until', v_pin.pinned_until
    )
  );

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',
    'institution_id', v_pin.institution_id,
    'group_id', v_pin.group_id,
    'message_id', v_pin.message_id,
    'pinned_by_user_uuid', v_pin.pinned_by_user_uuid,
    'pinned_at', v_pin.pinned_at,
    'pinned_until', v_pin.pinned_until
  );
end;
$$;


ALTER FUNCTION "server_api"."pin_chat_message"("p_message_id" "uuid", "p_duration_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."register_rag_document"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_document_key" "text", "p_title" "text", "p_category" "text", "p_version_label" "text", "p_effective_date" "date", "p_storage_path" "text", "p_original_file_name" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_file_sha256" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_job_id uuid;
  v_existing_document_id uuid;
  v_storage_metadata jsonb;
  v_storage_size bigint;
  v_storage_mime_type text;
  v_upload_count integer;
  v_rate_window timestamptz :=
    pg_catalog.date_trunc('hour', pg_catalog.now());
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

  if p_document_id is null
     or p_storage_path is null
     or pg_catalog.array_length(
       pg_catalog.string_to_array(p_storage_path, '/'),
       1
     ) <> 3
     or pg_catalog.split_part(p_storage_path, '/', 1) <> v_institution_id
     or pg_catalog.split_part(p_storage_path, '/', 2) <> p_document_id::text
     or pg_catalog.btrim(
       pg_catalog.split_part(p_storage_path, '/', 3)
     ) = ''
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_storage_path'
    );
  end if;

  select o.metadata
  into v_storage_metadata
  from storage.objects o
  where o.bucket_id = 'rag-documents'
    and o.name = p_storage_path;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'source_file_missing'
    );
  end if;

  begin
    v_storage_size := nullif(
      v_storage_metadata ->> 'size',
      ''
    )::bigint;
  exception
    when invalid_text_representation or numeric_value_out_of_range then
      return pg_catalog.jsonb_build_object(
        'success', false,
        'status_code', 'source_metadata_invalid'
      );
  end;

  v_storage_mime_type := nullif(
    v_storage_metadata ->> 'mimetype',
    ''
  );

  if (v_storage_size is not null and v_storage_size <> p_file_size_bytes)
     or (
       v_storage_mime_type is not null
       and v_storage_mime_type <> p_mime_type
     )
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'source_metadata_mismatch'
    );
  end if;

  select d.document_id
  into v_existing_document_id
  from internal.rag_documents d
  where d.institution_id = v_institution_id
    and d.file_sha256 = p_file_sha256
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'duplicate_file',
      'existing_document_id', v_existing_document_id
    );
  end if;

  select d.document_id
  into v_existing_document_id
  from internal.rag_documents d
  where d.institution_id = v_institution_id
    and d.document_key = p_document_key
    and d.version_label = p_version_label
  limit 1;

  if found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'version_already_exists',
      'existing_document_id', v_existing_document_id
    );
  end if;

  /*
    Limite propre au RAG : 20 nouveaux dÃ©pÃ´ts par administrateur et par heure.
    Le type de sujet est distinct de ceux utilisÃ©s par le chat.
  */
  insert into internal.rate_limits as rl (
    subject_type,
    subject_id,
    window_start,
    count,
    updated_at
  )
  values (
    'rag_upload_admin',
    v_admin_user_uuid::text,
    v_rate_window,
    1,
    pg_catalog.now()
  )
  on conflict (subject_type, subject_id, window_start)
  do update
  set
    count = rl.count + 1,
    updated_at = pg_catalog.now()
  where rl.count < 20
  returning rl.count into v_upload_count;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'upload_rate_limited'
    );
  end if;

  insert into internal.rag_documents (
    document_id,
    institution_id,
    document_key,
    title,
    category,
    version_label,
    effective_date,
    status,
    storage_path,
    original_file_name,
    mime_type,
    file_size_bytes,
    file_sha256,
    uploaded_by
  )
  values (
    p_document_id,
    v_institution_id,
    p_document_key,
    p_title,
    p_category,
    p_version_label,
    p_effective_date,
    'draft',
    p_storage_path,
    p_original_file_name,
    p_mime_type,
    p_file_size_bytes,
    p_file_sha256,
    v_admin_user_uuid
  );

  insert into internal.rag_ingestion_jobs (
    document_id,
    institution_id,
    status,
    stage,
    requested_by
  )
  values (
    p_document_id,
    v_institution_id,
    'queued',
    'queued',
    v_admin_user_uuid
  )
  returning job_id into v_job_id;

  insert into internal.security_log (
    event_type,
    user_uuid,
    institution_id,
    actor_admin_uuid,
    detail
  )
  values (
    'rag_document_uploaded',
    null,
    v_institution_id,
    v_admin_user_uuid,
    pg_catalog.jsonb_build_object(
      'document_id', p_document_id,
      'document_key', p_document_key,
      'version_label', p_version_label,
      'file_sha256', p_file_sha256
    )
  );

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'queued',
    'document_id', p_document_id,
    'job_id', v_job_id
  );
exception
  when unique_violation then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_conflict'
    );
end;
$$;


ALTER FUNCTION "server_api"."register_rag_document"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_document_key" "text", "p_title" "text", "p_category" "text", "p_version_label" "text", "p_effective_date" "date", "p_storage_path" "text", "p_original_file_name" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_file_sha256" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."send_chat_message"("p_group_id" "text", "p_body" "text", "p_reply_to_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_uid uuid;

  v_device internal.devices%rowtype;
  v_user internal.users%rowtype;
  v_channel internal.channels%rowtype;

  v_reply public.gb_78487711_chat_messages%rowtype;
  v_message public.gb_78487711_chat_messages%rowtype;
  v_duplicate public.gb_78487711_chat_messages%rowtype;

  v_group_id text;
  v_body text;
  v_legacy_user_id text;

  v_count_minute integer;
  v_count_hour integer;
begin
  /*
   * L’identité de l’appareil provient exclusivement
   * du JWT Supabase transmis à la RPC.
   */
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'authentication_required'
    );
  end if;

  /*
   * Nettoyage des paramètres.
   */
  v_group_id := lower(
    btrim(coalesce(p_group_id, ''))
  );

  v_body := btrim(
    replace(
      replace(
        coalesce(p_body, ''),
        E'\r\n',
        E'\n'
      ),
      E'\r',
      E'\n'
    )
  );

  if length(v_group_id) < 1
     or length(v_group_id) > 100
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_channel'
    );
  end if;

  if length(v_body) < 1 then
    return jsonb_build_object(
      'success', false,
      'status_code', 'empty_message'
    );
  end if;

  if length(v_body) > 4000 then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_too_long',
      'maximum_length', 4000
    );
  end if;

  /*
   * Recherche de l’appareil.
   */
  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_unknown'
    );
  end if;

  if v_device.revoked_at is not null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_revoked'
    );
  end if;

  if v_device.activated_at is null
     or v_device.user_uuid is null
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_not_activated'
    );
  end if;

  /*
   * Recherche du collaborateur lié à l’appareil.
   */
  select u.*
  into v_user
  from internal.users u
  where u.user_uuid = v_device.user_uuid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_unknown'
    );
  end if;

  if v_user.active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_inactive'
    );
  end if;

  /*
   * Le canal doit exister et être actif dans
   * l’institution du collaborateur.
   */
  select c.*
  into v_channel
  from internal.channels c
  where c.institution_id = v_user.institution_id
    and c.channel_id = v_group_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_unknown'
    );
  end if;

  if v_channel.enabled is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_disabled'
    );
  end if;

  /*
   * Vérification des droits réels.
   * Les groupes transmis par GoodBarber ne sont jamais utilisés ici.
   */
  if not exists (
    select 1
    from internal.user_channel_memberships m
    where m.user_uuid = v_user.user_uuid
      and m.institution_id = v_user.institution_id
      and m.channel_id = v_group_id
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_access_denied'
    );
  end if;

  /*
   * Sérialisation des envois du même utilisateur.
   * Cela évite de contourner la limite par plusieurs
   * requêtes simultanées.
   */
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_user.user_uuid::text,
      78487711
    )
  );

  /*
   * Limitation anti-spam :
   * maximum 15 messages par minute et 120 par heure.
   */
  select
    count(*) filter (
      where m.created_at >= now() - interval '1 minute'
    ),
    count(*) filter (
      where m.created_at >= now() - interval '1 hour'
    )
  into
    v_count_minute,
    v_count_hour
  from public.gb_78487711_chat_messages m
  where m.institution_id = v_user.institution_id
    and m.author_user_uuid = v_user.user_uuid
    and m.created_at >= now() - interval '1 hour';

  if v_count_minute >= 15
     or v_count_hour >= 120
  then
    insert into internal.security_log (
      event_type,
      user_uuid,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'chat_message_rate_limited',
      v_user.user_uuid,
      v_auth_uid,
      v_user.institution_id,
      jsonb_build_object(
        'channel_id', v_group_id,
        'messages_last_minute', v_count_minute,
        'messages_last_hour', v_count_hour
      )
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'rate_limited'
    );
  end if;

  /*
   * Validation du message auquel on répond.
   * Il doit appartenir au même canal et à la même institution.
   */
  if p_reply_to_id is not null then
    select m.*
    into v_reply
    from public.gb_78487711_chat_messages m
    where m.id = p_reply_to_id
      and m.institution_id = v_user.institution_id
      and m.group_id = v_group_id
      and m.deleted is not true;

    if not found then
      return jsonb_build_object(
        'success', false,
        'status_code', 'reply_message_unavailable'
      );
    end if;
  end if;

  /*
   * Protection contre un double clic ou une répétition réseau :
   * un contenu identique envoyé dans le même canal et avec
   * la même réponse dans les trois dernières secondes
   * retourne le message déjà créé.
   */
  select m.*
  into v_duplicate
  from public.gb_78487711_chat_messages m
  where m.institution_id = v_user.institution_id
    and m.group_id = v_group_id
    and m.author_user_uuid = v_user.user_uuid
    and m.body = v_body
    and m.reply_to_id is not distinct from p_reply_to_id
    and m.deleted is not true
    and m.created_at >= now() - interval '3 seconds'
  order by m.created_at desc
  limit 1;

  if found then
    update internal.devices
    set last_seen_at = now()
    where device_auth_uid = v_auth_uid;

    return jsonb_build_object(
      'success', true,
      'status_code', 'duplicate_suppressed',
      'message', to_jsonb(v_duplicate)
    );
  end if;

  /*
   * Compatibilité temporaire avec le HTML GoodBarber actuel.
   * La vraie identité reste author_user_uuid.
   */
  v_legacy_user_id := coalesce(
    nullif(btrim(v_user.goodbarber_user_id), ''),
    v_user.user_uuid::text
  );

  insert into public.gb_78487711_chat_messages (
    first_name,
    last_name,
    body,
    group_id,
    user_id,
    institution_id,
    author_user_uuid,
    reply_to_id,
    reply_to_first_name,
    reply_to_last_name,
    reply_to_body
  )
  values (
    v_user.display_name,
    '',
    v_body,
    v_group_id,
    v_legacy_user_id,
    v_user.institution_id,
    v_user.user_uuid,
    p_reply_to_id,
    case
      when p_reply_to_id is null then null
      else v_reply.first_name
    end,
    case
      when p_reply_to_id is null then null
      else v_reply.last_name
    end,
    case
      when p_reply_to_id is null then null
      else v_reply.body
    end
  )
  returning *
  into v_message;

  update internal.devices
  set last_seen_at = now()
  where device_auth_uid = v_auth_uid;

  insert into internal.security_log (
    event_type,
    user_uuid,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'chat_message_sent',
    v_user.user_uuid,
    v_auth_uid,
    v_user.institution_id,
    jsonb_build_object(
      'message_id', v_message.id,
      'channel_id', v_group_id,
      'reply_to_id', p_reply_to_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',
    'message', to_jsonb(v_message)
  );
end;
$$;


ALTER FUNCTION "server_api"."send_chat_message"("p_group_id" "text", "p_body" "text", "p_reply_to_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."set_rag_ingestion_plan"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_total_items" integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_authorized boolean;
  v_institution_id text;
  v_job internal.rag_ingestion_jobs%rowtype;
begin
  select r.authorized, r.institution_id
  into v_authorized, v_institution_id
  from server_api.check_backoffice_role(p_auth_uid, 'admin') r
  limit 1;

  if coalesce(v_authorized, false) is not true
     or v_institution_id is null
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'admin_unauthorized'
    );
  end if;

  if p_total_items is null or p_total_items < 1 or p_total_items > 800 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_total_items'
    );
  end if;

  select j.*
  into v_job
  from internal.rag_ingestion_jobs j
  where j.job_id = p_job_id
    and j.institution_id = v_institution_id
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_found'
    );
  end if;

  if v_job.status <> 'running' or v_job.worker_id <> p_worker_id then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_owned'
    );
  end if;

  update internal.rag_ingestion_jobs j
  set
    stage = 'embedding',
    total_items = p_total_items,
    processed_items = 0,
    locked_at = pg_catalog.now()
  where j.job_id = p_job_id;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'plan_set',
    'total_items', p_total_items
  );
end;
$$;


ALTER FUNCTION "server_api"."set_rag_ingestion_plan"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_total_items" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."start_rag_ingestion"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_worker_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_authorized boolean;
  v_admin_user_uuid uuid;
  v_institution_id text;
  v_document_status text;
  v_storage_path text;
  v_mime_type text;
  v_title text;
  v_original_file_name text;
  v_job_id uuid;
  v_job_status text;
  v_attempt_count integer;
  v_max_attempts integer;
  v_locked_at timestamptz;
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

  if p_worker_id is null
     or pg_catalog.btrim(p_worker_id) = ''
     or pg_catalog.char_length(p_worker_id) > 120
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_worker_id'
    );
  end if;

  select d.status, d.storage_path, d.mime_type, d.title, d.original_file_name
  into
    v_document_status,
    v_storage_path,
    v_mime_type,
    v_title,
    v_original_file_name
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

  if v_document_status in ('ready', 'active') then
    return pg_catalog.jsonb_build_object(
      'success', true,
      'status_code', 'already_ready',
      'document_id', p_document_id
    );
  end if;

  if v_document_status = 'obsolete' then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'document_obsolete'
    );
  end if;

  select
    j.job_id,
    j.status,
    j.attempt_count,
    j.max_attempts,
    j.locked_at
  into
    v_job_id,
    v_job_status,
    v_attempt_count,
    v_max_attempts,
    v_locked_at
  from internal.rag_ingestion_jobs j
  where j.document_id = p_document_id
    and j.institution_id = v_institution_id
  order by j.created_at desc
  limit 1
  for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_not_found'
    );
  end if;

  if v_job_status = 'succeeded' then
    return pg_catalog.jsonb_build_object(
      'success', true,
      'status_code', 'already_ready',
      'document_id', p_document_id
    );
  end if;

  if v_job_status = 'cancelled' then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'job_cancelled'
    );
  end if;

  if v_job_status = 'running'
     and v_locked_at is not null
     and v_locked_at >= v_now - pg_catalog.make_interval(mins => 15)
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'already_processing'
    );
  end if;

  if v_attempt_count >= v_max_attempts then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'retry_exhausted'
    );
  end if;

  delete from internal.rag_passages p
  where p.document_id = p_document_id
    and p.institution_id = v_institution_id;

  update internal.rag_ingestion_jobs j
  set
    status = 'running',
    stage = 'extraction',
    total_items = null,
    processed_items = 0,
    attempt_count = j.attempt_count + 1,
    last_error_code = null,
    last_error_message = null,
    worker_id = p_worker_id,
    locked_at = v_now,
    started_at = coalesce(j.started_at, v_now),
    finished_at = null
  where j.job_id = v_job_id;

  update internal.rag_documents d
  set
    status = 'processing',
    extraction_method = null,
    extraction_version = null,
    page_count = null,
    extraction_metadata = '{}'::jsonb,
    error_message = null
  where d.document_id = p_document_id
    and d.institution_id = v_institution_id;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'started',
    'document_id', p_document_id,
    'job_id', v_job_id,
    'storage_path', v_storage_path,
    'mime_type', v_mime_type,
    'title', v_title,
    'original_file_name', v_original_file_name
  );
end;
$$;


ALTER FUNCTION "server_api"."start_rag_ingestion"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_worker_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."toggle_chat_reaction"("p_message_id" "uuid", "p_emoji" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_uid uuid;

  v_device internal.devices%rowtype;
  v_user internal.users%rowtype;
  v_message public.gb_78487711_chat_messages%rowtype;
  v_reaction public.gb_78487711_chat_reactions%rowtype;

  v_emoji text;
  v_legacy_user_id text;
  v_action text;
  v_reaction_id uuid;

  v_deleted_count integer := 0;
  v_count_minute integer := 0;
  v_count_hour integer := 0;

  v_counts jsonb;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'authentication_required'
    );
  end if;

  v_emoji := case btrim(coalesce(p_emoji, ''))
    when '👍' then '👍'
    when '❤️' then '❤️'
    when '❤' then '❤️'
    when '😂' then '😂'
    else null
  end;

  if v_emoji is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_emoji',
      'allowed_emojis',
      jsonb_build_array('👍', '❤️', '😂')
    );
  end if;

  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_unknown'
    );
  end if;

  if v_device.revoked_at is not null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_revoked'
    );
  end if;

  if v_device.activated_at is null
     or v_device.user_uuid is null
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_not_activated'
    );
  end if;

  select u.*
  into v_user
  from internal.users u
  where u.user_uuid = v_device.user_uuid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_unknown'
    );
  end if;

  if v_user.active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_inactive'
    );
  end if;

  select m.*
  into v_message
  from public.gb_78487711_chat_messages m
  where m.id = p_message_id
    and m.institution_id = v_user.institution_id
  for key share;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_not_found'
    );
  end if;

  if v_message.deleted is true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'message_deleted'
    );
  end if;

  if not exists (
    select 1
    from internal.channels c
    join internal.user_channel_memberships membership
      on membership.institution_id = c.institution_id
     and membership.channel_id = c.channel_id
    where c.institution_id = v_user.institution_id
      and c.channel_id = v_message.group_id
      and c.enabled is true
      and membership.user_uuid = v_user.user_uuid
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_access_denied'
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_user.user_uuid::text,
      78487712
    )
  );

  select
    count(*) filter (
      where l.created_at >= now() - interval '1 minute'
    ),
    count(*) filter (
      where l.created_at >= now() - interval '1 hour'
    )
  into
    v_count_minute,
    v_count_hour
  from internal.security_log l
  where l.user_uuid = v_user.user_uuid
    and l.event_type = 'chat_reaction_toggled'
    and l.created_at >= now() - interval '1 hour';

  if v_count_minute >= 60
     or v_count_hour >= 500
  then
    insert into internal.security_log (
      event_type,
      user_uuid,
      device_auth_uid,
      institution_id,
      detail
    )
    values (
      'chat_reaction_rate_limited',
      v_user.user_uuid,
      v_auth_uid,
      v_user.institution_id,
      jsonb_build_object(
        'message_id', v_message.id,
        'channel_id', v_message.group_id,
        'reactions_last_minute', v_count_minute,
        'reactions_last_hour', v_count_hour
      )
    );

    return jsonb_build_object(
      'success', false,
      'status_code', 'rate_limited'
    );
  end if;

  v_legacy_user_id := coalesce(
    nullif(btrim(v_user.goodbarber_user_id), ''),
    v_user.user_uuid::text
  );

  /*
   * Correction : on compte uniquement les lignes supprimées.
   * min(uuid) n’existe pas dans PostgreSQL.
   */
  with deleted_rows as (
    delete from public.gb_78487711_chat_reactions r
    where r.message_id = v_message.id
      and r.institution_id = v_user.institution_id
      and r.group_id = v_message.group_id
      and r.emoji = v_emoji
      and (
        r.user_uuid = v_user.user_uuid
        or (
          r.user_uuid is null
          and r.user_id = v_legacy_user_id
        )
      )
    returning r.id
  )
  select count(*)::integer
  into v_deleted_count
  from deleted_rows;

  if v_deleted_count > 0 then
    v_action := 'removed';
    v_reaction_id := null;
  else
    insert into public.gb_78487711_chat_reactions (
      message_id,
      group_id,
      user_id,
      emoji,
      institution_id,
      user_uuid
    )
    values (
      v_message.id,
      v_message.group_id,
      v_legacy_user_id,
      v_emoji,
      v_user.institution_id,
      v_user.user_uuid
    )
    returning *
    into v_reaction;

    v_reaction_id := v_reaction.id;
    v_action := 'added';
  end if;

  update internal.devices
  set last_seen_at = now()
  where device_auth_uid = v_auth_uid;

  insert into internal.security_log (
    event_type,
    user_uuid,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'chat_reaction_toggled',
    v_user.user_uuid,
    v_auth_uid,
    v_user.institution_id,
    jsonb_build_object(
      'reaction_id', v_reaction_id,
      'message_id', v_message.id,
      'channel_id', v_message.group_id,
      'emoji', v_emoji,
      'action', v_action
    )
  );

  select coalesce(
    jsonb_object_agg(summary.emoji, summary.total),
    '{}'::jsonb
  )
  into v_counts
  from (
    select
      r.emoji,
      count(*)::integer as total
    from public.gb_78487711_chat_reactions r
    where r.message_id = v_message.id
      and r.institution_id = v_user.institution_id
      and r.group_id = v_message.group_id
    group by r.emoji
  ) summary;

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',
    'action', v_action,
    'reaction_id', v_reaction_id,
    'message_id', v_message.id,
    'emoji', v_emoji,
    'counts', v_counts
  );
end;
$$;


ALTER FUNCTION "server_api"."toggle_chat_reaction"("p_message_id" "uuid", "p_emoji" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "server_api"."unpin_chat_message"("p_group_id" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  v_auth_uid uuid;

  v_device internal.devices%rowtype;
  v_user internal.users%rowtype;
  v_pin public.gb_78487711_chat_pins%rowtype;

  v_group_id text;
  v_now timestamptz;
begin
  v_auth_uid := auth.uid();

  if v_auth_uid is null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'authentication_required'
    );
  end if;

  v_group_id := lower(
    btrim(coalesce(p_group_id, ''))
  );

  if length(v_group_id) < 1
     or length(v_group_id) > 100
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'invalid_channel'
    );
  end if;

  select d.*
  into v_device
  from internal.devices d
  where d.device_auth_uid = v_auth_uid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_unknown'
    );
  end if;

  if v_device.revoked_at is not null then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_revoked'
    );
  end if;

  if v_device.activated_at is null
     or v_device.user_uuid is null
  then
    return jsonb_build_object(
      'success', false,
      'status_code', 'device_not_activated'
    );
  end if;

  select u.*
  into v_user
  from internal.users u
  where u.user_uuid = v_device.user_uuid;

  if not found then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_unknown'
    );
  end if;

  if v_user.active is not true then
    return jsonb_build_object(
      'success', false,
      'status_code', 'user_inactive'
    );
  end if;

  /*
   * Seuls les Cadres peuvent désépingler.
   */
  if not exists (
    select 1
    from internal.user_channel_memberships membership
    join internal.channels channel
      on channel.institution_id = membership.institution_id
     and channel.channel_id = membership.channel_id
    where membership.user_uuid = v_user.user_uuid
      and membership.institution_id = v_user.institution_id
      and membership.channel_id = 'cadres'
      and channel.enabled is true
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'cadre_required'
    );
  end if;

  /*
   * Le Cadre doit avoir accès au canal concerné.
   */
  if not exists (
    select 1
    from internal.user_channel_memberships membership
    join internal.channels channel
      on channel.institution_id = membership.institution_id
     and channel.channel_id = membership.channel_id
    where membership.user_uuid = v_user.user_uuid
      and membership.institution_id = v_user.institution_id
      and membership.channel_id = v_group_id
      and channel.enabled is true
  ) then
    return jsonb_build_object(
      'success', false,
      'status_code', 'channel_access_denied'
    );
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      v_user.institution_id || ':' || v_group_id,
      78487714
    )
  );

  select p.*
  into v_pin
  from public.gb_78487711_chat_pins p
  where p.institution_id = v_user.institution_id
    and p.group_id = v_group_id
  for update;

  if not found or v_pin.message_id is null then
    return jsonb_build_object(
      'success', true,
      'status_code', 'already_unpinned',
      'institution_id', v_user.institution_id,
      'group_id', v_group_id
    );
  end if;

  v_now := clock_timestamp();

  update public.gb_78487711_chat_pins
  set
    message_id = null,
    pinned_by_user_id = null,
    pinned_by_user_uuid = null,
    pinned_at = null,
    pinned_until = null
  where institution_id = v_user.institution_id
    and group_id = v_group_id;

  update internal.devices
  set last_seen_at = v_now
  where device_auth_uid = v_auth_uid;

  insert into internal.security_log (
    event_type,
    user_uuid,
    device_auth_uid,
    institution_id,
    detail
  )
  values (
    'chat_message_unpinned',
    v_user.user_uuid,
    v_auth_uid,
    v_user.institution_id,
    jsonb_build_object(
      'message_id', v_pin.message_id,
      'channel_id', v_group_id
    )
  );

  return jsonb_build_object(
    'success', true,
    'status_code', 'success',
    'institution_id', v_user.institution_id,
    'group_id', v_group_id,
    'message_id', v_pin.message_id
  );
end;
$$;


ALTER FUNCTION "server_api"."unpin_chat_message"("p_group_id" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "internal"."activation_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "token_hash" "text" NOT NULL,
    "user_uuid" "uuid" NOT NULL,
    "method" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "consumed_at" timestamp with time zone,
    "consumed_by_device_auth_uid" "uuid",
    "created_by" "uuid",
    "invalidated_at" timestamp with time zone,
    CONSTRAINT "activation_tokens_consumed_after_created" CHECK ((("consumed_at" IS NULL) OR ("consumed_at" >= "created_at"))),
    CONSTRAINT "activation_tokens_consumption_consistent" CHECK ((("consumed_at" IS NULL) = ("consumed_by_device_auth_uid" IS NULL))),
    CONSTRAINT "activation_tokens_expires_after_created" CHECK (("expires_at" > "created_at")),
    CONSTRAINT "activation_tokens_invalidated_after_created" CHECK ((("invalidated_at" IS NULL) OR ("invalidated_at" >= "created_at"))),
    CONSTRAINT "activation_tokens_method_check" CHECK (("method" = ANY (ARRAY['qr'::"text", 'manual_code'::"text", 'mcp'::"text"]))),
    CONSTRAINT "activation_tokens_not_both_consumed_and_invalidated" CHECK ((NOT (("consumed_at" IS NOT NULL) AND ("invalidated_at" IS NOT NULL))))
);


ALTER TABLE "internal"."activation_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "internal"."backoffice_auth_links" (
    "link_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_uuid" "uuid" NOT NULL,
    "institution_id" "text" NOT NULL,
    "backoffice_auth_uid" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_at" timestamp with time zone,
    CONSTRAINT "backoffice_auth_links_email_not_blank" CHECK ((("length"(TRIM(BOTH FROM "email")) >= 3) AND ("length"(TRIM(BOTH FROM "email")) <= 320))),
    CONSTRAINT "backoffice_auth_links_revoked_after_creation" CHECK ((("revoked_at" IS NULL) OR ("revoked_at" >= "created_at")))
);


ALTER TABLE "internal"."backoffice_auth_links" OWNER TO "postgres";


COMMENT ON TABLE "internal"."backoffice_auth_links" IS 'Relie un compte Supabase Auth (e-mail, lien magique) au collaborateur interne correspondant, pour l’accès au back-office admin.';



COMMENT ON COLUMN "internal"."backoffice_auth_links"."backoffice_auth_uid" IS 'Identifiant auth.users du compte e-mail admin — distinct du device_auth_uid anonyme utilisé pour le chat.';



CREATE TABLE IF NOT EXISTS "internal"."channels" (
    "institution_id" "text" NOT NULL,
    "channel_id" "text" NOT NULL,
    "label" "text" NOT NULL,
    "enabled" boolean DEFAULT true NOT NULL
);


ALTER TABLE "internal"."channels" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "internal"."device_activation_requests" (
    "request_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "institution_id" "text" NOT NULL,
    "device_auth_uid" "uuid" NOT NULL,
    "suggested_display_name" "text" NOT NULL,
    "suggested_email" "text",
    "suggested_goodbarber_user_id" "text",
    "suggested_groups" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "approval_token_hash" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "decided_at" timestamp with time zone,
    "approved_user_uuid" "uuid",
    "decision_detail" "jsonb",
    CONSTRAINT "device_activation_requests_decision_after_creation" CHECK ((("decided_at" IS NULL) OR ("decided_at" >= "created_at"))),
    CONSTRAINT "device_activation_requests_display_name_not_blank" CHECK ((("length"(TRIM(BOTH FROM "suggested_display_name")) >= 1) AND ("length"(TRIM(BOTH FROM "suggested_display_name")) <= 150))),
    CONSTRAINT "device_activation_requests_expires_after_creation" CHECK (("expires_at" > "created_at")),
    CONSTRAINT "device_activation_requests_groups_is_array" CHECK (("jsonb_typeof"("suggested_groups") = 'array'::"text")),
    CONSTRAINT "device_activation_requests_state_consistent" CHECK (((("status" = 'pending'::"text") AND ("decided_at" IS NULL) AND ("approved_user_uuid" IS NULL)) OR (("status" = 'approved'::"text") AND ("decided_at" IS NOT NULL) AND ("approved_user_uuid" IS NOT NULL)) OR (("status" = ANY (ARRAY['rejected'::"text", 'expired'::"text", 'cancelled'::"text"])) AND ("decided_at" IS NOT NULL) AND ("approved_user_uuid" IS NULL)))),
    CONSTRAINT "device_activation_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'rejected'::"text", 'expired'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "device_activation_requests_token_hash_format" CHECK (("approval_token_hash" ~ '^[0-9a-f]{64}$'::"text"))
);


ALTER TABLE "internal"."device_activation_requests" OWNER TO "postgres";


COMMENT ON TABLE "internal"."device_activation_requests" IS 'Demandes d’activation d’appareils en attente de validation par une institution.';



COMMENT ON COLUMN "internal"."device_activation_requests"."suggested_groups" IS 'Groupes GoodBarber déclarés par le client. Suggestion non fiable, jamais utilisée directement comme autorisation.';



COMMENT ON COLUMN "internal"."device_activation_requests"."approval_token_hash" IS 'Hash SHA-256 du jeton présent dans le lien envoyé à l’administrateur. Le jeton brut n’est jamais stocké.';



CREATE TABLE IF NOT EXISTS "internal"."devices" (
    "device_auth_uid" "uuid" NOT NULL,
    "user_uuid" "uuid",
    "activated_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "revoked_reason" "text",
    "last_seen_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "devices_revoked_after_activated" CHECK ((("revoked_at" IS NULL) OR ("activated_at" IS NULL) OR ("revoked_at" >= "activated_at"))),
    CONSTRAINT "devices_revoked_reason_requires_revoked_at" CHECK ((("revoked_reason" IS NULL) OR ("revoked_at" IS NOT NULL))),
    CONSTRAINT "devices_user_activation_consistent" CHECK ((("user_uuid" IS NULL) = ("activated_at" IS NULL)))
);


ALTER TABLE "internal"."devices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "internal"."institutions" (
    "institution_id" "text" NOT NULL,
    "label" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "activation_admin_email" "text",
    CONSTRAINT "institutions_activation_admin_email_not_blank" CHECK ((("activation_admin_email" IS NULL) OR (("length"(TRIM(BOTH FROM "activation_admin_email")) >= 3) AND ("length"(TRIM(BOTH FROM "activation_admin_email")) <= 320))))
);


ALTER TABLE "internal"."institutions" OWNER TO "postgres";


COMMENT ON COLUMN "internal"."institutions"."activation_admin_email" IS 'Adresse qui reçoit les demandes d’activation du chat pour cette institution.';



CREATE TABLE IF NOT EXISTS "internal"."rag_documents" (
    "document_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "institution_id" "text" NOT NULL,
    "document_key" "text" NOT NULL,
    "title" "text" NOT NULL,
    "category" "text" NOT NULL,
    "version_label" "text" NOT NULL,
    "effective_date" "date",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "original_file_name" "text" NOT NULL,
    "mime_type" "text" NOT NULL,
    "file_size_bytes" bigint NOT NULL,
    "file_sha256" "text" NOT NULL,
    "extraction_method" "text",
    "extraction_version" "text",
    "page_count" integer,
    "extraction_metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "error_message" "text",
    "uploaded_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "activated_at" timestamp with time zone,
    "obsolete_at" timestamp with time zone,
    CONSTRAINT "rag_documents_active_date_check" CHECK ((("status" <> 'active'::"text") OR ("activated_at" IS NOT NULL))),
    CONSTRAINT "rag_documents_category_check" CHECK ((("btrim"("category") <> ''::"text") AND ("char_length"("category") <= 100))),
    CONSTRAINT "rag_documents_document_key_check" CHECK (("document_key" ~ '^[a-z0-9][a-z0-9_-]{0,119}$'::"text")),
    CONSTRAINT "rag_documents_file_sha256_check" CHECK (("file_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "rag_documents_file_size_check" CHECK ((("file_size_bytes" > 0) AND ("file_size_bytes" <= 20971520))),
    CONSTRAINT "rag_documents_mime_type_check" CHECK (("mime_type" = ANY (ARRAY['application/pdf'::"text", 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'::"text"]))),
    CONSTRAINT "rag_documents_obsolete_date_check" CHECK ((("status" <> 'obsolete'::"text") OR ("obsolete_at" IS NOT NULL))),
    CONSTRAINT "rag_documents_original_file_name_check" CHECK ((("btrim"("original_file_name") <> ''::"text") AND ("char_length"("original_file_name") <= 255))),
    CONSTRAINT "rag_documents_page_count_check" CHECK ((("page_count" IS NULL) OR ("page_count" > 0))),
    CONSTRAINT "rag_documents_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'processing'::"text", 'ready'::"text", 'active'::"text", 'obsolete'::"text", 'error'::"text"]))),
    CONSTRAINT "rag_documents_storage_path_check" CHECK ((("split_part"("storage_path", '/'::"text", 1) = "institution_id") AND ("storage_path" <> "institution_id") AND (POSITION(('/'::"text") IN ("storage_path")) > 1))),
    CONSTRAINT "rag_documents_title_check" CHECK ((("btrim"("title") <> ''::"text") AND ("char_length"("title") <= 250))),
    CONSTRAINT "rag_documents_version_label_check" CHECK ((("btrim"("version_label") <> ''::"text") AND ("char_length"("version_label") <= 50)))
);

ALTER TABLE ONLY "internal"."rag_documents" FORCE ROW LEVEL SECURITY;


ALTER TABLE "internal"."rag_documents" OWNER TO "postgres";


COMMENT ON TABLE "internal"."rag_documents" IS 'Documents officiels privés du RAG, isolés par institution et versionnés.';



COMMENT ON COLUMN "internal"."rag_documents"."document_key" IS 'Clé stable regroupant les différentes versions du même document logique.';



COMMENT ON COLUMN "internal"."rag_documents"."storage_path" IS 'Chemin privé dans le bucket rag-documents, préfixé par institution_id.';



CREATE TABLE IF NOT EXISTS "internal"."rag_ingestion_jobs" (
    "job_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "institution_id" "text" NOT NULL,
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "stage" "text" DEFAULT 'queued'::"text" NOT NULL,
    "total_items" integer,
    "processed_items" integer DEFAULT 0 NOT NULL,
    "attempt_count" integer DEFAULT 0 NOT NULL,
    "max_attempts" integer DEFAULT 3 NOT NULL,
    "last_error_code" "text",
    "last_error_message" "text",
    "worker_id" "text",
    "locked_at" timestamp with time zone,
    "requested_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "started_at" timestamp with time zone,
    "finished_at" timestamp with time zone,
    CONSTRAINT "rag_ingestion_jobs_attempt_count_check" CHECK (("attempt_count" >= 0)),
    CONSTRAINT "rag_ingestion_jobs_attempt_limit_check" CHECK (("attempt_count" <= "max_attempts")),
    CONSTRAINT "rag_ingestion_jobs_finished_at_check" CHECK ((("status" <> ALL (ARRAY['succeeded'::"text", 'failed'::"text", 'cancelled'::"text"])) OR ("finished_at" IS NOT NULL))),
    CONSTRAINT "rag_ingestion_jobs_max_attempts_check" CHECK ((("max_attempts" >= 1) AND ("max_attempts" <= 10))),
    CONSTRAINT "rag_ingestion_jobs_processed_items_check" CHECK (("processed_items" >= 0)),
    CONSTRAINT "rag_ingestion_jobs_progress_check" CHECK ((("total_items" IS NULL) OR ("processed_items" <= "total_items"))),
    CONSTRAINT "rag_ingestion_jobs_stage_check" CHECK (("stage" = ANY (ARRAY['queued'::"text", 'extraction'::"text", 'chunking'::"text", 'embedding'::"text", 'finalization'::"text", 'completed'::"text"]))),
    CONSTRAINT "rag_ingestion_jobs_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'running'::"text", 'succeeded'::"text", 'failed'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "rag_ingestion_jobs_total_items_check" CHECK ((("total_items" IS NULL) OR ("total_items" >= 0)))
);

ALTER TABLE ONLY "internal"."rag_ingestion_jobs" FORCE ROW LEVEL SECURITY;


ALTER TABLE "internal"."rag_ingestion_jobs" OWNER TO "postgres";


COMMENT ON TABLE "internal"."rag_ingestion_jobs" IS 'Suivi et reprise des traitements fractionnés : extraction, découpage et embeddings.';



CREATE TABLE IF NOT EXISTS "internal"."rag_passages" (
    "passage_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "document_id" "uuid" NOT NULL,
    "institution_id" "text" NOT NULL,
    "chunk_index" integer NOT NULL,
    "content" "text" NOT NULL,
    "content_sha256" "text" NOT NULL,
    "token_count" integer,
    "page_start" integer,
    "page_end" integer,
    "section_title" "text",
    "article_reference" "text",
    "source_reference" "text" NOT NULL,
    "embedding" "extensions"."vector"(1536),
    "embedding_model" "text",
    "embedding_dimensions" smallint,
    "embedded_at" timestamp with time zone,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "rag_passages_chunk_index_check" CHECK (("chunk_index" >= 0)),
    CONSTRAINT "rag_passages_content_check" CHECK (("btrim"("content") <> ''::"text")),
    CONSTRAINT "rag_passages_content_sha256_check" CHECK (("content_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "rag_passages_embedding_bundle_check" CHECK (((("embedding" IS NULL) AND ("embedding_model" IS NULL) AND ("embedding_dimensions" IS NULL) AND ("embedded_at" IS NULL)) OR (("embedding" IS NOT NULL) AND ("embedding_model" = 'Qwen/Qwen3-Embedding-8B'::"text") AND ("embedding_dimensions" = 1536) AND ("embedded_at" IS NOT NULL)))),
    CONSTRAINT "rag_passages_page_end_check" CHECK ((("page_end" IS NULL) OR ("page_end" > 0))),
    CONSTRAINT "rag_passages_page_range_check" CHECK ((("page_start" IS NULL) OR ("page_end" IS NULL) OR ("page_end" >= "page_start"))),
    CONSTRAINT "rag_passages_page_start_check" CHECK ((("page_start" IS NULL) OR ("page_start" > 0))),
    CONSTRAINT "rag_passages_source_reference_check" CHECK ((("btrim"("source_reference") <> ''::"text") AND ("char_length"("source_reference") <= 500))),
    CONSTRAINT "rag_passages_token_count_check" CHECK ((("token_count" IS NULL) OR ("token_count" > 0)))
);

ALTER TABLE ONLY "internal"."rag_passages" FORCE ROW LEVEL SECURITY;


ALTER TABLE "internal"."rag_passages" OWNER TO "postgres";


COMMENT ON TABLE "internal"."rag_passages" IS 'Passages citables et embeddings des documents RAG.';



COMMENT ON COLUMN "internal"."rag_passages"."source_reference" IS 'Référence présentable à l’utilisateur, par exemple page, article et section.';



CREATE TABLE IF NOT EXISTS "internal"."rate_limits" (
    "subject_type" "text" NOT NULL,
    "subject_id" "text" NOT NULL,
    "window_start" timestamp with time zone NOT NULL,
    "count" integer DEFAULT 0 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "rate_limits_count_check" CHECK (("count" >= 0)),
    CONSTRAINT "rate_limits_subject_type_check" CHECK (("subject_type" = ANY (ARRAY['message'::"text", 'reaction'::"text", 'activation'::"text", 'push'::"text", 'rag_upload_admin'::"text"])))
);


ALTER TABLE "internal"."rate_limits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "internal"."security_log" (
    "id" bigint NOT NULL,
    "event_type" "text" NOT NULL,
    "user_uuid" "uuid",
    "device_auth_uid" "uuid",
    "institution_id" "text",
    "actor_admin_uuid" "uuid",
    "detail" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "internal"."security_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "internal"."security_log_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "internal"."security_log_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "internal"."security_log_id_seq" OWNED BY "internal"."security_log"."id";



CREATE TABLE IF NOT EXISTS "internal"."user_channel_memberships" (
    "user_uuid" "uuid" NOT NULL,
    "institution_id" "text" NOT NULL,
    "channel_id" "text" NOT NULL,
    "granted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "granted_by" "uuid"
);


ALTER TABLE "internal"."user_channel_memberships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "internal"."user_roles" (
    "user_uuid" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "granted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_roles_role_check" CHECK (("role" = ANY (ARRAY['cadre'::"text", 'admin'::"text", 'admin_readonly'::"text"])))
);


ALTER TABLE "internal"."user_roles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "internal"."users" (
    "user_uuid" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "display_name" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "institution_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "goodbarber_user_id" "text",
    CONSTRAINT "users_goodbarber_user_id_not_blank" CHECK ((("goodbarber_user_id" IS NULL) OR (("length"(TRIM(BOTH FROM "goodbarber_user_id")) >= 1) AND ("length"(TRIM(BOTH FROM "goodbarber_user_id")) <= 250))))
);


ALTER TABLE "internal"."users" OWNER TO "postgres";


COMMENT ON COLUMN "internal"."users"."goodbarber_user_id" IS 'Identifiant du compte GoodBarber. Sert à regrouper plusieurs appareils d’un même collaborateur. Information vérifiée et confirmée par l’administrateur lors de l’activation.';



CREATE TABLE IF NOT EXISTS "public"."gb_78487711_chat_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "body" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "group_id" "text" DEFAULT 'all'::"text" NOT NULL,
    "user_id" "text",
    "edited" boolean DEFAULT false NOT NULL,
    "deleted" boolean DEFAULT false NOT NULL,
    "deleted_at" timestamp with time zone,
    "reply_to_id" "uuid",
    "reply_to_first_name" "text",
    "reply_to_last_name" "text",
    "reply_to_body" "text",
    "institution_id" "text" NOT NULL,
    "author_user_uuid" "uuid"
);


ALTER TABLE "public"."gb_78487711_chat_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gb_78487711_chat_pins" (
    "group_id" "text" NOT NULL,
    "message_id" "uuid",
    "pinned_by_user_id" "text",
    "pinned_at" timestamp with time zone,
    "pinned_until" timestamp with time zone,
    "institution_id" "text" NOT NULL,
    "pinned_by_user_uuid" "uuid",
    CONSTRAINT "gb_78487711_chat_pins_consistent_state" CHECK (((("message_id" IS NULL) AND ("pinned_by_user_id" IS NULL) AND ("pinned_at" IS NULL) AND ("pinned_until" IS NULL)) OR (("message_id" IS NOT NULL) AND ("pinned_by_user_id" IS NOT NULL) AND ("pinned_at" IS NOT NULL) AND ("pinned_until" IS NOT NULL) AND ("pinned_until" > "pinned_at"))))
);


ALTER TABLE "public"."gb_78487711_chat_pins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gb_78487711_chat_reactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "message_id" "uuid" NOT NULL,
    "group_id" "text" NOT NULL,
    "user_id" "text" NOT NULL,
    "emoji" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "institution_id" "text" NOT NULL,
    "user_uuid" "uuid"
);


ALTER TABLE "public"."gb_78487711_chat_reactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."gb_78487711_chat_reads" (
    "user_id" "text" NOT NULL,
    "group_id" "text" NOT NULL,
    "last_read_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "institution_id" "text" NOT NULL,
    "user_uuid" "uuid"
);


ALTER TABLE "public"."gb_78487711_chat_reads" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."proto_devices" (
    "device_auth_uid" "uuid" NOT NULL,
    "user_uuid" "uuid",
    "activated" boolean DEFAULT false NOT NULL,
    "activated_at" timestamp with time zone,
    "revoked_at" timestamp with time zone
);


ALTER TABLE "public"."proto_devices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."proto_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "body" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."proto_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."proto_people" (
    "user_uuid" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "display_name" "text",
    "active" boolean DEFAULT true NOT NULL
);


ALTER TABLE "public"."proto_people" OWNER TO "postgres";


ALTER TABLE ONLY "internal"."security_log" ALTER COLUMN "id" SET DEFAULT "nextval"('"internal"."security_log_id_seq"'::"regclass");



ALTER TABLE ONLY "internal"."activation_tokens"
    ADD CONSTRAINT "activation_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "internal"."activation_tokens"
    ADD CONSTRAINT "activation_tokens_token_hash_key" UNIQUE ("token_hash");



ALTER TABLE ONLY "internal"."backoffice_auth_links"
    ADD CONSTRAINT "backoffice_auth_links_pkey" PRIMARY KEY ("link_id");



ALTER TABLE ONLY "internal"."channels"
    ADD CONSTRAINT "channels_pkey" PRIMARY KEY ("institution_id", "channel_id");



ALTER TABLE ONLY "internal"."device_activation_requests"
    ADD CONSTRAINT "device_activation_requests_approval_token_hash_key" UNIQUE ("approval_token_hash");



ALTER TABLE ONLY "internal"."device_activation_requests"
    ADD CONSTRAINT "device_activation_requests_pkey" PRIMARY KEY ("request_id");



ALTER TABLE ONLY "internal"."devices"
    ADD CONSTRAINT "devices_pkey" PRIMARY KEY ("device_auth_uid");



ALTER TABLE ONLY "internal"."institutions"
    ADD CONSTRAINT "institutions_pkey" PRIMARY KEY ("institution_id");



ALTER TABLE ONLY "internal"."rag_documents"
    ADD CONSTRAINT "rag_documents_document_institution_unique" UNIQUE ("document_id", "institution_id");



ALTER TABLE ONLY "internal"."rag_documents"
    ADD CONSTRAINT "rag_documents_file_hash_unique" UNIQUE ("institution_id", "file_sha256");



ALTER TABLE ONLY "internal"."rag_documents"
    ADD CONSTRAINT "rag_documents_pkey" PRIMARY KEY ("document_id");



ALTER TABLE ONLY "internal"."rag_documents"
    ADD CONSTRAINT "rag_documents_storage_path_unique" UNIQUE ("storage_path");



ALTER TABLE ONLY "internal"."rag_documents"
    ADD CONSTRAINT "rag_documents_version_unique" UNIQUE ("institution_id", "document_key", "version_label");



ALTER TABLE ONLY "internal"."rag_ingestion_jobs"
    ADD CONSTRAINT "rag_ingestion_jobs_pkey" PRIMARY KEY ("job_id");



ALTER TABLE ONLY "internal"."rag_passages"
    ADD CONSTRAINT "rag_passages_document_chunk_unique" UNIQUE ("document_id", "chunk_index");



ALTER TABLE ONLY "internal"."rag_passages"
    ADD CONSTRAINT "rag_passages_pkey" PRIMARY KEY ("passage_id");



ALTER TABLE ONLY "internal"."rate_limits"
    ADD CONSTRAINT "rate_limits_pkey" PRIMARY KEY ("subject_type", "subject_id", "window_start");



ALTER TABLE ONLY "internal"."security_log"
    ADD CONSTRAINT "security_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "internal"."user_channel_memberships"
    ADD CONSTRAINT "user_channel_memberships_pkey" PRIMARY KEY ("user_uuid", "institution_id", "channel_id");



ALTER TABLE ONLY "internal"."user_roles"
    ADD CONSTRAINT "user_roles_pkey" PRIMARY KEY ("user_uuid", "role");



ALTER TABLE ONLY "internal"."users"
    ADD CONSTRAINT "users_pkey" PRIMARY KEY ("user_uuid");



ALTER TABLE ONLY "internal"."users"
    ADD CONSTRAINT "users_user_uuid_institution_unique" UNIQUE ("user_uuid", "institution_id");



ALTER TABLE ONLY "public"."gb_78487711_chat_messages"
    ADD CONSTRAINT "gb_78487711_chat_messages_id_institution_group_unique" UNIQUE ("id", "institution_id", "group_id");



ALTER TABLE ONLY "public"."gb_78487711_chat_messages"
    ADD CONSTRAINT "gb_78487711_chat_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gb_78487711_chat_pins"
    ADD CONSTRAINT "gb_78487711_chat_pins_pkey" PRIMARY KEY ("institution_id", "group_id");



ALTER TABLE ONLY "public"."gb_78487711_chat_reactions"
    ADD CONSTRAINT "gb_78487711_chat_reactions_message_id_user_id_emoji_key" UNIQUE ("message_id", "user_id", "emoji");



ALTER TABLE ONLY "public"."gb_78487711_chat_reactions"
    ADD CONSTRAINT "gb_78487711_chat_reactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."gb_78487711_chat_reads"
    ADD CONSTRAINT "gb_78487711_chat_reads_pkey" PRIMARY KEY ("institution_id", "user_id", "group_id");



ALTER TABLE ONLY "public"."proto_devices"
    ADD CONSTRAINT "proto_devices_pkey" PRIMARY KEY ("device_auth_uid");



ALTER TABLE ONLY "public"."proto_messages"
    ADD CONSTRAINT "proto_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."proto_people"
    ADD CONSTRAINT "proto_people_pkey" PRIMARY KEY ("user_uuid");



CREATE INDEX "activation_tokens_user_uuid_idx" ON "internal"."activation_tokens" USING "btree" ("user_uuid");



CREATE UNIQUE INDEX "backoffice_auth_links_auth_uid_unique" ON "internal"."backoffice_auth_links" USING "btree" ("backoffice_auth_uid") WHERE ("revoked_at" IS NULL);



CREATE INDEX "backoffice_auth_links_user_idx" ON "internal"."backoffice_auth_links" USING "btree" ("user_uuid", "institution_id") WHERE ("revoked_at" IS NULL);



CREATE INDEX "device_activation_requests_institution_status_idx" ON "internal"."device_activation_requests" USING "btree" ("institution_id", "status", "created_at" DESC);



CREATE UNIQUE INDEX "device_activation_requests_one_pending_per_device" ON "internal"."device_activation_requests" USING "btree" ("device_auth_uid") WHERE ("status" = 'pending'::"text");



CREATE INDEX "device_activation_requests_pending_expiration_idx" ON "internal"."device_activation_requests" USING "btree" ("expires_at") WHERE ("status" = 'pending'::"text");



CREATE INDEX "devices_user_uuid_idx" ON "internal"."devices" USING "btree" ("user_uuid");



CREATE INDEX "rag_documents_institution_category_idx" ON "internal"."rag_documents" USING "btree" ("institution_id", "category") WHERE ("status" = 'active'::"text");



CREATE INDEX "rag_documents_institution_status_idx" ON "internal"."rag_documents" USING "btree" ("institution_id", "status", "updated_at" DESC);



CREATE UNIQUE INDEX "rag_documents_one_active_version_idx" ON "internal"."rag_documents" USING "btree" ("institution_id", "document_key") WHERE ("status" = 'active'::"text");



CREATE INDEX "rag_ingestion_jobs_institution_idx" ON "internal"."rag_ingestion_jobs" USING "btree" ("institution_id", "created_at" DESC);



CREATE UNIQUE INDEX "rag_ingestion_jobs_one_open_per_document_idx" ON "internal"."rag_ingestion_jobs" USING "btree" ("document_id") WHERE ("status" = ANY (ARRAY['queued'::"text", 'running'::"text"]));



CREATE INDEX "rag_ingestion_jobs_queue_idx" ON "internal"."rag_ingestion_jobs" USING "btree" ("status", "created_at") WHERE ("status" = ANY (ARRAY['queued'::"text", 'running'::"text"]));



CREATE INDEX "rag_passages_document_idx" ON "internal"."rag_passages" USING "btree" ("document_id", "chunk_index");



CREATE INDEX "rag_passages_institution_idx" ON "internal"."rag_passages" USING "btree" ("institution_id", "document_id");



CREATE INDEX "rag_passages_pending_embedding_idx" ON "internal"."rag_passages" USING "btree" ("institution_id", "document_id", "chunk_index") WHERE ("embedding" IS NULL);



CREATE INDEX "rate_limits_window_start_idx" ON "internal"."rate_limits" USING "btree" ("window_start");



CREATE INDEX "security_log_created_at_idx" ON "internal"."security_log" USING "btree" ("created_at");



CREATE INDEX "security_log_device_auth_uid_idx" ON "internal"."security_log" USING "btree" ("device_auth_uid");



CREATE INDEX "security_log_user_event_created_idx" ON "internal"."security_log" USING "btree" ("user_uuid", "event_type", "created_at" DESC) WHERE ("user_uuid" IS NOT NULL);



CREATE INDEX "security_log_user_uuid_idx" ON "internal"."security_log" USING "btree" ("user_uuid");



CREATE INDEX "user_channel_memberships_channel_idx" ON "internal"."user_channel_memberships" USING "btree" ("institution_id", "channel_id");



CREATE UNIQUE INDEX "users_one_goodbarber_id_per_institution" ON "internal"."users" USING "btree" ("institution_id", "goodbarber_user_id") WHERE ("goodbarber_user_id" IS NOT NULL);



CREATE INDEX "gb_78487711_chat_messages_author_created_idx" ON "public"."gb_78487711_chat_messages" USING "btree" ("institution_id", "author_user_uuid", "created_at" DESC) WHERE ("author_user_uuid" IS NOT NULL);



CREATE INDEX "gb_78487711_chat_messages_group_created_idx" ON "public"."gb_78487711_chat_messages" USING "btree" ("group_id", "created_at");



CREATE INDEX "gb_78487711_chat_messages_institution_channel_created_idx" ON "public"."gb_78487711_chat_messages" USING "btree" ("institution_id", "group_id", "created_at" DESC);



CREATE INDEX "gb_78487711_chat_reactions_group_message_idx" ON "public"."gb_78487711_chat_reactions" USING "btree" ("group_id", "message_id");



CREATE UNIQUE INDEX "gb_78487711_chat_reactions_message_user_uuid_emoji_key" ON "public"."gb_78487711_chat_reactions" USING "btree" ("message_id", "user_uuid", "emoji") WHERE ("user_uuid" IS NOT NULL);



CREATE UNIQUE INDEX "gb_78487711_chat_reads_institution_user_uuid_group_key" ON "public"."gb_78487711_chat_reads" USING "btree" ("institution_id", "user_uuid", "group_id") WHERE ("user_uuid" IS NOT NULL);



CREATE OR REPLACE TRIGGER "rag_documents_set_updated_at" BEFORE UPDATE ON "internal"."rag_documents" FOR EACH ROW EXECUTE FUNCTION "internal"."rag_set_updated_at"();



CREATE OR REPLACE TRIGGER "rag_ingestion_jobs_set_updated_at" BEFORE UPDATE ON "internal"."rag_ingestion_jobs" FOR EACH ROW EXECUTE FUNCTION "internal"."rag_set_updated_at"();



CREATE OR REPLACE TRIGGER "rag_passages_set_updated_at" BEFORE UPDATE ON "internal"."rag_passages" FOR EACH ROW EXECUTE FUNCTION "internal"."rag_set_updated_at"();



ALTER TABLE ONLY "internal"."activation_tokens"
    ADD CONSTRAINT "activation_tokens_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "internal"."users"("user_uuid") ON DELETE SET NULL;



ALTER TABLE ONLY "internal"."activation_tokens"
    ADD CONSTRAINT "activation_tokens_user_uuid_fkey" FOREIGN KEY ("user_uuid") REFERENCES "internal"."users"("user_uuid") ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."backoffice_auth_links"
    ADD CONSTRAINT "backoffice_auth_links_auth_uid_fkey" FOREIGN KEY ("backoffice_auth_uid") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."backoffice_auth_links"
    ADD CONSTRAINT "backoffice_auth_links_user_fkey" FOREIGN KEY ("user_uuid", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "internal"."channels"
    ADD CONSTRAINT "channels_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "internal"."institutions"("institution_id") ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."device_activation_requests"
    ADD CONSTRAINT "device_activation_requests_approved_user_fkey" FOREIGN KEY ("approved_user_uuid", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "internal"."device_activation_requests"
    ADD CONSTRAINT "device_activation_requests_device_fkey" FOREIGN KEY ("device_auth_uid") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."device_activation_requests"
    ADD CONSTRAINT "device_activation_requests_institution_fkey" FOREIGN KEY ("institution_id") REFERENCES "internal"."institutions"("institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "internal"."devices"
    ADD CONSTRAINT "devices_device_auth_uid_fkey" FOREIGN KEY ("device_auth_uid") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."devices"
    ADD CONSTRAINT "devices_user_uuid_fkey" FOREIGN KEY ("user_uuid") REFERENCES "internal"."users"("user_uuid") ON DELETE RESTRICT;



ALTER TABLE ONLY "internal"."rag_documents"
    ADD CONSTRAINT "rag_documents_institution_fk" FOREIGN KEY ("institution_id") REFERENCES "internal"."institutions"("institution_id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "internal"."rag_documents"
    ADD CONSTRAINT "rag_documents_uploader_institution_fk" FOREIGN KEY ("uploaded_by", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "internal"."rag_ingestion_jobs"
    ADD CONSTRAINT "rag_ingestion_jobs_document_institution_fk" FOREIGN KEY ("document_id", "institution_id") REFERENCES "internal"."rag_documents"("document_id", "institution_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."rag_ingestion_jobs"
    ADD CONSTRAINT "rag_ingestion_jobs_requester_institution_fk" FOREIGN KEY ("requested_by", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "internal"."rag_passages"
    ADD CONSTRAINT "rag_passages_document_institution_fk" FOREIGN KEY ("document_id", "institution_id") REFERENCES "internal"."rag_documents"("document_id", "institution_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."user_channel_memberships"
    ADD CONSTRAINT "user_channel_memberships_channel_fkey" FOREIGN KEY ("institution_id", "channel_id") REFERENCES "internal"."channels"("institution_id", "channel_id") ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."user_channel_memberships"
    ADD CONSTRAINT "user_channel_memberships_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "internal"."users"("user_uuid") ON DELETE SET NULL;



ALTER TABLE ONLY "internal"."user_channel_memberships"
    ADD CONSTRAINT "user_channel_memberships_user_institution_fkey" FOREIGN KEY ("user_uuid", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."user_roles"
    ADD CONSTRAINT "user_roles_user_uuid_fkey" FOREIGN KEY ("user_uuid") REFERENCES "internal"."users"("user_uuid") ON DELETE CASCADE;



ALTER TABLE ONLY "internal"."users"
    ADD CONSTRAINT "users_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "internal"."institutions"("institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_messages"
    ADD CONSTRAINT "gb_78487711_chat_messages_author_user_fkey" FOREIGN KEY ("author_user_uuid", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_messages"
    ADD CONSTRAINT "gb_78487711_chat_messages_channel_fkey" FOREIGN KEY ("institution_id", "group_id") REFERENCES "internal"."channels"("institution_id", "channel_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_messages"
    ADD CONSTRAINT "gb_78487711_chat_messages_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "internal"."institutions"("institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_messages"
    ADD CONSTRAINT "gb_78487711_chat_messages_reply_to_id_fkey" FOREIGN KEY ("reply_to_id") REFERENCES "public"."gb_78487711_chat_messages"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."gb_78487711_chat_pins"
    ADD CONSTRAINT "gb_78487711_chat_pins_channel_fkey" FOREIGN KEY ("institution_id", "group_id") REFERENCES "internal"."channels"("institution_id", "channel_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_pins"
    ADD CONSTRAINT "gb_78487711_chat_pins_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "internal"."institutions"("institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_pins"
    ADD CONSTRAINT "gb_78487711_chat_pins_message_coherence_fkey" FOREIGN KEY ("message_id", "institution_id", "group_id") REFERENCES "public"."gb_78487711_chat_messages"("id", "institution_id", "group_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_pins"
    ADD CONSTRAINT "gb_78487711_chat_pins_pinned_by_user_fkey" FOREIGN KEY ("pinned_by_user_uuid", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_reactions"
    ADD CONSTRAINT "gb_78487711_chat_reactions_channel_fkey" FOREIGN KEY ("institution_id", "group_id") REFERENCES "internal"."channels"("institution_id", "channel_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_reactions"
    ADD CONSTRAINT "gb_78487711_chat_reactions_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "internal"."institutions"("institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_reactions"
    ADD CONSTRAINT "gb_78487711_chat_reactions_message_coherence_fkey" FOREIGN KEY ("message_id", "institution_id", "group_id") REFERENCES "public"."gb_78487711_chat_messages"("id", "institution_id", "group_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."gb_78487711_chat_reactions"
    ADD CONSTRAINT "gb_78487711_chat_reactions_user_fkey" FOREIGN KEY ("user_uuid", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_reads"
    ADD CONSTRAINT "gb_78487711_chat_reads_channel_fkey" FOREIGN KEY ("institution_id", "group_id") REFERENCES "internal"."channels"("institution_id", "channel_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_reads"
    ADD CONSTRAINT "gb_78487711_chat_reads_institution_id_fkey" FOREIGN KEY ("institution_id") REFERENCES "internal"."institutions"("institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."gb_78487711_chat_reads"
    ADD CONSTRAINT "gb_78487711_chat_reads_user_fkey" FOREIGN KEY ("user_uuid", "institution_id") REFERENCES "internal"."users"("user_uuid", "institution_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."proto_devices"
    ADD CONSTRAINT "proto_devices_user_uuid_fkey" FOREIGN KEY ("user_uuid") REFERENCES "public"."proto_people"("user_uuid");



ALTER TABLE "internal"."activation_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."backoffice_auth_links" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."channels" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."device_activation_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."institutions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."rag_documents" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."rag_ingestion_jobs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."rag_passages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."rate_limits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."security_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."user_channel_memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."user_roles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "internal"."users" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."gb_78487711_chat_messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gb_78487711_chat_messages_select_own_channel" ON "public"."gb_78487711_chat_messages" FOR SELECT TO "authenticated" USING (( SELECT "internal"."current_user_has_channel"("gb_78487711_chat_messages"."institution_id", "gb_78487711_chat_messages"."group_id") AS "current_user_has_channel"));



ALTER TABLE "public"."gb_78487711_chat_pins" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gb_78487711_chat_pins_select_own_channel" ON "public"."gb_78487711_chat_pins" FOR SELECT TO "authenticated" USING (( SELECT "internal"."current_user_has_channel"("gb_78487711_chat_pins"."institution_id", "gb_78487711_chat_pins"."group_id") AS "current_user_has_channel"));



ALTER TABLE "public"."gb_78487711_chat_reactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gb_78487711_chat_reactions_select_own_channel" ON "public"."gb_78487711_chat_reactions" FOR SELECT TO "authenticated" USING (( SELECT "internal"."current_user_has_channel"("gb_78487711_chat_reactions"."institution_id", "gb_78487711_chat_reactions"."group_id") AS "current_user_has_channel"));



ALTER TABLE "public"."gb_78487711_chat_reads" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "gb_78487711_chat_reads_select_own" ON "public"."gb_78487711_chat_reads" FOR SELECT TO "authenticated" USING ((( SELECT "internal"."current_user_has_channel"("gb_78487711_chat_reads"."institution_id", "gb_78487711_chat_reads"."group_id") AS "current_user_has_channel") AND ( SELECT "internal"."current_user_matches"("gb_78487711_chat_reads"."user_uuid") AS "current_user_matches")));



ALTER TABLE "public"."proto_devices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."proto_messages" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "proto_messages_select" ON "public"."proto_messages" FOR SELECT TO "authenticated" USING (( SELECT "public"."proto_device_is_active"() AS "proto_device_is_active"));



ALTER TABLE "public"."proto_people" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."gb_78487711_chat_messages";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."gb_78487711_chat_pins";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."gb_78487711_chat_reactions";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."proto_messages";



GRANT USAGE ON SCHEMA "api" TO "service_role";



GRANT USAGE ON SCHEMA "internal" TO "service_role";
GRANT USAGE ON SCHEMA "internal" TO "authenticated";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT USAGE ON SCHEMA "server_api" TO "service_role";












































































































































































































































































































































































































































































































REVOKE ALL ON FUNCTION "internal"."current_device_and_user_ok"() FROM PUBLIC;
GRANT ALL ON FUNCTION "internal"."current_device_and_user_ok"() TO "authenticated";



REVOKE ALL ON FUNCTION "internal"."current_user_has_channel"("p_institution_id" "text", "p_channel_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "internal"."current_user_has_channel"("p_institution_id" "text", "p_channel_id" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "internal"."current_user_has_role"("p_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "internal"."current_user_has_role"("p_role" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "internal"."current_user_matches"("p_user_uuid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "internal"."current_user_matches"("p_user_uuid" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "internal"."rag_set_updated_at"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."activate_device_wrapper"("p_device_auth_uid" "uuid", "p_token_hash" "text", "p_method" "text", "p_ip_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."activate_device_wrapper"("p_device_auth_uid" "uuid", "p_token_hash" "text", "p_method" "text", "p_ip_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."activate_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."activate_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."append_rag_passage_batch_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_passages" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."append_rag_passage_batch_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_passages" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_backoffice_request_wrapper"("p_request_id" "uuid", "p_institution_id" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_backoffice_request_wrapper"("p_request_id" "uuid", "p_institution_id" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."approve_device_activation_request_wrapper"("p_request_id" "uuid", "p_approval_token_hash" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."approve_device_activation_request_wrapper"("p_request_id" "uuid", "p_approval_token_hash" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."cancel_device_activation_request_wrapper"("p_request_id" "uuid", "p_device_auth_uid" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_device_activation_request_wrapper"("p_request_id" "uuid", "p_device_auth_uid" "uuid", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."check_backoffice_role_wrapper"("p_auth_uid" "uuid", "p_required_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."check_backoffice_role_wrapper"("p_auth_uid" "uuid", "p_required_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_extraction_method" "text", "p_extraction_version" "text", "p_page_count" integer, "p_extraction_metadata" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_extraction_method" "text", "p_extraction_version" "text", "p_page_count" integer, "p_extraction_metadata" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_device_activation_request_wrapper"("p_device_auth_uid" "uuid", "p_institution_id" "text", "p_suggested_display_name" "text", "p_suggested_email" "text", "p_suggested_goodbarber_user_id" "text", "p_suggested_groups" "jsonb", "p_approval_token_hash" "text", "p_ip_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_device_activation_request_wrapper"("p_device_auth_uid" "uuid", "p_institution_id" "text", "p_suggested_display_name" "text", "p_suggested_email" "text", "p_suggested_goodbarber_user_id" "text", "p_suggested_groups" "jsonb", "p_approval_token_hash" "text", "p_ip_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_chat_message"("p_message_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_chat_message"("p_message_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."delete_chat_message"("p_message_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."edit_chat_message"("p_message_id" "uuid", "p_body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."edit_chat_message"("p_message_id" "uuid", "p_body" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."edit_chat_message"("p_message_id" "uuid", "p_body" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."fail_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_error_code" "text", "p_error_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fail_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_error_code" "text", "p_error_message" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_backoffice_dashboard_wrapper"("p_institution_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_backoffice_dashboard_wrapper"("p_institution_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_backoffice_pending_requests_wrapper"("p_institution_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_backoffice_pending_requests_wrapper"("p_institution_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_backoffice_request_detail_wrapper"("p_request_id" "uuid", "p_institution_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_backoffice_request_detail_wrapper"("p_request_id" "uuid", "p_institution_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_chat_context"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_chat_context"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_chat_context"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_device_activation_request_for_approval_wrapper"("p_request_id" "uuid", "p_approval_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_device_activation_request_for_approval_wrapper"("p_request_id" "uuid", "p_approval_token_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_rag_documents_wrapper"("p_auth_uid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_rag_documents_wrapper"("p_auth_uid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."mark_chat_channel_read"("p_group_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_chat_channel_read"("p_group_id" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."mark_chat_channel_read"("p_group_id" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."pin_chat_message"("p_message_id" "uuid", "p_duration_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."pin_chat_message"("p_message_id" "uuid", "p_duration_code" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."pin_chat_message"("p_message_id" "uuid", "p_duration_code" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."proto_device_is_active"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."proto_device_is_active"() TO "service_role";
GRANT ALL ON FUNCTION "public"."proto_device_is_active"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."register_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_document_key" "text", "p_title" "text", "p_category" "text", "p_version_label" "text", "p_effective_date" "date", "p_storage_path" "text", "p_original_file_name" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_file_sha256" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."register_rag_document_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_document_key" "text", "p_title" "text", "p_category" "text", "p_version_label" "text", "p_effective_date" "date", "p_storage_path" "text", "p_original_file_name" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_file_sha256" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."send_chat_message"("p_group_id" "text", "p_body" "text", "p_reply_to_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."send_chat_message"("p_group_id" "text", "p_body" "text", "p_reply_to_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."send_chat_message"("p_group_id" "text", "p_body" "text", "p_reply_to_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_rag_ingestion_plan_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_total_items" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_rag_ingestion_plan_wrapper"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_total_items" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."start_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_worker_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."start_rag_ingestion_wrapper"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_worker_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."toggle_chat_reaction"("p_message_id" "uuid", "p_emoji" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."toggle_chat_reaction"("p_message_id" "uuid", "p_emoji" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."toggle_chat_reaction"("p_message_id" "uuid", "p_emoji" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."unpin_chat_message"("p_group_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unpin_chat_message"("p_group_id" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."unpin_chat_message"("p_group_id" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "server_api"."activate_device"("p_device_auth_uid" "uuid", "p_token_hash" "text", "p_method" "text", "p_ip_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."activate_device"("p_device_auth_uid" "uuid", "p_token_hash" "text", "p_method" "text", "p_ip_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."activate_rag_document"("p_auth_uid" "uuid", "p_document_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."append_rag_passage_batch"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_passages" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."approve_backoffice_request"("p_request_id" "uuid", "p_institution_id" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."approve_backoffice_request"("p_request_id" "uuid", "p_institution_id" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."approve_device_activation_request"("p_request_id" "uuid", "p_approval_token_hash" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."approve_device_activation_request"("p_request_id" "uuid", "p_approval_token_hash" "text", "p_display_name" "text", "p_channel_ids" "text"[], "p_confirmed_goodbarber_user_id" "text", "p_existing_user_uuid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."cancel_device_activation_request"("p_request_id" "uuid", "p_device_auth_uid" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."cancel_device_activation_request"("p_request_id" "uuid", "p_device_auth_uid" "uuid", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."check_backoffice_role"("p_auth_uid" "uuid", "p_required_role" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."check_backoffice_role"("p_auth_uid" "uuid", "p_required_role" "text") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."complete_rag_ingestion"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_extraction_method" "text", "p_extraction_version" "text", "p_page_count" integer, "p_extraction_metadata" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."create_device_activation_request"("p_device_auth_uid" "uuid", "p_institution_id" "text", "p_suggested_display_name" "text", "p_suggested_email" "text", "p_suggested_goodbarber_user_id" "text", "p_suggested_groups" "jsonb", "p_approval_token_hash" "text", "p_ip_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."create_device_activation_request"("p_device_auth_uid" "uuid", "p_institution_id" "text", "p_suggested_display_name" "text", "p_suggested_email" "text", "p_suggested_goodbarber_user_id" "text", "p_suggested_groups" "jsonb", "p_approval_token_hash" "text", "p_ip_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."delete_chat_message"("p_message_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."edit_chat_message"("p_message_id" "uuid", "p_body" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."fail_rag_ingestion"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_error_code" "text", "p_error_message" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."get_backoffice_dashboard"("p_institution_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."get_backoffice_dashboard"("p_institution_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."get_backoffice_identity"("p_auth_uid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."get_backoffice_identity"("p_auth_uid" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."get_backoffice_pending_requests"("p_institution_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."get_backoffice_pending_requests"("p_institution_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."get_backoffice_request_detail"("p_request_id" "uuid", "p_institution_id" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."get_backoffice_request_detail"("p_request_id" "uuid", "p_institution_id" "text") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."get_chat_context"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."get_device_activation_request_for_approval"("p_request_id" "uuid", "p_approval_token_hash" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "server_api"."get_device_activation_request_for_approval"("p_request_id" "uuid", "p_approval_token_hash" "text") TO "service_role";



REVOKE ALL ON FUNCTION "server_api"."list_rag_documents"("p_auth_uid" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."mark_chat_channel_read"("p_group_id" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."pin_chat_message"("p_message_id" "uuid", "p_duration_code" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."register_rag_document"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_document_key" "text", "p_title" "text", "p_category" "text", "p_version_label" "text", "p_effective_date" "date", "p_storage_path" "text", "p_original_file_name" "text", "p_mime_type" "text", "p_file_size_bytes" bigint, "p_file_sha256" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."send_chat_message"("p_group_id" "text", "p_body" "text", "p_reply_to_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."set_rag_ingestion_plan"("p_auth_uid" "uuid", "p_job_id" "uuid", "p_worker_id" "text", "p_total_items" integer) FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."start_rag_ingestion"("p_auth_uid" "uuid", "p_document_id" "uuid", "p_worker_id" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."toggle_chat_reaction"("p_message_id" "uuid", "p_emoji" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "server_api"."unpin_chat_message"("p_group_id" "text") FROM PUBLIC;






























GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "internal"."backoffice_auth_links" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "internal"."device_activation_requests" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "internal"."rag_documents" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "internal"."rag_ingestion_jobs" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "internal"."rag_passages" TO "service_role";



GRANT ALL ON TABLE "public"."gb_78487711_chat_messages" TO "service_role";
GRANT SELECT ON TABLE "public"."gb_78487711_chat_messages" TO "authenticated";



GRANT ALL ON TABLE "public"."gb_78487711_chat_pins" TO "service_role";
GRANT SELECT ON TABLE "public"."gb_78487711_chat_pins" TO "authenticated";



GRANT ALL ON TABLE "public"."gb_78487711_chat_reactions" TO "service_role";
GRANT SELECT ON TABLE "public"."gb_78487711_chat_reactions" TO "authenticated";



GRANT ALL ON TABLE "public"."gb_78487711_chat_reads" TO "service_role";
GRANT SELECT ON TABLE "public"."gb_78487711_chat_reads" TO "authenticated";



GRANT ALL ON TABLE "public"."proto_devices" TO "anon";
GRANT ALL ON TABLE "public"."proto_devices" TO "authenticated";
GRANT ALL ON TABLE "public"."proto_devices" TO "service_role";



GRANT ALL ON TABLE "public"."proto_messages" TO "anon";
GRANT ALL ON TABLE "public"."proto_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."proto_messages" TO "service_role";



GRANT ALL ON TABLE "public"."proto_people" TO "anon";
GRANT ALL ON TABLE "public"."proto_people" TO "authenticated";
GRANT ALL ON TABLE "public"."proto_people" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";



































drop extension if exists "pg_net";

revoke references on table "public"."gb_78487711_chat_messages" from "anon";

revoke trigger on table "public"."gb_78487711_chat_messages" from "anon";

revoke truncate on table "public"."gb_78487711_chat_messages" from "anon";

revoke references on table "public"."gb_78487711_chat_messages" from "authenticated";

revoke trigger on table "public"."gb_78487711_chat_messages" from "authenticated";

revoke truncate on table "public"."gb_78487711_chat_messages" from "authenticated";

revoke references on table "public"."gb_78487711_chat_pins" from "anon";

revoke trigger on table "public"."gb_78487711_chat_pins" from "anon";

revoke truncate on table "public"."gb_78487711_chat_pins" from "anon";

revoke references on table "public"."gb_78487711_chat_pins" from "authenticated";

revoke trigger on table "public"."gb_78487711_chat_pins" from "authenticated";

revoke truncate on table "public"."gb_78487711_chat_pins" from "authenticated";

revoke references on table "public"."gb_78487711_chat_reactions" from "anon";

revoke trigger on table "public"."gb_78487711_chat_reactions" from "anon";

revoke truncate on table "public"."gb_78487711_chat_reactions" from "anon";

revoke references on table "public"."gb_78487711_chat_reactions" from "authenticated";

revoke trigger on table "public"."gb_78487711_chat_reactions" from "authenticated";

revoke truncate on table "public"."gb_78487711_chat_reactions" from "authenticated";

revoke references on table "public"."gb_78487711_chat_reads" from "anon";

revoke trigger on table "public"."gb_78487711_chat_reads" from "anon";

revoke truncate on table "public"."gb_78487711_chat_reads" from "anon";

revoke references on table "public"."gb_78487711_chat_reads" from "authenticated";

revoke trigger on table "public"."gb_78487711_chat_reads" from "authenticated";

revoke truncate on table "public"."gb_78487711_chat_reads" from "authenticated";


