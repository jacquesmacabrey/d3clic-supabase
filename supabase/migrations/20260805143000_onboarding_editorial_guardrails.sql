/*
  D3clic — Onboarding
  Correctifs de gouvernance éditoriale après audit de la migration initiale.

  Cette migration :
  - interdit les insertions directes hors statut draft ;
  - impose les transitions draft -> needs_review -> validated -> published ;
  - interdit toute modification métier d'une version publiée ;
  - autorise le réordonnancement direct via display_order ;
  - force la RLS sur les huit tables Onboarding.
*/

begin;

create or replace function internal.onboarding_enforce_editorial_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status <> 'draft' then
    raise exception
      'Onboarding : toute nouvelle version doit être créée en brouillon';
  end if;

  if new.validated_by is not null
     or new.validated_at is not null
     or new.published_by is not null
     or new.published_at is not null
     or new.archived_at is not null
  then
    raise exception
      'Onboarding : métadonnées éditoriales interdites à la création';
  end if;

  return new;
end;
$$;

create or replace function internal.onboarding_protect_editorial_update()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old_business jsonb;
  v_new_business jsonb;
begin
  v_old_business := pg_catalog.to_jsonb(old)
    - array[
      'status',
      'active',
      'display_order',
      'updated_by',
      'updated_at',
      'validated_by',
      'validated_at',
      'published_by',
      'published_at',
      'archived_at'
    ];
  v_new_business := pg_catalog.to_jsonb(new)
    - array[
      'status',
      'active',
      'display_order',
      'updated_by',
      'updated_at',
      'validated_by',
      'validated_at',
      'published_by',
      'published_at',
      'archived_at'
    ];

  if old.status = 'draft' then
    if new.status not in ('draft', 'needs_review') then
      raise exception
        'Onboarding : transition draft interdite vers %', new.status;
    end if;

  elsif old.status = 'needs_review' then
    if new.status not in ('draft', 'needs_review', 'validated') then
      raise exception
        'Onboarding : transition needs_review interdite vers %', new.status;
    end if;

  elsif old.status = 'validated' then
    if new.status not in ('draft', 'validated', 'published', 'archived') then
      raise exception
        'Onboarding : transition validated interdite vers %', new.status;
    end if;

    if v_old_business is distinct from v_new_business then
      raise exception
        'Onboarding : revenir en brouillon avant de modifier un contenu validé';
    end if;

    if new.status in ('validated', 'published', 'archived')
       and (
         new.validated_by is distinct from old.validated_by
         or new.validated_at is distinct from old.validated_at
       )
    then
      raise exception
        'Onboarding : métadonnées de validation immuables hors retour en brouillon';
    end if;

  elsif old.status = 'published' then
    if new.status not in ('published', 'archived') then
      raise exception
        'Onboarding : un contenu publié doit rester publié ou être archivé';
    end if;

    if v_old_business is distinct from v_new_business
       or new.validated_by is distinct from old.validated_by
       or new.validated_at is distinct from old.validated_at
       or new.published_by is distinct from old.published_by
       or new.published_at is distinct from old.published_at
    then
      raise exception
        'Onboarding : modifier un contenu publié exige une nouvelle version';
    end if;

  elsif old.status = 'archived' then
    raise exception
      'Onboarding : une version archivée est immuable';
  end if;

  return new;
end;
$$;

revoke execute on function internal.onboarding_enforce_editorial_insert()
  from public, anon, authenticated;
revoke execute on function internal.onboarding_protect_editorial_update()
  from public, anon, authenticated;

create trigger onboarding_content_blocks_05_enforce_insert
before insert on internal.onboarding_content_blocks
for each row execute function internal.onboarding_enforce_editorial_insert();
create trigger onboarding_contacts_05_enforce_insert
before insert on internal.onboarding_contacts
for each row execute function internal.onboarding_enforce_editorial_insert();
create trigger onboarding_documents_05_enforce_insert
before insert on internal.onboarding_documents
for each row execute function internal.onboarding_enforce_editorial_insert();
create trigger onboarding_faq_items_05_enforce_insert
before insert on internal.onboarding_faq_items
for each row execute function internal.onboarding_enforce_editorial_insert();
create trigger onboarding_checklist_items_05_enforce_insert
before insert on internal.onboarding_checklist_items
for each row execute function internal.onboarding_enforce_editorial_insert();

alter table internal.onboarding_services force row level security;
alter table internal.onboarding_jobs force row level security;
alter table internal.onboarding_units force row level security;
alter table internal.onboarding_content_blocks force row level security;
alter table internal.onboarding_contacts force row level security;
alter table internal.onboarding_documents force row level security;
alter table internal.onboarding_faq_items force row level security;
alter table internal.onboarding_checklist_items force row level security;

comment on function internal.onboarding_protect_editorial_update() is
  'Impose les transitions draft -> needs_review -> validated -> published, protège les versions publiées et autorise uniquement les changements de métadonnées administratives comme display_order.';

commit;