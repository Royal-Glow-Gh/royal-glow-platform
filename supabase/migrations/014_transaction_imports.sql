-- =====================================================================
-- Royal Glow Platform — 014_transaction_imports.sql
-- Imports (Import page) for purchases, sales, customer payments and supplier payments.
--  * The same rules as entering by hand: the cost of each sale line is recorded, credit sales
--    need a named customer, credit purchases a supplier, and so on.
--  * Normal mode refuses a sale when there isn't enough stock at that location on that date.
--    "Older records" mode (p_older = true) lets stock go below zero instead (the page shows
--    these as warnings); a stock count afterwards puts stock right.
--  * A receipt number that is already in the system is refused, so the same file can't be
--    imported twice. All-or-nothing, logged in account_imports, undoable.
-- Requires 001–013. Safe to re-run. Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

alter table public.purchases         add column if not exists import_id uuid;
alter table public.sales             add column if not exists import_id uuid;
alter table public.customer_payments add column if not exists import_id uuid;
alter table public.supplier_payments add column if not exists import_id uuid;
create index if not exists sales_receipt_idx on public.sales (lower(receipt_no)) where receipt_no is not null;

-- Stock of an item at a location at the end of a day.
create or replace function public.stock_at(p_item uuid, p_location uuid, p_date date)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(qty_change), 0) from public.stock_ledger
  where item_id = p_item and location_id = p_location and move_date <= p_date $$;
grant execute on function public.stock_at(uuid, uuid, date) to authenticated;

