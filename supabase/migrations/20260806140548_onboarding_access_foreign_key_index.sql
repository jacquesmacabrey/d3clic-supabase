/*
  D3clic — Onboarding
  Ajoute l'index couvrant requis par la clé étrangère composite de l'accès.
*/

begin;

create index if not exists onboarding_access_user_scope_fk_idx
  on internal.onboarding_access (user_uuid, institution_id);

commit;
