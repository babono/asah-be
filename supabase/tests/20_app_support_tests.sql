-- Checks for 20261121000000_app_support.sql. Runs after 10_behaviour_tests.sql
-- (same database): Outlet A = ...f1 in Area ...a1, Outlet B = ...f2.
-- People: 2 Made (mentor, Outlet A), 4 Area manager (Area a1), 9 Ketut (Outlet B),
-- 11 Wayan (Outlet A staff). Added here: 12 Nyoman, a new trainee at Outlet A.
\set ON_ERROR_STOP 1

insert into auth.users (id) values ('aaaaaaaa-0000-0000-0000-000000000012');
insert into profiles (id, full_name, position_id, outlet_id) values
  ('aaaaaaaa-0000-0000-0000-000000000012', 'Nyoman', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1');
insert into user_roles (user_id, role_id, scope_type, scope_id)
select 'aaaaaaaa-0000-0000-0000-000000000012', id, 'outlet', '00000000-0000-0000-0000-0000000000f1' from roles where name = 'Staff';
insert into mentorships (id, mentor_id, trainee_id, outlet_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002',
   'aaaaaaaa-0000-0000-0000-000000000012', '00000000-0000-0000-0000-0000000000f1');

-- ---------- 1. Trainee reads own mentor ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000012', false);
select t.ok((select count(*) = 1 from profiles where id = 'aaaaaaaa-0000-0000-0000-000000000002'),
            'trainee reads their mentor''s profile');
select t.ok((select count(*) = 0 from profiles where id = 'aaaaaaaa-0000-0000-0000-000000000011'),
            'trainee still cannot read other colleagues'' profiles');

-- ---------- 2. people_names ----------
select t.ok((select count(*) = 1 from people_names(array['aaaaaaaa-0000-0000-0000-000000000011'::uuid])),
            'people_names: colleague at the same outlet');
select t.ok((select count(*) = 0 from people_names(array['aaaaaaaa-0000-0000-0000-000000000009'::uuid])),
            'people_names: nobody from another outlet');
select t.ok((select full_name = 'Made' from people_names(array['aaaaaaaa-0000-0000-0000-000000000002'::uuid])),
            'people_names: own mentor');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000009', false);
select t.ok((select count(*) = 0 from people_names(array['aaaaaaaa-0000-0000-0000-000000000001'::uuid,
                                                         'aaaaaaaa-0000-0000-0000-000000000012'::uuid])),
            'people_names: Outlet B staff gets no Outlet A names');

-- ---------- 3. Audit photos for outlets in scope ----------
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000004', false);
select t.ok(not t.fails($$insert into media_files (bucket, object_key, kind, uploaded_by, outlet_id)
  values ('asah-media', 'personal/00000000-0000-0000-0000-0000000000f1/aaaaaaaa-0000-0000-0000-000000000004/a.jpg',
          'checklist_photo', 'aaaaaaaa-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000f1')$$),
            'area manager uploads an audit photo for an outlet in their area');
select t.ok(t.fails($$insert into media_files (bucket, object_key, kind, uploaded_by, outlet_id)
  values ('asah-media', 'personal/00000000-0000-0000-0000-0000000000f2/aaaaaaaa-0000-0000-0000-000000000004/b.jpg',
          'checklist_photo', 'aaaaaaaa-0000-0000-0000-000000000004', '00000000-0000-0000-0000-0000000000f2')$$),
            'area manager cannot upload for an outlet outside their area');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000011', false);
select t.ok(t.fails($$insert into media_files (bucket, object_key, kind, uploaded_by, outlet_id)
  values ('asah-media', 'x', 'checklist_photo', 'aaaaaaaa-0000-0000-0000-000000000011', '00000000-0000-0000-0000-0000000000f2')$$),
            'staff cannot upload photos for another outlet');

-- ---------- 4. Storage bucket policies ----------
select t.ok(not t.fails($$insert into storage.objects (bucket_id, name) values ('asah-media',
  'personal/00000000-0000-0000-0000-0000000000f1/aaaaaaaa-0000-0000-0000-000000000011/p.jpg')$$),
            'staff stores a photo in their own outlet folder');
select t.ok(t.fails($$insert into storage.objects (bucket_id, name) values ('asah-media',
  'personal/00000000-0000-0000-0000-0000000000f1/aaaaaaaa-0000-0000-0000-000000000001/p.jpg')$$),
            'staff cannot store into someone else''s folder');
select t.ok(t.fails($$insert into storage.objects (bucket_id, name) values ('asah-media', 'training/x.pdf')$$),
            'staff cannot store training files');
reset role;
insert into storage.objects (bucket_id, name) values
  ('asah-media', 'personal/00000000-0000-0000-0000-0000000000f1/aaaaaaaa-0000-0000-0000-000000000004/a.jpg');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000004', false);
select t.ok((select count(*) = 1 from storage.objects
             where name = 'personal/00000000-0000-0000-0000-0000000000f1/aaaaaaaa-0000-0000-0000-000000000004/a.jpg'),
            'uploader reads an object they have a media row for');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000009', false);
select t.ok((select count(*) = 0 from storage.objects
             where name = 'personal/00000000-0000-0000-0000-0000000000f1/aaaaaaaa-0000-0000-0000-000000000004/a.jpg'),
            'Outlet B staff cannot read Outlet A photos');
reset role;

-- ---------- 5. Reminders and escalations ----------
insert into checklist_templates (id, name) values ('bbbbbbbb-0000-0000-0000-0000000000c1', 'Reminder test');
insert into checklist_template_versions (id, template_id, version, published_at)
  values ('bbbbbbbb-0000-0000-0000-0000000000c2', 'bbbbbbbb-0000-0000-0000-0000000000c1', 1, now());
insert into checklist_template_positions (template_id, position_id)
  values ('bbbbbbbb-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000c1');
insert into checklist_schedules (id, template_id, outlet_id, shift, due_time)
  values ('bbbbbbbb-0000-0000-0000-0000000000c3', 'bbbbbbbb-0000-0000-0000-0000000000c1',
          '00000000-0000-0000-0000-0000000000f1', 'mid', '12:00');
insert into checklist_runs (template_version_id, outlet_id, schedule_id, shift_date, shift, due_at)
  values ('bbbbbbbb-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000f1',
          'bbbbbbbb-0000-0000-0000-0000000000c3', current_date + 30, 'mid', now() + interval '10 minutes');

select t.ok(app.remind_due_checklists() = 1, 'due-soon checklist reminds once');
select t.ok((select count(*) >= 3 from notifications where type = 'checklist_due'),
            'every Server at the outlet got the reminder');
select t.ok((select count(*) = 0 from notifications where type = 'checklist_due'
             and user_id = 'aaaaaaaa-0000-0000-0000-000000000009'), 'Outlet B was not reminded');
select t.ok(app.remind_due_checklists() = 0, 'no second reminder for the same run');

select t.ok(app.remind_mentor_checkins() >= 1, 'mentor without a check-in this week is reminded');
insert into mentor_checkins (mentorship_id, week_of, feedback, created_by)
  values ('bbbbbbbb-0000-0000-0000-000000000001', current_date, 'Good week', 'aaaaaaaa-0000-0000-0000-000000000002');
select set_config('t.before', (select count(*)::text from notifications where type = 'checkin_due'
  and data ->> 'mentorship_id' = 'bbbbbbbb-0000-0000-0000-000000000001'), false);
select app.remind_mentor_checkins();
select t.ok((select count(*) from notifications where type = 'checkin_due'
             and data ->> 'mentorship_id' = 'bbbbbbbb-0000-0000-0000-000000000001') = current_setting('t.before')::int,
            'no reminder once this week''s check-in is logged');

update module_assignments set due_at = now() - interval '5 days'
 where user_id = 'aaaaaaaa-0000-0000-0000-000000000012' and completed_at is null;
select t.ok(app.escalate_behind_trainees() >= 1, 'trainee overdue by 3+ days escalates');
select t.ok((select count(*) >= 1 from notifications where type = 'trainee_behind'
             and user_id = 'aaaaaaaa-0000-0000-0000-000000000002'), 'mentor told the trainee is behind');
select t.ok(app.escalate_behind_trainees() = 0, 'escalates only once');

-- ---------- 6. Push forwarding ----------
select t.ok(not t.fails($$insert into notifications (user_id, type, title)
  values ('aaaaaaaa-0000-0000-0000-000000000012', 'test', 'No push configured')$$),
            'notifications still save when push is not configured');
insert into vault.decrypted_secrets values ('push_hook_url', 'https://example.test/push'), ('push_hook_secret', 's');
select t.ok(not t.fails($$insert into notifications (user_id, type, title)
  values ('aaaaaaaa-0000-0000-0000-000000000012', 'test', 'With push')$$),
            'notifications save and forward when push is configured');
