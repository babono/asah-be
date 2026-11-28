// deno test supabase/functions/ai-photo-check   (no network, no Supabase: everything is faked)
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import { type ChatClient, type ChatResponse, createPhotoChecker, extractJson } from "./provider.ts";
import { type ClaimedCheck, handle, MAX_FILE_BYTES, type WorkerDeps } from "./worker.ts";

const SECRET = "test-secret";
const CHECK: ClaimedCheck = {
  check_id: "c1",
  bucket: "checklist-photos",
  object_key: "f1/run1/toilet.jpg",
  criteria: "Floor dry, no rubbish on the floor",
  item_label: "Toilet clean",
  prompt_version: "clean-v1",
  locale: "id",
};
const GOOD = {
  verdict: "not_clean",
  confidence: 0.92,
  right_area: true,
  photo_usable: true,
  reasons: ["Tisu berserakan di lantai"],
};

const reply = (content: string): ChatResponse => ({
  choices: [{ message: { content } }],
  usage: { prompt_tokens: 700, completion_tokens: 100 },
});

/** A fake model that answers from a script; a function entry is called (e.g. to throw). */
function fakeClient(script: (ChatResponse | ((body: Record<string, unknown>) => ChatResponse))[]) {
  const calls: Record<string, unknown>[] = [];
  const client: ChatClient = {
    complete: (body) => {
      calls.push(body);
      const next = script.shift();
      if (!next) throw new Error("unexpected model call");
      return Promise.resolve(typeof next === "function" ? next(body) : next);
    },
  };
  return { client, calls };
}

function setup(client: ChatClient, opts: { file?: Blob; claimed?: ClaimedCheck[] } = {}) {
  const completed: { id: string; result: Record<string, unknown> }[] = [];
  const failed: { id: string; error: string }[] = [];
  let claimCalls = 0;
  const deps: WorkerDeps = {
    workerSecret: SECRET,
    provider: "qwen",
    checkPhoto: createPhotoChecker(client, "qwen3-vl-plus"),
    claim: () => {
      claimCalls++;
      return Promise.resolve(opts.claimed ?? [CHECK]);
    },
    download: () => Promise.resolve(opts.file ?? new Blob([new Uint8Array([0xff, 0xd8, 0xff])], { type: "image/jpeg" })),
    complete: (id, result) => {
      completed.push({ id, result });
      return Promise.resolve();
    },
    fail: (id, error) => {
      failed.push({ id, error });
      return Promise.resolve();
    },
    log: () => {},
  };
  const run = (secret = SECRET) =>
    handle(new Request("http://x", { method: "POST", headers: { Authorization: `Bearer ${secret}` } }), deps);
  return { deps, run, completed, failed, claimCalls: () => claimCalls };
}

Deno.test("valid JSON is saved with usage, provider and model", async () => {
  const { client, calls } = fakeClient([reply(JSON.stringify(GOOD))]);
  const t = setup(client);
  const res = await t.run();
  assertEquals(await res.json(), { claimed: 1, done: 1, failed: 0 });
  const r = t.completed[0].result;
  assertEquals([r.verdict, r.confidence, r.provider, r.model], ["not_clean", 0.92, "qwen", "qwen3-vl-plus"]);
  assertEquals([r.input_tokens, r.output_tokens], [700, 100]);
  assertEquals(r.raw, GOOD);
  assert(typeof r.latency_ms === "number");
  // temperature 0, JSON mode, image sent as a data URL
  assertEquals(calls[0].temperature, 0);
  assertEquals(calls[0].response_format, { type: "json_object" });
  const user = (calls[0].messages as { content: unknown }[])[1].content as { type: string; image_url?: { url: string } }[];
  assertMatch(user[1].image_url!.url, /^data:image\/jpeg;base64,/);
  assert(!JSON.stringify(r).includes("base64"), "the image is never stored");
});

Deno.test("JSON wrapped in text is extracted", async () => {
  const { client } = fakeClient([reply("Here is my answer:\n```json\n" + JSON.stringify(GOOD) + "\n```")]);
  const t = setup(client);
  await t.run();
  assertEquals(t.completed[0].result.verdict, "not_clean");
});

Deno.test("invalid output is retried once, then the valid answer is used", async () => {
  const { client, calls } = fakeClient([reply("not json at all"), reply(JSON.stringify(GOOD))]);
  const t = setup(client);
  await t.run();
  assertEquals(calls.length, 2);
  assertEquals(t.completed.length, 1);
  assertEquals(t.completed[0].result.input_tokens, 1400, "tokens of both calls are counted");
});

