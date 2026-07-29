import {
  assertAllowedOrigin,
  callRpc,
  createAdminClient,
  errorResponse,
  handlePreflight,
  isUuid,
  jsonResponse,
  RAG_BUCKET,
  RagError,
  readRequestBytesWithLimit,
  requireBackofficeAdmin,
} from "../_shared/rag/common.ts";

const FUNCTION_VERSION = "RAG-9-ADMIN-DOCUMENTS-2026-07-29";
const MAX_JSON_BODY_BYTES = 4_096;

type Action = "list" | "activate" | "deactivate" | "delete";

async function readJson(request: Request): Promise<Record<string, unknown>> {
  const contentType = (request.headers.get("content-type") ?? "")
    .split(";", 1)[0]
    .trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    throw new RagError("invalid_content_type", "Corps JSON requis.", 415);
  }

  const bytes = await readRequestBytesWithLimit(request, MAX_JSON_BODY_BYTES);
  try {
    const parsed = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(bytes),
    );
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      return parsed as Record<string, unknown>;
    }
  } catch {
    // Réponse uniforme ci-dessous.
  }
  throw new RagError("invalid_json", "Corps JSON invalide.", 400);
}

function readAction(body: Record<string, unknown>): Action {
  const action = body.action;
  if (
    action === "list" ||
    action === "activate" ||
    action === "deactivate" ||
    action === "delete"
  ) {
    return action;
  }
  throw new RagError("invalid_action", "Action invalide.", 400);
}

function readDocumentId(body: Record<string, unknown>): string {
  if (!isUuid(body.document_id)) {
    throw new RagError(
      "invalid_document_id",
      "Identifiant de document invalide.",
      400,
    );
  }
  return body.document_id;
}

function messageFor(code: string): string {
  const messages: Record<string, string> = {
    admin_unauthorized: "Accès réservé aux administrateurs.",
    document_not_found: "Document introuvable.",
    document_not_ready: "Ce document n'est pas prêt à être activé.",
    document_not_active: "Seul un document actif peut être désactivé.",
    extraction_incomplete: "L'extraction du document est incomplète.",
    ingestion_in_progress: "Le traitement du document est encore en cours.",
    no_passages: "Aucun passage exploitable n'a été créé.",
    embeddings_incomplete: "L'indexation du document est incomplète.",
    source_file_missing: "Le fichier source est introuvable.",
    delete_confirmation_required:
      "La suppression définitive doit être confirmée.",
    active_confirmation_required:
      "Le titre exact du document actif doit être confirmé.",
  };
  return messages[code] ?? "L'opération n'a pas pu être effectuée.";
}

function statusFor(code: string): number {
  if (code === "admin_unauthorized") return 403;
  if (code === "document_not_found") return 404;
  if (
    code === "document_not_ready" ||
    code === "document_not_active" ||
    code === "ingestion_in_progress" ||
    code === "active_confirmation_required"
  ) {
    return 409;
  }
  return 400;
}

Deno.serve(async (request: Request) => {
  const requestId = crypto.randomUUID();
  const startedAt = performance.now();
  const log = (event: string, detail: Record<string, unknown> = {}) => {
    console.log(
      JSON.stringify({
        requestId,
        functionVersion: FUNCTION_VERSION,
        event,
        durationMs: Math.round(performance.now() - startedAt),
        ...detail,
      }),
    );
  };

  const preflight = handlePreflight(request);
  if (preflight) return preflight;

  if (request.method !== "POST") {
    return jsonResponse(
      request,
      { success: false, code: "method_not_allowed" },
      405,
    );
  }

  try {
    assertAllowedOrigin(request);
    const contentLength = Number(request.headers.get("content-length") ?? "0");
    if (Number.isFinite(contentLength) && contentLength > MAX_JSON_BODY_BYTES) {
      throw new RagError(
        "request_too_large",
        "La requête est trop volumineuse.",
        413,
      );
    }

    const admin = createAdminClient();
    const identity = await requireBackofficeAdmin(request, admin);
    const body = await readJson(request);
    const action = readAction(body);

    if (action === "list") {
      const result = await callRpc(admin, "list_rag_documents_wrapper", {
        p_auth_uid: identity.authUid,
      });
      if (result.success !== true) {
        const code = String(result.status_code ?? "list_failed");
        return jsonResponse(
          request,
          { success: false, code, message: messageFor(code) },
          statusFor(code),
        );
      }
      return jsonResponse(request, {
        success: true,
        documents: result.documents ?? [],
      });
    }

    const documentId = readDocumentId(body);
    const rpc =
      action === "activate"
        ? "activate_rag_document_wrapper"
        : action === "deactivate"
          ? "deactivate_rag_document_wrapper"
          : "delete_rag_document_wrapper";
    const params: Record<string, unknown> = {
      p_auth_uid: identity.authUid,
      p_document_id: documentId,
    };

    if (action === "delete") {
      params.p_confirm_delete = body.confirm_delete === true;
      params.p_confirmation_title =
        typeof body.confirmation_title === "string"
          ? body.confirmation_title.trim().slice(0, 250)
          : null;
    }

    const result = await callRpc(admin, rpc, params);
    if (result.success !== true) {
      const code = String(result.status_code ?? `${action}_failed`);
      return jsonResponse(
        request,
        {
          success: false,
          code,
          message: messageFor(code),
          confirmation_title: result.confirmation_title ?? null,
          current_status: result.current_status ?? null,
        },
        statusFor(code),
      );
    }

    let storageCleanupPending = false;
    if (action === "delete") {
      const storagePath = result.storage_path;
      const expectedPrefix = `${identity.institutionId}/${documentId}/`;
      if (
        typeof storagePath !== "string" ||
        !storagePath.startsWith(expectedPrefix)
      ) {
        log("invalid_delete_storage_path", { documentId });
        storageCleanupPending = true;
      } else {
        const { error } = await admin.storage
          .from(RAG_BUCKET)
          .remove([storagePath]);
        if (error) {
          storageCleanupPending = true;
          log("storage_cleanup_failed", {
            documentId,
            storageCode: error.name,
          });
        }
      }
    }

    log("document_action_completed", {
      action,
      documentId,
      statusCode: result.status_code,
      storageCleanupPending,
    });
    return jsonResponse(request, {
      success: true,
      status: result.status_code,
      document_id: documentId,
      obsoleted_document_ids: result.obsoleted_document_ids ?? [],
      storage_cleanup_pending: storageCleanupPending,
    });
  } catch (error) {
    log("request_failed", {
      code: error instanceof RagError ? error.code : "unexpected_error",
    });
    return errorResponse(request, error);
  }
});
