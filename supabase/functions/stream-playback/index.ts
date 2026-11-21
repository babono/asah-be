// POST { media_file_id, download?: boolean }
// -> { hls_url, mp4_url?, thumbnail_url, expires_at, download_status? }
//
// Reads the media_files row with the caller's client: if RLS hides the row
// (not your trainee, not your outlet, module not assigned...), there is no URL.
// download=true also enables Cloudflare's MP4 rendition so lessons can be saved
// for offline viewing (PRD F7).
import { handle, HttpError, json, requireUser, userClient } from "../_shared/http.ts";
import { enableDownload, signedToken, STREAM_BUCKET, streamUrls } from "../_shared/cloudflare.ts";

Deno.serve(handle(async (req) => {
  const client = userClient(req);
  await requireUser(client);
  const { media_file_id, download } = await req.json();
  if (!media_file_id) throw new HttpError(400, "media_file_id is required");

  const { data: media } = await client.from("media_files")
    .select("id, bucket, object_key, status").eq("id", media_file_id).maybeSingle();
  if (!media) throw new HttpError(404, "Video not found");
  if (media.bucket !== STREAM_BUCKET) throw new HttpError(400, "Not a Stream video");
  if (media.status === "failed") throw new HttpError(409, "This video failed to process");

  const ttl = download ? 6 * 3600 : 3600;
  const { token, exp } = await signedToken(media.object_key, { downloadable: !!download, ttlSeconds: ttl });
  const urls = streamUrls(token);

  let downloadStatus: string | undefined;
  if (download) {
    const d = await enableDownload(media.object_key);
    downloadStatus = d.status; // "ready" | "inprogress" | "error"
  }

  return json({
    hls_url: urls.hls,
    mp4_url: download ? urls.mp4 : undefined,
    thumbnail_url: urls.thumbnail,
    expires_at: new Date(exp * 1000).toISOString(),
    status: media.status,
    download_status: downloadStatus,
  });
}));
