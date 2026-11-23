-- 015_shop_offers.sql
-- Online offers: a product can have an offer price for the online shop, with optional
-- start and end dates. While the offer runs, the shop and website show
--   was GH₵ 85.00 (crossed out)  now GH₵ 68.00
-- where "was" is always the product's normal retail price, so the crossed-out price is
-- a real price. Customers are charged the offer price (checked here, never trusted from
-- the browser). When the offer ends, the normal price comes back by itself.
-- In-store sales (Sales page) are not affected: they still use the retail price.

alter table public.items
  add column if not exists offer_price numeric(12,2),
  add column if not exists offer_from  date,
  add column if not exists offer_until date;

alter table public.items drop constraint if exists items_offer_check;
alter table public.items add constraint items_offer_check
  check (offer_price is null or offer_price > 0);

-- The price the online shop charges today
create or replace function public.shop_price(i public.items)
returns numeric language sql stable set search_path = public as $$
  select case
    when i.offer_price > 0 and i.offer_price < i.retail_price
     and (i.offer_from  is null or i.offer_from  <= current_date)
     and (i.offer_until is null or i.offer_until >= current_date)
    then i.offer_price else i.retail_price end
$$;

-- Catalogue: price = what the customer pays today; was_price = normal price while an offer runs
drop function if exists public.shop_catalog();
create function public.shop_catalog()
returns table (id uuid, name text, unit text, price numeric, description text,
               image_path text, available numeric, was_price numeric, offer_until date)
language sql stable security definer set search_path = public as $$
  select i.id, i.name, i.unit, public.shop_price(i), i.shop_description, i.image_path,
         greatest(coalesce((select sum(s.qty) from public.stock_on_hand s
                            where s.item_id = i.id
                              and s.location_id in (select public.shop_stock_locations())), 0)
                  -- stock held by orders not yet fulfilled
                - coalesce((select sum(l.qty) from public.shop_order_lines l
                            join public.shop_orders o on o.id = l.order_id
                            where l.item_id = i.id and o.status in ('new', 'confirmed', 'paid')), 0), 0),
         case when public.shop_price(i) < i.retail_price then i.retail_price end,
         case when public.shop_price(i) < i.retail_price then i.offer_until end
  from public.items i
  where i.shop_visible and i.retail_price > 0 and i.kind in ('product', 'goods')
  order by i.name;
$$;
grant execute on function public.shop_catalog() to anon, authenticated;

-- Set or remove an offer (admin and sales). p_price null = remove the offer.
create or replace function public.set_shop_offer(p_item uuid, p_price numeric, p_from date, p_until date)
returns void language plpgsql security definer set search_path = public as $$
declare v_retail numeric;
begin
  if not public.is_staff(array['admin', 'sales']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  select retail_price into v_retail from public.items where id = p_item;
  if not found then raise exception 'Product not found.'; end if;
  if p_price is null then
    update public.items set offer_price = null, offer_from = null, offer_until = null where id = p_item;
    return;
  end if;
  if coalesce(v_retail, 0) <= 0 then raise exception 'Set the normal retail price first (Sales -> Price list).'; end if;
  if p_price <= 0 or p_price >= v_retail then
    raise exception 'The offer price must be more than 0 and less than the normal price (%).', v_retail;
  end if;
  if p_until is not null and p_until < current_date then raise exception 'The end date is in the past.'; end if;
  if p_from is not null and p_until is not null and p_until < p_from then
    raise exception 'The offer ends before it starts.';
  end if;
  update public.items set offer_price = round(p_price, 2), offer_from = p_from, offer_until = p_until
  where id = p_item;
end $$;
revoke all on function public.set_shop_offer(uuid, numeric, date, date) from public, anon;
grant execute on function public.set_shop_offer(uuid, numeric, date, date) to authenticated;

-- place_order (from 007) now charges the shop price, so offers are honoured at checkout
create or replace function public.place_order(
  p_items jsonb, p_name text, p_phone text, p_email text,
  p_delivery_method text, p_address text, p_pickup_location uuid,
  p_payment_method text, p_notes text, p_zone uuid default null)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_order public.shop_orders;
  v_zone public.delivery_zones;
  v_line jsonb; v_item public.items; v_qty numeric; v_avail numeric; v_price numeric;
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
    v_price := public.shop_price(v_item);
    insert into public.shop_order_lines (order_id, item_id, qty, unit_price, item_name)
    values (v_order.id, v_item.id, v_qty, v_price, v_item.name);
    v_total := v_total + v_qty * v_price;
  end loop;

  return json_build_object(
    'order_no', v_order.order_no, 'subtotal', v_total,
    'delivery_fee', v_fee, 'fee_confirmed', v_confirmed, 'fee_to_rider', v_to_rider,
    -- what the customer pays Royal Glow now (rider fees and unconfirmed fees excluded)
    'total', v_total + case when v_confirmed and not v_to_rider then v_fee else 0 end);
end $$;

grant execute on function public.place_order(jsonb, text, text, text, text, text, uuid, text, text, uuid) to anon, authenticated;
