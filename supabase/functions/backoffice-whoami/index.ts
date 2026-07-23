import { createClient } from "npm:@supabase/supabase-js@2.95.0";

function requiredSecret(name: string): string {
  const value = Deno.env.get(name);

  if (!value) {
    throw new Error(`Secret manquant : ${name}`);
  }

  return value;
}

const ALLOWED_ORIGINS = new Set([
  "https://d3clic-suite.ch",
  "https://www.d3clic-suite.ch",
]);

function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("origin") ?? "";

  if (!ALLOWED_ORIGINS.has(origin)) {
    return {};
  }

  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Vary": "Origin",
  };
}

function jsonResponse(
  req: Request,
  body: unknown,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(req),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store, max-age=0",
    },
  });
}

export default {
  async fetch(req: Request): Promise<Response> {
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(req) });
    }

    if (req.method !== "GET" && req.method !== "POST") {
      return jsonResponse(
        req,
        { authorized: false, error: "method_not_allowed" },
        405,
      );
    }

    try {
      const supabaseUrl = requiredSecret("SUPABASE_URL");
      const anonKey = requiredSecret("SUPABASE_ANON_KEY");
      const serviceRoleKey = requiredSecret("SUPABASE_SERVICE_ROLE_KEY");

      const authHeader = req.headers.get("Authorization") ?? "";
      const jwt = authHeader.replace(/^Bearer\s+/i, "").trim();

      if (!jwt) {
        return jsonResponse(
          req,
          { authorized: false, error: "missing_authorization" },
          401,
        );
      }

      const callerClient = createClient(supabaseUrl, anonKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      });

      const { data: userData, error: userError } =
        await callerClient.auth.getUser(jwt);

      if (userError || !userData?.user?.id) {
        return jsonResponse(
          req,
          { authorized: false, error: "invalid_session" },
          401,
        );
      }

      const authUid = userData.user.id;

      const adminClient = createClient(supabaseUrl, serviceRoleKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      });

      const { data, error } = await adminClient.rpc(
        "check_backoffice_role_wrapper",
        { p_auth_uid: authUid, p_required_role: "admin" },
      );

      if (error) {
        console.error("Erreur RPC check_backoffice_role_wrapper :", error);

        return jsonResponse(
          req,
          { authorized: false, error: "server_error" },
          503,
        );
      }

      const result = Array.isArray(data) ? data[0] : data;

      if (!result || result.authorized !== true) {
        return jsonResponse(
          req,
          { authorized: false, error: "not_authorized" },
          403,
        );
      }

      return jsonResponse(req, {
        authorized: true,
        user_uuid: result.user_uuid,
        institution_id: result.institution_id,
        display_name: result.display_name,
        role: result.role,
      });
    } catch (error) {
      console.error("Erreur interne backoffice-whoami :", error);

      return jsonResponse(
        req,
        { authorized: false, error: "internal_error" },
        500,
      );
    }
  },
};