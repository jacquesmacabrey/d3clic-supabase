import {
  ANSWER_SYSTEM_PROMPT,
  buildAnswerUserPrompt,
  clarificationRefinementReason,
  type ModelAnswer,
  parseModelAnswer,
} from "./answer-contract.ts";
import { RagError } from "./errors.ts";

const INFOMANIAK_BASE_URL = "https://api.infomaniak.com";
// Supabase coupe une requête HTTP Edge Function restée sans réponse après
// 150 secondes, y compris sur les plans payants. Deux appels de 35 secondes
// laissent une marge suffisante pour l'embedding, les RPC et la clôture du log.
const REQUEST_TIMEOUT_MS = 35_000;
const MAX_TOTAL_CALLS = 2;

export interface TokenUsage {
  promptTokens: number;

  completionTokens: number;
  totalTokens: number;
}

export interface StructuredGeneration {
  answer: ModelAnswer;
  usage: TokenUsage;
  callCount: number;
  fallbackErrorCode: "generation_invalid" | null;
}

interface ChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

interface GenerationResponse {
  choices?: Array<{ message?: { content?: string } }>;
  usage?: {
    prompt_tokens?: number;
    completion_tokens?: number;
    total_tokens?: number;
  };
}

type Fetcher = typeof fetch;

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function safeToken(value: unknown): number {
  const numeric = Number(value ?? 0);
  return Number.isSafeInteger(numeric) && numeric >= 0 && numeric <= 10_000_000
    ? numeric
    : 0;
}

function addUsage(left: TokenUsage, right: TokenUsage): TokenUsage {
  const promptTokens = left.promptTokens + right.promptTokens;
  const completionTokens = left.completionTokens + right.completionTokens;
  return {
    promptTokens,
    completionTokens,
    totalTokens: promptTokens + completionTokens,
  };
}

function extractJsonObject(text: string): string | null {
  const unwrapped = text
    .replace(/^\s*```(?:json)?\s*/i, "")
    .replace(/```\s*$/i, "");
  let objectStart = -1;
  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let index = 0; index < unwrapped.length; index += 1) {
    const character = unwrapped[index];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === '"') {
        inString = false;
      }
      continue;
    }

    if (character === '"') {
      inString = true;
    } else if (character === "{") {
      if (depth === 0) objectStart = index;
      depth += 1;
    } else if (character === "}" && depth > 0) {
      depth -= 1;
      if (depth === 0 && objectStart >= 0) {
        return unwrapped.slice(objectStart, index + 1);
      }
    }
  }

  return null;
}

function escapeControlCharactersInJsonStrings(json: string): string {
  let repaired = "";
  let inString = false;
  let escaped = false;

  for (const character of json) {
    if (!inString) {
      repaired += character;
      if (character === '"') inString = true;
      continue;
    }

    if (escaped) {
      repaired += character;
      escaped = false;
      continue;
    }

    if (character === "\\") {
      repaired += character;
      escaped = true;
      continue;
    }

    if (character === '"') {
      repaired += character;
      inString = false;
      continue;
    }

    const code = character.charCodeAt(0);
    if (code >= 0x20) {
      repaired += character;
      continue;
    }

    switch (character) {
      case "\b":
        repaired += "\\b";
        break;
      case "\f":
        repaired += "\\f";
        break;
      case "\n":
        repaired += "\\n";
        break;
      case "\r":
        repaired += "\\r";
        break;
      case "\t":
        repaired += "\\t";
        break;
      default:
        repaired += `\\u${code.toString(16).padStart(4, "0")}`;
    }
  }

  return repaired;
}

function repairModelJson(text: string): string | null {
  const candidate = extractJsonObject(text);
  return candidate ? escapeControlCharactersInJsonStrings(candidate) : null;
}

function jsonValueKind(value: unknown): string {
  if (value === null) return "null";
  if (Array.isArray(value)) return "array";
  return typeof value;
}

function isProbeUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value);
}

/**
 * Décrit uniquement la forme d'une sortie refusée. Aucune valeur textuelle,
 * aucun identifiant et aucun contenu documentaire ne sont journalisés.
 */
export function safeModelOutputProbe(
  text: string,
): Record<string, unknown> {
  const repairedJson = repairModelJson(text);
  let candidate = "none";
  let parsed: unknown;

  try {
    parsed = JSON.parse(text);
    candidate = "raw";
  } catch {
    if (repairedJson !== null) {
      try {
        parsed = JSON.parse(repairedJson);
        candidate = "embedded";
      } catch {
        // Le diagnostic reste volontairement structurel.
      }
    }
  }

  if (candidate === "none") {
    return {
      candidate,
      contractIssue: "syntax_invalid",
      rootKind: "invalid",
    };
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return {
      candidate,
      contractIssue: "root_invalid",
      rootKind: jsonValueKind(parsed),
    };
  }

  const row = parsed as Record<string, unknown>;
  const expectedFields = new Set([
    "answer",
    "needs_human_review",
    "result",
    "used_passage_ids",
  ]);
  const keys = Object.keys(row);
  const expectedFieldCount = keys.filter((key) =>
    expectedFields.has(key)
  ).length;
  const extraFieldCount = keys.length - expectedFieldCount;
  const ids = row.used_passage_ids;
  const usedPassageIdCount = Array.isArray(ids) ? ids.length : null;
  const validPassageIdCount = Array.isArray(ids)
    ? ids.filter(isProbeUuid).length
    : null;
  const validResults = new Set([
    "supported",
    "insufficient_sources",
    "conflicting_sources",
    "needs_clarification",
  ]);
  const resultCategory = validResults.has(String(row.result))
    ? row.result
    : "other";
  let contractIssue = "unexpected_acceptance";

  if (row.result === "insufficient_sources") {
  } else if (keys.length !== 4 || expectedFieldCount !== 4) {
    contractIssue = "fields_invalid";
  } else if (resultCategory === "other") {
    contractIssue = "result_invalid";
  } else if (
    typeof row.answer !== "string" ||
    row.answer.trim().length < 1 ||
    row.answer.trim().length > 4_000
  ) {
    contractIssue = "answer_invalid";
  } else if (
    !Array.isArray(ids) ||
    ids.length > 20 ||
    validPassageIdCount !== ids.length
  ) {
    contractIssue = "used_passage_ids_invalid";
  } else if (typeof row.needs_human_review !== "boolean") {
    contractIssue = "needs_human_review_invalid";
  } else if (
    ((resultCategory === "needs_clarification") && ids.length !== 0) ||
    (resultCategory !== "needs_clarification" && ids.length === 0)
  ) {
    contractIssue = "citation_cardinality_invalid";
  }

  return {
    candidate,
    contractIssue,
    rootKind: "object",
    expectedFieldCount,
    extraFieldCount,
    resultKind: jsonValueKind(row.result),
    resultCategory,
    answerKind: jsonValueKind(row.answer),
    answerLength: typeof row.answer === "string" ? row.answer.length : null,
    usedPassageIdsKind: jsonValueKind(ids),
    usedPassageIdCount,
    validPassageIdCount,
    needsHumanReviewKind: jsonValueKind(row.needs_human_review),
  };
}

function hasMissingOrEmptyClarificationAnswer(
  text: string,
  repairedJson: string | null,
): boolean {
  const candidates = repairedJson !== null && repairedJson !== text
    ? [text, repairedJson]
    : [text];

  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate) as unknown;
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        continue;
      }
      const row = parsed as Record<string, unknown>;
      if (
        row.result === "needs_clarification" &&
        (typeof row.answer !== "string" || row.answer.trim().length === 0)
      ) {
        return true;
      }
    } catch {
      // Une sortie non JSON reste prise en charge par la réparation générique.
    }
  }

  return false;
}

