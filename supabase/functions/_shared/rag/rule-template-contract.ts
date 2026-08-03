export type FactValueType = "number" | "category";
export type Comparator = "=" | "!=" | "<" | "<=" | ">" | ">=";
export type FactValue = number | string | null;

export interface TemplateCategoryValue {
  valueKey: string;
  labelFr: string;
}

export interface TemplateFact {
  factKey: string;
  valueType: FactValueType;
  extractorKey: string;
  labelFr: string;
  clarificationLabelFr: string;
  minimumNumber: number | null;
  maximumNumber: number | null;
  integerOnly: boolean;
  allowedOperators: Comparator[];
  categoryValues: TemplateCategoryValue[];
}

export interface TemplateFactConstraint {
  constraintKey: string;
  leftFactKey: string;
  comparator: Comparator;
  rightFactKey: string;
  errorCode: string;
}

export interface RuleTemplate {
  templateVersionId: string;
  templateKey: string;
  versionNumber: number;
  resultValueType: "number";
  resultIntegerOnly: boolean;
  resultMinimumNumber: number | null;
  resultMaximumNumber: number | null;
  resultUnit: string;
  aggregationStrategy: string;
  intentDetectorKey: string;
  rendererKey: string;
  clarificationMessageFr: string;
  facts: TemplateFact[];
  factConstraints: TemplateFactConstraint[];
}

export interface RuleCondition {
  factKey: string;
  factValueType: FactValueType;
  comparator: Comparator;
  numberValue: number | null;
  categoryValue: string | null;
}

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
  templateVersionId: string;
  aggregationStrategy: string;
  resultUnit: string;
  documentId: string;
  status: "validated";
  documentStatus: "active";
  template: RuleTemplate;
  rules: NumericRule[];
}

export interface ProtectedPassage {
  passageId: string;
  resultUnit: string;
}

export interface RuleContext {
  ruleSets: ValidatedRuleSet[];
  protectedPassages: ProtectedPassage[];
}

const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KEY_PATTERN = /^[a-z][a-z0-9_]{2,99}$/;
const COMPARATORS = new Set<Comparator>(["=", "!=", "<", "<=", ">", ">="]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_PATTERN.test(value);
}

