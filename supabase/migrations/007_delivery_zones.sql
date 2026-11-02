-- =====================================================================
-- Royal Glow Platform — 007_delivery_zones.sql
-- Delivery zones with their own fees, who delivers, and whether the
-- fee is paid to Royal Glow or to the rider. "Somewhere else" orders
-- get a fee confirmed by staff. Requires 001–006. Safe to re-run.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Zones
-- ---------------------------------------------------------------------
create table if not exists public.delivery_zones (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,
  fee          numeric(12,2) not null default 0 check (fee >= 0),
  fee_to_rider boolean not null default false,   -- customer pays the rider directly
  carrier      text,                             -- who delivers, e.g. "Royal Glow rider"
  sort_order   int not null default 0,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

-- Sample zones (only if none exist yet). Edit them in Online shop -> Settings.
insert into public.delivery_zones (name, fee, fee_to_rider, carrier, sort_order)
select * from (values
  ('Kumasi central (sample)',   20.00, false, 'Royal Glow rider',            1),
  ('Kumasi outskirts (sample)', 35.00, true,  'Dispatch rider',              2),
  ('Accra (sample)',            50.00, false, 'Bus parcel service',          3),
  ('Other regions (sample)',    60.00, false, 'Bus parcel service',          4)
) v(name, fee, fee_to_rider, carrier, sort_order)
where not exists (select 1 from public.delivery_zones);

-- ---------------------------------------------------------------------
-- 2. Orders remember the zone, whether the fee is confirmed, who gets it
-- ---------------------------------------------------------------------
alter table public.shop_orders
  add column if not exists zone_id       uuid references public.delivery_zones(id) on delete set null,
  add column if not exists zone_name     text,                         -- snapshot for history
  add column if not exists fee_confirmed boolean not null default true,
  add column if not exists fee_to_rider  boolean not null default false;

-- ---------------------------------------------------------------------
-- 3. shop_info now lists the zones
-- ---------------------------------------------------------------------
create or replace function public.shop_info()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'momo_number',  s.momo_number,
    'momo_name',    s.momo_name,
    'whatsapp',     s.whatsapp,
    'zones', coalesce((select json_agg(json_build_object('id', z.id, 'name', z.name, 'fee', z.fee,
                                                          'fee_to_rider', z.fee_to_rider, 'carrier', z.carrier)
                                       order by z.sort_order, z.name)
                       from public.delivery_zones z where z.active), '[]'::json),
    'pickup_points', coalesce((select json_agg(json_build_object('id', l.id, 'name', l.name) order by l.name)
                               from public.locations l where l.pickup_point and l.active), '[]'::json))
  from public.shop_settings s where s.id = 1;
$$;

-- ---------------------------------------------------------------------
-- 4. place_order takes a zone (null = "somewhere else, fee to confirm")
-- ---------------------------------------------------------------------
drop function if exists public.place_order(jsonb, text, text, text, text, text, uuid, text, text);

create or replace function public.place_order(
  p_items jsonb, p_name text, p_phone text, p_email text,
  p_delivery_method text, p_address text, p_pickup_location uuid,
  p_payment_method text, p_notes text, p_zone uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_order public.shop_orders;
  v_zone public.delivery_zones;
  v_line jsonb; v_item public.items; v_qty numeric; v_avail numeric;
  v_fee numeric := 0; v_confirmed boolean := true; v_to_rider boolean := false;
  v_total numeric := 0;
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_phone), '') = '' then
    raise exception 'Please give your name and phone number.';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty.';
  end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Too many different items in one order.'; end if;
  if p_delivery_method not in ('delivery', 'pickup') then raise exception 'Choose delivery or pickup.'; end if;
  if p_payment_method not in ('momo', 'cash') then raise exception 'Choose a payment method.'; end if;

  if p_delivery_method = 'delivery' then
    if coalesce(trim(p_address), '') = '' then raise exception 'Please give a delivery address.'; end if;
    if p_zone is not null then
      select * into v_zone from public.delivery_zones where id = p_zone and active;
      if not found then raise exception 'Choose a delivery area.'; end if;
      v_fee := v_zone.fee; v_to_rider := v_zone.fee_to_rider;
    else
      v_confirmed := false;      -- "somewhere else": staff confirm the fee
    end if;
  else
    if not exists (select 1 from public.locations where id = p_pickup_location and pickup_point and active) then
      raise exception 'Choose a pickup point.';
    end if;
  end if;

  insert into public.shop_orders (customer_user_id, full_name, phone, email, delivery_method, address,
                                  pickup_location_id, payment_method, delivery_fee, notes,
                                  zone_id, zone_name, fee_confirmed, fee_to_rider)
  values (auth.uid(), trim(p_name), trim(p_phone), nullif(trim(p_email), ''), p_delivery_method,
          case when p_delivery_method = 'delivery' then trim(p_address) end,
          case when p_delivery_method = 'pickup' then p_pickup_location end,
          p_payment_method, v_fee, nullif(trim(p_notes), ''),
          v_zone.id,
          case when p_delivery_method = 'delivery' then coalesce(v_zone.name, 'Somewhere else') end,
          v_confirmed, v_to_rider)
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

  return json_build_object(
    'order_no', v_order.order_no, 'subtotal', v_total,
    'delivery_fee', v_fee, 'fee_confirmed', v_confirmed, 'fee_to_rider', v_to_rider,
    -- what the customer pays Royal Glow now (rider fees and unconfirmed fees excluded)
    'total', v_total + case when v_confirmed and not v_to_rider then v_fee else 0 end);
end $$;

grant execute on function public.place_order(jsonb, text, text, text, text, text, uuid, text, text, uuid) to anon, authenticated;

-- ---------------------------------------------------------------------
-- 5. Row Level Security for zones: staff read; admin + sales manage
--    (customers see zones through shop_info)
-- ---------------------------------------------------------------------
alter table public.delivery_zones enable row level security;
drop policy if exists delivery_zones_read  on public.delivery_zones;
drop policy if exists delivery_zones_write on public.delivery_zones;
create policy delivery_zones_read on public.delivery_zones for select using (public.is_staff());
create policy delivery_zones_write on public.delivery_zones for all
  using (public.is_staff(array['admin', 'sales'])) with check (public.is_staff(array['admin', 'sales']));
