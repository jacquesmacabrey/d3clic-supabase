import assert from "node:assert/strict";
import test from "node:test";

import {
  evaluateValidatedRuleSets,
} from "../../supabase/functions/_shared/rag/deterministic-rules.ts";
import {
  evaluateCondition,
} from "../../supabase/functions/_shared/rag/rule-engine.ts";
import type {
  RuleCondition,
  RuleTemplate,
} from "../../supabase/functions/_shared/rag/rule-template-contract.ts";
import {
  annualLeaveRuleSet,
  annualLeaveTemplate,
} from "./rule-fixtures.ts";

function evaluate(question: string) {
  return evaluateValidatedRuleSets(question, [annualLeaveRuleSet()]);
}

test("58 ans sans ancienneté donne 30 jours et conserve le palier possible", () => {
  const result = evaluate("J’ai 58 ans. Combien de jours de vacances ?");
  assert.equal(result?.answer.result, "supported");
  assert.match(result!.answer.answer, /30 jours de vacances/);
  assert.match(result!.answer.answer, /25 ans de service/);
  assert.match(result!.answer.answer, /35 jours/);
});

test("58 ans et 25 ans de service donne 35 jours", () => {
  const result = evaluate(
    "J’ai 58 ans et 25 ans de service. Quel est mon droit aux vacances ?",
  );
  assert.equal(result?.answer.result, "supported");
  assert.match(result!.answer.answer, /35 jours de vacances/);
});

test("moins de 20 ans donne 30 jours", () => {
  const result = evaluate("J’ai 19 ans. Combien de jours de vacances ?");
  assert.match(result!.answer.answer, /30 jours de vacances/);
});

test("50 ans donne 30 jours", () => {
  const result = evaluate("J’ai 50 ans. Quel est mon droit aux vacances ?");
  assert.match(result!.answer.answer, /30 jours de vacances/);
});

test("60 ans donne 35 jours", () => {
  const result = evaluate("J’ai 60 ans. Quel est mon droit aux vacances ?");
  assert.match(result!.answer.answer, /35 jours de vacances/);
});

test("15 ans de service donne 30 jours", () => {
  const result = evaluate(
    "J’ai 15 ans de service. Quel est mon droit aux vacances ?",
  );
  assert.match(result!.answer.answer, /30 jours de vacances/);
});

test("25 ans de service donne 35 jours", () => {
  const result = evaluate(
    "J’ai 25 ans de service. Quel est mon droit aux vacances ?",
  );
  assert.match(result!.answer.answer, /35 jours de vacances/);
});

test("un âge décimal est refusé lorsque le fait exige un entier", () => {
  const result = evaluate(
    "J’ai 58,5 ans. Quel est mon droit aux vacances ?",
  );
  assert.equal(result?.answer.result, "needs_clarification");
  assert.equal(result?.errorCode, "deterministic_invalid_question_facts");
});

test("une ancienneté supérieure à l’âge provoque une clarification", () => {
  const result = evaluate(
    "J’ai 30 ans et 35 ans de service. Quel est mon droit aux vacances ?",
  );
  assert.equal(result?.answer.result, "needs_clarification");
  assert.equal(result?.errorCode, "deterministic_impossible_question_facts");
});

test("le moteur compare un fait catégoriel sans logique métier spéciale", () => {
  const base = annualLeaveTemplate();
  const template: RuleTemplate = {
    ...base,
    templateKey: "special_leave_days",
    facts: [{
      factKey: "event_type",
      valueType: "category",
      extractorKey: "future_event_type_fr_v1",
      labelFr: "Événement",
      clarificationLabelFr: "le type d’événement",
      minimumNumber: null,
      maximumNumber: null,
      integerOnly: false,
      allowedOperators: ["="],
      categoryValues: [{ valueKey: "marriage", labelFr: "Mariage" }],
    }],
    factConstraints: [],
  };
  const condition: RuleCondition = {
    factKey: "event_type",
    factValueType: "category",
    comparator: "=",
    numberValue: null,
    categoryValue: "marriage",
  };
  assert.equal(
    evaluateCondition(condition, { event_type: "marriage" }, template),
    "true",
  );
  assert.equal(
    evaluateCondition(condition, { event_type: null }, template),
    "unknown",
  );
});

