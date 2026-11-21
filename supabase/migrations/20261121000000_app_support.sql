-- =============================================================================
-- ASAH: app support layer on top of 20261118000000_asah_mvp_schema.sql
--
-- Fills gaps found while building the Flutter app and admin web:
--   1. A trainee can read their own mentor's name (the base schema only lets the
--      mentor read the trainee, so the "Your mentor" card had nothing to show).
--   2. people_names(): names (and position) of colleagues in scope, so issue
--      timelines and check-ins can show "Wayan" instead of a uuid, without
--      granting user.view to staff.
--   3. Area managers can upload audit photos for outlets in their area (the base
--      "upload own media" policy only allows the uploader's own outlet, and an
--      area manager usually has no outlet).
--   4. Storage bucket "asah-media" for photos and PDFs, with policies that follow
--      public.media_files RLS. Videos go to Cloudflare Stream instead (see
--      supabase/functions/stream-*).
--   5. Reminders the PRD asks for that the base schema does not schedule:
--      checklist due soon (A2), weekly check-in due (M3), trainee still behind
--      escalates to the outlet manager (M4).
--   6. Push delivery: every new row in public.notifications is sent to the
--      "push" Edge Function through pg_net (no-op until the vault secrets exist).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Trainee reads their mentor's profile (current and past mentors, for rating)
-- -----------------------------------------------------------------------------
create or replace function app.is_trainee_of(p_mentor uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.mentorships m
    where m.trainee_id = (select auth.uid()) and m.mentor_id = p_mentor);
$$;

create policy "trainee reads own mentor" on public.profiles for select to authenticated
  using (app.is_trainee_of(id));

-- -----------------------------------------------------------------------------
-- 2. Names of people the caller works with
-- -----------------------------------------------------------------------------
create or replace function public.people_names(p_ids uuid[])
returns table (id uuid, full_name text, position_name text)
language sql stable security definer set search_path = '' as $$
  select p.id, p.full_name, pos.name
  from public.profiles p
  left join public.positions pos on pos.id = p.position_id
  join public.profiles me on me.id = (select auth.uid()) and me.status = 'active'
  where p.id = any(p_ids)
    and (
         p.id = me.id
      or (p.outlet_id is not null and p.outlet_id = me.outlet_id)
      or app.has_permission('user.view', p.outlet_id)
      or app.has_permission('issue.view', p.outlet_id)
      or app.is_mentor_of(p.id)
      or app.is_trainee_of(p.id)
      -- people who acted on an issue I can see (e.g. the area manager who verified)
      or exists (select 1 from public.issues i
                 where (i.raised_by = p.id or i.assigned_to = p.id or i.fixed_by = p.id or i.closed_by = p.id)
                   and (i.raised_by = me.id or i.assigned_to = me.id
                        or app.has_permission('issue.view', i.outlet_id))));
$$;

-- -----------------------------------------------------------------------------
-- 3. Audit and issue photos for outlets in the caller's scope
-- -----------------------------------------------------------------------------
create policy "upload media for outlets in scope" on public.media_files for insert to authenticated
  with check (kind in ('checklist_photo', 'issue_photo')
              and uploaded_by = (select auth.uid())
              and outlet_id is not null
              and (app.has_permission('audit.conduct', outlet_id)
                   or app.has_permission('issue.assign', outlet_id)));

-- -----------------------------------------------------------------------------
-- 4. Storage: one private bucket. Object keys:
--      personal/<outlet_id>/<user_id>/<uuid>.jpg   checklist and issue photos
--      training/<uuid>.<ext>                        SOP images and PDFs
--    Reading an object requires being able to read its media_files row, so the
--    media RLS above is the single source of truth.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('asah-media', 'asah-media', false, 52428800,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create policy "asah upload personal media" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'asah-media'
    and (storage.foldername(name))[1] = 'personal'
    and (storage.foldername(name))[3] = (select auth.uid())::text
    and app.is_active_user()
    and (
         (storage.foldername(name))[2] = app.user_outlet((select auth.uid()))::text
      or app.has_permission('audit.conduct', ((storage.foldername(name))[2])::uuid)
      or app.has_permission('issue.assign', ((storage.foldername(name))[2])::uuid)));

create policy "asah upload training media" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'asah-media'
    and (storage.foldername(name))[1] = 'training'
    and app.has_permission('module.author'));

create policy "asah read media" on storage.objects for select to authenticated
  using (
    bucket_id = 'asah-media'
    and exists (select 1 from public.media_files m
                where m.bucket = 'asah-media' and m.object_key = storage.objects.name));

-- -----------------------------------------------------------------------------
-- 5. Reminders and escalations
-- -----------------------------------------------------------------------------
alter table public.checklist_runs add column if not exists reminded_at timestamptz;
alter table public.module_assignments add column if not exists escalated_at timestamptz;

