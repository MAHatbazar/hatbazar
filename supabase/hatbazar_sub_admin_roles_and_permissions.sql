-- Hatbazar Super Admin / Sub Admin permissions
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role = any (array['admin','sub_admin','sub_admin_disabled','seller','reseller','customer']::text[]));

create or replace function public.is_staff()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles where id=(select auth.uid()) and role in ('admin','sub_admin'));
$$;
revoke all on function public.is_staff() from public;
grant execute on function public.is_staff() to authenticated;

create or replace function public.hatbazar_guard_product_base_price()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if (select auth.uid()) is null or not public.is_admin() then
    if tg_op='UPDATE' then new.base_price:=old.base_price; else new.base_price:=null; end if;
  end if;
  return new;
end;
$$;

drop policy if exists "Admin manages categories" on public.categories;
create policy "Staff manages categories" on public.categories for all to authenticated
using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "Admin manages products" on public.products;
create policy "Staff manages products" on public.products for all to authenticated
using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "Admin manages product images" on public.product_images;
create policy "Staff manages product images" on public.product_images for all to authenticated
using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "Admin manages all orders" on public.orders;
create policy "Staff views all orders" on public.orders for select to authenticated using ((select public.is_staff()));
create policy "Staff updates all orders" on public.orders for update to authenticated
using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "Admin manages all order items" on public.order_items;
create policy "Staff views all order items" on public.order_items for select to authenticated using ((select public.is_staff()));
drop policy if exists "Admin views all profiles" on public.profiles;
create policy "Staff views all profiles" on public.profiles for select to authenticated using ((select public.is_staff()));
drop policy if exists "Admin manages seller profiles" on public.seller_profiles;
create policy "Staff manages seller profiles" on public.seller_profiles for all to authenticated
using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "Admin manages reseller profiles" on public.reseller_profiles;
create policy "Staff manages reseller profiles" on public.reseller_profiles for all to authenticated
using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "Admins manage product supplier sources" on public.product_supplier_sources;
create policy "Staff manages product supplier sources" on public.product_supplier_sources for all to authenticated
using ((select public.is_staff())) with check ((select public.is_staff()));
drop policy if exists "Admins manage supplier order submissions" on public.supplier_order_submissions;
create policy "Staff manages supplier order submissions" on public.supplier_order_submissions for all to authenticated
using ((select public.is_staff())) with check ((select public.is_staff()));

drop policy if exists "Admins create own Hatbazar AI jobs" on public.hatbazar_ai_jobs;
create policy "Staff create own Hatbazar AI jobs" on public.hatbazar_ai_jobs for insert to authenticated
with check (public.is_staff() and created_by=(select auth.uid()));
drop policy if exists "Admins view own Hatbazar AI jobs" on public.hatbazar_ai_jobs;
create policy "Staff view own Hatbazar AI jobs" on public.hatbazar_ai_jobs for select to authenticated
using (public.is_staff() and created_by=(select auth.uid()));
drop policy if exists "Admins delete own completed or failed Hatbazar AI jobs" on public.hatbazar_ai_jobs;
create policy "Staff delete own completed or failed Hatbazar AI jobs" on public.hatbazar_ai_jobs for delete to authenticated
using (public.is_staff() and created_by=(select auth.uid()) and status=any(array['completed','failed']::text[]));

drop policy if exists "Admin can upload product images" on storage.objects;
create policy "Staff can upload product images" on storage.objects for insert to authenticated
with check (bucket_id='product-images' and (select public.is_staff()));
drop policy if exists "Admin can update product images" on storage.objects;
create policy "Staff can update product images" on storage.objects for update to authenticated
using (bucket_id='product-images' and (select public.is_staff()))
with check (bucket_id='product-images' and (select public.is_staff()));
drop policy if exists "Admin can delete product images" on storage.objects;
create policy "Staff can delete product images" on storage.objects for delete to authenticated
using (bucket_id='product-images' and (select public.is_staff()));

create or replace function public.hatbazar_admin_list_marketplace_applications()
returns table(user_id uuid,full_name text,phone text,role text,status text,shop_name text)
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null or public.is_staff() is not true then raise exception 'Only authorized Hatbazar staff can view marketplace applications'; end if;
  return query
  select p.id,p.full_name,p.phone,p.role,
    case when p.role='seller' then sp.status else rp.status end::text,
    case when p.role='seller' then sp.shop_name else rp.shop_name end::text
  from public.profiles p
  left join public.seller_profiles sp on sp.id=p.id and p.role='seller'
  left join public.reseller_profiles rp on rp.id=p.id and p.role='reseller'
  where p.role in ('seller','reseller') order by p.created_at desc;
