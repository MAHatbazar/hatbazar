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
  IF v_payment_method NOT IN ('cod', 'bkash', 'nagad', 'rocket', 'bank') THEN
    RAISE EXCEPTION 'Invalid payment method';
  END IF;

  IF v_payment_method <> 'cod'
     AND NULLIF(pg_catalog.btrim(COALESCE(p_payment_trx_id, '')), '') IS NULL
  THEN
    RAISE EXCEPTION 'Transaction reference is required for online payment';
  END IF;

  IF p_delivery_zone NOT IN ('inside', 'outside') THEN
    RAISE EXCEPTION 'Invalid delivery zone';
  END IF;

  v_delivery_fee := COALESCE(p_delivery_fee, -1);
  IF v_delivery_fee < 0 OR v_delivery_fee > 5000 THEN
    RAISE EXCEPTION 'Invalid delivery fee';
  END IF;

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
    'message', 'Order created successfully'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT) TO anon, authenticated, postgres;
