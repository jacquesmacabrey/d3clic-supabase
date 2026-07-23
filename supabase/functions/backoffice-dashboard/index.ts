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
        { ok: false, error: "method_not_allowed" },
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
          { ok: false, error: "missing_authorization" },
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
          { ok: false, error: "invalid_session" },
          401,
        );
      }

      const authUid = userData.user.id;

      const adminClient = createClient(supabaseUrl, serviceRoleKey, {
        auth: { persistSession: false, autoRefreshToken: false },
      });

      const { data: roleData, error: roleError } = await adminClient.rpc(
        "check_backoffice_role_wrapper",
        { p_auth_uid: authUid, p_required_role: "admin" },
      );

      if (roleError) {
        console.error("Erreur RPC check_backoffice_role_wrapper :", roleError);

        return jsonResponse(
          req,
          { ok: false, error: "server_error" },
          503,
        );
      }

      const roleResult = Array.isArray(roleData) ? roleData[0] : roleData;

      if (!roleResult || roleResult.authorized !== true) {
        return jsonResponse(
          req,
          { ok: false, error: "not_authorized" },
          403,
        );
      }

      const institutionId = roleResult.institution_id;

      const [dashboardResult, pendingResult] = await Promise.all([
        adminClient.rpc("get_backoffice_dashboard_wrapper", {
          p_institution_id: institutionId,
        }),
        adminClient.rpc("get_backoffice_pending_requests_wrapper", {
          p_institution_id: institutionId,
        }),
      ]);

      if (dashboardResult.error) {
        console.error(
          "Erreur RPC get_backoffice_dashboard_wrapper :",
          dashboardResult.error,
        );

        return jsonResponse(req, { ok: false, error: "server_error" }, 503);
      }

      if (pendingResult.error) {
        console.error(
          "Erreur RPC get_backoffice_pending_requests_wrapper :",
          pendingResult.error,
        );

        return jsonResponse(req, { ok: false, error: "server_error" }, 503);
      }

      return jsonResponse(req, {
        ok: true,
        institution_id: institutionId,
        collaborators: dashboardResult.data ?? [],
        pending_requests: pendingResult.data ?? [],
      });
    } catch (error) {
      console.error("Erreur interne backoffice-dashboard :", error);

      return jsonResponse(
        req,
        { ok: false, error: "internal_error" },
        500,
      );
    }
  },
};