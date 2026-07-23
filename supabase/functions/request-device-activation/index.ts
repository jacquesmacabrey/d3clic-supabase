import { createClient } from "npm:@supabase/supabase-js@2.95.0";

// @ts-ignore — Nodemailer fonctionne via la compatibilité npm de Deno.
import nodemailer from "npm:nodemailer@6.9.16";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function requiredSecret(name: string): string {
  const value = Deno.env.get(name);

  if (!value) {
    throw new Error(`Secret manquant : ${name}`);
  }

  return value;
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";

  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/g, "");
}

async function sha256Hex(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);

  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function optionalString(
  value: unknown,
  maxLength: number,
): string | null {
  if (typeof value !== "string") {
    return null;
  }

  const cleaned = value.trim();

  if (!cleaned) {
    return null;
  }

  return cleaned.slice(0, maxLength);
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function groupDescription(value: unknown): string {
  if (
    typeof value === "string" ||
    typeof value === "number"
  ) {
    return String(value).slice(0, 150);
  }

  if (value && typeof value === "object") {
    const group = value as Record<string, unknown>;

    const preferred =
      group.name ??
      group.label ??
      group.group_name ??
      group.id ??
      group.group_id;

    if (
      typeof preferred === "string" ||
      typeof preferred === "number"
    ) {
      return String(preferred).slice(0, 150);
    }

    return JSON.stringify(group).slice(0, 150);
  }

  return "";
}

function getClientIp(req: Request): string | null {
  const forwarded = req.headers.get("x-forwarded-for");

  if (forwarded) {
    return forwarded.split(",")[0]?.trim() || null;
  }

  return (
    req.headers.get("cf-connecting-ip") ??
    req.headers.get("x-real-ip") ??
    null
  );
}

function httpStatusForRpcCode(code: string): number {
  switch (code) {
    case "rate_limited":
      return 429;

    case "device_already_activated":
      return 409;

    case "device_revoked":
      return 403;

    case "invalid_params":
    case "institution_unknown":
    case "institution_inactive":
      return 400;

    case "admin_email_missing":
      return 503;

    default:
      return 500;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      status: 200,
      headers: corsHeaders,
    });
  }

  if (req.method !== "POST") {
    return jsonResponse(
      {
        ok: false,
        error: "method_not_allowed",
      },
      405,
    );
  }

  try {
    const authorization =
      req.headers.get("Authorization");

    if (!authorization?.startsWith("Bearer ")) {
      return jsonResponse(
        {
          ok: false,
          error: "missing_authorization",
        },
        401,
      );
    }

    const jwt = authorization
      .slice("Bearer ".length)
      .trim();

    const supabaseUrl =
      requiredSecret("SUPABASE_URL");

    const anonKey =
      requiredSecret("SUPABASE_ANON_KEY");

    const serviceRoleKey =
      requiredSecret("SUPABASE_SERVICE_ROLE_KEY");

    const institutionId =
      requiredSecret("CHAT_INSTITUTION_ID");

    /*
     * Vérification réelle du JWT transmis par l’appareil.
     */
    const authClient = createClient(
      supabaseUrl,
      anonKey,
      {
        auth: {
          persistSession: false,
          autoRefreshToken: false,
        },
      },
    );

    const {
      data: { user },
      error: authError,
    } = await authClient.auth.getUser(jwt);

    if (authError || !user) {
      console.error(
        "JWT refusé :",
        authError?.message,
      );

      return jsonResponse(
        {
          ok: false,
          error: "invalid_authorization",
        },
        401,
      );
    }

    if (user.is_anonymous !== true) {
      return jsonResponse(
        {
          ok: false,
          error: "anonymous_device_required",
        },
        403,
      );
    }

    const contentLength = Number(
      req.headers.get("content-length") ?? "0",
    );

    if (contentLength > 20_000) {
      return jsonResponse(
        {
          ok: false,
          error: "request_too_large",
        },
        413,
      );
    }

    let payload: Record<string, unknown>;

    try {
      payload = await req.json();
    } catch {
      return jsonResponse(
        {
          ok: false,
          error: "invalid_json",
        },
        400,
      );
    }

    const displayName = optionalString(
      payload.display_name,
      150,
    );

    const suggestedEmail = optionalString(
      payload.email,
      320,
    );

    const goodbarberUserId = optionalString(
      payload.goodbarber_user_id,
      250,
    );

    const suggestedGroups = Array.isArray(
      payload.suggested_groups,
    )
      ? payload.suggested_groups
      : [];

    if (!displayName) {
      return jsonResponse(
        {
          ok: false,
          error: "display_name_required",
        },
        400,
      );
    }

    if (
      JSON.stringify(suggestedGroups).length > 8_192
    ) {
      return jsonResponse(
        {
          ok: false,
          error: "suggested_groups_too_large",
        },
        400,
      );
    }

    /*
     * Le jeton brut est envoyé dans le lien.
     * La base ne reçoit que son hash SHA-256.
     */
    const tokenBytes = crypto.getRandomValues(
      new Uint8Array(32),
    );

    const approvalToken =
      base64Url(tokenBytes);

    const approvalTokenHash =
      await sha256Hex(approvalToken);

    /*
     * Le hash IP est facultatif.
     */
    const clientIp = getClientIp(req);

    const ipHashSecret =
      Deno.env.get("ACTIVATION_IP_HASH_SECRET");

    const ipHash =
      clientIp && ipHashSecret
        ? await sha256Hex(
          `${ipHashSecret}:${clientIp}`,
        )
        : null;

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

    const {
      data: rpcData,
      error: rpcError,
    } = await adminClient.rpc(
      "create_device_activation_request_wrapper",
      {
        p_device_auth_uid: user.id,
        p_institution_id: institutionId,
        p_suggested_display_name: displayName,
        p_suggested_email: suggestedEmail,
        p_suggested_goodbarber_user_id:
          goodbarberUserId,
        p_suggested_groups: suggestedGroups,
        p_approval_token_hash:
          approvalTokenHash,
        p_ip_hash: ipHash,
      },
    );

    if (rpcError) {
      console.error(
        "Erreur RPC :",
        rpcError,
      );

      return jsonResponse(
        {
          ok: false,
          error: "database_error",
        },
        500,
      );
    }

    const result =
      rpcData as Record<string, unknown>;

    const statusCode = String(
      result?.status_code ?? "unknown_error",
    );

    if (result?.success !== true) {
      return jsonResponse(
        {
          ok: false,
          error: statusCode,
        },
        httpStatusForRpcCode(statusCode),
      );
    }

    const requestId =
      String(result.request_id);

    const expiresAt =
      String(result.expires_at);

    const adminEmail =
      String(result.admin_email);

    const institutionLabel =
      String(result.institution_label);

    /*
     * URL publique de la page hébergée chez Infomaniak.
     */
    const activationPublicUrl =
      requiredSecret("ACTIVATION_PUBLIC_URL")
        .replace(/\/+$/, "");

    const approvalUrl =
      `${activationPublicUrl}/` +
      `?request=${encodeURIComponent(requestId)}` +
      `&token=${encodeURIComponent(approvalToken)}`;

    const groupNames = suggestedGroups
      .map(groupDescription)
      .filter(Boolean)
      .slice(0, 30);

    const groupText = groupNames.length
      ? groupNames.join(", ")
      : "Aucun canal détecté";

    const smtpHost =
      requiredSecret("SMTP_HOST");

    const smtpPort = Number(
      requiredSecret("SMTP_PORT"),
    );

    const smtpUser =
      requiredSecret("SMTP_USER");

    const smtpPassword =
      requiredSecret("SMTP_PASS");

    const smtpFrom =
      requiredSecret("SMTP_FROM");

    const transporter =
      nodemailer.createTransport({
        host: smtpHost,
        port: smtpPort,
        secure: false,
        requireTLS: true,
        auth: {
          user: smtpUser,
          pass: smtpPassword,
        },
        connectionTimeout: 15_000,
        greetingTimeout: 15_000,
        socketTimeout: 20_000,
        tls: {
          minVersion: "TLSv1.2",
        },
      });

    try {
      await transporter.sendMail({
        from:
          `"D3clic — Notifications" <${smtpFrom}>`,

        to: adminEmail,

        subject:
          `D3clic — demande d’activation de ${displayName}`,

        text: [
          "Une demande d’activation du chat D3clic a été reçue.",
          "",
          `Institution : ${institutionLabel}`,
          `Nom déclaré : ${displayName}`,
          suggestedEmail
            ? `Adresse déclarée : ${suggestedEmail}`
            : "Adresse déclarée : non fournie",
          goodbarberUserId
            ? `Identifiant GoodBarber : ${goodbarberUserId}`
            : "Identifiant GoodBarber : non fourni",
          `Canaux suggérés : ${groupText}`,
          "",
          "Ces informations proviennent de l’appareil et doivent être vérifiées.",
          "",
          `Examiner la demande : ${approvalUrl}`,
          "",
          "Ce lien est personnel, à usage unique et valable 24 heures.",
        ].join("\n"),

        html: `
          <!doctype html>
          <html lang="fr">
            <body style="margin:0;background:#f4f6f8;font-family:Arial,sans-serif;color:#20242a;">
              <div style="max-width:620px;margin:30px auto;background:#ffffff;border-radius:12px;padding:30px;">
                <h2 style="margin-top:0;">
                  Demande d’activation du chat D3clic
                </h2>

                <p>
                  Une nouvelle demande d’activation a été reçue pour
                  <strong>
                    ${escapeHtml(institutionLabel)}
                  </strong>.
                </p>

                <table style="width:100%;border-collapse:collapse;margin:22px 0;">
                  <tr>
                    <td style="padding:8px 0;font-weight:bold;">
                      Nom déclaré
                    </td>
                    <td style="padding:8px 0;">
                      ${escapeHtml(displayName)}
                    </td>
                  </tr>

                  <tr>
                    <td style="padding:8px 0;font-weight:bold;">
                      Adresse déclarée
                    </td>
                    <td style="padding:8px 0;">
                      ${escapeHtml(
                        suggestedEmail ?? "Non fournie",
                      )}
                    </td>
                  </tr>

                  <tr>
                    <td style="padding:8px 0;font-weight:bold;">
                      Identifiant GoodBarber
                    </td>
                    <td style="padding:8px 0;">
                      ${escapeHtml(
                        goodbarberUserId ?? "Non fourni",
                      )}
                    </td>
                  </tr>

                  <tr>
                    <td style="padding:8px 0;font-weight:bold;">
                      Canaux suggérés
                    </td>
                    <td style="padding:8px 0;">
                      ${escapeHtml(groupText)}
                    </td>
                  </tr>
                </table>

                <p style="padding:12px;background:#fff7df;border-radius:8px;">
                  Ces informations sont transmises par l’appareil.
                  Elles constituent uniquement une suggestion et doivent être vérifiées.
                </p>

                <p style="margin:28px 0;text-align:center;">
                  <a
                    href="${escapeHtml(approvalUrl)}"
                    style="display:inline-block;padding:13px 22px;background:#1769aa;color:#ffffff;text-decoration:none;border-radius:7px;font-weight:bold;"
                  >
                    Examiner la demande
                  </a>
                </p>

                <p style="font-size:13px;color:#68717c;">
                  Ce lien est personnel, à usage unique et valable 24 heures.
                </p>
              </div>
            </body>
          </html>
        `,
      });
    } catch (smtpError) {
      console.error(
        "Erreur d’envoi SMTP :",
        smtpError,
      );

      /*
       * Si l’e-mail ne part pas, la demande est immédiatement
       * annulée afin que l’utilisateur puisse réessayer.
       */
      const {
        data: cancelData,
        error: cancelError,
      } = await adminClient.rpc(
        "cancel_device_activation_request_wrapper",
        {
          p_request_id: requestId,
          p_device_auth_uid: user.id,
          p_reason: "smtp_send_failed",
        },
      );

      if (cancelError) {
        console.error(
          "Impossible d’annuler la demande après l’échec SMTP :",
          cancelError,
        );
      } else {
        const cancelResult =
          cancelData as Record<string, unknown>;

        if (cancelResult?.success !== true) {
          console.error(
            "Annulation refusée après l’échec SMTP :",
            cancelResult,
          );
        }
      }

      return jsonResponse(
        {
          ok: false,
          error: "email_send_failed",
        },
        502,
      );
    } finally {
      transporter.close();
    }

    return jsonResponse({
      ok: true,
      status: "pending",
      expires_at: expiresAt,
    });
  } catch (error) {
    console.error(
      "Erreur interne :",
      error,
    );

    return jsonResponse(
      {
        ok: false,
        error: "internal_error",
      },
      500,
    );
  }
});