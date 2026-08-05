/*
  D3clic — Onboarding
  Schéma relationnel multi-institution, cycle éditorial et garde-fous de sécurité.

  Cette migration est additive. Elle crée uniquement les objets internes du
  module Onboarding. Elle n'expose aucune RPC publique et ne crée aucun accès
  GoodBarber, Chat ou RAG.
*/

begin;

do $$
begin
  if pg_catalog.to_regclass('internal.institutions') is null
     or pg_catalog.to_regclass('internal.users') is null
     or pg_catalog.to_regclass('internal.devices') is null
  then
    raise exception 'Onboarding : socle identité D3clic incomplet';
  end if;
end;
$$;

-- -------------------------------------------------------------------------
-- 1. Fonctions techniques internes
-- -------------------------------------------------------------------------

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
      'updated_by',
      'updated_at',
      'validated_by',
      'validated_at',
      'published_by',
      'published_at',
      'archived_at'
    ];

  if old.status = 'published' then
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
  elsif old.status = 'validated' then
    if new.status in ('validated', 'published', 'archived')
       and (
         v_old_business is distinct from v_new_business
         or new.validated_by is distinct from old.validated_by
         or new.validated_at is distinct from old.validated_at
       )
    then
      raise exception
        'Onboarding : revenir en brouillon avant de modifier un contenu validé';
    end if;

    if new.status in ('validated', 'archived')
       and (
         new.published_by is distinct from old.published_by
         or new.published_at is distinct from old.published_at
       )
    then
      raise exception
        'Onboarding : métadonnées de publication incohérentes';
    end if;
  elsif old.status = 'archived' then
    raise exception
      'Onboarding : une version archivée est immuable';
  end if;

  return new;
end;
$$;

create or replace function internal.onboarding_set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

create or replace function internal.onboarding_prepare_editorial_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status in ('draft', 'needs_review')
     and old.status is distinct from new.status
  then
    new.validated_by := null;
    new.validated_at := null;
    new.published_by := null;
    new.published_at := null;
    new.archived_at := null;
  end if;

  if new.status = 'archived'
     and old.status is distinct from 'archived'
  then
    new.active := false;
    if new.archived_at is null then
      new.archived_at := pg_catalog.now();
    end if;
  end if;

  new.updated_at := pg_catalog.now();
  return new;
end;
$$;

revoke execute on function internal.onboarding_protect_editorial_update()
  from public, anon, authenticated;
revoke execute on function internal.onboarding_set_updated_at()
  from public, anon, authenticated;
revoke execute on function internal.onboarding_prepare_editorial_update()
  from public, anon, authenticated;

-- -------------------------------------------------------------------------
-- 2. Référentiels institutionnels
-- -------------------------------------------------------------------------

create table internal.onboarding_services (
  service_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  service_key text not null,
  name text not null,
  address_text text not null,
  job_selection_enabled boolean not null default false,
  unit_selection_enabled boolean not null default false,
  display_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),

  constraint onboarding_services_institution_fk
    foreign key (institution_id)
    references internal.institutions (institution_id)
    on update cascade on delete restrict,
  constraint onboarding_services_scope_unique
    unique (service_id, institution_id),
  constraint onboarding_services_key_unique
    unique (institution_id, service_key),
  constraint onboarding_services_key_check
    check (service_key ~ '^[a-z0-9][a-z0-9_-]{0,99}$'),
  constraint onboarding_services_name_check
    check (
      pg_catalog.btrim(name) <> ''
      and pg_catalog.char_length(name) <= 150
    ),
  constraint onboarding_services_address_check
    check (
      pg_catalog.btrim(address_text) <> ''
      and pg_catalog.char_length(address_text) <= 500
    ),
  constraint onboarding_services_display_order_check
    check (display_order between 0 and 10000)
);

