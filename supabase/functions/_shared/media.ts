// Shared rules for creating a media_files row for a Stream video.
import { SupabaseClient, User } from "jsr:@supabase/supabase-js@2";
import { HttpError } from "./http.ts";
import { STREAM_BUCKET } from "./cloudflare.ts";

/** Supabase Storage bucket for photos, PDFs and Storage-hosted videos. */
export const MEDIA_BUCKET = "asah-media";

export const VIDEO_LIMITS: Record<string, number> = {
  practical_video: 5 * 60, // trainees record short practical tests
  training_video: 30 * 60,
};

export function checkKind(kind: unknown): asserts kind is keyof typeof VIDEO_LIMITS {
  if (typeof kind !== "string" || !(kind in VIDEO_LIMITS)) {
    throw new HttpError(400, "kind must be practical_video or training_video");
  }
}

/** Practical videos belong to the uploader's outlet. */
export async function outletFor(client: SupabaseClient, user: User, kind: string): Promise<string | null> {
  if (kind !== "practical_video") return null;
  const { data: me } = await client.from("profiles").select("outlet_id").eq("id", user.id).single();
  if (!me?.outlet_id) throw new HttpError(400, "You are not assigned to an outlet");
  return me.outlet_id;
}

/**
 * Inserted with the caller's own client, so RLS decides who may upload what:
 * practical_video for the caller's outlet, training_video for module.author.
 */
export async function insertVideoRow(
  client: SupabaseClient,
  opts: { uid: string; kind: string; userId: string; outletId: string | null; size?: number },
): Promise<string> {
  const { data, error } = await client.from("media_files").insert({
    bucket: STREAM_BUCKET,
    object_key: opts.uid,
    kind: opts.kind,
    mime_type: "video/mp4",
    size_bytes: opts.size ?? null,
    status: "uploading",
    uploaded_by: opts.userId,
    outlet_id: opts.outletId,
  }).select("id").single();
  if (error) throw new HttpError(403, `Not allowed to upload this video: ${error.message}`);
  return data.id as string;
}
