import {
  ANSWER_SYSTEM_PROMPT,
  buildAnswerUserPrompt,
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
      if (answer) return { answer, usage, callCount };

      console.error("generation_parse_failure", {
        callCount,
        textLength: generated.text.length,
        repairAttempted:
          repairedJson !== null && repairedJson !== generated.text,
      });

      previousInvalidText = generated.text.slice(0, 8_000);
      if (callCount === MAX_TOTAL_CALLS) break;
      messages = [
        ...baseMessages,
        { role: "assistant", content: previousInvalidText },
        {
          role: "user",
          content:
            "La sortie précédente ne respecte pas le schéma JSON strict. Retourne uniquement un objet JSON valide conforme au schéma, sans Markdown ni commentaire.",
        },
      ];
    } catch (error) {
      const retryable =
        error instanceof RagError &&
        (error.code === "generation_retryable" ||
          error.code === "generation_unavailable");
      if (!retryable || callCount === MAX_TOTAL_CALLS) throw error;
      await sleep(500);
    }
  }

  throw new RagError(
    "generation_invalid",
    "Le service de réponse a renvoyé un résultat invalide.",
    502,
  );
}
