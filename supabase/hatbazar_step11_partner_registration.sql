-- Hatbazar Step 11: persist seller and reseller applications in Supabase.
-- Applied to project wagtpkukzutsxwhutznu on 2026-11-20.

alter table public.seller_profiles
  add column if not exists district text,
  add column if not exists notes text;

alter table public.reseller_profiles
  add column if not exists shop_name text,
  add column if not exists district text,
  add column if not exists notes text;

create or replace function public.hatbazar_register_marketplace_profile_v2(
  p_full_name text,
  p_phone text,
  p_role text,
  p_shop_name text,
  p_district text,
  p_notes text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_existing_role text;
  v_phone text;
  v_shop_name text;
begin
  if auth.uid() is null then
    raise exception 'Sign in is required';
  end if;
  if nullif(pg_catalog.btrim(coalesce(p_full_name, '')), '') is null then
    raise exception 'Full name is required';
  end if;
  if p_role is null or p_role not in ('seller', 'reseller') then
    raise exception 'Invalid marketplace role';
  end if;
  v_phone := pg_catalog.regexp_replace(pg_catalog.btrim(coalesce(p_phone, '')), '[^0-9]', '', 'g');
  if pg_catalog.length(v_phone) <> 11 or pg_catalog.left(v_phone, 2) <> '01' then
    raise exception 'A valid Bangladesh mobile number is required';
  end if;
  v_shop_name := nullif(pg_catalog.btrim(coalesce(p_shop_name, '')), '');
  if v_shop_name is null then
    raise exception 'Shop or business name is required';
  end if;
  select p.role into v_existing_role
  from public.profiles p
  where p.id = auth.uid()
  for update;
  if v_existing_role is not null and v_existing_role not in ('customer', p_role) then
    raise exception 'This account already has a different role';
  end if;
  insert into public.profiles (id, full_name, phone, role)
  values (auth.uid(), pg_catalog.btrim(p_full_name), v_phone, p_role)
  on conflict (id) do update
  set full_name = excluded.full_name, phone = excluded.phone, role = excluded.role;

  if p_role = 'seller' then
    insert into public.seller_profiles (id, shop_name, district, notes, status)
    values (auth.uid(), v_shop_name, nullif(pg_catalog.btrim(coalesce(p_district, '')), ''), nullif(pg_catalog.btrim(coalesce(p_notes, '')), ''), 'pending')
    on conflict (id) do update
    set shop_name = excluded.shop_name, district = excluded.district, notes = excluded.notes;
  else
    insert into public.reseller_profiles (id, shop_name, district, notes, status)
    values (auth.uid(), v_shop_name, nullif(pg_catalog.btrim(coalesce(p_district, '')), ''), nullif(pg_catalog.btrim(coalesce(p_notes, '')), ''), 'pending')
    on conflict (id) do update
    set shop_name = excluded.shop_name, district = excluded.district, notes = excluded.notes;
  end if;
  return pg_catalog.jsonb_build_object('success', true, 'role', p_role, 'status', 'pending');
end;
$function$;

revoke all on function public.hatbazar_register_marketplace_profile_v2(text,text,text,text,text,text) from public, anon;
grant execute on function public.hatbazar_register_marketplace_profile_v2(text,text,text,text,text,text) to authenticated;

create or replace function public.hatbazar_admin_list_marketplace_applications()
returns table(user_id uuid, full_name text, phone text, role text, status text, shop_name text)
language plpgsql
security definer
set search_path = ''
as $function$
begin
  if auth.uid() is null or public.is_admin() is not true then
    raise exception 'Only administrators can view marketplace applications';
  end if;
  return query
  select p.id, p.full_name, p.phone, p.role,
         case when p.role = 'seller' then sp.status else rp.status end::text,
         case when p.role = 'seller' then sp.shop_name else rp.shop_name end::text
  from public.profiles p
  left join public.seller_profiles sp on sp.id = p.id and p.role = 'seller'
  left join public.reseller_profiles rp on rp.id = p.id and p.role = 'reseller'
  where p.role in ('seller','reseller')
  order by p.created_at desc;
end;
$function$;
revoke all on function public.hatbazar_admin_list_marketplace_applications() from public, anon;
grant execute on function public.hatbazar_admin_list_marketplace_applications() to authenticated;
