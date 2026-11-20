-- Secure Supabase Auth profile registration for seller and reseller accounts.
CREATE OR REPLACE FUNCTION public.hatbazar_register_marketplace_profile(
  p_full_name TEXT,
  p_phone TEXT,
  p_role TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_existing_role TEXT;
  v_phone TEXT;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sign in is required';
  END IF;
  IF NULLIF(pg_catalog.btrim(p_full_name), '') IS NULL THEN
    RAISE EXCEPTION 'Full name is required';
  END IF;
  IF p_role NOT IN ('seller', 'reseller') THEN
    RAISE EXCEPTION 'Invalid marketplace role';
  END IF;

  v_phone := pg_catalog.regexp_replace(pg_catalog.btrim(COALESCE(p_phone, '')), '[^0-9]', '', 'g');
  IF pg_catalog.length(v_phone) <> 11 OR pg_catalog.left(v_phone, 2) <> '01' THEN
    RAISE EXCEPTION 'A valid Bangladesh mobile number is required';
  END IF;

  SELECT p.role INTO v_existing_role
  FROM public.profiles p
  WHERE p.id = auth.uid();

  IF v_existing_role IS NOT NULL AND v_existing_role NOT IN (p_role, 'customer') THEN
    RAISE EXCEPTION 'This account already has a different role';
  END IF;

  INSERT INTO public.profiles (id, full_name, phone, role)
  VALUES (auth.uid(), pg_catalog.btrim(p_full_name), v_phone, p_role)
  ON CONFLICT (id) DO UPDATE
  SET full_name = EXCLUDED.full_name, phone = EXCLUDED.phone;

  IF p_role = 'seller' THEN
    INSERT INTO public.seller_profiles (id, shop_name, status)
    VALUES (auth.uid(), pg_catalog.btrim(p_full_name), 'pending')
    ON CONFLICT (id) DO NOTHING;
  ELSE
    INSERT INTO public.reseller_profiles (id, status)
    VALUES (auth.uid(), 'pending')
    ON CONFLICT (id) DO NOTHING;
  END IF;

  RETURN pg_catalog.jsonb_build_object('success', TRUE, 'role', p_role, 'status', 'pending');
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_register_marketplace_profile(TEXT,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_register_marketplace_profile(TEXT,TEXT,TEXT) TO authenticated;
