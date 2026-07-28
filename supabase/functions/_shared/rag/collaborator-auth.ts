import { createClient } from "npm:@supabase/supabase-js@2.110.6";
import { RagError } from "./errors.ts";

const CLIENT_OPTIONS = {
  autoRefreshToken: false,
  persistSession: false,
  detectSessionInUrl: false,
};

function publishableKey(): string | undefined {
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

export async function requireAuthenticatedUser(
  request: Request,
): Promise<string> {
  const match = request.headers.get("authorization")?.match(
    /^Bearer\s+(.+)$/i,
  );
  const jwt = match?.[1]?.trim() ?? "";
  if (!jwt) {
    throw new RagError("unauthorized", "Authentification requise.", 401);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const key = publishableKey();
  if (!url || !key) {
    throw new RagError(
      "server_not_configured",
      "Service momentanément indisponible.",
      500,
    );
  }

  const authClient = createClient(url, key, {
    auth: CLIENT_OPTIONS,
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });
  const { data, error } = await authClient.auth.getUser(jwt);
  const authUid = data?.user?.id;
  if (error || typeof authUid !== "string") {
    throw new RagError(
      "unauthorized",
      "Session invalide ou expirée.",
      401,
    );
  }
  return authUid;
}
