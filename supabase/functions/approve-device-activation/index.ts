import { createClient } from "npm:@supabase/supabase-js@2.95.0";

const allowedOrigins = new Set([
  "https://d3clic-suite.ch",
  "https://www.d3clic-suite.ch",
]);

function requiredSecret(name: string): string {
  const value = Deno.env.get(name);

  if (!value) {
    throw new Error(`Secret manquant : ${name}`);
  }

  return value;
}

function isAllowedOrigin(req: Request): boolean {
  const origin = req.headers.get("origin");

  // Autorise aussi les tests serveur sans en-tête Origin.
  return !origin || allowedOrigins.has(origin);
}

function responseHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin");
  const headers: Record<string, string> = {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store, max-age=0",
    "X-Content-Type-Options": "nosniff",
  };

  if (origin && allowedOrigins.has(origin)) {
    headers["Access-Control-Allow-Origin"] = origin;
    headers["Vary"] = "Origin";
  }

  return headers;
}

function jsonResponse(
  req: Request,
  body: unknown,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: responseHeaders(req),
  });
}

function objectValue(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function stringValue(
  value: unknown,
  maxLength: number,
): string {
  return typeof value === "string"
    ? value.trim().slice(0, maxLength)
    : "";
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
    .test(value);
}

function validToken(value: string): boolean {
  return value.length >= 32 && value.length <= 200;
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );

  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function statusForCode(code: string): number {
  switch (code) {
    case "expired":
      return 410;

    case "request_not_pending":
    case "device_already_activated":
    case "goodbarber_user_already_exists":
    case "goodbarber_user_id_mismatch":
    case "existing_user_not_found":
    case "existing_user_inactive":
      return 409;

    case "device_revoked":
      return 403;

    case "institution_inactive":
      return 503;

    case "invalid_link":
    case "invalid_channel_selection":
    case "display_name_required":
    case "invalid_display_name":
    case "invalid_goodbarber_user_id":
    case "too_many_channels":
      return 400;

    default:
      return 500;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    if (!isAllowedOrigin(req)) {
      return new Response(null, { status: 403 });
    }

    return new Response(null, {
      status: 204,
      headers: {
        ...responseHeaders(req),
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "content-type",
        "Access-Control-Max-Age": "600",
      },
    });
  }

  if (!isAllowedOrigin(req)) {
    return jsonResponse(
      req,
      {
        ok: false,
        error: "origin_not_allowed",
      },
      403,
    );
  }

  if (req.method !== "POST") {
    return jsonResponse(
      req,
      {
        ok: false,
        error: "method_not_allowed",
      },
      405,
    );
  }

  const contentLength = Number(
    req.headers.get("content-length") ?? "0",
  );

  if (contentLength > 25_000) {
    return jsonResponse(
      req,
      {
        ok: false,
        error: "request_too_large",
      },
      413,
    );
  }

  try {
    let payload: Record<string, unknown>;

    try {
      payload = objectValue(await req.json());
    } catch {
      return jsonResponse(
        req,
        {
          ok: false,
          error: "invalid_json",
        },
        400,
      );
    }

    const action = stringValue(payload.action, 20);
    const requestId = stringValue(payload.request_id, 36);
    const token = stringValue(payload.token, 200);

    if (
      !["load", "approve"].includes(action) ||
      !isUuid(requestId) ||
      !validToken(token)
    ) {
      return jsonResponse(
        req,
        {
          ok: false,
          error: "invalid_request",
        },
        400,
      );
    }

    const tokenHash = await sha256Hex(token);

    const supabaseUrl = requiredSecret("SUPABASE_URL");
    const serviceRoleKey = requiredSecret(
      "SUPABASE_SERVICE_ROLE_KEY",
    );

    const adminClient = createClient(
      supabaseUrl,
      serviceRoleKey,
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
        },
      },
    );

    if (action === "load") {
      const { data, error } = await adminClient.rpc(
        "get_device_activation_request_for_approval_wrapper",
        {
          p_request_id: requestId,
          p_approval_token_hash: tokenHash,
        },
      );

      if (error) {
        console.error("Erreur RPC lecture :", error);

        return jsonResponse(
          req,
          {
            ok: false,
            error: "database_error",
          },
          500,
        );
      }

      const result = objectValue(data);

      if (result.success !== true) {
        const code = String(
          result.status_code ?? "invalid_link",
        );

        return jsonResponse(
          req,
          {
            ok: false,
            error: code,
            request_status:
              result.request_status ?? null,
          },
          statusForCode(code),
        );
      }

      return jsonResponse(req, {
        ok: true,
        data: result,
      });
    }

    const mode = stringValue(payload.mode, 20);

    if (!["new", "existing"].includes(mode)) {
      return jsonResponse(
        req,
        {
          ok: false,
          error: "invalid_mode",
        },
        400,
      );
    }

    const displayName = mode === "new"
      ? stringValue(payload.display_name, 150)
      : "";

    const confirmedGoodbarberUserId = stringValue(
      payload.confirmed_goodbarber_user_id,
      250,
    );

    const existingUserUuid = mode === "existing"
      ? stringValue(payload.existing_user_uuid, 36)
      : "";

    if (mode === "new" && !displayName) {
      return jsonResponse(
        req,
        {
          ok: false,
          error: "display_name_required",
        },
        400,
      );
    }

    if (
      mode === "existing" &&
      !isUuid(existingUserUuid)
    ) {
      return jsonResponse(
        req,
        {
          ok: false,
          error: "existing_user_required",
        },
        400,
      );
    }

    const channelIds = Array.isArray(payload.channel_ids)
      ? payload.channel_ids
        .filter(
          (value): value is string =>
            typeof value === "string",
        )
        .map((value) => value.trim())
        .filter(Boolean)
        .slice(0, 50)
      : [];

    const { data, error } = await adminClient.rpc(
      "approve_device_activation_request_wrapper",
      {
        p_request_id: requestId,
        p_approval_token_hash: tokenHash,
        p_display_name:
          mode === "new" ? displayName : null,
        p_channel_ids:
          mode === "new" ? channelIds : [],
        p_confirmed_goodbarber_user_id:
          confirmedGoodbarberUserId || null,
        p_existing_user_uuid:
          mode === "existing"
            ? existingUserUuid
            : null,
      },
    );

    if (error) {
      console.error("Erreur RPC approbation :", error);

      return jsonResponse(
        req,
        {
          ok: false,
          error: "database_error",
        },
        500,
      );
    }

    const result = objectValue(data);

    if (result.success !== true) {
      const code = String(
        result.status_code ?? "invalid_link",
      );

      return jsonResponse(
        req,
        {
          ok: false,
          error: code,
          request_status:
            result.request_status ?? null,
          existing_user_uuid:
            result.existing_user_uuid ?? null,
        },
        statusForCode(code),
      );
    }

    return jsonResponse(req, {
      ok: true,
      data: result,
    });
  } catch (error) {
    console.error(
      "Erreur interne approve-device-activation :",
      error,
    );

    return jsonResponse(
      req,
      {
        ok: false,
        error: "internal_error",
      },
      500,
    );
  }
});