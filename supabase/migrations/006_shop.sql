-- =====================================================================
-- Royal Glow Platform — 006_shop.sql
-- Online shop: published products, customer accounts, orders,
-- shop settings, product photos. Requires 001–005. Safe to re-run.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Shop fields on items and locations
-- ---------------------------------------------------------------------
alter table public.items
  add column if not exists shop_visible     boolean not null default false,
  add column if not exists shop_description text,
  add column if not exists image_path       text;     -- file name in the product-images bucket

alter table public.locations
  add column if not exists fulfils_online boolean not null default false,  -- online stock comes from here
  add column if not exists pickup_point   boolean not null default false;  -- customers may collect here

-- ---------------------------------------------------------------------
-- 2. Shop settings (single row)
-- ---------------------------------------------------------------------
create table if not exists public.shop_settings (
  id           int primary key default 1 check (id = 1),
  delivery_fee numeric(12,2) not null default 0 check (delivery_fee >= 0),
  momo_number  text,
  momo_name    text,
  whatsapp     text,
  updated_at   timestamptz not null default now()
);
insert into public.shop_settings (id) values (1) on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 3. Customer profiles (created automatically when a customer signs up)
-- ---------------------------------------------------------------------
create table if not exists public.shop_profiles (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  full_name      text,
  phone          text,
  address        text,
  wants_deals    boolean not null default false,
  wants_articles boolean not null default false,
  created_at     timestamptz not null default now()
);

create or replace function public.handle_new_customer()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(new.raw_user_meta_data->>'account_type', '') = 'customer' then
    insert into public.shop_profiles (user_id, full_name, phone, wants_deals, wants_articles)
    values (new.id,
            new.raw_user_meta_data->>'full_name',
            new.raw_user_meta_data->>'phone',
            coalesce((new.raw_user_meta_data->>'wants_deals')::boolean, false),
            coalesce((new.raw_user_meta_data->>'wants_articles')::boolean, false))
    on conflict (user_id) do nothing;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created_customer on auth.users;
create trigger on_auth_user_created_customer
  after insert on auth.users
  for each row execute function public.handle_new_customer();

