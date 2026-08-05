import assert from "node:assert/strict";
import test from "node:test";

import {
  BEREAVEMENT_RELATIONSHIP_CLARIFICATION,
  GENERIC_LEAVE_CLARIFICATION,
  routeGenericLeaveQuestion,
} from "../../supabase/functions/_shared/rag/question-routing.ts";
import { buildEffectiveQuestion } from "../../supabase/functions/_shared/rag/question-request.ts";

test("un congé sans type demande une clarification neutre", () => {
  const routed = routeGenericLeaveQuestion(
    "À combien de jours de congé ai-je droit ?",
  );

  assert.deepEqual(routed, {
    result: "needs_clarification",
    answer: GENERIC_LEAVE_CLARIFICATION,
    needs_human_review: false,
  });
  assert.doesNotMatch(routed!.answer, /\d/);
});

test("une mention explicite des vacances reste sur la route déterministe", () => {
  assert.equal(
    routeGenericLeaveQuestion("Combien de semaines de vacances ai-je ?"),
    null,
  );
  assert.equal(
    routeGenericLeaveQuestion("Quel est mon droit aux congés payés ?"),
    null,
  );
  assert.equal(
    routeGenericLeaveQuestion("Combien de jours de congé annuel ai-je ?"),
    null,
  );
});

test("les types de congé documentaires ne sont pas interceptés", () => {
  const questions = [
    "À combien de jours de congé maladie ai-je droit ?",
    "Quelle est la durée du congé maternité ?",
    "Quel congé est prévu lors du décès de ma mère ?",
    "Quel congé est prévu lors du décès de mon frère ?",
    "Quel congé est prévu pour un enfant malade ?",
    "Quel congé est prévu pour mon conjoint malade ?",
    "Existe-t-il un congé sans solde ?",
    "Puis-je prendre un congé pour un examen professionnel ?",
  ];

  for (const question of questions) {
    assert.equal(routeGenericLeaveQuestion(question), null, question);
  }
});

test("un déménagement personnel exprimé par un verbe atteint la règle déterministe", () => {
  const questions = [
    "Je déménage prochainement. À combien de jours de congé ai-je droit ?",
    "Je dois déménager en septembre. Quel congé est prévu ?",
    "Nous allons déménager le mois prochain. Combien de jours avons-nous ?",
  ];

  for (const question of questions) {
    assert.equal(routeGenericLeaveQuestion(question), null, question);
  }
});

test("un décès avec une relation indéterminée demande le lien exact", () => {
  const questions = [
    "À combien de jours de congé ai-je droit en cas de décès d’un proche ?",
    "Quel congé est prévu en cas de décès ?",
    "Combien de jours de congé pour le deuil d’un membre de ma famille ?",
  ];

  for (const question of questions) {
    assert.deepEqual(routeGenericLeaveQuestion(question), {
      result: "needs_clarification",
      answer: BEREAVEMENT_RELATIONSHIP_CLARIFICATION,
      needs_human_review: false,
    }, question);
  }
});

test("la réponse à la clarification décès poursuit le parcours documentaire", () => {
  const answers = [
    "Il s’agit de mon frère.",
    "Il s’agit de ma belle-sœur.",
    "C’est mon fiancé.",
  ];

  for (const answer of answers) {
    const continuedQuestion = buildEffectiveQuestion(
      answer,
      "À combien de jours de congé ai-je droit en cas de décès d’un proche ?",
    );

    assert.equal(routeGenericLeaveQuestion(continuedQuestion), null, answer);
  }
});

test("une demande d'inventaire des congés reste documentaire", () => {
  assert.equal(
    routeGenericLeaveQuestion("Quels sont les différents types de congés ?"),
    null,
  );
  assert.equal(
    routeGenericLeaveQuestion("Peux-tu me donner la liste des congés prévus ?"),
    null,
  );
});

test("un objet qualifié de congé reste documentaire", () => {
  const questions = [
    "À combien de week-ends de congé ai-je droit chaque mois ?",
    "Quelle est la procédure de congé applicable ?",
    "Existe-t-il une indemnité de congé ?",
  ];

  for (const question of questions) {
    assert.equal(routeGenericLeaveQuestion(question), null, question);
  }
});

test("une simple unité de durée ne suffit pas à préciser le type de congé", () => {
  const questions = [
    "À combien de jours de congé ai-je droit ?",
    "Quelle durée de congé puis-je obtenir ?",
    "Combien de semaines de congé sont prévues ?",
  ];

  for (const question of questions) {
    assert.equal(
      routeGenericLeaveQuestion(question)?.result,
      "needs_clarification",
      question,
    );
  }
});

test("une situation encore ambiguë reste clarifiable sans supposer une source", () => {
  const routed = routeGenericLeaveQuestion(
    "Je viens d'avoir un bébé, quel congé ai-je ?",
  );

  assert.equal(routed?.result, "needs_clarification");
  assert.equal(routed?.answer, GENERIC_LEAVE_CLARIFICATION);
});
