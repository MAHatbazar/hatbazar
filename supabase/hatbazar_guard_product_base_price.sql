-- Prevent non-admin sellers or public clients from setting a private wholesale/base price.
CREATE OR REPLACE FUNCTION public.hatbazar_guard_product_base_price()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    NEW.base_price := NULL;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS hatbazar_guard_product_base_price_trigger ON public.products;
CREATE TRIGGER hatbazar_guard_product_base_price_trigger
BEFORE INSERT OR UPDATE OF base_price ON public.products
FOR EACH ROW
EXECUTE FUNCTION public.hatbazar_guard_product_base_price();

REVOKE ALL ON FUNCTION public.hatbazar_guard_product_base_price() FROM PUBLIC, anon, authenticated;
