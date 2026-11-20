-- Hatbazar step 10: server-side rate limits for guest checkout and order lookup.
-- Identifiers are SHA-256 hashed; raw mobile numbers are not persisted in the rate table.
CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA private TO postgres;

CREATE TABLE IF NOT EXISTS private.hatbazar_rate_limits (
  scope text NOT NULL,
  key_hash text NOT NULL,
  window_start timestamptz NOT NULL,
  hit_count integer NOT NULL CHECK (hit_count > 0),
  PRIMARY KEY (scope, key_hash, window_start)
);
ALTER TABLE private.hatbazar_rate_limits OWNER TO postgres;
ALTER TABLE private.hatbazar_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.hatbazar_rate_limits FROM PUBLIC, anon, authenticated, service_role;
CREATE INDEX IF NOT EXISTS hatbazar_rate_limits_window_idx ON private.hatbazar_rate_limits (window_start);

CREATE OR REPLACE FUNCTION private.hatbazar_consume_rate_limit(
  p_scope text, p_identifier text, p_max_hits integer, p_window_seconds integer
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $function$
DECLARE v_hash text; v_window_start timestamptz; v_hits integer;
BEGIN
  IF p_scope IS NULL OR p_scope NOT IN ('checkout', 'order_lookup')
     OR p_identifier IS NULL OR pg_catalog.length(p_identifier) < 1
     OR p_max_hits < 1 OR p_window_seconds < 1 OR p_window_seconds > 86400 THEN
    RAISE EXCEPTION 'Invalid rate-limit parameters';
  END IF;
  v_hash := pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to('hatbazar-rate-v1:' || p_scope || ':' || p_identifier, 'UTF8'), 'sha256'),
    'hex'
  );
  v_window_start := pg_catalog.to_timestamp(
    pg_catalog.floor(extract(epoch FROM pg_catalog.clock_timestamp()) / p_window_seconds) * p_window_seconds
  );
  INSERT INTO private.hatbazar_rate_limits (scope, key_hash, window_start, hit_count)
  VALUES (p_scope, v_hash, v_window_start, 1)
  ON CONFLICT (scope, key_hash, window_start)
  DO UPDATE SET hit_count = private.hatbazar_rate_limits.hit_count + 1
  RETURNING hit_count INTO v_hits;
  DELETE FROM private.hatbazar_rate_limits
  WHERE window_start < pg_catalog.clock_timestamp() - INTERVAL '2 days';
  RETURN v_hits <= p_max_hits;
END;
$function$;
ALTER FUNCTION private.hatbazar_consume_rate_limit(text,text,integer,integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.hatbazar_consume_rate_limit(text,text,integer,integer) FROM PUBLIC, anon, authenticated, service_role;

DO $patch$
DECLARE
  c text; l text;
  ca text := $ca$  IF pg_catalog.length(v_phone) <> 11 OR pg_catalog.left(v_phone, 2) <> '01' THEN
    RAISE EXCEPTION 'Invalid Bangladesh mobile number';
  END IF;$ca$;
  cg text := $cg$  IF NOT private.hatbazar_consume_rate_limit('checkout', v_phone, 4, 600) THEN
    RAISE EXCEPTION 'Too many checkout attempts. Please wait 10 minutes before trying again.';
  END IF;$cg$;
  la text := $la$  IF pg_catalog.length(v_phone) <> 11 OR pg_catalog.left(v_phone, 2) <> '01'
     OR pg_catalog.length(v_code) < 20 OR pg_catalog.length(v_code) > 40
     OR v_code !~ '^HB-[0-9]{6}-[A-F0-9]{16}$' THEN
    RETURN pg_catalog.jsonb_build_object('found', FALSE);
  END IF;$la$;
  lg text := $lg$  IF NOT private.hatbazar_consume_rate_limit('order_lookup', v_phone, 10, 600) THEN
    RAISE EXCEPTION 'Too many order lookup attempts. Please wait 10 minutes before trying again.';
  END IF;$lg$;
BEGIN
  SELECT pg_catalog.pg_get_functiondef('public.hatbazar_checkout_v2(text,text,text,text,jsonb,text,text,text,numeric,text,uuid)'::pg_catalog.regprocedure) INTO c;
  SELECT pg_catalog.pg_get_functiondef('public.hatbazar_lookup_order(text,text)'::pg_catalog.regprocedure) INTO l;
  IF pg_catalog.strpos(c, 'Too many checkout attempts') = 0 THEN
    IF pg_catalog.strpos(c, ca) = 0 THEN RAISE EXCEPTION 'Checkout function did not match audited definition'; END IF;
    c := pg_catalog.replace(c, ca, ca || E'\n\n' || cg);
    EXECUTE c;
  END IF;
  IF pg_catalog.strpos(l, 'Too many order lookup attempts') = 0 THEN
    IF pg_catalog.strpos(l, la) = 0 THEN RAISE EXCEPTION 'Order lookup function did not match audited definition'; END IF;
    l := pg_catalog.replace(l, la, la || E'\n\n' || lg);
    EXECUTE l;
  END IF;
END;
$patch$;