-- Customers must not appear in the staff "waiting for approval" list
create or replace function public.list_unassigned_users()
returns table (user_id uuid, email text, suggested_name text,
               signed_up_at timestamptz, email_confirmed boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_staff(array['admin']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select u.id, u.email::text, (u.raw_user_meta_data->>'full_name')::text,
           u.created_at, u.email_confirmed_at is not null
    from auth.users u
    where not exists (select 1 from public.staff s where s.user_id = u.id)
      and not exists (select 1 from public.shop_profiles p where p.user_id = u.id)
      and coalesce(u.raw_user_meta_data->>'account_type', '') <> 'customer'
    order by u.created_at desc;
end $$;

-- ---------------------------------------------------------------------
-- 4. Orders
-- ---------------------------------------------------------------------
create sequence if not exists public.shop_order_seq;

create table if not exists public.shop_orders (
  id                 uuid primary key default gen_random_uuid(),
  order_no           text not null unique
                     default 'RG-' || lpad(nextval('public.shop_order_seq')::text, 5, '0'),
  customer_user_id   uuid references auth.users(id) on delete set null,
  full_name          text not null,
  phone              text not null,
  email              text,
  delivery_method    text not null check (delivery_method in ('delivery', 'pickup')),
  address            text,
  pickup_location_id uuid references public.locations(id),
  payment_method     text not null check (payment_method in ('momo', 'cash')),
  status             text not null default 'new'
                     check (status in ('new', 'confirmed', 'paid', 'fulfilled', 'cancelled')),
  delivery_fee       numeric(12,2) not null default 0,
  notes              text,
  sale_id            uuid references public.sales(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists shop_orders_status_idx on public.shop_orders (status, created_at desc);

create table if not exists public.shop_order_lines (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references public.shop_orders(id) on delete cascade,
  item_id    uuid not null references public.items(id),
  qty        numeric(12,3) not null check (qty > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  item_name  text,                     -- name at the time of ordering, for the customer's history
  unique (order_id, item_id)
);
alter table public.shop_order_lines add column if not exists item_name text;

-- ---------------------------------------------------------------------
-- 5. Where online stock comes from
-- ---------------------------------------------------------------------
create or replace function public.shop_stock_locations()
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from public.locations where fulfils_online and active
  union all
  select public.default_factory()
  where not exists (select 1 from public.locations where fulfils_online and active);
$$;

-- ---------------------------------------------------------------------
-- 6. Public functions (callable by anyone, signed in or not)
-- ---------------------------------------------------------------------
create or replace function public.shop_catalog()
returns table (id uuid, name text, unit text, price numeric, description text,
               image_path text, available numeric)
language sql stable security definer set search_path = public as $$
  select i.id, i.name, i.unit, i.retail_price, i.shop_description, i.image_path,
         greatest(coalesce((select sum(s.qty) from public.stock_on_hand s
                            where s.item_id = i.id
                              and s.location_id in (select public.shop_stock_locations())), 0)
                  -- stock held by orders not yet fulfilled
                - coalesce((select sum(l.qty) from public.shop_order_lines l
                            join public.shop_orders o on o.id = l.order_id
                            where l.item_id = i.id and o.status in ('new', 'confirmed', 'paid')), 0), 0)
  from public.items i
  where i.shop_visible and i.retail_price > 0 and i.kind in ('product', 'goods')
  order by i.name;
$$;

create or replace function public.shop_info()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'delivery_fee', s.delivery_fee,
    'momo_number',  s.momo_number,
    'momo_name',    s.momo_name,
    'whatsapp',     s.whatsapp,
    'pickup_points', coalesce((select json_agg(json_build_object('id', l.id, 'name', l.name) order by l.name)
                               from public.locations l where l.pickup_point and l.active), '[]'::json))
  from public.shop_settings s where s.id = 1;
$$;

-- Places an order. Prices and stock are checked here, never trusted from the browser.
create or replace function public.place_order(
  p_items jsonb, p_name text, p_phone text, p_email text,
  p_delivery_method text, p_address text, p_pickup_location uuid,
  p_payment_method text, p_notes text)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_order public.shop_orders;
  v_line jsonb; v_item public.items; v_qty numeric; v_avail numeric;
  v_fee numeric := 0; v_total numeric := 0;
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_phone), '') = '' then
    raise exception 'Please give your name and phone number.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty.';
  end if;
  if jsonb_array_length(p_items) > 30 then
    raise exception 'Too many different items in one order.';
  end if;
  if p_delivery_method not in ('delivery', 'pickup') then raise exception 'Choose delivery or pickup.'; end if;
  if p_payment_method not in ('momo', 'cash') then raise exception 'Choose a payment method.'; end if;
  if p_delivery_method = 'delivery' then
    if coalesce(trim(p_address), '') = '' then raise exception 'Please give a delivery address.'; end if;
    select delivery_fee into v_fee from public.shop_settings where id = 1;
  else
    if not exists (select 1 from public.locations where id = p_pickup_location and pickup_point and active) then
      raise exception 'Choose a pickup point.';
    end if;
  end if;

  insert into public.shop_orders (customer_user_id, full_name, phone, email, delivery_method, address,
                                  pickup_location_id, payment_method, delivery_fee, notes)
  values (auth.uid(), trim(p_name), trim(p_phone), nullif(trim(p_email), ''), p_delivery_method,
          case when p_delivery_method = 'delivery' then trim(p_address) end,
          case when p_delivery_method = 'pickup' then p_pickup_location end,
          p_payment_method, coalesce(v_fee, 0), nullif(trim(p_notes), ''))
  returning * into v_order;

  for v_line in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_line->>'qty')::numeric;
    if v_qty is null or v_qty <> trunc(v_qty) or v_qty < 1 or v_qty > 100 then
      raise exception 'Invalid quantity.';
    end if;
    select * into v_item from public.items
    where id = (v_line->>'item_id')::uuid and shop_visible and retail_price > 0;
    if not found then raise exception 'A product in your cart is no longer available.'; end if;
    select available into v_avail from public.shop_catalog() c where c.id = v_item.id;
    if v_qty > coalesce(v_avail, 0) then
      raise exception 'Only % of "%" left in stock.', trunc(coalesce(v_avail, 0)), v_item.name;
    end if;
    insert into public.shop_order_lines (order_id, item_id, qty, unit_price, item_name)
    values (v_order.id, v_item.id, v_qty, v_item.retail_price, v_item.name);
    v_total := v_total + v_qty * v_item.retail_price;
  end loop;

  return json_build_object('order_no', v_order.order_no, 'subtotal', v_total,
                           'delivery_fee', v_order.delivery_fee, 'total', v_total + v_order.delivery_fee);
end $$;

-- ---------------------------------------------------------------------
-- 7. Staff functions
-- ---------------------------------------------------------------------
-- Publish / describe a product (sales staff can't edit items directly)
create or replace function public.set_shop_product(p_item uuid, p_visible boolean,
                                                   p_description text, p_image_path text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff(array['admin', 'sales']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  update public.items
  set shop_visible = coalesce(p_visible, false),
      shop_description = nullif(trim(p_description), ''),
      image_path = nullif(p_image_path, '')
  where id = p_item;
end $$;

-- Fulfil an order: records it as a sale (stock leaves p_location) and links it
create or replace function public.fulfil_order(p_order uuid, p_location uuid, p_payment text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_order public.shop_orders; v_sale uuid;
begin
  if not public.is_staff(array['admin', 'sales']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select * into v_order from public.shop_orders where id = p_order for update;
  if not found then raise exception 'Order not found.'; end if;
  if v_order.status in ('fulfilled', 'cancelled') then
    raise exception 'This order is already %.', v_order.status;
  end if;
  if p_payment not in ('cash', 'momo', 'card', 'bank') then raise exception 'Invalid payment method.'; end if;

  insert into public.sales (sale_date, location_id, customer_id, payment_method, receipt_no, notes)
  values (current_date, p_location, null, p_payment, v_order.order_no,
          'Online order' || case when v_order.delivery_fee > 0
                                 then ' (delivery fee GH₵ ' || v_order.delivery_fee || ' not included)' else '' end)
  returning id into v_sale;

  insert into public.sale_lines (sale_id, item_id, qty, unit_price, unit_cost)
  select v_sale, l.item_id, l.qty, l.unit_price, coalesce(c.current_unit_cost, 0)
  from public.shop_order_lines l
  left join public.item_current_cost c on c.id = l.item_id
  where l.order_id = p_order;

  update public.shop_orders set status = 'fulfilled', sale_id = v_sale, updated_at = now()
  where id = p_order;
  return v_sale;
end $$;

-- ---------------------------------------------------------------------
-- 8. Grants and Row Level Security
-- ---------------------------------------------------------------------
grant execute on function public.shop_catalog() to anon, authenticated;
grant execute on function public.shop_info() to anon, authenticated;
grant execute on function public.place_order(jsonb, text, text, text, text, text, uuid, text, text) to anon, authenticated;
revoke all on function public.shop_stock_locations() from public, anon;

alter table public.shop_settings    enable row level security;
alter table public.shop_profiles    enable row level security;
alter table public.shop_orders      enable row level security;
alter table public.shop_order_lines enable row level security;

drop policy if exists shop_settings_read  on public.shop_settings;
drop policy if exists shop_settings_write on public.shop_settings;
create policy shop_settings_read  on public.shop_settings for select using (public.is_staff());
create policy shop_settings_write on public.shop_settings for update
  using (public.is_staff(array['admin', 'sales'])) with check (public.is_staff(array['admin', 'sales']));

drop policy if exists shop_profiles_own   on public.shop_profiles;
drop policy if exists shop_profiles_staff on public.shop_profiles;
create policy shop_profiles_own on public.shop_profiles for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy shop_profiles_staff on public.shop_profiles for select using (public.is_staff());

-- Orders are created only through place_order(); customers can read their own
drop policy if exists shop_orders_own   on public.shop_orders;
drop policy if exists shop_orders_staff_read  on public.shop_orders;
drop policy if exists shop_orders_staff_write on public.shop_orders;
create policy shop_orders_own on public.shop_orders for select using (customer_user_id = auth.uid());
create policy shop_orders_staff_read on public.shop_orders for select using (public.is_staff());
create policy shop_orders_staff_write on public.shop_orders for update
  using (public.is_staff(array['admin', 'sales'])) with check (public.is_staff(array['admin', 'sales']));

drop policy if exists shop_order_lines_read on public.shop_order_lines;
create policy shop_order_lines_read on public.shop_order_lines for select using (
  public.is_staff() or exists (select 1 from public.shop_orders o
                               where o.id = order_id and o.customer_user_id = auth.uid()));

-- ---------------------------------------------------------------------
-- 9. Product photos: public bucket, staff (admin/sales) upload.
--    If this part reports a permission notice, create the bucket and
--    policies in Storage instead (see the setup notes).
-- ---------------------------------------------------------------------
do $$
begin
  insert into storage.buckets (id, name, public)
  values ('product-images', 'product-images', true)
  on conflict (id) do update set public = true;

  drop policy if exists product_images_insert on storage.objects;
  drop policy if exists product_images_update on storage.objects;
  drop policy if exists product_images_delete on storage.objects;
  create policy product_images_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'product-images' and public.is_staff(array['admin', 'sales']));
  create policy product_images_update on storage.objects for update to authenticated
    using (bucket_id = 'product-images' and public.is_staff(array['admin', 'sales']));
  create policy product_images_delete on storage.objects for delete to authenticated
    using (bucket_id = 'product-images' and public.is_staff(array['admin', 'sales']));
exception when others then
  raise notice 'Storage setup skipped (%). Create the product-images bucket and its policies in Storage.', sqlerrm;
end $$;
