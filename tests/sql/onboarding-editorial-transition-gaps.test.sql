/*
  Test de non-régression ciblé : needs_review ne peut pas être publié
  sans passage préalable par validated.

  À exécuter après les migrations :
  - 20260805140000_onboarding_core_schema.sql
  - 20260805143000_onboarding_editorial_guardrails.sql

  Le test est transactionnel et ne conserve aucune donnée.
*/

begin;

insert into internal.institutions (institution_id, label)
values ('onboarding-transition-test', 'Institution test transitions');

insert into internal.users (
  user_uuid,
  display_name,
  institution_id,
  active
)
values (
  '55555555-5555-4555-8555-555555555555'::uuid,
  'Test transitions éditoriales',
  'onboarding-transition-test',
  true
);

insert into internal.onboarding_services (
  service_id,
  institution_id,
  service_key,
  name,
  address_text
)
values (
  '66666666-6666-4666-8666-666666666666'::uuid,
  'onboarding-transition-test',
  'transition-service',
  'Service transitions',
  'Adresse test'
);

insert into internal.onboarding_content_blocks (
  content_block_id,
  institution_id,
  content_key,
  service_id,
  block_type,
  title,
  body_markdown,
  status,
  created_by
)
values (
  '77777777-7777-4777-8777-777777777777'::uuid,
  'onboarding-transition-test',
  'needs-review-publish-gap',
  '66666666-6666-4666-8666-666666666666'::uuid,
  'welcome',
  'Contenu à relire',
  'Ce contenu doit être validé avant publication.',
  'draft',
  '55555555-5555-4555-8555-555555555555'::uuid
);

update internal.onboarding_content_blocks
set status = 'needs_review'
where content_block_id =
  '77777777-7777-4777-8777-777777777777'::uuid;

-- needs_review -> published doit être refusé, même si toutes les métadonnées
-- requises par l'état final sont fournies dans la même requête.
do $$
begin
  begin
    update internal.onboarding_content_blocks
    set status = 'published',
        validated_by = '55555555-5555-4555-8555-555555555555'::uuid,
        validated_at = pg_catalog.now(),
        published_by = '55555555-5555-4555-8555-555555555555'::uuid,
        published_at = pg_catalog.now()
    where content_block_id =
      '77777777-7777-4777-8777-777777777777'::uuid;

    raise exception
      'ÉCHEC : transition needs_review -> published acceptée';
  exception
    when others then
      if sqlerrm =
        'ÉCHEC : transition needs_review -> published acceptée'
      then
        raise;
      end if;
  end;
end;
$$;

-- L'échec ne doit avoir modifié ni l'état ni les métadonnées éditoriales.
do $$
begin
  if not exists (
    select 1
    from internal.onboarding_content_blocks
    where content_block_id =
      '77777777-7777-4777-8777-777777777777'::uuid
      and status = 'needs_review'
      and validated_by is null
      and validated_at is null
      and published_by is null
      and published_at is null
      and archived_at is null
  ) then
    raise exception
      'ÉCHEC : état altéré après refus needs_review -> published';
  end if;
end;
$$;

rollback;
