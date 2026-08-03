import type {
  RuleTemplate,
  ValidatedRuleSet,
} from "../../supabase/functions/_shared/rag/rule-template-contract.ts";

export const SOURCE_A = "11111111-1111-4111-8111-111111111111";
export const TEMPLATE_VERSION =
  "f0a00000-0000-4000-8000-000000000001";

export function annualLeaveTemplate(): RuleTemplate {
  return {
    templateVersionId: TEMPLATE_VERSION,
    templateKey: "annual_leave_days",
    versionNumber: 1,
    resultValueType: "number",
    resultIntegerOnly: true,
    resultMinimumNumber: 0,
    resultMaximumNumber: 10000,
    resultUnit: "days",
    aggregationStrategy: "maximum_applicable_entitlement",
    intentDetectorKey: "annual_leave_intent_v1",
    rendererKey: "annual_leave_answer_fr_v1",
    clarificationMessageFr:
      "J’ai besoin de ton âge et de ton nombre d’années de service dans la même institution pour déterminer ce droit.",
    facts: [
      {
        factKey: "age_years",
        valueType: "number",
        extractorKey: "age_years_fr_v1",
        labelFr: "Âge",
        clarificationLabelFr: "ton âge",
        minimumNumber: 14,
        maximumNumber: 100,
        integerOnly: true,
        allowedOperators: ["<", ">="],
        categoryValues: [],
      },
      {
        factKey: "service_years",
        valueType: "number",
        extractorKey: "service_years_fr_v1",
        labelFr: "Ancienneté",
        clarificationLabelFr:
          "ton nombre d’années de service dans la même institution",
        minimumNumber: 0,
        maximumNumber: 80,
        integerOnly: true,
        allowedOperators: [">="],
        categoryValues: [],
      },
    ],
    factConstraints: [{
      constraintKey: "service_not_greater_than_age",
      leftFactKey: "service_years",
      comparator: "<=",
      rightFactKey: "age_years",
      errorCode: "impossible_question_facts",
    }],
  };
}

function numericCondition(
  factKey: "age_years" | "service_years",
  comparator: "<" | ">=",
  value: number,
) {
  return {
    factKey,
    factValueType: "number" as const,
    comparator,
    numberValue: value,
    categoryValue: null,
  };
}

export function annualLeaveRuleSet(
  sourcePassageId = SOURCE_A,
): ValidatedRuleSet {
  const template = annualLeaveTemplate();
  return {
    ruleSetId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    ruleKey: template.templateKey,
    templateVersionId: template.templateVersionId,
    aggregationStrategy: template.aggregationStrategy,
    resultUnit: template.resultUnit,
    documentId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    status: "validated",
    documentStatus: "active",
    template,
    rules: [
      {
        ruleId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        outcomeValue: 25,
        isDefault: true,
        label: "Droit de base",
        conditionGroups: [],
        sourcePassageIds: [sourcePassageId],
      },
      {
        ruleId: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        outcomeValue: 30,
        isDefault: false,
        label: "Moins de 20 ans",
        conditionGroups: [{
          conditions: [numericCondition("age_years", "<", 20)],
        }],
        sourcePassageIds: [sourcePassageId],
      },
      {
        ruleId: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        outcomeValue: 30,
        isDefault: false,
        label: "Dès 50 ans",
        conditionGroups: [{
          conditions: [numericCondition("age_years", ">=", 50)],
        }],
        sourcePassageIds: [sourcePassageId],
      },
      {
        ruleId: "ffffffff-ffff-4fff-8fff-ffffffffffff",
        outcomeValue: 30,
        isDefault: false,
        label: "Dès 15 ans de service",
        conditionGroups: [{
          conditions: [numericCondition("service_years", ">=", 15)],
        }],
        sourcePassageIds: [sourcePassageId],
      },
      {
        ruleId: "99999999-9999-4999-8999-999999999999",
        outcomeValue: 35,
        isDefault: false,
        label: "Dès 60 ans",
        conditionGroups: [{
          conditions: [numericCondition("age_years", ">=", 60)],
        }],
        sourcePassageIds: [sourcePassageId],
      },
      {
        ruleId: "88888888-8888-4888-8888-888888888888",
        outcomeValue: 35,
        isDefault: false,
        label: "Dès 25 ans de service",
        conditionGroups: [{
          conditions: [numericCondition("service_years", ">=", 25)],
        }],
        sourcePassageIds: [sourcePassageId],
      },
    ],
  };
}

export function exceptionalLeaveTemplate(): RuleTemplate {
  return {
    templateVersionId: "f0a00000-0000-4000-8000-000000000002",
    templateKey: "fixed_duration_exceptional_leave_by_event",
    versionNumber: 1,
    resultValueType: "number",
    resultIntegerOnly: true,
    resultMinimumNumber: 0,
    resultMaximumNumber: 30,
    resultUnit: "days",
    aggregationStrategy: "maximum_applicable_entitlement",
    intentDetectorKey: "exceptional_leave_intent_v1",
    rendererKey: "exceptional_leave_answer_fr_v1",
    clarificationMessageFr:
      "De quel motif de congé exceptionnel s’agit-il : mariage ou partenariat enregistré, décès d’un parent au premier degré, décès d’un parent au deuxième degré, ou déménagement ?",
    facts: [
      {
        factKey: "leave_reason",
        valueType: "category",
        extractorKey: "leave_reason_fr_v1",
        labelFr: "Motif du congé",
        clarificationLabelFr: "le motif exact de ta demande",
        minimumNumber: null,
        maximumNumber: null,
        integerOnly: false,
        allowedOperators: ["="],
        categoryValues: [
          { valueKey: "marriage", labelFr: "Mariage ou partenariat enregistré" },
          { valueKey: "death_first_degree", labelFr: "Décès, 1er degré" },
          { valueKey: "death_second_degree", labelFr: "Décès, 2e degré" },
          { valueKey: "moving", labelFr: "Déménagement" },
        ],
      },
    ],
    factConstraints: [],
  };
}

