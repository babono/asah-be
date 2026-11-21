-- Behaviour tests for the ASAH schema. Run as superuser after the migration.
\set ON_ERROR_STOP 1
\set QUIET 1

create schema t;
grant usage on schema t to authenticated, anon;
create function t.fails(q text) returns boolean language plpgsql as $$
begin execute q; return false; exception when others then return true; end $$;
create function t.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAILED: %', msg; end if; raise notice 'ok  %', msg; end $$;
grant execute on all functions in schema t to authenticated, anon;

-- ---------- Seed (as superuser) ----------
insert into brands (id, name) values ('00000000-0000-0000-0000-0000000000b1', 'Brand One');
insert into areas (id, name) values
  ('00000000-0000-0000-0000-0000000000a1', 'Area Denpasar'),
  ('00000000-0000-0000-0000-0000000000a2', 'Area Makassar');
insert into outlets (id, brand_id, area_id, name, latitude, longitude, geofence_radius_m) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'Outlet A', -8.650000, 115.216000, 150),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a2', 'Outlet B', -5.147000, 119.432000, 150);
insert into departments (id, name) values ('00000000-0000-0000-0000-0000000000d1', 'Service');
insert into positions (id, department_id, name, level) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000d1', 'Server', 1),
  ('00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000d1', 'Captain', 2);

