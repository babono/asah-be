-- Makes the first HQ admin, so they can sign in to the admin web and create
-- everyone else there (Users and roles › Add user / Import spreadsheet).
--
-- 1. Supabase Dashboard › Authentication › Users › Add user › "Create new user"
--    with the phone number (e.g. +628123456789) and "Auto confirm user" on.
-- 2. Edit the two values below and run this in the SQL editor.
do $$
declare
  admin_phone text := '+628123456789';   -- the phone you used in step 1
  admin_name  text := 'HQ Admin';
  uid uuid;
begin
  -- auth.users stores the phone without the leading '+'
  select id into uid from auth.users where phone = ltrim(admin_phone, '+');
  if uid is null then
    raise exception 'No auth user with phone %. Create it in Authentication › Users first.', admin_phone;
  end if;

  insert into public.profiles (id, full_name, phone, locale)
  values (uid, admin_name, admin_phone, 'en')
  on conflict (id) do update set full_name = excluded.full_name;

  -- HQ admin sets up the organisation; add HQ trainer if the same person writes modules.
  insert into public.user_roles (user_id, role_id, scope_type)
  select uid, r.id, 'group' from public.roles r where r.name in ('HQ admin')
  on conflict do nothing;
end $$;
