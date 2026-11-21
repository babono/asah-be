// Cloudflare Stream API (https://developers.cloudflare.com/stream/)
import { HttpError } from "./http.ts";

const ACCOUNT_ID = Deno.env.get("CLOUDFLARE_ACCOUNT_ID");
const API_TOKEN = Deno.env.get("CLOUDFLARE_STREAM_API_TOKEN");
// The "customer-<code>" part of https://customer-<code>.cloudflarestream.com
export const CUSTOMER_CODE = Deno.env.get("CLOUDFLARE_STREAM_CUSTOMER_CODE");

export const STREAM_BUCKET = "cloudflare-stream";

async function cf(path: string, init: RequestInit = {}) {
  if (!ACCOUNT_ID || !API_TOKEN) throw new HttpError(500, "Cloudflare Stream is not configured");
  const res = await fetch(`https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/stream${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${API_TOKEN}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
  const body = await res.json();
  if (!res.ok || body.success === false) {
    throw new HttpError(502, `Cloudflare Stream: ${JSON.stringify(body.errors ?? body)}`);
  }
  return body.result;
}

/** One-time upload URL the app POSTs the file to (multipart, field "file"). */
export async function createDirectUpload(opts: { maxDurationSeconds: number; meta: Record<string, string> }) {
  const result = await cf("/direct_upload", {
    method: "POST",
    body: JSON.stringify({
      maxDurationSeconds: opts.maxDurationSeconds,
      requireSignedURLs: true,
      meta: opts.meta,
    }),
  });
  return { uid: result.uid as string, uploadURL: result.uploadURL as string };
}

/** Short-lived signed token for a video that requires signed URLs. */
export async function signedToken(uid: string, opts: { downloadable?: boolean; ttlSeconds?: number } = {}) {
  const exp = Math.floor(Date.now() / 1000) + (opts.ttlSeconds ?? 3600);
  const result = await cf(`/${uid}/token`, {
    method: "POST",
    body: JSON.stringify({ exp, downloadable: opts.downloadable ?? false }),
  });
  return { token: result.token as string, exp };
}

/** Makes an MP4 rendition available for offline download (idempotent). */
export async function enableDownload(uid: string): Promise<{ status: string; percentComplete: number }> {
  const result = await cf(`/${uid}/downloads`, { method: "POST" });
  const d = result.default ?? {};
  return { status: d.status ?? "inprogress", percentComplete: d.percentComplete ?? 0 };
}

export function streamUrls(token: string) {
  if (!CUSTOMER_CODE) throw new HttpError(500, "CLOUDFLARE_STREAM_CUSTOMER_CODE is not set");
  const base = `https://customer-${CUSTOMER_CODE}.cloudflarestream.com/${token}`;
  return {
    hls: `${base}/manifest/video.m3u8`,
    mp4: `${base}/downloads/default.mp4`,
    thumbnail: `${base}/thumbnails/thumbnail.jpg`,
  };
}
