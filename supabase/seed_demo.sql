-- =============================================================================
-- ASAH demo data (mock): 5 outlets in Bali, 23 people, 6 modules (one with the
-- client's real "3 Seconds Rule of Eye Contact" video), 6 checklists with four
-- weeks of history, issues, audits, mentorships, ratings and formal trainings.
--
-- Everything except the eye-contact video is made up for the client demo.
-- Replace or delete it before the pilot.
--
-- Prerequisites (see README › Demo):
--   * the migrations are applied;
--   * the 23 auth users exist (phones +62811000000[1-7] and +62811000001[01-16]),
--     e.g. created with the Auth admin API;
--   * the video is uploaded to asah-media/training/8a000000-0000-0000-0000-000000000001.mp4.
-- Run as postgres. Safe to run once on an empty database.
-- =============================================================================

create or replace function pg_temp.u(p_phone text) returns uuid language sql stable as $$
  select id from auth.users where phone = p_phone
$$;

-- Org --------------------------------------------------------------------------
insert into public.brands (id, name) values
  ('10000000-0000-0000-0000-000000000001', 'Dapur Berlian'),
  ('10000000-0000-0000-0000-000000000002', 'Kopi Berlian');
insert into public.areas (id, name) values
  ('20000000-0000-0000-0000-000000000001', 'Badung'),
  ('20000000-0000-0000-0000-000000000002', 'Denpasar');
insert into public.outlets (id, brand_id, area_id, name, address, latitude, longitude, geofence_radius_m, timezone) values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'Dapur Berlian Seminyak', 'Jl. Kayu Aya, Seminyak', -8.691300, 115.168200, 150, 'Asia/Makassar'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001',
   'Dapur Berlian Canggu', 'Jl. Batu Bolong, Canggu', -8.647800, 115.138500, 150, 'Asia/Makassar'),
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001',
   'Kopi Berlian Kuta', 'Jl. Legian, Kuta', -8.718000, 115.169000, 150, 'Asia/Makassar'),
  ('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000002',
   'Dapur Berlian Sanur', 'Jl. Danau Tamblingan, Sanur', -8.692900, 115.262000, 150, 'Asia/Makassar'),
  ('30000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000002',
   'Kopi Berlian Renon', 'Jl. Raya Puputan, Renon', -8.670500, 115.233000, 150, 'Asia/Makassar');

insert into public.departments (id, name, sort_order) values
  ('40000000-0000-0000-0000-000000000001', 'Service', 0),
  ('40000000-0000-0000-0000-000000000002', 'Kitchen', 1),
  ('40000000-0000-0000-0000-000000000003', 'Bar', 2);
insert into public.positions (id, department_id, name, level) values
  ('50000000-0000-0000-0000-000000000001', '40000000-0000-0000-0000-000000000001', 'Server', 1),
  ('50000000-0000-0000-0000-000000000002', '40000000-0000-0000-0000-000000000001', 'Captain', 2),
  ('50000000-0000-0000-0000-000000000003', '40000000-0000-0000-0000-000000000001', 'Service supervisor', 3),
  ('50000000-0000-0000-0000-000000000004', '40000000-0000-0000-0000-000000000001', 'Restaurant manager', 4),
  ('50000000-0000-0000-0000-000000000005', '40000000-0000-0000-0000-000000000002', 'Cook helper', 1),
  ('50000000-0000-0000-0000-000000000006', '40000000-0000-0000-0000-000000000002', 'Cook', 2),
  ('50000000-0000-0000-0000-000000000007', '40000000-0000-0000-0000-000000000002', 'Chef de partie', 3),
  ('50000000-0000-0000-0000-000000000008', '40000000-0000-0000-0000-000000000003', 'Barista', 1),
  ('50000000-0000-0000-0000-000000000009', '40000000-0000-0000-0000-000000000003', 'Head barista', 2);

-- Demo settings: the client demo is not at an outlet, so skip the on-site check.
update public.app_settings set value = 'false' where key = 'require_geofence';

-- Asuh: modules --------------------------------------------------------------
insert into public.media_files (id, bucket, object_key, kind, mime_type, size_bytes, duration_seconds, status) values
  ('8a000000-0000-0000-0000-000000000001', 'asah-media', 'training/8a000000-0000-0000-0000-000000000001.mp4',
   'training_video', 'video/mp4', 22107400, 18, 'ready');

insert into public.modules (id, category) values
  ('70000000-0000-0000-0000-000000000001', 'Onboarding'),
  ('70000000-0000-0000-0000-000000000002', 'Service'),
  ('70000000-0000-0000-0000-000000000003', 'Service'),
  ('70000000-0000-0000-0000-000000000004', 'Kitchen'),
  ('70000000-0000-0000-0000-000000000005', 'Bar'),
  ('70000000-0000-0000-0000-000000000006', 'Service');

insert into public.module_versions (id, module_id, version, status, title, summary, estimated_minutes, certificate_valid_days, published_at, submitted_at, reviewed_at) values
  ('71000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', 1, 'published',
   'Welcome to Juta Berlian', 'Who is who, where things are, and how a shift runs.', 10, null, now() - interval '200 days', null, null),
  ('71000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000002', 1, 'published',
   '3 Seconds Rule of Eye Contact', 'Make every guest feel seen: greet, take the order and say goodbye with eye contact.', 5, 365,
   now() - interval '180 days', null, null),
  ('71000000-0000-0000-0000-000000000003', '70000000-0000-0000-0000-000000000003', 1, 'published',
   'Table setting', 'Set a table the same way at every outlet.', 15, 365, now() - interval '200 days', null, null),
  ('71000000-0000-0000-0000-000000000004', '70000000-0000-0000-0000-000000000004', 1, 'published',
   'Food safety and temperature control', 'Keep food safe: temperatures, labels, FIFO and storage.', 15, 180, now() - interval '200 days', null, null),
  ('71000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000005', 1, 'published',
   'Espresso basics', 'Dose, tamp and pull a shot to the Kopi Berlian standard.', 20, 365, now() - interval '200 days', null, null),
  ('71000000-0000-0000-0000-000000000006', '70000000-0000-0000-0000-000000000006', 1, 'in_review',
   'Handling guest complaints', 'Listen, apologise, solve and thank: turn a complaint into a returning guest.', 10, null,
   null, now() - interval '1 day', null);

insert into public.module_target_positions (module_id, position_id)
select '70000000-0000-0000-0000-000000000001'::uuid, id from public.positions
union all select '70000000-0000-0000-0000-000000000002', unnest(array['50000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000008','50000000-0000-0000-0000-000000000009']::uuid[])
union all select '70000000-0000-0000-0000-000000000003', unnest(array['50000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002']::uuid[])
union all select '70000000-0000-0000-0000-000000000004', unnest(array['50000000-0000-0000-0000-000000000005','50000000-0000-0000-0000-000000000006','50000000-0000-0000-0000-000000000007']::uuid[])
union all select '70000000-0000-0000-0000-000000000005', unnest(array['50000000-0000-0000-0000-000000000008','50000000-0000-0000-0000-000000000009']::uuid[])
union all select '70000000-0000-0000-0000-000000000006', unnest(array['50000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000003']::uuid[]);

