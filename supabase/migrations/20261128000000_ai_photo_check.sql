-- =============================================================================
-- ASAH: AI photo check for checklist items (e.g. "is the toilet clean?")
-- Depends on 20261118000000_asah_mvp_schema.sql
--
-- Flow: run submitted -> one queued ai_photo_checks row per photo on an
-- AI-enabled item -> Edge Function claims rows, calls the vision model,
-- completes them -> in 'flag' mode a confident "not clean" raises an issue
-- for the outlet manager. In 'shadow' mode results are stored only.
-- AI results NEVER change compliance_pct or any staff score.
-- =============================================================================

-- ---------- Types ----------
create type public.ai_verdict as enum ('clean', 'not_clean', 'unsure');
create type public.ai_check_status as enum ('queued', 'running', 'done', 'failed', 'skipped');
-- Issues raised by the AI are distinguishable from checklist failures
alter type public.issue_source add value if not exists 'ai_check';
-- A manager closed an AI-raised issue as a false alarm (nothing was fixed)
alter type public.issue_event_type add value if not exists 'dismissed';

-- ---------- Configuration on checklist items (edited by HQ admin) ----------
alter table public.checklist_items
  add column ai_check_enabled boolean not null default false,
  add column ai_criteria      text,
  add constraint checklist_items_ai_needs_photo_and_criteria check (
    not ai_check_enabled
    or (photo_rule <> 'none' or answer_type = 'photo')
       and coalesce(length(trim(ai_criteria)), 0) > 0);

-- ---------- Results ----------
create table public.ai_photo_checks (
  id                uuid primary key default gen_random_uuid(),
  run_id            uuid not null references public.checklist_runs(id) on delete cascade,
  response_id       uuid not null references public.checklist_responses(id) on delete cascade,
  media_file_id     uuid not null references public.media_files(id),
  item_id           uuid not null references public.checklist_items(id),
  outlet_id         uuid not null references public.outlets(id),
  status            public.ai_check_status not null default 'queued',
  mode              text not null check (mode in ('shadow', 'flag')),   -- mode at enqueue time
  prompt_version    text not null,
  criteria_snapshot text not null,
  provider          text,
  model             text,
  verdict           public.ai_verdict,
  confidence        numeric(4, 3) check (confidence between 0 and 1),
  right_area        boolean,
  photo_usable      boolean,
  reasons           jsonb,               -- array of short strings
  raw_response      jsonb,
  input_tokens      integer,
  output_tokens     integer,
  cost_usd          numeric(10, 6),
  latency_ms        integer,
  attempts          integer not null default 0,
  last_error        text,
  issue_id          uuid references public.issues(id),
  review_verdict    public.ai_verdict check (review_verdict is null or review_verdict <> 'unsure'),
  review_note       text,
  reviewed_by       uuid references public.profiles(id),
  reviewed_at       timestamptz,
  created_at        timestamptz not null default now(),
  started_at        timestamptz,
  completed_at      timestamptz,
  unique (media_file_id, prompt_version)
);
create index on public.ai_photo_checks (status, created_at);
create index on public.ai_photo_checks (outlet_id, created_at desc);

-- ---------- Settings ----------
-- mode: 'off' | 'shadow' | 'flag'. Start in 'shadow' for the pilot.
-- Prices: qwen3-vl-plus, Model Studio Singapore (Nov 2026). Update when the model changes.
insert into public.app_settings (key, value) values
  ('ai_photo_check', '{
     "mode": "shadow",
     "prompt_version": "clean-v1",
     "flag_min_confidence": 0.8,
     "max_attempts": 3,
     "max_checks_per_day": 2000,
     "price_per_1m_input_usd": 0.2,
     "price_per_1m_output_usd": 1.6
   }')
on conflict (key) do nothing;

-- ---------- Permissions ----------
insert into public.permissions (code, description, is_sensitive) values
  ('ai_check.review', 'Review AI photo checks and confirm or overrule them', false)
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'ai_check.review' from public.roles r
where r.name in ('Outlet manager', 'Area manager')
on conflict do nothing;

