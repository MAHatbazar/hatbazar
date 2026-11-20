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
