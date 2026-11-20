-- Hatbazar: admin-only order status and payment verification updates
CREATE OR REPLACE FUNCTION public.hatbazar_admin_update_order(
  p_order_id UUID,
  p_order_status TEXT DEFAULT NULL,
  p_payment_verified BOOLEAN DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_status TEXT;
  v_verified BOOLEAN;
  v_payment_status TEXT;
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only an authenticated administrator can update orders';
  END IF;

  IF p_order_status IS NOT NULL AND p_order_status NOT IN (
    'pending', 'pending_verification', 'confirmed', 'processing', 'shipped', 'delivered', 'cancelled'
  ) THEN
    RAISE EXCEPTION 'Invalid order status';
  END IF;

  UPDATE public.orders
  SET
    order_status = COALESCE(p_order_status, order_status),
    payment_verified = COALESCE(p_payment_verified, payment_verified),
    payment_status = CASE
      WHEN p_payment_verified IS TRUE THEN 'paid'
      WHEN p_payment_verified IS FALSE THEN 'pending'
      ELSE payment_status
    END
  WHERE id = p_order_id
  RETURNING order_status, payment_verified, payment_status
  INTO v_status, v_verified, v_payment_status;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'success', TRUE,
    'order_status', v_status,
    'payment_verified', v_verified,
    'payment_status', v_payment_status
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_admin_update_order(UUID,TEXT,BOOLEAN) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_update_order(UUID,TEXT,BOOLEAN) TO authenticated, postgres;
