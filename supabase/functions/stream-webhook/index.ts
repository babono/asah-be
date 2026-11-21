// Cloudflare Stream webhook: marks media_files ready/failed with its duration.
// Register once:
//   curl -X PUT https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/stream/webhook \
//     -H "Authorization: Bearer $TOKEN" -d '{"notificationUrl":"https://<ref>.supabase.co/functions/v1/stream-webhook"}'
// and store the returned secret as CLOUDFLARE_STREAM_WEBHOOK_SECRET.
// Deploy with --no-verify-jwt (Cloudflare does not send a Supabase JWT).
import { json, serviceClient } from "../_shared/http.ts";
import { STREAM_BUCKET } from "../_shared/cloudflare.ts";

const SECRET = Deno.env.get("CLOUDFLARE_STREAM_WEBHOOK_SECRET");

async function validSignature(header: string | null, body: string): Promise<boolean> {
  if (!SECRET || !header) return false;
  const parts = Object.fromEntries(header.split(",").map((p) => p.split("=") as [string, string]));
  const time = parts["time"];
  const sig = parts["sig1"];
  if (!time || !sig) return false;
  if (Math.abs(Date.now() / 1000 - Number(time)) > 300) return false; // replay window
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${time}.${body}`));
  const hex = [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return hex === sig;
}

Deno.serve(async (req) => {
  const raw = await req.text();
  if (!(await validSignature(req.headers.get("Webhook-Signature"), raw))) {
    return json({ error: "bad signature" }, 401);
  }
  const event = JSON.parse(raw);
  const state = event?.status?.state as string | undefined;
  const status = event.readyToStream ? "ready" : state === "error" ? "failed" : "processing";

  const { error } = await serviceClient().from("media_files")
    .update({
      status,
      duration_seconds: event.duration > 0 ? Math.round(event.duration) : null,
      size_bytes: event.size ?? null,
    })
    .eq("bucket", STREAM_BUCKET).eq("object_key", event.uid);
  if (error) return json({ error: error.message }, 500);
  return json({ ok: true });
});