insert into public.content_blocks (module_version_id, sort, type, title, body, media_file_id) values
  ('71000000-0000-0000-0000-000000000001', 1, 'sop_card', 'Your first day',
   E'1. Meet your outlet manager and your mentor\n2. Collect your uniform and name tag\n3. Walk through the floor, kitchen and store\n4. Download ASAH and check today''s checklists', null),
  ('71000000-0000-0000-0000-000000000001', 2, 'sop_card', 'How a shift runs',
   E'1. Opening checklist before 09:00\n2. Mid-shift floor check at 15:00\n3. Closing checklist before you go home\n4. Anything broken or unsafe: raise an issue in ASAH with a photo', null),
  ('71000000-0000-0000-0000-000000000002', 1, 'video', '3 Seconds Rule of Eye Contact', null, '8a000000-0000-0000-0000-000000000001'),
  ('71000000-0000-0000-0000-000000000002', 2, 'sop_card', 'At every table',
   E'1. Look up when guests walk in, smile and greet them within 30 seconds\n2. Hold eye contact for about 3 seconds while you greet them\n3. Look at the guest while taking the order, then repeat it back\n4. Busy? Make eye contact and nod so the guest knows you have seen them\n5. Make eye contact again when you say goodbye', null),
  ('71000000-0000-0000-0000-000000000003', 1, 'sop_card', 'Table setting · 6 steps',
   E'1. Wipe the table and check it does not wobble\n2. Place the folded napkin in the centre of each cover\n3. Fork on the left, knife and spoon on the right, 2 cm from the edge\n4. Dessert spoon above the plate, handle to the right\n5. Water glass above the knife, polished\n6. Condiments and menu in the centre, logo facing the guest', null),
  ('71000000-0000-0000-0000-000000000004', 1, 'sop_card', 'Temperatures',
   E'1. Chillers 1–5 °C, freezers −22 to −18 °C\n2. Log every chiller and freezer at 10:00 and 16:00\n3. Out of range: move the food, raise a high issue and tell the chef', null),
  ('71000000-0000-0000-0000-000000000004', 2, 'sop_card', 'Labels, FIFO and storage',
   E'1. Every container has a label: item, date prepared, use-by date\n2. First in, first out: new stock goes behind old stock\n3. Raw meat and chicken on the bottom shelf, ready-to-eat on top', null),
  ('71000000-0000-0000-0000-000000000005', 1, 'sop_card', 'Pulling a shot',
   E'1. Purge the group head\n2. Dose 18 g, level and tamp evenly\n3. Lock in and start within 5 seconds\n4. 36 g out in 25–30 seconds\n5. Knock out, wipe and purge again', null),
  ('71000000-0000-0000-0000-000000000006', 1, 'sop_card', 'L.A.S.T.',
   E'1. Listen without interrupting\n2. Apologise sincerely\n3. Solve it, or get your manager within 2 minutes\n4. Thank the guest for telling you', null);

insert into public.quizzes (id, module_version_id, pass_mark_pct, max_attempts) values
  ('72000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000002', 75, 3),
  ('72000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000003', 100, 2),
  ('72000000-0000-0000-0000-000000000004', '71000000-0000-0000-0000-000000000004', 80, 2);

insert into public.questions (id, topic, prompt, explanation) values
  ('73000000-0000-0000-0000-000000000001', 'Service', 'How long should you hold eye contact when you greet a guest?', 'About 3 seconds feels warm and confident without staring.'),
  ('73000000-0000-0000-0000-000000000002', 'Service', 'When should you make eye contact with a guest?', 'At every moment that matters: arrival, order and goodbye.'),
  ('73000000-0000-0000-0000-000000000003', 'Service', 'A guest raises their hand while you are carrying plates to another table. What do you do?', 'Eye contact and a nod tell the guest you have seen them, even when you cannot come right away.'),
  ('73000000-0000-0000-0000-000000000004', 'Service', 'Why does eye contact matter in service?', 'Guests remember how you made them feel.'),
  ('73000000-0000-0000-0000-000000000005', 'Service', 'Where does the dessert spoon go?', null),
  ('73000000-0000-0000-0000-000000000006', 'Service', 'Which side does the fork go on?', null),
  ('73000000-0000-0000-0000-000000000007', 'Kitchen', 'What is the safe temperature for a chiller?', null),
  ('73000000-0000-0000-0000-000000000008', 'Kitchen', 'What does FIFO mean?', null),
  ('73000000-0000-0000-0000-000000000009', 'Kitchen', 'Which shelf does raw chicken go on?', 'Raw meat on the bottom so nothing drips onto ready-to-eat food.');

insert into public.question_options (question_id, label, is_correct, sort) values
  ('73000000-0000-0000-0000-000000000001', 'About 3 seconds', true, 0),
  ('73000000-0000-0000-0000-000000000001', 'Less than 1 second', false, 1),
  ('73000000-0000-0000-0000-000000000001', 'The whole time the guest is talking', false, 2),
  ('73000000-0000-0000-0000-000000000001', 'You do not need to look at the guest', false, 3),
  ('73000000-0000-0000-0000-000000000002', 'When they arrive, when they order and when they leave', true, 0),
  ('73000000-0000-0000-0000-000000000002', 'Only when they complain', false, 1),
  ('73000000-0000-0000-0000-000000000002', 'Only when they pay', false, 2),
  ('73000000-0000-0000-0000-000000000002', 'Only with regular guests', false, 3),
  ('73000000-0000-0000-0000-000000000003', 'Make eye contact, nod and smile so they know you have seen them', true, 0),
  ('73000000-0000-0000-0000-000000000003', 'Ignore them until your hands are free', false, 1),
  ('73000000-0000-0000-0000-000000000003', 'Call out across the room that you are coming', false, 2),
  ('73000000-0000-0000-0000-000000000004', 'It shows the guest they are welcome and listened to', true, 0),
  ('73000000-0000-0000-0000-000000000004', 'It makes the kitchen faster', false, 1),
  ('73000000-0000-0000-0000-000000000004', 'It is only a rule for managers', false, 2),
  ('73000000-0000-0000-0000-000000000005', 'Above the plate', true, 0),
  ('73000000-0000-0000-0000-000000000005', 'Left of the fork', false, 1),
  ('73000000-0000-0000-0000-000000000005', 'Right of the knife', false, 2),
  ('73000000-0000-0000-0000-000000000006', 'Left', true, 0),
  ('73000000-0000-0000-0000-000000000006', 'Right', false, 1),
  ('73000000-0000-0000-0000-000000000007', '1–5 °C', true, 0),
  ('73000000-0000-0000-0000-000000000007', '6–10 °C', false, 1),
  ('73000000-0000-0000-0000-000000000007', '0 to −5 °C', false, 2),
  ('73000000-0000-0000-0000-000000000008', 'First in, first out', true, 0),
  ('73000000-0000-0000-0000-000000000008', 'Fresh items first only', false, 1),
  ('73000000-0000-0000-0000-000000000008', 'Freeze in, freeze out', false, 2),
  ('73000000-0000-0000-0000-000000000009', 'The bottom shelf', true, 0),
  ('73000000-0000-0000-0000-000000000009', 'The top shelf', false, 1),
  ('73000000-0000-0000-0000-000000000009', 'Any shelf with space', false, 2);