Deno.test("invalid output twice fails the check", async () => {
  const { client } = fakeClient([reply('{"verdict":"dirty"}'), reply("nope")]);
  const t = setup(client);
  const res = await t.run();
  assertEquals(await res.json(), { claimed: 1, done: 0, failed: 1 });
  assertEquals(t.failed, [{ id: "c1", error: "model returned invalid output twice" }]);
});

Deno.test("right_area false forces verdict unsure", async () => {
  const { client } = fakeClient([reply(JSON.stringify({ ...GOOD, right_area: false }))]);
  const t = setup(client);
  await t.run();
  assertEquals(t.completed[0].result.verdict, "unsure");
});

Deno.test("confidence is clamped and reasons are trimmed", async () => {
  const long = "x".repeat(300);
  const { client } = fakeClient([reply(JSON.stringify({ ...GOOD, confidence: 1.7, reasons: [long, "b", "c", "d"] }))]);
  const t = setup(client);
  await t.run();
  const r = t.completed[0].result;
  assertEquals(r.confidence, 1);
  assertEquals((r.reasons as string[]).length, 3);
  assertEquals((r.reasons as string[])[0].length, 200);
});

Deno.test("provider timeout fails the check", async () => {
  const { client } = fakeClient([() => {
    throw Object.assign(new Error("Request timed out."), { name: "APIConnectionTimeoutError" });
  }]);
  const t = setup(client);
  await t.run();
  assertEquals(t.failed, [{ id: "c1", error: "Request timed out." }]);
  assertEquals(t.completed.length, 0);
});

Deno.test("a provider that rejects response_format is retried without it", async () => {
  const { client, calls } = fakeClient([
    () => {
      throw Object.assign(new Error("response_format is not supported"), { status: 400 });
    },
    reply(JSON.stringify(GOOD)),
  ]);
  const t = setup(client);
  await t.run();
  assertEquals(calls.length, 2);
  assertEquals(calls[1].response_format, undefined);
  assertEquals(t.completed.length, 1);
});

Deno.test("files over 5 MB fail without calling the model", async () => {
  const { client, calls } = fakeClient([]);
  const t = setup(client, { file: new Blob([new Uint8Array(MAX_FILE_BYTES + 1)], { type: "image/jpeg" }) });
  await t.run();
  assertEquals(calls.length, 0);
  assertEquals(t.failed[0].error, "file too large");
});

Deno.test("wrong bearer secret gets 401 and claims nothing", async () => {
  const { client } = fakeClient([]);
  const t = setup(client);
  const res = await t.run("wrong");
  assertEquals(res.status, 401);
  await res.body?.cancel();
  assertEquals(t.claimCalls(), 0);
});

Deno.test("without a configured model nothing is claimed", async () => {
  const { client } = fakeClient([]);
  const t = setup(client);
  t.deps.checkPhoto = null;
  const res = await t.run();
  assertEquals(res.status, 500);
  await res.body?.cancel();
  assertEquals(t.claimCalls(), 0);
});

Deno.test("one failing check does not stop the others", async () => {
  const claimed = ["a", "b", "c", "d"].map((id) => ({ ...CHECK, check_id: id }));
  const { client } = fakeClient([
    reply(JSON.stringify(GOOD)),
    () => {
      throw new Error("boom");
    },
    reply(JSON.stringify(GOOD)),
    reply(JSON.stringify(GOOD)),
  ]);
  const t = setup(client, { claimed });
  const res = await t.run();
  assertEquals(await res.json(), { claimed: 4, done: 3, failed: 1 });
});

Deno.test("provider-specific fields are sent with every request", async () => {
  const { client, calls } = fakeClient([reply(JSON.stringify(GOOD))]);
  const checkPhoto = createPhotoChecker(client, "qwen3-vl-plus", { enable_thinking: false });
  await checkPhoto({ imageDataUrl: "data:image/jpeg;base64,AA==", itemLabel: "x", criteria: "y", promptVersion: "clean-v1" });
  assertEquals(calls[0].enable_thinking, false);
  assertEquals(calls[0].model, "qwen3-vl-plus");
});

Deno.test("extractJson handles braces inside strings", () => {
  assertEquals(extractJson('ok {"reasons":["a } b"],"n":1} trailing {x}'), { reasons: ["a } b"], n: 1 });
  assertEquals(extractJson("no json"), undefined);
});
