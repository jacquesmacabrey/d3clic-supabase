import {
  assertAllowedOrigin,
  callRpc,
  createAdminClient,
  DOCX_MIME,
  errorResponse,
  handlePreflight,
  jsonResponse,
  MAX_FILE_BYTES,
  PDF_MIME,
  RAG_BUCKET,
  RagError,
  readRequestBytesWithLimit,
  requireBackofficeAdmin,
  sanitizeStorageFileName,
  sha256Hex,
} from "../_shared/rag/common.ts";

const FUNCTION_VERSION = "RAG-9-UPLOAD-2026-07-29";
const MAX_MULTIPART_BYTES = MAX_FILE_BYTES + 256 * 1024;

function requiredText(form: FormData, name: string, maxLength: number): string {
  const value = form.get(name);
  if (typeof value !== "string") {
    throw new RagError("invalid_form", `Champ ${name} manquant.`, 400);
  }
  const normalized = value.trim();
  if (!normalized || normalized.length > maxLength) {
    throw new RagError("invalid_form", `Champ ${name} invalide.`, 400);
  }
  return normalized;
}

function optionalDate(form: FormData): string | null {
  const value = form.get("effective_date");
  if (value === null || value === "") return null;
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new RagError(
      "invalid_effective_date",
      "Date d'entrée en vigueur invalide.",
      400,
    );
  }
  const parsed = new Date(`${value}T00:00:00Z`);
  if (
    Number.isNaN(parsed.getTime()) ||
    parsed.toISOString().slice(0, 10) !== value
  ) {
    throw new RagError(
      "invalid_effective_date",
      "Date d'entrée en vigueur invalide.",
      400,
    );
  }
  return value;
}

function fileKind(file: File): { mimeType: string; extension: string } {
  const name = file.name.toLowerCase();
  if (name.endsWith(".pdf")) {
    if (file.type && file.type !== PDF_MIME) {
      throw new RagError(
        "invalid_file_type",
        "Le type du fichier PDF est invalide.",
        415,
      );
    }
    return { mimeType: PDF_MIME, extension: ".pdf" };
  }
  if (name.endsWith(".docx")) {
    if (file.type && file.type !== DOCX_MIME) {
      throw new RagError(
        "invalid_file_type",
        "Le type du fichier Word est invalide.",
        415,
      );
    }
    return { mimeType: DOCX_MIME, extension: ".docx" };
  }
  throw new RagError(
    "invalid_file_type",
    "Seuls les fichiers PDF et Word .docx sont acceptés.",
    415,
  );
}

function assertFileSignature(bytes: Uint8Array, extension: string): void {
  if (extension === ".pdf") {
    const pdf = [0x25, 0x50, 0x44, 0x46, 0x2d];
    if (!pdf.every((value, index) => bytes[index] === value)) {
      throw new RagError(
        "invalid_pdf",
        "Le fichier ne contient pas un PDF valide.",
        415,
      );
    }
    return;
  }

  const isZip =
    bytes[0] === 0x50 &&
    bytes[1] === 0x4b &&
    ((bytes[2] === 0x03 && bytes[3] === 0x04) ||
      (bytes[2] === 0x05 && bytes[3] === 0x06) ||
      (bytes[2] === 0x07 && bytes[3] === 0x08));
  if (!isZip) {
    throw new RagError(
      "invalid_docx",
      "Le fichier ne contient pas un document Word .docx valide.",
      415,
    );
  }
}

function statusFor(code: string): number {
  if (code === "admin_unauthorized") return 403;
  if (code === "duplicate_file" || code === "version_already_exists") {
    return 409;
  }
  if (code === "upload_rate_limited") return 429;
  if (code === "source_file_missing") return 500;
  return 400;
}

