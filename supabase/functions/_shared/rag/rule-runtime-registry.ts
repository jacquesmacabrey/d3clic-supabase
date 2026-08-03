import type {
  DeterministicResolution,
  ExtractedFacts,
  FactExtraction,
} from "./rule-engine.ts";
import type {
  RuleCondition,
  RuleTemplate,
  TemplateFact,
} from "./rule-template-contract.ts";
import runtimeRegistryManifest from "./rule-runtime-registry.json" with {
  type: "json",
};

export interface PublicDeterministicAnswer {
  result: "supported" | "needs_clarification" | "insufficient_sources";
  answer: string;
  needs_human_review: boolean;
}

export interface TemplateIntent {
  templateKey: string;
  confidence: number;
}

interface ExtractedFact {
  status: "ok" | "invalid" | "conflicting";
  value: number | string | null;
  errors: string[];
}

type IntentDetector = (question: string) => number;
type FactExtractor = (
  question: string,
  fact: TemplateFact,
) => ExtractedFact;
type Renderer = (
  resolution: DeterministicResolution,
  template: RuleTemplate,
) => PublicDeterministicAnswer;

const FRENCH_NUMBER_WORD =
  "(?:un|une|deux|trois|quatre|cinq|six|sept|huit|neuf|dix|onze|douze|treize|quatorze|quinze|seize|vingt|vingts|trente|quarante|cinquante|soixante|cent)";
const FRENCH_NUMBER_SEPARATOR = "(?:\\s*-\\s*|\\s+)";
const FRENCH_NUMBER_WITH_UNIT_PATTERN = new RegExp(
  `\\b${FRENCH_NUMBER_WORD}(?:${FRENCH_NUMBER_SEPARATOR}(?:et${FRENCH_NUMBER_SEPARATOR})?${FRENCH_NUMBER_WORD})*\\s+(?:jours?|ans?|semaines?|mois)\\b`,
);

