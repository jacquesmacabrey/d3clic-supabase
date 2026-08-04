import assert from "node:assert/strict";
import test from "node:test";

import { simulateAdministrativeRuleSet } from "../../supabase/functions/_shared/rag/rule-admin-simulation.ts";
import {
  annualLeaveRuleSet,
  exceptionalLeaveRuleSet,
} from "./rule-fixtures.ts";

function rawRuleSet(set = annualLeaveRuleSet()) {
  return {
    rule_set_id: set.ruleSetId,
    rule_key: set.ruleKey,
    template_version_id: set.templateVersionId,
    aggregation_strategy: set.aggregationStrategy,
    result_unit: set.resultUnit,
    document_id: set.documentId,
    template: {
      template_version_id: set.template.templateVersionId,
      template_key: set.template.templateKey,
      version_number: set.template.versionNumber,
      result_value_type: set.template.resultValueType,
      result_integer_only: set.template.resultIntegerOnly,
      result_minimum_number: set.template.resultMinimumNumber,
      result_maximum_number: set.template.resultMaximumNumber,
      result_unit: set.template.resultUnit,
      aggregation_strategy: set.template.aggregationStrategy,
      intent_detector_key: set.template.intentDetectorKey,
      renderer_key: set.template.rendererKey,
      clarification_message_fr: set.template.clarificationMessageFr,
      facts: set.template.facts.map((fact) => ({
        fact_key: fact.factKey,
        value_type: fact.valueType,
        extractor_key: fact.extractorKey,
        label_fr: fact.labelFr,
        clarification_label_fr: fact.clarificationLabelFr,
        minimum_number: fact.minimumNumber,
        maximum_number: fact.maximumNumber,
        integer_only: fact.integerOnly,
        allowed_operators: fact.allowedOperators,
        category_values: fact.categoryValues.map((value) => ({
          value_key: value.valueKey,
          label_fr: value.labelFr,
        })),
      })),
      fact_constraints: set.template.factConstraints.map((constraint) => ({
        constraint_key: constraint.constraintKey,
        left_fact_key: constraint.leftFactKey,
        comparator: constraint.comparator,
        right_fact_key: constraint.rightFactKey,
        error_code: constraint.errorCode,
      })),
    },
    rules: set.rules.map((rule) => ({
      rule_id: rule.ruleId,
      outcome_value: rule.outcomeValue,
      is_default: rule.isDefault,
      label: rule.label,
      condition_groups: rule.conditionGroups.map((group) => ({
        conditions: group.conditions.map((condition) => ({
          fact_key: condition.factKey,
          fact_value_type: condition.factValueType,
          comparator: condition.comparator,
          number_value: condition.numberValue,
          category_value: condition.categoryValue,
        })),
      })),
      source_passage_ids: rule.sourcePassageIds,
    })),
  };
}

test("simule un brouillon sans modifier son statut persistant", () => {
  const result = simulateAdministrativeRuleSet(
    rawRuleSet(),
    "proposed",
    "J’ai 58 ans et 10 ans de service, combien de jours de vacances ?",
  );
  assert.equal(result.success, true);
  assert.equal(result.persisted_status, "proposed");
  assert.equal(result.simulation_did_not_change_status, true);
  assert.match(result.answer ?? "", /30 jours/);
});

test("refuse une question destinée à un autre gabarit", () => {
  const result = simulateAdministrativeRuleSet(
    rawRuleSet(),
    "needs_attention",
    "Je me marie, quel congé ai-je ?",
  );
  assert.equal(result.success, false);
  assert.equal(result.code, "question_outside_template");
});

test("la simulation n’accorde pas le congé de mariage pour le mariage d’un tiers", () => {
  const result = simulateAdministrativeRuleSet(
    rawRuleSet(exceptionalLeaveRuleSet()),
    "validated",
    "Je participe au mariage de mon frère. À combien de jours ai-je droit ?",
  );
  assert.equal(result.success, true);
  assert.equal(result.code, "needs_clarification");
  assert.doesNotMatch(result.answer ?? "", /3 jours/);
});

test("la simulation n’accorde pas un jour pour le déménagement d’un tiers", () => {
  const result = simulateAdministrativeRuleSet(
    rawRuleSet(exceptionalLeaveRuleSet()),
    "validated",
    "Mon collègue déménage. À combien de jours ai-je droit ?",
  );
  assert.equal(result.success, true);
  assert.equal(result.code, "needs_clarification");
  assert.doesNotMatch(result.answer ?? "", /1 jour/);
});
