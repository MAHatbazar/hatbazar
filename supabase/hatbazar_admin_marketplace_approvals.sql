-- Admin review queue and approval controls for real authenticated marketplace accounts.
CREATE OR REPLACE FUNCTION public.hatbazar_admin_list_marketplace_applications()
RETURNS TABLE(user_id UUID, full_name TEXT, phone TEXT, role TEXT, status TEXT, shop_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only administrators can view marketplace applications';
  END IF;

  RETURN QUERY
  SELECT p.id, p.full_name, p.phone, p.role,
         CASE WHEN p.role = 'seller' THEN sp.status ELSE rp.status END::TEXT,
         sp.shop_name
  FROM public.profiles p
  LEFT JOIN public.seller_profiles sp ON sp.id = p.id AND p.role = 'seller'
  LEFT JOIN public.reseller_profiles rp ON rp.id = p.id AND p.role = 'reseller'
  WHERE p.role IN ('seller','reseller')
  ORDER BY p.created_at DESC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.hatbazar_admin_update_marketplace_status(
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
    RAISE EXCEPTION 'Only administrators can approve marketplace accounts';
  END IF;
  IF p_user_id IS NULL OR p_role NOT IN ('seller','reseller') OR p_status NOT IN ('pending','approved','rejected') THEN
    RAISE EXCEPTION 'Invalid marketplace approval request';
  END IF;

  IF p_role = 'seller' THEN
    UPDATE public.seller_profiles SET status = p_status WHERE id = p_user_id;
  ELSE
    UPDATE public.reseller_profiles SET status = p_status WHERE id = p_user_id;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Marketplace application not found';
  END IF;
  RETURN pg_catalog.jsonb_build_object('success',TRUE,'user_id',p_user_id,'role',p_role,'status',p_status);
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_admin_list_marketplace_applications() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_list_marketplace_applications() TO authenticated, postgres;
REVOKE ALL ON FUNCTION public.hatbazar_admin_update_marketplace_status(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_update_marketplace_status(UUID,TEXT,TEXT) TO authenticated, postgres;