function rejectedOutputRepairInstruction(
  missingOrEmptyClarificationAnswer: boolean,
): string {
  if (missingOrEmptyClarificationAnswer) {
    return [
      "La sortie précédente utilise result=needs_clarification, mais le champ answer est vide ou invalide.",
      "Dans answer, écris une seule question de clarification non vide.",
      "Compare les réponses possibles dans les sources et demande le critère minimal qui permet de les départager, en nommant explicitement ce critère.",
      "Ne cite aucun seuil numérique.",
      "Retourne uniquement un objet JSON valide conforme au schéma, sans Markdown ni commentaire.",
    ].join("\n");
  }

  return "La sortie précédente ne respecte pas le schéma JSON strict. Retourne uniquement un objet JSON valide conforme au schéma, sans Markdown ni commentaire.";
}

function allowedPassageIdsFromContext(context: string): string[] {
  return [
    ...context.matchAll(
      /<source passage_id="([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})">/gi,
    ),
  ].map((match) => match[1]);
}

async function generationCall(
  model: string,
  messages: ChatMessage[],
  maxTokens: number,
  fetcher: Fetcher,
): Promise<{ text: string; usage: TokenUsage }> {
  const token = Deno.env.get("INFOMANIAK_AI_TOKEN");
  const productId = Deno.env.get("INFOMANIAK_AI_PRODUCT_ID");
  if (!token || !productId) {
    throw new RagError(
      "generation_not_configured",
      "Le service de réponse n'est pas configuré.",
      500,
    );
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  let response: Response;
  try {
    response = await fetcher(
      `${INFOMANIAK_BASE_URL}/2/ai/${productId}/openai/v1/chat/completions`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model,
          messages,
          temperature: 0,
          max_tokens: maxTokens,
        }),
        signal: controller.signal,
      },
    );
  } catch {
    throw new RagError(
      "generation_unavailable",
      "Le service de réponse ne répond pas.",
      502,
    );
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    const retryable = response.status === 429 || response.status >= 500;
    throw new RagError(
      retryable
        ? "generation_retryable"
        : response.status === 401 || response.status === 403
          ? "generation_auth_failed"
          : "generation_request_rejected",
      "Le service de réponse est momentanément indisponible.",
      502,
    );
  }

  const payload = (await response
    .json()
    .catch(() => null)) as GenerationResponse | null;
  const text = payload?.choices?.[0]?.message?.content?.trim();
  if (!text) {
    throw new RagError(
      "generation_invalid",
      "Le service de réponse a renvoyé un résultat invalide.",
      502,
    );
  }
  const promptTokens = safeToken(payload?.usage?.prompt_tokens);
  const completionTokens = safeToken(payload?.usage?.completion_tokens);
  return {
    text,
    usage: {
      promptTokens,
      completionTokens,
      totalTokens: promptTokens + completionTokens,
    },
  };
}

