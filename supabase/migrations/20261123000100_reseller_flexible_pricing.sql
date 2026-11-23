-- Hatbazar reseller pricing foundation
-- products.price remains the public Hatbazar retail price.
-- original_cost and facebook_selling_price are intentionally available only through
-- Super Admin RPCs / trusted Edge Functions, never through public product SELECT.

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS original_cost numeric(12,2),
  ADD COLUMN IF NOT EXISTS facebook_selling_price numeric(12,2);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.products'::regclass
      AND conname = 'products_original_cost_nonnegative'
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_original_cost_nonnegative
      CHECK (original_cost IS NULL OR original_cost >= 0);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.products'::regclass
      AND conname = 'products_facebook_selling_price_nonnegative'
  ) THEN
    ALTER TABLE public.products
      ADD CONSTRAINT products_facebook_selling_price_nonnegative
      CHECK (facebook_selling_price IS NULL OR facebook_selling_price >= 0);
  END IF;
END $$;

-- Close the legacy Base Price column exposure. It is no longer the reseller floor.
REVOKE SELECT (base_price) ON public.products FROM anon, authenticated;
REVOKE INSERT (base_price), UPDATE (base_price) ON public.products FROM authenticated;

-- Checkout resolves reseller-specific price on the server. Browser-submitted prices are ignored.
CREATE OR REPLACE FUNCTION public.hatbazar_checkout_v2(p_customer_name text, p_phone text, p_address text, p_payment_method text, p_items jsonb, p_district text, p_upazila text, p_delivery_zone text, p_delivery_fee numeric, p_payment_trx_id text DEFAULT NULL::text, p_reseller_id uuid DEFAULT NULL::uuid)
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
  v_admin_price NUMERIC;
  v_reseller_id UUID;
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

  IF pg_catalog.btrim(p_district) <> ALL (ARRAY['ঢাকা', 'চট্টগ্রাম', 'সিলেট', 'রাজশাহী', 'খুলনা', 'বরিশাল', 'রংপুর', 'ময়মনসিংহ', 'কুমিল্লা', 'গাজীপুর', 'নারায়ণগঞ্জ', 'নরসিংদী', 'মানিকগঞ্জ', 'মুন্সীগঞ্জ', 'ফরিদপুর', 'গোপালগঞ্জ', 'মাদারীপুর', 'রাজবাড়ী', 'শরীয়তপুর', 'কিশোরগঞ্জ', 'টাঙ্গাইল', 'জামালপুর', 'নেত্রকোণা', 'শেরপুর', 'বগুড়া', 'জয়পুরহাট', 'নওগাঁ', 'নাটোর', 'চাঁপাইনবাবগঞ্জ', 'পাবনা', 'সিরাজগঞ্জ', 'দিনাজপুর', 'ঠাকুরগাঁও', 'পঞ্চগড়', 'নীলফামারী', 'লালমনিরহাট', 'কুড়িগ্রাম', 'গাইবান্ধা', 'যশোর', 'কুষ্টিয়া', 'ঝিনাইদহ', 'মাগুরা', 'নড়াইল', 'বাগেরহাট', 'সাতক্ষীরা', 'চুয়াডাঙ্গা', 'মেহেরপুর', 'ভোলা', 'পটুয়াখালী', 'বরগুনা', 'ঝালকাঠি', 'পিরোজপুর', 'ব্রাহ্মণবাড়িয়া', 'চাঁদপুর', 'লক্ষ্মীপুর', 'ফেনী', 'নোয়াখালী', 'কক্সবাজার', 'খাগড়াছড়ি', 'রাঙ্গামাটি', 'বান্দরবান', 'মৌলভীবাজার', 'হবিগঞ্জ', 'সুনামগঞ্জ']::TEXT[]) THEN
    RAISE EXCEPTION 'Unsupported Bangladesh district';
  END IF;

  v_phone := pg_catalog.regexp_replace(pg_catalog.btrim(p_phone), '[^0-9]', '', 'g');
  IF pg_catalog.length(v_phone) <> 11 OR pg_catalog.left(v_phone, 2) <> '01' THEN
    RAISE EXCEPTION 'Invalid Bangladesh mobile number';
  END IF;

  IF NOT private.hatbazar_consume_rate_limit('checkout', v_phone, 4, 600) THEN
    RAISE EXCEPTION 'Too many checkout attempts. Please wait 10 minutes before trying again.';
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
    SELECT rp.id INTO v_reseller_id
    FROM public.reseller_profiles AS rp
    WHERE pg_catalog.lower(rp.status::TEXT) = 'approved'
      AND (
        rp.public_share_token = p_reseller_id
        OR (rp.id = p_reseller_id AND auth.uid() = rp.id)
      );
    IF v_reseller_id IS NULL THEN
      RAISE EXCEPTION 'Reseller share link is invalid or reseller account is not approved';
    END IF;
  END IF;

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
    FROM pg_catalog.jsonb_to_recordset(p_items) AS x(product_id UUID, quantity INTEGER)
    WHERE x.product_id IS NULL OR x.quantity IS NULL OR x.quantity < 1 OR x.quantity > 100
  ) OR EXISTS (
    SELECT 1
    FROM pg_catalog.jsonb_to_recordset(p_items) AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id
    HAVING SUM(x.quantity) > 100
  ) THEN
    RAISE EXCEPTION 'Invalid product or quantity';
  END IF;

  FOR v_item IN
    SELECT x.product_id, SUM(x.quantity)::INTEGER AS quantity
    FROM pg_catalog.jsonb_to_recordset(p_items) AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id
    ORDER BY x.product_id
  LOOP
    SELECT p.name, p.price,
           CASE WHEN v_reseller_id IS NULL THEN p.price ELSE rpp.selling_price END,
           p.stock, p.is_active
      INTO v_product_name, v_admin_price, v_price, v_stock, v_is_active
    FROM public.products AS p
    LEFT JOIN public.reseller_product_prices AS rpp
      ON rpp.product_id = p.id AND rpp.reseller_id = v_reseller_id
    WHERE p.id = v_item.product_id
    FOR UPDATE OF p;

    IF NOT FOUND THEN RAISE EXCEPTION 'Product not found: %', v_item.product_id; END IF;
    IF v_is_active IS NOT TRUE THEN RAISE EXCEPTION 'Product is not available: %', v_product_name; END IF;
    IF v_stock IS NULL OR v_stock < v_item.quantity THEN
      RAISE EXCEPTION 'Insufficient stock for %. Available: %, Requested: %',
        v_product_name, COALESCE(v_stock, 0), v_item.quantity;
    END IF;
    IF v_price IS NULL OR v_price <= 0 THEN
      RAISE EXCEPTION 'Reseller has not set a valid price for: %', v_product_name;
    END IF;
    IF v_reseller_id IS NOT NULL AND v_price < v_admin_price THEN
      RAISE EXCEPTION 'Reseller price is below Hatbazar Selling Price for: %', v_product_name;
    END IF;
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
    CASE WHEN v_reseller_id IS NULL THEN auth.uid() ELSE NULL END,
    v_reseller_id, pg_catalog.btrim(p_customer_name), v_phone, pg_catalog.btrim(p_address),
    v_total, v_payment_method, 'pending', 'pending',
    v_order_code, pg_catalog.btrim(p_district), pg_catalog.btrim(p_upazila), p_delivery_zone,
    v_subtotal, v_delivery_fee, v_trx, FALSE
  )
  RETURNING id INTO v_order_id;

  FOR v_item IN
    SELECT x.product_id, SUM(x.quantity)::INTEGER AS quantity
    FROM pg_catalog.jsonb_to_recordset(p_items) AS x(product_id UUID, quantity INTEGER)
    GROUP BY x.product_id
    ORDER BY x.product_id
  LOOP
    SELECT p.name, p.price,
           CASE WHEN v_reseller_id IS NULL THEN p.price ELSE rpp.selling_price END
      INTO v_product_name, v_base_price, v_price
    FROM public.products AS p
    LEFT JOIN public.reseller_product_prices AS rpp
      ON rpp.product_id = p.id AND rpp.reseller_id = v_reseller_id
    WHERE p.id = v_item.product_id;

    IF v_reseller_id IS NOT NULL THEN
      IF v_price IS NULL OR v_base_price IS NULL OR v_price < v_base_price THEN
        RAISE EXCEPTION 'Reseller price is missing or below Hatbazar Selling Price: %', v_product_name;
      END IF;
      INSERT INTO public.reseller_ledger (reseller_id, order_id, product_id, base_price, selling_price, quantity)
      VALUES (v_reseller_id, v_order_id, v_item.product_id, v_base_price, v_price, v_item.quantity);
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

