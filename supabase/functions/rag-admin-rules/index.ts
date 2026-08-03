import {
  assertAllowedOrigin,
  callRpc,
  createAdminClient,
  errorResponse,
  handlePreflight,
  jsonResponse,
  RagError,
  readRequestBytesWithLimit,
  requireBackofficeAdmin,
} from "../_shared/rag/common.ts";
import {
  parseRuleAdminRequest,
  type RuleAdminRequest,
} from "../_shared/rag/rule-admin-contract.ts";
import { addRuleDisplayModel } from "../_shared/rag/rule-admin-presenter.ts";
import { simulateAdministrativeRuleSet } from "../_shared/rag/rule-admin-simulation.ts";

const FUNCTION_VERSION = "RAG-10.7-ADMIN-RULES-2026-08-03";
const MAX_JSON_BODY_BYTES = 65_536;

async function readBody(request: Request): Promise<RuleAdminRequest> {
  const contentType = (request.headers.get("content-type") ?? "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    throw new RagError("invalid_content_type", "Corps JSON requis.", 415);
  }
  const bytes = await readRequestBytesWithLimit(request, MAX_JSON_BODY_BYTES);
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new RagError("invalid_json", "Corps JSON invalide.", 400);
  }
  try {
    return parseRuleAdminRequest(parsed);
  } catch (error) {
    const code = error instanceof Error ? error.message : "invalid_request";
    throw new RagError(code, "Requête invalide.", 400);
  }
}

function httpStatus(code: string): number {
  if (code === "admin_unauthorized") return 403;
  if (code === "rule_set_not_found") return 404;
  if (code === "request_too_large") return 413;
  if (
    code === "revision_conflict" ||
    code === "status_conflict" ||
    code === "validated_rule_conflict" ||
    code === "validated_rule_immutable" ||
    code === "open_revision_exists" ||
    code === "idempotency_conflict" ||
    code === "document_not_eligible"
  ) return 409;
  return 400;
}

function userMessage(code: string): string {
  const messages: Record<string, string> = {
    admin_unauthorized: "Accès réservé aux administrateurs.",
    rule_set_not_found: "Règle introuvable.",
    revision_conflict: "Cette règle a été modifiée. Recharge-la avant de continuer.",
    status_conflict: "Cette action n’est plus permise pour le statut actuel.",
    validated_rule_conflict: "Une autre règle active existe déjà pour ce domaine.",
    validated_rule_immutable: "Une règle active ne peut pas être modifiée directement.",
    open_revision_exists: "Une révision ouverte existe déjà.",
    idempotency_conflict: "Cette opération a déjà été utilisée avec un autre contenu.",
    document_not_eligible: "Le document n’est pas prêt ou actif.",
    integrity_check_failed: "La règle contient encore des éléments à corriger.",
    invalid_rule_structure: "La structure de la règle est invalide.",
  };
  return messages[code] ?? "L’opération n’a pas pu être effectuée.";
}

function mutationRpc(request: RuleAdminRequest): {
  name: string;
  params: Record<string, unknown>;
} {
  const base = { p_rule_set_id: request.rule_set_id };
  if (request.action === "create_revision") {
    return { name: "create_rag_rule_revision_wrapper", params: base };
  }
  if (request.action === "save") {
    return {
      name: "save_rag_rule_set_correction_wrapper",
      params: {
        ...base,
        p_expected_revision_number: request.expected_revision_number,
        p_operation_id: request.operation_id,
        p_rules: request.rules,
      },
    };
  }
  if (request.action === "confirm") {
    return {
      name: "confirm_rag_rule_set_wrapper",
      params: {
        ...base,
        p_expected_revision_number: request.expected_revision_number,
        p_operation_id: request.operation_id,
        p_confirmation: true,
      },
    };
  }
  return {
    name: "reject_rag_rule_set_wrapper",
    params: {
      ...base,
      p_expected_revision_number: request.expected_revision_number,
      p_operation_id: request.operation_id,
      p_reason_code: request.reason_code,
      p_rejection_note: request.rejection_note ?? null,
    },
  };
}