export async function generateStructuredAnswer(
  model: string,
  question: string,
  context: string,
  maxTokens: number,
  fetcher: Fetcher = fetch,
): Promise<StructuredGeneration> {
  const baseMessages: ChatMessage[] = [
    { role: "system", content: ANSWER_SYSTEM_PROMPT },
    { role: "user", content: buildAnswerUserPrompt(question, context) },
  ];
  let messages = baseMessages;
  let usage: TokenUsage = {
    promptTokens: 0,
    completionTokens: 0,
    totalTokens: 0,
  };
  let previousInvalidText: string | null = null;
  const allowedPassageIds = allowedPassageIdsFromContext(context);
  const allowedPassageIdSet = new Set(allowedPassageIds);

  for (let callCount = 1; callCount <= MAX_TOTAL_CALLS; callCount += 1) {
    try {
      const generated = await generationCall(
        model,
        messages,
        maxTokens,
        fetcher,
      );
      usage = addUsage(usage, generated.usage);
      const repairedJson = repairModelJson(generated.text);
      const answer =
        parseModelAnswer(generated.text) ??
        (repairedJson ? parseModelAnswer(repairedJson) : null);
      if (answer) {
        const refinementReason = answer.result === "needs_clarification"
          ? clarificationRefinementReason(answer.answer)
          : null;
        if (refinementReason !== null && callCount < MAX_TOTAL_CALLS) {
          console.error("generation_clarification_refinement", {
            callCount,
            reason: refinementReason,
          });
          previousInvalidText = generated.text.slice(0, 8_000);
          messages = [
            ...baseMessages,
            { role: "assistant", content: previousInvalidText },
            {
              role: "user",
              content: [
                refinementReason === "numeric"
                  ? "La question de clarification cite des seuils ou des choix numériques."
                  : "La question de clarification est trop vague.",
                "Compare les réponses possibles dans les sources et identifie le critère minimal qui permet de les départager.",
                "Reformule une seule question qui nomme explicitement ce critère, sans citer de seuil numérique.",
                "Retourne uniquement un objet JSON valide conforme au schéma.",
              ].join("\n"),
            },
          ];
          continue;
        }

        const citationsAreValid =
          answer.result === "insufficient_sources" ||
          answer.result === "needs_clarification" ||
          answer.usedPassageIds.every((passageId) =>
            allowedPassageIdSet.has(passageId)
          );
        if (citationsAreValid) {
          return { answer, usage, callCount, fallbackErrorCode: null };
        }

        console.error("generation_invalid_citation", {
          callCount,
          invalidCitationCount: answer.usedPassageIds.filter((passageId) =>
            !allowedPassageIdSet.has(passageId)
          ).length,
        });

        if (callCount === MAX_TOTAL_CALLS) {
          return { answer, usage, callCount, fallbackErrorCode: null };
        }
        previousInvalidText = generated.text.slice(0, 8_000);
        messages = [
          ...baseMessages,
          { role: "assistant", content: previousInvalidText },
          {
            role: "user",
            content: [
              "La sortie précédente contient un passage_id absent des sources.",
              "Retourne uniquement un objet JSON valide conforme au schéma.",
              "Dans used_passage_ids, copie exactement un ou plusieurs identifiants de cette liste, sans les modifier :",
              allowedPassageIds.join(", "),
            ].join("\n"),
          },
        ];
        continue;
      }

      const missingOrEmptyClarificationAnswer =
        hasMissingOrEmptyClarificationAnswer(generated.text, repairedJson);
      console.error("generation_parse_failure", {
        callCount,
        textLength: generated.text.length,
        repairAttempted:
          repairedJson !== null && repairedJson !== generated.text,
        outputProbe: safeModelOutputProbe(generated.text),
      });

      previousInvalidText = generated.text.slice(0, 8_000);
      if (callCount === MAX_TOTAL_CALLS) break;
      messages = [
        ...baseMessages,
        { role: "assistant", content: previousInvalidText },
        {
          role: "user",
          content: rejectedOutputRepairInstruction(
            missingOrEmptyClarificationAnswer,
          ),
        },
      ];
    } catch (error) {
      if (
        error instanceof RagError && error.code === "generation_invalid"
      ) {
        if (callCount === MAX_TOTAL_CALLS) break;
        await sleep(500);
        continue;
      }
      const retryable = error instanceof RagError &&
        (error.code === "generation_retryable" ||
          error.code === "generation_unavailable");
      if (!retryable || callCount === MAX_TOTAL_CALLS) throw error;
      await sleep(500);
    }
  }

  return {
    answer: {
      result: "insufficient_sources",
      answer: "Les sources disponibles ne permettent pas de produire une réponse fiable.",
      usedPassageIds: [],
      needsHumanReview: true,
    },
    usage,
    callCount: MAX_TOTAL_CALLS,
    fallbackErrorCode: "generation_invalid",
  };
}
