export type FactKey = "age_years" | "service_years";
export type Comparator = ">=" | ">" | "<=" | "<" | "=";

export interface QuestionFacts {
  ageYears: number | null;
  serviceYears: number | null;
}

export interface RuleCondition {
  factKey: FactKey;
  comparator: Comparator;
  thresholdValue: number;
}

/*
  Les groupes sont combinés avec OR.
  Les conditions d'un groupe sont combinées avec AND.
*/
export interface RuleConditionGroup {
  conditions: RuleCondition[];
}

export interface NumericRule {
  ruleId: string;
  outcomeValue: number;
  isDefault: boolean;
  label: string;
  conditionGroups: RuleConditionGroup[];
  sourcePassageIds: string[];
}

export interface ValidatedRuleSet {
  ruleSetId: string;
  ruleKey: string;
  aggregationStrategy: "maximum_applicable_entitlement";
  resultUnit: "days";
  status: "validated" | "draft" | "invalidated";
  documentStatus: "active" | "ready" | "obsolete" | "error";
  rules: NumericRule[];
}

export interface FactExtraction {
  status: "ok" | "invalid" | "conflicting";
  facts: QuestionFacts;
  errors: string[];
}

export interface ConditionalOutcome {
  outcomeValue: number;
  /*
    Au moins un groupe suffit. Toutes les conditions d'un groupe sont requises.
  */
  requirementGroups: RuleCondition[][];
}

export interface DeterministicResolution {
  status: "resolved" | "conditional" | "needs_clarification" | "blocked";
  outcomeValue: number | null;
  conditionalOutcomes: ConditionalOutcome[];
  sourcePassageIds: string[];
  facts: QuestionFacts;
  reason: string | null;
}

export interface PublicDeterministicAnswer {
  result: "supported" | "needs_clarification" | "insufficient_sources";
  answer: string;
  needs_human_review: boolean;
}

export interface DeterministicEvaluation {
  answer: PublicDeterministicAnswer;
  sourcePassageIds: string[];
  errorCode: string | null;
}

type TriState = "true" | "false" | "unknown";

const AGE_MIN = 14;
const AGE_MAX = 100;
const SERVICE_MIN = 0;
const SERVICE_MAX = 80;
const RULE_KEY_PATTERN = /^[a-z][a-z0-9_]{2,99}$/;
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
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

function questionTargetsAnnualLeave(question: string): boolean {
  const text = normalize(question);
  const explicitlyDifferentLeave =
    /\bconges?\s+(?:(?:de|pour)\s+)?(?:maladie|maternite|paternite|parental(?:e|es|s|aux)?|sans\s+solde)\b/
      .test(text);
  if (explicitlyDifferentLeave) return false;

  return /\b(?:vacances?|conges?\s+(?:annuels?|payes?)|jours?\s+de\s+conges?)\b/
    .test(text);
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

function parseFactValues(
  rawValues: string[],
  minimum: number,
  maximum: number,
  factName: string,
): { value: number | null; invalid: string[]; conflicting: boolean } {
  const invalid: string[] = [];
  const values = new Set<number>();

  for (const raw of rawValues) {
    if (!/^\d+$/.test(raw)) {
      invalid.push(`${factName}_not_integer`);
      continue;
    }
    const parsed = Number(raw);
    if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
      invalid.push(`${factName}_out_of_range`);
      continue;
    }
    values.add(parsed);
  }

  return {
    value: values.size === 1 ? [...values][0] : null,
    invalid,
    conflicting: values.size > 1,
  };
}

