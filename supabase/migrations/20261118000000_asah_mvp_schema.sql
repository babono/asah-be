-- =============================================================================
-- ASAH MVP database schema (Supabase / Postgres 15+)
-- Juta Berlian Culinary · iteration 1
--
-- Scope (matches the MVP PRD):
--   Foundation  : org structure (brands, areas, outlets, departments, positions,
--                 levels), users, fine-grained roles and permissions, settings,
--                 media references, notifications, admin audit log
--   Asuh        : learning modules (versioned), question bank, quizzes, practical
--                 tests with rubrics, learning paths, assignments, certificates,
--                 mentorship, check-ins, anonymous mentor ratings
--   Aksi        : checklist templates (versioned), schedules, runs, responses
--   Standar     : issues with SLA, escalation, verification; audits reuse
--                 checklist templates of kind 'audit'
--   Out of scope: product knowledge, promotion (Hebat), guest feedback
--
-- Security model (least privilege):
--   * Every table has RLS enabled. No policy = no access through the API.
--   * Access is granted through roles -> permissions, each role assignment
--     scoped to group, brand, area or outlet (table user_roles).
--   * Department / position / level describe a person's job; they never grant
--     access by themselves.
--   * State changes with business rules (quiz grading, checklist submission,
--     issue fix/verify, module review, ratings) go through SECURITY DEFINER
--     RPC functions that check permissions and separation of duties.
--   * Inactive users lose all access immediately.
-- =============================================================================

create extension if not exists pgcrypto;

-- Private schema for helper functions. Not exposed through the Data API.
create schema if not exists app;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
create type public.scope_type as enum ('group', 'brand', 'area', 'outlet');
create type public.user_status as enum ('active', 'inactive');
create type public.media_kind as enum (
  'training_video', 'training_document', 'training_image',
  'checklist_photo', 'issue_photo', 'practical_video');
create type public.media_status as enum ('uploading', 'processing', 'ready', 'failed');
create type public.module_version_status as enum (
  'draft', 'in_review', 'changes_requested', 'published', 'retired');
create type public.content_block_type as enum ('video', 'sop_card', 'document');
create type public.assignment_source as enum ('path', 'manual', 'refresher', 'retraining');
create type public.assignment_status as enum ('not_started', 'in_progress', 'completed');
create type public.practical_status as enum ('pending', 'passed', 'redo');
create type public.rubric_result as enum ('pass', 'redo');
create type public.mentorship_end_reason as enum (
  'path_completed', 'transferred', 'reassigned', 'left_company', 'other');
create type public.checklist_kind as enum ('routine', 'audit');
create type public.answer_type as enum ('yes_no', 'number', 'text', 'photo');
create type public.photo_rule as enum ('none', 'optional', 'required');
create type public.shift_type as enum ('opening', 'mid', 'closing', 'other');
create type public.run_status as enum ('pending', 'in_progress', 'submitted', 'missed');
create type public.issue_source as enum ('checklist', 'audit', 'manual');
create type public.issue_severity as enum ('low', 'medium', 'high');
create type public.issue_status as enum ('open', 'fixed', 'closed');
create type public.issue_event_type as enum (
  'created', 'assigned', 'fixed', 'accepted', 'reopened', 'escalated', 'commented');
create type public.device_platform as enum ('android', 'ios');

