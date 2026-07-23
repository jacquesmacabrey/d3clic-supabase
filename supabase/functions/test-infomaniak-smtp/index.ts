// @ts-ignore: Nodemailer n'inclut pas ses types TypeScript
import nodemailer from "npm:nodemailer@6.9.16";

const jsonHeaders = {
  "Content-Type": "application/json; charset=utf-8",
};

function getRequiredSecret(name: string): string {
  const value = Deno.env.get(name);

  if (!value) {
    throw new Error(`Secret manquant : ${name}`);
  }

  return value;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({
        ok: false,
        error: "Utiliser une requête POST.",
      }),
      {
        status: 405,
        headers: jsonHeaders,
      },
    );
  }

  try {
    const host = getRequiredSecret("SMTP_HOST");
    const port = Number(getRequiredSecret("SMTP_PORT"));
    const user = getRequiredSecret("SMTP_USER");
    const password = getRequiredSecret("SMTP_PASS");
    const from = getRequiredSecret("SMTP_FROM");

    const transporter = nodemailer.createTransport({
      host,
      port,
      secure: false,
      requireTLS: true,
      auth: {
        user,
        pass: password,
      },
      connectionTimeout: 15000,
      greetingTimeout: 15000,
      socketTimeout: 20000,
      tls: {
        minVersion: "TLSv1.2",
      },
    });

    const result = await transporter.sendMail({
      from: `"D3clic - Notifications" <${from}>`,
      to: user,
      subject: "Test SMTP D3clic",
      text: "L'envoi SMTP depuis Supabase vers Infomaniak fonctionne.",
      html: `
        <h2>Test SMTP D3clic</h2>
        <p>L'envoi SMTP depuis Supabase vers Infomaniak fonctionne.</p>
      `,
    });

    transporter.close();

    return new Response(
      JSON.stringify({
        ok: true,
        message: "E-mail envoyé.",
        messageId: result.messageId,
      }),
      {
        status: 200,
        headers: jsonHeaders,
      },
    );
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error);

    console.error("Erreur SMTP :", message);

    return new Response(
      JSON.stringify({
        ok: false,
        error: message,
      }),
      {
        status: 500,
        headers: jsonHeaders,
      },
    );
  }
});