-- Keep products.base_price private from public and normal authenticated clients.
-- Product listing remains available through explicit public columns only.
REVOKE SELECT ON TABLE public.products FROM anon, authenticated;
GRANT SELECT (
  id, category_id, seller_id, name, name_bn, description,
  price, stock, image_url, is_active, created_at
) ON TABLE public.products TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.hatbazar_admin_product_base_prices()
RETURNS TABLE(product_id UUID, base_price NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only an authenticated administrator can view base prices';
  END IF;

  RETURN QUERY
  SELECT p.id, p.base_price
  FROM public.products AS p;
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_admin_product_base_prices() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_product_base_prices() TO authenticated, postgres;
