import assert from "node:assert/strict";
import test from "node:test";

import {
  buildEffectiveQuestion,
  parseQuestionRequestBody,
} from "../../supabase/functions/_shared/rag/question-request.ts";
import { RagError } from "../../supabase/functions/_shared/rag/errors.ts";
import {
  evaluateValidatedRuleSets,
  questionTargetsAnnualLeave,
} from "../../supabase/functions/_shared/rag/deterministic-rules.ts";
import { annualLeaveRuleSet } from "./rule-fixtures.ts";

test("une question isolée conserve le contrat historique", () => {
  const parsed = parseQuestionRequestBody({
    question: "  Quelle est la durée des vacances annuelles ?  ",
  });

  assert.equal(
    parsed.effectiveQuestion,
    "Quelle est la durée des vacances annuelles ?",
  );
  assert.equal(parsed.pendingQuestion, null);
});

test("le complément est rattaché explicitement à la demande en cours", () => {
  const parsed = parseQuestionRequestBody({
    question: "J’ai 58 ans et 10 années de service dans la même institution.",
    pending_question: "À combien de jours de vacances annuelles ai-je droit ?",
  });

  assert.match(parsed.effectiveQuestion, /Question initiale/);
  assert.match(parsed.effectiveQuestion, /vacances annuelles/);
  assert.match(parsed.effectiveQuestion, /58 ans/);
  assert.match(parsed.effectiveQuestion, /10 années de service/);

  const evaluation = evaluateValidatedRuleSets(
    parsed.effectiveQuestion,
    [annualLeaveRuleSet()],
  );
  assert.equal(evaluation?.answer.result, "supported");
  assert.match(evaluation!.answer.answer, /30 jours de vacances/);
  assert.doesNotMatch(evaluation!.answer.answer, /35 jours/);
});

test("une clarification générique peut être précisée par vacances annuelles", () => {
  const effective = buildEffectiveQuestion(
    "vacances annuelles",
    "À combien de jours de congé ai-je droit ?",
  );

  assert.equal(questionTargetsAnnualLeave(effective), true);
});

test("deux clarifications successives restent consolidées sans imbrication", () => {
  const firstTurn = buildEffectiveQuestion(
    "vacances annuelles",
    "À combien de jours de congé ai-je droit ?",
  );
  const secondTurn = buildEffectiveQuestion(
    "J’ai 58 ans et 10 années de service dans la même institution.",
    firstTurn,
  );

  assert.equal(
    secondTurn,
    [
      "Question initiale : À combien de jours de congé ai-je droit ?",
      "Complément de l’utilisateur : vacances annuelles",
      "Complément de l’utilisateur : J’ai 58 ans et 10 années de service dans la même institution.",
    ].join("\n"),
  );
  assert.equal(
    secondTurn.match(/Question initiale :/g)?.length,
    1,
  );
  assert.equal(
    secondTurn.match(/Complément de l’utilisateur :/g)?.length,
    2,
  );

  const evaluation = evaluateValidatedRuleSets(
    secondTurn,
    [annualLeaveRuleSet()],
  );
  assert.equal(evaluation?.answer.result, "supported");
  assert.match(evaluation!.answer.answer, /30 jours de vacances/);
  assert.doesNotMatch(evaluation!.answer.answer, /35 jours/);
});

test("les champs inconnus restent refusés", () => {
  assert.throws(
    () =>
      parseQuestionRequestBody({
        question: "Quelle est la règle ?",
        pending_question: "Quel est mon droit ?",
        history: ["texte arbitraire"],
      }),
    (error: unknown) =>
      error instanceof RagError && error.code === "invalid_request",
  );
});

test("une demande en cours invalide reste refusée", () => {
  assert.throws(
    () =>
      parseQuestionRequestBody({
        question: "J’ai 58 ans.",
        pending_question: "x",
      }),
    (error: unknown) =>
      error instanceof RagError && error.code === "invalid_request",
  );
});
