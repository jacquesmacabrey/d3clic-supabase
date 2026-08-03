import {
  resolveValidatedRuleSet,
  type DeterministicResolution,
  type FactExtraction,
} from "./rule-engine.ts";
import {
  detectTemplateIntent,
  extractFacts,
  type PublicDeterministicAnswer,
  questionTargetsAnnualLeave,
  renderResolution,
  requiresDeterministicHandling,
  runtimeRegistryMismatch,
} from "./rule-runtime-registry.ts";
import {
  parseRuleContext,
  type ProtectedPassage,
  type RuleContext,
  type ValidatedRuleSet,
} from "./rule-template-contract.ts";

export type {
  DeterministicResolution,
  FactExtraction,
  ProtectedPassage,
  PublicDeterministicAnswer,
  RuleContext,
  ValidatedRuleSet,
};
export {
  detectTemplateIntent,
  parseRuleContext,
  questionTargetsAnnualLeave,
  requiresDeterministicHandling,
  runtimeRegistryMismatch,
};

export const DETERMINISTIC_INTENT_CONFIDENCE_THRESHOLD = 0.9;
export const DETERMINISTIC_RULE_REQUIRED_MESSAGE =
  "Cette disposition nécessite une vérification avant que je puisse déterminer ton droit individuel.";

export interface DeterministicEvaluation {
  answer: PublicDeterministicAnswer;
  sourcePassageIds: string[];
  errorCode: string | null;
}
function blockedAnswer(): PublicDeterministicAnswer {
  return {
    result: "insufficient_sources",
    answer:
      "Je ne peux pas déterminer ce droit de manière suffisamment fiable à partir des informations disponibles.",
    needs_human_review: true,
  };
}

function evaluateOne(
  question: string,
  ruleSet: ValidatedRuleSet,
): DeterministicEvaluation {
  const missingRuntimeKey = runtimeRegistryMismatch(ruleSet.template);
  if (missingRuntimeKey !== null) {
    return {
      answer: blockedAnswer(),
      sourcePassageIds: [],
      errorCode: "rag_runtime_registry_mismatch",
    };
  }

  const extraction = extractFacts(question, ruleSet.template);
  const resolution = resolveValidatedRuleSet(ruleSet, extraction);
  const answer = renderResolution(resolution, ruleSet.template);
  if (answer === null) {
    return {
      answer: blockedAnswer(),
      sourcePassageIds: [],
      errorCode: "rag_runtime_registry_mismatch",
    };
  }
  return {
    answer,
    sourcePassageIds: resolution.sourcePassageIds,
    errorCode: resolution.reason === null
      ? resolution.status === "needs_clarification"
        ? "deterministic_needs_clarification"
        : null
      : `deterministic_${resolution.reason}`.slice(0, 100),
  };
}

export function evaluateValidatedRuleSets(
  question: string,
  ruleSets: ValidatedRuleSet[],
): DeterministicEvaluation | null {
  const intent = detectTemplateIntent(question);
  if (intent === null) return null;
  const matchingRuleSets = ruleSets.filter((ruleSet) =>
    ruleSet.ruleKey === intent.templateKey
  );
  if (matchingRuleSets.length === 0) return null;
  if (matchingRuleSets.length !== 1) {
    return {
      answer: blockedAnswer(),
      sourcePassageIds: [],
      errorCode: "deterministic_rule_ambiguous",
    };
  }
  return evaluateOne(question, matchingRuleSets[0]);
}
