# Lecture sécurisée Onboarding

Cette version remplace le contenu GoodBarber codé en dur par un paquet JSON lu
depuis Supabase. Le navigateur ne choisit jamais l’institution : elle est
résolue à partir du JWT de l’appareil, de son activation et du collaborateur
rattaché.

## Chaîne de contrôle

1. GoodBarber réutilise ou crée la session anonyme Supabase de l’appareil.
2. L’Edge Function `onboarding-content` vérifie le JWT auprès de Supabase Auth.
3. La fonction SQL retrouve l’appareil activé, l’utilisateur actif et son
   institution active.
4. Elle exige un accès `internal.onboarding_access` non révoqué et non expiré.
5. Elle renvoie uniquement les lignes `status = 'published'` et `active = true`.

Les brouillons ne sont jamais envoyés au navigateur. Les numéros et e-mails
restent masqués tant que les indicateurs de validation explicite ne sont pas
activés. Les chemins Storage et URL externes des documents ne sont pas renvoyés.

## Accès temporaire

L’accès expire un mois après l’octroi par défaut. La création ou la révocation
des accès doit rester une action de back-office ; aucune RPC client n’est créée
par cette version.

## Fichiers

- `supabase/migrations/20260806120000_onboarding_secure_read.sql`
- `supabase/functions/onboarding-content/index.ts`
- `goodbarber/onboarding-secure-staging.html`
- `tests/sql/onboarding-secure-read.test.sql`

Le jeu de données métier (coordonnées et brouillons) est volontairement exclu
de ce dépôt public. Il est chargé uniquement dans l’environnement Supabase de
staging.
