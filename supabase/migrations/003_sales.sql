-- =====================================================================
-- Royal Glow Platform — 003_sales.sql
-- Sales: selling prices, customers (partners, wholesale, retail),
-- sales from any location, credit and payments, returns.
-- Requires 001_production.sql and 002_inventory.sql. Safe to run more than once.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Selling prices on items
-- ---------------------------------------------------------------------
alter table public.items
  add column if not exists retail_price    numeric(12,2) not null default 0 check (retail_price >= 0),
  add column if not exists wholesale_price numeric(12,2) not null default 0 check (wholesale_price >= 0);

-- ---------------------------------------------------------------------
-- 2. Customers
--    partner   = partner shops / pharmacies (usually on credit)
--    wholesale = stockists, wholesalers, distributors
--    retail    = named retail customers (walk-ins need no record)
-- ---------------------------------------------------------------------
create table if not exists public.customers (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique,
  kind        text not null default 'partner' check (kind in ('partner', 'wholesale', 'retail')),
  price_tier  text not null default 'wholesale' check (price_tier in ('retail', 'wholesale')),
  phone       text,
  email       text,
  address     text,
  notes       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. Sales (stock out from the selling location)
-- ---------------------------------------------------------------------
create table if not exists public.sales (
  id             uuid primary key default gen_random_uuid(),
  sale_date      date not null default current_date,
  location_id    uuid not null references public.locations(id) default public.default_factory(),
  customer_id    uuid references public.customers(id),          -- null = walk-in
  payment_method text not null check (payment_method in ('cash', 'momo', 'card', 'bank', 'credit')),
  receipt_no     text,
  discount       numeric(12,2) not null default 0 check (discount >= 0),
  notes          text,
  created_by     uuid references auth.users(id) default auth.uid(),
  created_at     timestamptz not null default now(),
  check (payment_method <> 'credit' or customer_id is not null)  -- credit needs a named customer
);
create index if not exists sales_date_idx on public.sales (sale_date);

create table if not exists public.sale_lines (
  id         uuid primary key default gen_random_uuid(),
  sale_id    uuid not null references public.sales(id) on delete cascade,
  item_id    uuid not null references public.items(id),
  qty        numeric(12,4) not null check (qty > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  unit_cost  numeric(12,4) not null default 0 check (unit_cost >= 0),  -- snapshot, for margins
  unique (sale_id, item_id)
);
create index if not exists sale_lines_item_idx on public.sale_lines (item_id);

-- ---------------------------------------------------------------------
-- 4. Payments received from customers against their credit balance
-- ---------------------------------------------------------------------
create table if not exists public.customer_payments (
  id           uuid primary key default gen_random_uuid(),
  customer_id  uuid not null references public.customers(id),
  payment_date date not null default current_date,
  amount       numeric(12,2) not null check (amount > 0),
  method       text not null check (method in ('cash', 'momo', 'card', 'bank')),
  ref          text,
  notes        text,
  created_by   uuid references auth.users(id) default auth.uid(),
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 5. Returns (e.g. unsold goods back from a partner shop)
--    restock = false for damaged goods: credited, but not put back into stock
-- ---------------------------------------------------------------------
create table if not exists public.sale_returns (
  id          uuid primary key default gen_random_uuid(),
  return_date date not null default current_date,
  customer_id uuid references public.customers(id),
  location_id uuid not null references public.locations(id),
  item_id     uuid not null references public.items(id),
  qty         numeric(12,4) not null check (qty > 0),
  unit_price  numeric(12,2) not null default 0 check (unit_price >= 0),  -- credit value per unit
  reason      text not null check (reason in ('unsold', 'damaged', 'customer_return', 'other')),
  restock     boolean not null default true,
  notes       text,
  created_by  uuid references auth.users(id) default auth.uid(),
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 6. Stock ledger now includes sales (out) and restocked returns (in)
-- ---------------------------------------------------------------------
create or replace view public.stock_ledger
with (security_invoker = true) as
select pl.item_id, p.location_id, p.purchase_date as move_date,
       pl.qty as qty_change, 'purchase'::text as source,
       p.id as ref_id, coalesce(p.ref, '') as ref, p.created_at
from public.purchase_lines pl join public.purchases p on p.id = pl.purchase_id
union all
select bi.item_id, coalesce(b.location_id, public.default_factory()), b.batch_date,
       -bi.qty, 'production_use', b.id, coalesce(b.code, ''), b.created_at
from public.batch_inputs bi join public.batches b on b.id = bi.batch_id
union all
select b.product_id, coalesce(b.location_id, public.default_factory()), b.batch_date,
       b.output_qty, 'production_output', b.id, coalesce(b.code, ''), b.created_at
from public.batches b
union all
select tl.item_id, t.from_location, t.transfer_date,
       -tl.qty, 'transfer_out', t.id, '', t.created_at
from public.transfer_lines tl join public.transfers t on t.id = tl.transfer_id
union all
select tl.item_id, t.to_location, t.transfer_date,
       tl.qty, 'transfer_in', t.id, '', t.created_at
from public.transfer_lines tl join public.transfers t on t.id = tl.transfer_id
union all
select a.item_id, a.location_id, a.adj_date,
       a.qty_change, 'adjustment', a.id, a.reason, a.created_at
from public.stock_adjustments a
union all
select sl.item_id, s.location_id, s.sale_date,
       -sl.qty, 'sale', s.id, coalesce(s.receipt_no, ''), s.created_at
from public.sale_lines sl join public.sales s on s.id = sl.sale_id
union all
select r.item_id, r.location_id, r.return_date,
       r.qty, 'return', r.id, r.reason, r.created_at
from public.sale_returns r where r.restock;

-- ---------------------------------------------------------------------
-- 7. Reporting views
-- ---------------------------------------------------------------------
create or replace view public.sale_totals
with (security_invoker = true) as
select s.id as sale_id, s.sale_date, s.location_id, s.customer_id, s.payment_method,
       coalesce(sum(sl.qty * sl.unit_price), 0)                as gross,
       s.discount,
       coalesce(sum(sl.qty * sl.unit_price), 0) - s.discount   as total,
       coalesce(sum(sl.qty * sl.unit_cost), 0)                 as cost
from public.sales s
left join public.sale_lines sl on sl.sale_id = s.id
group by s.id;

create or replace view public.customer_balances
with (security_invoker = true) as
select c.id as customer_id, c.name,
       coalesce((select sum(t.total) from public.sale_totals t
                 where t.customer_id = c.id and t.payment_method = 'credit'), 0) as credit_sales,
       coalesce((select sum(r.qty * r.unit_price) from public.sale_returns r
                 where r.customer_id = c.id), 0)                                as returns_credit,
       coalesce((select sum(p.amount) from public.customer_payments p
                 where p.customer_id = c.id), 0)                                as payments,
       coalesce((select sum(t.total) from public.sale_totals t
                 where t.customer_id = c.id and t.payment_method = 'credit'), 0)
     - coalesce((select sum(r.qty * r.unit_price) from public.sale_returns r
                 where r.customer_id = c.id), 0)
     - coalesce((select sum(p.amount) from public.customer_payments p
                 where p.customer_id = c.id), 0)                                as balance
from public.customers c;

-- ---------------------------------------------------------------------
-- 8. Sales staff can set selling prices (items stay admin/production-editable)
-- ---------------------------------------------------------------------
create or replace function public.set_prices(p_item uuid, p_retail numeric, p_wholesale numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff(array['admin', 'sales']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  update public.items
  set retail_price = greatest(coalesce(p_retail, 0), 0),
      wholesale_price = greatest(coalesce(p_wholesale, 0), 0)
  where id = p_item;
end $$;

-- ---------------------------------------------------------------------
-- 9. Row Level Security: all staff read; admin + sales write
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['customers', 'sales', 'sale_lines', 'customer_payments', 'sale_returns'] loop
    execute format('alter table public.%1$s enable row level security', t);
    execute format('drop policy if exists %1$s_read  on public.%1$s', t);
    execute format('drop policy if exists %1$s_write on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select using (public.is_staff())', t);
    execute format($p$create policy %1$s_write on public.%1$s for all
                     using (public.is_staff(array['admin','sales']))
                     with check (public.is_staff(array['admin','sales']))$p$, t);
  end loop;
end $$;
