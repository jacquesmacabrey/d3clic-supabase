import { RagError } from "./errors.ts";

const INFOMANIAK_BASE_URL = "https://api.infomaniak.com";
export const EMBEDDING_MODEL = "Qwen/Qwen3-Embedding-8B";
export const EMBEDDING_DIMENSIONS = 1536;
export const EMBEDDING_BATCH_SIZE = 16;
const REQUEST_TIMEOUT_MS = 75_000;
const MAX_ATTEMPTS = 3;
const QUESTION_REQUEST_TIMEOUT_MS = 20_000;
const QUESTION_MAX_ATTEMPTS = 2;

interface EmbeddingPolicy {
  requestTimeoutMs: number;
  maxAttempts: number;
}

interface EmbeddingItem {
  index?: number;
  embedding?: number[];
}

interface EmbeddingResponse {
  data?: EmbeddingItem[];
  model?: string;
  usage?: {
    prompt_tokens?: number;
    total_tokens?: number;
  };
}

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function validateVector(vector: unknown): number[] {
  if (
    !Array.isArray(vector) ||
    vector.length !== EMBEDDING_DIMENSIONS ||
    !vector.every((value) =>
      typeof value === "number" && Number.isFinite(value)
    )
  ) {
    throw new RagError(
      "embedding_invalid",
      "Le service d'embeddings a renvoyé un vecteur invalide.",
      502,
    );
  }
  return vector as number[];
}

async function callEmbeddingBatch(
  inputs: string[],
  policy: EmbeddingPolicy = {
    requestTimeoutMs: REQUEST_TIMEOUT_MS,
    maxAttempts: MAX_ATTEMPTS,
  },
): Promise<number[][]> {
  const token = Deno.env.get("INFOMANIAK_AI_TOKEN");
  const productId = Deno.env.get("INFOMANIAK_AI_PRODUCT_ID");
  if (!token || !productId) {
    throw new RagError(
      "embedding_not_configured",
      "Le service d'embeddings n'est pas configuré.",
      500,
    );
  }

  const url = `${INFOMANIAK_BASE_URL}/2/ai/${productId}/openai/v1/embeddings`;
  let lastStatus = 0;

  for (let attempt = 1; attempt <= policy.maxAttempts; attempt += 1) {
    const controller = new AbortController();
    const timeout = setTimeout(
      () => controller.abort(),
      policy.requestTimeoutMs,
    );
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          model: EMBEDDING_MODEL,
          input: inputs,
          dimensions: EMBEDDING_DIMENSIONS,
          encoding_format: "float",
        }),
        signal: controller.signal,
      });
      clearTimeout(timeout);
      lastStatus = response.status;

      if (response.ok) {
        const payload = await response.json().catch(() => null) as
          | EmbeddingResponse
          | null;
        const items = payload?.data;
        if (!Array.isArray(items) || items.length !== inputs.length) {
          throw new RagError(
            "embedding_invalid",
            "Le service d'embeddings a renvoyé une réponse incomplète.",
            502,
          );
        }
        const sorted = [...items].sort(
          (left, right) => Number(left.index ?? 0) - Number(right.index ?? 0),
        );
        return sorted.map((item) => validateVector(item.embedding));
      }

      const retryable = response.status === 429 || response.status >= 500;
      if (!retryable) {
        throw new RagError(
          response.status === 401 || response.status === 403
            ? "embedding_auth_failed"
            : "embedding_request_rejected",
          "Le service d'embeddings a refusé la requête.",
          502,
        );
      }
    } catch (error) {
      clearTimeout(timeout);
      if (error instanceof RagError) throw error;
      if (attempt === policy.maxAttempts) {
        throw new RagError(
          "embedding_unavailable",
          "Le service d'embeddings ne répond pas.",
          502,
        );
      }
    }

    if (attempt < policy.maxAttempts) {
      await sleep(500 * 2 ** (attempt - 1) + Math.floor(Math.random() * 250));
    }
  }

  throw new RagError(
    lastStatus === 429 ? "embedding_rate_limited" : "embedding_unavailable",
    lastStatus === 429
      ? "Le service d'embeddings est temporairement saturé."
      : "Le service d'embeddings ne répond pas.",
    502,
  );
}

export async function embedTexts(inputs: string[]): Promise<number[][]> {
  if (inputs.length < 1 || inputs.length > EMBEDDING_BATCH_SIZE) {
    throw new RagError(
      "invalid_embedding_batch",
      "Lot d'embeddings invalide.",
      500,
    );
  }
  if (inputs.some((input) => !input.trim())) {
    throw new RagError(
      "invalid_embedding_input",
      "Un passage à vectoriser est vide.",
      500,
    );
  }
  return await callEmbeddingBatch(inputs);
}

/**
 * Politique synchrone dédiée aux questions collaborateur.
 *
 * L'ingestion conserve ses valeurs auditées (3 tentatives de 75 secondes).
 * Le parcours HTTP interactif est borné à 2 tentatives de 20 secondes afin
 * de rester, avec la génération, sous l'idle timeout HTTP de 150 secondes
 * de Supabase tout en gardant une marge pour les RPC et la clôture du log.
 */
export async function embedQuestion(question: string): Promise<number[]> {
  const inputs = [question];
  if (!question.trim()) {
    throw new RagError(
      "invalid_embedding_input",
      "La question à vectoriser est vide.",
      500,
    );
  }
  const vectors = await callEmbeddingBatch(inputs, {
    requestTimeoutMs: QUESTION_REQUEST_TIMEOUT_MS,
    maxAttempts: QUESTION_MAX_ATTEMPTS,
  });
  return vectors[0];
}

export function vectorLiteral(vector: number[]): string {
  const validated = validateVector(vector);
  return `[${validated.join(",")}]`;
}