function isKey(value: unknown): value is string {
  return typeof value === "string" && KEY_PATTERN.test(value);
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function nullableNumber(value: unknown): number | null | undefined {
  if (value === null) return null;
  const parsed = finiteNumber(value);
  return parsed === null ? undefined : parsed;
}

function parseComparator(value: unknown): Comparator | null {
  return typeof value === "string" && COMPARATORS.has(value as Comparator)
    ? value as Comparator
    : null;
}

function parseCategoryValue(value: unknown): TemplateCategoryValue | null {
  if (!isRecord(value) || !isKey(value.value_key)) return null;
  if (
    typeof value.label_fr !== "string" ||
    value.label_fr.length < 1 ||
    value.label_fr.length > 200
  ) return null;
  return { valueKey: value.value_key, labelFr: value.label_fr };
}

function parseTemplateFact(value: unknown): TemplateFact | null {
  if (!isRecord(value)) return null;
  const valueType = value.value_type;
  const minimumNumber = nullableNumber(value.minimum_number);
  const maximumNumber = nullableNumber(value.maximum_number);
  if (
    !isKey(value.fact_key) ||
    (valueType !== "number" && valueType !== "category") ||
    !isKey(value.extractor_key) ||
    typeof value.label_fr !== "string" ||
    typeof value.clarification_label_fr !== "string" ||
    minimumNumber === undefined ||
    maximumNumber === undefined ||
    typeof value.integer_only !== "boolean" ||
    !Array.isArray(value.allowed_operators) ||
    value.allowed_operators.length < 1 ||
    value.allowed_operators.length > 6 ||
    !Array.isArray(value.category_values) ||
    value.category_values.length > 100
  ) return null;

  const operators = value.allowed_operators.map(parseComparator);
  const categories = value.category_values.map(parseCategoryValue);
  if (
    operators.some((operator) => operator === null) ||
    categories.some((category) => category === null)
  ) return null;

  const uniqueOperators = [...new Set(operators as Comparator[])];
  const typedCategories = categories as TemplateCategoryValue[];
  if (
    uniqueOperators.length !== operators.length ||
    new Set(typedCategories.map((category) => category.valueKey)).size !==
      typedCategories.length
  ) return null;

  if (
    valueType === "number" &&
    minimumNumber !== null &&
    maximumNumber !== null &&
    minimumNumber > maximumNumber
  ) return null;
  if (
    valueType === "category" &&
    (
      minimumNumber !== null ||
      maximumNumber !== null ||
      value.integer_only ||
      typedCategories.length === 0
    )
  ) return null;

  return {
    factKey: value.fact_key,
    valueType,
    extractorKey: value.extractor_key,
    labelFr: value.label_fr,
    clarificationLabelFr: value.clarification_label_fr,
    minimumNumber,
    maximumNumber,
    integerOnly: value.integer_only,
    allowedOperators: uniqueOperators,
    categoryValues: typedCategories,
  };
}

function parseFactConstraint(value: unknown): TemplateFactConstraint | null {
  if (!isRecord(value)) return null;
  const comparator = parseComparator(value.comparator);
  if (
    !isKey(value.constraint_key) ||
    !isKey(value.left_fact_key) ||
    !isKey(value.right_fact_key) ||
    comparator === null ||
    !isKey(value.error_code) ||
    value.left_fact_key === value.right_fact_key
  ) return null;
  return {
    constraintKey: value.constraint_key,
    leftFactKey: value.left_fact_key,
    comparator,
    rightFactKey: value.right_fact_key,
    errorCode: value.error_code,
  };
}

function parseTemplate(value: unknown): RuleTemplate | null {
  if (!isRecord(value)) return null;
  const resultMinimumNumber = nullableNumber(value.result_minimum_number);
  const resultMaximumNumber = nullableNumber(value.result_maximum_number);
  if (
    !isUuid(value.template_version_id) ||
    !isKey(value.template_key) ||
    !Number.isSafeInteger(value.version_number) ||
    (value.version_number as number) < 1 ||
    value.result_value_type !== "number" ||
    typeof value.result_integer_only !== "boolean" ||
    resultMinimumNumber === undefined ||
    resultMaximumNumber === undefined ||
    !isKey(value.result_unit) ||
    !isKey(value.aggregation_strategy) ||
    !isKey(value.intent_detector_key) ||
    !isKey(value.renderer_key) ||
    typeof value.clarification_message_fr !== "string" ||
    value.clarification_message_fr.length < 1 ||
    value.clarification_message_fr.length > 1000 ||
    !Array.isArray(value.facts) ||
    value.facts.length < 1 ||
    value.facts.length > 50 ||
    !Array.isArray(value.fact_constraints) ||
    value.fact_constraints.length > 50
  ) return null;
  if (
    resultMinimumNumber !== null &&
    resultMaximumNumber !== null &&
    resultMinimumNumber > resultMaximumNumber
  ) return null;

  const facts = value.facts.map(parseTemplateFact);
  const constraints = value.fact_constraints.map(parseFactConstraint);
  if (
    facts.some((fact) => fact === null) ||
    constraints.some((constraint) => constraint === null)
  ) return null;
  const typedFacts = facts as TemplateFact[];
  const factKeys = new Set(typedFacts.map((fact) => fact.factKey));
  if (factKeys.size !== typedFacts.length) return null;
  if (
    (constraints as TemplateFactConstraint[]).some((constraint) =>
      !factKeys.has(constraint.leftFactKey) ||
      !factKeys.has(constraint.rightFactKey)
    )
  ) return null;

  return {
    templateVersionId: value.template_version_id,
    templateKey: value.template_key,
    versionNumber: value.version_number as number,
    resultValueType: "number",
    resultIntegerOnly: value.result_integer_only,
    resultMinimumNumber,
    resultMaximumNumber,
    resultUnit: value.result_unit,
    aggregationStrategy: value.aggregation_strategy,
    intentDetectorKey: value.intent_detector_key,
    rendererKey: value.renderer_key,
    clarificationMessageFr: value.clarification_message_fr,
    facts: typedFacts,
    factConstraints: constraints as TemplateFactConstraint[],
  };
}

function parseCondition(value: unknown): RuleCondition | null {
  if (!isRecord(value) || !isKey(value.fact_key)) return null;
  const comparator = parseComparator(value.comparator);
  const factValueType = value.fact_value_type;
  const numberValue = nullableNumber(value.number_value);
  const categoryValue = value.category_value;
  if (
    comparator === null ||
    (factValueType !== "number" && factValueType !== "category") ||
    numberValue === undefined ||
    (categoryValue !== null && !isKey(categoryValue))
  ) return null;
  if (
    (factValueType === "number" &&
      (numberValue === null || categoryValue !== null)) ||
    (factValueType === "category" &&
      (numberValue !== null || !isKey(categoryValue)))
  ) return null;
  return {
    factKey: value.fact_key,
    factValueType,
    comparator,
    numberValue,
    categoryValue: categoryValue as string | null,
  };
}

function parseConditionGroup(value: unknown): RuleConditionGroup | null {
  if (!isRecord(value) || !Array.isArray(value.conditions)) return null;
  if (value.conditions.length < 1 || value.conditions.length > 20) return null;
  const conditions = value.conditions.map(parseCondition);
  return conditions.some((condition) => condition === null)
    ? null
    : { conditions: conditions as RuleCondition[] };
}

function parseRule(value: unknown): NumericRule | null {
  if (!isRecord(value)) return null;
  const outcomeValue = finiteNumber(value.outcome_value);
  if (
    !isUuid(value.rule_id) ||
    outcomeValue === null ||
    typeof value.is_default !== "boolean" ||
    typeof value.label !== "string" ||
    value.label.length < 1 ||
    value.label.length > 500 ||
    !Array.isArray(value.condition_groups) ||
    value.condition_groups.length > 20 ||
    !Array.isArray(value.source_passage_ids) ||
    value.source_passage_ids.length < 1 ||
    value.source_passage_ids.length > 20 ||
    !value.source_passage_ids.every(isUuid)
  ) return null;
  const groups = value.condition_groups.map(parseConditionGroup);
  if (groups.some((group) => group === null)) return null;
  return {
    ruleId: value.rule_id,
    outcomeValue,
    isDefault: value.is_default,
    label: value.label,
    conditionGroups: groups as RuleConditionGroup[],
    sourcePassageIds: [
      ...new Set(value.source_passage_ids as string[]),
    ],
  };
}

function parseRuleSet(value: unknown): ValidatedRuleSet | null {
  if (!isRecord(value)) return null;
  const template = parseTemplate(value.template);
  if (
    !isUuid(value.rule_set_id) ||
    !isKey(value.rule_key) ||
    !isUuid(value.template_version_id) ||
    !isKey(value.aggregation_strategy) ||
    !isKey(value.result_unit) ||
    !isUuid(value.document_id) ||
    template === null ||
    !Array.isArray(value.rules) ||
    value.rules.length < 1 ||
    value.rules.length > 100
  ) return null;
  if (
    value.rule_key !== template.templateKey ||
    value.template_version_id !== template.templateVersionId ||
    value.aggregation_strategy !== template.aggregationStrategy ||
    value.result_unit !== template.resultUnit
  ) return null;
  const rules = value.rules.map(parseRule);
  if (rules.some((rule) => rule === null)) return null;
  return {
    ruleSetId: value.rule_set_id,
    ruleKey: value.rule_key,
    templateVersionId: value.template_version_id,
    aggregationStrategy: value.aggregation_strategy,
    resultUnit: value.result_unit,
    documentId: value.document_id,
    status: "validated",
    documentStatus: "active",
    template,
    rules: rules as NumericRule[],
  };
}

function parseProtectedPassage(value: unknown): ProtectedPassage | null {
  if (!isRecord(value)) return null;
  const passageId = value.passage_id;
  const resultUnit = value.result_unit;
  if (!isUuid(passageId) || !isKey(resultUnit)) return null;
  return { passageId, resultUnit };
}

export function parseRuleContext(
  ruleSetsValue: unknown,
  protectedPassagesValue: unknown,
): RuleContext | null {
  if (
    !Array.isArray(ruleSetsValue) ||
    ruleSetsValue.length > 20 ||
    !Array.isArray(protectedPassagesValue) ||
    protectedPassagesValue.length > 40
  ) return null;
  const ruleSets = ruleSetsValue.map(parseRuleSet);
  if (ruleSets.some((ruleSet) => ruleSet === null)) return null;
  const protectedPassages = protectedPassagesValue.map(
    parseProtectedPassage,
  );
  if (protectedPassages.some((entry) => entry === null)) return null;
  const seen = new Set<string>();
  const dedupedProtectedPassages: ProtectedPassage[] = [];
  for (const entry of protectedPassages as ProtectedPassage[]) {
    const key = `${entry.passageId}|${entry.resultUnit}`;
    if (seen.has(key)) continue;
    seen.add(key);
    dedupedProtectedPassages.push(entry);
  }
  return {
    ruleSets: ruleSets as ValidatedRuleSet[],
    protectedPassages: dedupedProtectedPassages,
  };
}
