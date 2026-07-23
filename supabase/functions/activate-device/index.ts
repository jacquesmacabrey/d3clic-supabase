// ============================================================
// activate-device — Edge Function, staging D3clic
//
// verify_jwt = false (voir config.toml) : la sécurité repose sur
// la vérification RÉELLE du JWT ci-dessous (auth.getUser), jamais
// sur ce réglage de plateforme.
// ============================================================

import { createClient } from "npm:@supabase/supabase-js@2.110.6";

const MAX_BODY_BYTES = 4096;
const CLIENT_SUPPLIED_IDENTITY_FIELDS = ["device_auth_uid", "user_uuid", "institution_id"];

function resolvePublishableKey(): string | undefined {
  const keysJson = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (keysJson) {
    try {
      const parsed = JSON.parse(keysJson);
      if (parsed && typeof parsed === "object" && typeof parsed.default === "string") {
        return parsed.default;
      }
    } catch {
      // Parsing invalide : repli silencieux, jamais de log du contenu.
    }
  }
  const single = Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (single) return single;
  return Deno.env.get("SUPABASE_ANON_KEY");
}

function resolveSecretKey(): string | undefined {
  const keysJson = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (keysJson) {
    try {
      const parsed = JSON.parse(keysJson);
      if (parsed && typeof parsed === "object" && typeof parsed.default === "string") {
        return parsed.default;
      }
    } catch {
      // idem
    }
  }
  const single = Deno.env.get("SUPABASE_SECRET_KEY");
  if (single) return single;
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
}

function jsonHeaders(extra: Record<string, string> = {}): Record<string, string> {
  return {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    ...extra,
  };
}

