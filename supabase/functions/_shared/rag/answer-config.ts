import { RagError } from "./errors.ts";

export interface AnswerConfig {
  generationModel: string;
  searchTopK: number;
  searchMinSimilarity: number;
  searchMaxPerDocument: number;
  maxContextChars: number;
  maxAnswerTokens: number;
  rateLimitPerHour: number;
}

type EnvReader = (name: string) => string | undefined;

function requiredValue(name: string, readEnv: EnvReader): string {
  const value = readEnv(name)?.trim();
  if (!value) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }
  return value;
}

function requiredInteger(
  name: string,
  min: number,
  max: number,
  readEnv: EnvReader,
): number {
  const raw = requiredValue(name, readEnv);
  if (!/^[0-9]+$/.test(raw)) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }
  return value;
}

function requiredNumber(
  name: string,
  min: number,
  max: number,
  readEnv: EnvReader,
): number {
  const raw = requiredValue(name, readEnv);
  const value = Number(raw);
  if (!Number.isFinite(value) || value < min || value > max) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }
  return value;
}

export function readAnswerConfig(
  readEnv: EnvReader = (name) => Deno.env.get(name),
): AnswerConfig {
  const generationModel = requiredValue("RAG_GENERATION_MODEL", readEnv);
  if (generationModel.length > 200) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }

  const searchTopK = requiredInteger("RAG_SEARCH_TOP_K", 1, 20, readEnv);
  const searchMaxPerDocument = requiredInteger(
    "RAG_SEARCH_MAX_PER_DOCUMENT",
    1,
    5,
    readEnv,
  );
  if (searchMaxPerDocument > searchTopK) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }

  return {
    generationModel,
    searchTopK,
    searchMinSimilarity: requiredNumber(
      "RAG_SEARCH_MIN_SIMILARITY",
      0,
      1,
      readEnv,
    ),
    searchMaxPerDocument,
    maxContextChars: requiredInteger(
      "RAG_MAX_CONTEXT_CHARS",
      4_000,
      60_000,
      readEnv,
    ),
    maxAnswerTokens: requiredInteger(
      "RAG_MAX_ANSWER_TOKENS",
      100,
      2_000,
      readEnv,
    ),
    rateLimitPerHour: requiredInteger(
      "RAG_RATE_LIMIT_PER_HOUR",
      1,
      120,
      readEnv,
    ),
  };
}