-- Content first, so new hires get the path on creation
insert into auth.users (id) select ('aaaaaaaa-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid from generate_series(1, 11) n;
insert into profiles (id, full_name, position_id, outlet_id) values
  ('aaaaaaaa-0000-0000-0000-000000000005', 'Trainer', null, null),
  ('aaaaaaaa-0000-0000-0000-000000000006', 'Training manager', null, null);
insert into modules (id, category, created_by) values ('00000000-0000-0000-0000-0000000000e1', 'Service', 'aaaaaaaa-0000-0000-0000-000000000005');
insert into module_versions (id, module_id, version, status, title, author_id, certificate_valid_days)
values ('00000000-0000-0000-0000-00000000e101', '00000000-0000-0000-0000-0000000000e1', 1, 'in_review', 'Table setting',
        'aaaaaaaa-0000-0000-0000-000000000005', 365);
insert into content_blocks (id, module_version_id, sort, type, title, body) values
  ('00000000-0000-0000-0000-00000000b101', '00000000-0000-0000-0000-00000000e101', 1, 'sop_card', 'Steps', '1. Plate 2. Fork');
insert into quizzes (id, module_version_id, pass_mark_pct, max_attempts) values
  ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-00000000e101', 100, 3);
insert into questions (id, prompt) values ('00000000-0000-0000-0000-0000000009b1', 'Where does the dessert spoon go?');
insert into question_options (id, question_id, label, is_correct, sort) values
  ('00000000-0000-0000-0000-0000000009c1', '00000000-0000-0000-0000-0000000009b1', 'Above the plate', true, 1),
  ('00000000-0000-0000-0000-0000000009c2', '00000000-0000-0000-0000-0000000009b1', 'Left of the fork', false, 2);
insert into quiz_questions (quiz_id, question_id) values ('00000000-0000-0000-0000-0000000009a1', '00000000-0000-0000-0000-0000000009b1');
insert into rubric_criteria (id, module_version_id, title, sort) values
  ('00000000-0000-0000-0000-0000000008a1', '00000000-0000-0000-0000-00000000e101', 'Hygiene', 1);

-- Roles
insert into user_roles (user_id, role_id, scope_type, scope_id)
select 'aaaaaaaa-0000-0000-0000-000000000005'::uuid, id, 'group'::scope_type, null::uuid from roles where name = 'HQ trainer'
union all select 'aaaaaaaa-0000-0000-0000-000000000006'::uuid, id, 'group'::scope_type, null::uuid from roles where name = 'Training manager';

-- ---------- Module review: SoD and publishing ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000005', false);
select t.ok(t.fails($$select review_module_version('00000000-0000-0000-0000-00000000e101', true)$$),
            'trainer cannot publish (no module.review)');
reset role;
-- give the training manager author rights too and make them the author of a v2 draft
insert into user_roles (user_id, role_id, scope_type) select 'aaaaaaaa-0000-0000-0000-000000000006'::uuid, id, 'group'::scope_type from roles where name = 'HQ trainer';
insert into module_versions (id, module_id, version, status, title, author_id)
values ('00000000-0000-0000-0000-00000000e102', '00000000-0000-0000-0000-0000000000e1', 2, 'in_review', 'Table setting v2', 'aaaaaaaa-0000-0000-0000-000000000006');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000006', false);
select t.ok(t.fails($$select review_module_version('00000000-0000-0000-0000-00000000e102', true)$$),
            'author cannot approve own module (separation of duties)');
select review_module_version('00000000-0000-0000-0000-00000000e101', true, 'Looks good');
select t.ok((select status = 'published' from module_versions where id = '00000000-0000-0000-0000-00000000e101'),
            'training manager publishes v1');
reset role;
delete from module_versions where id = '00000000-0000-0000-0000-00000000e102';

-- Learning path for Server, then hire people
insert into learning_paths (id, position_id, name) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000c1', 'Server path');
insert into learning_path_items (path_id, module_id, sort, due_days) values
  ('00000000-0000-0000-0000-0000000007a1', '00000000-0000-0000-0000-0000000000e1', 1, 7);

insert into profiles (id, full_name, position_id, outlet_id) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Putu',   '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Made',   '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Outlet manager A', '00000000-0000-0000-0000-0000000000c2', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'Area manager 1', null, null),
  ('aaaaaaaa-0000-0000-0000-000000000007', 'HQ admin', null, null),
  ('aaaaaaaa-0000-0000-0000-000000000008', 'HR head', null, null),
  ('aaaaaaaa-0000-0000-0000-000000000009', 'Ketut (Outlet B)', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f2'),
  ('aaaaaaaa-0000-0000-0000-000000000010', 'Komang', '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000011', 'Wayan',  '00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1');

select t.ok((select count(*) = 4 from module_assignments where source = 'path'),
            'path auto-assigned to the 4 servers on creation');

insert into user_roles (user_id, role_id, scope_type, scope_id)
select u::uuid, r.id, s::scope_type, sid::uuid from (values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Staff', 'outlet', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Staff', 'outlet', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000002', 'Mentor', 'outlet', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Staff', 'outlet', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000003', 'Outlet manager', 'outlet', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'Area manager', 'area', '00000000-0000-0000-0000-0000000000a1'),
  ('aaaaaaaa-0000-0000-0000-000000000007', 'HQ admin', 'group', null),
  ('aaaaaaaa-0000-0000-0000-000000000008', 'HR and senior management', 'group', null),
  ('aaaaaaaa-0000-0000-0000-000000000009', 'Staff', 'outlet', '00000000-0000-0000-0000-0000000000f2'),
  ('aaaaaaaa-0000-0000-0000-000000000010', 'Staff', 'outlet', '00000000-0000-0000-0000-0000000000f1'),
  ('aaaaaaaa-0000-0000-0000-000000000011', 'Staff', 'outlet', '00000000-0000-0000-0000-0000000000f1')
) v(u, role_name, s, sid) join roles r on r.name = v.role_name;

-- ---------- Visibility (least privilege) ----------
select set_config('t.adminrole', (select id::text from roles where name = 'HQ admin'), false);
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok((select count(*) = 1 from profiles), 'staff sees only own profile');
select t.ok((select count(*) = 0 from question_options), 'staff cannot read quiz answers');
select t.ok((select count(*) = 0 from user_roles), 'staff cannot read role grants');
select t.ok((select count(*) = 1 from module_assignments), 'staff sees only own assignment');
select t.ok(t.fails($$insert into user_roles (user_id, role_id, scope_type) values (auth.uid(), current_setting('t.adminrole')::uuid, 'group')$$),
            'staff cannot grant themselves a role');
select t.ok((select count(*) > 0 from my_permissions() where permission_code = 'checklist.fill'),
            'my_permissions lists own permissions');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000003', false);
select t.ok((select count(*) = 5 from profiles), 'outlet manager sees the 5 people at Outlet A only');

select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000007', false);
select t.ok((select count(*) = 0 from module_assignments), 'HQ admin cannot see training records (not their job)');
reset role;

-- ---------- Mentorship ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000003', false);
select t.ok(t.fails($$select assign_mentor('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000010')$$),
            'level 1 server cannot mentor (min level 2)');
select assign_mentor('aaaaaaaa-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000002');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select t.ok((select count(*) = 2 from profiles), 'mentor sees own profile and own trainee');
reset role;

-- ---------- Quiz and practical ----------
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select complete_block(id, '00000000-0000-0000-0000-00000000b101') from module_assignments;
select set_config('t.quiz', start_quiz_attempt((select id from module_assignments))::text, false);
select t.ok(position('is_correct' in current_setting('t.quiz')) = 0, 'quiz questions are served without answers');
select t.ok((submit_quiz_attempt((current_setting('t.quiz')::jsonb ->> 'attempt_id')::uuid,
            '{"00000000-0000-0000-0000-0000000009b1": "00000000-0000-0000-0000-0000000009c1"}') ->> 'passed')::boolean,
            'correct answer passes the quiz');
select t.ok((select status <> 'completed' from module_assignments), 'not complete until the practical test passes');
reset role;
insert into media_files (id, bucket, object_key, kind, uploaded_by, outlet_id, status)
values ('00000000-0000-0000-0000-0000000006a1', 'practical', 'putu/test1.mp4', 'practical_video',
        'aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000f1', 'ready');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select set_config('t.sub', submit_practical((select id from module_assignments), '00000000-0000-0000-0000-0000000006a1')::text, false);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000003', false);
select t.ok(t.fails(format($$select score_practical(%L, '[{"criterion_id":"00000000-0000-0000-0000-0000000008a1","result":"pass"}]')$$, current_setting('t.sub'))),
            'only the mentor can score the practical test');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select score_practical(current_setting('t.sub')::uuid, '[{"criterion_id":"00000000-0000-0000-0000-0000000008a1","result":"pass"}]', 'Nice');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok((select status = 'completed' from module_assignments), 'module completes after the mentor passes the test');
select t.ok((select count(*) = 1 from certificates), 'certificate issued with expiry');
reset role;

-- ---------- Checklists and issues ----------
insert into checklist_templates (id, name, fail_issue_sla_hours) values ('00000000-0000-0000-0000-0000000005a1', 'Opening checklist', 4);
insert into checklist_template_versions (id, template_id, version, published_at) values
  ('00000000-0000-0000-0000-0000000005b1', '00000000-0000-0000-0000-0000000005a1', 1, now());
insert into checklist_items (id, template_version_id, sort, label, answer_type, min_value, max_value) values
  ('00000000-0000-0000-0000-0000000005c1', '00000000-0000-0000-0000-0000000005b1', 1, 'Hand soap refilled', 'yes_no', null, null),
  ('00000000-0000-0000-0000-0000000005c2', '00000000-0000-0000-0000-0000000005b1', 2, 'Chiller temperature', 'number', 1, 5);
insert into checklist_template_positions values ('00000000-0000-0000-0000-0000000005a1', '00000000-0000-0000-0000-0000000000c1');
insert into checklist_schedules (template_id, shift, due_time) values ('00000000-0000-0000-0000-0000000005a1', 'opening', '23:59');
select t.ok(app.generate_checklist_runs(current_date) = 2, 'one run generated per outlet');

set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000009', false);
select t.ok((select count(*) = 1 from checklist_runs), 'Outlet B staff sees only their own outlet run');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select set_config('t.run', (select id::text from checklist_runs), false);
insert into checklist_responses (run_id, item_id, value_bool, answered_by)
  values (current_setting('t.run')::uuid, '00000000-0000-0000-0000-0000000005c1', false, auth.uid());
insert into checklist_responses (run_id, item_id, value_number, answered_by)
  values (current_setting('t.run')::uuid, '00000000-0000-0000-0000-0000000005c2', 4, auth.uid());
select t.ok(t.fails(format($$select submit_checklist_run(%L, -5.147, 119.432)$$, current_setting('t.run'))),
            'submit refused away from the outlet');
select t.ok((submit_checklist_run(current_setting('t.run')::uuid, -8.650100, 115.216100) ->> 'failed')::int = 1,
            'submit at the outlet: 1 failed item');
reset role;
select t.ok((select count(*) = 1 from issues), 'failed item raised an issue');
select t.ok((select count(*) >= 1 from notifications where type = 'issue_created'
             and user_id = 'aaaaaaaa-0000-0000-0000-000000000003'), 'outlet manager notified');

set role authenticated;
select set_config('t.issue', (select id::text from issues), false);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000009', false);
select t.ok((select count(*) = 0 from issues), 'Outlet B staff cannot see Outlet A issues');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000003', false);
select assign_issue(current_setting('t.issue')::uuid, 'aaaaaaaa-0000-0000-0000-000000000010');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000010', false);
select fix_issue(current_setting('t.issue')::uuid, 'Refilled');
select t.ok(t.fails(format($$select verify_issue(%L, true)$$, current_setting('t.issue'))),
            'staff cannot verify (no issue.verify)');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000004', false);
select verify_issue(current_setting('t.issue')::uuid, true, 'Checked on visit');
select t.ok((select status = 'closed' from issues), 'area manager closes the fixed issue');
reset role;

-- fixer cannot verify own fix
insert into issues (id, outlet_id, source, title, due_at, status, fixed_by, fixed_at)
values ('00000000-0000-0000-0000-0000000004a1', '00000000-0000-0000-0000-0000000000f1', 'manual', 'Test', now(), 'fixed',
        'aaaaaaaa-0000-0000-0000-000000000003', now());
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000003', false);
select t.ok(t.fails($$select verify_issue('00000000-0000-0000-0000-0000000004a1', true)$$),
            'nobody verifies their own fix');
reset role;

-- ---------- Anonymous mentor rating ----------
update mentorships set ended_at = now(), end_reason = 'path_completed';
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select submit_mentor_rating((select id from mentorships), 5::smallint, 'Very patient');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000002', false);
select t.ok((select count(*) = 0 from mentor_ratings), 'mentor cannot read rating rows');
select t.ok((my_mentor_rating() ->> 'average') is null, 'average hidden below 3 ratings');
select t.ok(t.fails($$select * from mentor_ratings_with_raters('aaaaaaaa-0000-0000-0000-000000000002')$$),
            'mentor cannot see raters');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000007', false);
select t.ok(t.fails($$select * from mentor_ratings_with_raters('aaaaaaaa-0000-0000-0000-000000000002')$$),
            'HQ admin cannot see raters');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000008', false);
select t.ok((select rater_name = 'Putu' from mentor_ratings_with_raters('aaaaaaaa-0000-0000-0000-000000000002')),
            'HR sees the rater');
reset role;
select t.ok((select count(*) = 1 from mentor_rating_access_log), 'HR view of raters was logged');

-- ---------- Deactivation and audit ----------
update profiles set status = 'inactive' where id = 'aaaaaaaa-0000-0000-0000-000000000003';
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000003', false);
select t.ok((select count(*) = 0 from profiles), 'deactivated manager sees nothing');
select t.ok((select count(*) = 0 from my_permissions()), 'deactivated manager has no permissions');
reset role;
select t.ok((select count(*) > 0 from admin_audit_log where table_name = 'user_roles' and action = 'DELETE'),
            'role removal is in the audit log');

-- ---------- Anonymous access ----------
set role anon;
select t.ok(t.fails($$select * from profiles$$), 'anon has no table access');
reset role;

\echo ALL TESTS PASSED
