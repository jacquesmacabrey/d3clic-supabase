export type RuleAdminAction =
  | "list"
  | "detail"
  | "precheck"
  | "simulate"
  | "create_revision"
  | "save"
  | "confirm"
  | "reject"
  | "history";

export type RuleSetStatus =
  | "proposed"
  | "needs_attention"
  | "approved"
  | "validated"
  | "rejected"
  | "invalidated";

export type RejectionReason =
  | "incorrect_values"
  | "incorrect_or_insufficient_sources"
  | "not_applicable_to_institution"
  | "wrong_template"
  | "other";

export interface RuleAdminRequest {
  action: RuleAdminAction;
  rule_set_id?: string;
  document_id?: string;
  template_key?: string;
  statuses?: RuleSetStatus[];
  action_required?: boolean;
  cursor?: string;
  limit?: number;
  expected_revision_number?: number;
  operation_id?: string;
  confirmation?: true;
  reason_code?: RejectionReason;
  rejection_note?: string;
  question?: string;
  rules?: EditableRule[];
}

export interface EditableCondition {
  fact_key: string;
  comparator: "=" | "!=" | "<" | "<=" | ">" | ">=";
  fact_value_type: "number" | "category";
  number_value: number | null;
  category_value: string | null;
}

export interface EditableConditionGroup {
  display_order: number;
  conditions: EditableCondition[];
}

export interface EditableRule {
  rule_id?: string;
  outcome_value: number;
  is_default: boolean;
  display_order: number;
  label: string;
  condition_groups: EditableConditionGroup[];
  source_passage_ids: string[];
}

const UUID =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const KEY = /^[a-z][a-z0-9_]{2,99}$/;
const STATUSES = new Set<RuleSetStatus>([
  "proposed",
  "needs_attention",
  "approved",
  "validated",
  "rejected",
  "invalidated",
]);
const REJECTION_REASONS = new Set<RejectionReason>([
  "incorrect_values",
  "incorrect_or_insufficient_sources",
  "not_applicable_to_institution",
  "wrong_template",
  "other",
]);
const COMPARATORS = new Set(["=", "!=", "<", "<=", ">", ">="]);

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasOnlyKeys(
  value: Record<string, unknown>,
  allowed: readonly string[],
): boolean {
  const allowedSet = new Set(allowed);
  return Object.keys(value).every((key) => allowedSet.has(key));
}

function requireUuid(value: unknown, code: string): string {
  if (typeof value !== "string" || !UUID.test(value)) throw new Error(code);
  return value;
}

function requirePositiveRevision(value: unknown): number {
  if (!Number.isSafeInteger(value) || (value as number) < 1) {
    throw new Error("invalid_revision_number");
  }
  return value as number;
}

function parseCondition(value: unknown): EditableCondition {
  if (
    !isRecord(value) ||
    !hasOnlyKeys(value, [
      "fact_key",
      "comparator",
      "fact_value_type",
      "number_value",
      "category_value",
    ]) ||
    typeof value.fact_key !== "string" ||
    !KEY.test(value.fact_key) ||
    typeof value.comparator !== "string" ||
    !COMPARATORS.has(value.comparator) ||
    (value.fact_value_type !== "number" &&
      value.fact_value_type !== "category")
  ) throw new Error("invalid_condition");

  const numberValue = value.number_value;
  const categoryValue = value.category_value;
  if (
    value.fact_value_type === "number"
      ? !(typeof numberValue === "number" && Number.isFinite(numberValue) &&
        categoryValue === null)
      : !(numberValue === null && typeof categoryValue === "string" &&
        KEY.test(categoryValue))
  ) throw new Error("invalid_condition_value");

  return {
    fact_key: value.fact_key,
    comparator: value.comparator as EditableCondition["comparator"],
    fact_value_type: value.fact_value_type,
    number_value: numberValue as number | null,
    category_value: categoryValue as string | null,
  };
}

