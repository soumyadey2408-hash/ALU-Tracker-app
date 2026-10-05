// Sends a push notification to the partner when a row is added to "events" (Miss you / SOS).
import { createClient } from "npm:@supabase/supabase-js@2";

const sa = JSON.parse(Deno.env.get("FCM_SERVICE_ACCOUNT")!);

const b64 = (b: ArrayBuffer | string) =>
  btoa(typeof b === "string" ? b : String.fromCharCode(...new Uint8Array(b)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

async function accessToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const head = b64(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${head}.${claim}`));
  const r = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${head}.${claim}.${b64(sig)}`,
  });
  return (await r.json()).access_token;
}

Deno.serve(async (req) => {
  const { record } = await req.json(); // Database Webhook payload (INSERT on events)
  const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const [toks, from] = await Promise.all([
    db.from("device_tokens").select("token").eq("user_id", record.to_user),
    db.from("profiles").select("name").eq("id", record.from_user).maybeSingle(),
  ]);
  const name = from.data?.name || "Your partner";
  const sos = record.kind === "sos";
  const at = await accessToken();
  await Promise.all((toks.data ?? []).map((t: { token: string }) =>
    fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: "POST",
      headers: { Authorization: `Bearer ${at}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token: t.token,
          notification: {
            title: sos ? "🚨 Emergency" : "💗 Miss you",
            body: sos ? `${name} needs help!` : `${name} misses you`,
          },
          android: { priority: "HIGH", notification: { channel_id: sos ? "sos" : "miss" } },
        },
      }),
    })
  ));
  return new Response("ok");
});
