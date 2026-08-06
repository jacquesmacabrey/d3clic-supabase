/*
  D3clic — Onboarding
  Accès temporaire par collaborateur et lecture serveur des seuls contenus publiés.

  Principes :
  - l'identité et l'institution viennent exclusivement de l'appareil activé ;
  - l'accès Onboarding expire automatiquement (un mois par défaut) ;
  - aucune table interne n'est exposée à anon/authenticated ;
  - les brouillons, contenus inactifs et coordonnées non validées sont masqués ;
  - les chemins Storage et URL externes des documents ne quittent pas la base.
*/

begin;

create table internal.onboarding_access (
  user_uuid uuid primary key,
  institution_id text not null,
  audience_type text not null default 'collaborator',
  granted_at timestamptz not null default pg_catalog.now(),
  expires_at timestamptz not null default (pg_catalog.now() + interval '1 month'),
  revoked_at timestamptz,
  created_at timestamptz not null default pg_catalog.now(),
  updated_at timestamptz not null default pg_catalog.now(),

  constraint onboarding_access_user_scope_fk
    foreign key (user_uuid, institution_id)
    references internal.users (user_uuid, institution_id)
    on update cascade on delete cascade,
  constraint onboarding_access_audience_check
    check (audience_type in ('collaborator', 'apprentice', 'intern', 'volunteer')),
  constraint onboarding_access_expiry_check
    check (expires_at > granted_at),
  constraint onboarding_access_revocation_check
    check (revoked_at is null or revoked_at >= granted_at)
);

create index onboarding_access_active_lookup_idx
  on internal.onboarding_access (institution_id, expires_at)
  where revoked_at is null;

create trigger onboarding_access_set_updated_at
before update on internal.onboarding_access
for each row execute function internal.onboarding_set_updated_at();

alter table internal.onboarding_access enable row level security;
alter table internal.onboarding_access force row level security;
revoke all privileges on table internal.onboarding_access
  from public, anon, authenticated;

alter table internal.onboarding_contacts
  add column phone_publicly_validated boolean not null default false,
  add column email_publicly_validated boolean not null default false;

comment on column internal.onboarding_contacts.phone_publicly_validated is
  'Vrai uniquement pour un numéro de service explicitement validé pour affichage.';
comment on column internal.onboarding_contacts.email_publicly_validated is
  'Vrai uniquement après validation explicite de l’adresse professionnelle.';

