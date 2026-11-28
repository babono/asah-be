-- Tests for 20261128000000_ai_photo_check.sql. Uses the fixtures from 10_behaviour_tests.sql.
\set ON_ERROR_STOP 1
\set QUIET 1
grant usage on schema t to service_role;
grant execute on all functions in schema t to service_role;

-- Setup (superuser): an AI-enabled toilet checklist for servers at Outlet A
update app_settings set value = jsonb_set(value, '{mode}', '"flag"') where key = 'ai_photo_check';
select t.ok(t.fails($$insert into checklist_items (template_version_id, sort, label, answer_type, photo_rule, ai_check_enabled)
                     values ('00000000-0000-0000-0000-0000000005b1', 9, 'x', 'yes_no', 'none', true)$$),
            'AI check needs a photo item and criteria');
insert into checklist_templates (id, name) values ('00000000-0000-0000-0000-0000000003a1', 'Toilet check');
insert into checklist_template_versions (id, template_id, version, published_at)
values ('00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000003a1', 1, now());
insert into checklist_items (id, template_version_id, sort, label, answer_type, photo_rule, ai_check_enabled, ai_criteria)
values ('00000000-0000-0000-0000-0000000003c1', '00000000-0000-0000-0000-0000000003b1', 1, 'Toilet clean', 'photo', 'required', true,
        'Floor dry, no rubbish on the floor, toilet bowl clean, tissue and soap available');
insert into checklist_template_positions values ('00000000-0000-0000-0000-0000000003a1', '00000000-0000-0000-0000-0000000000c1');
insert into checklist_runs (id, template_version_id, outlet_id, shift_date, shift, due_at)
values ('00000000-0000-0000-0000-0000000003d1', '00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000f1', current_date, 'mid', now() + interval '1 hour'),
       ('00000000-0000-0000-0000-0000000003d2', '00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000f1', current_date, 'closing', now() + interval '2 hours');

-- Staff fills and submits run 1 with a photo
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
insert into media_files (id, bucket, object_key, kind, uploaded_by, outlet_id, status)
values ('00000000-0000-0000-0000-0000000003e1', 'checklist-photos', 'f1/run1/toilet.jpg', 'checklist_photo', auth.uid(),
        '00000000-0000-0000-0000-0000000000f1', 'ready');
insert into checklist_responses (id, run_id, item_id, answered_by)
values ('00000000-0000-0000-0000-0000000003f1', '00000000-0000-0000-0000-0000000003d1', '00000000-0000-0000-0000-0000000003c1', auth.uid());
insert into checklist_response_photos values ('00000000-0000-0000-0000-0000000003f1', '00000000-0000-0000-0000-0000000003e1');
select submit_checklist_run('00000000-0000-0000-0000-0000000003d1', -8.650100, 115.216100);
select t.ok((select count(*) = 0 from ai_photo_checks), 'staff cannot read AI results');
select t.ok(t.fails($$select * from ai_claim_photo_checks(10)$$), 'staff cannot call the worker functions');
reset role;
select t.ok((select count(*) = 1 from ai_photo_checks where status = 'queued' and mode = 'flag'),
            'submitting the run queued one AI check');

-- Worker (service_role) claims and completes it as "not clean"
set role service_role;
select t.ok((select count(*) = 1 from ai_claim_photo_checks(10) where object_key = 'f1/run1/toilet.jpg'),
            'worker claims the queued check with its file key');