function messageFor(code: string): string {
  const messages: Record<string, string> = {
    duplicate_file: "Ce fichier a déjà été déposé.",
    version_already_exists: "Cette version existe déjà pour ce document.",
    upload_rate_limited:
      "Trop de documents ont été déposés. Réessaie plus tard.",
    document_conflict:
      "Le document entre en conflit avec une version existante.",
    invalid_storage_path: "Le chemin de stockage du document est invalide.",
    source_metadata_mismatch:
      "Les métadonnées du fichier ne correspondent pas au dépôt.",
  };
  return messages[code] ?? "Le document n'a pas pu être enregistré.";
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

  let uploadedPath: string | null = null;
  let admin: ReturnType<typeof createAdminClient> | null = null;

  try {
    assertAllowedOrigin(request);
    const contentType = request.headers.get("content-type") ?? "";
    if (!contentType.toLowerCase().startsWith("multipart/form-data;")) {
      throw new RagError(
        "invalid_content_type",
        "Formulaire multipart requis.",
        415,
      );
    }

    const contentLength = Number(request.headers.get("content-length") ?? "0");
    if (Number.isFinite(contentLength) && contentLength > MAX_MULTIPART_BYTES) {
      throw new RagError(
        "request_too_large",
        "Le fichier dépasse la limite de 20 Mo.",
        413,
      );
    }

    admin = createAdminClient();
    const identity = await requireBackofficeAdmin(request, admin);
    const body = await readRequestBytesWithLimit(request, MAX_MULTIPART_BYTES);
    const parsedRequest = new Request(request.url, {
      method: "POST",
      headers: request.headers,
      body,
    });

    let form: FormData;
    try {
      form = await parsedRequest.formData();
    } catch {
      throw new RagError(
        "invalid_multipart",
        "Le formulaire de dépôt est invalide.",
        400,
      );
    }

    const documentKey = requiredText(form, "document_key", 120);
    if (!/^[a-z0-9][a-z0-9_-]{0,119}$/.test(documentKey)) {
      throw new RagError(
        "invalid_document_key",
        "La clé documentaire est invalide.",
        400,
      );
    }

    const title = requiredText(form, "title", 250);
    const category = requiredText(form, "category", 100);
    const versionLabel = requiredText(form, "version_label", 50);
    const effectiveDate = optionalDate(form);
    const fileEntry = form.get("file");
    if (!(fileEntry instanceof File)) {
      throw new RagError("file_missing", "Fichier manquant.", 400);
    }
    if (fileEntry.size < 1 || fileEntry.size > MAX_FILE_BYTES) {
      throw new RagError(
        "invalid_file_size",
        "Le fichier doit peser au maximum 20 Mo.",
        413,
      );
    }

    const { mimeType, extension } = fileKind(fileEntry);
    const bytes = new Uint8Array(await fileEntry.arrayBuffer());
    assertFileSignature(bytes, extension);
    const fileSha256 = await sha256Hex(bytes);
    const documentId = crypto.randomUUID();
    const safeName = sanitizeStorageFileName(fileEntry.name);
    uploadedPath = `${identity.institutionId}/${documentId}/${safeName}`;

    const { error: uploadError } = await admin.storage
      .from(RAG_BUCKET)
      .upload(uploadedPath, bytes, {
        contentType: mimeType,
        upsert: false,
        cacheControl: "3600",
      });
    if (uploadError) {
      log("storage_upload_failed", { storageCode: uploadError.name });
      throw new RagError(
        "storage_upload_failed",
        "Le fichier n'a pas pu être enregistré.",
        502,
      );
    }

    const result = await callRpc(admin, "register_rag_document_wrapper", {
      p_auth_uid: identity.authUid,
      p_document_id: documentId,
      p_document_key: documentKey,
      p_title: title,
      p_category: category,
      p_version_label: versionLabel,
      p_effective_date: effectiveDate,
      p_storage_path: uploadedPath,
      p_original_file_name: fileEntry.name.slice(0, 255),
      p_mime_type: mimeType,
      p_file_size_bytes: fileEntry.size,
      p_file_sha256: fileSha256,
    });

    if (result.success !== true) {
      const code = String(result.status_code ?? "registration_failed");
      await admin.storage.from(RAG_BUCKET).remove([uploadedPath]);
      uploadedPath = null;
      return jsonResponse(
        request,
        {
          success: false,
          code,
          message: messageFor(code),
          existing_document_id: result.existing_document_id ?? null,
        },
        statusFor(code),
      );
    }

    log("document_registered", {
      documentId,
      jobId: result.job_id,
      fileSizeBytes: fileEntry.size,
    });
    uploadedPath = null;
    return jsonResponse(
      request,
      {
        success: true,
        status: "queued",
        document_id: documentId,
        job_id: result.job_id,
      },
      201,
    );
  } catch (error) {
    if (uploadedPath && admin) {
      try {
        await admin.storage.from(RAG_BUCKET).remove([uploadedPath]);
      } catch {
        log("orphan_cleanup_failed");
      }
    }
    log("request_failed", {
      code: error instanceof RagError ? error.code : "unexpected_error",
    });
    return errorResponse(request, error);
  }
});
