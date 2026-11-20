-- Allow authenticated resellers to view only orders and items attributed to their account.
DROP POLICY IF EXISTS "Resellers view own attributed orders" ON public.orders;
CREATE POLICY "Resellers view own attributed orders"
ON public.orders
FOR SELECT TO authenticated
USING (reseller_id = auth.uid());

DROP POLICY IF EXISTS "Resellers view own attributed order items" ON public.order_items;
CREATE POLICY "Resellers view own attributed order items"
ON public.order_items
FOR SELECT TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM public.orders o
    WHERE o.id = order_items.order_id
      AND o.reseller_id = auth.uid()
  )
);

-- Keep a single reseller-ledger read policy covering owner and administrator access.
ALTER TABLE public.reseller_ledger ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.reseller_ledger FROM PUBLIC, anon;
GRANT SELECT ON TABLE public.reseller_ledger TO authenticated;
DROP POLICY IF EXISTS "Admin views all reseller earnings" ON public.reseller_ledger;
DROP POLICY IF EXISTS "Reseller views own earnings" ON public.reseller_ledger;
DROP POLICY IF EXISTS "Resellers view own reseller ledger" ON public.reseller_ledger;
CREATE POLICY "Resellers view own reseller ledger"
ON public.reseller_ledger
FOR SELECT TO authenticated
USING (reseller_id = (SELECT auth.uid()) OR public.is_admin());
