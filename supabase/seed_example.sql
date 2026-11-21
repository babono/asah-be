-- Example data to try the app end to end. Replace names with Juta Berlian
-- Culinary's real brands, outlets, departments and positions before the pilot.
-- Run once in the SQL editor after the migrations (as the postgres role).
-- Users are not created here: add them in the admin web.

-- Org ------------------------------------------------------------------------
insert into public.brands (id, name) values ('10000000-0000-0000-0000-000000000001', 'Brand A') on conflict do nothing;
insert into public.areas (id, name) values ('20000000-0000-0000-0000-000000000001', 'Area 1') on conflict do nothing;
-- Set real coordinates: checklists can only be submitted within the radius.
insert into public.outlets (id, brand_id, area_id, name, address, latitude, longitude, geofence_radius_m, timezone) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'Outlet A', '[ADDRESS]', -8.650000, 115.216000, 150, 'Asia/Makassar'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'Outlet B', '[ADDRESS]', -8.670000, 115.230000, 150, 'Asia/Makassar')
on conflict do nothing;

insert into public.departments (id, name, sort_order) values
  ('40000000-0000-0000-0000-000000000001', 'Service', 0),
  ('40000000-0000-0000-0000-000000000002', 'Kitchen', 1)
on conflict do nothing;
insert into public.positions (id, department_id, name, level) values
  ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'Server', 1),
  ('50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000001', 'Captain', 2),
  ('50000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000001', 'Service supervisor', 3),
  ('50000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000002', 'Cook helper', 1),
  ('50000000-0000-0000-0000-000000000005', '40000000-0000-0000-0000-000000000002', 'Cook', 2)
on conflict do nothing;

-- Aksi: opening checklist (design screen 2) ----------------------------------
insert into public.checklist_templates (id, name, kind, fail_issue_severity, fail_issue_sla_hours) values
  ('60000000-0000-0000-0000-000000000001', 'Opening checklist', 'routine', 'medium', 4),
  ('60000000-0000-0000-0000-000000000002', 'Fridge temperature log', 'routine', 'high', 2),
  ('60000000-0000-0000-0000-000000000003', 'Area manager visit', 'audit', 'medium', 24)
on conflict do nothing;
insert into public.checklist_template_versions (id, template_id, version, published_at) values
  ('61000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 1, now()),
  ('61000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002', 1, now()),
  ('61000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000003', 1, now())
on conflict do nothing;
insert into public.checklist_items (template_version_id, sort, label, answer_type, photo_rule, min_value, max_value, unit) values
  ('61000000-0000-0000-0000-000000000001', 1, 'Floor mopped and dry', 'yes_no', 'optional', null, null, null),
  ('61000000-0000-0000-0000-000000000001', 2, 'Toilet clean', 'yes_no', 'required', null, null, null),
  ('61000000-0000-0000-0000-000000000001', 3, 'Chiller temperature', 'number', 'optional', 1, 5, '°C'),
  ('61000000-0000-0000-0000-000000000001', 4, 'Hand soap refilled', 'yes_no', 'none', null, null, null),
  ('61000000-0000-0000-0000-000000000002', 1, 'Chiller 1 temperature', 'number', 'none', 1, 5, '°C'),
  ('61000000-0000-0000-0000-000000000002', 2, 'Freezer temperature', 'number', 'none', -22, -18, '°C'),
  ('61000000-0000-0000-0000-000000000002', 3, 'FIFO labels on all containers', 'yes_no', 'required', null, null, null),
  ('61000000-0000-0000-0000-000000000003', 1, 'Opening checklist done on time this week', 'yes_no', 'none', null, null, null),
  ('61000000-0000-0000-0000-000000000003', 2, 'Kitchen floor and drains clean', 'yes_no', 'required', null, null, null),
  ('61000000-0000-0000-0000-000000000003', 3, 'Staff in full uniform', 'yes_no', 'optional', null, null, null)
on conflict do nothing;
insert into public.checklist_template_positions (template_id, position_id) values
  ('60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001'),
  ('60000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000002'),
  ('60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000004'),
  ('60000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000005')
on conflict do nothing;
insert into public.checklist_schedules (template_id, outlet_id, shift, due_time) values
  ('60000000-0000-0000-0000-000000000001', null, 'opening', '09:00'),
  ('60000000-0000-0000-0000-000000000002', null, 'opening', '10:00');

-- Asuh: a module with an SOP card, a quiz and a practical test ----------------
insert into public.modules (id, category) values
  ('70000000-0000-0000-0000-000000000001', 'Service'),
  ('70000000-0000-0000-0000-000000000002', 'Service')
on conflict do nothing;
insert into public.module_versions (id, module_id, version, status, title, summary, estimated_minutes, certificate_valid_days, published_at) values
  ('71000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', 1, 'published', 'Welcome to the outlet',
   'Who is who, where things are, and how a shift runs.', 10, null, now()),
  ('71000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000002', 1, 'published', 'Table setting',
   'Set a table the same way at every outlet.', 15, 365, now())
on conflict do nothing;
insert into public.module_target_positions (module_id, position_id) values
  ('70000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000001')
on conflict do nothing;
insert into public.content_blocks (module_version_id, sort, type, title, body) values
  ('71000000-0000-0000-0000-000000000001', 1, 'sop_card', 'Your first day', E'1. Meet your outlet manager and your mentor\n2. Collect your uniform\n3. Walk through the floor, kitchen and store'),
  ('71000000-0000-0000-0000-000000000002', 1, 'sop_card', 'Table setting · 6 steps', E'1. [SOP step from HQ]\n2. [SOP step from HQ]\n3. [SOP step from HQ]\n4. [SOP step from HQ]\n5. [SOP step from HQ]\n6. [SOP step from HQ]')
on conflict do nothing;
insert into public.quizzes (id, module_version_id, pass_mark_pct, max_attempts) values
  ('72000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000002', 80, 2) on conflict do nothing;
insert into public.questions (id, topic, prompt) values
  ('73000000-0000-0000-0000-000000000001', 'Service', 'Where does the dessert spoon go?') on conflict do nothing;
insert into public.question_options (question_id, label, is_correct, sort) values
  ('73000000-0000-0000-0000-000000000001', 'Above the plate', true, 0),
  ('73000000-0000-0000-0000-000000000001', 'Left of the fork', false, 1),
  ('73000000-0000-0000-0000-000000000001', 'Right of the knife', false, 2);
insert into public.quiz_questions (quiz_id, question_id) values
  ('72000000-0000-0000-0000-000000000001', '73000000-0000-0000-0000-000000000001') on conflict do nothing;
insert into public.rubric_criteria (module_version_id, title, sort) values
  ('71000000-0000-0000-0000-000000000002', 'Cutlery in the right place', 0),
  ('71000000-0000-0000-0000-000000000002', 'Glassware polished and placed', 1),
  ('71000000-0000-0000-0000-000000000002', 'Hygiene', 2);

-- Learning path for Server: assigned automatically to every Server (T7)
insert into public.learning_paths (id, position_id, name) values
  ('74000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'Server path') on conflict do nothing;
insert into public.learning_path_items (path_id, module_id, sort, is_mandatory, due_days) values
  ('74000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', 1, true, 1),
  ('74000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000002', 2, true, 7)
on conflict do nothing;

-- Today's runs, without waiting for the nightly job
select app.generate_checklist_runs();
