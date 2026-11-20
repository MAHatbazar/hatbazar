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

-- Persist reseller payout requests and reserve available profit until rejected or paid.
CREATE TABLE IF NOT EXISTS public.reseller_payout_requests (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reseller_id UUID NOT NULL REFERENCES public.reseller_profiles(id) ON DELETE CASCADE,
  payout_method TEXT NOT NULL CHECK (payout_method IN ('bkash', 'nagad', 'bank')),
  payout_account TEXT NOT NULL CHECK (length(btrim(payout_account)) BETWEEN 3 AND 100),
  amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'paid', 'rejected')),
  admin_note TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.reseller_payout_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Resellers view own payout requests" ON public.reseller_payout_requests;
CREATE POLICY "Resellers view own payout requests" ON public.reseller_payout_requests
FOR SELECT TO authenticated
USING (reseller_id = auth.uid() OR public.is_admin());

REVOKE ALL ON TABLE public.reseller_payout_requests FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.reseller_payout_requests TO authenticated;

CREATE OR REPLACE FUNCTION public.hatbazar_reseller_request_payout(
  p_payout_method TEXT,
  p_payout_account TEXT,
  p_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_earned NUMERIC(12,2);
  v_reserved NUMERIC(12,2);
  v_available NUMERIC(12,2);
  v_request_id UUID;
BEGIN
  IF auth.uid() IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.reseller_profiles rp
    WHERE rp.id = auth.uid() AND lower(rp.status) = 'approved'
  ) THEN
    RAISE EXCEPTION 'Only approved resellers can request payouts';
  END IF;

  IF p_payout_method IS NULL OR p_payout_method NOT IN ('bkash', 'nagad', 'bank')
     OR NULLIF(pg_catalog.btrim(p_payout_account), '') IS NULL
     OR pg_catalog.length(pg_catalog.btrim(p_payout_account)) > 100
     OR p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Invalid payout details';
  END IF;

  SELECT COALESCE(SUM(s.profit_amount), 0)
  INTO v_earned
  FROM public.reseller_sales s
  WHERE s.reseller_id = auth.uid();

  SELECT COALESCE(SUM(r.amount), 0)
  INTO v_reserved
  FROM public.reseller_payout_requests r
  WHERE r.reseller_id = auth.uid()
    AND r.status IN ('pending', 'approved', 'paid');

  v_available := v_earned - v_reserved;
  IF p_amount > v_available THEN
    RAISE EXCEPTION 'Insufficient available profit. Available: %', GREATEST(v_available, 0);
  END IF;

  INSERT INTO public.reseller_payout_requests (
    reseller_id, payout_method, payout_account, amount
  ) VALUES (
    auth.uid(), p_payout_method, pg_catalog.btrim(p_payout_account), p_amount
  ) RETURNING id INTO v_request_id;

  RETURN pg_catalog.jsonb_build_object(
    'success', TRUE,
    'request_id', v_request_id,
    'amount', p_amount,
    'available_after_request', v_available - p_amount
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.hatbazar_admin_update_reseller_payout(
  p_request_id UUID,
  p_status TEXT,
  p_admin_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_row public.reseller_payout_requests%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR public.is_admin() IS NOT TRUE THEN
    RAISE EXCEPTION 'Only an authenticated administrator can update payout requests';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('approved', 'paid', 'rejected') THEN
    RAISE EXCEPTION 'Invalid payout status';
  END IF;

  UPDATE public.reseller_payout_requests
  SET status = p_status,
      admin_note = NULLIF(pg_catalog.btrim(COALESCE(p_admin_note, '')), ''),
      updated_at = pg_catalog.now()
  WHERE id = p_request_id
  RETURNING * INTO v_row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Payout request not found';
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'success', TRUE, 'request_id', v_row.id,
    'status', v_row.status, 'amount', v_row.amount
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.hatbazar_reseller_request_payout(TEXT,TEXT,NUMERIC) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.hatbazar_admin_update_reseller_payout(UUID,TEXT,TEXT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.hatbazar_reseller_request_payout(TEXT,TEXT,NUMERIC) TO authenticated;
GRANT EXECUTE ON FUNCTION public.hatbazar_admin_update_reseller_payout(UUID,TEXT,TEXT) TO authenticated, postgres;

