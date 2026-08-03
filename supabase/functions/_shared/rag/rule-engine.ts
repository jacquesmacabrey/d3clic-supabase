import type {
  Comparator,
  FactValue,
  NumericRule,
  RuleCondition,
  RuleConditionGroup,
  RuleTemplate,
  TemplateFact,
  ValidatedRuleSet,
} from "./rule-template-contract.ts";

export type TriState = "true" | "false" | "unknown";
export type ExtractedFacts = Record<string, FactValue>;

export interface FactExtraction {
  status: "ok" | "invalid" | "conflicting";
  facts: ExtractedFacts;
  errors: string[];
}

export interface ConditionalOutcome {
  outcomeValue: number;
  requirementGroups: RuleCondition[][];
}

export interface DeterministicResolution {
  status: "resolved" | "conditional" | "needs_clarification" | "blocked";
  outcomeValue: number | null;
  conditionalOutcomes: ConditionalOutcome[];
  sourcePassageIds: string[];
  facts: ExtractedFacts;
  reason: string | null;
}

function compareNumbers(
  left: number,
  comparator: Comparator,
  right: number,
): boolean {
  switch (comparator) {
    case "=":
      return left === right;
    case "!=":
      return left !== right;
    case "<":
      return left < right;
    case "<=":
      return left <= right;
    case ">":
      return left > right;
    case ">=":
      return left >= right;
  }
}

function compareCategories(
  left: string,
  comparator: Comparator,
  right: string,
): boolean {
  if (comparator === "=") return left === right;
  if (comparator === "!=") return left !== right;
  return false;
}

function templateFact(
  template: RuleTemplate,
  factKey: string,
): TemplateFact | null {
  return template.facts.find((fact) => fact.factKey === factKey) ?? null;
}

function conditionValue(condition: RuleCondition): number | string {
  return condition.factValueType === "number"
    ? condition.numberValue!
    : condition.categoryValue!;
}

function conditionImpossibleFromConstraints(
  condition: RuleCondition,
  facts: ExtractedFacts,
  template: RuleTemplate,
): boolean {
  if (
    condition.factValueType !== "number" ||
    condition.numberValue === null
  ) return false;

  for (const constraint of template.factConstraints) {
    if (
      constraint.leftFactKey !== condition.factKey ||
      (constraint.comparator !== "<" && constraint.comparator !== "<=")
    ) continue;
    const right = facts[constraint.rightFactKey];
    if (typeof right !== "number") continue;

    if (
      condition.comparator === ">=" &&
      (
        condition.numberValue > right ||
        (
          constraint.comparator === "<" &&
          condition.numberValue >= right
        )
      )
    ) return true;
    if (
      condition.comparator === ">" &&
      condition.numberValue >= right
    ) return true;
  }
  return false;
}

export function evaluateCondition(
  condition: RuleCondition,
  facts: ExtractedFacts,
  template: RuleTemplate,
): TriState {
  const fact = templateFact(template, condition.factKey);
  if (fact === null || fact.valueType !== condition.factValueType) {
    return "false";
  }
  const value = facts[condition.factKey] ?? null;
  if (value === null) {
    return conditionImpossibleFromConstraints(condition, facts, template)
      ? "false"
      : "unknown";
  }
  if (condition.factValueType === "number") {
    return typeof value === "number" &&
        compareNumbers(
          value,
          condition.comparator,
          conditionValue(condition) as number,
        )
      ? "true"
      : "false";
  }
  return typeof value === "string" &&
      compareCategories(
        value,
        condition.comparator,
        conditionValue(condition) as string,
      )
    ? "true"
    : "false";
}

export function evaluateGroup(
  group: RuleConditionGroup,
  facts: ExtractedFacts,
  template: RuleTemplate,
): TriState {
  let hasUnknown = false;
  for (const condition of group.conditions) {
    const result = evaluateCondition(condition, facts, template);
    if (result === "false") return "false";
    if (result === "unknown") hasUnknown = true;
  }
  return hasUnknown ? "unknown" : "true";
}

function evaluateRule(
  rule: NumericRule,
  facts: ExtractedFacts,
  template: RuleTemplate,
): TriState {
  if (rule.isDefault) return "true";
  let hasUnknown = false;
  for (const group of rule.conditionGroups) {
    const result = evaluateGroup(group, facts, template);
    if (result === "true") return "true";
    if (result === "unknown") hasUnknown = true;
  }
  return hasUnknown ? "unknown" : "false";
}

function validateFactValue(fact: TemplateFact, value: FactValue): boolean {
  if (value === null) return true;
  if (fact.valueType === "number") {
    return (
      typeof value === "number" &&
      Number.isFinite(value) &&
      (!fact.integerOnly || Number.isSafeInteger(value)) &&
      (fact.minimumNumber === null || value >= fact.minimumNumber) &&
      (fact.maximumNumber === null || value <= fact.maximumNumber)
    );
  }
  return (
    typeof value === "string" &&
    fact.categoryValues.some((category) => category.valueKey === value)
  );
}

function validateCondition(
  condition: RuleCondition,
  template: RuleTemplate,
): boolean {
  const fact = templateFact(template, condition.factKey);
  if (
    fact === null ||
    fact.valueType !== condition.factValueType ||
    !fact.allowedOperators.includes(condition.comparator)
  ) return false;
  if (condition.factValueType === "number") {
    return (
      condition.numberValue !== null &&
      condition.categoryValue === null &&
      validateFactValue(fact, condition.numberValue)
    );
  }
  return (
    condition.numberValue === null &&
    condition.categoryValue !== null &&
    validateFactValue(fact, condition.categoryValue)
  );
}

