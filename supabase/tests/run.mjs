// Runs the migrations and the behaviour tests in PGlite (Postgres in WASM):
//   npm install && npm run test:db
// No Docker, no Supabase project. Supabase-only pieces (auth, storage, vault,
// pg_net, publications) are stubbed by 00_supabase_stub.sql and below.
import { PGlite } from "@electric-sql/pglite";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const migrations = join(here, "..", "migrations");

const extraStub = `
create schema if not exists extensions;
create schema if not exists storage;
create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text);
alter table storage.objects enable row level security;
grant usage on schema storage to authenticated;
grant all on storage.objects, storage.buckets to authenticated;
create function storage.foldername(name text) returns text[] language sql immutable as $$ select string_to_array(name, '/') $$;
create schema if not exists vault;
create table vault.decrypted_secrets (name text, decrypted_secret text);
create schema if not exists net;
create function net.http_post(url text, headers jsonb, body jsonb) returns bigint language sql as $$ select 0::bigint $$;
`;

const adapt = (sql) =>
  sql
    .replace(/^\s*create extension[^;]*;/gim, "")
    .replace(/^\s*alter publication[^;]*;/gim, "")
    .split("\n")
    .filter((l) => !l.startsWith("\\")) // psql meta-commands
    .join("\n");

const notices = [];
const db = new PGlite();
const onNotice = (n) => notices.push(n.message);

const run = async (label, sql) => {
  try {
    await db.exec(sql, { onNotice });
  } catch (e) {
    console.error(`\n✗ ${label}: ${e.message}`);
    for (const n of notices.splice(0)) console.log(`  ${n}`);
    process.exit(1);
  }
};

await run("supabase stub", readFileSync(join(here, "00_supabase_stub.sql"), "utf8") + extraStub);
for (const f of readdirSync(migrations).filter((x) => x.endsWith(".sql")).sort()) {
  await run(f, adapt(readFileSync(join(migrations, f), "utf8")));
  console.log(`applied ${f}`);
}
for (const f of readdirSync(here).filter((x) => /^\d+_.*test.*\.sql$/.test(x)).sort()) {
  await run(f, adapt(readFileSync(join(here, f), "utf8")));
  const oks = notices.splice(0).filter((n) => n.startsWith("ok"));
  for (const n of oks) console.log(`  ${n}`);
  console.log(`✓ ${f}: ${oks.length} checks passed`);
}
await db.close();
