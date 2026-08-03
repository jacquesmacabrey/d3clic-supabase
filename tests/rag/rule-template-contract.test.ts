import assert from "node:assert/strict";
import test from "node:test";

import { parseRuleContext } from "../../supabase/functions/_shared/rag/rule-template-contract.ts";
import {
  annualLeaveRuleSet,
  ruleSetToRpc,
  SOURCE_A,
} from "./rule-fixtures.ts";

function rawRuleSet(): Record<string, unknown> {
  return structuredClone(
    ruleSetToRpc(annualLeaveRuleSet()),
  ) as Record<string, unknown>;
}

test("le contexte générique valide est parsé strictement", () => {
  const parsed = parseRuleContext(
    [rawRuleSet()],
    [{ passage_id: SOURCE_A, result_unit: "days" }],
  );
  assert.equal(parsed?.ruleSets.length, 1);
  assert.equal(parsed?.ruleSets[0].template.facts.length, 2);
  assert.deepEqual(parsed?.protectedPassages, [
    { passageId: SOURCE_A, resultUnit: "days" },
  ]);
});

test("une liaison vers une autre version de gabarit est refusée", () => {
  const raw = rawRuleSet();
  raw.template_version_id = "12345678-1234-4234-8234-123456789012";
  assert.equal(parseRuleContext([raw], []), null);
});

test("une clé de fait hors registre syntaxique est refusée", () => {
  const raw = rawRuleSet();
  const template = raw.template as Record<string, unknown>;
  const facts = template.facts as Record<string, unknown>[];
  facts[0].fact_key = "Âge libre";
  assert.equal(parseRuleContext([raw], []), null);
});

test("une condition avec deux types de valeur est refusée", () => {
  const raw = rawRuleSet();
  const rules = raw.rules as Record<string, unknown>[];
  const groups = rules[1].condition_groups as Record<string, unknown>[];
  const conditions = groups[0].conditions as Record<string, unknown>[];
  conditions[0].category_value = "marriage";
  assert.equal(parseRuleContext([raw], []), null);
});

test("une condition sans valeur est refusée", () => {
  const raw = rawRuleSet();
  const rules = raw.rules as Record<string, unknown>[];
  const groups = rules[1].condition_groups as Record<string, unknown>[];
  const conditions = groups[0].conditions as Record<string, unknown>[];
  conditions[0].number_value = null;
  assert.equal(parseRuleContext([raw], []), null);
});

test("un fait catégoriel sans catalogue fermé est refusé", () => {
  const raw = rawRuleSet();
  const template = raw.template as Record<string, unknown>;
  const facts = template.facts as Record<string, unknown>[];
  facts[0] = {
    ...facts[0],
    value_type: "category",
    minimum_number: null,
    maximum_number: null,
    integer_only: false,
    category_values: [],
  };
  assert.equal(parseRuleContext([raw], []), null);
});

test("une borne numérique inversée est refusée", () => {
  const raw = rawRuleSet();
  const template = raw.template as Record<string, unknown>;
  template.result_minimum_number = 100;
  template.result_maximum_number = 10;
  assert.equal(parseRuleContext([raw], []), null);
});

test("les passages protégés sont dédupliqués par identifiant et unité", () => {
  const parsed = parseRuleContext(
    [],
    [
      { passage_id: SOURCE_A, result_unit: "days" },
      { passage_id: SOURCE_A, result_unit: "days" },
    ],
  );
  assert.deepEqual(parsed?.protectedPassages, [
    { passageId: SOURCE_A, resultUnit: "days" },
  ]);
});

test("un même passage protégé par deux unités distinctes est conservé deux fois", () => {
  const parsed = parseRuleContext(
    [],
    [
      { passage_id: SOURCE_A, result_unit: "days" },
      { passage_id: SOURCE_A, result_unit: "hours" },
    ],
  );
  assert.equal(parsed?.protectedPassages.length, 2);
});

test("un identifiant de passage protégé invalide est refusé", () => {
  assert.equal(
    parseRuleContext(
      [],
      [{ passage_id: "pas-un-uuid", result_unit: "days" }],
    ),
    null,
  );
});

test("une unité de passage protégé invalide est refusée", () => {
  assert.equal(
    parseRuleContext(
      [],
      [{ passage_id: SOURCE_A, result_unit: "Jours!" }],
    ),
    null,
  );
});
