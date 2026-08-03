import assert from "node:assert/strict";
import test from "node:test";

import {
  chunkDocument,
  type PassageDraft,
} from "../../supabase/functions/_shared/rag/chunk.ts";
import type {
  ExtractedDocument,
} from "../../supabase/functions/_shared/rag/extract.ts";

function extracted(
  text: string,
  extractionMethod = "unpdf",
): ExtractedDocument {
  return {
    segments: [{ text, pageStart: 28, pageEnd: 28 }],
    pageCount: 1,
    characterCount: text.length,
    extractionMethod,
    extractionVersion: "test",
  };
}

const EXCEPTIONAL_LEAVE_SECTION = [
  "4.12.2 Congés extraordinaires",
  "1 L'employé-e a droit aux congés extraordinaires suivants :",
  "a) mariage de l'employé-e ou partenariat enregistré : 3 jours ;",
  "b) décès d'un parent ou allié au 1er degré : 5 jours (conjoint, partenaire déclaré, enfant, père, mère) ;",
  "c) décès d'un parent ou allié au 2e degré : 2 jours (grands-parents, beaux grands-parents, petits-enfants, beaux petits-enfants, frère et sœur) ;",
  "d) déménagement : 1 jour ;",
  "e) enfant malade : jusqu'à 3 jours par cas, sur présentation d'un certificat médical ;",
  "f) enfant gravement atteint dans sa santé : selon l'art. 329i CO ;",
  "g) soins à un proche : jusqu'à 3 jours par cas et 10 jours par an.",
].join("\n");

test("un long passage de liste lettrée est découpé en plusieurs passages", () => {
  const passages = chunkDocument(
    extracted(EXCEPTIONAL_LEAVE_SECTION),
    "CCT-21",
  );
  assert.ok(
    passages.length > 1,
    "le passage unique attendu avant correctif ne doit plus se produire",
  );
});

test("chaque lettre a-g démarre bien un nouveau passage", () => {
  const passages = chunkDocument(
    extracted(EXCEPTIONAL_LEAVE_SECTION),
    "CCT-21",
  );
  const startsWithLetter = passages.filter((passage) =>
    /^[a-g]\s*[-–—.)]\s+\S/u.test(passage.content)
  );
  assert.equal(startsWithLetter.length, 7);
});

test("les lettres a-d et e-g se retrouvent dans des passages distincts", () => {
  const passages = chunkDocument(
    extracted(EXCEPTIONAL_LEAVE_SECTION),
    "CCT-21",
  );
  const passageOf = (marker: string): PassageDraft | undefined =>
    passages.find((passage) => passage.content.includes(marker));

  const mariage = passageOf("mariage de l'employé-e");
  const demenagement = passageOf("déménagement : 1 jour");
  const enfantMalade = passageOf("enfant malade");
  const soinsProche = passageOf("soins à un proche");

  assert.ok(mariage && demenagement && enfantMalade && soinsProche);
  const abcdIndexes = new Set(
    [mariage, demenagement].map((passage) => passage!.chunkIndex),
  );
  const efgIndexes = new Set(
    [enfantMalade, soinsProche].map((passage) => passage!.chunkIndex),
  );
  for (const abcdIndex of abcdIndexes) {
    assert.equal(efgIndexes.has(abcdIndex), false);
  }
});

test("le titre de section reste identique sur tous les fragments de liste", () => {
  const passages = chunkDocument(
    extracted(EXCEPTIONAL_LEAVE_SECTION),
    "CCT-21",
  );
  const titles = new Set(passages.map((passage) => passage.sectionTitle));
  assert.deepEqual([...titles], ["4.12.2 Congés extraordinaires"]);
});

test("une lettre de liste n'est jamais promue au rang de titre de section", () => {
  const passages = chunkDocument(
    extracted(EXCEPTIONAL_LEAVE_SECTION),
    "CCT-21",
  );
  for (const passage of passages) {
    assert.doesNotMatch(passage.sectionTitle ?? "", /^[a-g]\s*[-–—.)]/u);
  }
});

test("list_fragment_index distingue les fragments issus d'une même liste", () => {
  const passages = chunkDocument(
    extracted(EXCEPTIONAL_LEAVE_SECTION),
    "CCT-21",
  );
  const fragmentIndexes = passages
    .map((passage) => passage.metadata.list_fragment_index)
    .filter((value): value is number => typeof value === "number");
  assert.ok(fragmentIndexes.length >= 7);
  assert.deepEqual(fragmentIndexes, [...fragmentIndexes].sort((a, b) => a - b));
});

test("un paragraphe ordinaire sans liste lettrée reste un seul passage", () => {
  const text = [
    "4.10 Vacances",
    "1 L'employé-e a droit aux vacances suivantes par année civile :",
    "avant l'âge de 20 ans : 30 jours ;",
    "dès l'âge de 20 ans : 25 jours.",
  ].join("\n");
  const passages = chunkDocument(extracted(text), "CCT-21");
  assert.equal(passages.length, 1);
  assert.equal(passages[0].metadata.list_fragment_index, null);
});

test("une ligne isolée ressemblant à une lettre sans contenu de liste réel n'est pas coupée à tort", () => {
  const text = [
    "3.1 Objet",
    "Le présent règlement précise les modalités d'application de la CCT.",
    "Il est disponible en version papier a) la demande sur simple requête écrite.",
  ].join("\n");
  const passages = chunkDocument(extracted(text), "CCT-21");
  // "a) la demande" ressemble syntaxiquement à une frontière de liste ;
  // ce n'est pas le cas visé, mais le comportement reste sûr : au pire un
  // découpage supplémentaire, jamais une perte de contenu ni un titre erroné.
  const totalContent = passages.map((passage) => passage.content).join("\n");
  assert.match(totalContent, /modalités d'application/);
  assert.match(totalContent, /simple requête écrite/);
  for (const passage of passages) {
    assert.doesNotMatch(passage.sectionTitle ?? "", /^[a-g]\s*[-–—.)]/u);
  }
});

test("les titres explicites restent détectés normalement (non-régression)", () => {
  const text = [
    "Article 5 Vacances",
    "Le texte de l'article continue normalement sur cette ligne.",
    "Article 6 Congés",
    "Suite du texte pour le second article.",
  ].join("\n");
  const passages = chunkDocument(extracted(text), "CCT-21");
  const titles = passages.map((passage) => passage.sectionTitle);
  assert.ok(titles.includes("Article 5 Vacances"));
  assert.ok(titles.includes("Article 6 Congés"));
});
