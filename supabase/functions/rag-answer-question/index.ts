import type { SupabaseClient } from "npm:@supabase/supabase-js@2.110.6";
import {
  buildContext,
  insufficientAnswer,
  parseSearchPassages,
  type SearchPassage,
  validateAnswerAgainstSources,
  validateDeterministicAnswerAgainstSources,
  type ValidatedAnswer,
} from "../_shared/rag/answer-contract.ts";
import {
  type AnswerConfig,
  readAnswerConfig,
} from "../_shared/rag/answer-config.ts";
import { requireAuthenticatedUser } from "../_shared/rag/collaborator-auth.ts";
import {
  callRpc,
  createAdminClient,
  isUuid,
  readRequestBytesWithLimit,
} from "../_shared/rag/common.ts";
import {
  EMBEDDING_MODEL,
  embedQuestion,
  vectorLiteral,
} from "../_shared/rag/embeddings.ts";
import { RagError } from "../_shared/rag/errors.ts";
import {
  DETERMINISTIC_INTENT_CONFIDENCE_THRESHOLD,
  DETERMINISTIC_RULE_REQUIRED_MESSAGE,
  detectTemplateIntent,
  evaluateValidatedRuleSets,
  parseRuleContext,
  runtimeRegistryMismatch,
  type RuleContext,
} from "../_shared/rag/deterministic-rules.ts";
import { routeGenericLeaveQuestion } from "../_shared/rag/question-routing.ts";
import {
  parseQuestionRequestBody,
  type QuestionRequest,
} from "../_shared/rag/question-request.ts";
import {
  generateStructuredAnswer,
  type TokenUsage,
} from "../_shared/rag/generation.ts";

const FUNCTION_VERSION =
  "RAG-10.1.1-PROTECTED-PASSAGE-UNIT-FIX-2026-07-30";
const MAX_JSON_BODY_BYTES = 16 * 1024;
const MAX_LOG_DURATION_MS = 300_000;

type JsonObject = Record<string, unknown>;

interface LogState {
  logId: string | null;
  passages: SearchPassage[];
  generationAttempted: boolean;
  usage: TokenUsage | null;
}