function parseGroup(value: unknown): EditableConditionGroup {
  if (
    !isRecord(value) ||
    !hasOnlyKeys(value, ["display_order", "conditions"]) ||
    !Number.isSafeInteger(value.display_order) ||
    (value.display_order as number) < 0 ||
    (value.display_order as number) > 1000 ||
    !Array.isArray(value.conditions) ||
    value.conditions.length < 1 ||
    value.conditions.length > 20
  ) throw new Error("invalid_condition_group");
  return {
    display_order: value.display_order as number,
    conditions: value.conditions.map(parseCondition),
  };
}

function parseEditableRule(value: unknown): EditableRule {
  if (
    !isRecord(value) ||
    !hasOnlyKeys(value, [
      "rule_id",
      "outcome_value",
      "is_default",
      "display_order",
      "label",
      "condition_groups",
      "source_passage_ids",
    ]) ||
    (value.rule_id !== undefined &&
      (typeof value.rule_id !== "string" || !UUID.test(value.rule_id))) ||
    typeof value.outcome_value !== "number" ||
    !Number.isFinite(value.outcome_value) ||
    typeof value.is_default !== "boolean" ||
    !Number.isSafeInteger(value.display_order) ||
    (value.display_order as number) < 0 ||
    (value.display_order as number) > 1000 ||
    typeof value.label !== "string" ||
    value.label !== value.label.trim() ||
    value.label.length < 1 ||
    value.label.length > 250 ||
    !Array.isArray(value.condition_groups) ||
    value.condition_groups.length > 20 ||
    !Array.isArray(value.source_passage_ids) ||
    value.source_passage_ids.length < 1 ||
    value.source_passage_ids.length > 20 ||
    !value.source_passage_ids.every((id) =>
      typeof id === "string" && UUID.test(id)
    ) ||
    new Set(value.source_passage_ids).size !== value.source_passage_ids.length
  ) throw new Error("invalid_rule");
  if (
    (value.is_default && value.condition_groups.length !== 0) ||
    (!value.is_default && value.condition_groups.length === 0)
  ) throw new Error("invalid_rule_structure");
  return {
    rule_id: value.rule_id as string | undefined,
    outcome_value: value.outcome_value,
    is_default: value.is_default,
    display_order: value.display_order as number,
    label: value.label,
    condition_groups: value.condition_groups.map(parseGroup),
    source_passage_ids: value.source_passage_ids as string[],
  };
}

