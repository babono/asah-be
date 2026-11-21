-- Empties every org, people, training and checklist table so seed_demo.sql can
-- run again with fresh dates (e.g. the morning of a demo). Keeps roles,
-- permissions, settings and the auth users. DEMO PROJECTS ONLY: this deletes
-- all real data too.
--   npm run demo:reset
do $$
declare t text;
begin
  -- app_settings references profiles, so truncating cascades to it: keep a copy
  create temp table keep_settings on commit drop as select key, value from public.app_settings;
  select string_agg(format('public.%I', tablename), ', ') into t
  from pg_tables
  where schemaname = 'public'
    and tablename not in ('permissions', 'roles', 'role_permissions', 'app_settings');
  execute 'truncate ' || t || ' cascade';
  insert into public.app_settings (key, value) select key, value from keep_settings
  on conflict (key) do update set value = excluded.value;
end $$;