select t.ok((select count(*) = 0 from ai_claim_photo_checks(10)), 'a running check is not claimed twice');
select ai_complete_photo_check((select id from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d1'),
  '{"verdict":"not_clean","confidence":0.92,"right_area":true,"photo_usable":true,
    "reasons":["Tissue paper on the floor","Bowl has stains"],"provider":"deepseek","model":"deepseek-flash",
    "input_tokens":700,"output_tokens":120,"latency_ms":1800,"raw":{}}');
reset role;
select t.ok((select count(*) = 1 from issues where source = 'ai_check' and title = 'AI flagged: Toilet clean'),
            'flag mode: confident not-clean raised an issue');
select t.ok((select cost_usd > 0 from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d1'),
            'cost recorded');

-- Area manager reviews; staff and outlet staff elsewhere cannot
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000009', false);
select t.ok((select count(*) = 0 from ai_photo_checks), 'Outlet B staff cannot see Outlet A AI checks');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000004', false);
select t.ok((select count(*) = 1 from ai_photo_checks), 'area manager sees AI checks in their area');
select review_ai_photo_check((select id from ai_photo_checks), 'not_clean', 'Agree');
select t.ok((select review_verdict = 'not_clean' and issue_id is not null from ai_photo_checks), 'review stored');
select t.ok((select count(*) = 1 from v_ai_check_agreement where agreed = 1), 'agreement view counts it');
reset role;

-- Shadow mode: result stored, no issue
update app_settings set value = jsonb_set(value, '{mode}', '"shadow"') where key = 'ai_photo_check';
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
insert into media_files (id, bucket, object_key, kind, uploaded_by, outlet_id, status)
values ('00000000-0000-0000-0000-0000000003e2', 'checklist-photos', 'f1/run2/toilet.jpg', 'checklist_photo', auth.uid(),
        '00000000-0000-0000-0000-0000000000f1', 'ready');
insert into checklist_responses (id, run_id, item_id, answered_by)
values ('00000000-0000-0000-0000-0000000003f2', '00000000-0000-0000-0000-0000000003d2', '00000000-0000-0000-0000-0000000003c1', auth.uid());
insert into checklist_response_photos values ('00000000-0000-0000-0000-0000000003f2', '00000000-0000-0000-0000-0000000003e2');
select submit_checklist_run('00000000-0000-0000-0000-0000000003d2', -8.650100, 115.216100);
reset role;
set role service_role;
select count(*) from ai_claim_photo_checks(10);
select ai_complete_photo_check((select id from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d2'),
  '{"verdict":"not_clean","confidence":0.95,"right_area":true,"photo_usable":true,"reasons":["Wet floor"]}');
reset role;
select t.ok((select count(*) = 1 from issues where source = 'ai_check' and run_id = '00000000-0000-0000-0000-0000000003d2') = false,
            'shadow mode: no issue raised');

-- Failures retry, then stop
update ai_photo_checks set status = 'running', attempts = 1 where run_id = '00000000-0000-0000-0000-0000000003d2';
set role service_role;
select ai_fail_photo_check((select id from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d2'), 'timeout');
reset role;
select t.ok((select status = 'queued' from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d2'),
            'failure requeues while attempts remain');
update ai_photo_checks set status = 'running', attempts = 3 where run_id = '00000000-0000-0000-0000-0000000003d2';
set role service_role;
select ai_fail_photo_check((select id from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d2'), 'timeout');
reset role;
select t.ok((select status = 'failed' from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d2'),
            'failure stops after max attempts');

-- False alarm: a manager marks a flagged check "clean" and the open AI issue closes
update app_settings set value = jsonb_set(value, '{mode}', '"flag"') where key = 'ai_photo_check';
insert into checklist_runs (id, template_version_id, outlet_id, shift_date, shift, due_at)
values ('00000000-0000-0000-0000-0000000003d3', '00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000f1', current_date, 'opening', now() + interval '3 hours'),
       ('00000000-0000-0000-0000-0000000003d4', '00000000-0000-0000-0000-0000000003b1', '00000000-0000-0000-0000-0000000000f1', current_date, 'other', now() + interval '4 hours');
set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
insert into media_files (id, bucket, object_key, kind, uploaded_by, outlet_id, status)
values ('00000000-0000-0000-0000-0000000003e3', 'checklist-photos', 'f1/run3/toilet.jpg', 'checklist_photo', auth.uid(), '00000000-0000-0000-0000-0000000000f1', 'ready'),
       ('00000000-0000-0000-0000-0000000003e4', 'checklist-photos', 'f1/run4/toilet.jpg', 'checklist_photo', auth.uid(), '00000000-0000-0000-0000-0000000000f1', 'ready');
insert into checklist_responses (id, run_id, item_id, answered_by)
values ('00000000-0000-0000-0000-0000000003f3', '00000000-0000-0000-0000-0000000003d3', '00000000-0000-0000-0000-0000000003c1', auth.uid()),
       ('00000000-0000-0000-0000-0000000003f4', '00000000-0000-0000-0000-0000000003d4', '00000000-0000-0000-0000-0000000003c1', auth.uid());
insert into checklist_response_photos values
  ('00000000-0000-0000-0000-0000000003f3', '00000000-0000-0000-0000-0000000003e3'),
  ('00000000-0000-0000-0000-0000000003f4', '00000000-0000-0000-0000-0000000003e4');
select submit_checklist_run('00000000-0000-0000-0000-0000000003d3', -8.650100, 115.216100);
select submit_checklist_run('00000000-0000-0000-0000-0000000003d4', -8.650100, 115.216100);
reset role;
set role service_role;
select count(*) from ai_claim_photo_checks(10);
select ai_complete_photo_check(c.id,
  '{"verdict":"not_clean","confidence":0.9,"right_area":true,"photo_usable":true,"reasons":["Lantai basah"],
    "provider":"qwen","model":"qwen3-vl-plus","input_tokens":900,"output_tokens":80,"latency_ms":2100,"raw":{}}')
  from ai_photo_checks c where c.run_id in ('00000000-0000-0000-0000-0000000003d3', '00000000-0000-0000-0000-0000000003d4');
reset role;
-- Run 4's issue was already marked fixed before the review
update issues set status = 'fixed', fixed_by = 'aaaaaaaa-0000-0000-0000-000000000001', fixed_at = now()
 where run_id = '00000000-0000-0000-0000-0000000003d4' and source = 'ai_check';

set role authenticated;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000001', false);
select t.ok(t.fails($$select review_ai_photo_check((select id from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d3'), 'clean')$$),
            'staff cannot dismiss an AI issue');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-0000-0000-0000-000000000004', false);
select review_ai_photo_check((select id from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d3'), 'clean', 'Sudah bersih');
select review_ai_photo_check((select id from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d4'), 'clean');
select t.ok(t.fails($$select review_ai_photo_check((select id from ai_photo_checks where run_id = '00000000-0000-0000-0000-0000000003d3'), 'not_clean')$$),
            'a check can be reviewed only once');
reset role;
select t.ok((select status = 'closed' and closed_by = 'aaaaaaaa-0000-0000-0000-000000000004' and fixed_by is null
               from issues where run_id = '00000000-0000-0000-0000-0000000003d3' and source = 'ai_check'),
            'false alarm: reviewing clean closes the open AI issue without a fix');
select t.ok((select count(*) = 1 from issue_events e join issues i on i.id = e.issue_id
              where i.run_id = '00000000-0000-0000-0000-0000000003d3' and e.type = 'dismissed'
                and e.note = 'False alarm (AI review): Sudah bersih'),
            'the dismissal is in the issue history');
select t.ok((select status = 'fixed' from issues where run_id = '00000000-0000-0000-0000-0000000003d4' and source = 'ai_check'),
            'an issue already marked fixed is left to the normal accept flow');
select t.ok((select false_flags = 2 from v_ai_check_agreement where model = 'qwen3-vl-plus'),
            'agreement view counts false flags per model');

-- Compliance score is never touched by AI
select t.ok((select compliance_pct = 100 from checklist_runs where id = '00000000-0000-0000-0000-0000000003d1'),
            'AI result does not change the compliance score');

\echo ALL AI TESTS PASSED