export function parseRuleAdminRequest(value: unknown): RuleAdminRequest {
  if (!isRecord(value) || typeof value.action !== "string") {
    throw new Error("invalid_request");
  }
  const action = value.action as RuleAdminAction;
  const commonListKeys = [
    "action",
    "document_id",
    "template_key",
    "statuses",
    "action_required",
    "cursor",
    "limit",
  ];
  if (action === "list") {
    if (!hasOnlyKeys(value, commonListKeys)) throw new Error("unknown_field");
    if (value.document_id !== undefined) requireUuid(value.document_id, "invalid_document_id");
    if (value.template_key !== undefined &&
      (typeof value.template_key !== "string" || !KEY.test(value.template_key))) {
      throw new Error("invalid_template_key");
    }
    if (value.statuses !== undefined &&
      (!Array.isArray(value.statuses) || value.statuses.length > 6 ||
        !value.statuses.every((status) => STATUSES.has(status)))) {
      throw new Error("invalid_statuses");
    }
    if (value.action_required !== undefined &&
      typeof value.action_required !== "boolean") {
      throw new Error("invalid_action_required");
    }
    if (value.cursor !== undefined &&
      (typeof value.cursor !== "string" || value.cursor.length > 500)) {
      throw new Error("invalid_cursor");
    }
    if (value.limit !== undefined &&
      (!Number.isSafeInteger(value.limit) || (value.limit as number) < 1 ||
        (value.limit as number) > 100)) throw new Error("invalid_limit");
    return value as unknown as RuleAdminRequest;
  }

  if (action === "detail" || action === "precheck" || action === "create_revision") {
    if (!hasOnlyKeys(value, ["action", "rule_set_id"])) throw new Error("unknown_field");
    return { action, rule_set_id: requireUuid(value.rule_set_id, "invalid_rule_set_id") };
  }

  if (action === "simulate") {
    if (!hasOnlyKeys(value, ["action", "rule_set_id", "question"])) throw new Error("unknown_field");
    if (typeof value.question !== "string" || value.question.trim().length < 1 || value.question.length > 1000) {
      throw new Error("invalid_question");
    }
    return {
      action,
      rule_set_id: requireUuid(value.rule_set_id, "invalid_rule_set_id"),
      question: value.question.trim(),
    };
  }

  if (action === "history") {
    if (!hasOnlyKeys(value, ["action", "rule_set_id", "cursor", "limit"])) throw new Error("unknown_field");
    if (value.rule_set_id !== undefined) requireUuid(value.rule_set_id, "invalid_rule_set_id");
    if (value.cursor !== undefined && (typeof value.cursor !== "string" || value.cursor.length > 500)) {
      throw new Error("invalid_cursor");
    }
    if (value.limit !== undefined &&
      (!Number.isSafeInteger(value.limit) || (value.limit as number) < 1 ||
        (value.limit as number) > 100)) throw new Error("invalid_limit");
    return value as unknown as RuleAdminRequest;
  }

  if (action === "save") {
    if (!hasOnlyKeys(value, ["action", "rule_set_id", "expected_revision_number", "operation_id", "rules"])) {
      throw new Error("unknown_field");
    }
    if (!Array.isArray(value.rules) || value.rules.length < 1 || value.rules.length > 100) {
      throw new Error("invalid_rules");
    }
    const rules = value.rules.map(parseEditableRule);
    if (rules.filter((rule) => rule.is_default).length !== 1 ||
      new Set(rules.map((rule) => rule.display_order)).size !== rules.length) {
      throw new Error("invalid_rule_structure");
    }
    return {
      action,
      rule_set_id: requireUuid(value.rule_set_id, "invalid_rule_set_id"),
      expected_revision_number: requirePositiveRevision(value.expected_revision_number),
      operation_id: requireUuid(value.operation_id, "invalid_operation_id"),
      rules,
    };
  }

  if (action === "confirm") {
    if (!hasOnlyKeys(value, ["action", "rule_set_id", "expected_revision_number", "operation_id", "confirmation"])) {
      throw new Error("unknown_field");
    }
    if (value.confirmation !== true) throw new Error("confirmation_required");
    return {
      action,
      rule_set_id: requireUuid(value.rule_set_id, "invalid_rule_set_id"),
      expected_revision_number: requirePositiveRevision(value.expected_revision_number),
      operation_id: requireUuid(value.operation_id, "invalid_operation_id"),
      confirmation: true,
    };
  }

  if (action === "reject") {
    if (!hasOnlyKeys(value, ["action", "rule_set_id", "expected_revision_number", "operation_id", "reason_code", "rejection_note"])) {
      throw new Error("unknown_field");
    }
    if (!REJECTION_REASONS.has(value.reason_code as RejectionReason)) {
      throw new Error("invalid_rejection_reason");
    }
    const note = typeof value.rejection_note === "string" ? value.rejection_note.trim() : undefined;
    if ((value.reason_code === "other" && (!note || note.length > 500)) ||
      (value.reason_code !== "other" && value.rejection_note !== undefined)) {
      throw new Error("invalid_rejection_note");
    }
    return {
      action,
      rule_set_id: requireUuid(value.rule_set_id, "invalid_rule_set_id"),
      expected_revision_number: requirePositiveRevision(value.expected_revision_number),
      operation_id: requireUuid(value.operation_id, "invalid_operation_id"),
      reason_code: value.reason_code as RejectionReason,
      rejection_note: note,
    };
  }

  throw new Error("invalid_action");
}
