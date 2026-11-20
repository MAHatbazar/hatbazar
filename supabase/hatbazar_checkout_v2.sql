-- Central delivery charges: server-side source of truth.
CREATE TABLE IF NOT EXISTS public.hatbazar_delivery_settings (
  id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  inside_fee NUMERIC(12,2) NOT NULL DEFAULT 80 CHECK (inside_fee >= 0 AND inside_fee <= 5000),
  outside_fee NUMERIC(12,2) NOT NULL DEFAULT 130 CHECK (outside_fee >= 0 AND outside_fee <= 5000),
  inside_eta TEXT NOT NULL DEFAULT '১–৩ কার্যদিবস',
  outside_eta TEXT NOT NULL DEFAULT '২–৫ কার্যদিবস',
  updated_at TIMESTAMPTZ NOT NULL DEFAULT pg_catalog.now()
);

INSERT INTO public.hatbazar_delivery_settings (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.hatbazar_delivery_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.hatbazar_delivery_settings FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.hatbazar_get_delivery_settings()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
  SELECT pg_catalog.jsonb_build_object(
    'inside_fee', s.inside_fee,
    'outside_fee', s.outside_fee,
    'inside_eta', s.inside_eta,
    'outside_eta', s.outside_eta,
    'updated_at', s.updated_at
  )
  FROM public.hatbazar_delivery_settings AS s
  WHERE s.id = 1;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_get_delivery_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hatbazar_get_delivery_settings() TO anon, authenticated, postgres;

CREATE OR REPLACE FUNCTION public.hatbazar_admin_update_delivery_settings(
  p_inside_fee NUMERIC,
  p_outside_fee NUMERIC,
  p_inside_eta TEXT DEFAULT NULL,
  p_outside_eta TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_settings JSONB;
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only an authenticated administrator can update delivery settings';
  END IF;
  IF p_inside_fee IS NULL OR p_outside_fee IS NULL
     OR p_inside_fee < 0 OR p_outside_fee < 0
     OR p_inside_fee > 5000 OR p_outside_fee > 5000 THEN
    RAISE EXCEPTION 'Invalid delivery fee';
  END IF;

  UPDATE public.hatbazar_delivery_settings
  SET inside_fee = p_inside_fee,
      outside_fee = p_outside_fee,
      inside_eta = COALESCE(NULLIF(pg_catalog.btrim(p_inside_eta), ''), inside_eta),
      outside_eta = COALESCE(NULLIF(pg_catalog.btrim(p_outside_eta), ''), outside_eta),
      updated_at = pg_catalog.now()
  WHERE id = 1;

  SELECT public.hatbazar_get_delivery_settings() INTO v_settings;
  RETURN v_settings;
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_admin_update_delivery_settings(NUMERIC,NUMERIC,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_update_delivery_settings(NUMERIC,NUMERIC,TEXT,TEXT) TO authenticated, postgres;

-- Hatbazar production checkout RPC v2
-- Run in Supabase SQL Editor after reviewing the schema.
ALTER TABLE public.orders
  ADD COLUMN IF NOT EXISTS reseller_id UUID REFERENCES public.reseller_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS order_code TEXT,
  ADD COLUMN IF NOT EXISTS district TEXT,
  ADD COLUMN IF NOT EXISTS upazila TEXT,
  ADD COLUMN IF NOT EXISTS delivery_zone TEXT,
  ADD COLUMN IF NOT EXISTS subtotal NUMERIC(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS delivery_fee NUMERIC(12,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS payment_trx_id TEXT,
  ADD COLUMN IF NOT EXISTS payment_verified BOOLEAN NOT NULL DEFAULT FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS orders_order_code_unique_idx
  ON public.orders (order_code)
  WHERE order_code IS NOT NULL;

-- Public storefronts may read gallery URLs for active products.
ALTER TABLE public.product_images ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON TABLE public.product_images TO anon, authenticated;
DROP POLICY IF EXISTS "Public can view gallery images for active products" ON public.product_images;
CREATE POLICY "Public can view gallery images for active products"
ON public.product_images
FOR SELECT TO anon, authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.products p
    WHERE p.id = product_images.product_id AND p.is_active IS TRUE
  )
);
-- This function calculates product prices from the database, locks stock rows,
-- writes the order and order_items atomically, and deducts stock only on success.

DROP FUNCTION IF EXISTS public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT,UUID);

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
  p_payment_trx_id TEXT DEFAULT NULL,
  p_reseller_id UUID DEFAULT NULL
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
  v_base_price NUMERIC;
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

  -- Delivery fee is read from the protected server-side settings row.
  SELECT CASE p_delivery_zone
    WHEN 'inside' THEN s.inside_fee
    WHEN 'outside' THEN s.outside_fee
  END
  INTO v_delivery_fee
  FROM public.hatbazar_delivery_settings AS s
  WHERE s.id = 1;

  IF v_delivery_fee IS NULL THEN
    RAISE EXCEPTION 'Delivery settings are unavailable';
  END IF;

  IF pg_catalog.jsonb_array_length(p_items) > 100 OR EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_to_recordset(p_items)
      AS x(product_id UUID, quantity INTEGER)
    WHERE x.product_id IS NULL OR x.quantity IS NULL OR x.quantity < 1 OR x.quantity > 100
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_to_recordset(p_items)
      AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id
    HAVING SUM(x.quantity) > 100
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
    SELECT p.name, p.price, p.base_price
      INTO v_product_name, v_price, v_base_price
    FROM public.products AS p
    WHERE p.id = v_item.product_id;

    IF p_reseller_id IS NOT NULL THEN
      IF v_base_price IS NULL OR v_base_price < 0 OR v_price < v_base_price THEN
        RAISE EXCEPTION 'Product base price is missing or exceeds selling price: %', v_product_name;
      END IF;
      INSERT INTO public.reseller_ledger (
        reseller_id, order_id, product_id, base_price, selling_price, quantity
      )
      VALUES (
        p_reseller_id, v_order_id, v_item.product_id, v_base_price, v_price, v_item.quantity
      );
    END IF;

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

REVOKE ALL ON FUNCTION public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT,UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT,UUID) TO anon, authenticated, postgres;
