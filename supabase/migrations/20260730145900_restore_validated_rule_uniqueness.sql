/*
  D3clic — correctif préalable à RAG-10.1

  Le socle des règles numériques a été installé manuellement en staging,
  mais l'index partiel garantissant un seul jeu validé par institution et
  domaine n'a pas été créé. Cette migration restaure uniquement cette
  garantie avant la migration RAG-10.1.
*/

begin;

do $$
declare
  v_duplicate_count bigint;
begin
  if to_regclass('internal.rag_rule_sets') is null then
    raise exception
      'RAG-10.1 correctif : table internal.rag_rule_sets absente';
  end if;

  select pg_catalog.count(*)
  into v_duplicate_count
  from (
    select s.institution_id, s.rule_key
    from internal.rag_rule_sets s
    where s.status = 'validated'
    group by s.institution_id, s.rule_key
    having pg_catalog.count(*) > 1
  ) duplicates;

  if v_duplicate_count <> 0 then
    raise exception
      'RAG-10.1 correctif : % doublon(s) de jeux validés détecté(s)',
      v_duplicate_count;
  end if;
end;
$$;

create unique index if not exists
  rag_rule_sets_validated_institution_key_unique
  on internal.rag_rule_sets (institution_id, rule_key)
  where status = 'validated';

do $$
begin
  if not exists (
    select 1
    from pg_catalog.pg_indexes i
    where i.schemaname = 'internal'
      and i.indexname =
        'rag_rule_sets_validated_institution_key_unique'
  ) then
    raise exception
      'RAG-10.1 correctif : index d''unicité non créé';
  end if;
end;
$$;

commit;
