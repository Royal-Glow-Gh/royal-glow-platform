-- =====================================================================
-- Royal Glow Platform — 002_inventory.sql
-- Inventory: locations, suppliers, purchases, transfers, adjustments,
-- and a stock ledger that also reads production batches.
-- Requires 001_production.sql. Safe to run more than once.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Items: allow goods bought for resale (accessories, complementary
--    products) and add a reorder level.
-- ---------------------------------------------------------------------
alter table public.items drop constraint if exists items_kind_check;
alter table public.items add constraint items_kind_check
  check (kind in ('raw', 'packaging', 'label', 'product', 'goods'));

alter table public.items
  add column if not exists reorder_level numeric(12,3) not null default 0
  check (reorder_level >= 0);

-- ---------------------------------------------------------------------
-- 2. Locations: where stock is held
-- ---------------------------------------------------------------------
create table if not exists public.locations (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  kind       text not null check (kind in ('factory', 'warehouse', 'shop')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.locations (name, kind)
select 'Factory', 'factory'
where not exists (select 1 from public.locations where kind = 'factory');

create or replace function public.default_factory()
returns uuid language sql stable security definer set search_path = public as $$
  select id from public.locations where kind = 'factory' order by created_at limit 1;
$$;

-- Production batches happen at a location (default: the factory)
alter table public.batches
  add column if not exists location_id uuid references public.locations(id)
  default public.default_factory();
update public.batches set location_id = public.default_factory() where location_id is null;

-- ---------------------------------------------------------------------
-- 3. Suppliers
-- ---------------------------------------------------------------------
create table if not exists public.suppliers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  phone      text,
  email      text,
  notes      text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. Purchases (stock in)
-- ---------------------------------------------------------------------
create table if not exists public.purchases (
  id            uuid primary key default gen_random_uuid(),
  supplier_id   uuid references public.suppliers(id),
  location_id   uuid not null references public.locations(id) default public.default_factory(),
  purchase_date date not null default current_date,
  ref           text,                      -- invoice / receipt number
  notes         text,
  created_by    uuid references auth.users(id) default auth.uid(),
  created_at    timestamptz not null default now()
);

create table if not exists public.purchase_lines (
  id          uuid primary key default gen_random_uuid(),
  purchase_id uuid not null references public.purchases(id) on delete cascade,
  item_id     uuid not null references public.items(id),
  qty         numeric(12,4) not null check (qty > 0),
  unit_cost   numeric(12,4) not null check (unit_cost >= 0),
  unique (purchase_id, item_id)
);
create index if not exists purchase_lines_item_idx on public.purchase_lines (item_id);

-- The latest purchase price becomes the item's current unit cost,
-- so the production app prefills it for new batches.
create or replace function public.update_cost_from_purchase()
returns trigger language plpgsql security definer set search_path = public as $$
declare d date;
begin
  select purchase_date into d from public.purchases where id = new.purchase_id;
  if not exists (
    select 1 from public.purchase_lines pl
    join public.purchases p on p.id = pl.purchase_id
    where pl.item_id = new.item_id and pl.id <> new.id and p.purchase_date > d
  ) then
    update public.items set unit_cost = new.unit_cost
    where id = new.item_id and kind <> 'product';
  end if;
  return new;
end $$;

drop trigger if exists trg_update_cost_from_purchase on public.purchase_lines;
create trigger trg_update_cost_from_purchase
  after insert on public.purchase_lines
  for each row execute function public.update_cost_from_purchase();

-- ---------------------------------------------------------------------
-- 5. Transfers between locations (e.g. factory -> shop)
-- ---------------------------------------------------------------------
create table if not exists public.transfers (
  id            uuid primary key default gen_random_uuid(),
  transfer_date date not null default current_date,
  from_location uuid not null references public.locations(id),
  to_location   uuid not null references public.locations(id),
  notes         text,
  created_by    uuid references auth.users(id) default auth.uid(),
  created_at    timestamptz not null default now(),
  check (from_location <> to_location)
);

create table if not exists public.transfer_lines (
  id          uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.transfers(id) on delete cascade,
  item_id     uuid not null references public.items(id),
  qty         numeric(12,4) not null check (qty > 0),
  unique (transfer_id, item_id)
);

-- ---------------------------------------------------------------------
-- 6. Adjustments: opening balances, stock counts, damage, expiry ...
-- ---------------------------------------------------------------------
create table if not exists public.stock_adjustments (
  id          uuid primary key default gen_random_uuid(),
  adj_date    date not null default current_date,
  item_id     uuid not null references public.items(id),
  location_id uuid not null references public.locations(id),
  qty_change  numeric(12,4) not null check (qty_change <> 0),
  reason      text not null check (reason in
              ('opening', 'count', 'damaged', 'expired', 'internal_use', 'other')),
  notes       text,
  created_by  uuid references auth.users(id) default auth.uid(),
  created_at  timestamptz not null default now()
);
create index if not exists stock_adjustments_item_idx on public.stock_adjustments (item_id);

-- ---------------------------------------------------------------------
-- 7. Stock ledger: every movement, from every source, in one view.
--    Nothing is stored twice; stock is always derived from the records.
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
from public.stock_adjustments a;

create or replace view public.stock_on_hand
with (security_invoker = true) as
select item_id, location_id, sum(qty_change) as qty
from public.stock_ledger
group by item_id, location_id;

-- ---------------------------------------------------------------------
-- 8. Reorder levels can be set by inventory staff too
--    (items themselves stay admin/production-editable).
-- ---------------------------------------------------------------------
create or replace function public.set_reorder_level(p_item uuid, p_level numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff(array['admin', 'inventory', 'production']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  update public.items set reorder_level = greatest(p_level, 0) where id = p_item;
end $$;

-- ---------------------------------------------------------------------
-- 9. Row Level Security: all staff read; admin + inventory write
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['locations', 'suppliers', 'purchases', 'purchase_lines',
                           'transfers', 'transfer_lines', 'stock_adjustments'] loop
    execute format('alter table public.%1$s enable row level security', t);
    execute format('drop policy if exists %1$s_read  on public.%1$s', t);
    execute format('drop policy if exists %1$s_write on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select using (public.is_staff())', t);
    execute format($p$create policy %1$s_write on public.%1$s for all
                     using (public.is_staff(array['admin','inventory']))
                     with check (public.is_staff(array['admin','inventory']))$p$, t);
  end loop;
end $$;
