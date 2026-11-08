-- Minimal stand-ins for what Supabase provides, so schema.sql loads in plain Postgres 15+.
-- auth.uid() reads a per-transaction setting the tests set (test.uid).
-- Roles are cluster-wide, so tolerate a second database in the same cluster.
--
-- Load this FIRST, before schema.sql: the `alter default privileges` statements below only apply to
-- tables created AFTER they run, and schema.sql is what creates them.
--
-- Why the table grants matter (eng review T-1): RLS is only observable from a non-superuser role.
-- `scripts/test-sql.sh` connects as `postgres` (rolsuper=t, rolbypassrls=t), which bypasses RLS
-- unconditionally -- `alter table ... force row level security` does not change that, because FORCE
-- constrains table *owners*, not superusers. So every RLS assertion must run under
-- `set local role authenticated` (or `anon`), and that role needs the same table privileges a real
-- Supabase project grants it, or the read fails with `permission denied` instead of exercising the
-- policy. Granting without switching role still passes vacuously; switching role without granting
-- errors instead of asserting. Both halves are required.
do $$ begin create role anon nologin; exception when duplicate_object then null; end $$;
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
do $$ begin create role service_role nologin bypassrls; exception when duplicate_object then null; end $$;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid
$$;
grant usage on schema auth to anon, authenticated, service_role;

-- Supabase's own identity table. This stand-in exists so the tombstone linkage is testable: when an
-- account is deleted the auth.users row goes, and public.users must SURVIVE it as an anonymized
-- tombstone. If public.users.id ever gained `references auth.users(id) on delete cascade`, a locked
-- plan would lose the name of someone other people had already committed time to. No such FK is
-- declared, here or in schema.sql -- that absence IS the design, and users_auth_test.sql asserts it.
create table auth.users (
  id uuid primary key,
  email text
);
grant select on auth.users to service_role;

-- Mirror the privileges a new Supabase project grants in `public`, so a missing REVOKE in our own
-- SQL shows up here rather than in production. Supabase grants ALL on tables, sequences and
-- functions to anon, authenticated and service_role, and sets matching default privileges.
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all functions in schema public to anon, authenticated, service_role;
