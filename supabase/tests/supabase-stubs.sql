-- Minimal stand-ins for what Supabase provides, so schema.sql loads in plain Postgres 14+.
-- auth.uid() reads a per-transaction setting the tests set (test.uid).
-- Roles are cluster-wide, so tolerate a second database in the same cluster.
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated;
-- Supabase grants execute on new public functions to anon and authenticated by default; mirror
-- that so a missing revoke in schema.sql shows up here.
alter default privileges in schema public grant execute on functions to anon, authenticated;
