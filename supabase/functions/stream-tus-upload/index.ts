// tus creation endpoint for resumable video uploads (no size limit).
//
// tus-js-client POSTs here with Upload-Length and Upload-Metadata, plus the
// user's Authorization header; ?kind=training_video|practical_video.
// We create the upload at Cloudflare (direct_user=true), record the
// media_files row as the caller, and answer 201 with Location = the
// one-time Cloudflare URL. The client then sends the file straight to
// Cloudflare, never through this function.
//
//   new tus.Upload(file, {
//     endpoint: `${SUPABASE_URL}/functions/v1/stream-tus-upload?kind=training_video`,
//     headers: { Authorization: `Bearer ${accessToken}`, apikey: ANON_KEY },
//     chunkSize: 50 * 1024 * 1024,
//     onAfterResponse: (_req, res) => res.getHeader("X-Media-File-Id"),
//   })
import { corsHeaders, handle, HttpError, requireUser, userClient } from "../_shared/http.ts";
import { createTusUpload } from "../_shared/cloudflare.ts";
import { checkKind, insertVideoRow, outletFor, VIDEO_LIMITS } from "../_shared/media.ts";

/** Reads the "name" key from tus Upload-Metadata ("key base64,key base64"). */
function metadataName(header: string | null): string | undefined {
  for (const pair of (header ?? "").split(",")) {
    const [key, value] = pair.trim().split(" ");
    if ((key === "name" || key === "filename") && value) {
      try {
        return decodeURIComponent(escape(atob(value)));
      } catch {
        return undefined;
      }
    }
  }
  return undefined;
}

Deno.serve(handle(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "POST only");
  const client = userClient(req);
  const user = await requireUser(client);
  const kind = new URL(req.url).searchParams.get("kind");
  checkKind(kind);

  const length = Number(req.headers.get("Upload-Length"));
  if (!Number.isFinite(length) || length <= 0) throw new HttpError(400, "Upload-Length is required");
  const outletId = await outletFor(client, user, kind);

  const { location, uid } = await createTusUpload({
    length,
    maxDurationSeconds: VIDEO_LIMITS[kind],
    name: metadataName(req.headers.get("Upload-Metadata")),
  });
  const mediaId = await insertVideoRow(client, { uid, kind, userId: user.id, outletId, size: length });

  return new Response(null, {
    status: 201,
    headers: {
      ...corsHeaders,
      Location: location,
      "Tus-Resumable": "1.0.0",
      "X-Media-File-Id": mediaId,
    },
  });
}));