-- ---------------------------------------------------------------------
-- Purchases. p_purchases: [{label, purchase_date, supplier_id, location_id, ref, payment_method,
--                           lines:[{item_id, qty, unit_cost}]}]
-- ---------------------------------------------------------------------
create or replace function public.import_purchases(p_file text, p_purchases jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; p jsonb; l jsonb; v_pid uuid; v_n int := 0; v_total numeric := 0;
begin
  v_id := public.import_begin('purchases', p_file, array['admin', 'inventory']);
  for p in select * from jsonb_array_elements(p_purchases) order by (value->>'purchase_date')::date loop
    begin
      if coalesce(p->>'payment_method', '') not in ('cash', 'momo', 'bank', 'card', 'credit') then raise exception 'paid with must be cash, momo, bank, card or unpaid'; end if;
      if p->>'payment_method' = 'credit' and nullif(p->>'supplier_id', '') is null then raise exception 'unpaid purchases need the supplier'; end if;
      if jsonb_array_length(coalesce(p->'lines', '[]')) = 0 then raise exception 'no items'; end if;
      insert into public.purchases (purchase_date, supplier_id, location_id, ref, payment_method, notes, import_id)
      values ((p->>'purchase_date')::date, nullif(p->>'supplier_id', '')::uuid, (p->>'location_id')::uuid,
              nullif(trim(p->>'ref'), ''), p->>'payment_method', 'Imported', v_id)
      returning id into v_pid;
      for l in select * from jsonb_array_elements(p->'lines') loop
        insert into public.purchase_lines (purchase_id, item_id, qty, unit_cost)
        values (v_pid, (l->>'item_id')::uuid, (l->>'qty')::numeric, (l->>'unit_cost')::numeric);
        v_total := v_total + round((l->>'qty')::numeric * (l->>'unit_cost')::numeric, 2);
      end loop;
      v_n := v_n + 1;
    exception when others then raise exception '%: %', coalesce(p->>'label', 'Purchase'), sqlerrm;
    end;
  end loop;
  update public.account_imports set row_count = v_n, total = v_total where id = v_id;
  return jsonb_build_object('import_id', v_id, 'count', v_n, 'total', v_total);
end $$;

-- ---------------------------------------------------------------------
-- Sales. p_sales: [{label, sale_date, location_id, customer_id, payment_method, receipt_no, discount,
--                   paid_now, paid_now_method, lines:[{item_id, qty, unit_price}]}]
-- Sales go in date order; with p_older = false each line needs the stock to be there.
-- ---------------------------------------------------------------------
create or replace function public.import_sales(p_file text, p_older boolean, p_sales jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; s jsonb; l jsonb; v_sid uuid; v_n int := 0; v_total numeric := 0; v_gross numeric; v_have numeric; v_name text; v_loc text;
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
        if not coalesce(p_older, false) then
          v_have := public.stock_at((l->>'item_id')::uuid, (s->>'location_id')::uuid, (s->>'sale_date')::date);
          if v_have < (l->>'qty')::numeric then
            select name into v_name from public.items where id = (l->>'item_id')::uuid;
            select name into v_loc from public.locations where id = (s->>'location_id')::uuid;
            raise exception 'only % of % in stock at % on %', trim(to_char(v_have, 'FM999999990.##')), v_name, v_loc, s->>'sale_date';
          end if;
        end if;
        insert into public.sale_lines (sale_id, item_id, qty, unit_price, unit_cost)
        values (v_sid, (l->>'item_id')::uuid, (l->>'qty')::numeric, (l->>'unit_price')::numeric,
                coalesce((select current_unit_cost from public.item_current_cost where id = (l->>'item_id')::uuid), 0));
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

-- ---------------------------------------------------------------------
-- Payments received from customers / paid to suppliers.
-- p_rows: [{row, party_id, payment_date, amount, method, ref, notes}]
-- ---------------------------------------------------------------------
create or replace function public.import_payments(p_file text, p_party text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; r jsonb; v_n int := 0; v_total numeric := 0;
begin
  if p_party not in ('customer', 'supplier') then raise exception 'Unknown payment type.'; end if;
  v_id := public.import_begin(p_party || '_payments', p_file,
            case when p_party = 'customer' then array['admin', 'sales', 'accounts'] else array['admin', 'inventory', 'accounts'] end);
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      if p_party = 'customer' then
        insert into public.customer_payments (customer_id, payment_date, amount, method, ref, notes, import_id)
        values ((r->>'party_id')::uuid, (r->>'payment_date')::date, round((r->>'amount')::numeric, 2), r->>'method',
                nullif(trim(r->>'ref'), ''), nullif(trim(r->>'notes'), ''), v_id);
      else
        insert into public.supplier_payments (supplier_id, payment_date, amount, method, ref, notes, import_id)
        values ((r->>'party_id')::uuid, (r->>'payment_date')::date, round((r->>'amount')::numeric, 2), r->>'method',
                nullif(trim(r->>'ref'), ''), nullif(trim(r->>'notes'), ''), v_id);
      end if;
      v_n := v_n + 1; v_total := v_total + round((r->>'amount')::numeric, 2);
    exception when others then raise exception 'Row %: %', coalesce(r->>'row', '?'), sqlerrm;
    end;
  end loop;
  update public.account_imports set row_count = v_n, total = v_total where id = v_id;
  return jsonb_build_object('import_id', v_id, 'count', v_n, 'total', v_total);
end $$;

-- ---------------------------------------------------------------------
-- Undo, now covering every kind of import.
-- ---------------------------------------------------------------------
create or replace function public.undo_import(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.account_imports; v_n int := 0; v_kept int := 0; x record; k int;
begin
  select * into i from public.account_imports where id = p_id for update;
  if not found then raise exception 'Import not found.'; end if;
  if not public.is_staff(case i.kind
      when 'items' then array['admin', 'production', 'inventory'] when 'customers' then array['admin', 'sales', 'accounts']
      when 'suppliers' then array['admin', 'inventory', 'accounts'] when 'stock' then array['admin', 'inventory']
      when 'purchases' then array['admin', 'inventory'] when 'sales' then array['admin', 'sales']
      when 'customer_payments' then array['admin', 'sales', 'accounts'] when 'supplier_payments' then array['admin', 'inventory', 'accounts']
      else array['admin', 'accounts'] end) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if i.undone_at is not null then raise exception 'This import has already been undone.'; end if;
  if i.kind = 'accounts' then raise exception 'Chart of accounts imports can''t be undone; change the names back on the Chart of accounts tab.'; end if;
  delete from public.customer_payments where import_id = p_id;  get diagnostics k = row_count; v_n := v_n + k;
  delete from public.supplier_payments where import_id = p_id;  get diagnostics k = row_count; v_n := v_n + k;
  delete from public.sales where import_id = p_id;              get diagnostics k = row_count; v_n := v_n + k;
  delete from public.purchases where import_id = p_id;          get diagnostics k = row_count; v_n := v_n + k;
  delete from public.expenses where import_id = p_id;           get diagnostics k = row_count; v_n := v_n + k;
  delete from public.journals where import_id = p_id;           get diagnostics k = row_count; v_n := v_n + k;
  delete from public.party_openings where import_id = p_id;     get diagnostics k = row_count; v_n := v_n + k;
  delete from public.stock_adjustments where import_id = p_id;  get diagnostics k = row_count; v_n := v_n + k;
  for x in select 'customers' t, id from public.customers where import_id = p_id
           union all select 'suppliers', id from public.suppliers where import_id = p_id
           union all select 'items', id from public.items where import_id = p_id loop
    begin
      execute format('delete from public.%I where id = $1', x.t) using x.id;
      v_n := v_n + 1;
    exception when foreign_key_violation then
      v_kept := v_kept + 1;
      execute format('update public.%I set import_id = null where id = $1', x.t) using x.id;
    end;
  end loop;
  update public.account_imports set undone_at = now(), undone_by = auth.uid() where id = p_id;
  return jsonb_build_object('removed', v_n, 'kept', v_kept);
end $$;

grant execute on function public.import_purchases(text, jsonb) to authenticated;
grant execute on function public.import_sales(text, boolean, jsonb) to authenticated;
grant execute on function public.import_payments(text, text, jsonb) to authenticated;
