// One worker run: claim queued checks, judge each photo, save the result.
// Kept free of Deno.env and network clients so it can be tested with fakes;
// index.ts wires in the real Supabase and model clients.
import { encodeBase64 } from "jsr:@std/encoding@1/base64";
import type { CheckPhoto } from "./provider.ts";

export const BATCH_SIZE = 10;
export const CONCURRENCY = 3;
export const MAX_FILE_BYTES = 5 * 1024 * 1024;

/** A row returned by rpc ai_claim_photo_checks. */
export type ClaimedCheck = {
  check_id: string;
  bucket: string;
  object_key: string;
  criteria: string;
  item_label: string;
  prompt_version: string;
  locale: string;
};

export type WorkerDeps = {
  workerSecret: string | undefined;
  provider: string;
  /** null when AI_API_KEY / AI_MODEL are not set: nothing is claimed. */
  checkPhoto: CheckPhoto | null;
  claim(limit: number): Promise<ClaimedCheck[]>;
  download(bucket: string, key: string): Promise<Blob>;
  complete(checkId: string, result: Record<string, unknown>): Promise<void>;
  fail(checkId: string, error: string): Promise<void>;
  log?: (line: string) => void;
};

function respond(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

export async function handle(req: Request, deps: WorkerDeps): Promise<Response> {
  if (!deps.workerSecret || req.headers.get("Authorization") !== `Bearer ${deps.workerSecret}`) {
    return respond({ error: "Unauthorized" }, 401);
  }
  // Without a model there is no point claiming rows: it would only burn attempts.
  if (!deps.checkPhoto) return respond({ error: "AI_API_KEY or AI_MODEL is not set" }, 500);

  const claimed = await deps.claim(BATCH_SIZE);
  const outcomes = await mapPool(claimed, CONCURRENCY, (c) => processCheck(c, deps));
  const done = outcomes.filter(Boolean).length;
  return respond({ claimed: claimed.length, done, failed: claimed.length - done });
}

/** Returns true when the check was completed, false when it was recorded as failed. */
export async function processCheck(c: ClaimedCheck, deps: WorkerDeps): Promise<boolean> {
  const log = deps.log ?? console.log;
  const started = Date.now();
  try {
    const file = await deps.download(c.bucket, c.object_key);
    if (file.size > MAX_FILE_BYTES) throw new Error("file too large");
    const mime = file.type.startsWith("image/") ? file.type : "image/jpeg";
    const imageDataUrl = `data:${mime};base64,${encodeBase64(new Uint8Array(await file.arrayBuffer()))}`;

    const modelStarted = Date.now();
    const out = await deps.checkPhoto!({
      imageDataUrl,
      itemLabel: c.item_label,
      criteria: c.criteria,
      promptVersion: c.prompt_version,
    });
    const latency = Date.now() - modelStarted;

    await deps.complete(c.check_id, {
      ...out.result,
      raw: out.raw,
      provider: deps.provider,
      model: out.model,
      input_tokens: out.usage.input,
      output_tokens: out.usage.output,
      latency_ms: latency,
    });
    log(`ai-photo-check ${c.check_id} ${out.result.verdict} ${Date.now() - started}ms`);
    return true;
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    log(`ai-photo-check ${c.check_id} failed ${Date.now() - started}ms: ${message}`);
    try {
      await deps.fail(c.check_id, message);
    } catch (e2) {
      // The row stays 'running'; app.requeue_stale_ai_checks puts it back later.
      log(`ai-photo-check ${c.check_id} could not record failure: ${e2 instanceof Error ? e2.message : e2}`);
    }
    return false;
  }
}

async function mapPool<T, R>(items: T[], size: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const run = async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]);
    }
  };
  await Promise.all(Array.from({ length: Math.min(size, items.length) }, run));
  return results;
}
