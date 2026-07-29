import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.110.6";
import { RagError } from "./errors.ts";

export { RagError } from "./errors.ts";

export const RAG_BUCKET = "rag-documents";
export const PDF_MIME = "application/pdf";
export const DOCX_MIME =
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
export const MAX_FILE_BYTES = 20 * 1024 * 1024;

const CLIENT_OPTIONS = {
  autoRefreshToken: false,
  persistSession: false,
  detectSessionInUrl: false,
};

export interface BackofficeIdentity {
  authUid: string;
  adminUserUuid: string;
  institutionId: string;
  jwt: string;
}

export interface RpcResult {
  success?: boolean;
  status_code?: string;
  [key: string]: unknown;
}

function resolvePublishableKey(): string | undefined {
  const keysJson = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (keysJson) {
    try {
      const parsed = JSON.parse(keysJson);
      if (
        parsed &&
        typeof parsed === "object" &&
        typeof parsed.default === "string"
      ) {
        return parsed.default;
      }
    } catch {
      // Repli volontaire, sans journaliser le secret ni son contenu.
    }
  }
  return Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
    Deno.env.get("SUPABASE_ANON_KEY") ?? undefined;
}

function resolveSecretKey(): string | undefined {
  const keysJson = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (keysJson) {
    try {
      const parsed = JSON.parse(keysJson);
      if (
        parsed &&
        typeof parsed === "object" &&
        typeof parsed.default === "string"
      ) {
        return parsed.default;
      }
    } catch {
      // Repli volontaire, sans journaliser le secret ni son contenu.
    }
  }
  return Deno.env.get("SUPABASE_SECRET_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? undefined;
}

export function createAdminClient(): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const secretKey = resolveSecretKey();
  if (!url || !secretKey) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }
  return createClient(url, secretKey, { auth: CLIENT_OPTIONS });
}

function createAuthClient(jwt: string): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL");
  const publishableKey = resolvePublishableKey();
  if (!url || !publishableKey) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }
  return createClient(url, publishableKey, {
    auth: CLIENT_OPTIONS,
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
}

export async function requireBackofficeAdmin(
  request: Request,
  admin: SupabaseClient,
): Promise<BackofficeIdentity> {
  const authHeader = request.headers.get("authorization");
  const match = authHeader?.match(/^Bearer\s+(.+)$/i);
  const jwt = match?.[1]?.trim() ?? "";
  if (!jwt) {
    throw new RagError("unauthorized", "Authentification requise.", 401);
  }

  const authClient = createAuthClient(jwt);
  const { data: userData, error: userError } = await authClient.auth.getUser(
    jwt,
  );
  const authUid = userData?.user?.id;
  if (userError || !authUid) {
    throw new RagError(
      "unauthorized",
      "Session invalide ou expirée.",
      401,
    );
  }

  const { data, error } = await admin.rpc("check_backoffice_role_wrapper", {
    p_auth_uid: authUid,
    p_required_role: "admin",
  });
  if (error) {
    throw new RagError(
      "authorization_failed",
      "Impossible de vérifier les droits.",
      500,
    );
  }

  const row = Array.isArray(data) ? data[0] : data;
  const identity = (row ?? {}) as {
    authorized?: boolean;
    user_uuid?: string;
    institution_id?: string;
  };
  if (
    identity.authorized !== true ||
    typeof identity.user_uuid !== "string" ||
    typeof identity.institution_id !== "string"
  ) {
    throw new RagError(
      "forbidden",
      "Accès réservé aux administrateurs.",
      403,
    );
  }

  return {
    authUid,
    adminUserUuid: identity.user_uuid,
    institutionId: identity.institution_id,
    jwt,
  };
}

function allowedOrigins(): Set<string> {
  return new Set(
    (Deno.env.get("ALLOWED_ORIGINS") ?? "")
      .split(",")
      .map((value) => value.trim())
      .filter(Boolean),
  );
}

export function corsHeaders(request: Request): Record<string, string> {
  const origin = request.headers.get("origin");
  const allowed = origin !== null && allowedOrigins().has(origin);
  const headers: Record<string, string> = {
    "Vary": "Origin",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  };
  if (allowed && origin) headers["Access-Control-Allow-Origin"] = origin;
  return headers;
}

export function handlePreflight(request: Request): Response | null {
  if (request.method !== "OPTIONS") return null;
  const origin = request.headers.get("origin");
  if (!origin || !allowedOrigins().has(origin)) {
    return new Response(null, {
      status: 403,
      headers: secureHeaders(),
    });
  }
  return new Response(null, {
    status: 204,
    headers: { ...secureHeaders(), ...corsHeaders(request) },
  });
}

export function assertAllowedOrigin(request: Request): void {
  const origin = request.headers.get("origin");
  if (origin !== null && !allowedOrigins().has(origin)) {
    throw new RagError("forbidden_origin", "Origine non autorisée.", 403);
  }
}

function secureHeaders(): Record<string, string> {
  return {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  };
}

export function jsonResponse(
  request: Request,
  body: unknown,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...secureHeaders(),
      ...corsHeaders(request),
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

export function errorResponse(request: Request, error: unknown): Response {
  if (error instanceof RagError) {
    return jsonResponse(
      request,
      { success: false, code: error.code, message: error.message },
      error.status,
    );
  }
  return jsonResponse(
    request,
    {
      success: false,
      code: "unexpected_error",
      message: "Une erreur inattendue est survenue.",
    },
    500,
  );
}

export async function readRequestBytesWithLimit(
  request: Request,
  maxBytes: number,
): Promise<Uint8Array<ArrayBuffer>> {
  if (!request.body) return new Uint8Array();

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value) continue;

      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel("request_too_large");
        throw new RagError(
          "request_too_large",
          "La requête dépasse la taille autorisée.",
          413,
        );
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }

  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

export async function callRpc(
  admin: SupabaseClient,
  name: string,
  params: Record<string, unknown>,
): Promise<RpcResult> {
  const { data, error } = await admin.rpc(name, params);
  if (error) {
    console.error(JSON.stringify({
      event: "rpc_failed",
      rpc: name,
      dbCode: error.code ?? null,
    }));
    throw new RagError(
      "database_error",
      "L'opération n'a pas pu être enregistrée.",
      500,
    );
  }
  const result = (Array.isArray(data) ? data[0] : data) as RpcResult | null;
  if (!result || typeof result !== "object") {
    throw new RagError(
      "invalid_backend_response",
      "Réponse serveur invalide.",
      500,
    );
  }
  return result;
}

export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  const digest = await crypto.subtle.digest("SHA-256", copy.buffer);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function sha256Text(text: string): Promise<string> {
  return sha256Hex(new TextEncoder().encode(text));
}

export function sanitizeStorageFileName(fileName: string): string {
  const base = fileName.split(/[\\/]/).pop() ?? "document";
  const extension = base.toLowerCase().endsWith(".pdf") ? ".pdf" : ".docx";
  const withoutExtension = base.replace(/\.(pdf|docx)$/i, "");
  const normalized = withoutExtension
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 100);
  return `${normalized || "document"}${extension}`;
}

export function isUuid(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(value);
}

export function compactErrorMessage(error: unknown): string {
  if (error instanceof RagError) return error.message.slice(0, 1000);
  return "Le traitement a été interrompu.";
}

export function compactErrorCode(error: unknown): string {
  return error instanceof RagError
    ? error.code.slice(0, 120)
    : "unexpected_error";
}
