import type { SupabaseClient } from "npm:@supabase/supabase-js@2.110.6";
import {
  assertAllowedOrigin,
  type BackofficeIdentity,
  callRpc,
  compactErrorCode,
  compactErrorMessage,
  createAdminClient,
  errorResponse,
  handlePreflight,
  isUuid,
  jsonResponse,
  RAG_BUCKET,
  RagError,
  readRequestBytesWithLimit,
  requireBackofficeAdmin,
  sha256Text,
} from "../_shared/rag/common.ts";
import { extractDocument } from "../_shared/rag/extract.ts";
import { chunkDocument, type PassageDraft } from "../_shared/rag/chunk.ts";
import {
  EMBEDDING_BATCH_SIZE,
  EMBEDDING_DIMENSIONS,
  EMBEDDING_MODEL,
  embedTexts,
  vectorLiteral,
} from "../_shared/rag/embeddings.ts";

const FUNCTION_VERSION = "RAG-2-PROCESS-AUDIT-2026-07-23";
const MAX_JSON_BODY_BYTES = 4_096;

interface StartedJob {
  jobId: string;
  documentId: string;
  workerId: string;
  storagePath: string;
  mimeType: string;
  title: string;
}

interface EdgeRuntimeApi {
  waitUntil(promise: Promise<unknown>): void;
}

function edgeRuntime(): EdgeRuntimeApi | null {
  const candidate = (globalThis as unknown as { EdgeRuntime?: EdgeRuntimeApi })
    .EdgeRuntime;
  return candidate?.waitUntil ? candidate : null;
}

async function downloadSource(
  admin: SupabaseClient,
  storagePath: string,
): Promise<Uint8Array> {
  const { data, error } = await admin.storage
    .from(RAG_BUCKET)
    .download(storagePath);
  if (error || !data) {
    throw new RagError(
      "source_download_failed",
      "Le fichier source n'a pas pu être téléchargé.",
      502,
    );
  }
  return new Uint8Array(await data.arrayBuffer());
}

async function passagePayload(
  drafts: PassageDraft[],
  vectors: number[][],
): Promise<Record<string, unknown>[]> {
  if (drafts.length !== vectors.length) {
    throw new RagError(
      "embedding_count_mismatch",
      "Le nombre d'embeddings ne correspond pas aux passages.",
      502,
    );
  }
  const hashes = await Promise.all(
    drafts.map((draft) => sha256Text(draft.content)),
  );
  return drafts.map((draft, index) => ({
    chunk_index: draft.chunkIndex,
    content: draft.content,
    content_sha256: hashes[index],
    page_start: draft.pageStart,
    page_end: draft.pageEnd,
    section_title: draft.sectionTitle,
    article_reference: draft.articleReference,
    source_reference: draft.sourceReference,
    embedding: vectorLiteral(vectors[index]),
    metadata: draft.metadata,
  }));
}

