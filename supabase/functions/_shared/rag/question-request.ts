import { RagError } from "./errors.ts";

export const MAX_QUESTION_CHARACTERS = 1_000;
export const MAX_PENDING_QUESTION_CHARACTERS = 4_000;
export const MAX_EFFECTIVE_QUESTION_CHARACTERS = 5_100;

export interface QuestionRequest {
  question: string;
  pendingQuestion: string | null;
  effectiveQuestion: string;
}

type JsonObject = Record<string, unknown>;

function isRecord(value: unknown): value is JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

export function normalizeQuestion(
  value: unknown,
  maximumCharacters = MAX_QUESTION_CHARACTERS,
): string {
  if (typeof value !== "string") {
    throw new RagError("invalid_request", "Question invalide.", 400);
  }
  const normalized = value.normalize("NFKC").replace(/\s+/g, " ").trim();
  if (
    normalized.length < 3 ||
    normalized.length > maximumCharacters
  ) {
    throw new RagError("invalid_request", "Question invalide.", 400);
  }
  return normalized;
}

export function buildEffectiveQuestion(
  question: string,
  pendingQuestion: string | null,
): string {
  if (pendingQuestion === null) return question;

  const effective = pendingQuestion.startsWith("Question initiale :")
    ? `${pendingQuestion}\nComplément de l’utilisateur : ${question}`
    : [
      `Question initiale : ${pendingQuestion}`,
      `Complément de l’utilisateur : ${question}`,
    ].join("\n");
  if (effective.length > MAX_EFFECTIVE_QUESTION_CHARACTERS) {
    throw new RagError("invalid_request", "Requête invalide.", 400);
  }
  return effective;
}

export function parseQuestionRequestBody(value: unknown): QuestionRequest {
  if (!isRecord(value)) {
    throw new RagError("invalid_request", "Corps JSON invalide.", 400);
  }

  const keys = Object.keys(value).sort();
  const allowed = value.pending_question === undefined
    ? ["question"]
    : ["pending_question", "question"];
  if (
    keys.length !== allowed.length ||
    keys.some((key, index) => key !== allowed[index])
  ) {
    throw new RagError("invalid_request", "Requête invalide.", 400);
  }

  const question = normalizeQuestion(value.question);
  const pendingQuestion = value.pending_question === undefined
    ? null
    : normalizeQuestion(
      value.pending_question,
      MAX_PENDING_QUESTION_CHARACTERS,
    );

  return {
    question,
    pendingQuestion,
    effectiveQuestion: buildEffectiveQuestion(question, pendingQuestion),
  };
}
