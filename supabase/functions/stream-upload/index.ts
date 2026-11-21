// POST { kind: "practical_video" | "training_video", max_duration_seconds? }
// -> { media_file_id, uid, upload_url }
//
// Basic direct upload (one multipart POST, files up to 200 MB). Used by the
// phone app for practical tests. The admin web uploads training videos with
// stream-tus-upload, which resumes and has no size limit.
import { handle, json, requireUser, userClient } from "../_shared/http.ts";
import { createDirectUpload } from "../_shared/cloudflare.ts";
import { checkKind, insertVideoRow, outletFor, VIDEO_LIMITS } from "../_shared/media.ts";

Deno.serve(handle(async (req) => {
  const client = userClient(req);
  const user = await requireUser(client);
  const { kind, max_duration_seconds } = await req.json();
  checkKind(kind);
  const outletId = await outletFor(client, user, kind);

  const maxDuration = Math.min(Number(max_duration_seconds) || VIDEO_LIMITS[kind], VIDEO_LIMITS[kind]);
  const { uid, uploadURL } = await createDirectUpload({
    maxDurationSeconds: maxDuration,
    meta: { kind, uploaded_by: user.id },
  });
  const mediaId = await insertVideoRow(client, { uid, kind, userId: user.id, outletId });
  return json({ media_file_id: mediaId, uid, upload_url: uploadURL });
}));
