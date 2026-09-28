-- ============================================================
-- roles.sql — supabase API roles bootstrapped into an EXISTING
-- database (plusthesite) that was created by stack/init, not by the
-- supabase/postgres image. Adapted from
-- supabase/postgres:17.6.1.136 init-scripts/00000000000000-initial-schema.sql
-- plus the authenticator-related migrations. Idempotent.
--
-- Run as the DB owner (vpsplus). No superuser required.
-- ============================================================

-- API roles (nologin — authenticator switches into them per request)
do $$ begin
  if not exists (select from pg_roles where rolname='anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname='authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname='service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

-- authenticator: the single login PostgREST uses; membership lets it
-- SET ROLE to anon/authenticated/service_role per JWT role claim.
do $$ begin
  if not exists (select from pg_roles where rolname='authenticator') then
    create role authenticator noinherit;
  end if;
end $$;
grant anon, authenticated, service_role to authenticator;

-- supabase_auth_admin: owns the auth schema (GoTrue writes here)
do $$ begin
  if not exists (select from pg_roles where rolname='supabase_auth_admin') then
    create role supabase_auth_admin noinherit createrole login;
  end if;
end $$;

-- supabase_storage_admin: owns storage schema objects (storage-api writes here)
do $$ begin
  if not exists (select from pg_roles where rolname='supabase_storage_admin') then
    create role supabase_storage_admin noinherit createrole login;
  end if;
end $$;
grant authenticator to supabase_storage_admin;
revoke anon, authenticated, service_role from supabase_storage_admin;

-- schema-level grants mirroring the stock init
grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;
grant usage on schema extensions to anon, authenticated, service_role;

-- timeboxes runaway API queries (stock values)
alter role anon set statement_timeout = '3s';
alter role authenticated set statement_timeout = '8s';
alter role authenticator set statement_timeout = '8s';

-- app.settings.jwt_secret is set per-database by supabase-env (jwt.sql)
