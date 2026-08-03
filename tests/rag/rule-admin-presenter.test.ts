import assert from "node:assert/strict";
import test from "node:test";

import {
  conditionLabel,
  formatOutcome,
  ruleStatusLabel,
} from "../../supabase/functions/_shared/rag/rule-admin-presenter.ts";

test("présente les seuils numériques en français", () => {
  assert.equal(conditionLabel({
    fact_key: "age_years",
    fact_label_fr: "Âge",
    comparator: ">=",
    number_value: 50,
    category_value: null,
    category_label_fr: null,
  }), "Dès 50 ans");
});

test("présente une catégorie avec son libellé contrôlé", () => {
  assert.equal(conditionLabel({
    fact_key: "leave_reason",
    fact_label_fr: "Motif du congé",
    comparator: "=",
    number_value: null,
    category_value: "marriage",
    category_label_fr: "Mariage ou partenariat enregistré",
  }), "Motif du congé est égal à Mariage ou partenariat enregistré");
});

test("présente le statut et l'unité", () => {
  assert.equal(ruleStatusLabel("validated"), "Active");
  assert.equal(formatOutcome(1, "days"), "1 jour");
  assert.equal(formatOutcome(3, "days"), "3 jours");
});