ALTER TABLE public.reseller_profiles
  ADD COLUMN IF NOT EXISTS public_share_token uuid NOT NULL DEFAULT gen_random_uuid();
CREATE UNIQUE INDEX IF NOT EXISTS reseller_profiles_public_share_token_uidx
  ON public.reseller_profiles(public_share_token);

-- Persistent per-reseller price list used by customer share links.
CREATE TABLE IF NOT EXISTS public.reseller_product_prices (
  reseller_id uuid NOT NULL REFERENCES public.reseller_profiles(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  selling_price numeric(12,2) NOT NULL CHECK (selling_price > 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (reseller_id, product_id)
);
ALTER TABLE public.reseller_product_prices ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.reseller_product_prices FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_set_product_price(
  p_product_id uuid,
  p_selling_price numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $hatbazar_fn_1$
DECLARE
  v_floor numeric(12,2);
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.reseller_profiles rp
    WHERE rp.id = auth.uid() AND lower(rp.status::text) = 'approved'
  ) THEN
    RAISE EXCEPTION 'Only approved resellers can set product prices';
  END IF;
  IF p_product_id IS NULL OR p_selling_price IS NULL OR p_selling_price <= 0 THEN
    RAISE EXCEPTION 'Enter a valid selling price';
  END IF;
  SELECT p.price INTO v_floor
  FROM public.products p
  WHERE p.id = p_product_id AND p.is_active IS TRUE
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Product is not available'; END IF;
  IF p_selling_price < v_floor THEN
    RAISE EXCEPTION 'Reseller price cannot be below Hatbazar Selling Price (৳%)', v_floor;
  END IF;
  INSERT INTO public.reseller_product_prices(reseller_id,product_id,selling_price,updated_at)
  VALUES(auth.uid(),p_product_id,p_selling_price,now())
  ON CONFLICT(reseller_id,product_id) DO UPDATE
  SET selling_price=EXCLUDED.selling_price,updated_at=now();
  RETURN jsonb_build_object('success',true,'product_id',p_product_id,'minimum_price',v_floor,'selling_price',p_selling_price);
END;
$hatbazar_fn_1$;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_public_catalog(p_share_token uuid)
RETURNS TABLE (
  reseller_id uuid,
  product_id uuid,
  product_name text,
  product_name_bn text,
  selling_price numeric,
  stock integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$ 
DECLARE
  v_reseller_id uuid;
BEGIN
  SELECT rp.id INTO v_reseller_id
  FROM public.reseller_profiles rp
  WHERE rp.public_share_token=p_share_token
    AND lower(rp.status::text)='approved';
  IF v_reseller_id IS NULL THEN
    RAISE EXCEPTION 'Reseller share link is invalid or inactive';
  END IF;
  RETURN QUERY
  SELECT v_reseller_id,p.id,p.name,p.name_bn,rpp.selling_price,p.stock
  FROM public.reseller_product_prices rpp
  JOIN public.products p ON p.id=rpp.product_id
  WHERE rpp.reseller_id=v_reseller_id AND p.is_active IS TRUE AND p.stock>0
  ORDER BY p.name;
END;
$$;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_get_share_token()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$ 
DECLARE v_token uuid;
BEGIN
  SELECT rp.public_share_token INTO v_token
  FROM public.reseller_profiles rp
  WHERE rp.id=auth.uid() AND lower(rp.status::text)='approved';
  IF v_token IS NULL THEN RAISE EXCEPTION 'Only approved resellers can create share links'; END IF;
  RETURN v_token;
END;
$$;

CREATE OR REPLACE FUNCTION public.hatbazar_admin_product_pricing()
RETURNS TABLE (
  product_id uuid,
  original_cost numeric,
  selling_price numeric,
  facebook_selling_price numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only the Super Admin can view private product pricing';
  END IF;

  RETURN QUERY
  SELECT p.id, p.original_cost, p.price, p.facebook_selling_price
  FROM public.products AS p;
END;
$$;

CREATE OR REPLACE FUNCTION public.hatbazar_admin_set_product_pricing(
  p_product_id uuid,
  p_original_cost numeric,
  p_selling_price numeric,
  p_facebook_selling_price numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only the Super Admin can change product pricing';
  END IF;
  IF p_product_id IS NULL
     OR p_original_cost IS NOT NULL AND p_original_cost < 0
     OR p_selling_price IS NULL OR p_selling_price < 0
     OR p_facebook_selling_price IS NOT NULL AND p_facebook_selling_price < 0 THEN
    RAISE EXCEPTION 'Invalid product pricing values';
  END IF;

  UPDATE public.products
  SET original_cost = p_original_cost,
      price = p_selling_price,
      facebook_selling_price = p_facebook_selling_price,
      base_price = NULL
  WHERE id = p_product_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found';
  END IF;

  RETURN jsonb_build_object('success', true, 'product_id', p_product_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_pricing_catalog()
RETURNS TABLE (
  product_id uuid,
  product_name text,
  product_name_bn text,
  selling_price numeric,
  facebook_selling_price numeric,
  stock integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.reseller_profiles rp
    WHERE rp.id = auth.uid() AND lower(rp.status) = 'approved'
  ) THEN
    RAISE EXCEPTION 'Only approved resellers can access reseller pricing';
  END IF;

  RETURN QUERY
  SELECT p.id, p.name, p.name_bn, p.price,
         COALESCE(p.facebook_selling_price, p.price), p.stock
  FROM public.products p
  WHERE p.is_active IS TRUE AND p.stock > 0
  ORDER BY p.name;
END;
$$;

-- In reseller manual sales, Hatbazar Selling Price is the minimum.
-- The reseller keeps the difference between their actual selling price and this floor.
-- Keep legacy RPC names safe for cached storefront builds: "base_price" now
-- means the Admin's Selling Price floor, never the private Original Cost.
CREATE OR REPLACE FUNCTION public.hatbazar_reseller_catalog()
RETURNS TABLE (
  product_id uuid,
  product_name text,
  product_name_bn text,
  base_price numeric,
  stock integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $hatbazar_fn_2$
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.reseller_profiles rp
    WHERE rp.id = auth.uid() AND lower(rp.status) = 'approved'
  ) THEN
    RAISE EXCEPTION 'Only approved resellers can access reseller prices';
  END IF;

  RETURN QUERY
  SELECT p.id, p.name, p.name_bn, p.price, p.stock
  FROM public.products p
  WHERE p.is_active IS TRUE AND p.stock > 0
  ORDER BY p.name;
END;
$hatbazar_fn_2$;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_record_sale_v2(
  p_product_id uuid,
  p_order_reference text,
  p_selling_price numeric,
  p_quantity integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_floor_price numeric(12,2);
  v_product_name text;
  v_stock integer;
  v_profit numeric(12,2);
  v_sale_id uuid;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.reseller_profiles rp
    WHERE rp.id = auth.uid() AND lower(rp.status) = 'approved'
  ) THEN
    RAISE EXCEPTION 'Only approved resellers can record sales';
  END IF;

  IF p_product_id IS NULL OR p_selling_price IS NULL OR p_selling_price <= 0
     OR p_quantity IS NULL OR p_quantity < 1 OR p_quantity > 1000
     OR NULLIF(pg_catalog.btrim(p_order_reference), '') IS NULL THEN
    RAISE EXCEPTION 'Invalid reseller sale details';
  END IF;

  SELECT p.price, COALESCE(p.name_bn, p.name), p.stock
  INTO v_floor_price, v_product_name, v_stock
  FROM public.products p
  WHERE p.id = p_product_id AND p.is_active IS TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product is not available for reseller sales';
  END IF;
  IF v_stock IS NULL OR v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock. Available: %, requested: %',
      COALESCE(v_stock, 0), p_quantity;
  END IF;
  IF p_selling_price < v_floor_price THEN
    RAISE EXCEPTION 'Reseller selling price cannot be below Hatbazar Selling Price';
  END IF;

  v_profit := (p_selling_price - v_floor_price) * p_quantity;

  UPDATE public.products SET stock = stock - p_quantity WHERE id = p_product_id;

  INSERT INTO public.reseller_sales (
    reseller_id, product_id, order_reference, base_price,
    selling_price, quantity, profit_amount
  ) VALUES (
    auth.uid(), p_product_id, pg_catalog.btrim(p_order_reference), v_floor_price,
    p_selling_price, p_quantity, v_profit
  ) RETURNING id INTO v_sale_id;

  RETURN pg_catalog.jsonb_build_object(
    'success', TRUE, 'sale_id', v_sale_id, 'product_name', v_product_name,
    'minimum_selling_price', v_floor_price, 'selling_price', p_selling_price,
    'quantity', p_quantity, 'profit_amount', v_profit
  );
END;
$$;

-- Keep the previous sale RPC compatible while changing its floor to
-- the Admin Selling Price rather than the retired Base Price.
CREATE OR REPLACE FUNCTION public.hatbazar_reseller_record_sale(
  p_product_id uuid,
  p_order_reference text,
  p_selling_price numeric,
  p_quantity integer
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $hatbazar_fn_3$
  SELECT public.hatbazar_reseller_record_sale_v2(
    p_product_id, p_order_reference, p_selling_price, p_quantity
  );
$hatbazar_fn_3$;

REVOKE ALL ON FUNCTION public.hatbazar_reseller_set_product_price(uuid,numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_reseller_public_catalog(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_reseller_get_share_token() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_set_product_price(uuid,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_public_catalog(uuid) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_get_share_token() TO authenticated;

-- The Facebook Edge Function uses the service role to read the dedicated post price.
GRANT SELECT (facebook_selling_price) ON public.products TO service_role;

REVOKE ALL ON FUNCTION public.hatbazar_admin_product_pricing() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_admin_set_product_pricing(uuid,numeric,numeric,numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_reseller_pricing_catalog() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_reseller_record_sale_v2(uuid,text,numeric,integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.hatbazar_admin_product_pricing() TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_set_product_pricing(uuid,numeric,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_pricing_catalog() TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_record_sale_v2(uuid,text,numeric,integer) TO authenticated;
