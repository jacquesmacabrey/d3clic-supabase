# RAG-10.7 — administration des règles

Branche de travail : `rag-10-7-admin-rules`.

## Contenu

- migration `20260803120000_rag_admin_rule_workflow.sql` ;
- Edge Function `rag-admin-rules` ;
- contrats stricts, présentation métier et simulation isolée ;
- tests TypeScript et postconditions SQL, dont un scénario négatif dédié au
  décalage catégoriel des sources ;
- scripts de déploiement et de retour arrière staging.

`rule-engine.ts` reste inchangé. Empreinte attendue :

```text
eca639155e99bff7bdf8acdc28e6cecb52f13089fae5bb00f6d25e8b4bad3bcf
```

## Vérifications locales réalisées

```text
node --test tests/rag/*.test.ts
100 tests réussis
```

La migration et le test SQL passent un parseur combiné PostgreSQL + PL/pgSQL.
L’exécution SQL réelle exige le staging Supabase, car Docker n’est pas présent
dans l’environnement de préparation.

Le test SQL construit notamment une règle « décès, 1er degré : 3 jours »
volontairement sourcée sur un passage « mariage : 3 jours ». Il exige le code
`categorical_source_mismatch`, tout en vérifiant que la même source est valide
pour la catégorie `marriage`.

## Avant déploiement

1. Comparer cette branche avec le `main` GitHub synchronisé après RAG-10.6b.
2. Confirmer l’absence de différences non prévues dans les fichiers existants.
3. Faire auditer la migration et l’Edge Function.
4. Déployer uniquement en staging avec `scripts/deploy-rag-10-7-staging.ps1`.
5. Exécuter `tests/sql/rag-10-7-admin-workflow.test.sql`.
6. Réaliser la recette croisée entre deux institutions.

Aucun déploiement en production n’est inclus ni autorisé par ce paquet.