function categoryCondition(value: string) {
  return {
    factKey: "leave_reason",
    factValueType: "category" as const,
    comparator: "=" as const,
    numberValue: null,
    categoryValue: value,
  };
}

export function exceptionalLeaveRuleSet(
  sourcePassageId = SOURCE_A,
): ValidatedRuleSet {
  const template = exceptionalLeaveTemplate();
  return {
    ruleSetId: "22222222-aaaa-4aaa-8aaa-222222222222",
    ruleKey: template.templateKey,
    templateVersionId: template.templateVersionId,
    aggregationStrategy: template.aggregationStrategy,
    resultUnit: template.resultUnit,
    documentId: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    status: "validated",
    documentStatus: "active",
    template,
    rules: [
      {
        ruleId: "33333333-bbbb-4bbb-8bbb-333333333333",
        outcomeValue: 1,
        isDefault: true,
        label: "Déménagement",
        conditionGroups: [],
        sourcePassageIds: [sourcePassageId],
      },
      {
        ruleId: "44444444-cccc-4ccc-8ccc-444444444444",
        outcomeValue: 3,
        isDefault: false,
        label: "Mariage",
        conditionGroups: [{ conditions: [categoryCondition("marriage")] }],
        sourcePassageIds: [sourcePassageId],
      },
      {
        ruleId: "55555555-dddd-4ddd-8ddd-555555555555",
        outcomeValue: 2,
        isDefault: false,
        label: "Décès, 2e degré",
        conditionGroups: [{
          conditions: [categoryCondition("death_second_degree")],
        }],
        sourcePassageIds: [sourcePassageId],
      },
      {
        ruleId: "66666666-eeee-4eee-8eee-666666666666",
        outcomeValue: 5,
        isDefault: false,
        label: "Décès, 1er degré",
        conditionGroups: [{
          conditions: [categoryCondition("death_first_degree")],
        }],
        sourcePassageIds: [sourcePassageId],
      },
    ],
  };
}

export function singleDayRuleSet(
  sourcePassageId: string,
): ValidatedRuleSet {
  const ruleSet = annualLeaveRuleSet(sourcePassageId);
  return {
    ...ruleSet,
    rules: [ruleSet.rules[0]],
  };
}

export function ruleSetToRpc(ruleSet: ValidatedRuleSet): unknown {
  const template = ruleSet.template;
  return {
    rule_set_id: ruleSet.ruleSetId,
    rule_key: ruleSet.ruleKey,
    template_version_id: ruleSet.templateVersionId,
    aggregation_strategy: ruleSet.aggregationStrategy,
    result_unit: ruleSet.resultUnit,
    document_id: ruleSet.documentId,
    template: {
      template_version_id: template.templateVersionId,
      template_key: template.templateKey,
      version_number: template.versionNumber,
      result_value_type: template.resultValueType,
      result_integer_only: template.resultIntegerOnly,
      result_minimum_number: template.resultMinimumNumber,
      result_maximum_number: template.resultMaximumNumber,
      result_unit: template.resultUnit,
      aggregation_strategy: template.aggregationStrategy,
      intent_detector_key: template.intentDetectorKey,
      renderer_key: template.rendererKey,
      clarification_message_fr: template.clarificationMessageFr,
      facts: template.facts.map((fact) => ({
        fact_key: fact.factKey,
        value_type: fact.valueType,
        extractor_key: fact.extractorKey,
        label_fr: fact.labelFr,
        clarification_label_fr: fact.clarificationLabelFr,
        minimum_number: fact.minimumNumber,
        maximum_number: fact.maximumNumber,
        integer_only: fact.integerOnly,
        allowed_operators: fact.allowedOperators,
        category_values: fact.categoryValues.map((category) => ({
          value_key: category.valueKey,
          label_fr: category.labelFr,
        })),
      })),
      fact_constraints: template.factConstraints.map((constraint) => ({
        constraint_key: constraint.constraintKey,
        left_fact_key: constraint.leftFactKey,
        comparator: constraint.comparator,
        right_fact_key: constraint.rightFactKey,
        error_code: constraint.errorCode,
      })),
    },
    rules: ruleSet.rules.map((rule) => ({
      rule_id: rule.ruleId,
      outcome_value: rule.outcomeValue,
      is_default: rule.isDefault,
      label: rule.label,
      condition_groups: rule.conditionGroups.map((group, index) => ({
        condition_group_id:
          `77777777-7777-4777-8777-${String(index + 1).padStart(12, "0")}`,
        conditions: group.conditions.map((condition) => ({
          fact_key: condition.factKey,
          fact_value_type: condition.factValueType,
          comparator: condition.comparator,
          number_value: condition.numberValue,
          category_value: condition.categoryValue,
        })),
      })),
      source_passage_ids: rule.sourcePassageIds,
    })),
  };
}
