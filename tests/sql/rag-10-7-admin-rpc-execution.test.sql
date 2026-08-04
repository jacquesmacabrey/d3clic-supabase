/*
  RAG-10.7 — exécution réelle des cinq RPC corrigés.
  Toutes les écritures de test sont annulées par ROLLBACK.
*/
begin;

do $test$
declare
  v_auth_uid uuid;
  v_active_set_id uuid;
  v_revision_id uuid;
  v_rejected_revision_id uuid;
  v_revision_number bigint;
  v_result jsonb;
  v_detail jsonb;
  v_rules jsonb;
  v_simulation_code text := 'rag_10_7_rpc_test_'
    || pg_catalog.replace(pg_catalog.gen_random_uuid()::text, '-', '');
  v_audit_count integer;
  v_status text;
begin
  select l.backoffice_auth_uid, s.rule_set_id
  into v_auth_uid, v_active_set_id
  from internal.rag_rule_sets s
  join internal.rag_documents d
    on d.document_id = s.document_id
   and d.institution_id = s.institution_id
  join internal.backoffice_auth_links l
    on l.institution_id = s.institution_id
   and l.revoked_at is null
  join internal.user_roles ur
    on ur.user_uuid = l.user_uuid
   and ur.role = 'admin'
  where s.status = 'validated'
    and d.status = 'active'
    and not exists (
      select 1
      from internal.rag_rule_sets child
      where child.parent_rule_set_id = s.rule_set_id
        and child.institution_id = s.institution_id
        and child.status in ('proposed', 'needs_attention', 'approved')
    )
  order by s.created_at, l.created_at
  limit 1;

  if v_auth_uid is null or v_active_set_id is null then
    raise exception
      'Précondition absente : règle validée active et administrateur';
  end if;

  -- 1. Simulation : exécute l'affectation corrigée et vérifie son audit.
  select public.audit_rag_rule_simulation_wrapper(
    v_auth_uid, v_active_set_id, true, v_simulation_code, 2
  ) into v_result;
  if v_result->>'success' <> 'true'
     or v_result->>'status_code' <> 'recorded'
  then
    raise exception 'Audit de simulation refusé : %', v_result;
  end if;

  select pg_catalog.count(*)
  into v_audit_count
  from internal.rag_rule_audit_events e
  where e.rule_set_id = v_active_set_id
    and e.event_type = 'rag_rule_simulated'
    and e.reason_code = v_simulation_code;
  if v_audit_count <> 1 then
    raise exception 'Audit de simulation non écrit exactement une fois';
  end if;

  -- 2. Révision : exécute les deux lectures composites de la fonction.
  select public.create_rag_rule_revision_wrapper(
    v_auth_uid, v_active_set_id
  ) into v_result;
  if v_result->>'success' <> 'true'
     or v_result->>'status_code' <> 'revision_created'
  then
    raise exception 'Création de révision refusée : %', v_result;
  end if;
  v_revision_id := (v_result->>'rule_set_id')::uuid;

  -- 3. Sauvegarde : réécrit à l'identique le brouillon transactionnel.
  select public.get_rag_rule_set_admin_wrapper(
    v_auth_uid, v_revision_id
  ) into v_detail;
  if v_detail->>'success' <> 'true' then
    raise exception 'Détail de la révision indisponible : %', v_detail;
  end if;
  v_rules := v_detail#>'{rule_set,rules}';
  v_revision_number := (v_detail->>'revision_number')::bigint;

  select public.save_rag_rule_set_correction_wrapper(
    v_auth_uid,
    v_revision_id,
    v_revision_number,
    pg_catalog.gen_random_uuid(),
    v_rules
  ) into v_result;
  if v_result->>'success' <> 'true'
     or v_result->>'status_code' <> 'saved'
  then
    raise exception 'Sauvegarde de révision refusée : %', v_result;
  end if;
  v_revision_number := (v_result->>'revision_number')::bigint;

  -- 4. Validation : exécute les deux lectures composites de confirmation.
  select public.confirm_rag_rule_set_wrapper(
    v_auth_uid,
    v_revision_id,
    v_revision_number,
    pg_catalog.gen_random_uuid(),
    true
  ) into v_result;
  if v_result->>'success' <> 'true'
     or v_result->>'status_code' <> 'validated'
  then
    raise exception 'Validation de révision refusée : %', v_result;
  end if;

  select s.status into v_status
  from internal.rag_rule_sets s
  where s.rule_set_id = v_revision_id;
  if v_status <> 'validated' then
    raise exception 'Révision non validée après confirmation : %', v_status;
  end if;

  -- 5. Rejet : crée un second brouillon transactionnel puis le rejette.
  select public.create_rag_rule_revision_wrapper(
    v_auth_uid, v_revision_id
  ) into v_result;
  if v_result->>'success' <> 'true'
     or v_result->>'status_code' <> 'revision_created'
  then
    raise exception 'Seconde révision refusée : %', v_result;
  end if;
  v_rejected_revision_id := (v_result->>'rule_set_id')::uuid;

  select public.get_rag_rule_set_admin_wrapper(
    v_auth_uid, v_rejected_revision_id
  ) into v_detail;
  v_revision_number := (v_detail->>'revision_number')::bigint;

  select public.reject_rag_rule_set_wrapper(
    v_auth_uid,
    v_rejected_revision_id,
    v_revision_number,
    pg_catalog.gen_random_uuid(),
    'incorrect_values',
    null
  ) into v_result;
  if v_result->>'success' <> 'true'
     or v_result->>'status_code' <> 'rejected'
  then
    raise exception 'Rejet de révision refusé : %', v_result;
  end if;

  select s.status into v_status
  from internal.rag_rule_sets s
  where s.rule_set_id = v_rejected_revision_id;
  if v_status <> 'rejected' then
    raise exception 'Révision non rejetée après action : %', v_status;
  end if;
end;
$test$;

rollback;
