-- RAG-10.7 — corrige les affectations de lignes composites dans cinq RPC.
--
-- La migration initiale chargeait l'alias composite `s` comme une valeur
-- unique dans une variable `%rowtype`. PostgreSQL attend les colonnes de la
-- ligne (`s.*`). Le correctif est additif, vérifie exactement les sept motifs
-- connus et conserve les signatures, propriétaires, ACL et options existants.

do $migration$
declare
  v_patch record;
  v_oid oid;
  v_definition text;
  v_updated_definition text;
  v_occurrences integer;
  v_owner oid;
  v_acl aclitem[];
  v_security_definer boolean;
  v_config text[];
begin
  for v_patch in
    select *
    from (values
      (
        'server_api.create_rag_rule_revision(uuid,uuid)',
        'select s into v_parent',
        'select s.* into v_parent',
        2
      ),
      (
        'server_api.save_rag_rule_set_correction(uuid,uuid,bigint,uuid,jsonb)',
        'select s into v_set',
        'select s.* into v_set',
        1
      ),
      (
        'server_api.confirm_rag_rule_set(uuid,uuid,bigint,uuid,boolean)',
        'select s into v_set',
        'select s.* into v_set',
        2
      ),
      (
        'server_api.reject_rag_rule_set(uuid,uuid,bigint,uuid,text,text)',
        'select s into v_set',
        'select s.* into v_set',
        1
      ),
      (
        'server_api.audit_rag_rule_simulation(uuid,uuid,boolean,text,integer)',
        'select s into v_set',
        'select s.* into v_set',
        1
      )
    ) as patches(signature, old_text, new_text, expected_occurrences)
  loop
    v_oid := pg_catalog.to_regprocedure(v_patch.signature)::oid;
    if v_oid is null then
      raise exception 'RAG-10.7 function missing: %', v_patch.signature;
    end if;

    select p.proowner, p.proacl, p.prosecdef, p.proconfig,
           pg_catalog.pg_get_functiondef(p.oid)
    into v_owner, v_acl, v_security_definer, v_config, v_definition
    from pg_catalog.pg_proc p
    where p.oid = v_oid;

    v_occurrences := (
      pg_catalog.char_length(v_definition)
      - pg_catalog.char_length(
          pg_catalog.replace(v_definition, v_patch.old_text, '')
        )
    ) / pg_catalog.char_length(v_patch.old_text);

    if v_occurrences <> v_patch.expected_occurrences then
      raise exception
        'RAG-10.7 unexpected source for %: expected % occurrence(s), found %',
        v_patch.signature, v_patch.expected_occurrences, v_occurrences;
    end if;

    v_updated_definition := pg_catalog.replace(
      v_definition, v_patch.old_text, v_patch.new_text
    );
    execute v_updated_definition;

    select p.oid, pg_catalog.pg_get_functiondef(p.oid)
    into v_oid, v_updated_definition
    from pg_catalog.pg_proc p
    where p.oid = pg_catalog.to_regprocedure(v_patch.signature)::oid
      and p.proowner = v_owner
      and p.proacl is not distinct from v_acl
      and p.prosecdef = v_security_definer
      and p.proconfig is not distinct from v_config;

    if v_oid is null
       or pg_catalog.strpos(v_updated_definition, v_patch.old_text) <> 0
    then
      raise exception
        'RAG-10.7 postcondition failed for %', v_patch.signature;
    end if;
  end loop;
end;
$migration$;

do $postcondition$
declare
  v_bad integer;
begin
  select pg_catalog.count(*)
  into v_bad
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'server_api'
    and p.proname in (
      'create_rag_rule_revision',
      'save_rag_rule_set_correction',
      'confirm_rag_rule_set',
      'reject_rag_rule_set',
      'audit_rag_rule_simulation'
    )
    and pg_catalog.pg_get_functiondef(p.oid)
      ~ 'select s into v_(parent|set)';

  if v_bad <> 0 then
    raise exception
      'RAG-10.7 composite row correction incomplete: % function(s)', v_bad;
  end if;
end;
$postcondition$;