end;
$$;

create or replace function public.hatbazar_admin_update_marketplace_status(p_user_id uuid,p_role text,p_status text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null or public.is_staff() is not true then raise exception 'Only authorized Hatbazar staff can approve marketplace accounts'; end if;
  if p_user_id is null or p_role not in ('seller','reseller') or p_status not in ('pending','approved','rejected','suspended') then raise exception 'Invalid marketplace approval request'; end if;
  if p_role='seller' then update public.seller_profiles set status=p_status where id=p_user_id;
  else update public.reseller_profiles set status=p_status where id=p_user_id; end if;
  if not found then raise exception 'Marketplace application not found'; end if;
  return pg_catalog.jsonb_build_object('success',true,'user_id',p_user_id,'role',p_role,'status',p_status);
end;
$$;

create or replace function public.hatbazar_admin_update_order(
 p_order_id uuid,p_order_status text default null,p_payment_verified boolean default null,p_cancellation_reason text default null
) returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_status text; v_old_status text; v_verified boolean; v_payment_status text; v_reason text;
begin
  if auth.uid() is null or public.is_staff() is not true then raise exception 'Only authorized Hatbazar staff can update orders'; end if;
  if p_order_status is not null and p_order_status not in ('pending','pending_verification','confirmed','processing','shipped','delivered','cancelled','returned') then raise exception 'Invalid order status'; end if;
  if p_order_status in ('cancelled','returned') and nullif(btrim(p_cancellation_reason),'') is null then raise exception 'A reason is required for cancellation or return'; end if;
  select o.order_status into v_old_status from public.orders o where o.id=p_order_id for update;
  if not found then raise exception 'Order not found'; end if;
  if v_old_status in ('cancelled','returned') and p_order_status is not null and p_order_status<>v_old_status then raise exception 'A cancelled or returned order cannot be reopened or changed'; end if;
  if p_order_status='cancelled' and v_old_status not in ('cancelled','delivered') then
    update public.products p set stock=p.stock+oi.quantity from public.order_items oi where oi.order_id=p_order_id and oi.product_id=p.id;
  elsif p_order_status='cancelled' and v_old_status='delivered' then raise exception 'A delivered order cannot be cancelled'; end if;
  update public.orders set
    order_status=coalesce(p_order_status,order_status),
    cancellation_reason=case when p_order_status in ('cancelled','returned') then btrim(p_cancellation_reason) else cancellation_reason end,
    payment_verified=coalesce(p_payment_verified,payment_verified),
    payment_status=case when p_payment_verified is true then 'paid' when p_payment_verified is false then 'pending' else payment_status end
  where id=p_order_id returning order_status,payment_verified,payment_status,cancellation_reason into v_status,v_verified,v_payment_status,v_reason;
  return pg_catalog.jsonb_build_object('success',true,'order_status',v_status,'payment_verified',v_verified,'payment_status',v_payment_status,'cancellation_reason',v_reason);
end;
$$;
grant execute on function public.hatbazar_admin_list_marketplace_applications() to authenticated;
grant execute on function public.hatbazar_admin_update_marketplace_status(uuid,text,text) to authenticated;
grant execute on function public.hatbazar_admin_update_order(uuid,text,boolean,text) to authenticated;

-- Remove direct Data API access to the private wholesale price column.
revoke all on table public.products from anon,authenticated;
grant select (id,seller_id,category_id,name,name_bn,description,price,stock,image_url,is_active,created_at,description_en,description_bn,attributes,sizes,original_price)
on public.products to anon,authenticated;
grant insert (id,seller_id,category_id,name,name_bn,description,price,stock,image_url,is_active,created_at,description_en,description_bn,attributes,sizes,original_price)
on public.products to authenticated;
grant update (seller_id,category_id,name,name_bn,description,price,stock,image_url,is_active,description_en,description_bn,attributes,sizes,original_price)
on public.products to authenticated;
grant delete on table public.products to authenticated;

create or replace function public.hatbazar_admin_set_product_base_price(p_product_id uuid,p_base_price numeric)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null or public.is_admin() is not true then raise exception 'Only the Super Admin can change product base prices'; end if;
  if p_product_id is null or (p_base_price is not null and p_base_price<0) then raise exception 'Invalid product base price'; end if;
  update public.products set base_price=p_base_price where id=p_product_id;
  if not found then raise exception 'Product not found'; end if;
  return jsonb_build_object('success',true,'product_id',p_product_id);
end;
$$;
revoke all on function public.hatbazar_admin_set_product_base_price(uuid,numeric) from public;
grant execute on function public.hatbazar_admin_set_product_base_price(uuid,numeric) to authenticated;
