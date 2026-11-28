-- =============================================================================
-- ASAH: formal training sessions (Asuh / mentorship)
--
-- A formal "on the spot" training: a scheduled session (30 minutes by default)
-- between a mentor and their trainee.
--   1. Either side requests a session for a date and time
--      (request_formal_training). The other side gets a notification.
--   2. The other side approves or declines it (respond_formal_training). The
--      requester cannot approve their own request.
--   3. Approved sessions are announced to everyone with mentorship.view at the
--      outlet (outlet manager, area manager, HR) so they can see them and attend.
--   4. Either side can cancel a pending or approved session
--      (cancel_formal_training). Ending a mentorship cancels its upcoming sessions.
--
-- The app reads public.formal_trainings directly (RLS below); every write goes
-- through the RPCs.
-- =============================================================================

create type public.formal_training_status as enum ('requested', 'approved', 'declined', 'cancelled');

create table public.formal_trainings (
  id               uuid primary key default gen_random_uuid(),
  mentorship_id    uuid not null references public.mentorships(id) on delete cascade,
  mentor_id        uuid not null references public.profiles(id),   -- copied from the mentorship
  trainee_id       uuid not null references public.profiles(id),   -- copied from the mentorship
  outlet_id        uuid not null references public.outlets(id),    -- copied from the mentorship
  scheduled_at     timestamptz not null,
  duration_minutes smallint not null default 30 check (duration_minutes between 5 and 240),
  topic            text not null check (length(trim(topic)) > 0),
  note             text,
  status           public.formal_training_status not null default 'requested',
  requested_by     uuid not null references public.profiles(id),
  responded_by     uuid references public.profiles(id),
  responded_at     timestamptz,
  response_note    text,     -- approve/decline note, or the cancellation reason
  cancelled_by     uuid references public.profiles(id),
  cancelled_at     timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index on public.formal_trainings (mentorship_id, scheduled_at);
create index on public.formal_trainings (outlet_id, scheduled_at);

create trigger formal_trainings_updated_at before update on public.formal_trainings
  for each row execute function app.set_updated_at();

-- -----------------------------------------------------------------------------
-- RLS: read only. Mentor, trainee, and people who oversee mentorships at the outlet.
-- -----------------------------------------------------------------------------
alter table public.formal_trainings enable row level security;

create policy "active users only" on public.formal_trainings as restrictive for all to authenticated
  using (app.is_active_user()) with check (app.is_active_user());

create policy "read formal trainings" on public.formal_trainings for select to authenticated
  using (mentor_id = (select auth.uid()) or trainee_id = (select auth.uid())
         or app.has_permission('mentorship.view', outlet_id)
         or app.has_permission('mentorship.manage', outlet_id));

-- No insert/update/delete policies: writes go through the RPCs below.
revoke all on public.formal_trainings from anon;
revoke insert, update, delete, truncate on public.formal_trainings from authenticated;
grant select on public.formal_trainings to authenticated;

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
-- Notification payload shared by every formal_training_* notification
create or replace function app.formal_training_data(f public.formal_trainings)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('formal_training_id', f.id,
                            'mentorship_id', f.mentorship_id,
                            'scheduled_at', f.scheduled_at);
$$;

-- People who oversee the session (mentorship.view at the outlet), minus the pair
create or replace function app.formal_training_watchers(f public.formal_trainings)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select distinct u
  from app.users_with_permission('mentorship.view', f.outlet_id) u
  where u not in (f.mentor_id, f.trainee_id);
$$;

-- -----------------------------------------------------------------------------
-- 1. Request a session (mentor or trainee)
-- -----------------------------------------------------------------------------
create or replace function public.request_formal_training(
  p_mentorship uuid, p_scheduled_at timestamptz, p_topic text,
  p_note text default null, p_duration_minutes smallint default 30)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me     uuid := (select auth.uid());
  ms     public.mentorships%rowtype;
  f      public.formal_trainings%rowtype;
  dur    smallint := coalesce(p_duration_minutes, 30);
  who    text;
  other  uuid;
begin
  -- lock the mentorship so two overlapping requests cannot both pass the check
  select * into ms from public.mentorships where id = p_mentorship for update;
  if not app.is_active_user() or ms.id is null
     or me not in (ms.mentor_id, ms.trainee_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if ms.ended_at is not null then
    raise exception 'this mentorship has ended';
  end if;
  if p_scheduled_at is null or p_scheduled_at <= now() then
    raise exception 'pick a time in the future';
  end if;
  if length(trim(coalesce(p_topic, ''))) = 0 then
    raise exception 'a topic is required';
  end if;
  if dur not between 5 and 240 then
    raise exception 'duration must be between 5 and 240 minutes';
  end if;
  if exists (
       select 1 from public.formal_trainings x
       where x.mentorship_id = ms.id and x.status in ('requested', 'approved')
         and x.scheduled_at < p_scheduled_at + make_interval(mins => dur)
         and p_scheduled_at < x.scheduled_at + make_interval(mins => x.duration_minutes)) then
    raise exception 'another formal training is already planned at that time';
  end if;

  insert into public.formal_trainings
    (mentorship_id, mentor_id, trainee_id, outlet_id, scheduled_at, duration_minutes,
     topic, note, requested_by)
  values (ms.id, ms.mentor_id, ms.trainee_id, ms.outlet_id, p_scheduled_at, dur,
          trim(p_topic), nullif(trim(p_note), ''), me)
  returning * into f;

  select full_name into who from public.profiles where id = me;
  other := case when me = ms.mentor_id then ms.trainee_id else ms.mentor_id end;
  perform app.notify(other, 'formal_training_requested', who || ' requested a formal training',
                     f.topic, app.formal_training_data(f));
  return f.id;
end $$;

-- -----------------------------------------------------------------------------
-- 2. Approve or decline (the other side, not the requester)
-- -----------------------------------------------------------------------------
create or replace function public.respond_formal_training(
  p_training uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me      uuid := (select auth.uid());
  f       public.formal_trainings%rowtype;
  who     text;
  mentor  text;
  trainee text;
begin
  select * into f from public.formal_trainings where id = p_training for update;
  if not app.is_active_user() or f.id is null
     or me not in (f.mentor_id, f.trainee_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if me = f.requested_by then
    raise exception 'the other person has to respond to your request' using errcode = '42501';
  end if;
  if f.status <> 'requested' then
    raise exception 'this request was already %', f.status;
  end if;
  if f.scheduled_at <= now() then
    raise exception 'this request has expired';
  end if;
  if p_approve is null then
    raise exception 'approve or decline the request';
  end if;

  update public.formal_trainings
     set status = case when p_approve then 'approved' else 'declined' end::public.formal_training_status,
         responded_by = me, responded_at = now(), response_note = nullif(trim(p_note), '')
   where id = f.id
  returning * into f;

  select full_name into who from public.profiles where id = me;
  if p_approve then
    perform app.notify(f.requested_by, 'formal_training_approved',
                       who || ' approved your formal training', f.topic, app.formal_training_data(f));
    select full_name into mentor from public.profiles where id = f.mentor_id;
    select full_name into trainee from public.profiles where id = f.trainee_id;
    perform app.notify(u, 'formal_training_scheduled',
                       'Formal training scheduled: ' || mentor || ' with ' || trainee,
                       f.topic, app.formal_training_data(f))
      from app.formal_training_watchers(f) u;
  else
    perform app.notify(f.requested_by, 'formal_training_declined',
                       who || ' declined your formal training', coalesce(f.response_note, f.topic),
                       app.formal_training_data(f));
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 3. Cancel (either side, while requested or approved)
-- -----------------------------------------------------------------------------
create or replace function public.cancel_formal_training(p_training uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me      uuid := (select auth.uid());
  f       public.formal_trainings%rowtype;
  was     public.formal_training_status;
  who     text;
  mentor  text;
  trainee text;
begin
  select * into f from public.formal_trainings where id = p_training for update;
  if not app.is_active_user() or f.id is null
     or me not in (f.mentor_id, f.trainee_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if f.status not in ('requested', 'approved') then
    raise exception 'this formal training was already %', f.status;
  end if;
  was := f.status;

  update public.formal_trainings
     set status = 'cancelled', cancelled_by = me, cancelled_at = now(),
         response_note = nullif(trim(p_reason), '')
   where id = f.id
  returning * into f;

  select full_name into who from public.profiles where id = me;
  perform app.notify(case when me = f.mentor_id then f.trainee_id else f.mentor_id end,
                     'formal_training_cancelled', who || ' cancelled a formal training',
                     coalesce(f.response_note, f.topic), app.formal_training_data(f));
  if was = 'approved' then
    select full_name into mentor from public.profiles where id = f.mentor_id;
    select full_name into trainee from public.profiles where id = f.trainee_id;
    perform app.notify(u, 'formal_training_cancelled',
                       'Formal training cancelled: ' || mentor || ' with ' || trainee,
                       coalesce(f.response_note, f.topic), app.formal_training_data(f))
      from app.formal_training_watchers(f) u;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 4. Ending a mentorship cancels its upcoming sessions
-- -----------------------------------------------------------------------------
create or replace function app.cancel_formal_trainings_of_ended_mentorship()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.formal_trainings
     set status = 'cancelled', cancelled_by = (select auth.uid()), cancelled_at = now(),
         response_note = 'Mentorship ended'
   where mentorship_id = new.id
     and status in ('requested', 'approved')
     and scheduled_at > now();
  return null;
end $$;

create trigger mentorships_cancel_formal_trainings
  after update of ended_at on public.mentorships
  for each row when (old.ended_at is null and new.ended_at is not null)
  execute function app.cancel_formal_trainings_of_ended_mentorship();

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
revoke all on function public.request_formal_training(uuid, timestamptz, text, text, smallint) from public, anon;
revoke all on function public.respond_formal_training(uuid, boolean, text) from public, anon;
revoke all on function public.cancel_formal_training(uuid, text) from public, anon;
grant execute on function public.request_formal_training(uuid, timestamptz, text, text, smallint) to authenticated;
grant execute on function public.respond_formal_training(uuid, boolean, text) to authenticated;
grant execute on function public.cancel_formal_training(uuid, text) to authenticated;

revoke all on function app.formal_training_data(public.formal_trainings) from public, anon;
revoke all on function app.formal_training_watchers(public.formal_trainings) from public, anon;
revoke all on function app.cancel_formal_trainings_of_ended_mentorship() from public, anon, authenticated;
