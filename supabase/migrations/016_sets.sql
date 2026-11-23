-- 016_sets.sql
-- Sets that are packed when sold (e.g. "Radiant Set").
--
-- A set is shown and sold as one product, with its own name, photo, description and
-- price (retail, wholesale, online offers). It has no stock of its own: when it is sold,
-- the sale is recorded as its individual products, with the set price shared out over
-- them in proportion to their normal retail prices. So stock, costs, product sales
-- reports and the accounts all work as before. Each line keeps which set it came from
-- (set_id, set_qty) so "sets sold" can be reported, and the contents are copied onto the
-- sale, so changing a set later never changes past sales.
--
-- Gift sets packed in advance are not "sets" here: they are ordinary products made with
-- a production batch (inputs = the products and the gift box).

-- ---------------------------------------------------------------------
-- 1. Sets and their contents
-- ---------------------------------------------------------------------
alter table public.items add column if not exists is_set boolean not null default false;

create table if not exists public.set_components (
  set_id  uuid not null references public.items(id) on delete cascade,
  item_id uuid not null references public.items(id),
  qty     numeric(12,3) not null check (qty > 0),
  sort    int not null default 0,
  primary key (set_id, item_id)
);
create index if not exists set_components_item_idx on public.set_components (item_id);

alter table public.set_components enable row level security;
drop policy if exists set_components_read on public.set_components;
create policy set_components_read on public.set_components for select using (public.is_staff());
-- written only through save_set()

-- ---------------------------------------------------------------------
-- 2. Lines remember the set they came from. The same product can now appear twice on
--    one sale or order (once loose, once inside a set), so the old one-line-per-product
--    rule is dropped.
-- ---------------------------------------------------------------------
alter table public.sale_lines        add column if not exists set_id  uuid references public.items(id);
alter table public.sale_lines        add column if not exists set_qty numeric(12,3);
alter table public.shop_order_lines  add column if not exists set_id  uuid references public.items(id);
alter table public.shop_order_lines  add column if not exists set_qty numeric(12,3);
alter table public.shop_order_lines  add column if not exists set_name text;
alter table public.sale_returns      add column if not exists set_id  uuid references public.items(id);
alter table public.sale_returns      add column if not exists set_qty numeric(12,3);

alter table public.sale_lines       drop constraint if exists sale_lines_sale_id_item_id_key;
alter table public.shop_order_lines drop constraint if exists shop_order_lines_order_id_item_id_key;
create index if not exists sale_lines_sale_idx  on public.sale_lines (sale_id);
create index if not exists sale_lines_set_idx   on public.sale_lines (set_id) where set_id is not null;
create index if not exists shop_order_lines_order_idx on public.shop_order_lines (order_id);

-- ---------------------------------------------------------------------
-- 3. A set never moves as stock itself
-- ---------------------------------------------------------------------
create or replace function public.refuse_set_item()
returns trigger language plpgsql set search_path = public as $$
declare v_id uuid := (to_jsonb(new) ->> tg_argv[0])::uuid; v_name text;
begin
  select name into v_name from public.items where id = v_id and is_set;
  if found then
    raise exception '"%" is a set (packed when sold): it has no stock of its own. Use its products instead.', v_name;
  end if;
  return new;
end $$;

