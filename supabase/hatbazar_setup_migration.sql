-- ==================== supabase/hatbazar_checkout_v2.sql ====================
-- Hatbazar production checkout RPC v2
-- Run in Supabase SQL Editor after reviewing the schema.
-- This function calculates product prices from the database, locks stock rows,
-- writes the order and order_items atomically, and deducts stock only on success.

CREATE OR REPLACE FUNCTION public.hatbazar_checkout_v2(
  p_customer_name TEXT,
  p_phone TEXT,
  p_address TEXT,
  p_payment_method TEXT,
  p_items JSONB,
  p_district TEXT,
  p_upazila TEXT,
  p_delivery_zone TEXT,
  p_delivery_fee NUMERIC,
  p_payment_trx_id TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_item RECORD;
  v_product_name TEXT;
  v_price NUMERIC;
  v_stock INTEGER;
  v_is_active BOOLEAN;
  v_subtotal NUMERIC(12,2) := 0;
  v_delivery_fee NUMERIC(12,2);
  v_total NUMERIC(12,2);
  v_order_id UUID;
  v_order_code TEXT;
  v_payment_method TEXT;
  v_phone TEXT;
BEGIN
  IF NULLIF(pg_catalog.btrim(p_customer_name), '') IS NULL
     OR NULLIF(pg_catalog.btrim(p_phone), '') IS NULL
     OR NULLIF(pg_catalog.btrim(p_address), '') IS NULL
     OR NULLIF(pg_catalog.btrim(p_district), '') IS NULL
     OR NULLIF(pg_catalog.btrim(p_upazila), '') IS NULL
  THEN
    RAISE EXCEPTION 'Customer information is incomplete';
  END IF;

  v_phone := pg_catalog.regexp_replace(pg_catalog.btrim(p_phone), '[^0-9]', '', 'g');
  IF pg_catalog.length(v_phone) <> 11 OR pg_catalog.left(v_phone, 2) <> '01' THEN
    RAISE EXCEPTION 'Invalid Bangladesh mobile number';
  END IF;

  IF p_items IS NULL
     OR pg_catalog.jsonb_typeof(p_items) <> 'array'
     OR pg_catalog.jsonb_array_length(p_items) = 0
  THEN
    RAISE EXCEPTION 'Shopping cart is empty';
  END IF;

  v_payment_method := pg_catalog.lower(pg_catalog.btrim(p_payment_method));
  IF v_payment_method IS NULL OR v_payment_method NOT IN ('cod', 'bkash', 'nagad', 'rocket', 'bank') THEN
    RAISE EXCEPTION 'Invalid payment method';
  END IF;

  IF v_payment_method <> 'cod'
     AND NULLIF(pg_catalog.btrim(COALESCE(p_payment_trx_id, '')), '') IS NULL
  THEN
    RAISE EXCEPTION 'Transaction reference is required for online payment';
  END IF;

  IF p_delivery_zone IS NULL OR p_delivery_zone NOT IN ('inside', 'outside') THEN
    RAISE EXCEPTION 'Invalid delivery zone';
  END IF;

  -- Delivery fee is calculated on the server, never trusted from the browser.
  v_delivery_fee := CASE p_delivery_zone
    WHEN 'inside' THEN 80
    WHEN 'outside' THEN 130
    ELSE NULL
  END;

  IF EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_to_recordset(p_items)
      AS x(product_id UUID, quantity INTEGER)
    WHERE x.product_id IS NULL OR x.quantity IS NULL OR x.quantity < 1 OR x.quantity > 100
  ) THEN
    RAISE EXCEPTION 'Invalid product or quantity';
  END IF;

  FOR v_item IN
    SELECT x.product_id, SUM(x.quantity)::INTEGER AS quantity
    FROM pg_catalog.jsonb_to_recordset(p_items)
      AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id
    ORDER BY x.product_id
  LOOP
    SELECT p.name, p.price, p.stock, p.is_active
      INTO v_product_name, v_price, v_stock, v_is_active
    FROM public.products AS p
    WHERE p.id = v_item.product_id
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Product not found: %', v_item.product_id;
    END IF;
    IF v_is_active IS NOT TRUE THEN
      RAISE EXCEPTION 'Product is not available: %', v_product_name;
    END IF;
    IF v_stock IS NULL OR v_stock < v_item.quantity THEN
      RAISE EXCEPTION 'Insufficient stock for %. Available: %, Requested: %',
        v_product_name, COALESCE(v_stock, 0), v_item.quantity;
    END IF;
    IF v_price IS NULL OR v_price < 0 THEN
      RAISE EXCEPTION 'Invalid product price: %', v_product_name;
    END IF;

    v_subtotal := v_subtotal + (v_price * v_item.quantity);
  END LOOP;

  v_total := v_subtotal + v_delivery_fee;
  v_order_code := 'HB-' ||
    pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYMMDD') || '-' ||
    pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(pg_catalog.gen_random_uuid()::TEXT, '-', ''), 1, 6));

  INSERT INTO public.orders (
    customer_id, customer_name, phone, address,
    total_amount, payment_method, payment_status, order_status,
    order_code, district, upazila, delivery_zone,
    subtotal, delivery_fee, payment_trx_id, payment_verified
  )
  VALUES (
    auth.uid(), pg_catalog.btrim(p_customer_name), v_phone, pg_catalog.btrim(p_address),
    v_total, v_payment_method, 'pending', 'pending',
    v_order_code, pg_catalog.btrim(p_district), pg_catalog.btrim(p_upazila), p_delivery_zone,
    v_subtotal, v_delivery_fee, NULLIF(pg_catalog.btrim(COALESCE(p_payment_trx_id, '')), ''), FALSE
  )
  RETURNING id INTO v_order_id;

  FOR v_item IN
    SELECT x.product_id, SUM(x.quantity)::INTEGER AS quantity
    FROM pg_catalog.jsonb_to_recordset(p_items)
      AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id
    ORDER BY x.product_id
  LOOP
    SELECT p.name, p.price
      INTO v_product_name, v_price
    FROM public.products AS p
    WHERE p.id = v_item.product_id;

    INSERT INTO public.order_items (
      order_id, product_id, product_name, quantity, unit_price
    )
    VALUES (
      v_order_id, v_item.product_id, v_product_name, v_item.quantity, v_price
    );

    UPDATE public.products
      SET stock = stock - v_item.quantity
    WHERE id = v_item.product_id;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'success', TRUE,
    'order_id', v_order_id,
    'order_code', v_order_code,
    'subtotal', v_subtotal,
    'delivery_fee', v_delivery_fee,
    'total_amount', v_total,
    'created_at', pg_catalog.clock_timestamp(),
    'items', (
      SELECT COALESCE(
        pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'product_id', oi.product_id,
          'product_name', oi.product_name,
          'quantity', oi.quantity,
          'unit_price', oi.unit_price
        )),
        '[]'::JSONB
      )
      FROM public.order_items AS oi
      WHERE oi.order_id = v_order_id
    ),
    'message', 'Order created successfully'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT) TO anon, authenticated, postgres;

-- ==================== supabase/hatbazar_admin_update_order.sql ====================
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

-- ==================== supabase/hatbazar_private_base_prices.sql ====================
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

-- ==================== supabase/hatbazar_guard_product_base_price.sql ====================
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
