-- Match production_db_user on Cluster 1: same grants plus object ownership.
-- Identity/serial sequences follow their table; skip those.
-- Database owner stays postgres (same as production_db_user).
-- Run on Cluster 1 leader. Does not restart Postgres.

\c race_core_service

REVOKE CREATE ON DATABASE race_core_service FROM
  race_billing_srv_user, race_entity_srv_user, race_meta_srv_user,
  race_invoice_srv_user, race_report_srv_user, race_appadmin_srv_user;

DO $$
DECLARE
  rec record;
  pair record;
BEGIN
  FOR pair IN
    SELECT * FROM (VALUES
      ('race_billing_srv',  'race_billing_srv_user'),
      ('race_entity_srv',   'race_entity_srv_user'),
      ('race_meta_srv',     'race_meta_srv_user'),
      ('race_invoice_srv',  'race_invoice_srv_user'),
      ('race_report_srv',   'race_report_srv_user'),
      ('race_appadmin_srv', 'race_appadmin_srv_user')
    ) AS t(sch, own)
  LOOP
    EXECUTE format('ALTER SCHEMA %I OWNER TO %I', pair.sch, pair.own);
    EXECUTE format('GRANT USAGE, CREATE ON SCHEMA %I TO %I', pair.sch, pair.own);
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO %I', pair.sch, pair.own);
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA %I TO %I', pair.sch, pair.own);
    EXECUTE format('GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA %I TO %I', pair.sch, pair.own);

    FOR rec IN
      SELECT c.relname, c.relkind
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = pair.sch
        AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
        AND NOT (
          c.relkind = 'S' AND EXISTS (
            SELECT 1 FROM pg_depend d
            WHERE d.objid = c.oid
              AND d.classid = 'pg_class'::regclass
              AND d.refclassid = 'pg_class'::regclass
              AND d.deptype IN ('a', 'i')
          )
        )
    LOOP
      CASE rec.relkind
        WHEN 'S' THEN
          EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO %I', pair.sch, rec.relname, pair.own);
        WHEN 'v' THEN
          EXECUTE format('ALTER VIEW %I.%I OWNER TO %I', pair.sch, rec.relname, pair.own);
        WHEN 'm' THEN
          EXECUTE format('ALTER MATERIALIZED VIEW %I.%I OWNER TO %I', pair.sch, rec.relname, pair.own);
        ELSE
          EXECUTE format('ALTER TABLE %I.%I OWNER TO %I', pair.sch, rec.relname, pair.own);
      END CASE;
    END LOOP;

    FOR rec IN
      SELECT t.typname
      FROM pg_type t
      JOIN pg_namespace n ON n.oid = t.typnamespace
      WHERE n.nspname = pair.sch
        AND t.typtype IN ('e', 'd')
    LOOP
      EXECUTE format('ALTER TYPE %I.%I OWNER TO %I', pair.sch, rec.typname, pair.own);
    END LOOP;

    FOR rec IN
      SELECT p.oid, p.prokind
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = pair.sch
    LOOP
      EXECUTE format(
        'ALTER %s %s OWNER TO %I',
        CASE rec.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
        rec.oid::regprocedure,
        pair.own
      );
    END LOOP;
  END LOOP;
END
$$;

SELECT n.nspname AS schema,
       pg_get_userbyid(n.nspowner) AS schema_owner,
       pg_get_userbyid(c.relowner) AS table_owner,
       count(*) FILTER (WHERE c.relkind = 'r') AS tables
FROM pg_namespace n
LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relkind = 'r'
WHERE n.nspname LIKE 'race_%'
GROUP BY 1, 2, 3
ORDER BY 1;

SELECT c.relname, pg_get_userbyid(c.relowner) AS owner
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'race_meta_srv' AND c.relname = 'terms_and_conditions';

\c race_billing
REVOKE CREATE ON DATABASE race_billing FROM race_billing_user;
GRANT USAGE, CREATE ON SCHEMA public TO race_billing_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO race_billing_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO race_billing_user;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO race_billing_user;

DO $$
DECLARE rec record;
BEGIN
  FOR rec IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
      AND pg_get_userbyid(c.relowner) = 'production_db_user'
      AND c.relname NOT LIKE 'pg_%'
      AND NOT (
        c.relkind = 'S' AND EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.objid = c.oid
            AND d.classid = 'pg_class'::regclass
            AND d.refclassid = 'pg_class'::regclass
            AND d.deptype IN ('a', 'i')
        )
      )
  LOOP
    CASE rec.relkind
      WHEN 'S' THEN
        EXECUTE format('ALTER SEQUENCE public.%I OWNER TO race_billing_user', rec.relname);
      WHEN 'v' THEN
        EXECUTE format('ALTER VIEW public.%I OWNER TO race_billing_user', rec.relname);
      WHEN 'm' THEN
        EXECUTE format('ALTER MATERIALIZED VIEW public.%I OWNER TO race_billing_user', rec.relname);
      ELSE
        EXECUTE format('ALTER TABLE public.%I OWNER TO race_billing_user', rec.relname);
    END CASE;
  END LOOP;
END
$$;

\c race_partner
REVOKE CREATE ON DATABASE race_partner FROM race_partner_user;
GRANT USAGE, CREATE ON SCHEMA public TO race_partner_user;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO race_partner_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO race_partner_user;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO race_partner_user;

DO $$
DECLARE rec record;
BEGIN
  FOR rec IN
    SELECT c.relname, c.relkind
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind IN ('r', 'p', 'S', 'v', 'm')
      AND pg_get_userbyid(c.relowner) = 'production_db_user'
      AND c.relname NOT LIKE 'pg_%'
      AND NOT (
        c.relkind = 'S' AND EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.objid = c.oid
            AND d.classid = 'pg_class'::regclass
            AND d.refclassid = 'pg_class'::regclass
            AND d.deptype IN ('a', 'i')
        )
      )
  LOOP
    CASE rec.relkind
      WHEN 'S' THEN
        EXECUTE format('ALTER SEQUENCE public.%I OWNER TO race_partner_user', rec.relname);
      WHEN 'v' THEN
        EXECUTE format('ALTER VIEW public.%I OWNER TO race_partner_user', rec.relname);
      WHEN 'm' THEN
        EXECUTE format('ALTER MATERIALIZED VIEW public.%I OWNER TO race_partner_user', rec.relname);
      ELSE
        EXECUTE format('ALTER TABLE public.%I OWNER TO race_partner_user', rec.relname);
    END CASE;
  END LOOP;
END
$$;
