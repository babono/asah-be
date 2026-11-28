# asah-be · ASAH backend

Supabase backend for ASAH (Juta Berlian Culinary), used by both clients:

- [asah-app](https://github.com/babono/asah-app): Flutter phone app (staff, mentors, outlet and area managers)
- [asah-admin](https://github.com/babono/asah-admin): web admin (HQ admin, trainers, training manager, HR)

Postgres with row-level security on every table and permission-checked RPCs, Auth with phone OTP,
Storage for photos and PDFs, Edge Functions, Realtime. Videos are on Cloudflare Stream; push goes
through OneSignal.

```
supabase/
  migrations/
    20261118000000_asah_mvp_schema.sql   the MVP schema: 48 tables, RLS, RPCs, default roles (see SCHEMA.md)
    20261121000000_app_support.sql       additions found while building the app (below)
    20261123000000_formal_trainings.sql  formal training sessions between mentor and trainee (below)
  functions/
    stream-upload     Cloudflare Stream basic direct upload (≤200 MB) + media_files row; used by the phone app
    stream-tus-upload resumable tus upload (any size) + media_files row; used by the admin web
    stream-playback   signed HLS / MP4 URLs, only if the caller can read the media_files row
    stream-webhook    Cloudflare callback: marks videos ready / failed with duration
    admin-users       creates staff accounts (one or a spreadsheet import) with the Staff role
    push              sends each new notifications row through OneSignal
  tests/              behaviour tests, run in PGlite (npm run test:db)
  bootstrap_first_admin.sql   makes the first HQ admin
  seed_example.sql            example org, checklists, module and path for testing
  seed_demo.sql               the client demo: 5 outlets, 23 people, 4 weeks of history (see Demo)
  demo_reset.sql              empties the data so seed_demo.sql can run again
  SCHEMA.md                   tables by module and how access works
```

## Setup

```bash
supabase link --project-ref <ref>
supabase db push
```

In the dashboard:

1. **Database › Extensions**: enable `pg_cron` (`pg_net` is enabled by the second migration). Run the
   `cron.schedule` lines at the end of both migrations.
2. **Authentication › Providers › Phone**: enable it with an SMS provider (Twilio, Vonage,
   MessageBird...). For development, add test numbers with fixed OTPs. Sign-ups stay off; HQ
   creates accounts.
3. **First admin**: add a user with a phone in Authentication › Users, then run
   `supabase/bootstrap_first_admin.sql` with that phone.
4. Optional: `supabase/seed_example.sql` for test data (replace names before the pilot).

### Edge Functions and secrets

```bash
supabase secrets set \
  CLOUDFLARE_ACCOUNT_ID=... CLOUDFLARE_STREAM_API_TOKEN=... CLOUDFLARE_STREAM_CUSTOMER_CODE=... \
  CLOUDFLARE_STREAM_WEBHOOK_SECRET=... \
  ONESIGNAL_APP_ID=... ONESIGNAL_REST_API_KEY=... PUSH_HOOK_SECRET=<random>

supabase functions deploy stream-upload stream-tus-upload stream-playback admin-users
supabase functions deploy stream-webhook push --no-verify-jwt
```

**Cloudflare Stream**: create an API token with *Stream: Edit*. The customer code is in any Stream
URL (`https://customer-<code>.cloudflarestream.com/...`). Videos require signed URLs. Register the
webhook and store the returned secret as `CLOUDFLARE_STREAM_WEBHOOK_SECRET`:

```bash
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/stream/webhook" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"notificationUrl":"https://<ref>.supabase.co/functions/v1/stream-webhook"}'
```

**Push**: store the hook in Vault so the `notifications_push` trigger can call the `push` function.
Until then notifications still show in the app's inbox.

```sql
select vault.create_secret('https://<ref>.supabase.co/functions/v1/push', 'push_hook_url');
select vault.create_secret('<same value as PUSH_HOOK_SECRET>', 'push_hook_secret');
```

## Demo

The live project (`ovrmicpviebbysbeupdg`) holds mock data for the client demo from `seed_demo.sql`:
Dapur Berlian (Seminyak, Canggu, Sanur) and Kopi Berlian (Kuta, Renon), 23 people, six modules and
four weeks of checklist history, issues, audits and mentor ratings. Only the training video
"3 Seconds Rule of Eye Contact" is real; it is in Storage (`asah-media/training/8a000000-…-0001.mp4`,
compressed to 1080p), not Cloudflare Stream yet. `require_geofence` is off so checklists can be
submitted away from the outlets.

Sign-in uses Supabase test numbers, so no SMS is sent. In the dashboard, **Authentication ›
Sign In / Providers › Phone**: enable it, pick any SMS provider with placeholder credentials (it is
never called for test numbers) and set **Test phone numbers and OTPs** to

```
6281100000001=123456,6281100000002=123456,6281100000003=123456,6281100000004=123456,6281100000005=123456,6281100000006=123456,6281100000007=123456
```

| Phone (+62) | Person | Use it to show |
| --- | --- | --- |
| 811 0000 001 | Rina Wijaya, HQ admin + HQ trainer | Admin web: setup, modules, checklists, dashboards |
| 811 0000 002 | Dewi Lestari, Training manager + HR | Admin web: approve "Handling guest complaints", mentor ratings |
| 811 0000 003 | Budi Santoso, Area manager (Badung, Denpasar) | App: area view, audit visit |
| 811 0000 004 | Made Ayu Pratiwi, Outlet manager, Seminyak | App: team, accept the chiller fix, assign issues |
| 811 0000 005 | Komang Adi Saputra, Captain + Mentor, Seminyak | App: mentor Putu (formal training tomorrow; answer Putu's new request), fix the soap dispenser issue |
| 811 0000 006 | Putu Sari Dewi, new Server, Seminyak (day 4) | App: eye-contact video and quiz, checklists, formal training with Komang |
| 811 0000 007 | Wayan Darma, Cook + Mentor, Seminyak | App: fridge temperature log, mentee behind on training |

Dates are relative to when the seed ran, and every day nobody fills the checklists they turn
"missed". The morning of a demo, start again with fresh dates (deletes everything except roles,
permissions, settings and auth users):

```bash
supabase link --project-ref ovrmicpviebbysbeupdg
npm run demo:reset
```

`npm run test:seed` checks the seed (and a reset + reseed) in PGlite first.

## Contract for clients

- Sign in with `signInWithOtp(phone, shouldCreateUser: false)` then `verifyOTP(type: sms)`.
- Read what the user may do with `rpc('my_permissions')` (permission, scope type, scope id). The
  server checks every action again; clients only hide what would be refused.
- State changes with business rules go through RPCs (`submit_checklist_run`, `start_quiz_attempt`,
  `submit_quiz_attempt`, `score_practical`, `assign_mentor`, `raise_issue`, `assign_issue`,
  `fix_issue`, `verify_issue`, `review_module_version`, ...). See `SCHEMA.md`.
- Photos and PDFs: upload to bucket `asah-media` (`personal/<outlet>/<user>/<uuid>.jpg` or
  `training/<uuid>.<ext>`), then insert a `media_files` row; read with signed URLs.
- Videos: Cloudflare Stream; until it is configured, the app stores practical videos in `asah-media`
  and `stream-playback` returns a signed Storage URL for any video there. Either call `stream-upload` and POST the file (multipart, field `file`) to the returned URL,
  or use a tus client with endpoint `functions/v1/stream-tus-upload?kind=training_video|practical_video`
  (the media id comes back in the `X-Media-File-Id` header). Play with `stream-playback`.
- Names of colleagues: `rpc('people_names', {p_ids})`.
- Formal training: read `formal_trainings` (mentor, trainee, and anyone with `mentorship.view`
  or `mentorship.manage` at the outlet); write only through `request_formal_training`,
  `respond_formal_training` and `cancel_formal_training` (see below).

## What `20261121000000_app_support.sql` adds

The MVP schema is unchanged; this migration fills gaps:

| Gap | Fix |
| --- | --- |
| A trainee could not read their mentor's profile | Policy `trainee reads own mentor` |
| Staff could not see colleagues' names in issue timelines without `user.view` | RPC `people_names(ids)`, limited to people the caller works with |
| Area managers (no outlet of their own) could not upload audit photos | Policy `upload media for outlets in scope` |
| No storage bucket for photos and PDFs | Private bucket `asah-media`; reading an object requires reading its `media_files` row |
| Reminders for A2, M3, M4 were not scheduled | `app.remind_due_checklists`, `app.remind_mentor_checkins`, `app.escalate_behind_trainees` |
| `notifications` rows never reached phones | Trigger → `pg_net` → `push` function → OneSignal; Realtime on `notifications` |

## What `20261123000000_formal_trainings.sql` adds

A formal "on the spot" training session (Asuh) between a mentor and their trainee:

| RPC | Who | What |
| --- | --- | --- |
| `request_formal_training(p_mentorship, p_scheduled_at, p_topic, p_note?, p_duration_minutes? = 30)` → id | mentor or trainee of an active mentorship | future time, non-empty topic, no overlap with a pending or approved session; notifies the other side (`formal_training_requested`) |
| `respond_formal_training(p_training, p_approve, p_note?)` | the other side, not the requester | before the start time only; notifies the requester (`formal_training_approved` / `_declined`); approving also notifies everyone with `mentorship.view` at the outlet (`formal_training_scheduled`) |
| `cancel_formal_training(p_training, p_reason?)` | mentor or trainee | pending or approved only; notifies the other side, and the higher-ups if it was approved (`formal_training_cancelled`) |

Every notification carries `data = {formal_training_id, mentorship_id, scheduled_at}`. Ending a
mentorship cancels its upcoming sessions.

## Deploying

There is one Supabase project for the MVP (the live one), so deploys are manual:

1. Merge to `main`. The **Test** workflow runs on every PR and push.
2. GitHub › Actions › **Deploy** › Run workflow. Leave *Dry run* on first to see which migrations
   would apply, then run again with it off.

Repository secrets: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID`, `SUPABASE_DB_PASSWORD`.
Edge Function secrets (Cloudflare, OneSignal) are set once with `supabase secrets set`.
To require a second approver, add reviewers to the `production` environment in the repo settings.

Never change the schema in the dashboard: write a migration, so the repo stays the source of truth.

## Checks

```bash
npm install
npm run test:db          # migrations + 98 behaviour checks in PGlite (Postgres in WASM), no Docker
npm run test:seed        # migrations + seed_demo.sql, then reset and seed again
npm run check:functions  # type-checks the Edge Functions with Deno
```

`test:db` runs `00_supabase_stub.sql` (auth, storage, vault and pg_net stand-ins), the migrations,
then `10_behaviour_tests.sql` (40 checks: least privilege, separation of duties, quiz grading,
practical tests, checklist submit with geofence, issues, anonymous ratings, deactivation) and
`20_app_support_tests.sql` (25 checks for the second migration) and `30_formal_training_tests.sql`
(33 checks: request, approve, decline rules, visibility by outlet, overlap, expiry, cancel,
notifications, no direct writes).

Not covered yet: the Edge Functions against live Cloudflare Stream and OneSignal, and pg_cron
scheduling (the job functions themselves are tested).