Deno.serve(async (request: Request) => {
  const requestId = crypto.randomUUID();
  const startedAt = performance.now();
  const log = (event: string, detail: Record<string, unknown> = {}) => {
    console.log(JSON.stringify({
      requestId,
      functionVersion: FUNCTION_VERSION,
      event,
      durationMs: Math.round(performance.now() - startedAt),
      ...detail,
    }));
  };

  const preflight = handlePreflight(request);
  if (preflight) return preflight;
  if (request.method !== "POST") {
    return jsonResponse(request, { success: false, code: "method_not_allowed", request_id: requestId }, 405);
  }

  try {
    assertAllowedOrigin(request);
    const contentLength = Number(request.headers.get("content-length") ?? "0");
    if (Number.isFinite(contentLength) && contentLength > MAX_JSON_BODY_BYTES) {
      throw new RagError("request_too_large", "La requête est trop volumineuse.", 413);
    }
    const admin = createAdminClient();
    const identity = await requireBackofficeAdmin(request, admin);
    const body = await readBody(request);
    const auth = { p_auth_uid: identity.authUid };

    if (body.action === "list") {
      const result = await callRpc(admin, "list_rag_rule_sets_admin_wrapper", {
        ...auth,
        p_document_id: body.document_id ?? null,
        p_template_key: body.template_key ?? null,
        p_statuses: body.statuses ?? null,
        p_action_required: body.action_required ?? null,
        p_cursor: body.cursor ?? null,
        p_limit: body.limit ?? 25,
      });
      return jsonResponse(request, { ...result, request_id: requestId });
    }

    if (body.action === "detail" || body.action === "precheck" || body.action === "simulate") {
      const result = await callRpc(admin, "get_rag_rule_set_admin_wrapper", {
        ...auth,
        p_rule_set_id: body.rule_set_id,
      });
      if (result.success !== true) {
        const code = String(result.status_code ?? "detail_failed");
        return jsonResponse(request, { success: false, code, message: userMessage(code), request_id: requestId }, httpStatus(code));
      }
      if (body.action === "precheck") {
        return jsonResponse(request, {
          success: true,
          revision_number: result.revision_number,
          ...(result.integrity as Record<string, unknown>),
          request_id: requestId,
        });
      }
      if (body.action === "simulate") {
        const simulation = simulateAdministrativeRuleSet(
          result.rule_set,
          String(result.persisted_status ?? "unknown"),
          body.question!,
        );
        await callRpc(admin, "audit_rag_rule_simulation_wrapper", {
          ...auth,
          p_rule_set_id: body.rule_set_id,
          p_success: simulation.success,
          p_result_code: simulation.code,
          p_recognized_fact_count: simulation.recognized_fact_count ?? 0,
        });
        log("rule_simulated", { ruleSetId: body.rule_set_id, code: simulation.code });
        return jsonResponse(request, { ...simulation, request_id: requestId }, simulation.success ? 200 : 400);
      }
      const detail = addRuleDisplayModel(result.rule_set as Record<string, unknown>);
      return jsonResponse(request, {
        success: true,
        rule_set: detail,
        integrity: result.integrity,
        allowed_actions: result.allowed_actions,
        request_id: requestId,
      });
    }

    if (body.action === "history") {
      const result = await callRpc(admin, "get_rag_rule_audit_admin_wrapper", {
        ...auth,
        p_rule_set_id: body.rule_set_id ?? null,
        p_cursor: body.cursor ?? null,
        p_limit: body.limit ?? 25,
      });
      return jsonResponse(request, { ...result, request_id: requestId });
    }

    const rpc = mutationRpc(body);
    const result = await callRpc(admin, rpc.name, { ...auth, ...rpc.params });
    if (result.success !== true) {
      const code = String(result.status_code ?? `${body.action}_failed`);
      return jsonResponse(request, {
        success: false,
        code,
        message: userMessage(code),
        current_revision_number: result.current_revision_number ?? null,
        blocking_issues: result.blocking_issues ?? [],
        request_id: requestId,
      }, httpStatus(code));
    }
    log("rule_action_completed", {
      action: body.action,
      ruleSetId: body.rule_set_id,
      statusCode: result.status_code,
    });
    return jsonResponse(request, { ...result, request_id: requestId });
  } catch (error) {
    log("request_failed", { code: error instanceof RagError ? error.code : "unexpected_error" });
    const response = errorResponse(request, error);
    const body = await response.json();
    return jsonResponse(request, { ...body, request_id: requestId }, response.status);
  }
});