-- ---------- Enqueue when a run is submitted ----------
create or replace function app.enqueue_ai_photo_checks()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  cfg jsonb := coalesce(app.setting('ai_photo_check'), '{}'::jsonb);
begin
  if coalesce(cfg ->> 'mode', 'off') = 'off' then return new; end if;

  insert into public.ai_photo_checks
    (run_id, response_id, media_file_id, item_id, outlet_id, mode, prompt_version, criteria_snapshot)
  select new.id, x.id, ph.media_file_id, i.id, new.outlet_id,
         cfg ->> 'mode', coalesce(cfg ->> 'prompt_version', 'clean-v1'), i.ai_criteria
  from public.checklist_responses x
  join public.checklist_items i on i.id = x.item_id and i.ai_check_enabled
  join public.checklist_response_photos ph on ph.response_id = x.id
  where x.run_id = new.id
  on conflict (media_file_id, prompt_version) do nothing;
  return new;
end $$;

create trigger checklist_runs_enqueue_ai
  after update of status on public.checklist_runs
  for each row when (new.status = 'submitted' and old.status is distinct from 'submitted')
  execute function app.enqueue_ai_photo_checks();

-- ---------- Worker RPCs (service_role only; called by the Edge Function) ----------
-- Claims up to p_limit queued checks; safe with several workers (SKIP LOCKED).
create or replace function public.ai_claim_photo_checks(p_limit integer default 10)
returns table (check_id uuid, bucket text, object_key text, criteria text,
               item_label text, prompt_version text, locale text)
language plpgsql security definer set search_path = '' as $$
declare
  cfg   jsonb   := coalesce(app.setting('ai_photo_check'), '{}'::jsonb);
  quota integer := coalesce((cfg ->> 'max_checks_per_day')::int, 2000);
  used  integer;
begin
  select count(*) into used from public.ai_photo_checks
   where started_at >= date_trunc('day', now());
  if used >= quota then return; end if;

  return query
  with picked as (
    select c.id from public.ai_photo_checks c
    where c.status = 'queued'
    order by c.created_at
    limit least(p_limit, quota - used)
    for update skip locked
  )
  update public.ai_photo_checks c
     set status = 'running', attempts = c.attempts + 1, started_at = now()
    from picked
   where c.id = picked.id
  returning c.id,
            (select m.bucket from public.media_files m where m.id = c.media_file_id),
            (select m.object_key from public.media_files m where m.id = c.media_file_id),
            c.criteria_snapshot,
            (select i.label from public.checklist_items i where i.id = c.item_id),
            c.prompt_version,
            'id'::text;
end $$;