function genericFailure(): { success: false; message: string } {
  return { success: false, message: "Activation impossible." };
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function hmacSha256Hex(secret: string, input: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(input));
  return [...new Uint8Array(signature)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function extractClientIp(req: Request): string | null {
  const forwardedFor = req.headers.get("x-forwarded-for");
  if (forwardedFor) return forwardedFor.split(",")[0].trim();
  return null;
}

async function readBodyWithLimit(req: Request, maxBytes: number): Promise<string | null> {
  if (!req.body) return null;

  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;

    if (value) {
      total += value.byteLength;

      if (total > maxBytes) {
        await reader.cancel();
        throw new Error("body_too_large");
      }

      chunks.push(value);
    }
  }

  if (total === 0) return null;

  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return new TextDecoder().decode(merged);
}

const SUPABASE_CLIENT_AUTH_OPTIONS = {
  autoRefreshToken: false,
  persistSession: false,
  detectSessionInUrl: false,
};

// NORMALISATION DU CODE MANUEL — DOIT rester identique, caractère
// pour caractère, à celle utilisée dans run-bloc6b-tests.mjs pour le
// calcul du HMAC de test, sinon les hashes ne correspondront jamais.
function normalizeManualCode(code: string): string {
  return code.trim().toUpperCase().replace(/[\s-]/g, "");
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  const startedAt = performance.now();

  function log(event: string, detail: Record<string, unknown> = {}) {
    // Jamais : JWT, token brut, code manuel, hash complet,
    // service_role key, IP brute, donnée personnelle.
    console.log(
      JSON.stringify({
        requestId,
        event,
        durationMs: Math.round(performance.now() - startedAt),
        ...detail,
      })
    );
  }

  const origin = req.headers.get("origin");
  const allowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const corsAllowed = origin !== null && allowedOrigins.includes(origin);

  const corsHeaders: Record<string, string> = { Vary: "Origin" };
  if (corsAllowed) {
    corsHeaders["Access-Control-Allow-Origin"] = origin!;
    corsHeaders["Access-Control-Allow-Methods"] = "POST, OPTIONS";
    corsHeaders["Access-Control-Allow-Headers"] =
      "authorization, x-client-info, apikey, content-type";
  }

  if (req.method === "OPTIONS") {
    if (!corsAllowed) {
      log("cors_preflight_rejected");
      return new Response(null, { status: 403, headers: jsonHeaders() });
    }
    log("cors_preflight_ok");
    return new Response(null, { status: 204, headers: jsonHeaders(corsHeaders) });
  }

  if (req.method !== "POST") {
    log("method_not_allowed", { method: req.method });
    return new Response(JSON.stringify(genericFailure()), {
      status: 405,
      headers: jsonHeaders(corsHeaders),
    });
  }

  if (origin !== null && !corsAllowed) {
    log("cors_origin_rejected");
    return new Response(JSON.stringify({ success: false, message: "Origine non autorisée." }), {
      status: 403,
      headers: jsonHeaders(),
    });
  }

  function respond(body: unknown, status: number): Response {
    return new Response(JSON.stringify(body), { status, headers: jsonHeaders(corsHeaders) });
  }

  try {
    const contentLength = req.headers.get("content-length");
    if (contentLength && Number(contentLength) > MAX_BODY_BYTES) {
      log("body_too_large_header");
      return respond(genericFailure(), 400);
    }

    const authHeader = req.headers.get("authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      log("missing_authorization");
      return respond(genericFailure(), 401);
    }
    const jwt = authHeader.slice("Bearer ".length).trim();
    if (jwt.length === 0) {
      log("empty_authorization");
      return respond(genericFailure(), 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const publishableKey = resolvePublishableKey();
    const secretKey = resolveSecretKey();
    const ipHmacSecret = Deno.env.get("ACTIVATION_IP_HMAC_SECRET");

    if (!supabaseUrl || !publishableKey || !secretKey) {
      log("missing_supabase_config");
      return respond(genericFailure(), 500);
    }

    if (!ipHmacSecret) {
      log("missing_secret_config", { which: "ACTIVATION_IP_HMAC_SECRET" });
      return respond(genericFailure(), 500);
    }

    const authClient = createClient(supabaseUrl, publishableKey, {
      auth: SUPABASE_CLIENT_AUTH_OPTIONS,
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });

    const { data: userData, error: userError } = await authClient.auth.getUser(jwt);

    if (userError || !userData?.user?.id) {
      log("invalid_or_expired_jwt");
      return respond(genericFailure(), 401);
    }

    const deviceAuthUid = userData.user.id;

    let rawBody: string | null;
    try {
      rawBody = await readBodyWithLimit(req, MAX_BODY_BYTES);
    } catch {
      log("body_too_large_stream");
      return respond(genericFailure(), 400);
    }

    if (!rawBody) {
      log("empty_body");
      return respond(genericFailure(), 400);
    }

    let body: unknown;
    try {
      body = JSON.parse(rawBody);
    } catch {
      log("invalid_json_body");
      return respond(genericFailure(), 400);
    }

    if (typeof body !== "object" || body === null) {
      log("invalid_json_body");
      return respond(genericFailure(), 400);
    }

    for (const field of CLIENT_SUPPLIED_IDENTITY_FIELDS) {
      if (field in (body as Record<string, unknown>)) {
        log("identity_field_rejected", { field });
        return respond(genericFailure(), 400);
      }
    }

    const { method, token, code } = body as Record<string, unknown>;

    if (method !== "qr" && method !== "manual_code" && method !== "mcp") {
      log("invalid_method");
      return respond(genericFailure(), 400);
    }

    let rawSecret: string;

    if (method === "qr" || method === "mcp") {
      if (typeof token !== "string" || token.length === 0) {
        log("missing_token");
        return respond(genericFailure(), 400);
      }
      rawSecret = token;
    } else {
      if (typeof code !== "string" || code.length === 0) {
        log("missing_code");
        return respond(genericFailure(), 400);
      }
      rawSecret = normalizeManualCode(code);
      if (rawSecret.length === 0 || rawSecret.length > 64) {
        log("invalid_code_format");
        return respond(genericFailure(), 400);
      }
    }

    let tokenHash: string;

    if (method === "qr" || method === "mcp") {
      tokenHash = await sha256Hex(rawSecret);
    } else {
      const codeSecret = Deno.env.get("ACTIVATION_CODE_HMAC_SECRET");
      if (!codeSecret) {
        log("missing_secret_config", { which: "ACTIVATION_CODE_HMAC_SECRET" });
        return respond(genericFailure(), 500);
      }
      tokenHash = await hmacSha256Hex(codeSecret, rawSecret);
    }

    let ipHash: string | null = null;
    const clientIp = extractClientIp(req);
    if (clientIp) {
      ipHash = await hmacSha256Hex(ipHmacSecret, clientIp);
    }

    const adminClient = createClient(supabaseUrl, secretKey, {
      auth: SUPABASE_CLIENT_AUTH_OPTIONS,
    });

    const { data: rpcResult, error: rpcError } = await adminClient.rpc(
      "activate_device_wrapper",
      {
        p_device_auth_uid: deviceAuthUid,
        p_token_hash: tokenHash,
        p_method: method,
        p_ip_hash: ipHash,
      }
    );

    if (rpcError) {
      log("rpc_error");
      return respond(genericFailure(), 500);
    }

    const statusCode = (rpcResult as { status_code?: string } | null)?.status_code;

    if (statusCode === "success") {
      log("activation_success");
      return respond({ success: true, message: "Appareil activé." }, 200);
    }

    if (statusCode === "rate_limited") {
      log("activation_rate_limited");
      return respond(
        { success: false, message: "Trop de tentatives. Réessayez plus tard." },
        429
      );
    }

    log("activation_failed_generic");
    return respond(genericFailure(), 400);
  } catch {
    log("unexpected_error");
    return respond(genericFailure(), 500);
  }
});
