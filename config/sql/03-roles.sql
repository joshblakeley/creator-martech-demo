-- Three login roles, one per SQL MCP server. This file is where the
-- subagent tool scoping actually lives.
--
-- Why database logins rather than a tool filter: a single shared MCP server
-- cannot be narrowed per specialist. Three servers, each logging in as a
-- different least-privilege role, is both available today and a stronger
-- claim — the boundary is the database, not a prompt or a filter.
--
-- To see it: ask the fit-scoring specialist to select from creator.creators and
-- Postgres refuses. `make prove-grants` checks all six combinations.
--
-- Run with psql variables:
--   psql -v creator_pw=... -v fit_pw=... -v campaign_pw=... -f 03-roles.sql

BEGIN;

-- Idempotent role creation. DO blocks because CREATE ROLE has no
-- IF NOT EXISTS.
--
-- Roles are cluster-wide, not per-database. On a shared instance a role named
-- creator_sql may already exist and belong to something else, and the ALTER ROLE
-- below would silently change its password and break whatever uses it. Each role
-- is tagged with a comment on creation, and an untagged role of the same name is
-- left alone.
DO $$
DECLARE
  marker text := 'creator-martech-demo';
  r      text;
  owner  text;
BEGIN
  FOREACH r IN ARRAY ARRAY['creator_sql', 'fit_sql', 'campaign_sql'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
      -- pg_roles, not pg_authid: the latter needs superuser, which a
      -- managed-Postgres admin (RDS, Cloud SQL) is not. pg_roles exposes the
      -- same oid, and shobj_description reads pg_shdescription regardless.
      SELECT shobj_description(oid, 'pg_authid') INTO owner
        FROM pg_roles WHERE rolname = r;
      IF owner IS DISTINCT FROM marker THEN
        RAISE EXCEPTION
          'role "%" already exists on this instance and was not created by % '
          '(comment: %). Refusing to reset its password — it may belong to '
          'another workload. Rename this demo''s roles or use a dedicated '
          'instance.', r, marker, coalesce(owner, '<none>');
      END IF;
    ELSE
      EXECUTE format('CREATE ROLE %I LOGIN', r);
      EXECUTE format('COMMENT ON ROLE %I IS %L', r, marker);
    END IF;
  END LOOP;
END $$;

ALTER ROLE creator_sql  PASSWORD :'creator_pw';
ALTER ROLE fit_sql      PASSWORD :'fit_pw';
ALTER ROLE campaign_sql PASSWORD :'campaign_pw';

-- Start from nothing. Without this, PUBLIC retains CREATE on the public
-- schema and USAGE elsewhere on some Postgres versions.
REVOKE ALL ON SCHEMA creator, fit, campaign FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA creator, fit, campaign FROM PUBLIC;

-- creator_sql: the creator base and the brand list. Nothing else.
GRANT USAGE  ON SCHEMA creator                      TO creator_sql;
GRANT SELECT ON creator.creators, creator.brands    TO creator_sql;

-- fit_sql: the scores view ONLY — not the tables underneath it.
--
-- This works because a Postgres view executes with the privileges of its
-- OWNER unless created WITH (security_invoker = true), which we
-- deliberately do not set (02-views.sql). So fit_sql reads the view's
-- output without holding any grant on creator.creators. Verify with
-- `make prove-grants` rather than trusting this comment.
GRANT USAGE  ON SCHEMA fit                          TO fit_sql;
GRANT SELECT ON fit.creator_fit_scores              TO fit_sql;

-- campaign_sql: monthly rollups only. The root orchestrator answers the
-- ROI question from here and has no path to the creator base at all.
-- Two views, not the underlying campaign_performance table: the orchestrator
-- gets monthly trends and creator-level results, and no access to raw rows or
-- to the creator base. creator_performance carries identity + results only
-- (no rate, engagement, audience or contact columns) so naming a top
-- performer never becomes a route into creator attributes.
GRANT USAGE  ON SCHEMA campaign                     TO campaign_sql;
GRANT SELECT ON campaign.monthly_rollup             TO campaign_sql;
GRANT SELECT ON campaign.creator_performance        TO campaign_sql;

COMMIT;