function allowedOrigins(): Set<string> {
  return new Set(
    (Deno.env.get("ALLOWED_ORIGINS") ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
}

function corsHeaders(request: Request): Record<string, string> {
  const origin = request.headers.get("origin");
  const headers: Record<string, string> = {
    "Vary": "Origin",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-request-id",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Expose-Headers": "x-request-id",
    "Access-Control-Max-Age": "86400",
  };
  if (origin && allowedOrigins().has(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
  }
  return headers;
}

function secureHeaders(request: Request, requestId: string): HeadersInit {
  return {
    ...corsHeaders(request),
    "Cache-Control": "no-store",
    "Content-Type": "application/json; charset=utf-8",
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Request-Id": requestId,
  };
}

function jsonResponse(
  request: Request,
  requestId: string,
  body: unknown,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: secureHeaders(request, requestId),
  });
}

function preflight(request: Request): Response | null {
  if (request.method !== "OPTIONS") return null;
  const origin = request.headers.get("origin");
  if (!origin || !allowedOrigins().has(origin)) {
    return new Response(null, {
      status: 403,
      headers: {
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
        "X-Content-Type-Options": "nosniff",
      },
    });
  }
  return new Response(null, {
    status: 204,
    headers: {
      ...corsHeaders(request),
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function assertAllowedOrigin(request: Request): void {
  const origin = request.headers.get("origin");
  if (origin !== null && !allowedOrigins().has(origin)) {
    throw new RagError("forbidden_origin", "Origine non autorisée.", 403);
  }
}

function resolveRequestId(request: Request): string {
  const candidate = request.headers.get("x-request-id")?.trim();
  return isUuid(candidate) ? candidate : crypto.randomUUID();
}

async function parseQuestion(request: Request): Promise<QuestionRequest> {
  const contentType = (request.headers.get("content-type") ?? "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    throw new RagError("invalid_request", "Corps JSON requis.", 400);
  }

  const bytes = await readRequestBytesWithLimit(request, MAX_JSON_BODY_BYTES);
  let body: JsonObject;
  try {
    const parsed = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    );
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("invalid");
    }
    body = parsed as JsonObject;
  } catch {
    throw new RagError("invalid_request", "Corps JSON invalide.", 400);
  }
  return parseQuestionRequestBody(body);
}

function clientPayload(
  client: ValidatedAnswer["client"],
  effectiveQuestion: string,
): ValidatedAnswer["client"] & { continuation_question?: string } {
  return client.result === "needs_clarification"
    ? { ...client, continuation_question: effectiveQuestion }
    : client;
}

function durationMs(startedAt: number): number {
  return Math.min(
    MAX_LOG_DURATION_MS,
    Math.max(0, Math.round(performance.now() - startedAt)),
  );
}

function safeErrorCode(error: unknown): string {
  const candidate = error instanceof RagError
    ? error.code
    : "unexpected_error";
  const normalized = candidate.toLowerCase().replace(/[^a-z0-9_]/g, "_")
    .slice(0, 100);
  return normalized || "unexpected_error";
}

async function completeLog(
  admin: SupabaseClient,
  config: AnswerConfig,
  state: LogState,
  startedAt: number,
  result: "supported" | "insufficient_sources" | "error",
  errorCode: string | null,
): Promise<void> {
  if (!state.logId) return;
  const completed = await callRpc(admin, "complete_rag_request_log_wrapper", {
    p_log_id: state.logId,
    p_result: result,
    p_duration_ms: durationMs(startedAt),
    p_passage_ids: state.passages.map((passage) => passage.passageId),
    p_similarity_scores: state.passages.map((passage) => passage.similarity),
    p_embedding_model: EMBEDDING_MODEL,
    p_generation_model: state.generationAttempted
      ? config.generationModel
      : null,
    p_prompt_tokens: state.usage?.promptTokens ?? null,
    p_completion_tokens: state.usage?.completionTokens ?? null,
    p_total_tokens: state.usage?.totalTokens ?? null,
    p_error_code: errorCode,
  });
  if (completed.success !== true || completed.status_code !== "ok") {
    throw new RagError(
      "log_completion_failed",
      "La requête n'a pas pu être finalisée.",
      500,
    );
  }
}

function reserveError(statusCode: unknown): RagError {
  const code = String(statusCode ?? "reservation_failed");
  if (code === "authentication_required") {
    return new RagError("unauthorized", "Authentification requise.", 401);
  }
  if (code === "access_denied") {
    return new RagError(
      "device_not_activated",
      "Cet appareil n'est pas activé.",
      403,
    );
  }
  if (code === "duplicate_request") {
    return new RagError(
      "duplicate_request",
      "Cette requête a déjà été prise en compte.",
      409,
    );
  }
  if (code === "rate_limited") {
    return new RagError(
      "rate_limited",
      "Limite de questions atteinte. Réessaie plus tard.",
      429,
    );
  }
  return new RagError(
    "server_error",
    "Service momentanément indisponible.",
    500,
  );
}

function publicError(error: unknown): RagError {
  if (!(error instanceof RagError)) {
    return new RagError(
      "server_error",
      "Une erreur inattendue est survenue.",
      500,
    );
  }
  if (
    error.code === "unauthorized" ||
    error.code === "device_not_activated" ||
    error.code === "duplicate_request" ||
    error.code === "rate_limited" ||
    error.code === "invalid_request" ||
    error.code === "request_too_large" ||
    error.code === "forbidden_origin"
  ) {
    return error;
  }
  if (error.code.startsWith("embedding_") && error.status === 502) {
    return new RagError(
      "embedding_unavailable",
      "La recherche documentaire est momentanément indisponible.",
      502,
    );
  }
  if (error.code.startsWith("generation_") && error.status === 502) {
    return new RagError(
      "generation_unavailable",
      "La réponse ne peut pas être générée pour le moment.",
      502,
    );
  }
  return new RagError(
    "server_error",
    "Service momentanément indisponible.",
    500,
  );
}

function noSourcesForStatus(statusCode: string): ValidatedAnswer | null {
  if (statusCode === "no_active_documents") {
    return insufficientAnswer(
      "Aucune documentation n'est actuellement disponible pour votre institution.",
      "no_active_documents",
    );
  }
  if (statusCode === "no_relevant_passages") {
    return insufficientAnswer();
  }
  return null;
}

async function loadRuleContext(
  admin: SupabaseClient,
  authUid: string,
  templateKey: string | null,
  passageIds: string[],
): Promise<{ context: RuleContext; statusCode: string }> {
  const lookup = await callRpc(
    admin,
    "get_rag_rule_context_wrapper",
    {
      p_auth_uid: authUid,
      p_template_key: templateKey,
      p_passage_ids: passageIds,
    },
  );
  const statusCode = String(
    lookup.status_code ?? "rule_lookup_failed",
  );
  if (
    lookup.success !== true ||
    !["ok", "no_validated_rule_set"].includes(statusCode)
  ) {
    if (statusCode === "access_denied") {
      throw new RagError(
        "device_not_activated",
        "Cet appareil n'est pas activé.",
        403,
      );
    }
    throw new RagError(
      "deterministic_rule_lookup_failed",
      "La vérification des règles métier est indisponible.",
      500,
    );
  }
  const context = parseRuleContext(
    lookup.rule_sets,
    lookup.protected_passage_ids,
  );
  if (context === null) {
    throw new RagError(
      "invalid_backend_response",
      "Réponse serveur invalide.",
      500,
    );
  }
  return { context, statusCode };
}

function firstRegistryMismatch(context: RuleContext): {
  templateVersionId: string;
  runtimeKey: string;
} | null {
  for (const ruleSet of context.ruleSets) {
    const runtimeKey = runtimeRegistryMismatch(ruleSet.template);
    if (runtimeKey !== null) {
      return {
        templateVersionId: ruleSet.templateVersionId,
        runtimeKey,
      };
    }
  }
  return null;
}

Deno.serve(async (request: Request) => {
  const requestId = resolveRequestId(request);
  const startedAt = performance.now();
  const log = (
    step: string,
    status: number,
    code: string | null = null,
    stepStartedAt = startedAt,
  ) => {
    console.log(JSON.stringify({
      requestId,
      functionVersion: FUNCTION_VERSION,
      step,
      durationMs: Math.round(performance.now() - stepStartedAt),
      status,
      code,
    }));
  };

  const preflightResponse = preflight(request);
  if (preflightResponse) return preflightResponse;
  if (request.method !== "POST") {
    return jsonResponse(
      request,
      requestId,
      { success: false, code: "method_not_allowed" },
      405,
    );
  }

  let admin: SupabaseClient | null = null;
  let config: AnswerConfig | null = null;
  const state: LogState = {
    logId: null,
    passages: [],
    generationAttempted: false,
    usage: null,
  };

  try {
    assertAllowedOrigin(request);
    const declaredLength = Number(
      request.headers.get("content-length") ?? "0",
    );
    if (
      Number.isFinite(declaredLength) &&
      declaredLength > MAX_JSON_BODY_BYTES
    ) {
      throw new RagError(
        "request_too_large",
        "La requête est trop volumineuse.",
        413,
      );
    }

    const questionRequest = await parseQuestion(request);
    const question = questionRequest.effectiveQuestion;
    config = readAnswerConfig();
    admin = createAdminClient();

    let stepStartedAt = performance.now();
    const authUid = await requireAuthenticatedUser(request);
    log("auth", 200, null, stepStartedAt);

    stepStartedAt = performance.now();
    const reservation = await callRpc(admin, "reserve_rag_request_wrapper", {
      p_auth_uid: authUid,
      p_request_id: requestId,
      p_limit_per_hour: config.rateLimitPerHour,
    });
    if (reservation.success !== true || reservation.status_code !== "ok") {
      throw reserveError(reservation.status_code);
    }
    if (!isUuid(reservation.log_id)) {
      throw new RagError(
        "invalid_backend_response",
        "Réponse serveur invalide.",
        500,
      );
    }
    state.logId = reservation.log_id;
    log("reservation", 200, null, stepStartedAt);

    const routedQuestion = routeGenericLeaveQuestion(question);
    if (routedQuestion !== null) {
      stepStartedAt = performance.now();
      const result = validateDeterministicAnswerAgainstSources(
        routedQuestion,
        [],
        [],
        "generic_leave_clarification",
      );
      log(
        "question_routing",
        200,
        result.errorCode,
        stepStartedAt,
      );
      await completeLog(
        admin,
        config,
        state,
        startedAt,
        result.logResult,
        result.errorCode,
      );
      log("completed", 200);
      return jsonResponse(
        request,
        requestId,
        clientPayload(result.client, question),
      );
    }

    const templateIntent = detectTemplateIntent(question);
    if (
      templateIntent !== null &&
      templateIntent.confidence >=
        DETERMINISTIC_INTENT_CONFIDENCE_THRESHOLD
    ) {
      stepStartedAt = performance.now();
      const earlyLookup = await loadRuleContext(
        admin,
        authUid,
        templateIntent.templateKey,
        [],
      );
      log(
        "deterministic_preflight",
        200,
        earlyLookup.statusCode,
        stepStartedAt,
      );

      const mismatch = firstRegistryMismatch(earlyLookup.context);
      if (mismatch !== null) {
        console.error(JSON.stringify({
          requestId,
          functionVersion: FUNCTION_VERSION,
          event: "rag_runtime_registry_mismatch",
          templateVersionId: mismatch.templateVersionId,
          runtimeKey: mismatch.runtimeKey,
        }));
        const result = insufficientAnswer(
          DETERMINISTIC_RULE_REQUIRED_MESSAGE,
          "rag_runtime_registry_mismatch",
          true,
        );
        await completeLog(
          admin,
          config,
          state,
          startedAt,
          result.logResult,
          result.errorCode,
        );
        log("completed", 200, result.errorCode);
        return jsonResponse(
          request,
          requestId,
          clientPayload(result.client, question),
        );
      }

      if (earlyLookup.context.ruleSets.length === 0) {
        const result = insufficientAnswer(
          DETERMINISTIC_RULE_REQUIRED_MESSAGE,
          "deterministic_rule_required",
          true,
        );
        await completeLog(
          admin,
          config,
          state,
          startedAt,
          result.logResult,
          result.errorCode,
        );
        log("completed", 200, result.errorCode);
        return jsonResponse(
          request,
          requestId,
          clientPayload(result.client, question),
        );
      }
    }

    stepStartedAt = performance.now();
    const queryVector = await embedQuestion(question);
    log("embedding", 200, null, stepStartedAt);

    stepStartedAt = performance.now();
    const search = await callRpc(admin, "search_rag_passages_wrapper", {
      p_auth_uid: authUid,
      p_query_embedding: vectorLiteral(queryVector),
      p_top_k: config.searchTopK,
      p_min_similarity: config.searchMinSimilarity,
      p_max_per_document: config.searchMaxPerDocument,
    });
    const searchStatus = String(search.status_code ?? "search_failed");
    if (
      search.success !== true ||
      !["ok", "no_active_documents", "no_relevant_passages"].includes(
        searchStatus,
      )
    ) {
      if (searchStatus === "authentication_required") {
        throw new RagError(
          "unauthorized",
          "Authentification requise.",
          401,
        );
      }
      if (searchStatus === "access_denied") {
        throw new RagError(
          "device_not_activated",
          "Cet appareil n'est pas activé.",
          403,
        );
      }
      throw new RagError(
        "search_failed",
        "La recherche documentaire est indisponible.",
        500,
      );
    }
    log("search", 200, searchStatus, stepStartedAt);

    const noSources = noSourcesForStatus(searchStatus);
    if (noSources) {
      await completeLog(
        admin,
        config,
        state,
        startedAt,
        noSources.logResult,
        noSources.errorCode,
      );
      log("completed", 200);
      return jsonResponse(
        request,
        requestId,
        clientPayload(noSources.client, question),
      );
    }

    const passages = parseSearchPassages(search.passages);
    const context = buildContext(passages, config.maxContextChars);
    state.passages = context.included;
    if (context.included.length === 0) {
      const result = insufficientAnswer(
        undefined,
        "context_limit_exceeded",
      );
      await completeLog(
        admin,
        config,
        state,
        startedAt,
        result.logResult,
        result.errorCode,
      );
      log("completed", 200);
      return jsonResponse(
        request,
        requestId,
        clientPayload(result.client, question),
      );
    }

    stepStartedAt = performance.now();
    const ruleLookup = await loadRuleContext(
      admin,
      authUid,
      templateIntent?.templateKey ?? null,
      context.included.map((passage) => passage.passageId),
    );
    const ruleSets = ruleLookup.context.ruleSets;
    const protectedPassages = ruleLookup.context.protectedPassages;
    log(
      "deterministic_lookup",
      200,
      ruleLookup.statusCode,
      stepStartedAt,
    );

    const runtimeMismatch = firstRegistryMismatch(ruleLookup.context);
    if (runtimeMismatch !== null) {
      console.error(JSON.stringify({
        requestId,
        functionVersion: FUNCTION_VERSION,
        event: "rag_runtime_registry_mismatch",
        templateVersionId: runtimeMismatch.templateVersionId,
        runtimeKey: runtimeMismatch.runtimeKey,
      }));
      const result = insufficientAnswer(
        DETERMINISTIC_RULE_REQUIRED_MESSAGE,
        "rag_runtime_registry_mismatch",
        true,
      );
      await completeLog(
        admin,
        config,
        state,
        startedAt,
        result.logResult,
        result.errorCode,
      );
      log("completed", 200, result.errorCode);
      return jsonResponse(
        request,
        requestId,
        clientPayload(result.client, question),
      );
    }

    const deterministic = evaluateValidatedRuleSets(question, ruleSets);
    if (deterministic !== null) {
      stepStartedAt = performance.now();
      const result = validateDeterministicAnswerAgainstSources(
        deterministic.answer,
        deterministic.sourcePassageIds,
        context.included,
        deterministic.errorCode,
      );
      const usedIds = new Set(
        result.client.citations.map((citation) => citation.passage_id),
      );
      state.passages = context.included.filter((passage) =>
        usedIds.has(passage.passageId)
      );
      log(
        "deterministic_resolution",
        200,
        result.errorCode,
        stepStartedAt,
      );
      await completeLog(
        admin,
        config,
        state,
        startedAt,
        result.logResult,
        result.errorCode,
      );
      log("completed", 200);
      return jsonResponse(
        request,
        requestId,
        clientPayload(result.client, question),
      );
    }

    stepStartedAt = performance.now();
    state.generationAttempted = true;
    const generation = await generateStructuredAnswer(
      config.generationModel,
      question,
      context.context,
      config.maxAnswerTokens,
    );
    state.usage = generation.usage;
    log("generation", 200, null, stepStartedAt);

    stepStartedAt = performance.now();
    const result = validateAnswerAgainstSources(
      generation.answer,
      context.included,
      ruleSets,
      protectedPassages,
    );
    log("validation", 200, result.errorCode, stepStartedAt);

    await completeLog(
      admin,
      config,
      state,
      startedAt,
      result.logResult,
      result.errorCode,
    );
    log("completed", 200);
    return jsonResponse(
      request,
      requestId,
      clientPayload(result.client, question),
    );
  } catch (error) {
    const internalCode = safeErrorCode(error);
    if (admin && config && state.logId) {
      try {
        await completeLog(
          admin,
          config,
          state,
          startedAt,
          "error",
          internalCode,
        );
      } catch {
        log("log_completion", 500, "log_completion_failed");
      }
    }
    const exposed = publicError(error);
    log("failed", exposed.status, internalCode);
    return jsonResponse(
      request,
      requestId,
      {
        success: false,
        code: exposed.code,
        message: exposed.message,
      },
      exposed.status,
    );
  }
});
