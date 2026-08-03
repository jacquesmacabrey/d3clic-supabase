import { resolveValidatedRuleSet } from "./rule-engine.ts";
import {
  parseRuleContext,
  type ValidatedRuleSet,
} from "./rule-template-contract.ts";
import {
  detectTemplateIntent,
  extractFacts,
  renderResolution,
  runtimeRegistryMismatch,
} from "./rule-runtime-registry.ts";

export interface RuleSimulationResult {
  success: boolean;
  simulation: true;
  persisted_status: string;
  simulation_did_not_change_status: true;
  code: string;
  answer?: string;
  result?: string;
  needs_human_review?: boolean;
  source_passage_ids?: string[];
  recognized_fact_count?: number;
}

function executableMemoryCopy(rawRuleSet: unknown): ValidatedRuleSet | null {
  // parseRuleContext valide tout le contrat du moteur et produit volontairement
  // un objet exécutable en mémoire. Il ne lit ni ne modifie la base.
  const parsed = parseRuleContext([rawRuleSet], []);
  return parsed?.ruleSets[0] ?? null;
}

export function simulateAdministrativeRuleSet(
  rawRuleSet: unknown,
  persistedStatus: string,
  question: string,
): RuleSimulationResult {
  const base = {
    simulation: true as const,
    persisted_status: persistedStatus,
    simulation_did_not_change_status: true as const,
  };
  const ruleSet = executableMemoryCopy(rawRuleSet);
  if (ruleSet === null) {
    return { ...base, success: false, code: "invalid_rule_contract" };
  }

  const runtimeMismatch = runtimeRegistryMismatch(ruleSet.template);
  if (runtimeMismatch !== null) {
    return { ...base, success: false, code: "runtime_registry_mismatch" };
  }

  const intent = detectTemplateIntent(question);
  if (intent === null || intent.templateKey !== ruleSet.ruleKey) {
    return { ...base, success: false, code: "question_outside_template" };
  }

  const extraction = extractFacts(question, ruleSet.template);
  const resolution = resolveValidatedRuleSet(ruleSet, extraction);
  const rendered = renderResolution(resolution, ruleSet.template);
  if (rendered === null) {
    return { ...base, success: false, code: "renderer_unavailable" };
  }
  if (
    resolution.sourcePassageIds.some((passageId) =>
      !ruleSet.rules.some((rule) => rule.sourcePassageIds.includes(passageId))
    )
  ) {
    return { ...base, success: false, code: "simulation_source_mismatch" };
  }

  return {
    ...base,
    success: true,
    code: resolution.status,
    answer: rendered.answer,
    result: rendered.result,
    needs_human_review: rendered.needs_human_review,
    source_passage_ids: resolution.sourcePassageIds,
    recognized_fact_count: Object.values(extraction.facts).filter((value) =>
      value !== null
    ).length,
  };
}
