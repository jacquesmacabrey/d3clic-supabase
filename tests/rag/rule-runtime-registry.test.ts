import assert from "node:assert/strict";
import test from "node:test";

import {
  RUNTIME_REGISTRY_KEYS,
  detectTemplateIntent,
  extractFacts,
  questionTargetsAnnualLeave,
  renderResolution,
  runtimeRegistryImplementationMismatch,
  runtimeRegistryMismatch,
} from "../../supabase/functions/_shared/rag/rule-runtime-registry.ts";
import { resolveValidatedRuleSet } from "../../supabase/functions/_shared/rag/rule-engine.ts";
import {
  annualLeaveTemplate,
  exceptionalLeaveRuleSet,
  exceptionalLeaveTemplate,
} from "./rule-fixtures.ts";

test("le détecteur reconnaît les vacances annuelles avec confiance", () => {
  assert.deepEqual(
    detectTemplateIntent("Combien de jours de vacances ai-je ?"),
    { templateKey: "annual_leave_days", confidence: 1 },
  );
});

test("les jours de congé non qualifiés ne ciblent pas les vacances", () => {
  assert.equal(
    detectTemplateIntent("Combien de jours de congé ai-je ?"),
    null,
  );
});

test("les congés exclus ne sont pas assimilés aux vacances", () => {
  const excluded = [
    "congé maladie",
    "congé maternité",
    "congé paternité",
    "congé parental",
    "congé sans solde",
  ];
  for (const question of excluded) {
    assert.equal(questionTargetsAnnualLeave(question), false, question);
  }
});

test("les formulations congés annuels et congés payés restent reconnues", () => {
  assert.equal(questionTargetsAnnualLeave("mes congés annuels"), true);
  assert.equal(questionTargetsAnnualLeave("mes congés payés"), true);
});

test("une clé de rendu absente produit un mismatch contrôlé", () => {
  const template = {
    ...annualLeaveTemplate(),
    rendererKey: "renderer_supprime_v9",
  };
  assert.equal(runtimeRegistryMismatch(template), "renderer_supprime_v9");
});

test("le registre TypeScript expose exactement ses quatre familles", () => {
  assert.equal(runtimeRegistryImplementationMismatch(), null);
  assert.deepEqual(
    [...new Set(RUNTIME_REGISTRY_KEYS.map((entry) => entry.keyType))].sort(),
    [
      "aggregation_strategy",
      "fact_extractor",
      "intent_detector",
      "renderer",
    ],
  );
  assert.equal(RUNTIME_REGISTRY_KEYS.length, 8);
});

test("le détecteur reconnaît un congé exceptionnel avec un lien de parenté précis", () => {
  assert.deepEqual(
    detectTemplateIntent("Décès de ma mère, combien de jours ai-je ?"),
    {
      templateKey: "fixed_duration_exceptional_leave_by_event",
      confidence: 1,
    },
  );
});

test("un décès sans lien de parenté précisé ne cible aucun gabarit", () => {
  assert.equal(detectTemplateIntent("Décès d’un proche, combien de jours ?"), null);
});

test("un mariage cible bien le gabarit des congés exceptionnels", () => {
  assert.deepEqual(
    detectTemplateIntent("Je me marie le mois prochain, quel congé ai-je ?"),
    {
      templateKey: "fixed_duration_exceptional_leave_by_event",
      confidence: 1,
    },
  );
});

test("les deux gabarits ne se déclenchent jamais simultanément sur les mêmes questions de test", () => {
  const questions = [
    "Combien de jours de vacances ai-je ?",
    "Décès de ma mère, combien de jours ?",
    "Je me marie, quel congé ai-je ?",
    "Je déménage la semaine prochaine",
  ];
  for (const question of questions) {
    const intent = detectTemplateIntent(question);
    assert.notEqual(intent, null, question);
  }
});

test("extractFacts reconnaît le motif mariage", () => {
  const result = extractFacts(
    "Je me marie le mois prochain",
    exceptionalLeaveTemplate(),
  );
  assert.equal(result.status, "ok");
  assert.equal(result.facts.leave_reason, "marriage");
});

test("extractFacts reconnaît le décès au premier degré", () => {
  const result = extractFacts(
    "Décès de ma mère",
    exceptionalLeaveTemplate(),
  );
  assert.equal(result.facts.leave_reason, "death_first_degree");
});

test("extractFacts reconnaît le décès au deuxième degré, y compris les alliés", () => {
  for (const question of ["Décès de mon frère", "Décès de mon beau-père"]) {
    const result = extractFacts(question, exceptionalLeaveTemplate());
    assert.equal(result.facts.leave_reason, "death_second_degree", question);
  }
});

test("les formes composées ne déclenchent jamais aussi le premier degré", () => {
  const questions = [
    "Décès de mon beau-père",
    "Décès de ma belle-mère",
    "Décès de mon grand-père",
    "Décès de ma grand-mère",
    "Décès de mon petit-fils",
    "Décès de ma petite-fille",
  ];
  for (const question of questions) {
    const result = extractFacts(question, exceptionalLeaveTemplate());
    assert.equal(result.status, "ok", question);
    assert.equal(result.facts.leave_reason, "death_second_degree", question);
  }
});

test("extractFacts ne reconnaît aucun motif sans indice suffisant", () => {
  const result = extractFacts(
    "J’ai une question sur mes congés",
    exceptionalLeaveTemplate(),
  );
  assert.equal(result.status, "ok");
  assert.equal(result.facts.leave_reason, null);
});

test("mariage résolu correctement de bout en bout", () => {
  const ruleSet = exceptionalLeaveRuleSet();
  const extraction = extractFacts(
    "Je me marie le mois prochain",
    ruleSet.template,
  );
  const resolution = resolveValidatedRuleSet(ruleSet, extraction);
  const answer = renderResolution(resolution, ruleSet.template);
  assert.equal(answer?.result, "supported");
  assert.match(answer!.answer, /3 jours/);
});

test("décès au premier degré résolu correctement de bout en bout", () => {
  const ruleSet = exceptionalLeaveRuleSet();
  const extraction = extractFacts("Décès de ma mère", ruleSet.template);
  const resolution = resolveValidatedRuleSet(ruleSet, extraction);
  const answer = renderResolution(resolution, ruleSet.template);
  assert.equal(answer?.result, "supported");
  assert.match(answer!.answer, /5 jours/);
});

test("aucun motif reconnu déclenche une clarification, jamais le déménagement par défaut affiché comme réponse", () => {
  const ruleSet = exceptionalLeaveRuleSet();
  const extraction = extractFacts(
    "J’ai une question sur mes congés",
    ruleSet.template,
  );
  const resolution = resolveValidatedRuleSet(ruleSet, extraction);
  const answer = renderResolution(resolution, ruleSet.template);
  assert.equal(answer?.result, "needs_clarification");
  assert.doesNotMatch(answer!.answer, /1 jour/);
});
