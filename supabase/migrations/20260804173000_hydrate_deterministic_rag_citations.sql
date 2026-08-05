/*
  Rend les passages sources des règles validées disponibles au moteur
  déterministe, même lorsqu'ils ne figurent pas dans le top-k de la recherche
  sémantique. L'institution est toujours dérivée de l'appareil authentifié.
*/

begin;

create or replace function server_api.get_rag_citation_passages(
  p_auth_uid uuid,
  p_passage_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_institution_id text;
  v_passages jsonb;
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

  if p_passage_ids is null
     or pg_catalog.cardinality(p_passage_ids) < 1
     or pg_catalog.cardinality(p_passage_ids) > 20
     or pg_catalog.array_position(p_passage_ids, null::uuid) is not null
  then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'status_code', 'invalid_passage_ids'
    );
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'passage_id', x.passage_id,
        'document_id', x.document_id,
        'title', x.title,
        'version_label', x.version_label,
        'effective_date', x.effective_date,
        'page_start', x.page_start,
        'page_end', x.page_end,
        'section_title', x.section_title,
        'article_reference', x.article_reference,
        'source_reference', x.source_reference,
        'content', x.content,
        'similarity', 1.0
      )
      order by x.document_id, x.chunk_index, x.passage_id
    ),
    '[]'::jsonb
  )
  into v_passages
  from (
    select distinct
      p.passage_id,
      p.document_id,
      p.chunk_index,
      p.content,
      p.page_start,
      p.page_end,
      p.section_title,
      p.article_reference,
      p.source_reference,
      d.title,
      d.version_label,
      d.effective_date
    from internal.rag_passages p
    join internal.rag_documents d
      on d.document_id = p.document_id
     and d.institution_id = p.institution_id
    join internal.rag_rule_sources src
      on src.passage_id = p.passage_id
     and src.document_id = p.document_id
     and src.institution_id = p.institution_id
    join internal.rag_rule_sets s
      on s.rule_set_id = src.rule_set_id
     and s.document_id = src.document_id
     and s.institution_id = src.institution_id
     and s.template_version_id = src.template_version_id
    where p.institution_id = v_institution_id
      and d.institution_id = v_institution_id
      and s.institution_id = v_institution_id
      and d.status = 'active'
      and s.status = 'validated'
      and p.passage_id = any(p_passage_ids)
  ) x;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'status_code', 'ok',
    'passages', v_passages
  );
end;
$function$;

create or replace function public.get_rag_citation_passages_wrapper(
  p_auth_uid uuid,
  p_passage_ids uuid[]
)
returns jsonb
language sql
security definer
set search_path = ''
as $function$
  select server_api.get_rag_citation_passages(
    p_auth_uid,
    p_passage_ids
  );
$function$;

revoke all on function
  server_api.get_rag_citation_passages(uuid, uuid[])
  from public, anon, authenticated, service_role;

revoke all on function
  public.get_rag_citation_passages_wrapper(uuid, uuid[])
  from public, anon, authenticated;

grant execute on function
  public.get_rag_citation_passages_wrapper(uuid, uuid[])
  to service_role;

do $$
begin
  if pg_catalog.has_function_privilege(
    'anon',
    'public.get_rag_citation_passages_wrapper(uuid,uuid[])',
    'EXECUTE'
  ) then
    raise exception 'Wrapper de citations RAG encore exécutable par anon';
  end if;

  if pg_catalog.has_function_privilege(
    'authenticated',
    'public.get_rag_citation_passages_wrapper(uuid,uuid[])',
    'EXECUTE'
  ) then
    raise exception
      'Wrapper de citations RAG encore exécutable par authenticated';
  end if;

  if not pg_catalog.has_function_privilege(
    'service_role',
    'public.get_rag_citation_passages_wrapper(uuid,uuid[])',
    'EXECUTE'
  ) then
    raise exception
      'Wrapper de citations RAG indisponible au service_role';
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