create table internal.onboarding_jobs (
  job_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  service_id uuid not null,
  job_key text not null,
  name text not null,
  display_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),

  constraint onboarding_jobs_institution_fk
    foreign key (institution_id)
    references internal.institutions (institution_id)
    on update cascade on delete restrict,
  constraint onboarding_jobs_service_scope_fk
    foreign key (service_id, institution_id)
    references internal.onboarding_services (service_id, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_jobs_scope_unique
    unique (job_id, institution_id, service_id),
  constraint onboarding_jobs_key_unique
    unique (institution_id, service_id, job_key),
  constraint onboarding_jobs_key_check
    check (job_key ~ '^[a-z0-9][a-z0-9_-]{0,99}$'),
  constraint onboarding_jobs_name_check
    check (
      pg_catalog.btrim(name) <> ''
      and pg_catalog.char_length(name) <= 150
    ),
  constraint onboarding_jobs_display_order_check
    check (display_order between 0 and 10000)
);

create table internal.onboarding_units (
  unit_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  service_id uuid not null,
  unit_key text not null,
  name text not null,
  display_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),

  constraint onboarding_units_institution_fk
    foreign key (institution_id)
    references internal.institutions (institution_id)
    on update cascade on delete restrict,
  constraint onboarding_units_service_scope_fk
    foreign key (service_id, institution_id)
    references internal.onboarding_services (service_id, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_units_scope_unique
    unique (unit_id, institution_id, service_id),
  constraint onboarding_units_key_unique
    unique (institution_id, service_id, unit_key),
  constraint onboarding_units_key_check
    check (unit_key ~ '^[a-z0-9][a-z0-9_-]{0,99}$'),
  constraint onboarding_units_name_check
    check (
      pg_catalog.btrim(name) <> ''
      and pg_catalog.char_length(name) <= 150
    ),
  constraint onboarding_units_display_order_check
    check (display_order between 0 and 10000)
);

create index onboarding_services_active_idx
  on internal.onboarding_services (institution_id, active, display_order);
create index onboarding_jobs_active_idx
  on internal.onboarding_jobs (
    institution_id,
    service_id,
    active,
    display_order
  );
create index onboarding_units_active_idx
  on internal.onboarding_units (
    institution_id,
    service_id,
    active,
    display_order
  );

-- -------------------------------------------------------------------------
-- 3. Blocs de contenu
-- -------------------------------------------------------------------------

