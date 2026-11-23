-- =====================================================================
-- Royal Glow Platform — 013_opening_and_imports.sql
-- Getting existing records in:
--  * books start date (the day the system's records begin; opening balances are as at that day)
--  * opening balance per customer (what they owed) and per supplier (what was owed to them),
--    included in customer and supplier balances and in the accounts
--  * imports (Import page) for products and prices, customers, suppliers and opening stock:
--    all-or-nothing, logged, and undoable
-- Requires 001–012. Safe to re-run. Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- 1. Books start date
create table if not exists public.books_settings (
  id         int primary key default 1 check (id = 1),
  start_date date not null default date_trunc('year', now())::date,
  updated_at timestamptz not null default now()
);
insert into public.books_settings (id) values (1) on conflict (id) do nothing;
alter table public.books_settings enable row level security;
drop policy if exists books_settings_read on public.books_settings;
drop policy if exists books_settings_write on public.books_settings;
create policy books_settings_read on public.books_settings for select using (public.is_staff());
create policy books_settings_write on public.books_settings for update
  using (public.is_staff(array['admin', 'accounts'])) with check (public.is_staff(array['admin', 'accounts']));

-- 2. Opening balances per customer / supplier (one each)
create table if not exists public.party_openings (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customers(id) on delete cascade,
  supplier_id uuid references public.suppliers(id) on delete cascade,
  as_of       date not null,
  amount      numeric(12,2) not null check (amount > 0),
  notes       text,
  import_id   uuid,
  created_by  uuid references auth.users(id) on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  check ((customer_id is null) <> (supplier_id is null))
);
create unique index if not exists party_openings_customer_uq on public.party_openings (customer_id) where customer_id is not null;
create unique index if not exists party_openings_supplier_uq on public.party_openings (supplier_id) where supplier_id is not null;
alter table public.party_openings enable row level security;
drop policy if exists party_openings_read on public.party_openings;
drop policy if exists party_openings_write on public.party_openings;
create policy party_openings_read on public.party_openings for select using (public.is_staff());
create policy party_openings_write on public.party_openings for all
  using ((customer_id is not null and public.is_staff(array['admin', 'sales', 'accounts']))
      or (supplier_id is not null and public.is_staff(array['admin', 'inventory', 'accounts'])))
  with check ((customer_id is not null and public.is_staff(array['admin', 'sales', 'accounts']))
      or (supplier_id is not null and public.is_staff(array['admin', 'inventory', 'accounts'])));

-- Balances now start from the opening balance. (New column "opening" is added at the end.)
create or replace view public.customer_balances
with (security_invoker = true) as
select c.id as customer_id, c.name,
       coalesce((select sum(t.total) from public.sale_totals t
                 where t.customer_id = c.id and t.payment_method = 'credit'), 0) as credit_sales,
       coalesce((select sum(r.qty * r.unit_price) from public.sale_returns r
                 where r.customer_id = c.id), 0)                                as returns_credit,
       coalesce((select sum(p.amount) from public.customer_payments p
                 where p.customer_id = c.id), 0)                                as payments,
       coalesce((select sum(o.amount) from public.party_openings o where o.customer_id = c.id), 0)
     + coalesce((select sum(t.total) from public.sale_totals t
                 where t.customer_id = c.id and t.payment_method = 'credit'), 0)
     - coalesce((select sum(r.qty * r.unit_price) from public.sale_returns r
                 where r.customer_id = c.id), 0)
     - coalesce((select sum(p.amount) from public.customer_payments p
                 where p.customer_id = c.id), 0)                                as balance,
       coalesce((select sum(o.amount) from public.party_openings o where o.customer_id = c.id), 0) as opening
from public.customers c;

create or replace view public.supplier_balances
with (security_invoker = true) as
select s.id as supplier_id, s.name,
  coalesce((select sum(o.amount) from public.party_openings o where o.supplier_id = s.id), 0)
+ coalesce((select sum(x.t) from (select round(sum(l.qty * l.unit_cost), 2) as t from public.purchases p join public.purchase_lines l on l.purchase_id = p.id
            where p.supplier_id = s.id and p.payment_method = 'credit' group by p.id) x), 0)
+ coalesce((select sum(e.amount) from public.expenses e where e.supplier_id = s.id and e.paid_from = 'payable'), 0)
- coalesce((select sum(sp.amount) from public.supplier_payments sp where sp.supplier_id = s.id), 0) as balance,
  coalesce((select sum(o.amount) from public.party_openings o where o.supplier_id = s.id), 0) as opening
from public.suppliers s;

-- 3. The ledger includes those opening balances
create or replace view public.gl_lines
with (security_invoker = true) as
-- Sales: money (or receivable) in, revenue out, discounts; cost of sales from stock
select t.sale_date as entry_date, public.pay_account(t.payment_method) as account_code,
       round(t.gross, 2) - t.discount as debit, 0::numeric as credit, 'sale'::text as source, t.sale_id as source_id, 'Sale' as memo
from public.sale_totals t where round(t.gross, 2) - t.discount <> 0
union all select t.sale_date, '4010', t.discount, 0, 'sale', t.sale_id, 'Discount' from public.sale_totals t where t.discount > 0
union all select t.sale_date, '4000', 0, round(t.gross, 2), 'sale', t.sale_id, 'Sale' from public.sale_totals t where round(t.gross, 2) <> 0
union all select t.sale_date, '5000', round(t.cost, 2), 0, 'sale', t.sale_id, 'Cost of goods sold' from public.sale_totals t where round(t.cost, 2) <> 0
union all select t.sale_date, '1200', 0, round(t.cost, 2), 'sale', t.sale_id, 'Cost of goods sold' from public.sale_totals t where round(t.cost, 2) <> 0
-- Returns: reduce revenue and what the customer owes (or refund cash); restocked goods back into stock
union all select r.return_date, '4020', round(r.qty * r.unit_price, 2), 0, 'return', r.id, 'Return'
  from public.sale_returns r where round(r.qty * r.unit_price, 2) > 0
union all select r.return_date, case when r.customer_id is not null then '1100' else '1000' end, 0, round(r.qty * r.unit_price, 2), 'return', r.id, 'Return'
  from public.sale_returns r where round(r.qty * r.unit_price, 2) > 0
union all select r.return_date, '1200', round(r.qty * coalesce(r.unit_cost, 0), 2), 0, 'return', r.id, 'Returned to stock'
  from public.sale_returns r where r.restock and round(r.qty * coalesce(r.unit_cost, 0), 2) > 0
union all select r.return_date, '5000', 0, round(r.qty * coalesce(r.unit_cost, 0), 2), 'return', r.id, 'Returned to stock'
  from public.sale_returns r where r.restock and round(r.qty * coalesce(r.unit_cost, 0), 2) > 0
-- Customer payments against credit
union all select p.payment_date, public.pay_account(p.method), p.amount, 0, 'customer_payment', p.id, 'Customer payment' from public.customer_payments p
union all select p.payment_date, '1100', 0, p.amount, 'customer_payment', p.id, 'Customer payment' from public.customer_payments p
-- Purchases: stock in; paid now or owed to the supplier
union all select x.purchase_date, '1200', x.total, 0, 'purchase', x.id, 'Purchase'
  from (select p.id, p.purchase_date, round(sum(l.qty * l.unit_cost), 2) as total from public.purchases p
        join public.purchase_lines l on l.purchase_id = p.id group by p.id) x where x.total > 0
union all select x.purchase_date, case when x.payment_method = 'credit' then '2000' else public.pay_account(x.payment_method) end,
       0, x.total, 'purchase', x.id, 'Purchase'
  from (select p.id, p.purchase_date, p.payment_method, round(sum(l.qty * l.unit_cost), 2) as total from public.purchases p
        join public.purchase_lines l on l.purchase_id = p.id group by p.id) x where x.total > 0
-- Supplier payments
union all select s.payment_date, '2000', s.amount, 0, 'supplier_payment', s.id, 'Supplier payment' from public.supplier_payments s
union all select s.payment_date, public.pay_account(s.method), 0, s.amount, 'supplier_payment', s.id, 'Supplier payment' from public.supplier_payments s
-- Production: inputs and outputs are both stock; labour/energy (other costs) are moved into stock value
union all select b.batch_date, '1200', b.other_cost, 0, 'production', b.batch_id, 'Production costs into stock' from public.batch_costs b where b.other_cost > 0
union all select b.batch_date, '5190', 0, b.other_cost, 'production', b.batch_id, 'Production costs into stock' from public.batch_costs b where b.other_cost > 0
-- Stock adjustments: write-offs and count differences; opening stock against opening balances
union all select a.adj_date, '1200', greatest(round(a.qty_change * coalesce(a.unit_cost, 0), 2), 0), greatest(-round(a.qty_change * coalesce(a.unit_cost, 0), 2), 0),
       'adjustment', a.id, 'Stock adjustment'
  from public.stock_adjustments a where round(a.qty_change * coalesce(a.unit_cost, 0), 2) <> 0
union all select a.adj_date, case when a.reason = 'opening' then '3900' else '5050' end,
       greatest(-round(a.qty_change * coalesce(a.unit_cost, 0), 2), 0), greatest(round(a.qty_change * coalesce(a.unit_cost, 0), 2), 0), 'adjustment', a.id, 'Stock adjustment'
  from public.stock_adjustments a where round(a.qty_change * coalesce(a.unit_cost, 0), 2) <> 0
-- Spa: completed treatments, by payment method
union all select (b.starts_at at time zone 'Africa/Accra')::date, public.pay_account(b.payment_method), b.paid_amount, 0, 'spa', b.id, 'Spa: ' || b.service_name
  from public.spa_bookings b where b.status = 'completed' and coalesce(b.paid_amount, 0) > 0 and b.payment_method is not null
union all select (b.starts_at at time zone 'Africa/Accra')::date, '4100', 0, b.paid_amount, 'spa', b.id, 'Spa: ' || b.service_name
  from public.spa_bookings b where b.status = 'completed' and coalesce(b.paid_amount, 0) > 0 and b.payment_method is not null
-- Expenses
union all select e.expense_date, e.account_code, e.amount, 0, 'expense', e.id, coalesce(e.description, e.payee, 'Expense') from public.expenses e
union all select e.expense_date, public.pay_account(e.paid_from), 0, e.amount, 'expense', e.id, coalesce(e.description, e.payee, 'Expense') from public.expenses e
-- Manual journals
union all select j.entry_date, l.account_code, l.debit, l.credit, case when j.kind = 'opening' then 'opening' else 'journal' end, j.id, coalesce(l.memo, j.memo)
  from public.journal_lines l join public.journals j on j.id = l.journal_id
-- Opening balances per customer (they owed us) and per supplier (we owed them), against 3900
union all select o.as_of, '1100', o.amount, 0, 'opening', o.id, 'Opening balance: ' || c.name
  from public.party_openings o join public.customers c on c.id = o.customer_id
union all select o.as_of, '3900', 0, o.amount, 'opening', o.id, 'Opening balance: ' || c.name
  from public.party_openings o join public.customers c on c.id = o.customer_id
union all select o.as_of, '3900', o.amount, 0, 'opening', o.id, 'Opening balance: ' || s.name
  from public.party_openings o join public.suppliers s on s.id = o.supplier_id
union all select o.as_of, '2000', 0, o.amount, 'opening', o.id, 'Opening balance: ' || s.name
  from public.party_openings o join public.suppliers s on s.id = o.supplier_id;


-- 4. Import log covers the new kinds; imported rows remember their import
alter table public.account_imports drop constraint if exists account_imports_kind_check;
alter table public.account_imports add constraint account_imports_kind_check check (kind in
  ('expenses', 'opening', 'journals', 'accounts', 'items', 'customers', 'suppliers', 'stock', 'purchases', 'sales', 'customer_payments', 'supplier_payments'));
alter table public.items             add column if not exists import_id uuid;
alter table public.customers         add column if not exists import_id uuid;
alter table public.suppliers         add column if not exists import_id uuid;
alter table public.stock_adjustments add column if not exists import_id uuid;
drop policy if exists account_imports_read on public.account_imports;
create policy account_imports_read on public.account_imports for select using (public.is_staff());

-- Helpers
create or replace function public.books_start() returns date language sql stable security definer set search_path = public as $$
  select start_date from public.books_settings where id = 1 $$;
create or replace function public.import_begin(p_kind text, p_file text, p_roles text[])
returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid := gen_random_uuid();
begin
  if not public.is_staff(p_roles) then raise exception 'Not allowed' using errcode = '42501'; end if;
  insert into public.account_imports (id, kind, file_name) values (v, p_kind, left(p_file, 200));
  return v;
end $$;
revoke execute on function public.import_begin(text, text, text[]) from public, anon, authenticated;

-- 5. Products and other items, with prices. Matched by name: new names are added,
--    existing ones get the unit, cost and prices given (blank = unchanged). The kind can't change.
--    p_rows: [{row, name, kind, unit, unit_cost, retail_price, wholesale_price}]
create or replace function public.import_items(p_file text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; r jsonb; it public.items; v_new int := 0; v_upd int := 0;
begin
  v_id := public.import_begin('items', p_file, array['admin', 'production', 'inventory']);
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      if coalesce(trim(r->>'name'), '') = '' then raise exception 'the name is missing'; end if;
      select * into it from public.items where lower(name) = lower(trim(r->>'name'));
      if found then
        if r->>'kind' is not null and r->>'kind' <> it.kind then raise exception '% is already recorded as %; the kind can''t be changed', it.name, it.kind; end if;
        update public.items set
          unit = coalesce(nullif(trim(r->>'unit'), ''), unit),
          unit_cost = coalesce((r->>'unit_cost')::numeric, unit_cost),
          retail_price = coalesce((r->>'retail_price')::numeric, retail_price),
          wholesale_price = coalesce((r->>'wholesale_price')::numeric, wholesale_price)
        where id = it.id;
        v_upd := v_upd + 1;
      else
        insert into public.items (name, kind, unit, unit_cost, retail_price, wholesale_price, import_id)
        values (trim(r->>'name'), r->>'kind', coalesce(nullif(trim(r->>'unit'), ''), 'unit'), coalesce((r->>'unit_cost')::numeric, 0),
                coalesce((r->>'retail_price')::numeric, 0), coalesce((r->>'wholesale_price')::numeric, 0), v_id);
        v_new := v_new + 1;
      end if;
    exception when others then raise exception 'Row %: %', coalesce(r->>'row', '?'), sqlerrm;
    end;
  end loop;
  update public.account_imports set row_count = v_new + v_upd where id = v_id;
  return jsonb_build_object('import_id', v_id, 'added', v_new, 'updated', v_upd);
end $$;

-- 6. Customers, with what each owed on the books start date.
--    p_rows: [{row, name, kind, price_tier, phone, email, address, notes, opening}]
create or replace function public.import_customers(p_file text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; r jsonb; c public.customers; v_cid uuid; v_new int := 0; v_upd int := 0; v_total numeric := 0; v_start date := public.books_start();
begin
  v_id := public.import_begin('customers', p_file, array['admin', 'sales', 'accounts']);
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      if coalesce(trim(r->>'name'), '') = '' then raise exception 'the name is missing'; end if;
      select * into c from public.customers where lower(name) = lower(trim(r->>'name'));
      if found then
        update public.customers set
          kind = coalesce(r->>'kind', kind), price_tier = coalesce(r->>'price_tier', price_tier),
          phone = coalesce(nullif(trim(r->>'phone'), ''), phone), email = coalesce(nullif(trim(r->>'email'), ''), email),
          address = coalesce(nullif(trim(r->>'address'), ''), address), notes = coalesce(nullif(trim(r->>'notes'), ''), notes)
        where id = c.id;
        v_cid := c.id; v_upd := v_upd + 1;
      else
        insert into public.customers (name, kind, price_tier, phone, email, address, notes, import_id)
        values (trim(r->>'name'), coalesce(r->>'kind', 'partner'), coalesce(r->>'price_tier', 'wholesale'),
                nullif(trim(r->>'phone'), ''), nullif(trim(r->>'email'), ''), nullif(trim(r->>'address'), ''), nullif(trim(r->>'notes'), ''), v_id)
        returning id into v_cid;
        v_new := v_new + 1;
      end if;
      if coalesce((r->>'opening')::numeric, 0) > 0 then
        if exists (select 1 from public.party_openings where customer_id = v_cid) then
          raise exception '% already has an opening balance; change it on the Sales page or undo the earlier import', trim(r->>'name');
        end if;
        insert into public.party_openings (customer_id, as_of, amount, import_id) values (v_cid, v_start, round((r->>'opening')::numeric, 2), v_id);
        v_total := v_total + round((r->>'opening')::numeric, 2);
      end if;
    exception when others then raise exception 'Row %: %', coalesce(r->>'row', '?'), sqlerrm;
    end;
  end loop;
  update public.account_imports set row_count = v_new + v_upd, total = v_total where id = v_id;
  return jsonb_build_object('import_id', v_id, 'added', v_new, 'updated', v_upd, 'opening', v_total);
end $$;

-- 7. Suppliers, with what was owed to each on the books start date.
--    p_rows: [{row, name, phone, email, notes, opening}]
create or replace function public.import_suppliers(p_file text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; r jsonb; s public.suppliers; v_sid uuid; v_new int := 0; v_upd int := 0; v_total numeric := 0; v_start date := public.books_start();
begin
  v_id := public.import_begin('suppliers', p_file, array['admin', 'inventory', 'accounts']);
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      if coalesce(trim(r->>'name'), '') = '' then raise exception 'the name is missing'; end if;
      select * into s from public.suppliers where lower(name) = lower(trim(r->>'name'));
      if found then
        update public.suppliers set phone = coalesce(nullif(trim(r->>'phone'), ''), phone), email = coalesce(nullif(trim(r->>'email'), ''), email),
          notes = coalesce(nullif(trim(r->>'notes'), ''), notes) where id = s.id;
        v_sid := s.id; v_upd := v_upd + 1;
      else
        insert into public.suppliers (name, phone, email, notes, import_id)
        values (trim(r->>'name'), nullif(trim(r->>'phone'), ''), nullif(trim(r->>'email'), ''), nullif(trim(r->>'notes'), ''), v_id)
        returning id into v_sid;
        v_new := v_new + 1;
      end if;
      if coalesce((r->>'opening')::numeric, 0) > 0 then
        if exists (select 1 from public.party_openings where supplier_id = v_sid) then
          raise exception '% already has an opening balance; undo the earlier import first', trim(r->>'name');
        end if;
        insert into public.party_openings (supplier_id, as_of, amount, import_id) values (v_sid, v_start, round((r->>'opening')::numeric, 2), v_id);
        v_total := v_total + round((r->>'opening')::numeric, 2);
      end if;
    exception when others then raise exception 'Row %: %', coalesce(r->>'row', '?'), sqlerrm;
    end;
  end loop;
  update public.account_imports set row_count = v_new + v_upd, total = v_total where id = v_id;
  return jsonb_build_object('import_id', v_id, 'added', v_new, 'updated', v_upd, 'opening', v_total);
end $$;

-- 8. Opening stock: quantity per item per location on the books start date (and its cost per unit,
--    if given; otherwise the item's current cost). One opening figure per item and location.
--    p_rows: [{row, item_id, location_id, qty, unit_cost}]
create or replace function public.import_opening_stock(p_file text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; r jsonb; v_n int := 0; v_total numeric := 0; v_start date := public.books_start(); v_cost numeric;
begin
  v_id := public.import_begin('stock', p_file, array['admin', 'inventory']);
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      if coalesce((r->>'qty')::numeric, 0) <= 0 then raise exception 'the quantity must be more than 0'; end if;
      if not exists (select 1 from public.items where id = (r->>'item_id')::uuid) then raise exception 'unknown item'; end if;
      if not exists (select 1 from public.locations where id = (r->>'location_id')::uuid) then raise exception 'unknown location'; end if;
      if exists (select 1 from public.stock_adjustments where reason = 'opening' and item_id = (r->>'item_id')::uuid and location_id = (r->>'location_id')::uuid) then
        raise exception 'this item already has opening stock at this location; undo the earlier import first, or use a stock count';
      end if;
      insert into public.stock_adjustments (adj_date, item_id, location_id, qty_change, reason, notes, unit_cost, import_id)
      values (v_start, (r->>'item_id')::uuid, (r->>'location_id')::uuid, (r->>'qty')::numeric, 'opening', 'Imported opening stock',
              (r->>'unit_cost')::numeric, v_id)
      returning unit_cost into v_cost;
      v_n := v_n + 1; v_total := v_total + round((r->>'qty')::numeric * coalesce(v_cost, 0), 2);
    exception when others then raise exception 'Row %: %', coalesce(r->>'row', '?'), sqlerrm;
    end;
  end loop;
  update public.account_imports set row_count = v_n, total = v_total where id = v_id;
  return jsonb_build_object('import_id', v_id, 'rows', v_n, 'value', v_total);
end $$;

-- 9. Undo any import. Records it created are removed; customers, suppliers and items it created
--    are removed only if nothing else uses them yet (otherwise they stay and are reported).
--    Changes it made to existing records (new prices, renamed accounts) are not reversed.
create or replace function public.undo_import(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare i public.account_imports; v_n int := 0; v_kept int := 0; x record; k int;
begin
  select * into i from public.account_imports where id = p_id for update;
  if not found then raise exception 'Import not found.'; end if;
  if not public.is_staff(case i.kind
      when 'items' then array['admin', 'production', 'inventory'] when 'customers' then array['admin', 'sales', 'accounts']
      when 'suppliers' then array['admin', 'inventory', 'accounts'] when 'stock' then array['admin', 'inventory']
      else array['admin', 'accounts'] end) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if i.undone_at is not null then raise exception 'This import has already been undone.'; end if;
  if i.kind = 'accounts' then raise exception 'Chart of accounts imports can''t be undone; change the names back on the Chart of accounts tab.'; end if;
  delete from public.expenses where import_id = p_id;            get diagnostics k = row_count; v_n := v_n + k;
  delete from public.journals where import_id = p_id;            get diagnostics k = row_count; v_n := v_n + k;
  delete from public.party_openings where import_id = p_id;      get diagnostics k = row_count; v_n := v_n + k;
  delete from public.stock_adjustments where import_id = p_id;   get diagnostics k = row_count; v_n := v_n + k;
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

-- The Accounts page's undo now uses the same function.
create or replace function public.undo_account_import(p_id uuid)
returns int language sql security definer set search_path = public as $$
  select (public.undo_import(p_id)->>'removed')::int $$;

grant execute on function public.books_start() to authenticated;
grant execute on function public.import_items(text, jsonb) to authenticated;
grant execute on function public.import_customers(text, jsonb) to authenticated;
grant execute on function public.import_suppliers(text, jsonb) to authenticated;
grant execute on function public.import_opening_stock(text, jsonb) to authenticated;
grant execute on function public.undo_import(uuid) to authenticated;
