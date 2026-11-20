-- Enforce seller approval at the database boundary.
-- Existing permissive seller policies remain, but these restrictive policies
-- require an approved seller profile for product writes.
DROP POLICY IF EXISTS "Approved sellers only insert products" ON public.products;
CREATE POLICY "Approved sellers only insert products"
ON public.products AS RESTRICTIVE
FOR INSERT TO authenticated
WITH CHECK (
  public.is_admin()
  OR (
    seller_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.seller_profiles sp
      WHERE sp.id = auth.uid() AND lower(sp.status) = 'approved'
    )
  )
);

DROP POLICY IF EXISTS "Approved sellers only update products" ON public.products;
CREATE POLICY "Approved sellers only update products"
ON public.products AS RESTRICTIVE
FOR UPDATE TO authenticated
USING (
  public.is_admin()
  OR (
    seller_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.seller_profiles sp
      WHERE sp.id = auth.uid() AND lower(sp.status) = 'approved'
    )
  )
)
WITH CHECK (
  public.is_admin()
  OR (
    seller_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.seller_profiles sp
      WHERE sp.id = auth.uid() AND lower(sp.status) = 'approved'
    )
  )
);

DROP POLICY IF EXISTS "Approved sellers only delete products" ON public.products;
CREATE POLICY "Approved sellers only delete products"
ON public.products AS RESTRICTIVE
FOR DELETE TO authenticated
USING (
  public.is_admin()
  OR (
    seller_id = auth.uid()
    AND EXISTS (
      SELECT 1 FROM public.seller_profiles sp
      WHERE sp.id = auth.uid() AND lower(sp.status) = 'approved'
    )
  )
);
