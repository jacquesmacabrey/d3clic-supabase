import { createClient } from "npm:@supabase/supabase-js@2.95.0";

const AUTH_OPTIONS = {
  autoRefreshToken: false,
  persistSession: false,
  detectSessionInUrl: false,
};

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing_${name.toLowerCase()}`);
  return value;
}

function allowedOrigins(): Set<string> {
  const configured = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
    .split(",")
    .map((origin) => origin.trim())
    .filter(Boolean);

  return new Set([
    "https://d3clic-suite.ch",
    "https://www.d3clic-suite.ch",
    ...configured,
  ]);
}

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin");
  if (!origin || !allowedOrigins().has(origin)) return { Vary: "Origin" };

  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "GET, OPTIONS",
    Vary: "Origin",
  };
}

function json(req: Request, body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(req),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "private, no-store, max-age=0",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
    },
  });
}

Deno.serve(async (req: Request) => {
  const requestId = crypto.randomUUID();
  const origin = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    if (!origin || !allowedOrigins().has(origin)) {
      return new Response(null, { status: 403, headers: { Vary: "Origin" } });
    }
    return new Response(null, { status: 204, headers: corsHeaders(req) });
  }

  if (req.method !== "GET") {
    return json(req, { authorized: false, error: "method_not_allowed", request_id: requestId }, 405);
  }

  if (origin && !allowedOrigins().has(origin)) {
    return json(req, { authorized: false, error: "origin_not_allowed", request_id: requestId }, 403);
  }

  const authHeader = req.headers.get("authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!jwt) {
    return json(req, { authorized: false, error: "missing_authorization", request_id: requestId }, 401);
  }

  try {
    const supabaseUrl = requiredEnv("SUPABASE_URL");
    const anonKey = requiredEnv("SUPABASE_ANON_KEY");
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

    const authClient = createClient(supabaseUrl, anonKey, { auth: AUTH_OPTIONS });
    const { data: authData, error: authError } = await authClient.auth.getUser(jwt);

    if (authError || !authData.user?.id) {
      return json(req, { authorized: false, error: "invalid_session", request_id: requestId }, 401);
    }

    const adminClient = createClient(supabaseUrl, serviceRoleKey, { auth: AUTH_OPTIONS });
    const { data, error } = await adminClient.rpc("onboarding_content_wrapper", {
      p_device_auth_uid: authData.user.id,
    });

    if (error) {
      console.error(JSON.stringify({ requestId, event: "onboarding_rpc_error", code: error.code }));
      return json(req, { authorized: false, error: "server_error", request_id: requestId }, 503);
    }

    if (!data || data.authorized !== true) {
      return json(req, { authorized: false, error: "not_authorized", request_id: requestId }, 403);
    }

    return json(req, { ...data, request_id: requestId });
  } catch (error) {
    console.error(JSON.stringify({
      requestId,
      event: "onboarding_unexpected_error",
      message: error instanceof Error ? error.message : "unknown",
    }));
    return json(req, { authorized: false, error: "internal_error", request_id: requestId }, 500);
  }
});