create table internal.onboarding_content_blocks (
  content_block_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  content_key text not null,
  version integer not null default 1,
  service_id uuid,
  job_id uuid,
  unit_id uuid,
  audience_type text,
  block_type text not null,
  title text,
  body_markdown text,
  status text not null default 'draft',
  active boolean not null default true,
  display_order integer not null default 0,
  created_by uuid,
  updated_by uuid,
  validated_by uuid,
  published_by uuid,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  validated_at timestamptz,
  published_at timestamptz,
  archived_at timestamptz,

  constraint onboarding_content_blocks_institution_fk
    foreign key (institution_id)
    references internal.institutions (institution_id)
    on update cascade on delete restrict,
  constraint onboarding_content_blocks_service_scope_fk
    foreign key (service_id, institution_id)
    references internal.onboarding_services (service_id, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_content_blocks_job_scope_fk
    foreign key (job_id, institution_id, service_id)
    references internal.onboarding_jobs (job_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_content_blocks_unit_scope_fk
    foreign key (unit_id, institution_id, service_id)
    references internal.onboarding_units (unit_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_content_blocks_created_by_fk
    foreign key (created_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_content_blocks_updated_by_fk
    foreign key (updated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_content_blocks_validated_by_fk
    foreign key (validated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_content_blocks_published_by_fk
    foreign key (published_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_content_blocks_version_unique
    unique (institution_id, content_key, version),
  constraint onboarding_content_blocks_key_check
    check (content_key ~ '^[a-z0-9][a-z0-9_-]{0,119}$'),
  constraint onboarding_content_blocks_version_check
    check (version between 1 and 1000000),
  constraint onboarding_content_blocks_target_check
    check (
      (job_id is null or service_id is not null)
      and (unit_id is null or service_id is not null)
    ),
  constraint onboarding_content_blocks_audience_check
    check (
      audience_type is null
      or audience_type in ('collaborator', 'apprentice', 'intern', 'volunteer')
    ),
  constraint onboarding_content_blocks_type_check
    check (
      block_type ~ '^[a-z][a-z0-9_]{1,79}$'
      and pg_catalog.char_length(block_type) <= 80
    ),
  constraint onboarding_content_blocks_status_check
    check (
      status in ('draft', 'needs_review', 'validated', 'published', 'archived')
    ),
  constraint onboarding_content_blocks_display_order_check
    check (display_order between 0 and 10000),
  constraint onboarding_content_blocks_required_content_check
    check (
      status not in ('validated', 'published')
      or (
        title is not null
        and pg_catalog.btrim(title) <> ''
        and pg_catalog.char_length(title) <= 250
        and body_markdown is not null
        and pg_catalog.btrim(body_markdown) <> ''
      )
    ),
  constraint onboarding_content_blocks_editorial_state_check
    check (
      (
        status in ('draft', 'needs_review')
        and validated_by is null and validated_at is null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'validated'
        and validated_by is not null and validated_at is not null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'published'
        and validated_by is not null and validated_at is not null
        and published_by is not null and published_at is not null
        and archived_at is null
      )
      or (
        status = 'archived'
        and active is false
        and archived_at is not null
      )
    )
);

create unique index onboarding_content_blocks_published_unique
  on internal.onboarding_content_blocks (institution_id, content_key)
  where status = 'published' and active is true;
create index onboarding_content_blocks_published_lookup_idx
  on internal.onboarding_content_blocks (
    institution_id,
    service_id,
    job_id,
    unit_id,
    display_order
  )
  where status = 'published' and active is true;

-- -------------------------------------------------------------------------
-- 4. Contacts
-- -------------------------------------------------------------------------

create table internal.onboarding_contacts (
  contact_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  contact_key text not null,
  version integer not null default 1,
  service_id uuid,
  job_id uuid,
  unit_id uuid,
  audience_type text,
  name text,
  role_label text,
  phone text,
  email text,
  show_in_key_info boolean not null default false,
  status text not null default 'draft',
  active boolean not null default true,
  display_order integer not null default 0,
  created_by uuid,
  updated_by uuid,
  validated_by uuid,
  published_by uuid,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  validated_at timestamptz,
  published_at timestamptz,
  archived_at timestamptz,

  constraint onboarding_contacts_institution_fk
    foreign key (institution_id)
    references internal.institutions (institution_id)
    on update cascade on delete restrict,
  constraint onboarding_contacts_service_scope_fk
    foreign key (service_id, institution_id)
    references internal.onboarding_services (service_id, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_contacts_job_scope_fk
    foreign key (job_id, institution_id, service_id)
    references internal.onboarding_jobs (job_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_contacts_unit_scope_fk
    foreign key (unit_id, institution_id, service_id)
    references internal.onboarding_units (unit_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_contacts_created_by_fk
    foreign key (created_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_contacts_updated_by_fk
    foreign key (updated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_contacts_validated_by_fk
    foreign key (validated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_contacts_published_by_fk
    foreign key (published_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_contacts_version_unique
    unique (institution_id, contact_key, version),
  constraint onboarding_contacts_key_check
    check (contact_key ~ '^[a-z0-9][a-z0-9_-]{0,119}$'),
  constraint onboarding_contacts_version_check
    check (version between 1 and 1000000),
  constraint onboarding_contacts_target_check
    check (
      (job_id is null or service_id is not null)
      and (unit_id is null or service_id is not null)
    ),
  constraint onboarding_contacts_audience_check
    check (
      audience_type is null
      or audience_type in ('collaborator', 'apprentice', 'intern', 'volunteer')
    ),
  constraint onboarding_contacts_status_check
    check (
      status in ('draft', 'needs_review', 'validated', 'published', 'archived')
    ),
  constraint onboarding_contacts_display_order_check
    check (display_order between 0 and 10000),
  constraint onboarding_contacts_phone_check
    check (
      phone is null
      or (
        pg_catalog.btrim(phone) <> ''
        and pg_catalog.char_length(phone) <= 50
      )
    ),
  constraint onboarding_contacts_email_check
    check (
      email is null
      or (
        email = pg_catalog.btrim(email)
        and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
        and pg_catalog.char_length(email) <= 320
      )
    ),
  constraint onboarding_contacts_required_content_check
    check (
      status not in ('validated', 'published')
      or (
        name is not null
        and pg_catalog.btrim(name) <> ''
        and pg_catalog.char_length(name) <= 150
        and role_label is not null
        and pg_catalog.btrim(role_label) <> ''
        and pg_catalog.char_length(role_label) <= 200
      )
    ),
  constraint onboarding_contacts_editorial_state_check
    check (
      (
        status in ('draft', 'needs_review')
        and validated_by is null and validated_at is null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'validated'
        and validated_by is not null and validated_at is not null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'published'
        and validated_by is not null and validated_at is not null
        and published_by is not null and published_at is not null
        and archived_at is null
      )
      or (
        status = 'archived'
        and active is false
        and archived_at is not null
      )
    )
);

create unique index onboarding_contacts_published_unique
  on internal.onboarding_contacts (institution_id, contact_key)
  where status = 'published' and active is true;
create index onboarding_contacts_published_lookup_idx
  on internal.onboarding_contacts (
    institution_id,
    service_id,
    job_id,
    unit_id,
    display_order
  )
  where status = 'published' and active is true;

-- -------------------------------------------------------------------------
-- 5. Documents
-- -------------------------------------------------------------------------

create table internal.onboarding_documents (
  document_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  document_key text not null,
  version integer not null default 1,
  service_id uuid,
  job_id uuid,
  unit_id uuid,
  audience_type text,
  document_kind text not null default 'read',
  category text,
  title text,
  description_markdown text,
  storage_path text,
  external_url text,
  original_file_name text,
  mime_type text,
  transmission_instructions text,
  status text not null default 'draft',
  active boolean not null default true,
  display_order integer not null default 0,
  created_by uuid,
  updated_by uuid,
  validated_by uuid,
  published_by uuid,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  validated_at timestamptz,
  published_at timestamptz,
  archived_at timestamptz,

  constraint onboarding_documents_institution_fk
    foreign key (institution_id)
    references internal.institutions (institution_id)
    on update cascade on delete restrict,
  constraint onboarding_documents_service_scope_fk
    foreign key (service_id, institution_id)
    references internal.onboarding_services (service_id, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_documents_job_scope_fk
    foreign key (job_id, institution_id, service_id)
    references internal.onboarding_jobs (job_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_documents_unit_scope_fk
    foreign key (unit_id, institution_id, service_id)
    references internal.onboarding_units (unit_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_documents_created_by_fk
    foreign key (created_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_documents_updated_by_fk
    foreign key (updated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_documents_validated_by_fk
    foreign key (validated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_documents_published_by_fk
    foreign key (published_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_documents_version_unique
    unique (institution_id, document_key, version),
  constraint onboarding_documents_key_check
    check (document_key ~ '^[a-z0-9][a-z0-9_-]{0,119}$'),
  constraint onboarding_documents_version_check
    check (version between 1 and 1000000),
  constraint onboarding_documents_target_check
    check (
      (job_id is null or service_id is not null)
      and (unit_id is null or service_id is not null)
    ),
  constraint onboarding_documents_audience_check
    check (
      audience_type is null
      or audience_type in ('collaborator', 'apprentice', 'intern', 'volunteer')
    ),
  constraint onboarding_documents_kind_check
    check (document_kind in ('read', 'blank_form')),
  constraint onboarding_documents_status_check
    check (
      status in ('draft', 'needs_review', 'validated', 'published', 'archived')
    ),
  constraint onboarding_documents_display_order_check
    check (display_order between 0 and 10000),
  constraint onboarding_documents_source_exclusive_check
    check (not (storage_path is not null and external_url is not null)),
  constraint onboarding_documents_storage_path_check
    check (
      storage_path is null
      or (
        pg_catalog.split_part(storage_path, '/', 1) = institution_id
        and storage_path <> institution_id
        and pg_catalog.strpos(storage_path, '/') > 1
        and pg_catalog.char_length(storage_path) <= 1000
      )
    ),
  constraint onboarding_documents_external_url_check
    check (
      external_url is null
      or (
        external_url ~ '^https://'
        and pg_catalog.char_length(external_url) <= 2000
      )
    ),
  constraint onboarding_documents_original_file_name_check
    check (
      original_file_name is null
      or (
        pg_catalog.btrim(original_file_name) <> ''
        and pg_catalog.char_length(original_file_name) <= 255
      )
    ),
  constraint onboarding_documents_mime_type_check
    check (
      mime_type is null
      or mime_type in (
        'application/pdf',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
      )
    ),
  constraint onboarding_documents_required_content_check
    check (
      status not in ('validated', 'published')
      or (
        category is not null
        and pg_catalog.btrim(category) <> ''
        and pg_catalog.char_length(category) <= 100
        and title is not null
        and pg_catalog.btrim(title) <> ''
        and pg_catalog.char_length(title) <= 250
        and ((storage_path is not null) <> (external_url is not null))
      )
    ),
  constraint onboarding_documents_editorial_state_check
    check (
      (
        status in ('draft', 'needs_review')
        and validated_by is null and validated_at is null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'validated'
        and validated_by is not null and validated_at is not null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'published'
        and validated_by is not null and validated_at is not null
        and published_by is not null and published_at is not null
        and archived_at is null
      )
      or (
        status = 'archived'
        and active is false
        and archived_at is not null
      )
    )
);

create unique index onboarding_documents_published_unique
  on internal.onboarding_documents (institution_id, document_key)
  where status = 'published' and active is true;
create index onboarding_documents_published_lookup_idx
  on internal.onboarding_documents (
    institution_id,
    service_id,
    job_id,
    unit_id,
    display_order
  )
  where status = 'published' and active is true;

-- -------------------------------------------------------------------------
-- 6. FAQ
-- -------------------------------------------------------------------------

create table internal.onboarding_faq_items (
  faq_item_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  faq_key text not null,
  version integer not null default 1,
  service_id uuid,
  job_id uuid,
  unit_id uuid,
  audience_type text,
  category text,
  question text,
  answer_markdown text,
  status text not null default 'draft',
  active boolean not null default true,
  display_order integer not null default 0,
  created_by uuid,
  updated_by uuid,
  validated_by uuid,
  published_by uuid,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  validated_at timestamptz,
  published_at timestamptz,
  archived_at timestamptz,

  constraint onboarding_faq_items_institution_fk
    foreign key (institution_id)
    references internal.institutions (institution_id)
    on update cascade on delete restrict,
  constraint onboarding_faq_items_service_scope_fk
    foreign key (service_id, institution_id)
    references internal.onboarding_services (service_id, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_faq_items_job_scope_fk
    foreign key (job_id, institution_id, service_id)
    references internal.onboarding_jobs (job_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_faq_items_unit_scope_fk
    foreign key (unit_id, institution_id, service_id)
    references internal.onboarding_units (unit_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_faq_items_created_by_fk
    foreign key (created_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_faq_items_updated_by_fk
    foreign key (updated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_faq_items_validated_by_fk
    foreign key (validated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_faq_items_published_by_fk
    foreign key (published_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_faq_items_version_unique
    unique (institution_id, faq_key, version),
  constraint onboarding_faq_items_key_check
    check (faq_key ~ '^[a-z0-9][a-z0-9_-]{0,119}$'),
  constraint onboarding_faq_items_version_check
    check (version between 1 and 1000000),
  constraint onboarding_faq_items_target_check
    check (
      (job_id is null or service_id is not null)
      and (unit_id is null or service_id is not null)
    ),
  constraint onboarding_faq_items_audience_check
    check (
      audience_type is null
      or audience_type in ('collaborator', 'apprentice', 'intern', 'volunteer')
    ),
  constraint onboarding_faq_items_status_check
    check (
      status in ('draft', 'needs_review', 'validated', 'published', 'archived')
    ),
  constraint onboarding_faq_items_display_order_check
    check (display_order between 0 and 10000),
  constraint onboarding_faq_items_required_content_check
    check (
      status not in ('validated', 'published')
      or (
        category is not null
        and pg_catalog.btrim(category) <> ''
        and pg_catalog.char_length(category) <= 100
        and question is not null
        and pg_catalog.btrim(question) <> ''
        and pg_catalog.char_length(question) <= 500
        and answer_markdown is not null
        and pg_catalog.btrim(answer_markdown) <> ''
      )
    ),
  constraint onboarding_faq_items_editorial_state_check
    check (
      (
        status in ('draft', 'needs_review')
        and validated_by is null and validated_at is null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'validated'
        and validated_by is not null and validated_at is not null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'published'
        and validated_by is not null and validated_at is not null
        and published_by is not null and published_at is not null
        and archived_at is null
      )
      or (
        status = 'archived'
        and active is false
        and archived_at is not null
      )
    )
);

create unique index onboarding_faq_items_published_unique
  on internal.onboarding_faq_items (institution_id, faq_key)
  where status = 'published' and active is true;
create index onboarding_faq_items_published_lookup_idx
  on internal.onboarding_faq_items (
    institution_id,
    service_id,
    job_id,
    unit_id,
    display_order
  )
  where status = 'published' and active is true;

-- -------------------------------------------------------------------------
-- 7. Checklist institutionnelle
-- -------------------------------------------------------------------------

create table internal.onboarding_checklist_items (
  checklist_item_id uuid primary key default gen_random_uuid(),
  institution_id text not null,
  item_key text not null,
  version integer not null default 1,
  service_id uuid,
  job_id uuid,
  unit_id uuid,
  audience_type text,
  label text,
  status text not null default 'draft',
  active boolean not null default true,
  display_order integer not null default 0,
  created_by uuid,
  updated_by uuid,
  validated_by uuid,
  published_by uuid,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),
  validated_at timestamptz,
  published_at timestamptz,
  archived_at timestamptz,

  constraint onboarding_checklist_items_institution_fk
    foreign key (institution_id)
    references internal.institutions (institution_id)
    on update cascade on delete restrict,
  constraint onboarding_checklist_items_service_scope_fk
    foreign key (service_id, institution_id)
    references internal.onboarding_services (service_id, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_checklist_items_job_scope_fk
    foreign key (job_id, institution_id, service_id)
    references internal.onboarding_jobs (job_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_checklist_items_unit_scope_fk
    foreign key (unit_id, institution_id, service_id)
    references internal.onboarding_units (unit_id, institution_id, service_id)
    on update cascade on delete restrict,
  constraint onboarding_checklist_items_created_by_fk
    foreign key (created_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_checklist_items_updated_by_fk
    foreign key (updated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_checklist_items_validated_by_fk
    foreign key (validated_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_checklist_items_published_by_fk
    foreign key (published_by, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete restrict,
  constraint onboarding_checklist_items_version_unique
    unique (institution_id, item_key, version),
  constraint onboarding_checklist_items_key_check
    check (item_key ~ '^[a-z0-9][a-z0-9_-]{0,119}$'),
  constraint onboarding_checklist_items_version_check
    check (version between 1 and 1000000),
  constraint onboarding_checklist_items_target_check
    check (
      (job_id is null or service_id is not null)
      and (unit_id is null or service_id is not null)
    ),
  constraint onboarding_checklist_items_audience_check
    check (
      audience_type is null
      or audience_type in ('collaborator', 'apprentice', 'intern', 'volunteer')
    ),
  constraint onboarding_checklist_items_status_check
    check (
      status in ('draft', 'needs_review', 'validated', 'published', 'archived')
    ),
  constraint onboarding_checklist_items_display_order_check
    check (display_order between 0 and 10000),
  constraint onboarding_checklist_items_required_content_check
    check (
      status not in ('validated', 'published')
      or (
        label is not null
        and pg_catalog.btrim(label) <> ''
        and pg_catalog.char_length(label) <= 500
      )
    ),
  constraint onboarding_checklist_items_editorial_state_check
    check (
      (
        status in ('draft', 'needs_review')
        and validated_by is null and validated_at is null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'validated'
        and validated_by is not null and validated_at is not null
        and published_by is null and published_at is null
        and archived_at is null
      )
      or (
        status = 'published'
        and validated_by is not null and validated_at is not null
        and published_by is not null and published_at is not null
        and archived_at is null
      )
      or (
        status = 'archived'
        and active is false
        and archived_at is not null
      )
    )
);

create unique index onboarding_checklist_items_published_unique
  on internal.onboarding_checklist_items (institution_id, item_key)
  where status = 'published' and active is true;
create index onboarding_checklist_items_published_lookup_idx
  on internal.onboarding_checklist_items (
    institution_id,
    service_id,
    job_id,
    unit_id,
    display_order
  )
  where status = 'published' and active is true;

-- -------------------------------------------------------------------------
-- 8. Déclencheurs de maintenance et éditoriaux
-- -------------------------------------------------------------------------

create trigger onboarding_services_set_updated_at
before update on internal.onboarding_services
for each row execute function internal.onboarding_set_updated_at();

create trigger onboarding_jobs_set_updated_at
before update on internal.onboarding_jobs
for each row execute function internal.onboarding_set_updated_at();

create trigger onboarding_units_set_updated_at
before update on internal.onboarding_units
for each row execute function internal.onboarding_set_updated_at();

create trigger onboarding_content_blocks_10_protect_update
before update on internal.onboarding_content_blocks
for each row execute function internal.onboarding_protect_editorial_update();
create trigger onboarding_content_blocks_20_prepare_update
before update on internal.onboarding_content_blocks
for each row execute function internal.onboarding_prepare_editorial_update();

create trigger onboarding_contacts_10_protect_update
before update on internal.onboarding_contacts
for each row execute function internal.onboarding_protect_editorial_update();
create trigger onboarding_contacts_20_prepare_update
before update on internal.onboarding_contacts
for each row execute function internal.onboarding_prepare_editorial_update();

create trigger onboarding_documents_10_protect_update
before update on internal.onboarding_documents
for each row execute function internal.onboarding_protect_editorial_update();
create trigger onboarding_documents_20_prepare_update
before update on internal.onboarding_documents
for each row execute function internal.onboarding_prepare_editorial_update();

create trigger onboarding_faq_items_10_protect_update
before update on internal.onboarding_faq_items
for each row execute function internal.onboarding_protect_editorial_update();
create trigger onboarding_faq_items_20_prepare_update
before update on internal.onboarding_faq_items
for each row execute function internal.onboarding_prepare_editorial_update();

create trigger onboarding_checklist_items_10_protect_update
before update on internal.onboarding_checklist_items
for each row execute function internal.onboarding_protect_editorial_update();
create trigger onboarding_checklist_items_20_prepare_update
before update on internal.onboarding_checklist_items
for each row execute function internal.onboarding_prepare_editorial_update();

-- -------------------------------------------------------------------------
-- 9. RLS et privilèges
-- -------------------------------------------------------------------------

alter table internal.onboarding_services enable row level security;
alter table internal.onboarding_jobs enable row level security;
alter table internal.onboarding_units enable row level security;
alter table internal.onboarding_content_blocks enable row level security;
alter table internal.onboarding_contacts enable row level security;
alter table internal.onboarding_documents enable row level security;
alter table internal.onboarding_faq_items enable row level security;
alter table internal.onboarding_checklist_items enable row level security;

revoke all privileges on table internal.onboarding_services
  from public, anon, authenticated;
revoke all privileges on table internal.onboarding_jobs
  from public, anon, authenticated;
revoke all privileges on table internal.onboarding_units
  from public, anon, authenticated;
revoke all privileges on table internal.onboarding_content_blocks
  from public, anon, authenticated;
revoke all privileges on table internal.onboarding_contacts
  from public, anon, authenticated;
revoke all privileges on table internal.onboarding_documents
  from public, anon, authenticated;
revoke all privileges on table internal.onboarding_faq_items
  from public, anon, authenticated;
revoke all privileges on table internal.onboarding_checklist_items
  from public, anon, authenticated;

comment on table internal.onboarding_documents is
  'Documents institutionnels vierges ou de consultation. Aucun document complété.';
comment on column internal.onboarding_documents.storage_path is
  'Chemin privé préfixé par institution_id. URL signée générée au Sprint 4.';
comment on table internal.onboarding_checklist_items is
  'Définition institutionnelle. L''état coché reste exclusivement local.';

commit;
