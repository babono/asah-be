// AI photo check worker (spec: AI photo check for SOP checklists).
// Called every minute by pg_cron + pg_net with `Authorization: Bearer <AI_WORKER_SECRET>`.
// Deploy with --no-verify-jwt (see config.toml). Claims queued ai_photo_checks,
// sends each photo to an OpenAI-compatible vision model and stores the verdict.
//
// Secrets: AI_PROVIDER (label for logs/results), AI_BASE_URL, AI_API_KEY, AI_MODEL,
// AI_WORKER_SECRET (same value as Vault `ai_worker_secret`).
import OpenAI from "npm:openai@5";
import { serviceClient } from "../_shared/http.ts";
import { type ChatResponse, createPhotoChecker } from "./provider.ts";
import { type ClaimedCheck, handle } from "./worker.ts";

const AI_API_KEY = Deno.env.get("AI_API_KEY");
const AI_MODEL = Deno.env.get("AI_MODEL");
const AI_BASE_URL = Deno.env.get("AI_BASE_URL");
const AI_PROVIDER = Deno.env.get("AI_PROVIDER") ?? "unknown";
// Qwen3 models can "think" before answering; we only need the JSON verdict.
const EXTRA_BODY = AI_PROVIDER === "qwen" ? { enable_thinking: false } : {};

const checkPhoto = AI_API_KEY && AI_MODEL
  ? (() => {
    // No SDK retries: a failed check goes back to the queue and is retried by the next run.
    const openai = new OpenAI({ apiKey: AI_API_KEY, baseURL: AI_BASE_URL, timeout: 30_000, maxRetries: 0 });
    return createPhotoChecker({
      complete: (body) =>
        openai.chat.completions.create(
          body as unknown as OpenAI.Chat.ChatCompletionCreateParamsNonStreaming,
        ) as Promise<ChatResponse>,
    }, AI_MODEL, EXTRA_BODY);
  })()
  : null;

const supabase = serviceClient();

async function rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

Deno.serve((req) =>
  handle(req, {
    workerSecret: Deno.env.get("AI_WORKER_SECRET"),
    provider: AI_PROVIDER,
    checkPhoto,
    claim: async (limit) => (await rpc<ClaimedCheck[] | null>("ai_claim_photo_checks", { p_limit: limit })) ?? [],
    download: async (bucket, key) => {
      const { data, error } = await supabase.storage.from(bucket).download(key);
      if (error || !data) throw new Error(`download failed: ${error?.message ?? "no data"}`);
      return data;
    },
    complete: (id, result) => rpc("ai_complete_photo_check", { p_check: id, p_result: result }),
    fail: (id, message) => rpc("ai_fail_photo_check", { p_check: id, p_error: message }),
  }).catch((e) => {
    console.error("ai-photo-check run failed:", e instanceof Error ? e.message : e);
    return new Response(JSON.stringify({ error: "worker error" }), { status: 500 });
  })
);
