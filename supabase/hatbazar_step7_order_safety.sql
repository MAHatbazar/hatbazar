-- Hatbazar step 7: checkout safety and guest order tracking.
-- Apply after hatbazar_checkout_v2.sql / the consolidated setup migration.

-- Keep the original unique order-code index; remove the redundant duplicate
-- introduced during the live hardening pass.
DROP INDEX IF EXISTS public.orders_order_code_unique_idx;

CREATE OR REPLACE FUNCTION public.hatbazar_checkout_v2(
  p_customer_name text, p_phone text, p_address text, p_payment_method text,
  p_items jsonb, p_district text, p_upazila text, p_delivery_zone text,
  p_delivery_fee numeric, p_payment_trx_id text DEFAULT NULL::text,
  p_reseller_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_item RECORD;
  v_product_name TEXT;
  v_price NUMERIC;
  v_stock INTEGER;
  v_base_price NUMERIC;
  v_is_active BOOLEAN;
  v_subtotal NUMERIC(12,2) := 0;
  v_delivery_fee NUMERIC(12,2);
  v_total NUMERIC(12,2);
  v_order_id UUID;
  v_order_code TEXT;
  v_payment_method TEXT;
  v_phone TEXT;
  v_expected_zone TEXT;
  v_trx TEXT;
BEGIN
  IF NULLIF(pg_catalog.btrim(p_customer_name), '') IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_customer_name)) > 120
     OR NULLIF(pg_catalog.btrim(p_phone), '') IS NULL
     OR NULLIF(pg_catalog.btrim(p_address), '') IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_address)) > 500
     OR NULLIF(pg_catalog.btrim(p_district), '') IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_district)) > 100
     OR NULLIF(pg_catalog.btrim(p_upazila), '') IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_upazila)) > 100
  THEN
    RAISE EXCEPTION 'Customer information is incomplete or too long';
  END IF;

  v_phone := pg_catalog.regexp_replace(pg_catalog.btrim(p_phone), '[^0-9]', '', 'g');
  IF pg_catalog.length(v_phone) <> 11 OR pg_catalog.left(v_phone, 2) <> '01' THEN
    RAISE EXCEPTION 'Invalid Bangladesh mobile number';
  END IF;

  IF p_items IS NULL OR pg_catalog.jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Shopping cart must be a valid array';
  END IF;
  IF pg_catalog.jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'Shopping cart is empty';
  END IF;

  v_payment_method := pg_catalog.lower(pg_catalog.btrim(p_payment_method));
  IF v_payment_method IS NULL OR v_payment_method NOT IN ('cod', 'bkash', 'nagad', 'rocket', 'bank') THEN
    RAISE EXCEPTION 'Invalid payment method';
  END IF;

  v_trx := NULLIF(pg_catalog.btrim(COALESCE(p_payment_trx_id, '')), '');
  IF v_payment_method <> 'cod' THEN
    IF v_trx IS NULL OR pg_catalog.length(v_trx) < 4 OR pg_catalog.length(v_trx) > 120
       OR v_trx ~ '[[:cntrl:]]' THEN
      RAISE EXCEPTION 'A valid transaction reference is required for online payment';
    END IF;
  ELSIF v_trx IS NOT NULL AND (pg_catalog.length(v_trx) > 120 OR v_trx ~ '[[:cntrl:]]') THEN
    RAISE EXCEPTION 'Invalid transaction reference';
  END IF;

  IF p_delivery_zone IS NULL OR p_delivery_zone NOT IN ('inside', 'outside') THEN
    RAISE EXCEPTION 'Invalid delivery zone';
  END IF;

  v_expected_zone := CASE
    WHEN pg_catalog.btrim(p_district) = 'ঢাকা'
      AND pg_catalog.btrim(p_upazila) IN ('ঢাকা উত্তর', 'ঢাকা দক্ষিণ', 'ধানমন্ডি', 'গুলশান', 'মিরপুর', 'উত্তরা', 'মোহাম্মদপুর')
    THEN 'inside'
    ELSE 'outside'
  END;
  IF p_delivery_zone <> v_expected_zone THEN
    RAISE EXCEPTION 'Delivery zone does not match the selected district and area';
  END IF;

  IF p_reseller_id IS NOT NULL THEN
    IF auth.uid() IS NULL OR auth.uid() <> p_reseller_id THEN
      RAISE EXCEPTION 'Reseller identity does not match the signed-in account';
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.reseller_profiles AS rp
      WHERE rp.id = p_reseller_id AND pg_catalog.lower(rp.status::TEXT) = 'approved'
    ) THEN
      RAISE EXCEPTION 'Reseller account is not approved';
    END IF;
  END IF;

  -- The submitted client fee is ignored; only this protected setting is used.
  SELECT CASE p_delivery_zone WHEN 'inside' THEN s.inside_fee ELSE s.outside_fee END
  INTO v_delivery_fee
  FROM public.hatbazar_delivery_settings AS s
  WHERE s.id = 1;
  IF v_delivery_fee IS NULL THEN
    RAISE EXCEPTION 'Delivery settings are unavailable';
  END IF;

  IF pg_catalog.jsonb_array_length(p_items) > 100 OR EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_items) AS x(product_id UUID, quantity INTEGER)
    WHERE x.product_id IS NULL OR x.quantity IS NULL OR x.quantity < 1 OR x.quantity > 100
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_items) AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id HAVING SUM(x.quantity) > 100
  ) THEN
    RAISE EXCEPTION 'Invalid product or quantity';
  END IF;

  FOR v_item IN
    SELECT x.product_id, SUM(x.quantity)::INTEGER AS quantity
    FROM pg_catalog.jsonb_to_recordset(p_items) AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id ORDER BY x.product_id
  LOOP
    SELECT p.name, p.price, p.stock, p.is_active
    INTO v_product_name, v_price, v_stock, v_is_active
    FROM public.products AS p WHERE p.id = v_item.product_id FOR UPDATE;

    IF NOT FOUND THEN RAISE EXCEPTION 'Product not found: %', v_item.product_id; END IF;
    IF v_is_active IS NOT TRUE THEN RAISE EXCEPTION 'Product is not available: %', v_product_name; END IF;
    IF v_stock IS NULL OR v_stock < v_item.quantity THEN
      RAISE EXCEPTION 'Insufficient stock for %. Available: %, Requested: %',
        v_product_name, COALESCE(v_stock, 0), v_item.quantity;
    END IF;
    IF v_price IS NULL OR v_price < 0 THEN RAISE EXCEPTION 'Invalid product price: %', v_product_name; END IF;
    v_subtotal := v_subtotal + (v_price * v_item.quantity);
  END LOOP;

  v_total := v_subtotal + v_delivery_fee;
  v_order_code := 'HB-' ||
    pg_catalog.to_char(pg_catalog.clock_timestamp(), 'YYMMDD') || '-' ||
    pg_catalog.upper(pg_catalog.substr(pg_catalog.replace(pg_catalog.gen_random_uuid()::TEXT, '-', ''), 1, 16));

  INSERT INTO public.orders (
    customer_id, reseller_id, customer_name, phone, address,
    total_amount, payment_method, payment_status, order_status,
    order_code, district, upazila, delivery_zone,
    subtotal, delivery_fee, payment_trx_id, payment_verified
  )
  VALUES (
    CASE WHEN p_reseller_id IS NULL THEN auth.uid() ELSE NULL END,
    p_reseller_id, pg_catalog.btrim(p_customer_name), v_phone, pg_catalog.btrim(p_address),
    v_total, v_payment_method, 'pending', 'pending',
    v_order_code, pg_catalog.btrim(p_district), pg_catalog.btrim(p_upazila), p_delivery_zone,
    v_subtotal, v_delivery_fee, v_trx, FALSE
  )
  RETURNING id INTO v_order_id;

  FOR v_item IN
    SELECT x.product_id, SUM(x.quantity)::INTEGER AS quantity
    FROM pg_catalog.jsonb_to_recordset(p_items) AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id ORDER BY x.product_id
  LOOP
    SELECT p.name, p.price, p.base_price INTO v_product_name, v_price, v_base_price
    FROM public.products AS p WHERE p.id = v_item.product_id;

    IF p_reseller_id IS NOT NULL THEN
      IF v_base_price IS NULL OR v_base_price < 0 OR v_price < v_base_price THEN
        RAISE EXCEPTION 'Product base price is missing or exceeds selling price: %', v_product_name;
      END IF;
      INSERT INTO public.reseller_ledger (reseller_id, order_id, product_id, base_price, selling_price, quantity)
      VALUES (p_reseller_id, v_order_id, v_item.product_id, v_base_price, v_price, v_item.quantity);
    END IF;

    INSERT INTO public.order_items (order_id, product_id, product_name, quantity, unit_price)
    VALUES (v_order_id, v_item.product_id, v_product_name, v_item.quantity, v_price);

    UPDATE public.products SET stock = stock - v_item.quantity WHERE id = v_item.product_id;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'success', TRUE, 'order_id', v_order_id, 'order_code', v_order_code,
    'subtotal', v_subtotal, 'delivery_fee', v_delivery_fee, 'total_amount', v_total,
    'created_at', pg_catalog.clock_timestamp(),
    'items', (
      SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'product_id', oi.product_id, 'product_name', oi.product_name,
        'quantity', oi.quantity, 'unit_price', oi.unit_price
      )), '[]'::JSONB)
      FROM public.order_items AS oi WHERE oi.order_id = v_order_id
    ),
    'message', 'Order created successfully'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT,UUID) TO anon, authenticated, postgres;