export function validateRuleSet(ruleSet: ValidatedRuleSet): string | null {
  const { template } = ruleSet;
  if (
    ruleSet.status !== "validated" ||
    ruleSet.documentStatus !== "active"
  ) return "rule_set_not_active";
  if (
    template.templateKey !== ruleSet.ruleKey ||
    template.templateVersionId !== ruleSet.templateVersionId ||
    template.aggregationStrategy !== ruleSet.aggregationStrategy ||
    template.resultUnit !== ruleSet.resultUnit ||
    template.resultValueType !== "number" ||
    ruleSet.rules.length === 0
  ) return "invalid_template_binding";

  const factKeys = new Set(template.facts.map((fact) => fact.factKey));
  if (factKeys.size !== template.facts.length) {
    return "duplicate_template_fact";
  }
  if (
    template.factConstraints.some((constraint) =>
      !factKeys.has(constraint.leftFactKey) ||
      !factKeys.has(constraint.rightFactKey)
    )
  ) return "invalid_fact_constraint";

  const defaults = ruleSet.rules.filter((rule) => rule.isDefault);
  if (defaults.length !== 1) return "invalid_default_rule_count";

  for (const rule of ruleSet.rules) {
    if (
      !Number.isFinite(rule.outcomeValue) ||
      (template.resultIntegerOnly &&
        !Number.isSafeInteger(rule.outcomeValue)) ||
      (
        template.resultMinimumNumber !== null &&
        rule.outcomeValue < template.resultMinimumNumber
      ) ||
      (
        template.resultMaximumNumber !== null &&
        rule.outcomeValue > template.resultMaximumNumber
      ) ||
      rule.sourcePassageIds.length === 0
    ) return "invalid_rule";
    if (rule.isDefault && rule.conditionGroups.length !== 0) {
      return "default_rule_has_conditions";
    }
    if (!rule.isDefault && rule.conditionGroups.length === 0) {
      return "conditional_rule_without_group";
    }
    for (const group of rule.conditionGroups) {
      if (
        group.conditions.length === 0 ||
        !group.conditions.every((condition) =>
          validateCondition(condition, template)
        )
      ) return "invalid_condition_group";
    }
  }
  return null;
}

function firstViolatedFactConstraint(
  template: RuleTemplate,
  facts: ExtractedFacts,
): string | null {
  for (const constraint of template.factConstraints) {
    const left = facts[constraint.leftFactKey];
    const right = facts[constraint.rightFactKey];
    if (left === null || right === null) continue;
    if (typeof left !== typeof right) return constraint.errorCode;
    const satisfied = typeof left === "number"
      ? compareNumbers(left, constraint.comparator, right as number)
      : compareCategories(
        left as string,
        constraint.comparator,
        right as string,
      );
    if (!satisfied) return constraint.errorCode;
  }
  return null;
}

function unknownRequirements(
  rule: NumericRule,
  facts: ExtractedFacts,
  template: RuleTemplate,
): RuleCondition[][] {
  const groups: RuleCondition[][] = [];
  for (const group of rule.conditionGroups) {
    if (evaluateGroup(group, facts, template) !== "unknown") continue;
    const unknownConditions: RuleCondition[] = [];
    let possible = true;
    for (const condition of group.conditions) {
      const result = evaluateCondition(condition, facts, template);
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
      reason: extraction.status === "invalid"
        ? "invalid_question_facts"
        : "conflicting_question_facts",
    };
  }
  const violatedConstraint = firstViolatedFactConstraint(
    ruleSet.template,
    extraction.facts,
  );
  if (violatedConstraint !== null) {
    return {
      status: "needs_clarification",
      outcomeValue: null,
      conditionalOutcomes: [],
      sourcePassageIds: [],
      facts: extraction.facts,
      reason: violatedConstraint,
    };
  }
  if (
    ruleSet.template.facts.every((fact) =>
      extraction.facts[fact.factKey] === null
    )
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

  const applicable = ruleSet.rules.filter((rule) =>
    evaluateRule(rule, extraction.facts, ruleSet.template) === "true"
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

  if (
    ruleSet.aggregationStrategy !== "maximum_applicable_entitlement"
  ) {
    return {
      status: "blocked",
      outcomeValue: null,
      conditionalOutcomes: [],
      sourcePassageIds: [],
      facts: extraction.facts,
      reason: "unsupported_aggregation_strategy",
    };
  }

  const outcomeValue = Math.max(...applicable.map((rule) => rule.outcomeValue));
  const selectedRules = applicable.filter((rule) =>
    rule.outcomeValue === outcomeValue
  );
  const conditionalOutcomes = ruleSet.rules
    .filter((rule) =>
      rule.outcomeValue > outcomeValue &&
      evaluateRule(rule, extraction.facts, ruleSet.template) === "unknown"
    )
    .map((rule) => ({
      outcomeValue: rule.outcomeValue,
      requirementGroups: unknownRequirements(
        rule,
        extraction.facts,
        ruleSet.template,
      ),
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
          conditionalOutcomes.some((outcome) =>
            outcome.outcomeValue === rule.outcomeValue
          )
        ),
      ].flatMap((rule) => rule.sourcePassageIds),
    ),
    facts: extraction.facts,
    reason: null,
  };
}