insert into public.quiz_questions (quiz_id, question_id, sort) values
  ('72000000-0000-0000-0000-000000000002', '73000000-0000-0000-0000-000000000001', 0),
  ('72000000-0000-0000-0000-000000000002', '73000000-0000-0000-0000-000000000002', 1),
  ('72000000-0000-0000-0000-000000000002', '73000000-0000-0000-0000-000000000003', 2),
  ('72000000-0000-0000-0000-000000000002', '73000000-0000-0000-0000-000000000004', 3),
  ('72000000-0000-0000-0000-000000000003', '73000000-0000-0000-0000-000000000005', 0),
  ('72000000-0000-0000-0000-000000000003', '73000000-0000-0000-0000-000000000006', 1),
  ('72000000-0000-0000-0000-000000000004', '73000000-0000-0000-0000-000000000007', 0),
  ('72000000-0000-0000-0000-000000000004', '73000000-0000-0000-0000-000000000008', 1),
  ('72000000-0000-0000-0000-000000000004', '73000000-0000-0000-0000-000000000009', 2);

insert into public.rubric_criteria (module_version_id, title, description, sort) values
  ('71000000-0000-0000-0000-000000000003', 'Cutlery in the right place', 'Fork left, knife and spoon right, dessert spoon above', 0),
  ('71000000-0000-0000-0000-000000000003', 'Glassware polished and placed', null, 1),
  ('71000000-0000-0000-0000-000000000003', 'Done within 2 minutes', null, 2),
  ('71000000-0000-0000-0000-000000000005', 'Dose and tamp', null, 0),
  ('71000000-0000-0000-0000-000000000005', 'Extraction time 25–30 s', null, 1),
  ('71000000-0000-0000-0000-000000000005', 'Clean station afterwards', null, 2);

insert into public.learning_paths (id, position_id, name) values
  ('74000000-0000-0000-0000-000000000001', '50000000-0000-0000-0000-000000000001', 'Server path'),
  ('74000000-0000-0000-0000-000000000002', '50000000-0000-0000-0000-000000000002', 'Captain path'),
  ('74000000-0000-0000-0000-000000000003', '50000000-0000-0000-0000-000000000005', 'Cook helper path'),
  ('74000000-0000-0000-0000-000000000004', '50000000-0000-0000-0000-000000000006', 'Cook path'),
  ('74000000-0000-0000-0000-000000000005', '50000000-0000-0000-0000-000000000008', 'Barista path'),
  ('74000000-0000-0000-0000-000000000006', '50000000-0000-0000-0000-000000000009', 'Head barista path');
insert into public.learning_path_items (path_id, module_id, sort, is_mandatory, due_days) values
  ('74000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000001', 1, true, 1),
  ('74000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000002', 2, true, 7),
  ('74000000-0000-0000-0000-000000000001', '70000000-0000-0000-0000-000000000003', 3, true, 14),
  ('74000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000001', 1, true, 1),
  ('74000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000002', 2, true, 7),
  ('74000000-0000-0000-0000-000000000002', '70000000-0000-0000-0000-000000000003', 3, true, 14),
  ('74000000-0000-0000-0000-000000000003', '70000000-0000-0000-0000-000000000001', 1, true, 1),
  ('74000000-0000-0000-0000-000000000003', '70000000-0000-0000-0000-000000000004', 2, true, 7),
  ('74000000-0000-0000-0000-000000000004', '70000000-0000-0000-0000-000000000001', 1, true, 1),
  ('74000000-0000-0000-0000-000000000004', '70000000-0000-0000-0000-000000000004', 2, true, 7),
  ('74000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000001', 1, true, 1),
  ('74000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000002', 2, true, 7),
  ('74000000-0000-0000-0000-000000000005', '70000000-0000-0000-0000-000000000005', 3, false, 30),
  ('74000000-0000-0000-0000-000000000006', '70000000-0000-0000-0000-000000000001', 1, true, 1),
  ('74000000-0000-0000-0000-000000000006', '70000000-0000-0000-0000-000000000002', 2, true, 7),
  ('74000000-0000-0000-0000-000000000006', '70000000-0000-0000-0000-000000000005', 3, true, 14);