do $$
declare t text[];
begin
  foreach t slice 1 in array array[
    ['batches', 'product_id'], ['batch_inputs', 'item_id'], ['purchase_lines', 'item_id'],
    ['transfer_lines', 'item_id'], ['stock_adjustments', 'item_id'], ['sale_lines', 'item_id'],
    ['sale_returns', 'item_id'], ['shop_order_lines', 'item_id'], ['set_components', 'item_id']] loop
    execute format('drop trigger if exists trg_refuse_set_item on public.%I', t[1]);
    execute format('create trigger trg_refuse_set_item before insert or update on public.%I
                    for each row execute function public.refuse_set_item(%L)', t[1], t[2]);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 4. Sharing a set price over its products
--    For ONE set at price p_price: one row per product (two for the product that takes
--    the rounding, when it is more than one unit). Callers multiply qty by the number of
--    sets. Unit prices are to the pesewa and add up to the set price exactly.
-- ---------------------------------------------------------------------
create or replace function public.set_split(p_set uuid, p_price numeric)
returns table (item_id uuid, qty numeric, unit_price numeric)
language plpgsql stable set search_path = public as $$
declare
  v_price numeric := round(coalesce(p_price, 0), 2);
  ids uuid[]; qs numeric[]; ws numeric[]; ps numeric[];
  v_w numeric; v_rem numeric; v_abs int; k int; n int;
begin
  select array_agg(sc.item_id order by sc.sort, i.name), array_agg(sc.qty order by sc.sort, i.name),
         array_agg(coalesce(i.retail_price, 0) * sc.qty order by sc.sort, i.name)
  into ids, qs, ws
  from public.set_components sc join public.items i on i.id = sc.item_id
  where sc.set_id = p_set;
  if ids is null then raise exception 'This set has no products in it yet.'; end if;
  n := array_length(ids, 1);

  select sum(x) into v_w from unnest(ws) x;
  if v_w = 0 then ws := qs; select sum(x) into v_w from unnest(ws) x; end if;

  ps := array_fill(0::numeric, array[n]);
  v_rem := v_price;
  for k in 1..n loop
    ps[k] := round(v_price * ws[k] / v_w / qs[k], 2);
    v_rem := v_rem - qs[k] * ps[k];
  end loop;

  -- the rounding goes on the product carrying the most value, preferring one of a single unit
  v_abs := 1;
  for k in 2..n loop
    if (qs[k] = 1 and qs[v_abs] <> 1) or ((qs[k] = 1) = (qs[v_abs] = 1) and ws[k] > ws[v_abs]) then v_abs := k; end if;
  end loop;

  for k in 1..n loop
    item_id := ids[k];
    if k = v_abs and v_rem <> 0 then
      if qs[k] = 1 then
        qty := 1; unit_price := ps[k] + v_rem; return next;
      elsif qs[k] > 1 and qs[k] = trunc(qs[k]) then
        qty := qs[k] - 1; unit_price := ps[k]; return next;
        qty := 1; unit_price := ps[k] + v_rem; return next;
      else  -- a fraction of a unit (rare): spread over it
        qty := qs[k]; unit_price := round(ps[k] + v_rem / qs[k], 2); return next;
      end if;
    else
      qty := qs[k]; unit_price := ps[k]; return next;
    end if;
  end loop;
end $$;
grant execute on function public.set_split(uuid, numeric) to authenticated;

-- ---------------------------------------------------------------------
-- 5. Creating and editing sets (admin, sales)
--    p_components: [{item_id, qty}]
-- ---------------------------------------------------------------------
create or replace function public.save_set(p_id uuid, p_name text, p_unit text, p_components jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := p_id; c jsonb; v_n int := 0; v_item public.items;
begin
  if not public.is_staff(array['admin', 'sales']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Give the set a name.'; end if;
  if jsonb_typeof(p_components) <> 'array' or jsonb_array_length(p_components) = 0 then
    raise exception 'Add the products that go in the set.';
  end if;
  if exists (select 1 from public.items where lower(name) = lower(trim(p_name)) and id is distinct from v_id) then
    raise exception 'There is already an item called "%".', trim(p_name);
  end if;

  if v_id is null then
    insert into public.items (name, kind, unit, is_set) values (trim(p_name), 'product', coalesce(nullif(trim(p_unit), ''), 'set'), true)
    returning id into v_id;
  else
    if not exists (select 1 from public.items where id = v_id and is_set) then raise exception 'Set not found.'; end if;
    update public.items set name = trim(p_name), unit = coalesce(nullif(trim(p_unit), ''), 'set') where id = v_id;
  end if;

  delete from public.set_components where set_id = v_id;
  for c in select * from jsonb_array_elements(p_components) loop
    select * into v_item from public.items where id = (c->>'item_id')::uuid;
    if not found then raise exception 'A product in the set was not found.'; end if;
    if v_item.is_set then raise exception 'A set can''t contain another set ("%").', v_item.name; end if;
    if v_item.kind not in ('product', 'goods', 'packaging') then
      raise exception '"%" is a %; a set can hold products, bought-in goods and packaging.', v_item.name, v_item.kind;
    end if;
    if coalesce((c->>'qty')::numeric, 0) <= 0 then raise exception 'Give a quantity for "%".', v_item.name; end if;
    if exists (select 1 from public.set_components where set_id = v_id and item_id = v_item.id) then
      raise exception '"%" is listed twice.', v_item.name;
    end if;
    v_n := v_n + 1;
    insert into public.set_components (set_id, item_id, qty, sort) values (v_id, v_item.id, (c->>'qty')::numeric, v_n);
  end loop;
  return v_id;
end $$;

-- Remove a set: deleted if never sold, otherwise retired (kept for the sales history)
create or replace function public.delete_set(p_id uuid)
returns text language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff(array['admin', 'sales']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if not exists (select 1 from public.items where id = p_id and is_set) then raise exception 'Set not found.'; end if;
  if exists (select 1 from public.sale_lines where set_id = p_id)
     or exists (select 1 from public.shop_order_lines where set_id = p_id)
     or exists (select 1 from public.sale_returns where set_id = p_id) then
    update public.items set active = false, shop_visible = false, offer_price = null, offer_from = null, offer_until = null
    where id = p_id;
    return 'retired';
  end if;
  delete from public.items where id = p_id;
  return 'deleted';
end $$;
revoke all on function public.save_set(uuid, text, text, jsonb) from public, anon;
revoke all on function public.delete_set(uuid) from public, anon;
grant execute on function public.save_set(uuid, text, text, jsonb) to authenticated;
grant execute on function public.delete_set(uuid) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Online shop: stock free to sell, and the catalogue with sets
-- ---------------------------------------------------------------------
-- Stock at the shop's stock locations, less what orders not yet fulfilled hold (may be negative)
create or replace function public.shop_free(p_item uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select sum(s.qty) from public.stock_on_hand s
                   where s.item_id = p_item and s.location_id in (select public.shop_stock_locations())), 0)
       - coalesce((select sum(l.qty) from public.shop_order_lines l
                   join public.shop_orders o on o.id = l.order_id
                   where l.item_id = p_item and o.status in ('new', 'confirmed', 'paid')), 0)
$$;
revoke all on function public.shop_free(uuid) from public, anon;

drop function if exists public.shop_catalog();
create function public.shop_catalog()
returns table (id uuid, name text, unit text, price numeric, description text,
               image_path text, available numeric, was_price numeric, offer_until date,
               is_set boolean, contents jsonb, parts_value numeric)
language sql stable security definer set search_path = public as $$
  select i.id, i.name, i.unit, public.shop_price(i), i.shop_description, i.image_path,
         case when i.is_set then
           coalesce((select min(floor(greatest(public.shop_free(sc.item_id), 0) / sc.qty))
                     from public.set_components sc where sc.set_id = i.id), 0)
         else greatest(public.shop_free(i.id), 0) end,
         case when public.shop_price(i) < i.retail_price then i.retail_price end,
         case when public.shop_price(i) < i.retail_price then i.offer_until end,
         i.is_set,
         case when i.is_set then
           (select jsonb_agg(jsonb_build_object('name', c.name, 'qty', sc.qty, 'unit', c.unit) order by sc.sort)
            from public.set_components sc join public.items c on c.id = sc.item_id where sc.set_id = i.id) end,
         case when i.is_set then
           (select nullif(sum(sc.qty * coalesce(c.retail_price, 0)), 0)
            from public.set_components sc join public.items c on c.id = sc.item_id where sc.set_id = i.id) end
  from public.items i
  where i.shop_visible and i.active and i.retail_price > 0 and i.kind in ('product', 'goods')
    and (not i.is_set or exists (select 1 from public.set_components sc where sc.set_id = i.id))
  order by i.name;
$$;
grant execute on function public.shop_catalog() to anon, authenticated;

-- place_order (from 015): a set in the cart becomes its products, each tagged with the set
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
  v_total numeric := 0; r record; v_short text;
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
    where id = (v_line->>'item_id')::uuid and shop_visible and active and retail_price > 0;
    if not found then raise exception 'A product in your cart is no longer available.'; end if;
    select available into v_avail from public.shop_catalog() c where c.id = v_item.id;
    if v_qty > coalesce(v_avail, 0) then
      raise exception 'Only % of "%" left in stock.', trunc(coalesce(v_avail, 0)), v_item.name;
    end if;
    v_price := public.shop_price(v_item);
    if v_item.is_set then
      for r in select s.item_id, s.qty, s.unit_price, i.name from public.set_split(v_item.id, v_price) s
               join public.items i on i.id = s.item_id loop
        insert into public.shop_order_lines (order_id, item_id, qty, unit_price, item_name, set_id, set_qty, set_name)
        values (v_order.id, r.item_id, r.qty * v_qty, r.unit_price, r.name, v_item.id, v_qty, v_item.name);
      end loop;
    else
      insert into public.shop_order_lines (order_id, item_id, qty, unit_price, item_name)
      values (v_order.id, v_item.id, v_qty, v_price, v_item.name);
    end if;
    v_total := v_total + v_qty * v_price;
  end loop;

  -- a product may be in the cart loose and inside a set: check the stock once more, all together
  select string_agg(i.name, ', ') into v_short
  from (select distinct item_id from public.shop_order_lines where order_id = v_order.id) x
  join public.items i on i.id = x.item_id
  where public.shop_free(x.item_id) < 0;
  if v_short is not null then
    raise exception 'Not enough stock of % for this order. Please reduce the quantities.', v_short;
  end if;

  return json_build_object(
    'order_no', v_order.order_no, 'subtotal', v_total,
    'delivery_fee', v_fee, 'fee_confirmed', v_confirmed, 'fee_to_rider', v_to_rider,
    -- what the customer pays Royal Glow now (rider fees and unconfirmed fees excluded)
    'total', v_total + case when v_confirmed and not v_to_rider then v_fee else 0 end);
end $$;
grant execute on function public.place_order(jsonb, text, text, text, text, text, uuid, text, text, uuid) to anon, authenticated;

-- fulfil_order (from 006): the set tags go onto the sale
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

  insert into public.sale_lines (sale_id, item_id, qty, unit_price, unit_cost, set_id, set_qty)
  select v_sale, l.item_id, l.qty, l.unit_price, coalesce(c.current_unit_cost, 0), l.set_id, l.set_qty
  from public.shop_order_lines l
  left join public.item_current_cost c on c.id = l.item_id
  where l.order_id = p_order;

  update public.shop_orders set status = 'fulfilled', sale_id = v_sale, updated_at = now()
  where id = p_order;
  return v_sale;
end $$;

-- ---------------------------------------------------------------------
-- 7. Imported sales (from 014): a set on a receipt becomes its products
--    (the line's qty = number of sets, unit_price = price of one set)
-- ---------------------------------------------------------------------
create or replace function public.import_sales(p_file text, p_older boolean, p_sales jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; s jsonb; l jsonb; v_sid uuid; v_n int := 0; v_total numeric := 0; v_gross numeric; v_have numeric; v_name text; v_loc text;
        v_item public.items; v_q numeric; r record;
begin
  v_id := public.import_begin('sales', p_file, array['admin', 'sales']);
  for s in select * from jsonb_array_elements(p_sales) order by (value->>'sale_date')::date loop
    begin
      if coalesce(s->>'payment_method', '') not in ('cash', 'momo', 'card', 'bank', 'credit') then raise exception 'paid with must be cash, momo, card, bank or credit'; end if;
      if s->>'payment_method' = 'credit' and nullif(s->>'customer_id', '') is null then raise exception 'credit sales need a named customer'; end if;
      if jsonb_array_length(coalesce(s->'lines', '[]')) = 0 then raise exception 'no items'; end if;
      if nullif(trim(s->>'receipt_no'), '') is not null and exists (select 1 from public.sales where lower(receipt_no) = lower(trim(s->>'receipt_no'))) then
        raise exception 'receipt % is already in the system', trim(s->>'receipt_no');
      end if;
      select coalesce(sum((x->>'qty')::numeric * (x->>'unit_price')::numeric), 0) into v_gross from jsonb_array_elements(s->'lines') x;
      if coalesce((s->>'discount')::numeric, 0) > v_gross then raise exception 'the discount is more than the sale'; end if;
      insert into public.sales (sale_date, location_id, customer_id, payment_method, receipt_no, discount, notes, import_id)
      values ((s->>'sale_date')::date, (s->>'location_id')::uuid, nullif(s->>'customer_id', '')::uuid, s->>'payment_method',
              nullif(trim(s->>'receipt_no'), ''), coalesce((s->>'discount')::numeric, 0), 'Imported', v_id)
      returning id into v_sid;
      for l in select * from jsonb_array_elements(s->'lines') loop
        select * into v_item from public.items where id = (l->>'item_id')::uuid;
        if v_item.is_set then
          if not coalesce(p_older, false) then
            -- stock_at already counts the lines of this sale inserted so far
            for r in select x.item_id, sum(x.qty) * (l->>'qty')::numeric as need, i.name
                     from public.set_split(v_item.id, (l->>'unit_price')::numeric) x
                     join public.items i on i.id = x.item_id group by x.item_id, i.name loop
              v_have := public.stock_at(r.item_id, (s->>'location_id')::uuid, (s->>'sale_date')::date);
              if v_have < r.need then
                select name into v_loc from public.locations where id = (s->>'location_id')::uuid;
                raise exception 'only % of % in stock at % on % (% needs %)', trim(to_char(greatest(v_have, 0), 'FM999999990.##')), r.name, v_loc, s->>'sale_date',
                                v_item.name, trim(to_char(r.need, 'FM999999990.##'));
              end if;
            end loop;
          end if;
          for r in select x.item_id, x.qty, x.unit_price from public.set_split(v_item.id, (l->>'unit_price')::numeric) x loop
            v_q := r.qty * (l->>'qty')::numeric;
            insert into public.sale_lines (sale_id, item_id, qty, unit_price, unit_cost, set_id, set_qty)
            values (v_sid, r.item_id, v_q, r.unit_price,
                    coalesce((select current_unit_cost from public.item_current_cost where id = r.item_id), 0),
                    v_item.id, (l->>'qty')::numeric);
          end loop;
        else
          if not coalesce(p_older, false) then
            v_have := public.stock_at((l->>'item_id')::uuid, (s->>'location_id')::uuid, (s->>'sale_date')::date);
            if v_have < (l->>'qty')::numeric then
              select name into v_loc from public.locations where id = (s->>'location_id')::uuid;
              raise exception 'only % of % in stock at % on %', trim(to_char(greatest(v_have, 0), 'FM999999990.##')), v_item.name, v_loc, s->>'sale_date';
            end if;
          end if;
          insert into public.sale_lines (sale_id, item_id, qty, unit_price, unit_cost)
          values (v_sid, (l->>'item_id')::uuid, (l->>'qty')::numeric, (l->>'unit_price')::numeric,
                  coalesce((select current_unit_cost from public.item_current_cost where id = (l->>'item_id')::uuid), 0));
        end if;
      end loop;
      -- Part paid when the goods went on credit: recorded as a payment on the same day.
      if s->>'payment_method' = 'credit' and coalesce((s->>'paid_now')::numeric, 0) > 0 then
        insert into public.customer_payments (customer_id, payment_date, amount, method, ref, notes, import_id)
        values ((s->>'customer_id')::uuid, (s->>'sale_date')::date, round((s->>'paid_now')::numeric, 2),
                coalesce(nullif(s->>'paid_now_method', ''), 'cash'), nullif(trim(s->>'receipt_no'), ''), 'Paid with the sale (imported)', v_id);
      end if;
      v_n := v_n + 1; v_total := v_total + round(v_gross - coalesce((s->>'discount')::numeric, 0), 2);
    exception when others then raise exception '%: %', coalesce(s->>'label', 'Sale'), sqlerrm;
    end;
  end loop;
  update public.account_imports set row_count = v_n, total = v_total where id = v_id;
  return jsonb_build_object('import_id', v_id, 'count', v_n, 'total', v_total);
end $$;
grant execute on function public.import_sales(text, boolean, jsonb) to authenticated;
