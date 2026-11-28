-- Checks for 20261123000000_formal_trainings.sql. Runs after 10_ and 20_ (same
-- database): mentorship bbbbbbbb-...-01 = mentor Made (...02) and trainee Nyoman
-- (...12) at Outlet A. Area manager (...04, Area a1) and HR head (...08, group)
-- hold mentorship.view; Ketut (...09) works at Outlet B.
\set ON_ERROR_STOP 1

set role authenticated;

-- ---------- Request ----------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000012', false);
select set_config('t.ft1', request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  date_trunc('hour', now()) + interval '1 day 10 hours', 'Table setting', 'Before the lunch rush')::text, false);
select t.ok((select status = 'requested' and requested_by = 'aaaaaaaa-0000-0000-0000-000000000012'
                    and mentor_id = 'aaaaaaaa-0000-0000-0000-000000000002' and duration_minutes = 30
             from formal_trainings where id = current_setting('t.ft1')::uuid),
            'trainee requests a formal training (30 minutes by default)');
select t.ok(t.fails($$select respond_formal_training(current_setting('t.ft1')::uuid, true)$$),
            'requester cannot approve their own request');
select t.ok(t.fails($$select request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  now() - interval '1 hour', 'Too late')$$), 'a time in the past is rejected');
select t.ok(t.fails($$select request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  now() + interval '3 days', '   ')$$), 'an empty topic is rejected');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select t.ok((select count(*) = 1 from notifications
             where user_id = 'aaaaaaaa-0000-0000-0000-000000000002' and type = 'formal_training_requested'
               and title = 'Nyoman requested a formal training' and body = 'Table setting'
               and data ->> 'formal_training_id' = current_setting('t.ft1')
               and data ->> 'mentorship_id' = 'bbbbbbbb-0000-0000-0000-000000000001'
               and data ? 'scheduled_at'),
            'mentor is notified of the request');
select t.ok(t.fails($$select request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  date_trunc('hour', now()) + interval '1 day 10 hours 15 minutes', 'Overlaps')$$),
            'a session overlapping a pending one is rejected');
select set_config('t.ft2', request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  date_trunc('hour', now()) + interval '1 day 11 hours', 'Closing checklist', null, 45::smallint)::text, false);
select t.ok((select duration_minutes = 45 from formal_trainings where id = current_setting('t.ft2')::uuid),
            'mentor requests a back-to-back session with a custom duration');

-- ---------- Visibility before approval ----------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000004', false);
select t.ok((select count(*) = 2 from formal_trainings where mentorship_id = 'bbbbbbbb-0000-0000-0000-000000000001'),
            'area manager (mentorship.view) sees the sessions');
select t.ok(t.fails($$select respond_formal_training(current_setting('t.ft1')::uuid, true)$$),
            'area manager cannot respond for the pair');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000009', false);
select t.ok((select count(*) = 0 from formal_trainings), 'Outlet B staff sees no Outlet A sessions');
select t.ok(t.fails($$select cancel_formal_training(current_setting('t.ft1')::uuid)$$),
            'Outlet B staff cannot cancel it');
select t.ok(t.fails($$select request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  now() + interval '5 days', 'Not mine')$$), 'outsider cannot request for someone else''s mentorship');

-- ---------- Approve ----------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select respond_formal_training(current_setting('t.ft1')::uuid, true, 'See you there');
select t.ok((select status = 'approved' and responded_by = 'aaaaaaaa-0000-0000-0000-000000000002'
                    and responded_at is not null and response_note = 'See you there'
             from formal_trainings where id = current_setting('t.ft1')::uuid),
            'mentor approves the trainee''s request');
select t.ok(t.fails($$select respond_formal_training(current_setting('t.ft1')::uuid, false)$$),
            'an answered request cannot be answered again');
reset role;
select t.ok((select count(*) = 1 from notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000012'
             and type = 'formal_training_approved' and data ->> 'formal_training_id' = current_setting('t.ft1')),
            'requester is told it was approved');
select t.ok((select count(*) = 1 from notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000004'
             and type = 'formal_training_scheduled' and title = 'Formal training scheduled: Made with Nyoman'
             and data ->> 'formal_training_id' = current_setting('t.ft1')),
            'area manager is told the session is scheduled');
select t.ok((select count(*) = 1 from notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000008'
             and type = 'formal_training_scheduled'), 'HR (group mentorship.view) is told too');