async function runIngestion(
  admin: SupabaseClient,
  identity: BackofficeIdentity,
  job: StartedJob,
  log: (event: string, detail?: Record<string, unknown>) => void,
): Promise<void> {
  try {
    const bytes = await downloadSource(admin, job.storagePath);
    const extracted = await extractDocument(bytes, job.mimeType);
    const drafts = chunkDocument(extracted, job.title);

    const plan = await callRpc(admin, "set_rag_ingestion_plan_wrapper", {
      p_auth_uid: identity.authUid,
      p_job_id: job.jobId,
      p_worker_id: job.workerId,
      p_total_items: drafts.length,
    });
    if (plan.success !== true) {
      throw new RagError(
        String(plan.status_code ?? "plan_failed"),
        "Le plan d'ingestion n'a pas pu être enregistré.",
        500,
      );
    }

    for (
      let offset = 0;
      offset < drafts.length;
      offset += EMBEDDING_BATCH_SIZE
    ) {
      const batch = drafts.slice(offset, offset + EMBEDDING_BATCH_SIZE);
      const vectors = await embedTexts(batch.map((draft) => draft.content));
      const payload = await passagePayload(batch, vectors);
      const saved = await callRpc(
        admin,
        "append_rag_passage_batch_wrapper",
        {
          p_auth_uid: identity.authUid,
          p_job_id: job.jobId,
          p_worker_id: job.workerId,
          p_passages: payload,
        },
      );
      if (saved.success !== true) {
        throw new RagError(
          String(saved.status_code ?? "batch_save_failed"),
          "Un lot de passages n'a pas pu être enregistré.",
          500,
        );
      }
      log("batch_saved", {
        jobId: job.jobId,
        processedItems: saved.processed_items,
        totalItems: drafts.length,
      });
    }

    const completed = await callRpc(
      admin,
      "complete_rag_ingestion_wrapper",
      {
        p_auth_uid: identity.authUid,
        p_job_id: job.jobId,
        p_worker_id: job.workerId,
        p_extraction_method: extracted.extractionMethod,
        p_extraction_version: extracted.extractionVersion,
        p_page_count: extracted.pageCount,
        p_extraction_metadata: {
          character_count: extracted.characterCount,
          passage_count: drafts.length,
          embedding_model: EMBEDDING_MODEL,
          embedding_dimensions: EMBEDDING_DIMENSIONS,
          chunk_target_characters: 4000,
          chunk_overlap_characters: 500,
          ocr_used: false,
        },
      },
    );
    if (completed.success !== true) {
      throw new RagError(
        String(completed.status_code ?? "completion_failed"),
        "L'ingestion n'a pas pu être finalisée.",
        500,
      );
    }
    log("ingestion_ready", {
      documentId: job.documentId,
      jobId: job.jobId,
      passageCount: drafts.length,
    });
  } catch (error) {
    log("ingestion_failed", {
      documentId: job.documentId,
      jobId: job.jobId,
      code: compactErrorCode(error),
    });
    try {
      await callRpc(admin, "fail_rag_ingestion_wrapper", {
        p_auth_uid: identity.authUid,
        p_job_id: job.jobId,
        p_worker_id: job.workerId,
        p_error_code: compactErrorCode(error),
        p_error_message: compactErrorMessage(error),
      });
    } catch {
      log("failure_persistence_failed", { jobId: job.jobId });
    }
  }
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
    return jsonResponse(
      request,
      { success: false, code: "method_not_allowed" },
      405,
    );
  }

  try {
    assertAllowedOrigin(request);
    const contentLength = Number(request.headers.get("content-length") ?? "0");
    if (
      Number.isFinite(contentLength) &&
      contentLength > MAX_JSON_BODY_BYTES
    ) {
      throw new RagError(
        "request_too_large",
        "La requête est trop volumineuse.",
        413,
      );
    }

    const contentType = (request.headers.get("content-type") ?? "")
      .split(";", 1)[0]
      .trim()
      .toLowerCase();
    if (contentType !== "application/json") {
      throw new RagError(
        "invalid_content_type",
        "Corps JSON requis.",
        415,
      );
    }

    const admin = createAdminClient();
    const identity = await requireBackofficeAdmin(request, admin);
    const bodyBytes = await readRequestBytesWithLimit(
      request,
      MAX_JSON_BODY_BYTES,
    );
    let body: Record<string, unknown> | null = null;
    try {
      const parsed = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(bodyBytes),
      );
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        body = parsed as Record<string, unknown>;
      }
    } catch {
      body = null;
    }
    if (!body) {
      throw new RagError("invalid_json", "Corps JSON invalide.", 400);
    }
    const documentId = body?.document_id;
    if (!isUuid(documentId)) {
      throw new RagError(
        "invalid_document_id",
        "Identifiant de document invalide.",
        400,
      );
    }

    const workerId = `rag-process:${requestId}`;
    const start = await callRpc(admin, "start_rag_ingestion_wrapper", {
      p_auth_uid: identity.authUid,
      p_document_id: documentId,
      p_worker_id: workerId,
    });

    if (start.status_code === "already_ready" && start.success === true) {
      return jsonResponse(request, {
        success: true,
        status: "ready",
        document_id: documentId,
      });
    }
    if (start.status_code === "already_processing") {
      return jsonResponse(
        request,
        {
          success: true,
          status: "processing",
          document_id: documentId,
        },
        202,
      );
    }
    if (start.success !== true || start.status_code !== "started") {
      const code = String(start.status_code ?? "ingestion_start_failed");
      const status = code === "document_not_found"
        ? 404
        : code === "admin_unauthorized"
        ? 403
        : code === "retry_exhausted" ||
            code === "job_cancelled" ||
            code === "document_obsolete"
        ? 409
        : 400;
      throw new RagError(
        code,
        code === "retry_exhausted"
          ? "Le nombre maximal de tentatives est atteint."
          : "L'ingestion ne peut pas démarrer.",
        status,
      );
    }

    const jobId = start.job_id;
    const storagePath = start.storage_path;
    const mimeType = start.mime_type;
    const title = start.title;
    if (
      !isUuid(jobId) ||
      typeof storagePath !== "string" ||
      typeof mimeType !== "string" ||
      typeof title !== "string"
    ) {
      throw new RagError(
        "invalid_backend_response",
        "Le serveur a renvoyé un job invalide.",
        500,
      );
    }

    const job: StartedJob = {
      jobId,
      documentId,
      workerId,
      storagePath,
      mimeType,
      title,
    };
    const task = runIngestion(admin, identity, job, log);
    const runtime = edgeRuntime();
    if (runtime) {
      runtime.waitUntil(task);
    } else {
      await task;
    }

    log("ingestion_accepted", { documentId, jobId });
    return jsonResponse(
      request,
      {
        success: true,
        status: "processing",
        document_id: documentId,
        job_id: jobId,
      },
      202,
    );
  } catch (error) {
    log("request_failed", {
      code: error instanceof RagError ? error.code : "unexpected_error",
    });
    return errorResponse(request, error);
  }
});