-- -----------------------------------------------------------------------------
-- Generic triggers
-- -----------------------------------------------------------------------------
create or replace function app.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- =============================================================================
-- 1. FOUNDATION: org structure
-- =============================================================================
create table public.brands (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.areas (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.outlets (
  id                 uuid primary key default gen_random_uuid(),
  brand_id           uuid not null references public.brands(id),
  area_id            uuid not null references public.areas(id),
  name               text not null,
  address            text,
  latitude           numeric(9, 6),
  longitude          numeric(9, 6),
  geofence_radius_m  integer not null default 150 check (geofence_radius_m between 10 and 5000),
  timezone           text not null default 'Asia/Makassar',  -- WIB/WITA/WIT per outlet
  archived_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (brand_id, name)
);
create index on public.outlets (area_id);

-- Department = career track (Kitchen, Service, Bar, Management)
create table public.departments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  sort_order  integer not null default 0,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Position = job title. Level = its step on the department's ladder (1 = entry).
-- All managed in the admin web (PRD F2).
create table public.positions (
  id            uuid primary key default gen_random_uuid(),
  department_id uuid not null references public.departments(id),
  name          text not null,
  level         smallint not null check (level > 0),
  archived_at   timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (department_id, name)
);
-- One active position per step of a ladder
create unique index positions_active_level_uq
  on public.positions (department_id, level) where archived_at is null;

-- =============================================================================
-- 2. FOUNDATION: users
-- =============================================================================
-- One row per auth.users row. Staff sign in with phone + OTP (PRD F5).
create table public.profiles (
  id             uuid primary key references auth.users(id) on delete cascade,
  full_name      text not null,
  phone          text unique,
  position_id    uuid references public.positions(id),
  outlet_id      uuid references public.outlets(id),
  hire_date      date,
  status         public.user_status not null default 'active',
  locale         text not null default 'id' check (locale in ('id', 'en')),
  deactivated_at timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index on public.profiles (outlet_id);
create index on public.profiles (position_id);

-- =============================================================================
-- 3. FOUNDATION: roles and permissions (PRD R1-R8)
-- =============================================================================
-- A permission = one action on one kind of record (e.g. 'issue.verify').
create table public.permissions (
  code         text primary key check (code ~ '^[a-z_]+\.[a-z_]+$'),
  description  text not null,
  is_sensitive boolean not null default false   -- every use is logged (R5)
);

-- A role = named bundle of permissions, editable in the admin web (R3).
create table public.roles (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  description text,
  is_system   boolean not null default false,   -- default roles seeded below
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.role_permissions (
  role_id         uuid not null references public.roles(id) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  primary key (role_id, permission_code)
);

-- A role is granted to a user within a scope (R2).
-- scope_type 'group' has no scope_id; others point to brands/areas/outlets.
create table public.user_roles (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  role_id    uuid not null references public.roles(id) on delete cascade,
  scope_type public.scope_type not null,
  scope_id   uuid,
  granted_by uuid references public.profiles(id),
  granted_at timestamptz not null default now(),
  expires_at timestamptz,
  check ((scope_type = 'group') = (scope_id is null))
);
create unique index user_roles_uq on public.user_roles
  (user_id, role_id, scope_type, coalesce(scope_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index on public.user_roles (user_id);

-- Validate scope_id against the right table (no polymorphic FK in Postgres)
create or replace function app.check_user_role_scope()
returns trigger language plpgsql as $$
begin
  if new.scope_type = 'brand' and not exists (select 1 from public.brands where id = new.scope_id) then
    raise exception 'scope_id % is not a brand', new.scope_id;
  elsif new.scope_type = 'area' and not exists (select 1 from public.areas where id = new.scope_id) then
    raise exception 'scope_id % is not an area', new.scope_id;
  elsif new.scope_type = 'outlet' and not exists (select 1 from public.outlets where id = new.scope_id) then
    raise exception 'scope_id % is not an outlet', new.scope_id;
  end if;
  return new;
end $$;
create trigger user_roles_scope_check before insert or update on public.user_roles
  for each row execute function app.check_user_role_scope();

-- =============================================================================
-- 4. FOUNDATION: settings, media, notifications, audit log
-- =============================================================================
create table public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

-- Files live in Supabase Storage (or any object storage); only the key is kept.
-- Signed URLs are generated at request time, never stored.
create table public.media_files (
  id               uuid primary key default gen_random_uuid(),
  bucket           text not null,
  object_key       text not null,
  kind             public.media_kind not null,
  mime_type        text,
  size_bytes       bigint check (size_bytes >= 0),
  duration_seconds integer check (duration_seconds >= 0),
  status           public.media_status not null default 'uploading',
  uploaded_by      uuid references public.profiles(id),
  outlet_id        uuid references public.outlets(id),  -- set for personal media (photos, test videos)
  created_at       timestamptz not null default now(),
  unique (bucket, object_key)
);

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  type       text not null,          -- e.g. 'module_assigned', 'issue_escalated'
  title      text not null,
  body       text,
  data       jsonb not null default '{}'::jsonb,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index on public.notifications (user_id, created_at desc);

-- FCM tokens for the Flutter app (Android and iOS)
create table public.device_tokens (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  token      text not null unique,
  platform   public.device_platform not null,
  updated_at timestamptz not null default now()
);

-- Every admin and permission change: who, what, when, before and after (F9)
create table public.admin_audit_log (
  id         bigint generated always as identity primary key,
  actor_id   uuid,
  action     text not null,       -- INSERT / UPDATE / DELETE / or an RPC name
  table_name text not null,
  record_id  text,
  before     jsonb,
  after      jsonb,
  created_at timestamptz not null default now()
);
create index on public.admin_audit_log (table_name, created_at desc);

-- =============================================================================
-- 5. ASUH: learning content
-- =============================================================================
-- Stable identity of a module; content lives in versions (PRD T5).
create table public.modules (
  id          uuid primary key default gen_random_uuid(),
  category    text not null,                 -- e.g. 'Service', 'Kitchen', 'Food safety'
  created_by  uuid references public.profiles(id),
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table public.module_versions (
  id                      uuid primary key default gen_random_uuid(),
  module_id               uuid not null references public.modules(id) on delete cascade,
  version                 integer not null check (version > 0),
  status                  public.module_version_status not null default 'draft',
  title                   text not null,
  summary                 text,
  prerequisite_module_id  uuid references public.modules(id),
  estimated_minutes       integer check (estimated_minutes > 0),
  certificate_valid_days  integer check (certificate_valid_days > 0),  -- null = no certificate
  requires_retraining     boolean not null default false,  -- reassign to people who finished the previous version
  author_id               uuid references public.profiles(id),
  submitted_at            timestamptz,
  reviewer_id             uuid references public.profiles(id),
  reviewed_at             timestamptz,
  review_comment          text,
  published_at            timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  unique (module_id, version),
  check (reviewer_id is null or reviewer_id <> author_id)   -- separation of duties (R7)
);
create unique index module_versions_one_published
  on public.module_versions (module_id) where status = 'published';

-- Which positions a module is meant for
create table public.module_target_positions (
  module_id   uuid not null references public.modules(id) on delete cascade,
  position_id uuid not null references public.positions(id),
  primary key (module_id, position_id)
);

create table public.content_blocks (
  id                uuid primary key default gen_random_uuid(),
  module_version_id uuid not null references public.module_versions(id) on delete cascade,
  sort              integer not null,
  type              public.content_block_type not null,
  title             text,
  body              text,                              -- SOP card text (markdown)
  media_file_id     uuid references public.media_files(id),
  unique (module_version_id, sort),
  check (type = 'sop_card' or media_file_id is not null)
);

-- Question bank, shared across modules
create table public.questions (
  id          uuid primary key default gen_random_uuid(),
  topic       text,
  prompt      text not null,
  explanation text,
  created_by  uuid references public.profiles(id),
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- is_correct is hidden from app users by a column grant (see GRANTS section)
create table public.question_options (
  id          uuid primary key default gen_random_uuid(),
  question_id uuid not null references public.questions(id) on delete cascade,
  label       text not null,
  is_correct  boolean not null default false,
  sort        integer not null default 0
);
create index on public.question_options (question_id);

create table public.quizzes (
  id                 uuid primary key default gen_random_uuid(),
  module_version_id  uuid not null unique references public.module_versions(id) on delete cascade,
  pass_mark_pct      integer not null default 80 check (pass_mark_pct between 0 and 100),
  max_attempts       integer check (max_attempts > 0),   -- null = unlimited
  time_limit_seconds integer check (time_limit_seconds > 0),
  question_count     integer check (question_count > 0), -- null = all linked questions
  randomize          boolean not null default true
);

create table public.quiz_questions (
  quiz_id     uuid not null references public.quizzes(id) on delete cascade,
  question_id uuid not null references public.questions(id),
  sort        integer not null default 0,
  primary key (quiz_id, question_id)
);

-- Practical test rubric (PRD T3). No rows = module has no practical test.
create table public.rubric_criteria (
  id                uuid primary key default gen_random_uuid(),
  module_version_id uuid not null references public.module_versions(id) on delete cascade,
  title             text not null,
  description       text,
  sort              integer not null default 0
);
create index on public.rubric_criteria (module_version_id);

-- =============================================================================
-- 6. ASUH: learning paths and progress
-- =============================================================================
-- One active path per position (PRD T6)
create table public.learning_paths (
  id          uuid primary key default gen_random_uuid(),
  position_id uuid not null references public.positions(id),
  name        text not null,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index learning_paths_one_active
  on public.learning_paths (position_id) where archived_at is null;

create table public.learning_path_items (
  id           uuid primary key default gen_random_uuid(),
  path_id      uuid not null references public.learning_paths(id) on delete cascade,
  module_id    uuid not null references public.modules(id),
  sort         integer not null,
  is_mandatory boolean not null default true,
  due_days     integer not null default 30 check (due_days >= 0),  -- 1 = day 1, 7 = week 1, 30 = month 1
  unique (path_id, module_id)
);

create table public.module_assignments (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles(id) on delete cascade,
  module_id         uuid not null references public.modules(id),
  module_version_id uuid not null references public.module_versions(id),
  source            public.assignment_source not null,
  path_id           uuid references public.learning_paths(id),
  assigned_by       uuid references public.profiles(id),
  assigned_at       timestamptz not null default now(),
  due_at            timestamptz,
  status            public.assignment_status not null default 'not_started',
  started_at        timestamptz,
  completed_at      timestamptz,
  check ((status = 'completed') = (completed_at is not null))
);
create unique index module_assignments_one_open
  on public.module_assignments (user_id, module_id) where completed_at is null;
create index on public.module_assignments (user_id, status);

create table public.block_progress (
  assignment_id uuid not null references public.module_assignments(id) on delete cascade,
  block_id      uuid not null references public.content_blocks(id),
  completed_at  timestamptz not null default now(),
  primary key (assignment_id, block_id)
);

create table public.quiz_attempts (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.module_assignments(id) on delete cascade,
  quiz_id       uuid not null references public.quizzes(id),
  user_id       uuid not null references public.profiles(id),
  question_ids  uuid[] not null,                -- questions served in this attempt
  started_at    timestamptz not null default now(),
  submitted_at  timestamptz,
  score_pct     numeric(5, 2),
  passed        boolean
);
create index on public.quiz_attempts (assignment_id);

create table public.quiz_attempt_answers (
  attempt_id  uuid not null references public.quiz_attempts(id) on delete cascade,
  question_id uuid not null references public.questions(id),
  option_id   uuid references public.question_options(id),
  is_correct  boolean not null,
  primary key (attempt_id, question_id)
);

create table public.practical_submissions (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.module_assignments(id) on delete cascade,
  user_id       uuid not null references public.profiles(id),
  media_file_id uuid not null references public.media_files(id),
  submitted_at  timestamptz not null default now(),
  status        public.practical_status not null default 'pending',
  scored_by     uuid references public.profiles(id),
  scored_at     timestamptz,
  feedback      text,
  check (scored_by is null or scored_by <> user_id)
);
create index on public.practical_submissions (assignment_id);

create table public.practical_scores (
  submission_id uuid not null references public.practical_submissions(id) on delete cascade,
  criterion_id  uuid not null references public.rubric_criteria(id),
  result        public.rubric_result not null,
  note          text,
  primary key (submission_id, criterion_id)
);

-- Outlet manager spot-checks a sample of mentor sign-offs (PRD M6)
create table public.practical_spot_checks (
  id            uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.practical_submissions(id) on delete cascade,
  checked_by    uuid not null references public.profiles(id),
  agrees        boolean not null,
  note          text,
  checked_at    timestamptz not null default now()
);

create table public.certificates (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles(id) on delete cascade,
  module_id         uuid not null references public.modules(id),
  module_version_id uuid not null references public.module_versions(id),
  assignment_id     uuid references public.module_assignments(id),
  issued_at         timestamptz not null default now(),
  expires_at        timestamptz
);
create index on public.certificates (user_id);
create index on public.certificates (expires_at);

-- =============================================================================
-- 7. ASUH: mentorship
-- =============================================================================
create table public.mentorships (
  id          uuid primary key default gen_random_uuid(),
  mentor_id   uuid not null references public.profiles(id),
  trainee_id  uuid not null references public.profiles(id),
  outlet_id   uuid not null references public.outlets(id),
  assigned_by uuid references public.profiles(id),
  started_at  timestamptz not null default now(),
  ended_at    timestamptz,
  end_reason  public.mentorship_end_reason,
  check (mentor_id <> trainee_id),
  check ((ended_at is null) = (end_reason is null))
);
create unique index mentorships_one_active_per_trainee
  on public.mentorships (trainee_id) where ended_at is null;
create index on public.mentorships (mentor_id) where ended_at is null;

create table public.mentor_checkins (
  id            uuid primary key default gen_random_uuid(),
  mentorship_id uuid not null references public.mentorships(id) on delete cascade,
  week_of       date not null,
  feedback      text not null,
  goals         text,
  created_by    uuid not null references public.profiles(id),
  created_at    timestamptz not null default now(),
  unique (mentorship_id, week_of)
);

-- Anonymous to the mentor (PRD M7). No SELECT policy exists on this table:
-- mentors read an average through my_mentor_rating(); HR reads raters through
-- mentor_ratings_with_raters(), which logs every view.
create table public.mentor_ratings (
  id            uuid primary key default gen_random_uuid(),
  mentorship_id uuid not null unique references public.mentorships(id),
  mentor_id     uuid not null references public.profiles(id),
  rater_id      uuid not null references public.profiles(id),
  score         smallint not null check (score between 1 and 5),
  comment       text,
  created_at    timestamptz not null default now()
);
create index on public.mentor_ratings (mentor_id);

create table public.mentor_rating_access_log (
  id         bigint generated always as identity primary key,
  viewer_id  uuid not null references public.profiles(id),
  mentor_id  uuid not null references public.profiles(id),
  viewed_at  timestamptz not null default now()
);

-- =============================================================================
-- 8. AKSI: checklist templates and runs
-- =============================================================================
create table public.checklist_templates (
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null,
  kind                 public.checklist_kind not null default 'routine',  -- 'audit' = area manager visit
  brand_id             uuid references public.brands(id),                 -- null = all brands
  fail_issue_severity  public.issue_severity not null default 'medium',
  fail_issue_sla_hours integer not null default 4 check (fail_issue_sla_hours > 0),
  created_by           uuid references public.profiles(id),
  archived_at          timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table public.checklist_template_versions (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references public.checklist_templates(id) on delete cascade,
  version      integer not null check (version > 0),
  published_at timestamptz,             -- null = draft
  created_by   uuid references public.profiles(id),
  created_at   timestamptz not null default now(),
  unique (template_id, version)
);

create table public.checklist_items (
  id                  uuid primary key default gen_random_uuid(),
  template_version_id uuid not null references public.checklist_template_versions(id) on delete cascade,
  sort                integer not null,
  label               text not null,
  help_text           text,
  answer_type         public.answer_type not null,
  photo_rule          public.photo_rule not null default 'none',
  min_value           numeric,     -- for 'number', e.g. chiller 1 to 5
  max_value           numeric,
  unit                text,        -- e.g. '°C'
  fail_on_no          boolean not null default true,   -- for 'yes_no'
  unique (template_version_id, sort),
  check (min_value is null or max_value is null or min_value <= max_value)
);

-- Which positions fill this checklist
create table public.checklist_template_positions (
  template_id uuid not null references public.checklist_templates(id) on delete cascade,
  position_id uuid not null references public.positions(id),
  primary key (template_id, position_id)
);

-- When runs are generated. outlet_id null = every outlet of the template's brand
-- (or every outlet if the template has no brand).
create table public.checklist_schedules (
  id           uuid primary key default gen_random_uuid(),
  template_id  uuid not null references public.checklist_templates(id) on delete cascade,
  outlet_id    uuid references public.outlets(id),
  shift        public.shift_type not null,
  due_time     time not null,                                 -- outlet local time
  days_of_week smallint[] not null default '{1,2,3,4,5,6,7}', -- ISO: 1 = Monday
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.checklist_runs (
  id                  uuid primary key default gen_random_uuid(),
  template_version_id uuid not null references public.checklist_template_versions(id),
  outlet_id           uuid not null references public.outlets(id),
  schedule_id         uuid references public.checklist_schedules(id),  -- null for ad-hoc audits
  shift_date          date not null,
  shift               public.shift_type not null,
  due_at              timestamptz not null,
  status              public.run_status not null default 'pending',
  conducted_by        uuid references public.profiles(id),   -- audits: the area manager
  submitted_by        uuid references public.profiles(id),
  submitted_at        timestamptz,                           -- server time
  latitude            numeric(9, 6),
  longitude           numeric(9, 6),
  within_geofence     boolean,
  item_count          integer,
  failed_count        integer,
  compliance_pct      numeric(5, 2),
  created_at          timestamptz not null default now(),
  unique (schedule_id, outlet_id, shift_date)
);
create index on public.checklist_runs (outlet_id, shift_date);
create index on public.checklist_runs (status, due_at);

create table public.checklist_responses (
  id            uuid primary key default gen_random_uuid(),
  run_id        uuid not null references public.checklist_runs(id) on delete cascade,
  item_id       uuid not null references public.checklist_items(id),
  value_bool    boolean,
  value_number  numeric,
  value_text    text,
  passed        boolean not null default true,   -- computed by trigger
  answered_by   uuid not null references public.profiles(id),
  answered_at   timestamptz not null default now(),
  unique (run_id, item_id)
);

create table public.checklist_response_photos (
  response_id   uuid not null references public.checklist_responses(id) on delete cascade,
  media_file_id uuid not null references public.media_files(id),
  primary key (response_id, media_file_id)
);

-- =============================================================================
-- 9. STANDAR: issues
-- =============================================================================
create table public.issues (
  id           uuid primary key default gen_random_uuid(),
  outlet_id    uuid not null references public.outlets(id),
  source       public.issue_source not null,
  run_id       uuid references public.checklist_runs(id),
  response_id  uuid references public.checklist_responses(id),
  title        text not null,
  description  text,
  severity     public.issue_severity not null default 'medium',
  status       public.issue_status not null default 'open',
  raised_by    uuid references public.profiles(id),   -- null when raised by the system
  assigned_to  uuid references public.profiles(id),
  due_at       timestamptz not null,
  fixed_by     uuid references public.profiles(id),
  fixed_at     timestamptz,
  closed_by    uuid references public.profiles(id),
  closed_at    timestamptz,
  escalated_at timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (closed_by is null or closed_by is distinct from fixed_by)   -- separation of duties (R7)
);
create index on public.issues (outlet_id, status);
create index on public.issues (assigned_to) where status <> 'closed';
create index on public.issues (due_at) where status = 'open';

create table public.issue_events (
  id            uuid primary key default gen_random_uuid(),
  issue_id      uuid not null references public.issues(id) on delete cascade,
  actor_id      uuid references public.profiles(id),
  type          public.issue_event_type not null,
  note          text,
  media_file_id uuid references public.media_files(id),
  created_at    timestamptz not null default now()
);
create index on public.issue_events (issue_id, created_at);

-- updated_at triggers
do $$
declare t text;
begin
  foreach t in array array[
    'brands','areas','outlets','departments','positions','profiles','roles',
    'modules','module_versions','questions','learning_paths',
    'checklist_templates','checklist_schedules','issues']
  loop
    execute format(
      'create trigger %I_updated_at before update on public.%I
         for each row execute function app.set_updated_at()', t, t);
  end loop;
end $$;

-- =============================================================================
-- 10. ACCESS HELPERS (schema app, SECURITY DEFINER, used by RLS and RPCs)
-- =============================================================================
create or replace function app.is_active_user()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and status = 'active');
$$;

-- Does the caller hold permission p for an outlet? p_outlet null = needs group scope.
create or replace function app.has_permission(p_perm text, p_outlet uuid default null)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.role_permissions rp on rp.role_id = ur.role_id
    join public.profiles me on me.id = ur.user_id and me.status = 'active'
    left join public.outlets o on o.id = p_outlet
    where ur.user_id = (select auth.uid())
      and rp.permission_code = p_perm
      and (ur.expires_at is null or ur.expires_at > now())
      and (
        ur.scope_type = 'group'
        or (p_outlet is not null and (
              (ur.scope_type = 'brand'  and ur.scope_id = o.brand_id)
           or (ur.scope_type = 'area'   and ur.scope_id = o.area_id)
           or (ur.scope_type = 'outlet' and ur.scope_id = o.id)))
      ));
$$;

-- Does the caller hold permission p in any scope? (for group-wide reference data
-- such as published modules that staff at any outlet may read)
create or replace function app.has_permission_any(p_perm text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.user_roles ur
    join public.role_permissions rp on rp.role_id = ur.role_id
    join public.profiles me on me.id = ur.user_id and me.status = 'active'
    where ur.user_id = (select auth.uid())
      and rp.permission_code = p_perm
      and (ur.expires_at is null or ur.expires_at > now()));
$$;

-- Active users who hold permission p for an outlet (for notifications)
create or replace function app.users_with_permission(p_perm text, p_outlet uuid)
returns setof uuid language sql stable security definer set search_path = '' as $$
  select distinct ur.user_id
  from public.user_roles ur
  join public.role_permissions rp on rp.role_id = ur.role_id
  join public.profiles p on p.id = ur.user_id and p.status = 'active'
  join public.outlets o on o.id = p_outlet
  where rp.permission_code = p_perm
    and (ur.expires_at is null or ur.expires_at > now())
    and (ur.scope_type = 'group'
      or (ur.scope_type = 'brand'  and ur.scope_id = o.brand_id)
      or (ur.scope_type = 'area'   and ur.scope_id = o.area_id)
      or (ur.scope_type = 'outlet' and ur.scope_id = o.id));
$$;

create or replace function app.user_outlet(p_user uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select outlet_id from public.profiles where id = p_user;
$$;

-- Caller is the active mentor of p_trainee
create or replace function app.is_mentor_of(p_trainee uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.mentorships m
    join public.profiles me on me.id = m.mentor_id and me.status = 'active'
    where m.mentor_id = (select auth.uid())
      and m.trainee_id = p_trainee
      and m.ended_at is null);
$$;

-- Caller may see this person's training records
create or replace function app.can_view_training_of(p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app.is_active_user() and (
       p_user = (select auth.uid())
    or app.is_mentor_of(p_user)
    or app.has_permission('training.view', app.user_outlet(p_user)));
$$;

-- Caller may fill this checklist run: right outlet, right position, permission
create or replace function app.can_fill_run(p_run uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
    from public.checklist_runs r
    join public.checklist_template_versions v on v.id = r.template_version_id
    join public.checklist_templates t on t.id = v.template_id
    join public.profiles me on me.id = (select auth.uid()) and me.status = 'active'
    where r.id = p_run
      and r.status in ('pending', 'in_progress')
      and (
        (t.kind = 'routine'
          and me.outlet_id = r.outlet_id
          and app.has_permission('checklist.fill', r.outlet_id)
          and exists (select 1 from public.checklist_template_positions tp
                      where tp.template_id = t.id and tp.position_id = me.position_id))
        or (t.kind = 'audit'
          and r.conducted_by = me.id
          and app.has_permission('audit.conduct', r.outlet_id))
      ));
$$;

create or replace function app.notify(p_user uuid, p_type text, p_title text,
                                      p_body text default null, p_data jsonb default '{}'::jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.notifications (user_id, type, title, body, data)
  values (p_user, p_type, p_title, p_body, p_data);
$$;

create or replace function app.setting(p_key text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select value from public.app_settings where key = p_key;
$$;

-- Great-circle distance in metres (no PostGIS needed)
create or replace function app.distance_m(lat1 numeric, lon1 numeric, lat2 numeric, lon2 numeric)
returns double precision language sql immutable as $$
  select 6371000 * 2 * asin(sqrt(
      power(sin(radians((lat2 - lat1)::float8) / 2), 2)
    + cos(radians(lat1::float8)) * cos(radians(lat2::float8))
    * power(sin(radians((lon2 - lon1)::float8) / 2), 2)));
$$;

-- =============================================================================
-- 11. BUSINESS TRIGGERS
-- =============================================================================

-- Admin audit log (F9) on setup and permission tables
create or replace function app.log_admin_change()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  rec_id text;
begin
  rec_id := coalesce(
    case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end ->> 'id',
    case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end ->> 'key',
    case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end ->> 'role_id');
  insert into public.admin_audit_log (actor_id, action, table_name, record_id, before, after)
  values ((select auth.uid()), tg_op, tg_table_name, rec_id,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array[
    'brands','areas','outlets','departments','positions','profiles',
    'roles','role_permissions','user_roles','app_settings',
    'learning_paths','learning_path_items','checklist_templates','checklist_schedules']
  loop
    execute format(
      'create trigger %I_audit after insert or update or delete on public.%I
         for each row execute function app.log_admin_change()', t, t);
  end loop;
end $$;

-- Archiving a position is blocked while staff or content still use it (F2)
create or replace function app.block_position_archive()
returns trigger language plpgsql as $$
begin
  if new.archived_at is not null and old.archived_at is null then
    if exists (select 1 from public.profiles where position_id = new.id and status = 'active') then
      raise exception 'Position % still has active staff; move them first', new.name;
    end if;
    if exists (select 1 from public.learning_paths where position_id = new.id and archived_at is null)
       or exists (select 1 from public.checklist_template_positions tp
                  join public.checklist_templates t on t.id = tp.template_id and t.archived_at is null
                  where tp.position_id = new.id) then
      raise exception 'Position % still has a learning path or checklist; move them first', new.name;
    end if;
  end if;
  return new;
end $$;
create trigger positions_block_archive before update on public.positions
  for each row execute function app.block_position_archive();

-- Deactivating a user ends their access, mentorships and open assignments (R8)
create or replace function app.on_profile_deactivated()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'inactive' and old.status = 'active' then
    new.deactivated_at := now();
    delete from public.user_roles where user_id = new.id;
    update public.mentorships set ended_at = now(), end_reason = 'left_company'
      where ended_at is null and (mentor_id = new.id or trainee_id = new.id);
  end if;
  return new;
end $$;
create trigger profiles_deactivate before update of status on public.profiles
  for each row execute function app.on_profile_deactivated();

-- Assign the learning path of the user's position (T7)
create or replace function app.sync_user_path(p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  me public.profiles%rowtype;
begin
  select * into me from public.profiles where id = p_user;
  if me.position_id is null or me.status <> 'active' then return; end if;

  insert into public.module_assignments
    (user_id, module_id, module_version_id, source, path_id, due_at)
  select me.id, i.module_id, mv.id, 'path', lp.id, now() + make_interval(days => i.due_days)
  from public.learning_paths lp
  join public.learning_path_items i on i.path_id = lp.id
  join public.module_versions mv on mv.module_id = i.module_id and mv.status = 'published'
  where lp.position_id = me.position_id and lp.archived_at is null
    and not exists (select 1 from public.module_assignments a
                    where a.user_id = me.id and a.module_id = i.module_id);

  if found then
    perform app.notify(me.id, 'module_assigned', 'New modules in your learning path');
  end if;
end $$;

create or replace function app.on_profile_position()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' or new.position_id is distinct from old.position_id then
    perform app.sync_user_path(new.id);
  end if;
  if tg_op = 'UPDATE' and new.outlet_id is distinct from old.outlet_id then
    update public.mentorships set ended_at = now(), end_reason = 'transferred'
      where ended_at is null and (mentor_id = new.id or trainee_id = new.id);
  end if;
  return new;
end $$;
create trigger profiles_position_path after insert or update of position_id, outlet_id
  on public.profiles for each row execute function app.on_profile_position();

-- A module added to a path is assigned to everyone in that position
create or replace function app.on_path_item_added()
returns trigger language plpgsql security definer set search_path = '' as $$
declare u uuid;
begin
  for u in
    select p.id from public.profiles p
    join public.learning_paths lp on lp.position_id = p.position_id
    where lp.id = new.path_id and p.status = 'active'
  loop
    perform app.sync_user_path(u);
  end loop;
  return new;
end $$;
create trigger learning_path_items_assign after insert on public.learning_path_items
  for each row execute function app.on_path_item_added();

-- Compute pass/fail for every checklist answer
create or replace function app.compute_response_passed()
returns trigger language plpgsql security definer set search_path = '' as $$
declare it public.checklist_items%rowtype;
begin
  select * into it from public.checklist_items where id = new.item_id;
  new.passed := case it.answer_type
    when 'yes_no' then not (it.fail_on_no and new.value_bool is false)
    when 'number' then new.value_number is not null
                       and (it.min_value is null or new.value_number >= it.min_value)
                       and (it.max_value is null or new.value_number <= it.max_value)
    else true end;
  return new;
end $$;
create trigger checklist_responses_passed before insert or update on public.checklist_responses
  for each row execute function app.compute_response_passed();

-- Completing an assignment: all blocks done, quiz passed, practical passed
create or replace function app.try_complete_assignment(p_assignment uuid)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  a  public.module_assignments%rowtype;
  mv public.module_versions%rowtype;
  q_id uuid;
begin
  select * into a from public.module_assignments where id = p_assignment for update;
  if a.status = 'completed' then return true; end if;
  select * into mv from public.module_versions where id = a.module_version_id;

  if exists (select 1 from public.content_blocks b
             where b.module_version_id = mv.id
               and not exists (select 1 from public.block_progress bp
                               where bp.assignment_id = a.id and bp.block_id = b.id)) then
    return false;
  end if;

  select id into q_id from public.quizzes where module_version_id = mv.id;
  if q_id is not null and not exists (
      select 1 from public.quiz_attempts where assignment_id = a.id and passed) then
    return false;
  end if;

  if exists (select 1 from public.rubric_criteria where module_version_id = mv.id)
     and not exists (select 1 from public.practical_submissions
                     where assignment_id = a.id and status = 'passed') then
    return false;
  end if;

  update public.module_assignments
     set status = 'completed', completed_at = now()
   where id = a.id;

  if mv.certificate_valid_days is not null then
    insert into public.certificates (user_id, module_id, module_version_id, assignment_id, expires_at)
    values (a.user_id, a.module_id, mv.id, a.id, now() + make_interval(days => mv.certificate_valid_days));
  end if;
  return true;
end $$;

-- =============================================================================
-- 12. RPC FUNCTIONS (called from the Flutter app and admin web via supabase.rpc)
-- =============================================================================

-- What can I do, and where? Lets the app show only allowed actions (R6:
-- the server still checks every action).
create or replace function public.my_permissions()
returns table (permission_code text, scope_type public.scope_type, scope_id uuid)
language sql stable security definer set search_path = '' as $$
  select distinct rp.permission_code, ur.scope_type, ur.scope_id
  from public.user_roles ur
  join public.role_permissions rp on rp.role_id = ur.role_id
  where ur.user_id = (select auth.uid())
    and app.is_active_user()
    and (ur.expires_at is null or ur.expires_at > now());
$$;

-- ---------- Learning: module review and publishing (T4, T5, R7) ----------
create or replace function public.submit_module_for_review(p_version uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_permission('module.author') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.module_versions
     set status = 'in_review', submitted_at = now()
   where id = p_version and status in ('draft', 'changes_requested');
  if not found then raise exception 'version is not a draft'; end if;
end $$;

create or replace function public.review_module_version(p_version uuid, p_approve boolean, p_comment text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  mv public.module_versions%rowtype;
  me uuid := (select auth.uid());
  u  uuid;
begin
  if not app.has_permission('module.review') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into mv from public.module_versions where id = p_version for update;
  if mv.status <> 'in_review' then raise exception 'version is not in review'; end if;
  if mv.author_id = me then
    raise exception 'authors cannot approve their own module' using errcode = '42501';
  end if;

  if not p_approve then
    update public.module_versions
       set status = 'changes_requested', reviewer_id = me, reviewed_at = now(), review_comment = p_comment
     where id = mv.id;
    perform app.notify(mv.author_id, 'module_changes_requested', 'Changes requested: ' || mv.title, p_comment);
    return;
  end if;

  update public.module_versions set status = 'retired'
   where module_id = mv.module_id and status = 'published';
  update public.module_versions
     set status = 'published', reviewer_id = me, reviewed_at = now(),
         review_comment = p_comment, published_at = now()
   where id = mv.id;

  -- Open assignments move to the new version
  update public.module_assignments
     set module_version_id = mv.id
   where module_id = mv.module_id and completed_at is null;

  -- Retraining: reassign to people who finished an older version
  if mv.requires_retraining then
    for u in
      select distinct a.user_id from public.module_assignments a
      join public.profiles p on p.id = a.user_id and p.status = 'active'
      where a.module_id = mv.module_id and a.completed_at is not null
        and not exists (select 1 from public.module_assignments o
                        where o.user_id = a.user_id and o.module_id = mv.module_id
                          and o.completed_at is null)
    loop
      insert into public.module_assignments (user_id, module_id, module_version_id, source, assigned_by, due_at)
      values (u, mv.module_id, mv.id, 'retraining', me, now() + interval '14 days');
      perform app.notify(u, 'module_assigned', 'Updated module: ' || mv.title);
    end loop;
  end if;
end $$;

-- ---------- Learning: taking a module (T10, T2) ----------
create or replace function public.complete_block(p_assignment uuid, p_block uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare a public.module_assignments%rowtype;
begin
  select * into a from public.module_assignments where id = p_assignment;
  if a.user_id is distinct from (select auth.uid()) or not app.has_permission_any('learning.take') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.content_blocks
                 where id = p_block and module_version_id = a.module_version_id) then
    raise exception 'block does not belong to this module';
  end if;
  insert into public.block_progress (assignment_id, block_id) values (a.id, p_block)
    on conflict do nothing;
  update public.module_assignments
     set status = 'in_progress', started_at = coalesce(started_at, now())
   where id = a.id and status = 'not_started';
  perform app.try_complete_assignment(a.id);
end $$;

-- Starts a quiz attempt and returns the questions WITHOUT correct answers
create or replace function public.start_quiz_attempt(p_assignment uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  a    public.module_assignments%rowtype;
  qz   public.quizzes%rowtype;
  qids uuid[];
  att  uuid;
  used integer;
begin
  select * into a from public.module_assignments where id = p_assignment;
  if a.user_id is distinct from (select auth.uid()) or not app.has_permission_any('learning.take') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into qz from public.quizzes where module_version_id = a.module_version_id;
  if qz.id is null then raise exception 'this module has no quiz'; end if;

  select count(*) into used from public.quiz_attempts where assignment_id = a.id;
  if qz.max_attempts is not null and used >= qz.max_attempts then
    raise exception 'no attempts left; ask your mentor for a refresher';
  end if;

  select array_agg(question_id) into qids from (
    select qq.question_id from public.quiz_questions qq
    where qq.quiz_id = qz.id
    order by case when qz.randomize then random() else qq.sort end
    limit coalesce(qz.question_count, 1000)) s;

  insert into public.quiz_attempts (assignment_id, quiz_id, user_id, question_ids)
  values (a.id, qz.id, a.user_id, qids) returning id into att;

  return jsonb_build_object(
    'attempt_id', att,
    'time_limit_seconds', qz.time_limit_seconds,
    'questions', (
      select jsonb_agg(jsonb_build_object(
               'id', q.id, 'prompt', q.prompt,
               'options', (select jsonb_agg(jsonb_build_object('id', o.id, 'label', o.label)
                                            order by case when qz.randomize then random() else o.sort end)
                           from public.question_options o where o.question_id = q.id))
             order by array_position(qids, q.id))
      from public.questions q where q.id = any(qids)));
end $$;

-- p_answers: {"<question_id>": "<option_id>", ...}
create or replace function public.submit_quiz_attempt(p_attempt uuid, p_answers jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  att      public.quiz_attempts%rowtype;
  qz       public.quizzes%rowtype;
  total    integer;
  correct  integer;
  pct      numeric;
  did_pass boolean;
  fails    integer;
  mentor   uuid;
begin
  select * into att from public.quiz_attempts where id = p_attempt for update;
  if att.user_id is distinct from (select auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if att.submitted_at is not null then raise exception 'already submitted'; end if;
  select * into qz from public.quizzes where id = att.quiz_id;
  if qz.time_limit_seconds is not null
     and now() > att.started_at + make_interval(secs => qz.time_limit_seconds + 30) then
    raise exception 'time is up';
  end if;

  insert into public.quiz_attempt_answers (attempt_id, question_id, option_id, is_correct)
  select att.id, q, (p_answers ->> q::text)::uuid,
         coalesce((select o.is_correct from public.question_options o
                   where o.id = (p_answers ->> q::text)::uuid and o.question_id = q), false)
  from unnest(att.question_ids) q;

  total   := coalesce(array_length(att.question_ids, 1), 0);
  select count(*) into correct from public.quiz_attempt_answers where attempt_id = att.id and is_correct;
  pct      := case when total = 0 then 100 else round(correct * 100.0 / total, 2) end;
  did_pass := pct >= qz.pass_mark_pct;

  update public.quiz_attempts set submitted_at = now(), score_pct = pct, passed = did_pass
   where id = att.id;
  update public.module_assignments
     set status = 'in_progress', started_at = coalesce(started_at, now())
   where id = att.assignment_id and status = 'not_started';

  if did_pass then
    perform app.try_complete_assignment(att.assignment_id);
  else
    -- Second failure alerts the mentor (M4)
    select count(*) into fails from public.quiz_attempts
     where assignment_id = att.assignment_id and passed = false;
    if fails >= 2 then
      select mentor_id into mentor from public.mentorships
       where trainee_id = att.user_id and ended_at is null;
      if mentor is not null then
        perform app.notify(mentor, 'trainee_failed_quiz', 'Your trainee failed a quiz twice',
                           null, jsonb_build_object('assignment_id', att.assignment_id));
      end if;
    end if;
  end if;

  return jsonb_build_object('score_pct', pct, 'passed', did_pass);
end $$;

-- ---------- Learning: practical test (T3, M2) ----------
create or replace function public.submit_practical(p_assignment uuid, p_media uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  a      public.module_assignments%rowtype;
  sub_id uuid;
  mentor uuid;
begin
  select * into a from public.module_assignments where id = p_assignment;
  if a.user_id is distinct from (select auth.uid()) or not app.has_permission_any('learning.take') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.media_files
                 where id = p_media and uploaded_by = a.user_id and kind = 'practical_video') then
    raise exception 'video not found';
  end if;
  insert into public.practical_submissions (assignment_id, user_id, media_file_id)
  values (a.id, a.user_id, p_media) returning id into sub_id;

  select mentor_id into mentor from public.mentorships
   where trainee_id = a.user_id and ended_at is null;
  if mentor is not null then
    perform app.notify(mentor, 'practical_to_score', 'A practical test is waiting for you',
                       null, jsonb_build_object('submission_id', sub_id));
  end if;
  return sub_id;
end $$;

-- p_scores: [{"criterion_id": "...", "result": "pass"|"redo", "note": "..."}]
create or replace function public.score_practical(p_submission uuid, p_scores jsonb, p_feedback text default null)
returns public.practical_status language plpgsql security definer set search_path = '' as $$
declare
  s       public.practical_submissions%rowtype;
  mv_id   uuid;
  missing integer;
  outcome public.practical_status;
begin
  select * into s from public.practical_submissions where id = p_submission for update;
  if s.status <> 'pending' then raise exception 'already scored'; end if;
  if not (app.is_mentor_of(s.user_id)
          and app.has_permission('practical.score', app.user_outlet(s.user_id))) then
    raise exception 'only the trainee''s mentor can score this test' using errcode = '42501';
  end if;

  select module_version_id into mv_id from public.module_assignments where id = s.assignment_id;

  insert into public.practical_scores (submission_id, criterion_id, result, note)
  select s.id, (e ->> 'criterion_id')::uuid, (e ->> 'result')::public.rubric_result, e ->> 'note'
  from jsonb_array_elements(p_scores) e
  join public.rubric_criteria c on c.id = (e ->> 'criterion_id')::uuid and c.module_version_id = mv_id;

  select count(*) into missing from public.rubric_criteria c
   where c.module_version_id = mv_id
     and not exists (select 1 from public.practical_scores ps
                     where ps.submission_id = s.id and ps.criterion_id = c.id);
  if missing > 0 then raise exception 'score every rubric line (% missing)', missing; end if;

  outcome := case when exists (select 1 from public.practical_scores ps
                               where ps.submission_id = s.id and ps.result = 'redo')
                  then 'redo' else 'passed' end;

  update public.practical_submissions
     set status = outcome, scored_by = (select auth.uid()), scored_at = now(), feedback = p_feedback
   where id = s.id;

  if outcome = 'passed' then
    perform app.try_complete_assignment(s.assignment_id);
    perform app.notify(s.user_id, 'practical_passed', 'You passed your practical test');
  else
    perform app.notify(s.user_id, 'practical_redo', 'Your mentor asked you to redo the test', p_feedback);
  end if;
  return outcome;
end $$;

-- ---------- Mentorship (M1, M5, M7) ----------
create or replace function public.assign_mentor(p_trainee uuid, p_mentor uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  t     public.profiles%rowtype;
  m     public.profiles%rowtype;
  rules jsonb := coalesce(app.setting('mentor_rules'), '{}'::jsonb);
  lvl   smallint;
  load  integer;
  ms_id uuid;
begin
  select * into t from public.profiles where id = p_trainee;
  select * into m from public.profiles where id = p_mentor;
  if not app.has_permission('mentorship.manage', t.outlet_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if m.status <> 'active' or m.outlet_id is distinct from t.outlet_id then
    raise exception 'mentor must be active and work at the same outlet';
  end if;

  select level into lvl from public.positions where id = m.position_id;
  if coalesce(lvl, 0) < coalesce((rules ->> 'min_level')::int, 1) then
    raise exception 'mentor''s level is below the minimum of %', rules ->> 'min_level';
  end if;

  select count(*) into load from public.mentorships where mentor_id = m.id and ended_at is null;
  if load >= coalesce((rules ->> 'max_trainees')::int, 3) then
    raise exception 'mentor already has % trainees', load;
  end if;

  if coalesce((rules ->> 'require_path_complete')::boolean, true) and exists (
       select 1 from public.module_assignments a
       join public.learning_path_items i on i.path_id = a.path_id and i.module_id = a.module_id
       where a.user_id = m.id and i.is_mandatory and a.completed_at is null) then
    raise exception 'mentor has not finished their own mandatory modules';
  end if;

  if not exists (select 1 from public.user_roles ur join public.roles r on r.id = ur.role_id
                 where ur.user_id = m.id and r.name = 'Mentor') then
    raise exception 'grant this person the Mentor role first';
  end if;

  update public.mentorships set ended_at = now(), end_reason = 'reassigned'
   where trainee_id = t.id and ended_at is null;
  insert into public.mentorships (mentor_id, trainee_id, outlet_id, assigned_by)
  values (m.id, t.id, t.outlet_id, (select auth.uid())) returning id into ms_id;

  perform app.notify(m.id, 'mentor_assigned', 'New trainee: ' || t.full_name);
  perform app.notify(t.id, 'mentor_assigned', 'Your mentor: ' || m.full_name);
  return ms_id;
end $$;

create or replace function public.submit_mentor_rating(p_mentorship uuid, p_score smallint, p_comment text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare ms public.mentorships%rowtype;
begin
  select * into ms from public.mentorships where id = p_mentorship;
  if ms.trainee_id is distinct from (select auth.uid()) or not app.has_permission_any('mentor_rating.submit') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if ms.ended_at is null then raise exception 'you can rate your mentor when the mentorship ends'; end if;
  insert into public.mentor_ratings (mentorship_id, mentor_id, rater_id, score, comment)
  values (ms.id, ms.mentor_id, ms.trainee_id, p_score, p_comment);
end $$;

-- Mentor's own view: average only, and only after the minimum number of ratings
create or replace function public.my_mentor_rating()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  n       integer;
  avg_s   numeric;
  min_n   integer := coalesce((app.setting('rating_min_count') #>> '{}')::int, 3);
begin
  if not app.is_active_user() then raise exception 'not allowed' using errcode = '42501'; end if;
  select count(*), round(avg(score), 1) into n, avg_s
    from public.mentor_ratings where mentor_id = (select auth.uid());
  if n < min_n then
    return jsonb_build_object('ratings', n, 'average', null, 'shown_after', min_n);
  end if;
  return jsonb_build_object('ratings', n, 'average', avg_s);
end $$;

-- HR and senior management only; every call is logged (M7, R5)
create or replace function public.mentor_ratings_with_raters(p_mentor uuid)
returns table (rating_id uuid, rater_id uuid, rater_name text, score smallint, comment text, created_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not app.has_permission('mentor_rating.view_raters') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  insert into public.mentor_rating_access_log (viewer_id, mentor_id) values ((select auth.uid()), p_mentor);
  return query
    select r.id, r.rater_id, p.full_name, r.score, r.comment, r.created_at
    from public.mentor_ratings r join public.profiles p on p.id = r.rater_id
    where r.mentor_id = p_mentor
    order by r.created_at desc;
end $$;

-- ---------- Aksi: checklists (A2-A5) ----------
-- Called by pg_cron once a day: creates today's runs for every active schedule.
create or replace function app.generate_checklist_runs(p_day date default (now() at time zone 'Asia/Makassar')::date)
returns integer language plpgsql security definer set search_path = '' as $$
declare n integer;
begin
  insert into public.checklist_runs
    (template_version_id, outlet_id, schedule_id, shift_date, shift, due_at)
  select v.id, o.id, s.id, p_day, s.shift, (p_day + s.due_time) at time zone o.timezone
  from public.checklist_schedules s
  join public.checklist_templates t on t.id = s.template_id and t.archived_at is null and t.kind = 'routine'
  join lateral (select id from public.checklist_template_versions
                where template_id = t.id and published_at is not null
                order by version desc limit 1) v on true
  join public.outlets o on o.archived_at is null
       and (s.outlet_id = o.id or (s.outlet_id is null and (t.brand_id is null or t.brand_id = o.brand_id)))
  where s.active and extract(isodow from p_day)::smallint = any(s.days_of_week)
  on conflict (schedule_id, outlet_id, shift_date) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Called by pg_cron every 15 minutes: marks overdue runs as missed and alerts (A5)
create or replace function app.mark_missed_runs(p_grace interval default interval '30 minutes')
returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
  for r in
    update public.checklist_runs set status = 'missed'
     where status in ('pending', 'in_progress') and due_at + p_grace < now()
    returning id, outlet_id
  loop
    n := n + 1;
    perform app.notify(u, 'checklist_missed', 'A checklist was missed', null,
                       jsonb_build_object('run_id', r.id))
      from app.users_with_permission('checklist.view', r.outlet_id) u;
  end loop;
  return n;
end $$;

-- Area manager starts an audit visit (S4)
create or replace function public.start_audit(p_template uuid, p_outlet uuid)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid; run_id uuid;
begin
  if not app.has_permission('audit.conduct', p_outlet) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select tv.id into v from public.checklist_template_versions tv
  join public.checklist_templates t on t.id = tv.template_id and t.kind = 'audit' and t.archived_at is null
  where tv.template_id = p_template and tv.published_at is not null
  order by tv.version desc limit 1;
  if v is null then raise exception 'no published audit form'; end if;
  insert into public.checklist_runs (template_version_id, outlet_id, shift_date, shift, due_at, status, conducted_by)
  values (v, p_outlet, current_date, 'other', now() + interval '1 day', 'in_progress', (select auth.uid()))
  returning id into run_id;
  return run_id;
end $$;

-- Submit: server time, location check, required photos, issues for failed items (A3, A4)
create or replace function public.submit_checklist_run(p_run uuid, p_latitude numeric, p_longitude numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r       public.checklist_runs%rowtype;
  o       public.outlets%rowtype;
  t       public.checklist_templates%rowtype;
  dist    double precision;
  inside  boolean;
  missing integer;
  total   integer;
  failed  integer;
  resp    record;
  iss_id  uuid;
  me      uuid := (select auth.uid());
begin
  if not app.can_fill_run(p_run) then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into r from public.checklist_runs where id = p_run for update;
  select * into o from public.outlets where id = r.outlet_id;
  select t2.* into t from public.checklist_templates t2
    join public.checklist_template_versions v on v.template_id = t2.id where v.id = r.template_version_id;

  if o.latitude is not null and p_latitude is not null then
    dist   := app.distance_m(p_latitude, p_longitude, o.latitude, o.longitude);
    inside := dist <= o.geofence_radius_m;
  end if;
  if coalesce((app.setting('require_geofence') #>> '{}')::boolean, true) and inside is not true then
    raise exception 'you must be at the outlet to submit';
  end if;

  select count(*) into missing from public.checklist_items i
   where i.template_version_id = r.template_version_id
     and (not exists (select 1 from public.checklist_responses x where x.run_id = r.id and x.item_id = i.id)
          or (i.photo_rule = 'required' and not exists (
                select 1 from public.checklist_responses x
                join public.checklist_response_photos ph on ph.response_id = x.id
                where x.run_id = r.id and x.item_id = i.id)));
  if missing > 0 then raise exception '% items still need an answer or photo', missing; end if;

  select count(*), count(*) filter (where not passed) into total, failed
    from public.checklist_responses where run_id = r.id;

  update public.checklist_runs
     set status = 'submitted', submitted_by = me, submitted_at = now(),
         latitude = p_latitude, longitude = p_longitude, within_geofence = inside,
         item_count = total, failed_count = failed,
         compliance_pct = case when total = 0 then 100 else round((total - failed) * 100.0 / total, 2) end
   where id = r.id;

  for resp in
    select x.id, i.label from public.checklist_responses x
    join public.checklist_items i on i.id = x.item_id
    where x.run_id = r.id and not x.passed
  loop
    insert into public.issues (outlet_id, source, run_id, response_id, title, severity, raised_by, due_at)
    values (r.outlet_id, case when t.kind = 'audit' then 'audit' else 'checklist' end::public.issue_source,
            r.id, resp.id, resp.label, t.fail_issue_severity, me,
            now() + make_interval(hours => t.fail_issue_sla_hours))
    returning id into iss_id;
    insert into public.issue_events (issue_id, actor_id, type) values (iss_id, me, 'created');
    perform app.notify(u, 'issue_created', 'New issue: ' || resp.label, null, jsonb_build_object('issue_id', iss_id))
      from app.users_with_permission('issue.assign', r.outlet_id) u;
  end loop;

  return jsonb_build_object('failed', failed, 'total', total);
end $$;

-- ---------- Standar: issues (S1-S3, R7) ----------
create or replace function public.raise_issue(p_outlet uuid, p_title text, p_description text default null,
                                              p_severity public.issue_severity default 'medium',
                                              p_sla_hours integer default 24, p_media uuid default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare iss uuid; me uuid := (select auth.uid());
begin
  if not app.has_permission('issue.create', p_outlet) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  insert into public.issues (outlet_id, source, title, description, severity, raised_by, due_at)
  values (p_outlet, 'manual', p_title, p_description, p_severity, me, now() + make_interval(hours => p_sla_hours))
  returning id into iss;
  insert into public.issue_events (issue_id, actor_id, type, media_file_id) values (iss, me, 'created', p_media);
  perform app.notify(u, 'issue_created', 'New issue: ' || p_title, null, jsonb_build_object('issue_id', iss))
    from app.users_with_permission('issue.assign', p_outlet) u where u <> me;
  return iss;
end $$;

create or replace function public.assign_issue(p_issue uuid, p_assignee uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.issues%rowtype;
begin
  select * into i from public.issues where id = p_issue for update;
  if not app.has_permission('issue.assign', i.outlet_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if app.user_outlet(p_assignee) is distinct from i.outlet_id then
    raise exception 'assignee must work at this outlet';
  end if;
  update public.issues set assigned_to = p_assignee where id = i.id;
  insert into public.issue_events (issue_id, actor_id, type, note)
  values (i.id, (select auth.uid()), 'assigned', p_assignee::text);
  perform app.notify(p_assignee, 'issue_assigned', 'Issue assigned to you: ' || i.title,
                     null, jsonb_build_object('issue_id', i.id));
end $$;

create or replace function public.fix_issue(p_issue uuid, p_note text default null, p_proof_media uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.issues%rowtype; me uuid := (select auth.uid());
begin
  select * into i from public.issues where id = p_issue for update;
  if i.status <> 'open' then raise exception 'issue is not open'; end if;
  if not ((i.assigned_to = me and app.has_permission('issue.fix', i.outlet_id))
          or app.has_permission('issue.assign', i.outlet_id)) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.issues set status = 'fixed', fixed_by = me, fixed_at = now() where id = i.id;
  insert into public.issue_events (issue_id, actor_id, type, note, media_file_id)
  values (i.id, me, 'fixed', p_note, p_proof_media);
end $$;

-- Accept closes the issue; reject reopens it. Nobody verifies their own fix.
create or replace function public.verify_issue(p_issue uuid, p_accept boolean, p_note text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.issues%rowtype; me uuid := (select auth.uid());
begin
  select * into i from public.issues where id = p_issue for update;
  if i.status <> 'fixed' then raise exception 'issue is not waiting for a check'; end if;
  if not app.has_permission('issue.verify', i.outlet_id) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if i.fixed_by = me then
    raise exception 'you cannot verify your own fix' using errcode = '42501';
  end if;
  if p_accept then
    update public.issues set status = 'closed', closed_by = me, closed_at = now() where id = i.id;
    insert into public.issue_events (issue_id, actor_id, type, note) values (i.id, me, 'accepted', p_note);
  else
    update public.issues set status = 'open', fixed_by = null, fixed_at = null where id = i.id;
    insert into public.issue_events (issue_id, actor_id, type, note) values (i.id, me, 'reopened', p_note);
    if i.fixed_by is not null then
      perform app.notify(i.fixed_by, 'issue_reopened', 'Issue reopened: ' || i.title, p_note);
    end if;
  end if;
end $$;

-- Called by pg_cron every 15 minutes: escalate issues past their deadline (S3)
create or replace function app.escalate_overdue_issues()
returns integer language plpgsql security definer set search_path = '' as $$
declare r record; n integer := 0;
begin
  for r in
    update public.issues set escalated_at = now()
     where status = 'open' and due_at < now() and escalated_at is null
    returning id, outlet_id, title
  loop
    n := n + 1;
    insert into public.issue_events (issue_id, type) values (r.id, 'escalated');
    perform app.notify(u, 'issue_escalated', 'Overdue issue: ' || r.title, null, jsonb_build_object('issue_id', r.id))
      from app.users_with_permission('audit.conduct', r.outlet_id) u;   -- area managers
  end loop;
  return n;
end $$;

-- Certificate expiry reminders (T8), daily
create or replace function app.remind_expiring_certificates()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  days integer := coalesce((app.setting('certificate_reminder_days') #>> '{}')::int, 30);
  n integer;
begin
  insert into public.notifications (user_id, type, title, data)
  select c.user_id, 'certificate_expiring', 'A certificate expires soon', jsonb_build_object('certificate_id', c.id)
  from public.certificates c
  join public.profiles p on p.id = c.user_id and p.status = 'active'
  where c.expires_at::date = (now() + make_interval(days => days))::date;
  get diagnostics n = row_count;
  return n;
end $$;

-- =============================================================================
-- 13. ROW LEVEL SECURITY
-- =============================================================================
-- RLS on every table, plus one RESTRICTIVE policy: inactive users get nothing,
-- whatever other policy would allow (R8). Permissive policies below are ANDed with it.
do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public'
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy "active users only" on public.%I as restrictive for all to authenticated
         using (app.is_active_user()) with check (app.is_active_user())', t);
  end loop;
end $$;

-- ----- Org structure: readable by active users, managed by permission -----
create policy "read brands"      on public.brands      for select to authenticated using (app.is_active_user());
create policy "read areas"       on public.areas       for select to authenticated using (app.is_active_user());
create policy "read outlets"     on public.outlets     for select to authenticated using (app.is_active_user());
create policy "read departments" on public.departments for select to authenticated using (app.is_active_user());
create policy "read positions"   on public.positions   for select to authenticated using (app.is_active_user());

create policy "manage brands" on public.brands for all to authenticated
  using (app.has_permission('outlet.manage')) with check (app.has_permission('outlet.manage'));
create policy "manage areas" on public.areas for all to authenticated
  using (app.has_permission('outlet.manage')) with check (app.has_permission('outlet.manage'));
create policy "manage outlets" on public.outlets for all to authenticated
  using (app.has_permission('outlet.manage')) with check (app.has_permission('outlet.manage'));
create policy "manage departments" on public.departments for all to authenticated
  using (app.has_permission('org.manage')) with check (app.has_permission('org.manage'));
create policy "manage positions" on public.positions for all to authenticated
  using (app.has_permission('org.manage')) with check (app.has_permission('org.manage'));

-- ----- Profiles -----
create policy "read own profile" on public.profiles for select to authenticated
  using (id = (select auth.uid()));
create policy "mentor reads trainees" on public.profiles for select to authenticated
  using (app.is_mentor_of(id));
create policy "read profiles in scope" on public.profiles for select to authenticated
  using (app.has_permission('user.view', outlet_id));
create policy "manage profiles" on public.profiles for all to authenticated
  using (app.has_permission('user.manage')) with check (app.has_permission('user.manage'));

-- ----- Roles and permissions: only role managers; users use my_permissions() -----
create policy "read permissions" on public.permissions for select to authenticated
  using (app.has_permission('role.manage'));
create policy "manage roles" on public.roles for all to authenticated
  using (app.has_permission('role.manage')) with check (app.has_permission('role.manage'));
create policy "manage role permissions" on public.role_permissions for all to authenticated
  using (app.has_permission('role.manage')) with check (app.has_permission('role.manage'));
create policy "manage user roles" on public.user_roles for all to authenticated
  using (app.has_permission('role.manage')) with check (app.has_permission('role.manage'));

create policy "manage settings" on public.app_settings for all to authenticated
  using (app.has_permission('settings.manage')) with check (app.has_permission('settings.manage'));
create policy "read audit log" on public.admin_audit_log for select to authenticated
  using (app.has_permission('audit_log.view'));

-- ----- Media -----
create policy "read training media" on public.media_files for select to authenticated
  using (kind in ('training_video', 'training_document', 'training_image')
         and (app.has_permission_any('learning.take') or app.has_permission('module.author')));
create policy "read own media" on public.media_files for select to authenticated
  using (uploaded_by = (select auth.uid()));
create policy "read personal media in scope" on public.media_files for select to authenticated
  using (kind in ('checklist_photo', 'issue_photo', 'practical_video')
         and (app.is_mentor_of(uploaded_by)
              or app.has_permission('checklist.view', outlet_id)
              or app.has_permission('issue.view', outlet_id)
              or app.has_permission('training.view', outlet_id)));
create policy "upload training media" on public.media_files for insert to authenticated
  with check (kind in ('training_video', 'training_document', 'training_image')
              and uploaded_by = (select auth.uid()) and app.has_permission('module.author'));
create policy "upload own media" on public.media_files for insert to authenticated
  with check (kind in ('checklist_photo', 'issue_photo', 'practical_video')
              and uploaded_by = (select auth.uid()) and app.is_active_user()
              and outlet_id = app.user_outlet((select auth.uid())));

-- ----- Notifications and devices: own rows only -----
create policy "own notifications" on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
create policy "mark own notifications read" on public.notifications for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own device tokens" on public.device_tokens for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()) and app.is_active_user());

-- ----- Learning content -----
create policy "read modules" on public.modules for select to authenticated
  using (app.has_permission_any('learning.take') or app.has_permission('module.author')
         or app.has_permission('module.review') or app.has_permission('path.manage'));
create policy "author modules" on public.modules for all to authenticated
  using (app.has_permission('module.author')) with check (app.has_permission('module.author'));

create policy "read published versions" on public.module_versions for select to authenticated
  using (status = 'published' and app.has_permission_any('learning.take'));
create policy "read versions as author or reviewer" on public.module_versions for select to authenticated
  using (app.has_permission('module.author') or app.has_permission('module.review'));
create policy "read own assigned version" on public.module_versions for select to authenticated
  using (exists (select 1 from public.module_assignments a
                 where a.module_version_id = module_versions.id and app.can_view_training_of(a.user_id)));
-- Authors edit drafts only; publishing goes through review_module_version()
create policy "author creates drafts" on public.module_versions for insert to authenticated
  with check (app.has_permission('module.author') and status = 'draft' and author_id = (select auth.uid()));
create policy "author edits drafts" on public.module_versions for update to authenticated
  using (app.has_permission('module.author') and status in ('draft', 'changes_requested'))
  with check (status in ('draft', 'changes_requested'));

create policy "read module targets" on public.module_target_positions for select to authenticated
  using (app.is_active_user());
create policy "author module targets" on public.module_target_positions for all to authenticated
  using (app.has_permission('module.author')) with check (app.has_permission('module.author'));

-- Child rows of a version: readable with the version, editable while it is a draft
create or replace function app.can_read_version(p_version uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.module_versions v where v.id = p_version and (
       (v.status = 'published' and app.has_permission_any('learning.take'))
    or app.has_permission('module.author') or app.has_permission('module.review')
    or exists (select 1 from public.module_assignments a
               where a.module_version_id = v.id and app.can_view_training_of(a.user_id))));
$$;
create or replace function app.can_edit_version(p_version uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select app.has_permission('module.author') and exists (
    select 1 from public.module_versions v
    where v.id = p_version and v.status in ('draft', 'changes_requested'));
$$;

create policy "read blocks" on public.content_blocks for select to authenticated
  using (app.can_read_version(module_version_id));
create policy "edit blocks" on public.content_blocks for all to authenticated
  using (app.can_edit_version(module_version_id)) with check (app.can_edit_version(module_version_id));
create policy "read quizzes" on public.quizzes for select to authenticated
  using (app.can_read_version(module_version_id));
create policy "edit quizzes" on public.quizzes for all to authenticated
  using (app.can_edit_version(module_version_id)) with check (app.can_edit_version(module_version_id));
create policy "read rubric" on public.rubric_criteria for select to authenticated
  using (app.can_read_version(module_version_id));
create policy "edit rubric" on public.rubric_criteria for all to authenticated
  using (app.can_edit_version(module_version_id)) with check (app.can_edit_version(module_version_id));
create policy "edit quiz questions" on public.quiz_questions for all to authenticated
  using (app.has_permission('module.author') or app.has_permission('module.review'))
  with check (exists (select 1 from public.quizzes q
                      where q.id = quiz_id and app.can_edit_version(q.module_version_id)));

-- Question bank: authors and reviewers only. Staff receive questions through
-- start_quiz_attempt(), which never returns the correct answer.
create policy "question bank" on public.questions for all to authenticated
  using (app.has_permission('module.author') or app.has_permission('module.review'))
  with check (app.has_permission('module.author'));
create policy "question options" on public.question_options for all to authenticated
  using (app.has_permission('module.author') or app.has_permission('module.review'))
  with check (app.has_permission('module.author'));

-- ----- Learning paths -----
create policy "read paths" on public.learning_paths for select to authenticated
  using (app.is_active_user());
create policy "manage paths" on public.learning_paths for all to authenticated
  using (app.has_permission('path.manage')) with check (app.has_permission('path.manage'));
create policy "read path items" on public.learning_path_items for select to authenticated
  using (app.is_active_user());
create policy "manage path items" on public.learning_path_items for all to authenticated
  using (app.has_permission('path.manage')) with check (app.has_permission('path.manage'));

-- ----- Training records: self, mentor, managers in scope -----
create policy "read assignments" on public.module_assignments for select to authenticated
  using (app.can_view_training_of(user_id));
create policy "assign refresher or manual module" on public.module_assignments for insert to authenticated
  with check (source in ('manual', 'refresher')
              and assigned_by = (select auth.uid())
              and app.has_permission('training.assign', app.user_outlet(user_id)));

create policy "read block progress" on public.block_progress for select to authenticated
  using (exists (select 1 from public.module_assignments a
                 where a.id = assignment_id and app.can_view_training_of(a.user_id)));
create policy "read quiz attempts" on public.quiz_attempts for select to authenticated
  using (app.can_view_training_of(user_id));
create policy "read quiz answers" on public.quiz_attempt_answers for select to authenticated
  using (exists (select 1 from public.quiz_attempts q
                 where q.id = attempt_id and app.can_view_training_of(q.user_id)));
create policy "read practical submissions" on public.practical_submissions for select to authenticated
  using (app.can_view_training_of(user_id));
create policy "read practical scores" on public.practical_scores for select to authenticated
  using (exists (select 1 from public.practical_submissions s
                 where s.id = submission_id and app.can_view_training_of(s.user_id)));
create policy "read spot checks" on public.practical_spot_checks for select to authenticated
  using (exists (select 1 from public.practical_submissions s
                 where s.id = submission_id
                   and app.has_permission('training.view', app.user_outlet(s.user_id))));
create policy "spot check sign-offs" on public.practical_spot_checks for insert to authenticated
  with check (checked_by = (select auth.uid()) and exists (
    select 1 from public.practical_submissions s
    where s.id = submission_id and s.status <> 'pending'
      and s.scored_by <> (select auth.uid())
      and app.has_permission('practical.spot_check', app.user_outlet(s.user_id))));
create policy "read certificates" on public.certificates for select to authenticated
  using (app.can_view_training_of(user_id));

-- ----- Mentorship -----
create policy "read own mentorships" on public.mentorships for select to authenticated
  using (mentor_id = (select auth.uid()) or trainee_id = (select auth.uid()));
create policy "read mentorships in scope" on public.mentorships for select to authenticated
  using (app.has_permission('mentorship.view', outlet_id) or app.has_permission('mentorship.manage', outlet_id));
create policy "end mentorships" on public.mentorships for update to authenticated
  using (app.has_permission('mentorship.manage', outlet_id))
  with check (app.has_permission('mentorship.manage', outlet_id));

create policy "read check-ins" on public.mentor_checkins for select to authenticated
  using (exists (select 1 from public.mentorships m where m.id = mentorship_id and (
           m.mentor_id = (select auth.uid()) or m.trainee_id = (select auth.uid())
           or app.has_permission('mentorship.view', m.outlet_id)
           or app.has_permission('mentorship.manage', m.outlet_id))));
create policy "mentor logs check-ins" on public.mentor_checkins for insert to authenticated
  with check (created_by = (select auth.uid()) and exists (
    select 1 from public.mentorships m
    where m.id = mentorship_id and m.mentor_id = (select auth.uid()) and m.ended_at is null
      and app.has_permission('mentor.checkin', m.outlet_id)));
create policy "mentor edits own check-ins" on public.mentor_checkins for update to authenticated
  using (created_by = (select auth.uid())) with check (created_by = (select auth.uid()));

-- mentor_ratings: intentionally NO policies (RPC access only)
create policy "read rating access log" on public.mentor_rating_access_log for select to authenticated
  using (app.has_permission('audit_log.view'));

-- ----- Checklists -----
create policy "read templates" on public.checklist_templates for select to authenticated
  using (app.has_permission_any('checklist.fill') or app.has_permission_any('checklist.view')
         or app.has_permission_any('audit.conduct') or app.has_permission('checklist_template.manage'));
create policy "manage templates" on public.checklist_templates for all to authenticated
  using (app.has_permission('checklist_template.manage')) with check (app.has_permission('checklist_template.manage'));

create policy "read template versions" on public.checklist_template_versions for select to authenticated
  using (published_at is not null or app.has_permission('checklist_template.manage'));
create policy "manage template versions" on public.checklist_template_versions for all to authenticated
  using (app.has_permission('checklist_template.manage')) with check (app.has_permission('checklist_template.manage'));

create policy "read items" on public.checklist_items for select to authenticated
  using (exists (select 1 from public.checklist_template_versions v
                 where v.id = template_version_id
                   and (v.published_at is not null or app.has_permission('checklist_template.manage'))));
-- Items of a published version are frozen; edit a new version instead
create policy "edit draft items" on public.checklist_items for all to authenticated
  using (app.has_permission('checklist_template.manage') and exists (
           select 1 from public.checklist_template_versions v
           where v.id = template_version_id and v.published_at is null))
  with check (app.has_permission('checklist_template.manage') and exists (
           select 1 from public.checklist_template_versions v
           where v.id = template_version_id and v.published_at is null));

create policy "read template positions" on public.checklist_template_positions for select to authenticated
  using (app.is_active_user());
create policy "manage template positions" on public.checklist_template_positions for all to authenticated
  using (app.has_permission('checklist_template.manage')) with check (app.has_permission('checklist_template.manage'));
create policy "read schedules" on public.checklist_schedules for select to authenticated
  using (app.has_permission('checklist_template.manage') or app.has_permission_any('checklist.view'));
create policy "manage schedules" on public.checklist_schedules for all to authenticated
  using (app.has_permission('checklist_template.manage')) with check (app.has_permission('checklist_template.manage'));

create policy "read runs" on public.checklist_runs for select to authenticated
  using (app.has_permission('checklist.view', outlet_id) or app.can_fill_run(id)
         or submitted_by = (select auth.uid()) or conducted_by = (select auth.uid()));

create policy "read responses" on public.checklist_responses for select to authenticated
  using (exists (select 1 from public.checklist_runs r where r.id = run_id and (
           app.has_permission('checklist.view', r.outlet_id) or app.can_fill_run(r.id)
           or r.submitted_by = (select auth.uid()))));
create policy "answer items" on public.checklist_responses for insert to authenticated
  with check (answered_by = (select auth.uid()) and app.can_fill_run(run_id)
              and exists (select 1 from public.checklist_runs r join public.checklist_items i
                          on i.template_version_id = r.template_version_id
                          where r.id = run_id and i.id = item_id));
create policy "change answers before submit" on public.checklist_responses for update to authenticated
  using (app.can_fill_run(run_id)) with check (answered_by = (select auth.uid()) and app.can_fill_run(run_id));

create policy "read response photos" on public.checklist_response_photos for select to authenticated
  using (exists (select 1 from public.checklist_responses x join public.checklist_runs r on r.id = x.run_id
                 where x.id = response_id and (app.has_permission('checklist.view', r.outlet_id)
                                               or app.can_fill_run(r.id))));
create policy "attach photos" on public.checklist_response_photos for insert to authenticated
  with check (exists (select 1 from public.checklist_responses x
                      join public.media_files m on m.id = media_file_id
                      where x.id = response_id and app.can_fill_run(x.run_id)
                        and m.uploaded_by = (select auth.uid()) and m.kind = 'checklist_photo'));

-- ----- Issues: reads by scope or assignment; all changes through RPCs -----
create policy "read issues in scope" on public.issues for select to authenticated
  using (app.has_permission('issue.view', outlet_id) or assigned_to = (select auth.uid())
         or raised_by = (select auth.uid()));
create policy "read issue events" on public.issue_events for select to authenticated
  using (exists (select 1 from public.issues i where i.id = issue_id and (
           app.has_permission('issue.view', i.outlet_id) or i.assigned_to = (select auth.uid())
           or i.raised_by = (select auth.uid()))));
create policy "comment on issues" on public.issue_events for insert to authenticated
  with check (type = 'commented' and actor_id = (select auth.uid()) and exists (
    select 1 from public.issues i where i.id = issue_id and (
      app.has_permission('issue.view', i.outlet_id) or i.assigned_to = (select auth.uid()))));

-- =============================================================================
-- 14. GRANTS
-- =============================================================================
-- Helper schema: callable from policies, not exposed through the API
grant usage on schema app to authenticated;
revoke all on all functions in schema app from public, anon;
grant execute on all functions in schema app to authenticated;
-- Scheduled jobs are run by pg_cron (postgres), never by app users
revoke execute on function app.generate_checklist_runs(date) from authenticated;
revoke execute on function app.mark_missed_runs(interval) from authenticated;
revoke execute on function app.escalate_overdue_issues() from authenticated;
revoke execute on function app.remind_expiring_certificates() from authenticated;
revoke execute on function app.sync_user_path(uuid) from authenticated;
revoke execute on function app.try_complete_assignment(uuid) from authenticated;
revoke execute on function app.notify(uuid, text, text, text, jsonb) from authenticated;

-- RPCs: signed-in users only
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;

-- Nothing for anonymous visitors
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
-- Staff never read questions or options directly (no policy lets them):
-- start_quiz_attempt() serves questions without the correct answer.

-- =============================================================================
-- 15. SEED: permissions, default roles, settings
-- =============================================================================
insert into public.permissions (code, description, is_sensitive) values
  -- setup
  ('org.manage',                'Manage departments, positions and levels', true),
  ('outlet.manage',             'Manage brands, areas and outlets', false),
  ('user.view',                 'View staff profiles in scope', false),
  ('user.manage',               'Create, edit and deactivate users', true),
  ('role.manage',               'Manage roles, permissions and role grants', true),
  ('settings.manage',           'Change system settings', true),
  ('audit_log.view',            'View the admin audit log', true),
  ('data.export',               'Export data to CSV', true),
  ('dashboard.view',            'View dashboards in scope', false),
  -- learning
  ('learning.take',             'Take own assigned modules and quizzes', false),
  ('module.author',             'Create and edit draft modules and the question bank', false),
  ('module.review',             'Review, approve and publish modules', false),
  ('path.manage',               'Manage learning paths', false),
  ('training.view',             'View training progress in scope', false),
  ('training.assign',           'Assign a manual or refresher module', false),
  ('practical.score',           'Score practical tests of own trainees', false),
  ('practical.spot_check',      'Spot-check mentor sign-offs', false),
  -- mentorship
  ('mentorship.manage',         'Assign and end mentorships', false),
  ('mentorship.view',           'View mentorships and check-ins in scope', false),
  ('mentor.checkin',            'Log weekly check-ins for own trainees', false),
  ('mentor_rating.submit',      'Rate own mentor', false),
  ('mentor_rating.view_raters', 'See who rated a mentor', true),
  -- checklists and audits
  ('checklist.fill',            'Fill checklists for own position and outlet', false),
  ('checklist.view',            'View checklist runs and results in scope', false),
  ('checklist_template.manage', 'Build checklist and audit templates and schedules', false),
  ('audit.conduct',             'Run outlet audits in scope', false),
  -- issues
  ('issue.create',              'Raise an issue', false),
  ('issue.view',                'View issues in scope', false),
  ('issue.assign',              'Assign issues', false),
  ('issue.fix',                 'Fix issues assigned to me', false),
  ('issue.verify',              'Accept or reopen a fixed issue', false);

insert into public.roles (name, description, is_system) values
  ('Staff',              'Every outlet employee. Grant at outlet scope.', true),
  ('Mentor',             'Added to staff who mentor trainees. Grant at outlet scope.', true),
  ('Outlet manager',     'Runs one outlet. Grant at outlet scope.', true),
  ('Area manager',       'Oversees several outlets. Grant at area scope.', true),
  ('HQ trainer',         'Writes modules and paths. Grant at group scope.', true),
  ('Training manager',   'Reviews and publishes modules. Grant at group scope.', true),
  ('HQ admin',           'Sets up the organisation and templates. Grant at group scope.', true),
  ('HR and senior management', 'Read-only view of the whole group. Grant at group scope.', true);

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
from (values
  ('Staff', 'learning.take'), ('Staff', 'checklist.fill'), ('Staff', 'issue.create'),
  ('Staff', 'issue.fix'), ('Staff', 'mentor_rating.submit'),

  ('Mentor', 'practical.score'), ('Mentor', 'mentor.checkin'),

  ('Outlet manager', 'user.view'), ('Outlet manager', 'dashboard.view'),
  ('Outlet manager', 'training.view'), ('Outlet manager', 'training.assign'),
  ('Outlet manager', 'practical.spot_check'),
  ('Outlet manager', 'mentorship.manage'), ('Outlet manager', 'mentorship.view'),
  ('Outlet manager', 'checklist.view'),
  ('Outlet manager', 'issue.create'), ('Outlet manager', 'issue.view'),
  ('Outlet manager', 'issue.assign'), ('Outlet manager', 'issue.fix'), ('Outlet manager', 'issue.verify'),

  ('Area manager', 'user.view'), ('Area manager', 'dashboard.view'),
  ('Area manager', 'training.view'), ('Area manager', 'mentorship.view'),
  ('Area manager', 'checklist.view'), ('Area manager', 'audit.conduct'),
  ('Area manager', 'issue.create'), ('Area manager', 'issue.view'),
  ('Area manager', 'issue.assign'), ('Area manager', 'issue.verify'),

  ('HQ trainer', 'module.author'), ('HQ trainer', 'path.manage'),

  ('Training manager', 'module.review'), ('Training manager', 'training.view'),

  ('HQ admin', 'org.manage'), ('HQ admin', 'outlet.manage'),
  ('HQ admin', 'user.view'), ('HQ admin', 'user.manage'), ('HQ admin', 'role.manage'),
  ('HQ admin', 'settings.manage'), ('HQ admin', 'checklist_template.manage'),
  ('HQ admin', 'audit_log.view'),

  ('HR and senior management', 'user.view'), ('HR and senior management', 'dashboard.view'),
  ('HR and senior management', 'training.view'), ('HR and senior management', 'mentorship.view'),
  ('HR and senior management', 'checklist.view'), ('HR and senior management', 'issue.view'),
  ('HR and senior management', 'mentor_rating.view_raters'),
  ('HR and senior management', 'data.export'), ('HR and senior management', 'audit_log.view')
) as m(role_name, perm)
join public.roles r on r.name = m.role_name
join public.permissions p on p.code = m.perm;

insert into public.app_settings (key, value) values
  ('mentor_rules', '{"min_level": 2, "max_trainees": 3, "require_path_complete": true}'),
  ('rating_min_count', '3'),
  ('certificate_reminder_days', '30'),
  ('require_geofence', 'true');

-- =============================================================================
-- 16. DASHBOARD VIEWS (security_invoker: callers only see rows RLS allows)
-- =============================================================================
create view public.v_outlet_daily_compliance with (security_invoker = true) as
select r.outlet_id, r.shift_date,
       count(*)                                        as runs,
       count(*) filter (where r.status = 'submitted')  as submitted,
       count(*) filter (where r.status = 'missed')     as missed,
       count(*) filter (where r.status = 'submitted' and r.submitted_at <= r.due_at) as on_time,
       round(avg(r.compliance_pct) filter (where r.status = 'submitted'), 1) as avg_compliance_pct
from public.checklist_runs r
group by r.outlet_id, r.shift_date;

create view public.v_issue_resolution with (security_invoker = true) as
select i.outlet_id, i.id as issue_id, i.source, i.severity, i.status, i.created_at, i.closed_at,
       i.escalated_at is not null as was_escalated,
       extract(epoch from (coalesce(i.closed_at, now()) - i.created_at)) / 3600.0 as hours_open
from public.issues i;

create view public.v_training_progress with (security_invoker = true) as
select a.user_id, p.outlet_id, p.position_id,
       count(*)                                                       as assigned,
       count(*) filter (where a.status = 'completed')                 as completed,
       count(*) filter (where a.completed_at is null and a.due_at < now()) as overdue
from public.module_assignments a
join public.profiles p on p.id = a.user_id
group by a.user_id, p.outlet_id, p.position_id;

grant select on public.v_outlet_daily_compliance, public.v_issue_resolution, public.v_training_progress
  to authenticated;

-- =============================================================================
-- 17. SCHEDULED JOBS (enable the pg_cron extension in Supabase first)
-- =============================================================================
-- select cron.schedule('asah-generate-runs',  '5 0 * * *',    $$select app.generate_checklist_runs()$$);
-- select cron.schedule('asah-missed-runs',    '*/15 * * * *', $$select app.mark_missed_runs()$$);
-- select cron.schedule('asah-escalate',       '*/15 * * * *', $$select app.escalate_overdue_issues()$$);
-- select cron.schedule('asah-cert-reminders', '0 1 * * *',    $$select app.remind_expiring_certificates()$$);