select t.ok((select count(*) = 0 from notifications where type = 'formal_training_scheduled'
             and user_id in ('aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000012',
                             'aaaaaaaa-0000-0000-0000-000000000009')),
            'mentor, trainee and Outlet B staff get no "scheduled" notice');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000004', false);
select t.ok((select status = 'approved' from formal_trainings where id = current_setting('t.ft1')::uuid),
            'area manager reads the approved session');

-- ---------- Direct writes are refused ----------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select t.ok(t.fails($$insert into formal_trainings (mentorship_id, mentor_id, trainee_id, outlet_id,
  scheduled_at, topic, status, requested_by) values ('bbbbbbbb-0000-0000-0000-000000000001',
  'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000012',
  '00000000-0000-0000-0000-0000000000f1', now() + interval '9 days', 'Sneaky', 'approved',
  'aaaaaaaa-0000-0000-0000-000000000002')$$), 'direct insert is refused');
select t.ok(t.fails($$update formal_trainings set status = 'approved' where id = current_setting('t.ft2')::uuid$$),
            'direct update is refused');
select t.ok(t.fails($$delete from formal_trainings where id = current_setting('t.ft2')::uuid$$),
            'direct delete is refused');
set role anon;
select t.ok(t.fails($$select request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  now() + interval '5 days', 'Anon')$$), 'anonymous callers cannot request');
reset role;

-- ---------- Cancel ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000012', false);
select cancel_formal_training(current_setting('t.ft2')::uuid, 'Off that day');
select t.ok((select status = 'cancelled' and cancelled_by = 'aaaaaaaa-0000-0000-0000-000000000012'
                    and cancelled_at is not null and response_note = 'Off that day'
             from formal_trainings where id = current_setting('t.ft2')::uuid),
            'trainee cancels a pending request');
select t.ok(t.fails($$select cancel_formal_training(current_setting('t.ft2')::uuid)$$),
            'a cancelled session cannot be cancelled again');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select cancel_formal_training(current_setting('t.ft1')::uuid, 'Outlet event');
reset role;
select t.ok((select count(*) = 1 from notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000002'
             and type = 'formal_training_cancelled' and data ->> 'formal_training_id' = current_setting('t.ft2')),
            'mentor is told the trainee cancelled');
select t.ok((select count(*) = 1 from notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000012'
             and type = 'formal_training_cancelled' and data ->> 'formal_training_id' = current_setting('t.ft1')),
            'trainee is told the mentor cancelled the approved session');
select t.ok((select count(*) = 1 from notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000004'
             and type = 'formal_training_cancelled' and data ->> 'formal_training_id' = current_setting('t.ft1')),
            'area manager is told an approved session was cancelled');
select t.ok((select count(*) = 0 from notifications where user_id = 'aaaaaaaa-0000-0000-0000-000000000004'
             and type = 'formal_training_cancelled' and data ->> 'formal_training_id' = current_setting('t.ft2')),
            'higher-ups are not told about cancelled requests that were never approved');

-- ---------- Expired requests ----------
insert into formal_trainings (id, mentorship_id, mentor_id, trainee_id, outlet_id, scheduled_at, topic, requested_by)
values ('bbbbbbbb-0000-0000-0000-0000000000f1', 'bbbbbbbb-0000-0000-0000-000000000001',
        'aaaaaaaa-0000-0000-0000-000000000002', 'aaaaaaaa-0000-0000-0000-000000000012',
        '00000000-0000-0000-0000-0000000000f1', now() - interval '1 hour', 'Old', 'aaaaaaaa-0000-0000-0000-000000000012');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select t.ok(t.fails($$select respond_formal_training('bbbbbbbb-0000-0000-0000-0000000000f1', true)$$),
            'a request whose time has passed cannot be approved');

-- ---------- Ending the mentorship cancels upcoming sessions ----------
select set_config('t.ft3', request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  now() + interval '4 days', 'Wine service')::text, false);
reset role;
update mentorships set ended_at = now(), end_reason = 'other' where id = 'bbbbbbbb-0000-0000-0000-000000000001';
select t.ok((select status = 'cancelled' and response_note = 'Mentorship ended'
             from formal_trainings where id = current_setting('t.ft3')::uuid),
            'ending the mentorship cancels its upcoming sessions');
select t.ok((select status = 'requested' from formal_trainings where id = 'bbbbbbbb-0000-0000-0000-0000000000f1'),
            'past sessions are left as they were');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000012', false);
select t.ok(t.fails($$select request_formal_training('bbbbbbbb-0000-0000-0000-000000000001',
  now() + interval '6 days', 'After the end')$$), 'no requests on an ended mentorship');
reset role;