-- Public order lookup requires both a 64-bit random order code and its checkout phone.
-- It returns only status, payment state, line-item names/quantities, and total.
CREATE OR REPLACE FUNCTION public.hatbazar_lookup_order(p_order_code text, p_phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_phone text;
  v_code text;
  v_result jsonb;
BEGIN
  v_phone := pg_catalog.regexp_replace(pg_catalog.btrim(COALESCE(p_phone, '')), '[^0-9]', '', 'g');
  v_code := pg_catalog.upper(pg_catalog.btrim(COALESCE(p_order_code, '')));
  IF pg_catalog.length(v_phone) <> 11 OR pg_catalog.left(v_phone, 2) <> '01'
     OR pg_catalog.length(v_code) < 20 OR pg_catalog.length(v_code) > 40
     OR v_code !~ '^HB-[0-9]{6}-[A-F0-9]{16}$' THEN
    RETURN pg_catalog.jsonb_build_object('found', FALSE);
  END IF;

  SELECT pg_catalog.jsonb_build_object(
    'found', TRUE, 'order_code', o.order_code,
    'order_status', o.order_status, 'payment_status', o.payment_status,
    'total_amount', o.total_amount, 'created_at', o.created_at,
    'items', COALESCE((
      SELECT pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'product_name', oi.product_name, 'quantity', oi.quantity
      ) ORDER BY oi.created_at)
      FROM public.order_items oi WHERE oi.order_id = o.id
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM public.orders o
  WHERE o.order_code = v_code
    AND pg_catalog.regexp_replace(o.phone, '[^0-9]', '', 'g') = v_phone
  LIMIT 1;

  RETURN COALESCE(v_result, pg_catalog.jsonb_build_object('found', FALSE));
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_lookup_order(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hatbazar_lookup_order(text, text) TO anon, authenticated;