-- People -----------------------------------------------------------------------
-- (phone, name, position, outlet, days since hired, locale)
drop table if exists pg_temp.demo_people;
create temp table demo_people (phone text, full_name text, position_id uuid, outlet_id uuid, hired_days int, locale text);
insert into demo_people values
  ('6281100000001', 'Rina Wijaya',        null, null, 900, 'en'),
  ('6281100000002', 'Dewi Lestari',       null, null, 700, 'en'),
  ('6281100000003', 'Budi Santoso',       null, null, 600, 'id'),
  ('6281100000004', 'Made Ayu Pratiwi',   '50000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000001', 500, 'id'),
  ('6281100000005', 'Komang Adi Saputra', '50000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001', 420, 'id'),
  ('6281100000006', 'Putu Sari Dewi',     '50000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 4, 'id'),
  ('6281100000007', 'Wayan Darma',        '50000000-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000001', 300, 'id'),
  ('6281100000101', 'Ketut Arya Wibawa',  '50000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 150, 'id'),
  ('6281100000102', 'Nyoman Rai Astuti',  '50000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 100, 'id'),
  ('6281100000103', 'Gede Pramana',       '50000000-0000-0000-0000-000000000005', '30000000-0000-0000-0000-000000000001', 12, 'id'),
  ('6281100000104', 'Wahyu Hidayat',      '50000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000002', 450, 'id'),
  ('6281100000105', 'Sinta Maharani',     '50000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002', 380, 'id'),
  ('6281100000106', 'Rizky Pratama',      '50000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000002', 9, 'id'),
  ('6281100000107', 'Eka Putri',          '50000000-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000002', 260, 'id'),
  ('6281100000108', 'Agus Setiawan',      '50000000-0000-0000-0000-000000000004', '30000000-0000-0000-0000-000000000004', 520, 'id'),
  ('6281100000109', 'Fitri Handayani',    '50000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004', 200, 'id'),
  ('6281100000110', 'Dimas Saputra',      '50000000-0000-0000-0000-000000000006', '30000000-0000-0000-0000-000000000004', 180, 'id'),
  ('6281100000111', 'Indah Permata',      '50000000-0000-0000-0000-000000000009', '30000000-0000-0000-0000-000000000005', 400, 'id'),
  ('6281100000112', 'Yoga Wirawan',       '50000000-0000-0000-0000-000000000008', '30000000-0000-0000-0000-000000000005', 6, 'id'),
  ('6281100000113', 'Rahmat Hidayat',     '50000000-0000-0000-0000-000000000009', '30000000-0000-0000-0000-000000000003', 350, 'id'),
  ('6281100000114', 'Lina Marlina',       '50000000-0000-0000-0000-000000000008', '30000000-0000-0000-0000-000000000003', 140, 'id'),
  ('6281100000115', 'Arief Nugroho',      null, null, 380, 'en'),
  ('6281100000116', 'Sari Utami',         '50000000-0000-0000-0000-000000000005', '30000000-0000-0000-0000-000000000004', 60, 'id');

-- Inserting a profile with a position assigns that position's learning path (trigger).
insert into public.profiles (id, full_name, phone, position_id, outlet_id, hire_date, locale, created_at)
select pg_temp.u(phone), full_name, '+' || phone, position_id, outlet_id,
       current_date - hired_days, locale, now() - make_interval(days => hired_days)
from demo_people;

-- Roles ------------------------------------------------------------------------
drop table if exists pg_temp.demo_roles;
create temp table demo_roles (phone text, role text, scope_type public.scope_type, scope_id uuid);
insert into demo_roles values
  ('6281100000001', 'HQ admin', 'group', null),
  ('6281100000001', 'HQ trainer', 'group', null),
  ('6281100000002', 'Training manager', 'group', null),
  ('6281100000002', 'HR and senior management', 'group', null),
  ('6281100000003', 'Area manager', 'area', '20000000-0000-0000-0000-000000000001'),
  ('6281100000003', 'Area manager', 'area', '20000000-0000-0000-0000-000000000002'),
  ('6281100000115', 'HQ trainer', 'group', null),
  ('6281100000004', 'Outlet manager', 'outlet', '30000000-0000-0000-0000-000000000001'),
  ('6281100000104', 'Outlet manager', 'outlet', '30000000-0000-0000-0000-000000000002'),
  ('6281100000113', 'Outlet manager', 'outlet', '30000000-0000-0000-0000-000000000003'),
  ('6281100000108', 'Outlet manager', 'outlet', '30000000-0000-0000-0000-000000000004'),
  ('6281100000111', 'Outlet manager', 'outlet', '30000000-0000-0000-0000-000000000005'),
  ('6281100000005', 'Mentor', 'outlet', '30000000-0000-0000-0000-000000000001'),
  ('6281100000007', 'Mentor', 'outlet', '30000000-0000-0000-0000-000000000001'),
  ('6281100000105', 'Mentor', 'outlet', '30000000-0000-0000-0000-000000000002'),
  ('6281100000111', 'Mentor', 'outlet', '30000000-0000-0000-0000-000000000005');
-- Everyone at an outlet is Staff there
insert into demo_roles select phone, 'Staff', 'outlet', outlet_id from demo_people where outlet_id is not null;

insert into public.user_roles (user_id, role_id, scope_type, scope_id, granted_by)
select pg_temp.u(d.phone), r.id, d.scope_type, d.scope_id, pg_temp.u('6281100000001')
from demo_roles d join public.roles r on r.name = d.role;

-- Training progress -----------------------------------------------------------
-- Due dates count from the hire date.
update public.module_assignments a
   set assigned_at = p.created_at,
       due_at = p.created_at + make_interval(days => i.due_days)
  from public.profiles p, public.learning_path_items i
 where p.id = a.user_id and i.path_id = a.path_id and i.module_id = a.module_id;

-- People hired more than 30 days ago have finished their path.
drop table if exists pg_temp.demo_done;
create temp table demo_done as
select a.id, a.user_id, a.module_id, a.module_version_id,
       least(a.due_at - interval '6 hours', now() - interval '1 day') as done_at
from public.module_assignments a join public.profiles p on p.id = a.user_id
where p.hire_date < current_date - 30;
-- New starters have finished Welcome on day 1.
insert into demo_done
select a.id, a.user_id, a.module_id, a.module_version_id, a.assigned_at + interval '7 hours'
from public.module_assignments a join public.profiles p on p.id = a.user_id
where p.hire_date >= current_date - 30 and a.module_id = '70000000-0000-0000-0000-000000000001';

insert into public.block_progress (assignment_id, block_id, completed_at)
select d.id, b.id, d.done_at - interval '20 minutes'
from demo_done d join public.content_blocks b on b.module_version_id = d.module_version_id;

insert into public.quiz_attempts (assignment_id, quiz_id, user_id, question_ids, started_at, submitted_at, score_pct, passed)
select d.id, q.id, d.user_id,
       array(select question_id from public.quiz_questions where quiz_id = q.id order by sort),
       d.done_at - interval '10 minutes', d.done_at - interval '5 minutes',
       case when q.pass_mark_pct = 100 then 100 else (array[75, 100, 100])[1 + floor(random() * 3)::int] end, true
from demo_done d join public.quizzes q on q.module_version_id = d.module_version_id;

update public.module_assignments a set status = 'completed', started_at = d.done_at - interval '1 day', completed_at = d.done_at
  from demo_done d where d.id = a.id;

insert into public.certificates (user_id, module_id, module_version_id, assignment_id, issued_at, expires_at)
select d.user_id, d.module_id, d.module_version_id, d.id, d.done_at, d.done_at + make_interval(days => mv.certificate_valid_days)
from demo_done d join public.module_versions mv on mv.id = d.module_version_id
where mv.certificate_valid_days is not null;

-- Rizky (Canggu) has watched the eye-contact video but not done the quiz yet.
update public.module_assignments set status = 'in_progress', started_at = now() - interval '2 days'
 where user_id = pg_temp.u('6281100000106') and module_id = '70000000-0000-0000-0000-000000000002';
insert into public.block_progress (assignment_id, block_id, completed_at)
select a.id, b.id, now() - interval '2 days'
from public.module_assignments a join public.content_blocks b on b.module_version_id = a.module_version_id and b.sort = 1
where a.user_id = pg_temp.u('6281100000106') and a.module_id = '70000000-0000-0000-0000-000000000002';

-- Mentorship ------------------------------------------------------------------
insert into public.mentorships (id, mentor_id, trainee_id, outlet_id, assigned_by, started_at, ended_at, end_reason) values
  -- Komang: Putu now; Ketut, Nyoman and Fitri before
  ('75000000-0000-0000-0000-000000000001', pg_temp.u('6281100000005'), pg_temp.u('6281100000006'), '30000000-0000-0000-0000-000000000001', pg_temp.u('6281100000004'), now() - interval '4 days', null, null),
  ('75000000-0000-0000-0000-000000000002', pg_temp.u('6281100000005'), pg_temp.u('6281100000101'), '30000000-0000-0000-0000-000000000001', pg_temp.u('6281100000004'), now() - interval '150 days', now() - interval '128 days', 'path_completed'),
  ('75000000-0000-0000-0000-000000000003', pg_temp.u('6281100000005'), pg_temp.u('6281100000102'), '30000000-0000-0000-0000-000000000001', pg_temp.u('6281100000004'), now() - interval '100 days', now() - interval '80 days', 'path_completed'),
  ('75000000-0000-0000-0000-000000000004', pg_temp.u('6281100000005'), pg_temp.u('6281100000109'), '30000000-0000-0000-0000-000000000001', pg_temp.u('6281100000004'), now() - interval '200 days', now() - interval '170 days', 'transferred'),
  -- Wayan: Gede (behind on Food safety)
  ('75000000-0000-0000-0000-000000000005', pg_temp.u('6281100000007'), pg_temp.u('6281100000103'), '30000000-0000-0000-0000-000000000001', pg_temp.u('6281100000004'), now() - interval '12 days', null, null),
  -- Sinta: Rizky
  ('75000000-0000-0000-0000-000000000006', pg_temp.u('6281100000105'), pg_temp.u('6281100000106'), '30000000-0000-0000-0000-000000000002', pg_temp.u('6281100000104'), now() - interval '9 days', null, null),
  -- Indah: Yoga
  ('75000000-0000-0000-0000-000000000007', pg_temp.u('6281100000111'), pg_temp.u('6281100000112'), '30000000-0000-0000-0000-000000000005', pg_temp.u('6281100000111'), now() - interval '6 days', null, null);
-- Fitri moved to Sanur after her path at Seminyak
-- (her mentorship ended with 'transferred'; her profile is already at Sanur)

insert into public.mentor_checkins (mentorship_id, week_of, feedback, goals, created_by, created_at) values
  ('75000000-0000-0000-0000-000000000002', current_date - 143, 'Learns the floor quickly. Still shy with guests.', 'Greet every table within 30 seconds', pg_temp.u('6281100000005'), now() - interval '143 days'),
  ('75000000-0000-0000-0000-000000000002', current_date - 136, 'Much more confident greeting guests. Table setting is neat.', 'Pass the table setting practical', pg_temp.u('6281100000005'), now() - interval '136 days'),
  ('75000000-0000-0000-0000-000000000003', current_date - 93, 'Good attitude, sometimes forgets the closing checklist.', 'Closing checklist every shift', pg_temp.u('6281100000005'), now() - interval '93 days'),
  ('75000000-0000-0000-0000-000000000005', current_date - 5, 'Keen and careful with knives. Has not opened the food safety module yet.', 'Finish Food safety this week', pg_temp.u('6281100000007'), now() - interval '5 days'),
  ('75000000-0000-0000-0000-000000000006', current_date - 2, 'Friendly with guests. Watched the eye-contact video, quiz next.', 'Pass the eye-contact quiz; start Table setting', pg_temp.u('6281100000105'), now() - interval '2 days');

insert into public.mentor_ratings (mentorship_id, mentor_id, rater_id, score, comment, created_at) values
  ('75000000-0000-0000-0000-000000000002', pg_temp.u('6281100000005'), pg_temp.u('6281100000101'), 5, 'Very patient, showed me every step of the opening checklist.', now() - interval '127 days'),
  ('75000000-0000-0000-0000-000000000003', pg_temp.u('6281100000005'), pg_temp.u('6281100000102'), 4, 'Helpful, but busy on weekends.', now() - interval '79 days'),
  ('75000000-0000-0000-0000-000000000004', pg_temp.u('6281100000005'), pg_temp.u('6281100000109'), 5, 'Explained why, not only how.', now() - interval '169 days');

-- Formal training (Komang and Putu): one approved for tomorrow 10:00, one Putu
-- asked for that Komang still has to answer. Times are Seminyak local (WITA).
insert into public.formal_trainings (id, mentorship_id, mentor_id, trainee_id, outlet_id, scheduled_at, duration_minutes,
                                     topic, note, status, requested_by, responded_by, responded_at, response_note, created_at) values
  ('77000000-0000-0000-0000-000000000001', '75000000-0000-0000-0000-000000000001', pg_temp.u('6281100000005'), pg_temp.u('6281100000006'),
   '30000000-0000-0000-0000-000000000001', (current_date + 1 + time '10:00') at time zone 'Asia/Makassar', 30,
   'Table setting on the floor', 'Before lunch service, at table 12.', 'approved',
   pg_temp.u('6281100000005'), pg_temp.u('6281100000006'), now() - interval '20 hours', 'Siap, Kak!', now() - interval '1 day'),
  ('77000000-0000-0000-0000-000000000002', '75000000-0000-0000-0000-000000000001', pg_temp.u('6281100000005'), pg_temp.u('6281100000006'),
   '30000000-0000-0000-0000-000000000001', (current_date + 3 + time '14:00') at time zone 'Asia/Makassar', 30,
   'Handling a guest complaint', 'I am not sure what to say when food is late.', 'requested',
   pg_temp.u('6281100000006'), null, null, null, now() - interval '2 hours');

insert into public.notifications (user_id, type, title, body, data, created_at)
select n.user_id, n.type, n.title, f.topic,
       jsonb_build_object('formal_training_id', f.id, 'mentorship_id', f.mentorship_id, 'scheduled_at', f.scheduled_at),
       n.created_at
from (values
  (pg_temp.u('6281100000005'), '77000000-0000-0000-0000-000000000001'::uuid, 'formal_training_approved', 'Putu Sari Dewi approved your formal training', now() - interval '20 hours'),
  (pg_temp.u('6281100000004'), '77000000-0000-0000-0000-000000000001'::uuid, 'formal_training_scheduled', 'Formal training scheduled: Komang Adi Saputra with Putu Sari Dewi', now() - interval '20 hours'),
  (pg_temp.u('6281100000003'), '77000000-0000-0000-0000-000000000001'::uuid, 'formal_training_scheduled', 'Formal training scheduled: Komang Adi Saputra with Putu Sari Dewi', now() - interval '20 hours'),
  (pg_temp.u('6281100000002'), '77000000-0000-0000-0000-000000000001'::uuid, 'formal_training_scheduled', 'Formal training scheduled: Komang Adi Saputra with Putu Sari Dewi', now() - interval '20 hours'),
  (pg_temp.u('6281100000005'), '77000000-0000-0000-0000-000000000002'::uuid, 'formal_training_requested', 'Putu Sari Dewi requested a formal training', now() - interval '2 hours')
) as n(user_id, training_id, type, title, created_at)
join public.formal_trainings f on f.id = n.training_id;

-- Aksi: checklist templates ----------------------------------------------------
insert into public.checklist_templates (id, name, kind, brand_id, fail_issue_severity, fail_issue_sla_hours, created_at) values
  ('60000000-0000-0000-0000-000000000001', 'Opening checklist', 'routine', null, 'medium', 4, now() - interval '200 days'),
  ('60000000-0000-0000-0000-000000000002', 'Mid-shift floor check', 'routine', null, 'low', 2, now() - interval '200 days'),
  ('60000000-0000-0000-0000-000000000003', 'Closing checklist', 'routine', null, 'high', 12, now() - interval '200 days'),
  ('60000000-0000-0000-0000-000000000004', 'Fridge and freezer temperature log', 'routine', '10000000-0000-0000-0000-000000000001', 'high', 2, now() - interval '200 days'),
  ('60000000-0000-0000-0000-000000000005', 'Coffee machine cleaning', 'routine', '10000000-0000-0000-0000-000000000002', 'medium', 12, now() - interval '200 days'),
  ('60000000-0000-0000-0000-000000000006', 'Area manager visit', 'audit', null, 'medium', 48, now() - interval '200 days');
insert into public.checklist_template_versions (id, template_id, version, published_at, created_by) values
  ('61000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', 1, now() - interval '200 days', pg_temp.u('6281100000001')),
  ('61000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002', 1, now() - interval '200 days', pg_temp.u('6281100000001')),
  ('61000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000003', 1, now() - interval '200 days', pg_temp.u('6281100000001')),
  ('61000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000004', 1, now() - interval '200 days', pg_temp.u('6281100000001')),
  ('61000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000005', 1, now() - interval '200 days', pg_temp.u('6281100000001')),
  ('61000000-0000-0000-0000-000000000006', '60000000-0000-0000-0000-000000000006', 1, now() - interval '200 days', pg_temp.u('6281100000001'));
insert into public.checklist_items (template_version_id, sort, label, help_text, answer_type, photo_rule, min_value, max_value, unit, fail_on_no) values
  ('61000000-0000-0000-0000-000000000001', 1, 'Floor mopped and dry', null, 'yes_no', 'optional', null, null, null, true),
  ('61000000-0000-0000-0000-000000000001', 2, 'Toilets clean and stocked', 'Soap, tissue, hand towels', 'yes_no', 'required', null, null, null, true),
  ('61000000-0000-0000-0000-000000000001', 3, 'Display chiller temperature', null, 'number', 'none', 1, 5, '°C', true),
  ('61000000-0000-0000-0000-000000000001', 4, 'Hand soap and sanitiser refilled', null, 'yes_no', 'none', null, null, null, true),
  ('61000000-0000-0000-0000-000000000001', 5, 'Tables set and menus clean', null, 'yes_no', 'optional', null, null, null, true),
  ('61000000-0000-0000-0000-000000000002', 1, 'Tables wiped and reset', null, 'yes_no', 'none', null, null, null, true),
  ('61000000-0000-0000-0000-000000000002', 2, 'Toilets checked', null, 'yes_no', 'optional', null, null, null, true),
  ('61000000-0000-0000-0000-000000000002', 3, 'Floor dry, no spills', null, 'yes_no', 'none', null, null, null, true),
  ('61000000-0000-0000-0000-000000000003', 1, 'Gas valves off', null, 'yes_no', 'required', null, null, null, true),
  ('61000000-0000-0000-0000-000000000003', 2, 'Floor swept and mopped', null, 'yes_no', 'none', null, null, null, true),
  ('61000000-0000-0000-0000-000000000003', 3, 'Rubbish taken out', null, 'yes_no', 'none', null, null, null, true),
  ('61000000-0000-0000-0000-000000000003', 4, 'Cash in drawer', 'Count and enter the total', 'number', 'none', null, null, 'IDR', true),
  ('61000000-0000-0000-0000-000000000003', 5, 'Doors and windows locked', null, 'yes_no', 'required', null, null, null, true),
  ('61000000-0000-0000-0000-000000000004', 1, 'Chiller 1 temperature', null, 'number', 'none', 1, 5, '°C', true),
  ('61000000-0000-0000-0000-000000000004', 2, 'Chiller 2 temperature', null, 'number', 'none', 1, 5, '°C', true),
  ('61000000-0000-0000-0000-000000000004', 3, 'Freezer temperature', null, 'number', 'none', -22, -18, '°C', true),
  ('61000000-0000-0000-0000-000000000004', 4, 'FIFO labels on all containers', null, 'yes_no', 'required', null, null, null, true),
  ('61000000-0000-0000-0000-000000000005', 1, 'Group heads backflushed', null, 'yes_no', 'none', null, null, null, true),
  ('61000000-0000-0000-0000-000000000005', 2, 'Steam wands purged and wiped', null, 'yes_no', 'none', null, null, null, true),
  ('61000000-0000-0000-0000-000000000005', 3, 'Grinder hopper cleaned', null, 'yes_no', 'optional', null, null, null, true),
  ('61000000-0000-0000-0000-000000000006', 1, 'Opening checklist done on time this week', null, 'yes_no', 'none', null, null, null, true),
  ('61000000-0000-0000-0000-000000000006', 2, 'Kitchen floor and drains clean', null, 'yes_no', 'required', null, null, null, true),
  ('61000000-0000-0000-0000-000000000006', 3, 'Staff in full uniform', null, 'yes_no', 'optional', null, null, null, true),
  ('61000000-0000-0000-0000-000000000006', 4, 'Food labelled with dates', null, 'yes_no', 'required', null, null, null, true),
  ('61000000-0000-0000-0000-000000000006', 5, 'Guests greeted within 30 seconds', null, 'yes_no', 'none', null, null, null, true);
insert into public.checklist_template_positions (template_id, position_id)
select t, p from unnest(array['60000000-0000-0000-0000-000000000001','60000000-0000-0000-0000-000000000002','60000000-0000-0000-0000-000000000003']::uuid[]) t,
              unnest(array['50000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000002','50000000-0000-0000-0000-000000000003',
                           '50000000-0000-0000-0000-000000000008','50000000-0000-0000-0000-000000000009']::uuid[]) p
union all
select '60000000-0000-0000-0000-000000000004', unnest(array['50000000-0000-0000-0000-000000000005','50000000-0000-0000-0000-000000000006','50000000-0000-0000-0000-000000000007']::uuid[])
union all
select '60000000-0000-0000-0000-000000000005', unnest(array['50000000-0000-0000-0000-000000000008','50000000-0000-0000-0000-000000000009']::uuid[]);
insert into public.checklist_schedules (id, template_id, outlet_id, shift, due_time) values
  ('62000000-0000-0000-0000-000000000001', '60000000-0000-0000-0000-000000000001', null, 'opening', '09:00'),
  ('62000000-0000-0000-0000-000000000002', '60000000-0000-0000-0000-000000000002', null, 'mid',     '15:00'),
  ('62000000-0000-0000-0000-000000000003', '60000000-0000-0000-0000-000000000003', null, 'closing', '22:00'),
  ('62000000-0000-0000-0000-000000000004', '60000000-0000-0000-0000-000000000004', null, 'opening', '10:00'),
  ('62000000-0000-0000-0000-000000000005', '60000000-0000-0000-0000-000000000004', null, 'mid',     '16:00'),
  ('62000000-0000-0000-0000-000000000006', '60000000-0000-0000-0000-000000000005', null, 'closing', '21:00');

-- Four weeks of checklist history, issues from failed answers, and audit visits.
-- Seminyak, Sanur, Canggu, Renon and Kuta go from best to worst.
do $$
declare
  quality jsonb := '{"30000000-0000-0000-0000-000000000001": [0.95, 0.015],
                     "30000000-0000-0000-0000-000000000002": [0.86, 0.035],
                     "30000000-0000-0000-0000-000000000003": [0.70, 0.07],
                     "30000000-0000-0000-0000-000000000004": [0.92, 0.02],
                     "30000000-0000-0000-0000-000000000005": [0.82, 0.04]}';
  today date := (now() at time zone 'Asia/Makassar')::date;
  d int; day date; s record; o record; it record;
  due timestamptz; sub timestamptz; r float; q float; failp float;
  run_id uuid; resp_id uuid; who uuid; mgr uuid; fixer uuid;
  n_items int; n_failed int; st public.run_status;
  iss_id uuid; created timestamptz; fixed timestamptz; closed timestamptz; sla int;
begin
  perform setseed(0.42);
  for d in reverse 27..0 loop
    day := today - d;
    for s in
      select sc.id, sc.shift, sc.due_time, t.id template_id, t.brand_id, t.fail_issue_severity, t.fail_issue_sla_hours, v.id version_id
      from public.checklist_schedules sc
      join public.checklist_templates t on t.id = sc.template_id
      join public.checklist_template_versions v on v.template_id = t.id
    loop
      for o in select * from public.outlets where s.brand_id is null or brand_id = s.brand_id loop
        due := (day + s.due_time) at time zone o.timezone;
        continue when due > now() - interval '30 minutes';  -- today's open runs come from generate_checklist_runs
        q := (quality -> o.id::text ->> 0)::float;
        failp := (quality -> o.id::text ->> 1)::float;
        r := random();
        st := case when r < q + (1 - q) * 0.6 then 'submitted' else 'missed' end;
        sub := case when r < q then due - make_interval(mins => 5 + floor(random() * 50)::int)
                    else due + make_interval(mins => 10 + floor(random() * 80)::int) end;
        select p.id into who from public.profiles p
          where p.outlet_id = o.id and p.position_id in (select position_id from public.checklist_template_positions where template_id = s.template_id)
          order by random() limit 1;
        select ur.user_id into mgr from public.user_roles ur join public.roles ro on ro.id = ur.role_id
          where ro.name = 'Outlet manager' and ur.scope_id = o.id limit 1;
        who := coalesce(who, mgr);

        insert into public.checklist_runs (template_version_id, outlet_id, schedule_id, shift_date, shift, due_at, status,
                                           submitted_by, submitted_at, latitude, longitude, within_geofence, created_at)
        values (s.version_id, o.id, s.id, day, s.shift, due, st,
                case when st = 'submitted' then who end, case when st = 'submitted' then sub end,
                case when st = 'submitted' then o.latitude end, case when st = 'submitted' then o.longitude end,
                case when st = 'submitted' then true end, due - interval '10 hours')
        returning id into run_id;
        continue when st <> 'submitted';

        n_items := 0; n_failed := 0;
        for it in select * from public.checklist_items where template_version_id = s.version_id order by sort loop
          n_items := n_items + 1;
          r := random();
          insert into public.checklist_responses (run_id, item_id, value_bool, value_number, answered_by, answered_at)
          values (run_id, it.id,
                  case when it.answer_type = 'yes_no' then r >= failp end,
                  case when it.answer_type = 'number' then
                         case when it.unit = 'IDR' then 500000 + floor(random() * 30) * 50000
                              when r < failp then it.max_value + 1 + floor(random() * 3)
                              else round((it.min_value + random() * (it.max_value - it.min_value))::numeric, 1) end end,
                  who, sub - interval '3 minutes')
          returning id into resp_id;
          continue when (select passed from public.checklist_responses where id = resp_id);

          n_failed := n_failed + 1;
          -- One issue per failed answer, as submit_checklist_run does
          created := sub;
          sla := s.fail_issue_sla_hours;
          select p.id into fixer from public.profiles p
            where p.outlet_id = o.id and p.id <> mgr order by random() limit 1;
          insert into public.issues (outlet_id, source, run_id, response_id, title, severity, status, raised_by, assigned_to, due_at, created_at)
          values (o.id, 'checklist', run_id, resp_id, it.label, s.fail_issue_severity, 'open', who, fixer,
                  created + make_interval(hours => sla), created)
          returning id into iss_id;
          insert into public.issue_events (issue_id, actor_id, type, note, created_at) values
            (iss_id, who, 'created', 'Failed on ' || (select name from public.checklist_templates where id = s.template_id), created),
            (iss_id, mgr, 'assigned', null, created + interval '15 minutes');
          if d >= 2 then
            fixed := created + make_interval(mins => (30 + random() * sla * 90)::int);
            closed := fixed + make_interval(mins => (20 + random() * 300)::int);
            update public.issues set status = 'closed', fixed_by = fixer, fixed_at = fixed, closed_by = mgr, closed_at = closed,
                   escalated_at = case when fixed > due_at then due_at end
             where id = iss_id;
            insert into public.issue_events (issue_id, actor_id, type, note, created_at) values
              (iss_id, fixer, 'fixed', 'Done', fixed),
              (iss_id, mgr, 'accepted', null, closed);
            if fixed > created + make_interval(hours => sla) then
              insert into public.issue_events (issue_id, actor_id, type, created_at)
              values (iss_id, null, 'escalated', created + make_interval(hours => sla));
            end if;
          elsif now() > created + make_interval(hours => sla) then
            update public.issues set escalated_at = created + make_interval(hours => sla) where id = iss_id;
            insert into public.issue_events (issue_id, actor_id, type, created_at)
            values (iss_id, null, 'escalated', created + make_interval(hours => sla));
          end if;
        end loop;
        update public.checklist_runs set item_count = n_items, failed_count = n_failed,
               compliance_pct = round(100.0 * (n_items - n_failed) / n_items, 2)
         where id = run_id;
      end loop;
    end loop;
  end loop;

  -- Budi's audit visits
  for o in
    select x.id, x.latitude, x.longitude, v.days_ago
    from public.outlets x
    join (values ('30000000-0000-0000-0000-000000000001'::uuid, 6), ('30000000-0000-0000-0000-000000000002'::uuid, 10),
                 ('30000000-0000-0000-0000-000000000003'::uuid, 3), ('30000000-0000-0000-0000-000000000004'::uuid, 13),
                 ('30000000-0000-0000-0000-000000000005'::uuid, 17), ('30000000-0000-0000-0000-000000000001'::uuid, 20)) v(oid, days_ago)
      on v.oid = x.id
  loop
    sub := (((today - o.days_ago) + time '11:00') at time zone 'Asia/Makassar');
    failp := (quality -> o.id::text ->> 1)::float * 2.5;
    insert into public.checklist_runs (template_version_id, outlet_id, schedule_id, shift_date, shift, due_at, status,
                                       conducted_by, submitted_by, submitted_at, latitude, longitude, within_geofence, created_at)
    values ('61000000-0000-0000-0000-000000000006', o.id, null, today - o.days_ago, 'other', sub, 'submitted',
            pg_temp.u('6281100000003'), pg_temp.u('6281100000003'), sub, o.latitude, o.longitude, true, sub - interval '40 minutes')
    returning id into run_id;
    select ur.user_id into mgr from public.user_roles ur join public.roles ro on ro.id = ur.role_id
      where ro.name = 'Outlet manager' and ur.scope_id = o.id limit 1;
    n_items := 0; n_failed := 0;
    for it in select * from public.checklist_items where template_version_id = '61000000-0000-0000-0000-000000000006' order by sort loop
      n_items := n_items + 1;
      insert into public.checklist_responses (run_id, item_id, value_bool, answered_by, answered_at)
      values (run_id, it.id, random() >= failp, pg_temp.u('6281100000003'), sub - interval '5 minutes')
      returning id into resp_id;
      continue when (select passed from public.checklist_responses where id = resp_id);
      n_failed := n_failed + 1;
      insert into public.issues (outlet_id, source, run_id, response_id, title, severity, status, raised_by, assigned_to,
                                 due_at, fixed_by, fixed_at, closed_by, closed_at, created_at)
      values (o.id, 'audit', run_id, resp_id, it.label, 'medium', case when o.days_ago > 4 then 'closed' else 'open' end::public.issue_status,
              pg_temp.u('6281100000003'), mgr, sub + interval '48 hours',
              case when o.days_ago > 4 then mgr end, case when o.days_ago > 4 then sub + interval '20 hours' end,
              case when o.days_ago > 4 then pg_temp.u('6281100000003') end, case when o.days_ago > 4 then sub + interval '30 hours' end, sub)
      returning id into iss_id;
      insert into public.issue_events (issue_id, actor_id, type, note, created_at) values
        (iss_id, pg_temp.u('6281100000003'), 'created', 'Found on visit', sub),
        (iss_id, pg_temp.u('6281100000003'), 'assigned', null, sub + interval '1 minute');
      if o.days_ago > 4 then
        insert into public.issue_events (issue_id, actor_id, type, note, created_at) values
          (iss_id, mgr, 'fixed', 'Sorted with the team', sub + interval '20 hours'),
          (iss_id, pg_temp.u('6281100000003'), 'accepted', null, sub + interval '30 hours');
      end if;
    end loop;
    update public.checklist_runs set item_count = n_items, failed_count = n_failed,
           compliance_pct = round(100.0 * (n_items - n_failed) / n_items, 2)
     where id = run_id;
  end loop;
end $$;

-- Today's remaining runs (the nightly job does this from tomorrow)
select app.generate_checklist_runs();

-- Hand-written issues for the demo story at Seminyak --------------------------
insert into public.issues (id, outlet_id, source, title, description, severity, status, raised_by, assigned_to, due_at,
                           fixed_by, fixed_at, created_at) values
  ('76000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'manual',
   'Soap dispenser in the guest toilet is broken', 'The pump is stuck. Guests are using the staff toilet soap.', 'medium', 'open',
   pg_temp.u('6281100000101'), pg_temp.u('6281100000005'), now() + interval '3 hours', null, null, now() - interval '1 hour'),
  ('76000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000001', 'manual',
   'Chiller 2 door does not close properly', 'Reading was 7 °C this morning. Moved the dairy to chiller 1.', 'high', 'fixed',
   pg_temp.u('6281100000007'), pg_temp.u('6281100000007'), now() + interval '1 hour',
   pg_temp.u('6281100000007'), now() - interval '40 minutes', now() - interval '3 hours'),
  ('76000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000001', 'manual',
   'Wobbly chair at table 12', null, 'low', 'open',
   pg_temp.u('6281100000102'), null, now() + interval '20 hours', null, null, now() - interval '30 minutes');
insert into public.issue_events (issue_id, actor_id, type, note, created_at) values
  ('76000000-0000-0000-0000-000000000001', pg_temp.u('6281100000101'), 'created', null, now() - interval '1 hour'),
  ('76000000-0000-0000-0000-000000000001', pg_temp.u('6281100000004'), 'assigned', null, now() - interval '50 minutes'),
  ('76000000-0000-0000-0000-000000000002', pg_temp.u('6281100000007'), 'created', null, now() - interval '3 hours'),
  ('76000000-0000-0000-0000-000000000002', pg_temp.u('6281100000004'), 'assigned', null, now() - interval '170 minutes'),
  ('76000000-0000-0000-0000-000000000002', pg_temp.u('6281100000007'), 'fixed', 'Replaced the door seal, now reading 3 °C.', now() - interval '40 minutes'),
  ('76000000-0000-0000-0000-000000000003', pg_temp.u('6281100000102'), 'created', null, now() - interval '30 minutes');

-- Inbox -------------------------------------------------------------------------
insert into public.notifications (user_id, type, title, body, data, created_at) values
  (pg_temp.u('6281100000006'), 'mentor_assigned', 'Komang Adi Saputra is your mentor', 'Say hello on your next shift.', '{}', now() - interval '4 days'),
  (pg_temp.u('6281100000005'), 'issue_assigned', 'New issue for you', 'Soap dispenser in the guest toilet is broken',
   '{"issue_id": "76000000-0000-0000-0000-000000000001"}', now() - interval '50 minutes'),
  (pg_temp.u('6281100000004'), 'issue_fixed', 'Fix waiting for your check', 'Chiller 2 door does not close properly',
   '{"issue_id": "76000000-0000-0000-0000-000000000002"}', now() - interval '40 minutes');

-- The seed is not admin activity: start the audit log empty.
delete from public.admin_audit_log;
