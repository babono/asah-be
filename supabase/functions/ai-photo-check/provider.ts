// The one place that talks to the vision model. Any OpenAI-compatible API works
// (Qwen on Alibaba Cloud Model Studio, DeepSeek, OpenRouter...): switching is
// AI_BASE_URL / AI_MODEL only.
import { z } from "npm:zod@3";
import { PROMPTS } from "./prompts/index.ts";

export type PhotoCheckResult = {
  verdict: "clean" | "not_clean" | "unsure";
  confidence: number;
  right_area: boolean;
  photo_usable: boolean;
  reasons: string[];
};

export const PhotoCheckSchema = z.object({
  verdict: z.enum(["clean", "not_clean", "unsure"]),
  confidence: z.number(),
  right_area: z.boolean(),
  photo_usable: z.boolean(),
  reasons: z.array(z.string()).max(5),
});

export type CheckPhotoInput = {
  imageDataUrl: string;
  itemLabel: string;
  criteria: string;
  promptVersion: string;
};

export type CheckPhotoOutput = {
  result: PhotoCheckResult;
  raw: unknown; // the model's parsed JSON, before normalising (never the image)
  usage: { input: number; output: number };
  model: string;
};

export type CheckPhoto = (input: CheckPhotoInput) => Promise<CheckPhotoOutput>;

/** The subset of a chat completion response we read. */
export type ChatResponse = {
  choices: { message?: { content?: string | null } }[];
  usage?: { prompt_tokens?: number; completion_tokens?: number } | null;
};

/** Sends one chat completion request (an OpenAI client in production, a fake in tests). */
export type ChatClient = { complete(body: Record<string, unknown>): Promise<ChatResponse> };

/**
 * @param extraBody provider-specific request fields, e.g. `{ enable_thinking: false }` for Qwen
 *   so hybrid thinking models answer directly instead of paying for reasoning tokens.
 */
export function createPhotoChecker(
  client: ChatClient,
  model: string,
  extraBody: Record<string, unknown> = {},
): CheckPhoto {
  // Some providers reject response_format; after the first rejection, stop sending it.
  let jsonMode = true;

  async function call(messages: unknown[]): Promise<ChatResponse> {
    const body = { ...extraBody, model, temperature: 0, messages };
    if (jsonMode) {
      try {
        return await client.complete({ ...body, response_format: { type: "json_object" } });
      } catch (e) {
        if ((e as { status?: number })?.status !== 400) throw e;
        jsonMode = false;
      }
    }
    return await client.complete(body);
  }

  return async ({ imageDataUrl, itemLabel, criteria, promptVersion }) => {
    const prompt = PROMPTS[promptVersion];
    if (!prompt) throw new Error(`unknown prompt version ${promptVersion}`);
    const messages = [
      { role: "system", content: prompt.SYSTEM },
      {
        role: "user",
        content: [
          { type: "text", text: prompt.userText(itemLabel, criteria) },
          { type: "image_url", image_url: { url: imageDataUrl } },
        ],
      },
    ];

    const usage = { input: 0, output: 0 };
    for (let attempt = 0; attempt < 2; attempt++) {
      const res = await call(messages);
      usage.input += res.usage?.prompt_tokens ?? 0;
      usage.output += res.usage?.completion_tokens ?? 0;
      const parsed = PhotoCheckSchema.safeParse(extractJson(res.choices[0]?.message?.content ?? ""));
      if (parsed.success) return { result: normalise(parsed.data), raw: parsed.data, usage, model };
    }
    throw new Error("model returned invalid output twice");
  };
}

/** Clamp confidence, force "unsure" when the photo can't be judged, trim reasons. */
export function normalise(r: PhotoCheckResult): PhotoCheckResult {
  return {
    verdict: r.right_area && r.photo_usable ? r.verdict : "unsure",
    confidence: Math.min(1, Math.max(0, r.confidence)),
    right_area: r.right_area,
    photo_usable: r.photo_usable,
    reasons: r.reasons.slice(0, 3).map((s) => s.slice(0, 200)),
  };
}

/** Parses the text as JSON, or else the first balanced {...} object inside it. */
export function extractJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    // fall through: look for an object wrapped in prose or a code fence
  }
  const start = text.indexOf("{");
  if (start < 0) return undefined;
  let depth = 0;
  let inString = false;
  for (let i = start; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (ch === "\\") i++;
      else if (ch === '"') inString = false;
    } else if (ch === '"') inString = true;
    else if (ch === "{") depth++;
    else if (ch === "}" && --depth === 0) {
      try {
        return JSON.parse(text.slice(start, i + 1));
      } catch {
        return undefined;
      }
    }
  }
  return undefined;
}
