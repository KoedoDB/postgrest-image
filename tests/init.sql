-- What a KoedoDB project database has before PostgREST runs: the roles Supabase clients expect, and a table with row level security.
-- authenticator is the role PostgREST logs in as (it can do nothing itself); it switches to anon or authenticated per request, from the token's role claim.
-- service_role skips row level security (BYPASSRLS). The password is given by the test (psql -v restpw=...).
CREATE ROLE anon NOLOGIN NOINHERIT;
CREATE ROLE authenticated NOLOGIN NOINHERIT;
CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD :'restpw';
GRANT anon, authenticated, service_role TO authenticator;
-- a request that runs too long is cancelled by the database, not by PostgREST
ALTER ROLE authenticator SET statement_timeout = '3s';

GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- what auth.uid() is in a Supabase database: the sub claim of the token PostgREST was given
CREATE SCHEMA auth;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS
  $$ SELECT nullif(current_setting('request.jwt.claims', true)::json ->> 'sub', '')::uuid $$;

CREATE TABLE public.notes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  owner uuid NOT NULL,
  body text NOT NULL
);
ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;
CREATE POLICY notes_own ON public.notes FOR ALL TO authenticated USING (owner = auth.uid()) WITH CHECK (owner = auth.uid());
GRANT SELECT, INSERT, UPDATE, DELETE ON public.notes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.notes TO service_role;

-- readable by everyone, including anon
CREATE TABLE public.posts (id int PRIMARY KEY, title text NOT NULL);
INSERT INTO public.posts SELECT g, 'post ' || g FROM generate_series(1, 30) g;
GRANT SELECT ON public.posts TO anon, authenticated, service_role;

-- no grant to anon or authenticated at all
CREATE TABLE public.secrets (id int PRIMARY KEY, value text);
INSERT INTO public.secrets VALUES (1, 'top secret');
GRANT SELECT ON public.secrets TO service_role;

CREATE FUNCTION public.slow() RETURNS void LANGUAGE sql AS $$ SELECT pg_sleep(10) $$;
GRANT EXECUTE ON FUNCTION public.slow() TO anon, authenticated, service_role;
CREATE FUNCTION public.who() RETURNS json LANGUAGE sql STABLE AS $$ SELECT json_build_object('role', current_user, 'sub', auth.uid()) $$;
GRANT EXECUTE ON FUNCTION public.who() TO anon, authenticated, service_role;
