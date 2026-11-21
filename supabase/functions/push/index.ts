// Sends a push for each new public.notifications row (PRD F6).
// Called by the notifications_push trigger (pg_net) with the x-push-secret header.
// Deploy with --no-verify-jwt. Targets the OneSignal External ID, which the
// app sets to the Supabase user id on sign-in.
const ONESIGNAL_APP_ID = Deno.env.get("ONESIGNAL_APP_ID");
const ONESIGNAL_REST_API_KEY = Deno.env.get("ONESIGNAL_REST_API_KEY") ?? "";
const PUSH_HOOK_SECRET = Deno.env.get("PUSH_HOOK_SECRET");

function authHeader(key: string): string {
  return key.startsWith("os_v2_") ? `Key ${key}` : `Basic ${key}`;
}

function respond(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

Deno.serve(async (req) => {
  if (!PUSH_HOOK_SECRET || req.headers.get("x-push-secret") !== PUSH_HOOK_SECRET) {
    return respond({ error: "Unauthorized" }, 401);
  }
  const { record } = await req.json();
  if (!record?.user_id) return respond({ error: "Missing record.user_id" }, 400);

  const res = await fetch("https://onesignal.com/api/v1/notifications", {
    method: "POST",
    headers: { "Content-Type": "application/json; charset=utf-8", Authorization: authHeader(ONESIGNAL_REST_API_KEY) },
    body: JSON.stringify({
      app_id: ONESIGNAL_APP_ID,
      include_aliases: { external_id: [record.user_id] },
      target_channel: "push",
      headings: { en: record.title },
      contents: { en: record.body ?? record.title },
      data: { notification_id: record.id, type: record.type, ...(record.data ?? {}) },
    }),
  });
  const result = await res.json();
  // OneSignal reports many failures inside a 200 body.
  const errors = result?.errors;
  const hasErrors = Array.isArray(errors) ? errors.length > 0 : errors && Object.keys(errors).length > 0;
  if (!res.ok || hasErrors || !result?.id) {
    console.error(`push failed for ${record.user_id}: ${JSON.stringify(result)}`);
    return respond({ error: result }, 502);
  }
  return respond({ id: result.id });
});
