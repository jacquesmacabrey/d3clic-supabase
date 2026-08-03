import assert from "node:assert/strict";
import test from "node:test";

import {
  ANSWER_SYSTEM_PROMPT,
  clarificationRefinementReason,
  type ModelAnswer,
  type SearchPassage,
  validateAnswerAgainstSources,
} from "../../supabase/functions/_shared/rag/answer-contract.ts";
import { singleDayRuleSet } from "./rule-fixtures.ts";

const PASSAGE_A = "11111111-1111-4111-8111-111111111111";
const PASSAGE_B = "22222222-2222-4222-8222-222222222222";
const DOCUMENT_A = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const DOCUMENT_B = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

function passage(
  passageId: string,
  documentId: string,
  title: string,
  content: string,
): SearchPassage {
  return {
    passageId,
    documentId,
    title,
    versionLabel: "2026",
    effectiveDate: "2026-01-01",
    pageStart: 1,
    pageEnd: 1,
    sectionTitle: "Congés",
    articleReference: null,
    sourceReference: "Page 1",
    content,
    similarity: 0.9,
  };
}

const maternity = passage(
  PASSAGE_A,
  DOCUMENT_A,
  "Convention collective",
  `${"Préambule sans rapport. ".repeat(30)}
  Le congé maternité est de 17 semaines. Il est rémunéré selon les conditions prévues.`,
);
const internalDirective = passage(
  PASSAGE_B,
  DOCUMENT_B,
  "Directive RH interne",
  "La demande doit être annoncée aux RH. Pour un proche malade, le droit est de 3 jours par cas.",
);
const mixedLeaveAndRest = passage(
  PASSAGE_A,
  DOCUMENT_A,
  "Convention collective",
  "Le droit aux vacances est fixé par palier d'âge et d'ancienneté. Le repos hebdomadaire est de 35 heures.",
);

function answer(
  partial: Partial<ModelAnswer> & Pick<ModelAnswer, "result" | "answer">,
): ModelAnswer {
  return {
    usedPassageIds: [],
    needsHumanReview: false,
    ...partial,
  };
}

test("une durée documentaire correctement citée reste autorisée", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "Le congé maternité est de 17 semaines.",
      usedPassageIds: [PASSAGE_A],
    }),
    [maternity],
  );

  assert.equal(result.client.result, "supported");
  assert.equal(result.errorCode, null);
  assert.match(result.client.citations[0].excerpt, /17 semaines/);
});

test("les durées documentaires légitimes conservent leur unité exacte", () => {
  const cases = [
    {
      value: "35 heures",
      content: "Le repos hebdomadaire total est de 35 heures.",
    },
    {
      value: "3 jours",
      content: "La garde d'un enfant malade est accordée jusqu'à 3 jours.",
    },
    {
      value: "10 jours",
      content: "L'assistance à un proche est limitée à 10 jours par an.",
    },
  ];

  for (const [index, item] of cases.entries()) {
    const source = passage(
      `0000000${index + 1}-0000-4000-8000-00000000000${index + 1}`,
      DOCUMENT_A,
      "Source documentaire active",
      item.content,
    );
    const result = validateAnswerAgainstSources(
      answer({
        result: "supported",
        answer: `La durée documentée est de ${item.value}.`,
        usedPassageIds: [source.passageId],
      }),
      [source],
    );

    assert.equal(result.client.result, "supported", item.value);
  }
});

test("une valeur explicitement documentée n'est pas bloquée par un autre usage du passage", () => {
  const sharedPassage = passage(
    PASSAGE_A,
    DOCUMENT_A,
    "Document avec plusieurs règles",
    [
      "Une règle structurée du document dépend de plusieurs conditions.",
      "Indépendamment de cette règle, le repos hebdomadaire total est de 35 heures.",
    ].join(" "),
  );
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "La durée minimale du repos hebdomadaire est de 35 heures.",
      usedPassageIds: [PASSAGE_A],
    }),
    [sharedPassage],
    [singleDayRuleSet(PASSAGE_A)],
  );

  assert.equal(result.client.result, "supported");
  assert.equal(result.errorCode, null);
});