create or replace function server_api.read_onboarding_content(
  p_device_auth_uid uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_institution_id text;
  v_institution_label text;
  v_audience_type text;
  v_expires_at timestamptz;
  v_result jsonb;
begin
  select
    u.institution_id,
    i.label,
    a.audience_type,
    a.expires_at
  into
    v_institution_id,
    v_institution_label,
    v_audience_type,
    v_expires_at
  from internal.devices d
  join internal.users u
    on u.user_uuid = d.user_uuid
  join internal.institutions i
    on i.institution_id = u.institution_id
  join internal.onboarding_access a
    on a.user_uuid = u.user_uuid
   and a.institution_id = u.institution_id
  where d.device_auth_uid = p_device_auth_uid
    and d.activated_at is not null
    and d.revoked_at is null
    and u.active is true
    and i.active is true
    and a.revoked_at is null
    and a.granted_at <= pg_catalog.now()
    and a.expires_at > pg_catalog.now();

  if not found then
    return jsonb_build_object(
      'authorized', false,
      'error', 'not_authorized'
    );
  end if;

  with published_scope as (
    select service_id, job_id, unit_id
    from internal.onboarding_content_blocks
    where institution_id = v_institution_id
      and status = 'published' and active is true
      and (audience_type is null or audience_type = v_audience_type)
    union
    select service_id, job_id, unit_id
    from internal.onboarding_contacts
    where institution_id = v_institution_id
      and status = 'published' and active is true
      and (audience_type is null or audience_type = v_audience_type)
    union
    select service_id, job_id, unit_id
    from internal.onboarding_documents
    where institution_id = v_institution_id
      and status = 'published' and active is true
      and (audience_type is null or audience_type = v_audience_type)
    union
    select service_id, job_id, unit_id
    from internal.onboarding_faq_items
    where institution_id = v_institution_id
      and status = 'published' and active is true
      and (audience_type is null or audience_type = v_audience_type)
    union
    select service_id, job_id, unit_id
    from internal.onboarding_checklist_items
    where institution_id = v_institution_id
      and status = 'published' and active is true
      and (audience_type is null or audience_type = v_audience_type)
  ),
  services_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', s.service_key,
      'name', s.name,
      'address', s.address_text,
      'job_selection_enabled', s.job_selection_enabled,
      'unit_selection_enabled', s.unit_selection_enabled,
      'display_order', s.display_order
    ) order by s.display_order, s.name), '[]'::jsonb) as value
    from internal.onboarding_services s
    where s.institution_id = v_institution_id
      and s.active is true
      and exists (select 1 from published_scope ps where ps.service_id = s.service_id)
  ),
  jobs_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', j.job_key,
      'service_key', s.service_key,
      'name', j.name,
      'display_order', j.display_order
    ) order by j.display_order, j.name), '[]'::jsonb) as value
    from internal.onboarding_jobs j
    join internal.onboarding_services s on s.service_id = j.service_id
    where j.institution_id = v_institution_id
      and j.active is true and s.active is true
      and exists (select 1 from published_scope ps where ps.job_id = j.job_id)
  ),
  units_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', u.unit_key,
      'service_key', s.service_key,
      'name', u.name,
      'display_order', u.display_order
    ) order by u.display_order, u.name), '[]'::jsonb) as value
    from internal.onboarding_units u
    join internal.onboarding_services s on s.service_id = u.service_id
    where u.institution_id = v_institution_id
      and u.active is true and s.active is true
      and exists (select 1 from published_scope ps where ps.unit_id = u.unit_id)
  ),
  content_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', c.content_key,
      'service_key', s.service_key,
      'job_key', j.job_key,
      'unit_key', u.unit_key,
      'type', c.block_type,
      'title', c.title,
      'body', c.body_markdown,
      'display_order', c.display_order
    ) order by c.display_order, c.content_key), '[]'::jsonb) as value
    from internal.onboarding_content_blocks c
    left join internal.onboarding_services s on s.service_id = c.service_id
    left join internal.onboarding_jobs j on j.job_id = c.job_id
    left join internal.onboarding_units u on u.unit_id = c.unit_id
    where c.institution_id = v_institution_id
      and c.status = 'published' and c.active is true
      and (c.audience_type is null or c.audience_type = v_audience_type)
  ),
  contacts_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', c.contact_key,
      'service_key', s.service_key,
      'job_key', j.job_key,
      'unit_key', u.unit_key,
      'name', c.name,
      'role', c.role_label,
      'phone', case when c.phone_publicly_validated then c.phone else null end,
      'email', case when c.email_publicly_validated then c.email else null end,
      'show_in_key_info', c.show_in_key_info,
      'display_order', c.display_order
    ) order by c.display_order, c.contact_key), '[]'::jsonb) as value
    from internal.onboarding_contacts c
    left join internal.onboarding_services s on s.service_id = c.service_id
    left join internal.onboarding_jobs j on j.job_id = c.job_id
    left join internal.onboarding_units u on u.unit_id = c.unit_id
    where c.institution_id = v_institution_id
      and c.status = 'published' and c.active is true
      and (c.audience_type is null or c.audience_type = v_audience_type)
  ),
  documents_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', d.document_key,
      'service_key', s.service_key,
      'job_key', j.job_key,
      'unit_key', u.unit_key,
      'kind', d.document_kind,
      'category', d.category,
      'title', d.title,
      'description', d.description_markdown,
      'transmission_instructions', d.transmission_instructions,
      'available', (d.storage_path is not null or d.external_url is not null),
      'display_order', d.display_order
    ) order by d.display_order, d.document_key), '[]'::jsonb) as value
    from internal.onboarding_documents d
    left join internal.onboarding_services s on s.service_id = d.service_id
    left join internal.onboarding_jobs j on j.job_id = d.job_id
    left join internal.onboarding_units u on u.unit_id = d.unit_id
    where d.institution_id = v_institution_id
      and d.status = 'published' and d.active is true
      and (d.audience_type is null or d.audience_type = v_audience_type)
  ),
  faq_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', f.faq_key,
      'service_key', s.service_key,
      'job_key', j.job_key,
      'unit_key', u.unit_key,
      'category', f.category,
      'question', f.question,
      'answer', f.answer_markdown,
      'display_order', f.display_order
    ) order by f.display_order, f.faq_key), '[]'::jsonb) as value
    from internal.onboarding_faq_items f
    left join internal.onboarding_services s on s.service_id = f.service_id
    left join internal.onboarding_jobs j on j.job_id = f.job_id
    left join internal.onboarding_units u on u.unit_id = f.unit_id
    where f.institution_id = v_institution_id
      and f.status = 'published' and f.active is true
      and (f.audience_type is null or f.audience_type = v_audience_type)
  ),
  checklist_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'key', c.item_key,
      'service_key', s.service_key,
      'job_key', j.job_key,
      'unit_key', u.unit_key,
      'label', c.label,
      'display_order', c.display_order
    ) order by c.display_order, c.item_key), '[]'::jsonb) as value
    from internal.onboarding_checklist_items c
    left join internal.onboarding_services s on s.service_id = c.service_id
    left join internal.onboarding_jobs j on j.job_id = c.job_id
    left join internal.onboarding_units u on u.unit_id = c.unit_id
    where c.institution_id = v_institution_id
      and c.status = 'published' and c.active is true
      and (c.audience_type is null or c.audience_type = v_audience_type)
  )
  select jsonb_build_object(
    'authorized', true,
    'context', jsonb_build_object(
      'institution', v_institution_label,
      'audience_type', v_audience_type,
      'access_expires_at', v_expires_at
    ),
    'services', services_json.value,
    'jobs', jobs_json.value,
    'units', units_json.value,
    'content', content_json.value,
    'contacts', contacts_json.value,
    'documents', documents_json.value,
    'faq', faq_json.value,
    'checklist', checklist_json.value
  )
  into v_result
  from services_json, jobs_json, units_json, content_json, contacts_json,
       documents_json, faq_json, checklist_json;

  return v_result;
end;
$$;

revoke execute on function server_api.read_onboarding_content(uuid)
  from public, anon, authenticated;

create or replace function public.onboarding_content_wrapper(
  p_device_auth_uid uuid
)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select server_api.read_onboarding_content(p_device_auth_uid);
$$;

revoke all on function public.onboarding_content_wrapper(uuid) from public;
revoke execute on function public.onboarding_content_wrapper(uuid)
  from anon, authenticated;
grant execute on function public.onboarding_content_wrapper(uuid)
  to service_role;

comment on table internal.onboarding_access is
  'Autorisation temporaire d’accès au module. Expiration par défaut après un mois.';
comment on function server_api.read_onboarding_content(uuid) is
  'Résout appareil, utilisateur et institution côté serveur, puis renvoie uniquement les contenus Onboarding publiés.';

commit;
