-- Allow approved sellers to upload and manage only their own product image objects.
DROP POLICY IF EXISTS "Approved sellers upload product images" ON storage.objects;
CREATE POLICY "Approved sellers upload product images"
ON storage.objects
FOR INSERT TO authenticated
WITH CHECK (
  bucket_id = 'product-images'
  AND EXISTS (
    SELECT 1 FROM public.seller_profiles sp
    WHERE sp.id = auth.uid() AND lower(sp.status) = 'approved'
  )
);

DROP POLICY IF EXISTS "Approved sellers update own product images" ON storage.objects;
CREATE POLICY "Approved sellers update own product images"
ON storage.objects
FOR UPDATE TO authenticated
USING (
  bucket_id = 'product-images'
  AND owner_id = auth.uid()::TEXT
  AND EXISTS (
    SELECT 1 FROM public.seller_profiles sp
    WHERE sp.id = auth.uid() AND lower(sp.status) = 'approved'
  )
)
WITH CHECK (
  bucket_id = 'product-images'
  AND owner_id = auth.uid()::TEXT
  AND EXISTS (
    SELECT 1 FROM public.seller_profiles sp
    WHERE sp.id = auth.uid() AND lower(sp.status) = 'approved'
  )
);

DROP POLICY IF EXISTS "Approved sellers delete own product images" ON storage.objects;
CREATE POLICY "Approved sellers delete own product images"
ON storage.objects
FOR DELETE TO authenticated
USING (
  bucket_id = 'product-images'
  AND owner_id = auth.uid()::TEXT
  AND EXISTS (
    SELECT 1 FROM public.seller_profiles sp
    WHERE sp.id = auth.uid() AND lower(sp.status) = 'approved'
  )
);
