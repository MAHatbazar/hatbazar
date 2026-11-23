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
AS $
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
$;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_public_catalog(p_reseller_id uuid)
RETURNS TABLE (
  product_id uuid,
  product_name text,
  product_name_bn text,
  selling_price numeric,
  stock integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $
BEGIN
  IF p_reseller_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.reseller_profiles rp
    WHERE rp.id=p_reseller_id AND lower(rp.status::text)='approved'
  ) THEN
    RAISE EXCEPTION 'Reseller share link is invalid or inactive';
  END IF;
  RETURN QUERY
  SELECT p.id,p.name,p.name_bn,rpp.selling_price,p.stock
  FROM public.reseller_product_prices rpp
  JOIN public.products p ON p.id=rpp.product_id
  WHERE rpp.reseller_id=p_reseller_id AND p.is_active IS TRUE AND p.stock>0
  ORDER BY p.name;
END;
$;

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
AS $
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
$;

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
AS $
  SELECT public.hatbazar_reseller_record_sale_v2(
    p_product_id, p_order_reference, p_selling_price, p_quantity
  );
$;

REVOKE ALL ON FUNCTION public.hatbazar_reseller_set_product_price(uuid,numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_reseller_public_catalog(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_set_product_price(uuid,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_public_catalog(uuid) TO anon, authenticated;

REVOKE ALL ON FUNCTION public.hatbazar_admin_product_pricing() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_admin_set_product_pricing(uuid,numeric,numeric,numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_reseller_pricing_catalog() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hatbazar_reseller_record_sale_v2(uuid,text,numeric,integer) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.hatbazar_admin_product_pricing() TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_set_product_pricing(uuid,numeric,numeric,numeric) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_pricing_catalog() TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_record_sale_v2(uuid,text,numeric,integer) TO authenticated;