-- A2: remind the staff who fill a checklist, once, p_before ahead of its due time
create or replace function app.remind_due_checklists(p_before interval default interval '30 minutes')
returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
  for r in
    update public.checklist_runs cr set reminded_at = now()
     where cr.status in ('pending', 'in_progress') and cr.reminded_at is null
       and cr.schedule_id is not null
       and cr.due_at - p_before <= now() and cr.due_at > now()
    returning cr.id, cr.outlet_id, cr.template_version_id, cr.due_at
  loop
    n := n + 1;
    perform app.notify(p.id, 'checklist_due', t.name || ' is due soon', null,
                       jsonb_build_object('run_id', r.id))
      from public.checklist_template_versions v
      join public.checklist_templates t on t.id = v.template_id
      join public.checklist_template_positions tp on tp.template_id = t.id
      join public.profiles p on p.position_id = tp.position_id
                            and p.outlet_id = r.outlet_id and p.status = 'active'
     where v.id = r.template_version_id;
  end loop;
  return n;
end $$;

-- M3: weekly check-in reminder for mentors without a check-in this week
create or replace function app.remind_mentor_checkins()
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into public.notifications (user_id, type, title, data)
  select m.mentor_id, 'checkin_due', 'Weekly check-in due: ' || t.full_name,
         jsonb_build_object('mentorship_id', m.id)
  from public.mentorships m
  join public.profiles t on t.id = m.trainee_id
  where m.ended_at is null
    and not exists (select 1 from public.mentor_checkins c
                    where c.mentorship_id = m.id
                      and c.week_of >= date_trunc('week', now())::date);
  get diagnostics n = row_count;
  return n;
end $$;

-- M4: a mandatory module overdue by more than p_grace alerts the mentor, then the
-- outlet manager once
create or replace function app.escalate_behind_trainees(p_grace interval default interval '3 days')
returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
  for r in
    update public.module_assignments a set escalated_at = now()
     where a.completed_at is null and a.escalated_at is null
       and a.due_at is not null and a.due_at + p_grace < now()
    returning a.id, a.user_id
  loop
    n := n + 1;
    perform app.notify(u, 'trainee_behind', 'A trainee is behind schedule', null,
                       jsonb_build_object('assignment_id', r.id, 'user_id', r.user_id))
      from app.users_with_permission('mentorship.manage', app.user_outlet(r.user_id)) u;
    perform app.notify(m.mentor_id, 'trainee_behind', 'Your trainee is behind schedule', null,
                       jsonb_build_object('assignment_id', r.id, 'user_id', r.user_id))
      from public.mentorships m where m.trainee_id = r.user_id and m.ended_at is null;
  end loop;
  return n;
end $$;

revoke execute on function app.remind_due_checklists(interval) from authenticated;
revoke execute on function app.remind_mentor_checkins() from authenticated;
revoke execute on function app.escalate_behind_trainees(interval) from authenticated;

-- select cron.schedule('asah-due-reminders', '*/5 * * * *', $$select app.remind_due_checklists()$$);
-- select cron.schedule('asah-checkin-reminders', '0 2 * * 5', $$select app.remind_mentor_checkins()$$);
-- select cron.schedule('asah-trainee-behind', '0 2 * * *', $$select app.escalate_behind_trainees()$$);

-- -----------------------------------------------------------------------------
-- 6. Push: forward each notification to the "push" Edge Function
--    Store two vault secrets once (SQL editor):
--      select vault.create_secret('https://<ref>.supabase.co/functions/v1/push', 'push_hook_url');
--      select vault.create_secret('<random string, same as PUSH_HOOK_SECRET>', 'push_hook_secret');
-- -----------------------------------------------------------------------------
create extension if not exists pg_net with schema extensions;

create or replace function app.forward_notification_to_push()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  hook_url    text;
  hook_secret text;
begin
  select decrypted_secret into hook_url from vault.decrypted_secrets where name = 'push_hook_url';
  select decrypted_secret into hook_secret from vault.decrypted_secrets where name = 'push_hook_secret';
  if hook_url is null or hook_secret is null then
    return new;  -- push not configured yet; the in-app inbox still works
  end if;
  perform net.http_post(
    url     := hook_url,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', hook_secret),
    body    := jsonb_build_object('record', to_jsonb(new)));
  return new;
exception when others then
  return new;  -- never block the business transaction on push delivery
end $$;

create trigger notifications_push after insert on public.notifications
  for each row execute function app.forward_notification_to_push();

-- Realtime for the in-app inbox badge
alter publication supabase_realtime add table public.notifications;

grant execute on function public.people_names(uuid[]) to authenticated;
grant execute on function app.is_trainee_of(uuid) to authenticated;
