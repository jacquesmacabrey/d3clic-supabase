# RAG-10.7 — administration des règles

Branche de travail : `rag-10-7-admin-rules-main`.

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
Le test SQL complet a également été exécuté avec succès sur le staging
Supabase ; toutes ses mutations sont annulées par `ROLLBACK`.

Le test SQL construit notamment une règle « décès, 1er degré : 3 jours »
volontairement sourcée sur un passage « mariage : 3 jours ». Il exige le code
`categorical_source_mismatch`, tout en vérifiant que la même source est valide
pour la catégorie `marriage`.

## Statut du staging au 3 août 2026

- branche transposée sur le `main` GitHub `c1c5b88` ;
- audit technique terminé sans réserve ;
- migration appliquée sur `d3clic-staging-auth` ;
- Edge Function `rag-admin-rules` active en version 1 ;
- effet indésirable du backfill corrigé : le trigger de cycle de vie est
  neutralisé uniquement pendant le remplissage des empreintes de sources ;
- deux jeux de règles rétablis en `validated` à partir des journaux historiques,
  avec deux événements d’audit explicites ;
- test SQL complet et 100 tests TypeScript réussis ;
- aucune donnée de test conservée.

## Étapes restantes

1. Publier la branche sur GitHub et ouvrir la revue correspondante.
2. Réaliser la recette fonctionnelle du back-office, notamment l’isolation
   entre deux institutions.
3. Décider séparément d’un éventuel déploiement en production.

Aucun déploiement en production n’est inclus ni autorisé par ce paquet.
