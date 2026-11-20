-- Step 8 security audit: remove the legacy seller policy.
-- PostgreSQL combines permissive policies with OR. This older policy allowed
-- any profile with role=seller to manage owned products, even when seller_profiles.status
-- was not approved. The approved-seller policies remain authoritative.
DROP POLICY IF EXISTS "Sellers manage own products" ON public.products;
