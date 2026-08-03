/*
  Retire les droits d'exécution navigateur restés explicitement accordés à
  trois fonctions d'administration ou d'infrastructure.

  Le service_role conserve son accès pour les Edge Functions serveur.
*/

revoke execute on function public.deactivate_rag_document_wrapper(
  uuid,
  uuid
) from public, anon, authenticated;

revoke execute on function public.delete_rag_document_wrapper(
  uuid,
  uuid,
  boolean,
  text
) from public, anon, authenticated;

revoke execute on function public.rls_auto_enable()
  from public, anon, authenticated;

grant execute on function public.deactivate_rag_document_wrapper(
  uuid,
  uuid
) to service_role;

grant execute on function public.delete_rag_document_wrapper(
  uuid,
  uuid,
  boolean,
  text
) to service_role;

grant execute on function public.rls_auto_enable()
  to service_role;

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
      raise exception 'Fonction encore exécutable par anon : %', v_function;
    end if;

    if pg_catalog.has_function_privilege(
      'authenticated', v_function, 'EXECUTE'
    ) then
      raise exception
        'Fonction encore exécutable par authenticated : %', v_function;
    end if;

    if not pg_catalog.has_function_privilege(
      'service_role', v_function, 'EXECUTE'
    ) then
      raise exception
        'Fonction indisponible au service_role : %', v_function;
    end if;
  end loop;
end;
$$;
