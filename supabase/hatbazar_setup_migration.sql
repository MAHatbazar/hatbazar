-- ==================== supabase/hatbazar_checkout_v2.sql ====================
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
  ADD COLUMN IF NOT EXISTS reseller_id UUID REFERENCES public.reseller_profiles(id) ON DELETE SET NULL;
-- This function calculates product prices from the database, locks stock rows,
-- writes the order and order_items atomically, and deducts stock only on success.

DROP FUNCTION IF EXISTS public.hatbazar_checkout_v2(TEXT,TEXT,TEXT,TEXT,JSONB,TEXT,TEXT,TEXT,NUMERIC,TEXT);

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
      WHERE rp.id = p_reseller_id
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
  v_old_status TEXT;
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

  SELECT o.order_status INTO v_old_status
  FROM public.orders o
  WHERE o.id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Order not found';
  END IF;

  IF v_old_status = 'cancelled' AND p_order_status IS NOT NULL AND p_order_status <> 'cancelled' THEN
    RAISE EXCEPTION 'A cancelled order cannot be reopened';
  END IF;

  IF p_order_status = 'cancelled' AND v_old_status NOT IN ('cancelled', 'delivered') THEN
    UPDATE public.products p
    SET stock = p.stock + oi.quantity
    FROM public.order_items oi
    WHERE oi.order_id = p_order_id AND oi.product_id = p.id;
  ELSIF p_order_status = 'cancelled' AND v_old_status = 'delivered' THEN
    RAISE EXCEPTION 'A delivered order cannot be cancelled';
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

-- ==================== supabase/hatbazar_reseller_margin.sql ====================
-- Hatbazar reseller margin model: reseller profit is selling_price minus admin-set base_price.
CREATE TABLE IF NOT EXISTS public.reseller_sales (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id UUID NOT NULL REFERENCES public.reseller_profiles(id) ON DELETE CASCADE,
  product_id UUID NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  order_reference TEXT NOT NULL,
  base_price NUMERIC(12,2) NOT NULL CHECK (base_price >= 0),
  selling_price NUMERIC(12,2) NOT NULL CHECK (selling_price >= base_price),
  quantity INTEGER NOT NULL CHECK (quantity > 0 AND quantity <= 1000),
  profit_amount NUMERIC(12,2) NOT NULL CHECK (profit_amount >= 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.reseller_sales ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Resellers view own sales" ON public.reseller_sales;
CREATE POLICY "Resellers view own sales" ON public.reseller_sales
FOR SELECT TO authenticated
USING (reseller_id = auth.uid() OR public.is_admin());

REVOKE ALL ON TABLE public.reseller_sales FROM anon, authenticated;
GRANT SELECT ON TABLE public.reseller_sales TO authenticated;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_catalog()
RETURNS TABLE(product_id UUID, product_name TEXT, product_name_bn TEXT, base_price NUMERIC, stock INTEGER)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.reseller_profiles rp
    WHERE rp.id = auth.uid() AND lower(rp.status) = 'approved'
  ) THEN
    RAISE EXCEPTION 'Only approved resellers can access wholesale prices';
  END IF;

  RETURN QUERY
  SELECT p.id, p.name, p.name_bn, p.base_price, p.stock
  FROM public.products p
  WHERE p.is_active IS TRUE AND p.base_price IS NOT NULL AND p.stock > 0
  ORDER BY p.name;
END;
$function$;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_record_sale(
  p_product_id UUID,
  p_order_reference TEXT,
  p_selling_price NUMERIC,
  p_quantity INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_base_price NUMERIC(12,2);
  v_product_name TEXT;
  v_stock INTEGER;
  v_profit NUMERIC(12,2);
  v_sale_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.reseller_profiles rp
    WHERE rp.id = auth.uid() AND lower(rp.status) = 'approved'
  ) THEN
    RAISE EXCEPTION 'Only approved resellers can record sales';
  END IF;

  IF p_product_id IS NULL OR p_selling_price IS NULL OR p_selling_price <= 0
     OR p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 1000
     OR NULLIF(btrim(p_order_reference), '') IS NULL THEN
    RAISE EXCEPTION 'Invalid reseller sale details';
  END IF;

  SELECT p.base_price, COALESCE(p.name_bn, p.name), p.stock
  INTO v_base_price, v_product_name, v_stock
  FROM public.products p
  WHERE p.id = p_product_id AND p.is_active IS TRUE
  FOR UPDATE;

  IF NOT FOUND OR v_base_price IS NULL THEN
    RAISE EXCEPTION 'Product is not available for reseller sales';
  END IF;
  IF v_stock IS NULL OR v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock for reseller sale. Available: %, requested: %',
      COALESCE(v_stock, 0), p_quantity;
  END IF;
  IF p_selling_price < v_base_price THEN
    RAISE EXCEPTION 'Selling price cannot be below the admin base price';
  END IF;

  v_profit := (p_selling_price - v_base_price) * p_quantity;

  UPDATE public.products
  SET stock = stock - p_quantity
  WHERE id = p_product_id;

  INSERT INTO public.reseller_sales (
    reseller_id, product_id, order_reference, base_price,
    selling_price, quantity, profit_amount
  ) VALUES (
    auth.uid(), p_product_id, btrim(p_order_reference), v_base_price,
    p_selling_price, p_quantity, v_profit
  ) RETURNING id INTO v_sale_id;

  RETURN pg_catalog.jsonb_build_object(
    'success', TRUE, 'sale_id', v_sale_id, 'product_name', v_product_name,
    'base_price', v_base_price, 'selling_price', p_selling_price,
    'quantity', p_quantity, 'profit_amount', v_profit
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_reseller_catalog() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hatbazar_reseller_record_sale(UUID,TEXT,NUMERIC,INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_catalog() TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_record_sale(UUID,TEXT,NUMERIC,INTEGER) TO authenticated;
