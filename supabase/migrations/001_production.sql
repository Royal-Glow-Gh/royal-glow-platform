-- =====================================================================
-- Royal Glow Platform — 001_production.sql
-- Production batch costing: items, batches, batch inputs.
-- Run once in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Staff: who may use the internal (non-customer) apps
-- ---------------------------------------------------------------------
create table if not exists public.staff (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  full_name  text not null,
  role       text not null default 'production'
             check (role in ('admin', 'production', 'sales', 'inventory')),
  created_at timestamptz not null default now()
);

-- Helper used by every internal policy. SECURITY DEFINER lets it read
-- the staff table without tripping that table's own RLS.
create or replace function public.is_staff(roles text[] default null)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff s
    where s.user_id = auth.uid()
      and (roles is null or s.role = any(roles))
  );
$$;

-- ---------------------------------------------------------------------
-- 2. Items: raw materials, packaging, labels, and in-house products
--    (a product can also be an input to another product, e.g. carrot oil)
-- ---------------------------------------------------------------------
create table if not exists public.items (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  kind       text not null check (kind in ('raw', 'packaging', 'label', 'product')),
  unit       text not null default 'unit',          -- kg, L, piece, jar ...
  unit_cost  numeric(12,4) not null default 0       -- GHS; for products, a fallback only
             check (unit_cost >= 0),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. Batches: one production run of one product
-- ---------------------------------------------------------------------
create table if not exists public.batches (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references public.items(id),
  batch_date  date not null default current_date,
  code        text unique,                           -- e.g. BB-2026-05
  output_qty  numeric(12,3) not null check (output_qty > 0),
  other_cost  numeric(12,2) not null default 0 check (other_cost >= 0),  -- labour, energy
  notes       text,
  created_by  uuid references auth.users(id) default auth.uid(),
  created_at  timestamptz not null default now()
);

create index if not exists batches_product_date_idx
  on public.batches (product_id, batch_date);

-- ---------------------------------------------------------------------
-- 4. Batch inputs: what each batch consumed.
--    unit_cost is a SNAPSHOT at the time of the batch, so later price
--    changes never rewrite history.
-- ---------------------------------------------------------------------
create table if not exists public.batch_inputs (
  id         uuid primary key default gen_random_uuid(),
  batch_id   uuid not null references public.batches(id) on delete cascade,
  item_id    uuid not null references public.items(id),
  qty        numeric(12,4) not null check (qty > 0),
  unit_cost  numeric(12,4) not null check (unit_cost >= 0),
  unique (batch_id, item_id)
);

create index if not exists batch_inputs_item_idx on public.batch_inputs (item_id);

-- ---------------------------------------------------------------------
-- 5. Integrity rules a CHECK constraint cannot express
-- ---------------------------------------------------------------------
-- Batches must make a product, not a raw material.
create or replace function public.check_batch_product()
returns trigger language plpgsql as $$
begin
  if (select kind from public.items where id = new.product_id) <> 'product' then
    raise exception 'Batch product must be an item of kind "product"';
  end if;
  return new;
end $$;

drop trigger if exists trg_check_batch_product on public.batches;
create trigger trg_check_batch_product
  before insert or update of product_id on public.batches
  for each row execute function public.check_batch_product();

-- A product cannot be an input to its own batch.
create or replace function public.check_input_not_self()
returns trigger language plpgsql as $$
begin
  if new.item_id = (select product_id from public.batches where id = new.batch_id) then
    raise exception 'A product cannot be an input to its own batch';
  end if;
  return new;
end $$;

drop trigger if exists trg_check_input_not_self on public.batch_inputs;
create trigger trg_check_input_not_self
  before insert or update on public.batch_inputs
  for each row execute function public.check_input_not_self();

-- ---------------------------------------------------------------------
-- 6. Reporting views
-- ---------------------------------------------------------------------
-- Cost per batch and per unit.
create or replace view public.batch_costs
with (security_invoker = true) as
select
  b.id            as batch_id,
  b.batch_date,
  b.code,
  b.product_id,
  p.name          as product,
  p.unit,
  b.output_qty,
  coalesce(sum(bi.qty * bi.unit_cost), 0)                  as input_cost,
  b.other_cost,
  coalesce(sum(bi.qty * bi.unit_cost), 0) + b.other_cost   as total_cost,
  (coalesce(sum(bi.qty * bi.unit_cost), 0) + b.other_cost) / b.output_qty
                                                           as cost_per_unit
from public.batches b
join public.items p on p.id = b.product_id
left join public.batch_inputs bi on bi.batch_id = b.id
group by b.id, p.id;

-- Current unit cost of every item: purchase price for materials,
-- latest batch cost for in-house products.
create or replace view public.item_current_cost
with (security_invoker = true) as
select
  i.id, i.name, i.kind, i.unit,
  case
    when i.kind = 'product' then coalesce(
      (select bc.cost_per_unit from public.batch_costs bc
        where bc.product_id = i.id
        order by bc.batch_date desc, bc.batch_id desc limit 1),
      i.unit_cost)
    else i.unit_cost
  end as current_unit_cost
from public.items i;

-- ---------------------------------------------------------------------
-- 7. Row Level Security: staff only. Customers (who will also have
--    Supabase logins for the shop and blog) see none of this.
-- ---------------------------------------------------------------------
alter table public.staff        enable row level security;
alter table public.items        enable row level security;
alter table public.batches      enable row level security;
alter table public.batch_inputs enable row level security;

-- staff: everyone on staff can see the list; only admins manage it
drop policy if exists staff_read  on public.staff;
drop policy if exists staff_admin on public.staff;
create policy staff_read  on public.staff for select using (public.is_staff());
create policy staff_admin on public.staff for all
  using (public.is_staff(array['admin'])) with check (public.is_staff(array['admin']));

-- items / batches / inputs: all staff read; admin + production write
do $$
declare t text;
begin
  foreach t in array array['items', 'batches', 'batch_inputs'] loop
    execute format('drop policy if exists %1$s_read  on public.%1$s', t);
    execute format('drop policy if exists %1$s_write on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select using (public.is_staff())', t);
    execute format($p$create policy %1$s_write on public.%1$s for all
                     using (public.is_staff(array['admin','production']))
                     with check (public.is_staff(array['admin','production']))$p$, t);
  end loop;
end $$;