export function extractQuestionFacts(question: string): FactExtraction {
  const text = normalize(question);

  const serviceValues = collectNumbers(text, [
    /\b(-?\d+(?:[.,]\d+)?)\s*ans?\s+(?:de\s+service|d[' ]anciennet[eé])\b/g,
    /\b(?:anciennet[eé]|service)\s*(?:de|:|est\s+de)?\s*(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
    /\b(?:compte|ayant|avec)\s+(-?\d+(?:[.,]\d+)?)\s*ans?\s+(?:de\s+service|d[' ]anciennet[eé])\b/g,
  ]);

  const ageValues = collectNumbers(text, [
    /\bj[' ]?ai\s+(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
    /\ba\s+(-?\d+(?:[.,]\d+)?)\s*ans?\b(?!\s+(?:de\s+service|d[' ]anciennet[eé]))/g,
    /\b(?:âge|age)\s*(?:de|:|est\s+de)?\s*(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
    /\bâg[eé](?:e)?\s+de\s+(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
    /\bemploy[eé](?:e)?\s+de\s+(-?\d+(?:[.,]\d+)?)\s*ans?\b/g,
    /\b(-?\d+(?:[.,]\d+)?)\s*ans?\s+d[' ]âge\b/g,
  ]);

  const age = parseFactValues(ageValues, AGE_MIN, AGE_MAX, "age");
  const service = parseFactValues(
    serviceValues,
    SERVICE_MIN,
    SERVICE_MAX,
    "service",
  );
  const errors = [...age.invalid, ...service.invalid];

  if (errors.length > 0) {
    return {
      status: "invalid",
      facts: { ageYears: null, serviceYears: null },
      errors,
    };
  }
  if (age.conflicting || service.conflicting) {
    return {
      status: "conflicting",
      facts: { ageYears: age.value, serviceYears: service.value },
      errors: [
        ...(age.conflicting ? ["conflicting_age"] : []),
        ...(service.conflicting ? ["conflicting_service"] : []),
      ],
    };
  }

  return {
    status: "ok",
    facts: {
      ageYears: age.value,
      serviceYears: service.value,
    },
    errors: [],
  };
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
    /\b(combien|calcul|seuil|minimum|maximum|dès|à partir de|plus de|moins de)\b/.test(
      questionText,
    ) ||
    /\b(âge|age|anciennet[eé]|ans? de service|jours?|semaines?|mois|montant|pourcentage|salaire|vacances?)\b/.test(
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

function factValue(facts: QuestionFacts, factKey: FactKey): number | null {
  return factKey === "age_years" ? facts.ageYears : facts.serviceYears;
}

function compare(
  value: number,
  comparator: Comparator,
  threshold: number,
): boolean {
  switch (comparator) {
    case ">=":
      return value >= threshold;
    case ">":
      return value > threshold;
    case "<=":
      return value <= threshold;
    case "<":
      return value < threshold;
    case "=":
      return value === threshold;
  }
}

function evaluateCondition(
  condition: RuleCondition,
  facts: QuestionFacts,
): TriState {
  const value = factValue(facts, condition.factKey);
  if (value === null) {
    if (
      condition.factKey === "service_years" &&
      facts.ageYears !== null &&
      ((condition.comparator === ">=" &&
        condition.thresholdValue > facts.ageYears) ||
        (condition.comparator === ">" &&
          condition.thresholdValue >= facts.ageYears))
    ) {
      return "false";
    }
    return "unknown";
  }
  return compare(value, condition.comparator, condition.thresholdValue)
    ? "true"
    : "false";
}

function evaluateGroup(
  group: RuleConditionGroup,
  facts: QuestionFacts,
): TriState {
  let hasUnknown = false;
  for (const condition of group.conditions) {
    const result = evaluateCondition(condition, facts);
    if (result === "false") return "false";
    if (result === "unknown") hasUnknown = true;
  }
  return hasUnknown ? "unknown" : "true";
}

function evaluateRule(rule: NumericRule, facts: QuestionFacts): TriState {
  if (rule.isDefault) return "true";

  let hasUnknown = false;
  for (const group of rule.conditionGroups) {
    const result = evaluateGroup(group, facts);
    if (result === "true") return "true";
    if (result === "unknown") hasUnknown = true;
  }
  return hasUnknown ? "unknown" : "false";
}

function validateCondition(condition: RuleCondition): boolean {
  return (
    (condition.factKey === "age_years" ||
      condition.factKey === "service_years") &&
    [">=", ">", "<=", "<", "="].includes(condition.comparator) &&
    Number.isSafeInteger(condition.thresholdValue) &&
    condition.thresholdValue >= 0 &&
    condition.thresholdValue <= 150
  );
}

export function validateRuleSet(ruleSet: ValidatedRuleSet): string | null {
  if (ruleSet.status !== "validated" || ruleSet.documentStatus !== "active") {
    return "rule_set_not_active";
  }
  if (
    ruleSet.aggregationStrategy !== "maximum_applicable_entitlement" ||
    ruleSet.resultUnit !== "days" ||
    ruleSet.rules.length === 0
  ) {
    return "unsupported_rule_set";
  }

  const defaults = ruleSet.rules.filter((rule) => rule.isDefault);
  if (defaults.length !== 1) return "invalid_default_rule_count";

  for (const rule of ruleSet.rules) {
    if (
      !Number.isSafeInteger(rule.outcomeValue) ||
      rule.outcomeValue < 0 ||
      rule.sourcePassageIds.length === 0
    ) {
      return "invalid_rule";
    }
    if (rule.isDefault && rule.conditionGroups.length !== 0) {
      return "default_rule_has_conditions";
    }
    if (!rule.isDefault && rule.conditionGroups.length === 0) {
      return "conditional_rule_without_group";
    }
    for (const group of rule.conditionGroups) {
      if (
        group.conditions.length === 0 ||
        !group.conditions.every(validateCondition)
      ) {
        return "invalid_condition_group";
      }
    }
  }

  return null;
}

function unknownRequirements(
  rule: NumericRule,
  facts: QuestionFacts,
): RuleCondition[][] {
  const groups: RuleCondition[][] = [];
  for (const group of rule.conditionGroups) {
    if (evaluateGroup(group, facts) !== "unknown") continue;

    const unknownConditions: RuleCondition[] = [];
    let possible = true;
    for (const condition of group.conditions) {
      const result = evaluateCondition(condition, facts);
      if (result === "false") {
        possible = false;
        break;
      }
      if (result === "unknown") unknownConditions.push(condition);
    }
    if (possible && unknownConditions.length > 0) {
      groups.push(unknownConditions);
    }
  }
  return groups;
}

function uniqueStrings(values: string[]): string[] {
  return [...new Set(values)];
}

export function resolveValidatedRuleSet(
  ruleSet: ValidatedRuleSet,
  extraction: FactExtraction,
): DeterministicResolution {
  const invalidRuleSet = validateRuleSet(ruleSet);
  if (invalidRuleSet !== null) {
    return {
      status: "blocked",
      outcomeValue: null,
      conditionalOutcomes: [],
      sourcePassageIds: [],
      facts: extraction.facts,
      reason: invalidRuleSet,
    };
  }
  if (extraction.status !== "ok") {
    return {
      status: "needs_clarification",
      outcomeValue: null,
      conditionalOutcomes: [],
      sourcePassageIds: [],
      facts: extraction.facts,
      reason:
        extraction.status === "invalid"
          ? "invalid_question_facts"
          : "conflicting_question_facts",
    };
  }
  if (
    extraction.facts.ageYears !== null &&
    extraction.facts.serviceYears !== null &&
    extraction.facts.serviceYears > extraction.facts.ageYears
  ) {
    return {
      status: "needs_clarification",
      outcomeValue: null,
      conditionalOutcomes: [],
      sourcePassageIds: [],
      facts: extraction.facts,
      reason: "impossible_question_facts",
    };
  }
  if (
    extraction.facts.ageYears === null &&
    extraction.facts.serviceYears === null
  ) {
    return {
      status: "needs_clarification",
      outcomeValue: null,
      conditionalOutcomes: [],
      sourcePassageIds: [],
      facts: extraction.facts,
      reason: "missing_question_facts",
    };
  }

  const applicable = ruleSet.rules.filter(
    (rule) => evaluateRule(rule, extraction.facts) === "true",
  );
  if (applicable.length === 0) {
    return {
      status: "blocked",
      outcomeValue: null,
      conditionalOutcomes: [],
      sourcePassageIds: [],
      facts: extraction.facts,
      reason: "no_applicable_rule",
    };
  }

  const outcomeValue = Math.max(...applicable.map((rule) => rule.outcomeValue));
  const selectedRules = applicable.filter(
    (rule) => rule.outcomeValue === outcomeValue,
  );
  const conditionalOutcomes = ruleSet.rules
    .filter(
      (rule) =>
        rule.outcomeValue > outcomeValue &&
        evaluateRule(rule, extraction.facts) === "unknown",
    )
    .map((rule) => ({
      outcomeValue: rule.outcomeValue,
      requirementGroups: unknownRequirements(rule, extraction.facts),
    }))
    .filter((outcome) => outcome.requirementGroups.length > 0)
    .sort((a, b) => a.outcomeValue - b.outcomeValue);

  return {
    status: conditionalOutcomes.length > 0 ? "conditional" : "resolved",
    outcomeValue,
    conditionalOutcomes,
    sourcePassageIds: uniqueStrings(
      [
        ...selectedRules,
        ...ruleSet.rules.filter((rule) =>
          conditionalOutcomes.some(
            (outcome) => outcome.outcomeValue === rule.outcomeValue,
          ),
        ),
      ].flatMap((rule) => rule.sourcePassageIds),
    ),
    facts: extraction.facts,
    reason: null,
  };
}

function conditionText(condition: RuleCondition): string {
  const subject = condition.factKey === "age_years" ? "tu as" : "tu comptes";
  const suffix =
    condition.factKey === "age_years"
      ? "ans"
      : "ans de service dans la même institution";

  switch (condition.comparator) {
    case ">=":
      return `${subject} au moins ${condition.thresholdValue} ${suffix}`;
    case ">":
      return `${subject} plus de ${condition.thresholdValue} ${suffix}`;
    case "<=":
      return `${subject} au plus ${condition.thresholdValue} ${suffix}`;
    case "<":
      return `${subject} moins de ${condition.thresholdValue} ${suffix}`;
    case "=":
      return `${subject} exactement ${condition.thresholdValue} ${suffix}`;
  }
}

function requirementsText(groups: RuleCondition[][]): string {
  return groups
    .map((group) => group.map(conditionText).join(" et "))
    .join(" ou ");
}

export function renderAnnualLeaveAnswer(
  resolution: DeterministicResolution,
): PublicDeterministicAnswer {
  if (resolution.status === "needs_clarification") {
    return {
      result: "needs_clarification",
      answer:
        "J’ai besoin de ton âge et de ton nombre d’années de service dans la même institution pour déterminer ce droit.",
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

  const prefix =
    resolution.facts.ageYears === null
      ? `Tu as droit à ${resolution.outcomeValue} jours de vacances.`
      : `À ${resolution.facts.ageYears} ans, tu as droit à ${resolution.outcomeValue} jours de vacances.`;
  const conditional = resolution.conditionalOutcomes.map(
    (outcome) =>
      `Si ${requirementsText(outcome.requirementGroups)}, tu as droit à ${outcome.outcomeValue} jours.`,
  );

  return {
    result: "supported",
    answer: [prefix, ...conditional].join(" "),
    needs_human_review: false,
  };
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function parseCondition(value: unknown): RuleCondition | null {
  if (!isRecord(value)) return null;
  const factKey = value.fact_key;
  const comparator = value.comparator;
  const thresholdValue = value.threshold_value;
  if (
    (factKey !== "age_years" && factKey !== "service_years") ||
    (comparator !== ">=" &&
      comparator !== ">" &&
      comparator !== "<=" &&
      comparator !== "<" &&
      comparator !== "=") ||
    !Number.isSafeInteger(thresholdValue)
  ) {
    return null;
  }
  return {
    factKey,
    comparator,
    thresholdValue: thresholdValue as number,
  };
}

function parseConditionGroup(value: unknown): RuleConditionGroup | null {
  if (!isRecord(value) || !Array.isArray(value.conditions)) return null;
  if (value.conditions.length < 1 || value.conditions.length > 20) return null;
  const conditions = value.conditions.map(parseCondition);
  if (conditions.some((condition) => condition === null)) return null;
  return { conditions: conditions as RuleCondition[] };
}

function parseRule(value: unknown): NumericRule | null {
  if (!isRecord(value)) return null;
  const ruleId = value.rule_id;
  const outcomeValue = value.outcome_value;
  const isDefault = value.is_default;
  const label = value.label;
  const rawGroups = value.condition_groups;
  const rawSourceIds = value.source_passage_ids;
  if (
    !isUuid(ruleId) ||
    !Number.isSafeInteger(outcomeValue) ||
    typeof isDefault !== "boolean" ||
    typeof label !== "string" ||
    label.length < 1 ||
    label.length > 500 ||
    !Array.isArray(rawGroups) ||
    rawGroups.length > 20 ||
    !Array.isArray(rawSourceIds) ||
    rawSourceIds.length < 1 ||
    rawSourceIds.length > 20 ||
    !rawSourceIds.every(isUuid)
  ) {
    return null;
  }
  const groups = rawGroups.map(parseConditionGroup);
  if (groups.some((group) => group === null)) return null;
  return {
    ruleId,
    outcomeValue: outcomeValue as number,
    isDefault,
    label,
    conditionGroups: groups as RuleConditionGroup[],
    sourcePassageIds: uniqueStrings(rawSourceIds as string[]),
  };
}

function parseRuleSet(value: unknown): ValidatedRuleSet | null {
  if (!isRecord(value)) return null;
  const ruleSetId = value.rule_set_id;
  const ruleKey = value.rule_key;
  const aggregationStrategy = value.aggregation_strategy;
  const resultUnit = value.result_unit;
  const documentId = value.document_id;
  const rawRules = value.rules;
  if (
    !isUuid(ruleSetId) ||
    typeof ruleKey !== "string" ||
    !RULE_KEY_PATTERN.test(ruleKey) ||
    aggregationStrategy !== "maximum_applicable_entitlement" ||
    resultUnit !== "days" ||
    !isUuid(documentId) ||
    !Array.isArray(rawRules) ||
    rawRules.length < 1 ||
    rawRules.length > 100
  ) {
    return null;
  }
  const rules = rawRules.map(parseRule);
  if (rules.some((rule) => rule === null)) return null;
  const parsed: ValidatedRuleSet = {
    ruleSetId,
    ruleKey,
    aggregationStrategy,
    resultUnit,
    status: "validated",
    documentStatus: "active",
    rules: rules as NumericRule[],
  };
  return validateRuleSet(parsed) === null ? parsed : null;
}

export function parseValidatedRuleSets(value: unknown): ValidatedRuleSet[] | null {
  if (!Array.isArray(value) || value.length > 20) return null;
  const ruleSets = value.map(parseRuleSet);
  return ruleSets.some((ruleSet) => ruleSet === null)
    ? null
    : ruleSets as ValidatedRuleSet[];
}

export function evaluateValidatedRuleSets(
  question: string,
  ruleSets: ValidatedRuleSet[],
): DeterministicEvaluation | null {
  if (ruleSets.length === 0) return null;
  if (ruleSets.length !== 1) {
    return {
      answer: renderAnnualLeaveAnswer({
        status: "blocked",
        outcomeValue: null,
        conditionalOutcomes: [],
        sourcePassageIds: [],
        facts: { ageYears: null, serviceYears: null },
        reason: "ambiguous_rule_sets",
      }),
      sourcePassageIds: [],
      errorCode: "deterministic_rule_ambiguous",
    };
  }

  const ruleSet = ruleSets[0];
  if (ruleSet.ruleKey !== "annual_leave_days") {
    return {
      answer: renderAnnualLeaveAnswer({
        status: "blocked",
        outcomeValue: null,
        conditionalOutcomes: [],
        sourcePassageIds: [],
        facts: { ageYears: null, serviceYears: null },
        reason: "unsupported_rule_key",
      }),
      sourcePassageIds: [],
      errorCode: "deterministic_rule_unsupported",
    };
  }
  if (!questionTargetsAnnualLeave(question)) return null;

  const resolution = resolveValidatedRuleSet(
    ruleSet,
    extractQuestionFacts(question),
  );
  return {
    answer: renderAnnualLeaveAnswer(resolution),
    sourcePassageIds: resolution.sourcePassageIds,
    errorCode: resolution.reason === null
      ? resolution.status === "needs_clarification"
        ? "deterministic_needs_clarification"
        : null
      : `deterministic_${resolution.reason}`.slice(0, 100),
  };
}
