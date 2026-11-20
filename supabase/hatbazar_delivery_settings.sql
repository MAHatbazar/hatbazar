-- Hatbazar delivery fees: centrally stored and enforced by the checkout RPC.
CREATE TABLE IF NOT EXISTS public.hatbazar_delivery_settings (
  id BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id IS TRUE),
  inside_fee NUMERIC(10,2) NOT NULL DEFAULT 80 CHECK (inside_fee >= 0 AND inside_fee <= 5000),
  outside_fee NUMERIC(10,2) NOT NULL DEFAULT 130 CHECK (outside_fee >= 0 AND outside_fee <= 5000),
  inside_eta TEXT NOT NULL DEFAULT '১–৩ কার্যদিবস',
  outside_eta TEXT NOT NULL DEFAULT '২–৫ কার্যদিবস',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.hatbazar_delivery_settings (id) VALUES (TRUE)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.hatbazar_delivery_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.hatbazar_delivery_settings FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.hatbazar_get_delivery_settings()
RETURNS JSONB
LANGUAGE SQL
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT pg_catalog.jsonb_build_object(
    'inside_fee', inside_fee,
    'outside_fee', outside_fee,
    'inside_eta', inside_eta,
    'outside_eta', outside_eta
  )
  FROM public.hatbazar_delivery_settings
  WHERE id IS TRUE;
$function$;

CREATE OR REPLACE FUNCTION public.hatbazar_admin_update_delivery_settings(
  p_inside_fee NUMERIC,
  p_outside_fee NUMERIC,
  p_inside_eta TEXT,
  p_outside_eta TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_result JSONB;
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only an authenticated administrator can update delivery settings';
  END IF;
  IF p_inside_fee IS NULL OR p_outside_fee IS NULL
     OR p_inside_fee < 0 OR p_outside_fee < 0
     OR p_inside_fee > 5000 OR p_outside_fee > 5000
     OR NULLIF(btrim(p_inside_eta), '') IS NULL
     OR NULLIF(btrim(p_outside_eta), '') IS NULL THEN
    RAISE EXCEPTION 'Invalid delivery settings';
  END IF;

  INSERT INTO public.hatbazar_delivery_settings (
    id, inside_fee, outside_fee, inside_eta, outside_eta, updated_at
  ) VALUES (
    TRUE, p_inside_fee, p_outside_fee, btrim(p_inside_eta), btrim(p_outside_eta), now()
  )
  ON CONFLICT (id) DO UPDATE SET
    inside_fee = EXCLUDED.inside_fee,
    outside_fee = EXCLUDED.outside_fee,
    inside_eta = EXCLUDED.inside_eta,
    outside_eta = EXCLUDED.outside_eta,
    updated_at = now();

  SELECT pg_catalog.jsonb_build_object(
    'inside_fee', inside_fee, 'outside_fee', outside_fee,
    'inside_eta', inside_eta, 'outside_eta', outside_eta
  ) INTO v_result
  FROM public.hatbazar_delivery_settings WHERE id IS TRUE;
  RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_get_delivery_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hatbazar_get_delivery_settings() TO anon, authenticated, postgres;
REVOKE ALL ON FUNCTION public.hatbazar_admin_update_delivery_settings(NUMERIC,NUMERIC,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_update_delivery_settings(NUMERIC,NUMERIC,TEXT,TEXT) TO authenticated, postgres;