-- Saves a model result. p_result keys: verdict, confidence, right_area,
-- photo_usable, reasons, raw, provider, model, input_tokens, output_tokens, latency_ms
create or replace function public.ai_complete_photo_check(p_check uuid, p_result jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c        public.ai_photo_checks%rowtype;
  cfg      jsonb := coalesce(app.setting('ai_photo_check'), '{}'::jsonb);
  x        public.checklist_responses%rowtype;
  t        public.checklist_templates%rowtype;
  label    text;
  iss      uuid;
  in_tok   integer := (p_result ->> 'input_tokens')::int;
  out_tok  integer := (p_result ->> 'output_tokens')::int;
begin
  select * into c from public.ai_photo_checks where id = p_check for update;
  if c.status <> 'running' then raise exception 'check % is not running', p_check; end if;

  update public.ai_photo_checks set
    status        = 'done',
    completed_at  = now(),
    verdict       = (p_result ->> 'verdict')::public.ai_verdict,
    confidence    = (p_result ->> 'confidence')::numeric,
    right_area    = (p_result ->> 'right_area')::boolean,
    photo_usable  = (p_result ->> 'photo_usable')::boolean,
    reasons       = p_result -> 'reasons',
    raw_response  = p_result -> 'raw',
    provider      = p_result ->> 'provider',
    model         = p_result ->> 'model',
    input_tokens  = in_tok,
    output_tokens = out_tok,
    latency_ms    = (p_result ->> 'latency_ms')::int,
    cost_usd      = round(coalesce(in_tok, 0) * coalesce((cfg ->> 'price_per_1m_input_usd')::numeric, 0) / 1e6
                        + coalesce(out_tok, 0) * coalesce((cfg ->> 'price_per_1m_output_usd')::numeric, 0) / 1e6, 6),
    last_error    = null
  where id = c.id
  returning * into c;

  -- Flag mode: only a confident, usable, right-area "not clean" raises an issue,
  -- and only when the staff answer itself passed (a failed answer already raised one).
  select * into x from public.checklist_responses where id = c.response_id;
  if c.mode = 'flag'
     and c.verdict = 'not_clean'
     and c.confidence >= coalesce((cfg ->> 'flag_min_confidence')::numeric, 0.8)
     and c.right_area is true and c.photo_usable is true
     and x.passed then
    select t2.* into t from public.checklist_templates t2
      join public.checklist_template_versions v on v.template_id = t2.id
      join public.checklist_runs r on r.template_version_id = v.id
     where r.id = c.run_id;
    select i.label into label from public.checklist_items i where i.id = c.item_id;

    insert into public.issues (outlet_id, source, run_id, response_id, title, description, severity, due_at)
    values (c.outlet_id, 'ai_check', c.run_id, c.response_id,
            'AI flagged: ' || label,
            (select string_agg(value, '; ') from jsonb_array_elements_text(coalesce(c.reasons, '[]'::jsonb))),
            t.fail_issue_severity, now() + make_interval(hours => t.fail_issue_sla_hours))
    returning id into iss;
    insert into public.issue_events (issue_id, type, note) values (iss, 'created', 'Raised by AI photo check');
    update public.ai_photo_checks set issue_id = iss where id = c.id;
    perform app.notify(u, 'issue_created', 'AI flagged: ' || label, null, jsonb_build_object('issue_id', iss))
      from app.users_with_permission('issue.assign', c.outlet_id) u;
  end if;
end $$;

-- Records a failure; requeues until max_attempts, then marks failed.
create or replace function public.ai_fail_photo_check(p_check uuid, p_error text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  max_att integer := coalesce((app.setting('ai_photo_check') ->> 'max_attempts')::int, 3);
begin
  update public.ai_photo_checks
     set status = case when attempts >= max_att then 'failed'::public.ai_check_status
                       else 'queued'::public.ai_check_status end,
         last_error = left(p_error, 2000)
   where id = p_check and status = 'running';
end $$;

-- Checks stuck in 'running' (worker crashed) go back to the queue. Run from pg_cron.
create or replace function app.requeue_stale_ai_checks(p_after interval default interval '10 minutes')
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  update public.ai_photo_checks set status = 'queued'
   where status = 'running' and started_at < now() - p_after;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- Manager review (authenticated, ai_check.review) ----------
-- p_label: 'clean' or 'not_clean'. A "not clean" label with no issue yet raises one.
-- A "clean" label on a check whose AI issue is still open closes that issue as a
-- false alarm (event 'dismissed'). An issue already marked fixed is left to the
-- normal accept/reopen flow. Each check can be reviewed once.
create or replace function public.review_ai_photo_check(p_check uuid, p_label public.ai_verdict, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c     public.ai_photo_checks%rowtype;
  me    uuid := (select auth.uid());
  r     public.checklist_runs%rowtype;
  t     public.checklist_templates%rowtype;
  label text;
  iss   uuid;
begin
  if p_label = 'unsure' then raise exception 'review must be clean or not_clean'; end if;
  select * into c from public.ai_photo_checks where id = p_check for update;
  if c.id is null or not app.has_permission('ai_check.review', c.outlet_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into r from public.checklist_runs where id = c.run_id;
  if r.submitted_by = me then
    raise exception 'you cannot review your own checklist' using errcode = '42501';
  end if;
  if c.status <> 'done' then raise exception 'check has no AI result yet'; end if;
  if c.review_verdict is not null then raise exception 'check was already reviewed'; end if;

  update public.ai_photo_checks
     set review_verdict = p_label, review_note = p_note, reviewed_by = me, reviewed_at = now()
   where id = c.id;

  if p_label = 'not_clean' and c.issue_id is null then
    select t2.* into t from public.checklist_templates t2
      join public.checklist_template_versions v on v.template_id = t2.id
     where v.id = r.template_version_id;
    select i.label into label from public.checklist_items i where i.id = c.item_id;
    insert into public.issues (outlet_id, source, run_id, response_id, title, description, severity, raised_by, due_at)
    values (c.outlet_id, 'ai_check', c.run_id, c.response_id, 'Not clean: ' || label, p_note,
            t.fail_issue_severity, me, now() + make_interval(hours => t.fail_issue_sla_hours))
    returning id into iss;
    insert into public.issue_events (issue_id, actor_id, type, note) values (iss, me, 'created', 'Confirmed on AI review');
    update public.ai_photo_checks set issue_id = iss where id = c.id;
  elsif p_label = 'clean' and c.issue_id is not null then
    update public.issues set status = 'closed', closed_by = me, closed_at = now()
     where id = c.issue_id and source = 'ai_check' and status = 'open';
    if found then
      insert into public.issue_events (issue_id, actor_id, type, note)
      values (c.issue_id, me, 'dismissed', coalesce('False alarm (AI review): ' || p_note, 'False alarm (AI review)'));
    end if;
  end if;
end $$;

-- ---------- RLS ----------
alter table public.ai_photo_checks enable row level security;
create policy "active users only" on public.ai_photo_checks as restrictive for all to authenticated
  using (app.is_active_user()) with check (app.is_active_user());
create policy "read ai checks in scope" on public.ai_photo_checks for select to authenticated
  using (app.has_permission('ai_check.review', outlet_id) or app.has_permission('checklist.view', outlet_id));
-- No insert/update/delete policies: writes only through the functions above.
-- Reviewers must be able to open the photo (signed URL), even without checklist.view.
create policy "read checklist photos for AI review" on public.media_files for select to authenticated
  using (kind = 'checklist_photo' and app.has_permission('ai_check.review', outlet_id));

-- ---------- Grants ----------
revoke all on public.ai_photo_checks from anon;
revoke execute on function public.ai_claim_photo_checks(integer)   from public, anon, authenticated;
revoke execute on function public.ai_complete_photo_check(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.ai_fail_photo_check(uuid, text)  from public, anon, authenticated;
grant  execute on function public.ai_claim_photo_checks(integer)   to service_role;
grant  execute on function public.ai_complete_photo_check(uuid, jsonb) to service_role;
grant  execute on function public.ai_fail_photo_check(uuid, text)  to service_role;
revoke execute on function public.review_ai_photo_check(uuid, public.ai_verdict, text) from public, anon;
grant  execute on function public.review_ai_photo_check(uuid, public.ai_verdict, text) to authenticated;
revoke execute on function app.enqueue_ai_photo_checks() from public, anon, authenticated;
revoke execute on function app.requeue_stale_ai_checks(interval) from public, anon, authenticated;

-- ---------- Evaluation view (shadow mode) ----------
create view public.v_ai_check_agreement with (security_invoker = true) as
select c.outlet_id, c.item_id, c.prompt_version, c.model,
       count(*) filter (where c.status = 'done')                                    as checked,
       count(*) filter (where c.review_verdict is not null)                         as reviewed,
       count(*) filter (where c.review_verdict is not null and c.verdict = c.review_verdict) as agreed,
       count(*) filter (where c.verdict = 'not_clean' and c.review_verdict = 'clean')      as false_flags,
       count(*) filter (where c.verdict = 'clean' and c.review_verdict = 'not_clean')      as misses,
       count(*) filter (where c.verdict = 'unsure')                                 as unsure,
       round(sum(c.cost_usd), 4)                                                    as cost_usd
from public.ai_photo_checks c
group by c.outlet_id, c.item_id, c.prompt_version, c.model;
grant select on public.v_ai_check_agreement to authenticated;

-- ---------- Scheduling (pg_cron + pg_net; fill in project URL and secret) ----------
-- select cron.schedule('asah-ai-photo-check', '* * * * *', $$
--   select net.http_post(
--     url     := 'https://<project-ref>.supabase.co/functions/v1/ai-photo-check',
--     headers := jsonb_build_object('Content-Type', 'application/json',
--                  'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'ai_worker_secret')),
--     body    := '{}'::jsonb)
-- $$);
-- select cron.schedule('asah-ai-requeue', '*/10 * * * *', $$select app.requeue_stale_ai_checks()$$);
