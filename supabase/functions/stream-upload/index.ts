// POST { kind: "practical_video" | "training_video", max_duration_seconds? }
// -> { media_file_id, uid, upload_url }
//
// Creates a Cloudflare Stream direct-upload URL and the media_files row that
// points at it. The row is inserted with the caller's own client, so the
// existing RLS policies decide who may upload what:
//   practical_video  any active user, for their own outlet  ("upload own media")
//   training_video   holders of module.author               ("upload training media")
import { handle, HttpError, json, requireUser, userClient } from "../_shared/http.ts";
import { createDirectUpload, STREAM_BUCKET } from "../_shared/cloudflare.ts";

const LIMITS: Record<string, number> = {
  practical_video: 5 * 60, // trainees record short practical tests
  training_video: 30 * 60,
};

Deno.serve(handle(async (req) => {
  const client = userClient(req);
  const user = await requireUser(client);
  const { kind, max_duration_seconds } = await req.json();
  if (!(kind in LIMITS)) throw new HttpError(400, "kind must be practical_video or training_video");

  let outletId: string | null = null;
  if (kind === "practical_video") {
    const { data: me } = await client.from("profiles").select("outlet_id").eq("id", user.id).single();
    outletId = me?.outlet_id ?? null;
    if (!outletId) throw new HttpError(400, "You are not assigned to an outlet");
  }

  const maxDuration = Math.min(Number(max_duration_seconds) || LIMITS[kind], LIMITS[kind]);
  const { uid, uploadURL } = await createDirectUpload({
    maxDurationSeconds: maxDuration,
    meta: { kind, uploaded_by: user.id },
  });

  const { data: media, error } = await client.from("media_files").insert({
    bucket: STREAM_BUCKET,
    object_key: uid,
    kind,
    mime_type: "video/mp4",
    status: "uploading",
    uploaded_by: user.id,
    outlet_id: outletId,
  }).select("id").single();
  if (error) throw new HttpError(403, `Not allowed to upload this video: ${error.message}`);

  return json({ media_file_id: media.id, uid, upload_url: uploadURL });
}));
