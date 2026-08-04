# RAG-10.7 — administration des règles

Branche de travail : `rag-10-7-admin-rules-main`.

## Contenu

- migration `20260803123935_rag_admin_rule_workflow.sql` ;
- Edge Function `rag-admin-rules` ;
- contrats stricts, présentation métier et simulation isolée ;
- tests TypeScript et postconditions SQL, dont un scénario négatif dédié au
  décalage catégoriel des sources ;
- interface du back-office staging versionnée dans
  `backoffice/rag-staging/index.html` ;
- scripts de déploiement et de retour arrière staging.

`rule-engine.ts` reste inchangé. Empreinte attendue :

```text
eca639155e99bff7bdf8acdc28e6cecb52f13089fae5bb00f6d25e8b4bad3bcf
```

## Vérifications locales réalisées

```text
node --test tests/rag/*.test.ts
107 tests réussis
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
- test SQL complet et 107 tests TypeScript réussis ;
- aucune donnée de test conservée.

Les versions des migrations Git correspondent à l'historique du staging :
`20260803123935` et `20260803135736`. La migration principale versionnée
conserve en plus la neutralisation temporaire du trigger pendant le backfill.
Cette protection a été ajoutée après la première exécution du staging pour
éviter de reproduire l'invalidation indésirable lors d'un déploiement neuf.

## Étapes restantes

1. Terminer la revue de la PR nº3.
2. Décider séparément d'un éventuel déploiement en production.

Aucun déploiement en production n’est inclus ni autorisé par ce paquet.