function normalize(value: string): string {
  return value
    .normalize("NFKD")
    .replace(/\p{M}/gu, "")
    .replace(/[’`´]/g, "'")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

export function questionTargetsAnnualLeave(question: string): boolean {
  const text = normalize(question);
  return (
    /\bvacances?\b/.test(text) ||
    /\bconges?\s+(?:annuels?|payes?)\b/.test(text) ||
    /\bdroit\s+annuel\s+aux?\s+conges?\b/.test(text)
  );
}

function annualLeaveIntent(question: string): number {
  return questionTargetsAnnualLeave(question) ? 1 : 0;
}

function collectNumbers(text: string, patterns: RegExp[]): string[] {
  const values: string[] = [];
  for (const pattern of patterns) {
    for (const match of text.matchAll(pattern)) {
      if (match[1] !== undefined) values.push(match[1]);
    }
  }
  return values;
}

function parseNumericFactValues(
  rawValues: string[],
  fact: TemplateFact,
): ExtractedFact {
  const invalid: string[] = [];
  const values = new Set<number>();
  for (const raw of rawValues) {
    if (!/^-?\d+(?:[.,]\d+)?$/.test(raw)) {
      invalid.push(`${fact.factKey}_not_number`);
      continue;
    }
    const parsed = Number(raw.replace(",", "."));
    if (
      !Number.isFinite(parsed) ||
      (fact.integerOnly && !Number.isSafeInteger(parsed)) ||
      (fact.minimumNumber !== null && parsed < fact.minimumNumber) ||
      (fact.maximumNumber !== null && parsed > fact.maximumNumber)
    ) {
      invalid.push(`${fact.factKey}_out_of_range`);
      continue;
    }
    values.add(parsed);
  }
  return {
    status: invalid.length > 0
      ? "invalid"
      : values.size > 1
      ? "conflicting"
      : "ok",
    value: values.size === 1 ? [...values][0] : null,
    errors: [
      ...invalid,
      ...(values.size > 1 ? [`conflicting_${fact.factKey}`] : []),
    ],
  };
}

function extractAgeYears(question: string, fact: TemplateFact): ExtractedFact {
  const text = normalize(question);
  return parseNumericFactValues(
    collectNumbers(text, [
      /\bj[' ]?ai\s+(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
      /\ba\s+(-?\d+(?:[.,]\d+)?)\s*ans?\b(?!\s+(?:de\s+service|d[' ]anciennete))/g,
      /\b(?:age)\s*(?:de|:|est\s+de)?\s*(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
      /\bagee?\s+de\s+(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
      /\bemploye?\s+de\s+(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
      /\b(-?\d+(?:[.,]\d+)?)\s*ans?\s+d[' ]age\b/g,
    ]),
    fact,
  );
}

function extractServiceYears(
  question: string,
  fact: TemplateFact,
): ExtractedFact {
  const text = normalize(question);
  return parseNumericFactValues(
    collectNumbers(text, [
      /\b(-?\d+(?:[.,]\d+)?)\s*(?:ans?|annees?)\s+(?:de\s+service|d[' ]anciennete)\b/g,
      /\b(?:anciennete|service)\s*(?:de|:|est\s+de)?\s*(-?\d+(?:[.,]\d+)?)\s*(?:ans?|annees?)\b/g,
      /\b(?:compte|ayant|avec)\s+(-?\d+(?:[.,]\d+)?)\s*(?:ans?|annees?)\s+(?:de\s+service|d[' ]anciennete)\b/g,
      /\b(?:cela|ca)\s+fait\s+(-?\d+(?:[.,]\d+)?)\s*(?:ans?|annees?)\s+que\s+(?:je\s+)?(?:travaille|travail|suis)\b/g,
      /\b(?:je\s+)?travaille\s+(?:ici\s+)?depuis\s+(-?\d+(?:[.,]\d+)?)\s*(?:ans?|annees?)\b/g,
      /\bj[' ]y\s+travaille\s+depuis\s+(-?\d+(?:[.,]\d+)?)\s*(?:ans?|annees?)\b/g,
      /\b(?:je\s+)?travaille\s+(?:dans|pour|au\s+sein\s+de)\s+(?:cette|la|l[' ])?\s*institution\s+depuis\s+(-?\d+(?:[.,]\d+)?)\s*(?:ans?|annees?)\b/g,
    ]),
    fact,
  );
}

function conditionText(condition: RuleCondition): string {
  const value = condition.numberValue ?? condition.categoryValue;
  const subject = condition.factKey === "age_years" ? "tu as" : "tu comptes";
  const suffix = condition.factKey === "age_years"
    ? "ans"
    : "ans de service dans la même institution";
  switch (condition.comparator) {
    case ">=":
      return `${subject} au moins ${value} ${suffix}`;
    case ">":
      return `${subject} plus de ${value} ${suffix}`;
    case "<=":
      return `${subject} au plus ${value} ${suffix}`;
    case "<":
      return `${subject} moins de ${value} ${suffix}`;
    case "=":
      return `${subject} exactement ${value} ${suffix}`;
    case "!=":
      return `${subject} une valeur différente de ${value} ${suffix}`;
  }
}

function requirementsText(groups: RuleCondition[][]): string {
  return groups
    .map((group) => group.map(conditionText).join(" et "))
    .join(" ou ");
}

function renderAnnualLeave(
  resolution: DeterministicResolution,
  template: RuleTemplate,
): PublicDeterministicAnswer {
  if (resolution.status === "needs_clarification") {
    return {
      result: "needs_clarification",
      answer: template.clarificationMessageFr,
      needs_human_review: false,
    };
  }
  if (resolution.status === "blocked" || resolution.outcomeValue === null) {
    return {
      result: "insufficient_sources",
      answer:
        "Je ne peux pas déterminer ce droit de manière suffisamment fiable à partir des informations disponibles.",
      needs_human_review: true,
    };
  }
  const age = resolution.facts.age_years;
  const prefix = typeof age !== "number"
    ? `Tu as droit à ${resolution.outcomeValue} jours de vacances.`
    : `À ${age} ans, tu as droit à ${resolution.outcomeValue} jours de vacances.`;
  const conditional = resolution.conditionalOutcomes.map((outcome) =>
    `Si ${requirementsText(outcome.requirementGroups)}, tu as droit à ${outcome.outcomeValue} jours.`
  );
  return {
    result: "supported",
    answer: [prefix, ...conditional].join(" "),
    needs_human_review: false,
  };
}

// ---------------------------------------------------------------------------
// Gabarit : congé exceptionnel à durée fixe selon motif (RAG-10.6b)
// ---------------------------------------------------------------------------

const EXCEPTIONAL_LEAVE_TOPIC_PATTERN =
  /\bconges?\s+(?:exceptionnels?|extraordinaires?)\b/;
const MARRIAGE_KEYWORDS_PATTERN =
  /\b(?:me\s+marie|se\s+marie|mariage|partenariat\s+enregistre)\b/;
const DEATH_FIRST_DEGREE_KEYWORDS_PATTERN =
  /\b(?:(?<!beau-)(?<!grand-)pere|(?<!belle-)(?<!grand-)mere|conjoint|conjointe|epoux|epouse|(?<!petit-)fils|(?<!petite-)fille|mon\s+enfant)\b/;
const DEATH_SECOND_DEGREE_KEYWORDS_PATTERN =
  /\b(?:frere|soeur|grand-pere|grand-mere|grands-parents|beau-frere|belle-soeur|beau-pere|belle-mere|petit-fils|petite-fille|petits-enfants)\b/;
const DEATH_KEYWORDS_PATTERN = /\b(?:deces|decede|decedee|mort|morte)\b/;
const MOVING_KEYWORDS_PATTERN = /\b(?:demenage|demenagement|demenager)\b/;

export function questionTargetsExceptionalLeave(question: string): boolean {
  const text = normalize(question);
  if (EXCEPTIONAL_LEAVE_TOPIC_PATTERN.test(text)) return true;
  if (MARRIAGE_KEYWORDS_PATTERN.test(text)) return true;
  if (MOVING_KEYWORDS_PATTERN.test(text)) return true;
  // Un décès n'appartient à ce gabarit que si un lien de parenté précis est
  // mentionné : "décès de ma mère" doit être reconnu, "décès de mon proche"
  // seul doit rester ambigu et passer par la clarification neutre déjà
  // établie pour les congés en général, pas par ce gabarit.
  if (
    DEATH_KEYWORDS_PATTERN.test(text) &&
    (DEATH_FIRST_DEGREE_KEYWORDS_PATTERN.test(text) ||
      DEATH_SECOND_DEGREE_KEYWORDS_PATTERN.test(text))
  ) {
    return true;
  }
  return false;
}

function exceptionalLeaveIntent(question: string): number {
  return questionTargetsExceptionalLeave(question) ? 1 : 0;
}

function extractLeaveReason(
  question: string,
  fact: TemplateFact,
): ExtractedFact {
  const text = normalize(question);
  const matches: string[] = [];
  if (MARRIAGE_KEYWORDS_PATTERN.test(text)) matches.push("marriage");
  if (
    DEATH_KEYWORDS_PATTERN.test(text) &&
    DEATH_FIRST_DEGREE_KEYWORDS_PATTERN.test(text)
  ) {
    matches.push("death_first_degree");
  }
  if (
    DEATH_KEYWORDS_PATTERN.test(text) &&
    DEATH_SECOND_DEGREE_KEYWORDS_PATTERN.test(text)
  ) {
    matches.push("death_second_degree");
  }
  if (MOVING_KEYWORDS_PATTERN.test(text)) matches.push("moving");

  const unique = [...new Set(matches)];
  const knownValues = new Set(fact.categoryValues.map((v) => v.valueKey));
  const valid = unique.filter((value) => knownValues.has(value));

  if (valid.length > 1) {
    return {
      status: "conflicting",
      value: null,
      errors: [`conflicting_${fact.factKey}`],
    };
  }
  return {
    status: "ok",
    value: valid.length === 1 ? valid[0] : null,
    errors: [],
  };
}

const EXCEPTIONAL_LEAVE_LABELS_FR: Readonly<Record<string, string>> = {
  marriage: "un mariage ou un partenariat enregistré",
  death_first_degree: "le décès d'un parent au premier degré",
  death_second_degree: "le décès d'un parent au deuxième degré",
  moving: "un déménagement",
};

function renderExceptionalLeave(
  resolution: DeterministicResolution,
  template: RuleTemplate,
): PublicDeterministicAnswer {
  if (resolution.status === "needs_clarification") {
    return {
      result: "needs_clarification",
      answer: template.clarificationMessageFr,
      needs_human_review: false,
    };
  }
  if (resolution.status === "blocked" || resolution.outcomeValue === null) {
    return {
      result: "insufficient_sources",
      answer:
        "Je ne peux pas déterminer ce droit de manière suffisamment fiable à partir des informations disponibles.",
      needs_human_review: true,
    };
  }
  // Le motif n'a pas été reconnu : la règle par défaut (déménagement) est
  // toujours vraie par construction, mais il serait trompeur d'affirmer un
  // droit à 1 jour sans savoir de quoi il s'agit réellement. On demande le
  // motif plutôt que d'énoncer la valeur plancher comme si elle répondait
  // à la question.
  if (typeof resolution.facts.leave_reason !== "string") {
    return {
      result: "needs_clarification",
      answer: template.clarificationMessageFr,
      needs_human_review: false,
    };
  }
  const label = EXCEPTIONAL_LEAVE_LABELS_FR[resolution.facts.leave_reason] ??
    "ce motif";
  const prefix =
    `Pour ${label}, tu as droit à ${resolution.outcomeValue} jour${
      resolution.outcomeValue > 1 ? "s" : ""
    }.`;
  return {
    result: "supported",
    answer: prefix,
    needs_human_review: false,
  };
}



const INTENT_DETECTORS: Readonly<Record<string, IntentDetector>> = {
  annual_leave_intent_v1: annualLeaveIntent,
  exceptional_leave_intent_v1: exceptionalLeaveIntent,
};

const FACT_EXTRACTORS: Readonly<Record<string, FactExtractor>> = {
  age_years_fr_v1: extractAgeYears,
  service_years_fr_v1: extractServiceYears,
  leave_reason_fr_v1: extractLeaveReason,
};

const RENDERERS: Readonly<Record<string, Renderer>> = {
  annual_leave_answer_fr_v1: renderAnnualLeave,
  exceptional_leave_answer_fr_v1: renderExceptionalLeave,
};

const AGGREGATION_STRATEGIES = new Set([
  "maximum_applicable_entitlement",
]);

const CODE_RUNTIME_REGISTRY_KEYS = [
  ...Object.keys(INTENT_DETECTORS).map((runtimeKey) => ({
    keyType: "intent_detector",
    runtimeKey,
  })),
  ...Object.keys(FACT_EXTRACTORS).map((runtimeKey) => ({
    keyType: "fact_extractor",
    runtimeKey,
  })),
  ...Object.keys(RENDERERS).map((runtimeKey) => ({
    keyType: "renderer",
    runtimeKey,
  })),
  ...[...AGGREGATION_STRATEGIES].map((runtimeKey) => ({
    keyType: "aggregation_strategy",
    runtimeKey,
  })),
].sort((left, right) =>
  `${left.keyType}:${left.runtimeKey}`.localeCompare(
    `${right.keyType}:${right.runtimeKey}`,
  )
);

export const RUNTIME_REGISTRY_KEYS = Object.freeze(
  runtimeRegistryManifest.map((entry) => ({ ...entry })),
);

export function runtimeRegistryImplementationMismatch(): string | null {
  const manifest = RUNTIME_REGISTRY_KEYS
    .map((entry) => `${entry.keyType}:${entry.runtimeKey}`)
    .sort();
  const code = CODE_RUNTIME_REGISTRY_KEYS
    .map((entry) => `${entry.keyType}:${entry.runtimeKey}`)
    .sort();
  if (manifest.length !== code.length) return "registry_key_count";
  for (let index = 0; index < manifest.length; index += 1) {
    if (manifest[index] !== code[index]) {
      return `${manifest[index] ?? "missing"}!=${code[index] ?? "missing"}`;
    }
  }
  return null;
}

export function runtimeRegistryMismatch(
  template: RuleTemplate,
): string | null {
  const implementationMismatch = runtimeRegistryImplementationMismatch();
  if (implementationMismatch !== null) return implementationMismatch;
  if (!(template.intentDetectorKey in INTENT_DETECTORS)) {
    return template.intentDetectorKey;
  }
  if (!(template.rendererKey in RENDERERS)) return template.rendererKey;
  if (!AGGREGATION_STRATEGIES.has(template.aggregationStrategy)) {
    return template.aggregationStrategy;
  }
  for (const fact of template.facts) {
    if (!(fact.extractorKey in FACT_EXTRACTORS)) return fact.extractorKey;
  }
  return null;
}

const TEMPLATE_INTENT_DETECTORS: ReadonlyArray<
  { templateKey: string; detectorKey: string }
> = [
  { templateKey: "annual_leave_days", detectorKey: "annual_leave_intent_v1" },
  {
    templateKey: "fixed_duration_exceptional_leave_by_event",
    detectorKey: "exceptional_leave_intent_v1",
  },
];

export function detectTemplateIntent(question: string): TemplateIntent | null {
  const candidates: TemplateIntent[] = [];
  for (const { templateKey, detectorKey } of TEMPLATE_INTENT_DETECTORS) {
    const detector = INTENT_DETECTORS[detectorKey];
    if (!detector) continue;
    const confidence = detector(question);
    if (confidence > 0) candidates.push({ templateKey, confidence });
  }
  if (candidates.length === 0) return null;
  const maxConfidence = Math.max(...candidates.map((c) => c.confidence));
  const best = candidates.filter((c) => c.confidence === maxConfidence);
  // Une égalité stricte entre deux gabarits ne doit jamais être tranchée au
  // hasard : on ne retient aucun des deux plutôt que de choisir arbitrairement.
  return best.length === 1 ? best[0] : null;
}

export function extractFacts(
  question: string,
  template: RuleTemplate,
): FactExtraction {
  const facts: ExtractedFacts = {};
  const errors: string[] = [];
  let status: FactExtraction["status"] = "ok";
  for (const fact of template.facts) {
    const extractor = FACT_EXTRACTORS[fact.extractorKey];
    if (!extractor) {
      return {
        status: "invalid",
        facts: {},
        errors: [`unknown_extractor_${fact.extractorKey}`],
      };
    }
    const extracted = extractor(question, fact);
    facts[fact.factKey] = extracted.value;
    errors.push(...extracted.errors);
    if (extracted.status === "invalid") status = "invalid";
    else if (extracted.status === "conflicting" && status === "ok") {
      status = "conflicting";
    }
  }
  return { status, facts, errors };
}

export function renderResolution(
  resolution: DeterministicResolution,
  template: RuleTemplate,
): PublicDeterministicAnswer | null {
  const renderer = RENDERERS[template.rendererKey];
  return renderer ? renderer(resolution, template) : null;
}

export function requiresDeterministicHandling(
  question: string,
  generatedAnswer = "",
  passagesLinkedToRules = false,
  modelSignalledStructuredDomain = false,
): boolean {
  if (passagesLinkedToRules || modelSignalledStructuredDomain) return true;
  const questionText = normalize(question);
  const answerText = normalize(generatedAnswer);
  const questionSignal =
    /\b(combien|calcul|seuil|minimum|maximum|a partir de|plus de|moins de)\b/.test(
      questionText,
    ) ||
    /\b(age|anciennete|ans? de service|jours?|semaines?|mois|montant|pourcentage|salaire|vacances?)\b/.test(
      questionText,
    ) ||
    /-?\d+(?:[.,]\d+)?/.test(questionText);
  const answerSignal =
    /-?\d+(?:[.,]\d+)?\s*(?:jours?|ans?|semaines?|mois|%|chf|francs?)\b/.test(
      answerText,
    ) ||
    FRENCH_NUMBER_WITH_UNIT_PATTERN.test(answerText);
  return questionSignal || answerSignal;
}