test("une valeur dans l'unité d'une règle liée reste réservée au moteur déterministe", () => {
  const source = passage(
    PASSAGE_A,
    DOCUMENT_A,
    "Document avec barème",
    "Le barème prévoit une valeur de 25 jours.",
  );
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "La valeur prévue est de 25 jours.",
      usedPassageIds: [PASSAGE_A],
    }),
    [source],
    [singleDayRuleSet(PASSAGE_A)],
  );

  assert.equal(result.client.result, "insufficient_sources");
  assert.equal(result.errorCode, "deterministic_rule_required");
  assert.equal(result.client.needs_human_review, true);
});

test("une réponse sans valeur numérique reste autorisée", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "Ce droit dépend de conditions personnelles.",
      usedPassageIds: [PASSAGE_A],
    }),
    [maternity],
  );

  assert.equal(result.client.result, "supported");
});

test("une clarification chiffrée encore présente après la relance est refusée proprement", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "needs_clarification",
      answer:
        "As-tu moins de 20 ans, entre 20 et 49 ans, ou 50 ans et plus ?",
    }),
    [maternity],
  );

  assert.equal(result.client.result, "insufficient_sources");
  assert.equal(result.client.needs_human_review, true);
  assert.equal(
    result.errorCode,
    "needs_clarification_numeric_rejected",
  );
});

test("une clarification vague encore présente après la relance est refusée proprement", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "needs_clarification",
      answer: "Peux-tu préciser ta situation ?",
    }),
    [maternity],
  );

  assert.equal(result.client.result, "insufficient_sources");
  assert.equal(result.client.needs_human_review, true);
  assert.equal(result.errorCode, "needs_clarification_vague_rejected");
});

test("une clarification qui nomme le critère manquant est conservée", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "needs_clarification",
      answer: "Parles-tu d'un congé maladie ou d'un congé maternité ?",
    }),
    [maternity],
  );

  assert.equal(
    result.client.answer,
    "Parles-tu d'un congé maladie ou d'un congé maternité ?",
  );
  assert.equal(result.errorCode, "needs_clarification");
});

test("le contrôle de précision reste générique quel que soit le document", () => {
  const cases = [
    ["Peux-tu préciser ta situation ?", "vague"],
    ["Peux-tu donner plus d'informations ?", "vague"],
    ["Peux-tu m'en dire plus ?", "vague"],
    ["De quoi s'agit-il ?", "vague"],
    ["Quelle information manque ?", "vague"],
    ["Quelle donnée mentionnée dans le document dois-tu préciser ?", "vague"],
    ["Quel est ton lien avec la personne concernée ?", null],
    ["Quel âge as-tu ?", null],
    ["De quel type d'incident s'agit-il ?", null],
    ["Quelle est ton ancienneté dans l'institution ?", null],
  ] as const;

  for (const [question, expected] of cases) {
    assert.equal(
      clarificationRefinementReason(question),
      expected,
      question,
    );
  }
});

test("les verbes génériques de reformulation ne suffisent pas à nommer un critère", () => {
  const vagueQuestions = [
    "Peux-tu clarifier ?",
    "Peux-tu expliquer ?",
    "Peux-tu détailler ?",
    "Peux-tu confirmer ?",
    "Peux-tu approfondir ?",
    "Pouvez-vous clarifier ?",
    "Pourriez-vous expliquer ?",
    "Clarifie, s'il te plaît.",
    "Explique davantage.",
  ];

  for (const question of vagueQuestions) {
    assert.equal(
      clarificationRefinementReason(question),
      "vague",
      question,
    );
  }

  const specificQuestions = [
    "Peux-tu clarifier le type d'incident ?",
    "Peux-tu confirmer ton ancienneté ?",
    "Pouvez-vous expliquer quel lien vous unit à la personne concernée ?",
  ];

  for (const question of specificQuestions) {
    assert.equal(
      clarificationRefinementReason(question),
      null,
      question,
    );
  }
});

