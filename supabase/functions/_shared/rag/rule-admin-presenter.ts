import type { Comparator } from "./rule-template-contract.ts";

const STATUS_LABELS: Readonly<Record<string, string>> = {
  proposed: "À vérifier",
  needs_attention: "Correction nécessaire",
  approved: "Approuvée, en attente d’activation",
  validated: "Active",
  rejected: "Rejetée",
  invalidated: "Remplacée ou retirée",
};

const OPERATOR_LABELS: Readonly<Record<Comparator, string>> = {
  "=": "est égal à",
  "!=": "est différent de",
  "<": "est inférieur à",
  "<=": "est inférieur ou égal à",
  ">": "est supérieur à",
  ">=": "est supérieur ou égal à",
};

export function ruleStatusLabel(status: string): string {
  return STATUS_LABELS[status] ?? "Statut inconnu";
}

export function operatorLabel(comparator: Comparator): string {
  return OPERATOR_LABELS[comparator];
}

export function formatOutcome(value: number, unit: string): string {
  if (unit === "days") return `${value} jour${value > 1 ? "s" : ""}`;
  return `${value} ${unit}`;
}

export function actionForStatus(status: string): string | null {
  if (status === "proposed") return "Vérifier et approuver";
  if (status === "needs_attention") return "Corriger";
  if (status === "approved") return "Activer le document";
  if (status === "validated") return "Créer une révision";
  return null;
}

export interface PresentableCondition {
  fact_key: string;
  fact_label_fr: string;
  comparator: Comparator;
  number_value: number | null;
  category_value: string | null;
  category_label_fr: string | null;
}

export function conditionLabel(condition: PresentableCondition): string {
  if (condition.category_value !== null) {
    return `${condition.fact_label_fr} ${operatorLabel(condition.comparator)} ${
      condition.category_label_fr ?? condition.category_value
    }`;
  }
  const value = condition.number_value;
  if (condition.fact_key === "age_years" && condition.comparator === ">=") {
    return `Dès ${value} ans`;
  }
  if (
    condition.fact_key === "service_years" && condition.comparator === ">="
  ) {
    return `Dès ${value} ans de service`;
  }
  return `${condition.fact_label_fr} ${operatorLabel(condition.comparator)} ${value}`;
}

export function addRuleDisplayModel<T extends Record<string, unknown>>(
  detail: T,
): T & { display_model: Record<string, unknown> } {
  const status = typeof detail.status === "string" ? detail.status : "";
  const resultUnit = typeof detail.result_unit === "string"
    ? detail.result_unit
    : "";
  const rules = Array.isArray(detail.rules) ? detail.rules : [];
  const displayRules = rules.map((raw) => {
    const rule = raw as Record<string, unknown>;
    const groups = Array.isArray(rule.condition_groups)
      ? rule.condition_groups
      : [];
    const conditions = groups.map((group) => {
      const groupRecord = group as Record<string, unknown>;
      const entries = Array.isArray(groupRecord.conditions)
        ? groupRecord.conditions
        : [];
      return entries.map((entry) => conditionLabel(entry as PresentableCondition));
    });
    return {
      rule_id: rule.rule_id,
      label: rule.label,
      outcome: formatOutcome(Number(rule.outcome_value), resultUnit),
      is_default: rule.is_default,
      conditions,
      sources: rule.sources ?? [],
    };
  });
  return {
    ...detail,
    display_model: {
      status_label: ruleStatusLabel(status),
      action_label: actionForStatus(status),
      rules: displayRules,
    },
  };
}
