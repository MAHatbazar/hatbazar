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
  SET full_name = EXCLUDED.full_name, phone = EXCLUDED.phone, role = EXCLUDED.role;

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

CREATE OR REPLACE FUNCTION public.hatbazar_admin_list_partner_applications()
RETURNS TABLE(
  user_id UUID,
  full_name TEXT,
  phone TEXT,
  role TEXT,
  shop_name TEXT,
  status TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only an administrator can view partner applications';
  END IF;

  RETURN QUERY
  SELECT x.user_id, x.full_name, x.phone, x.role, x.shop_name, x.status, x.created_at
  FROM (
    SELECT sp.id AS user_id, p.full_name, p.phone, 'seller'::TEXT AS role,
           sp.shop_name, sp.status, p.created_at
    FROM public.seller_profiles sp
    JOIN public.profiles p ON p.id = sp.id
    UNION ALL
    SELECT rp.id AS user_id, p.full_name, p.phone, 'reseller'::TEXT AS role,
           p.full_name AS shop_name, rp.status, p.created_at
    FROM public.reseller_profiles rp
    JOIN public.profiles p ON p.id = rp.id
  ) AS x
  ORDER BY x.created_at DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.hatbazar_admin_update_partner_status(
  p_user_id UUID,
  p_role TEXT,
  p_status TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only an administrator can update partner applications';
  END IF;
  IF p_user_id IS NULL OR p_role IS NULL OR p_role NOT IN ('seller', 'reseller')
     OR p_status IS NULL OR p_status NOT IN ('pending', 'approved', 'rejected') THEN
    RAISE EXCEPTION 'Invalid partner status update';
  END IF;

  IF p_role = 'seller' THEN
    UPDATE public.seller_profiles SET status = p_status WHERE id = p_user_id;
  ELSE
    UPDATE public.reseller_profiles SET status = p_status WHERE id = p_user_id;
  END IF;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Partner profile not found';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'success', TRUE, 'user_id', p_user_id, 'role', p_role, 'status', p_status
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_admin_list_partner_applications() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hatbazar_admin_update_partner_status(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_list_partner_applications() TO authenticated, postgres;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_update_partner_status(UUID,TEXT,TEXT) TO authenticated, postgres;