test("le contrat exige explicitement le critère qui départage les réponses", () => {
  assert.match(ANSWER_SYSTEM_PROMPT, /critère minimal/i);
  assert.match(ANSWER_SYSTEM_PROMPT, /nomme explicitement ce critère/i);
  assert.match(ANSWER_SYSTEM_PROMPT, /formulations vagues/i);
});

test("une réponse peut citer plusieurs documents actifs", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer:
        "Le droit documenté est de 3 jours par cas et la demande doit être annoncée aux RH.",
      usedPassageIds: [PASSAGE_B, PASSAGE_A],
    }),
    [
      internalDirective,
      passage(
        PASSAGE_A,
        DOCUMENT_A,
        "Règlement du personnel",
        "Le droit documenté est de 3 jours par cas.",
      ),
    ],
  );

  assert.equal(result.client.result, "supported");
  assert.equal(result.client.citations.length, 2);
  assert.deepEqual(
    new Set(result.client.citations.map((citation) => citation.document_id)),
    new Set([DOCUMENT_A, DOCUMENT_B]),
  );
});

test("un conflit entre documents est signalé et conserve les deux sources", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "conflicting_sources",
      answer:
        "Les documents divergent : l'un prévoit 2 jours et l'autre 3 jours.",
      usedPassageIds: [PASSAGE_A, PASSAGE_B],
      needsHumanReview: true,
    }),
    [
      passage(
        PASSAGE_A,
        DOCUMENT_A,
        "Règlement du personnel",
        "Le droit est de 2 jours.",
      ),
      internalDirective,
    ],
  );

  assert.equal(result.client.result, "conflicting_sources");
  assert.equal(result.client.needs_human_review, true);
  assert.equal(result.client.citations.length, 2);
});

test("une valeur absente des passages cités reste refusée", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "Le droit est de 10 jours.",
      usedPassageIds: [PASSAGE_A],
    }),
    [maternity],
  );

  assert.equal(result.client.result, "insufficient_sources");
  assert.equal(result.errorCode, "ungrounded_numeric_answer");
});

test("une valeur avec une unité différente de la source est refusée", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "Le congé maternité est de 17 jours.",
      usedPassageIds: [PASSAGE_A],
    }),
    [maternity],
  );

  assert.equal(result.client.result, "insufficient_sources");
  assert.equal(result.errorCode, "ungrounded_numeric_answer");
});

test("une réponse libre citant une proposition protégée est bloquée sans chiffre", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "Cette disposition s’applique à ta situation.",
      usedPassageIds: [PASSAGE_A],
    }),
    [maternity],
    [],
    [{ passageId: PASSAGE_A, resultUnit: "days" }],
  );
  assert.equal(result.client.result, "insufficient_sources");
  assert.equal(result.errorCode, "deterministic_rule_required");
  assert.match(result.client.answer, /nécessite une vérification/);
});

test("un passage protégé présent mais non cité ne bloque pas la réponse", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "Le droit documenté est de 3 jours.",
      usedPassageIds: [PASSAGE_B],
    }),
    [maternity, internalDirective],
    [],
    [{ passageId: PASSAGE_A, resultUnit: "days" }],
  );
  assert.equal(result.client.result, "supported");
  assert.equal(result.errorCode, null);
});

test("un passage protégé cité avec un nombre dans une autre unité n'est pas bloqué", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "Le repos hebdomadaire est de 35 heures.",
      usedPassageIds: [PASSAGE_A],
    }),
    [mixedLeaveAndRest],
    [],
    [{ passageId: PASSAGE_A, resultUnit: "days" }],
  );
  assert.equal(result.client.result, "supported");
  assert.equal(result.errorCode, null);
});

test("un passage protégé cité avec un chiffre dans l'unité protégée reste bloqué", () => {
  const result = validateAnswerAgainstSources(
    answer({
      result: "supported",
      answer: "Le droit est de 35 jours.",
      usedPassageIds: [PASSAGE_A],
    }),
    [mixedLeaveAndRest],
    [],
    [{ passageId: PASSAGE_A, resultUnit: "days" }],
  );
  assert.equal(result.client.result, "insufficient_sources");
  assert.equal(result.errorCode, "deterministic_rule_required");
});
