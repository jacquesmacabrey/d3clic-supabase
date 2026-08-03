/*
  Vérifie le verrouillage des fonctions RAG destructives et du trigger RLS.
  Lecture seule : aucune donnée ni permission n'est modifiée par ce test.
*/

begin;

do $$
declare
  v_function text;
begin
  foreach v_function in array array[
    'public.deactivate_rag_document_wrapper(uuid,uuid)',
    'public.delete_rag_document_wrapper(uuid,uuid,boolean,text)',
    'public.rls_auto_enable()'
  ] loop
    if pg_catalog.has_function_privilege(
      'anon', v_function, 'EXECUTE'
    ) then
      raise exception 'Fonction exposée à anon : %', v_function;
    end if;

    if pg_catalog.has_function_privilege(
      'authenticated', v_function, 'EXECUTE'
    ) then
      raise exception 'Fonction exposée à authenticated : %', v_function;
    end if;

    if not pg_catalog.has_function_privilege(
      'service_role', v_function, 'EXECUTE'
    ) then
      raise exception 'Fonction indisponible au service_role : %', v_function;
    end if;
  end loop;
end;
$$;

rollback;
