import assert from "node:assert/strict";
import test from "node:test";

import { parseRuleAdminRequest } from "../../supabase/functions/_shared/rag/rule-admin-contract.ts";

const RULE_SET_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const OPERATION_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
const PASSAGE_ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";

test("parse une confirmation fermée", () => {
  assert.deepEqual(parseRuleAdminRequest({
    action: "confirm",
    rule_set_id: RULE_SET_ID,
    expected_revision_number: 3,
    operation_id: OPERATION_ID,
    confirmation: true,
  }), {
    action: "confirm",
    rule_set_id: RULE_SET_ID,
    expected_revision_number: 3,
    operation_id: OPERATION_ID,
    confirmation: true,
  });
});

test("refuse une propriété inconnue", () => {
  assert.throws(() => parseRuleAdminRequest({
    action: "detail",
    rule_set_id: RULE_SET_ID,
    institution_id: "autre-institution",
  }), /unknown_field/);
});

test("un rejet autre exige une note", () => {
  assert.throws(() => parseRuleAdminRequest({
    action: "reject",
    rule_set_id: RULE_SET_ID,
    expected_revision_number: 1,
    operation_id: OPERATION_ID,
    reason_code: "other",
  }), /invalid_rejection_note/);
});

test("parse une correction structurée minimale", () => {
  const parsed = parseRuleAdminRequest({
    action: "save",
    rule_set_id: RULE_SET_ID,
    expected_revision_number: 1,
    operation_id: OPERATION_ID,
    rules: [{
      outcome_value: 25,
      is_default: true,
      display_order: 10,
      label: "Droit de base",
      condition_groups: [],
      source_passage_ids: [PASSAGE_ID],
    }],
  });
  assert.equal(parsed.action, "save");
  assert.equal(parsed.rules?.length, 1);
});

test("refuse les doublons de passages", () => {
  assert.throws(() => parseRuleAdminRequest({
    action: "save",
    rule_set_id: RULE_SET_ID,
    expected_revision_number: 1,
    operation_id: OPERATION_ID,
    rules: [{
      outcome_value: 25,
      is_default: true,
      display_order: 10,
      label: "Droit de base",
      condition_groups: [],
      source_passage_ids: [PASSAGE_ID, PASSAGE_ID],
    }],
  }), /invalid_rule/);
});
