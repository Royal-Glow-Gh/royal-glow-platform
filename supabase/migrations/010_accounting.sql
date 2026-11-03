-- =====================================================================
-- Royal Glow Platform — 010_accounting.sql
-- Double-entry accounting. The general ledger (gl_lines) is DERIVED from
-- the records the apps already keep (sales, returns, payments, purchases,
-- production, stock adjustments, spa), plus expenses, supplier payments
-- and manual journals entered on the Accounts page. Nothing is posted
-- twice and the books can't drift from operations.
-- Assumptions (changeable later): not VAT-registered; year Jan–Dec.
-- Requires 001–009. Safe to re-run.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. New staff role: accounts
-- ---------------------------------------------------------------------
alter table public.staff drop constraint if exists staff_roles_check;
alter table public.staff add constraint staff_roles_check
  check (cardinality(roles) > 0 and roles <@ array['admin','production','inventory','sales','spa','content','accounts']);

-- ---------------------------------------------------------------------
-- 2. Chart of accounts
--    category: cash (cash & equivalents), receivable, inventory, fixed,
--    payable, cogs — used by the reports to group lines.
-- ---------------------------------------------------------------------
create table if not exists public.accounts (
  code      text primary key check (code ~ '^[0-9]{4}$'),
  name      text not null,
  type      text not null check (type in ('asset', 'liability', 'equity', 'income', 'expense')),
  category  text,
  is_system boolean not null default false,   -- used by automatic postings; can't be removed
  active    boolean not null default true
);

insert into public.accounts (code, name, type, category, is_system) values
  ('1000', 'Cash on hand',                         'asset',     'cash',       true),
  ('1010', 'Mobile money',                         'asset',     'cash',       true),
  ('1020', 'Bank',                                 'asset',     'cash',       true),
  ('1100', 'Accounts receivable (customers owe)',  'asset',     'receivable', true),
  ('1200', 'Inventory (stock)',                    'asset',     'inventory',  true),
  ('1500', 'Equipment and fixed assets',           'asset',     'fixed',      false),
  ('1510', 'Accumulated depreciation',             'asset',     'fixed',      false),
  ('2000', 'Accounts payable (we owe suppliers)',  'liability', 'payable',    true),
  ('2200', 'Loans',                                'liability', null,         false),
  ('2300', 'Taxes payable',                        'liability', null,         false),
  ('3000', 'Owner''s capital',                     'equity',    null,         false),
  ('3100', 'Retained earnings',                    'equity',    null,         false),
  ('3200', 'Owner''s drawings',                    'equity',    null,         false),
  ('3900', 'Opening balances',                     'equity',    null,         true),
  ('4000', 'Product sales',                        'income',    null,         true),
  ('4010', 'Sales discounts',                      'income',    null,         true),
  ('4020', 'Sales returns',                        'income',    null,         true),
  ('4100', 'Spa services',                         'income',    null,         true),
  ('4900', 'Other income',                         'income',    null,         false),
  ('5000', 'Cost of goods sold',                   'expense',   'cogs',       true),
  ('5050', 'Stock adjustments and write-offs',     'expense',   'cogs',       true),
  ('5190', 'Production costs moved into stock',    'expense',   'cogs',       true),
  ('6000', 'Salaries and wages',                   'expense',   null,         false),
  ('6100', 'Rent',                                 'expense',   null,         false),
  ('6200', 'Utilities (electricity, water)',       'expense',   null,         false),
  ('6300', 'Transport and delivery',               'expense',   null,         false),
  ('6400', 'Marketing and advertising',            'expense',   null,         false),
  ('6500', 'Phone and internet',                   'expense',   null,         false),
  ('6600', 'Repairs and maintenance',              'expense',   null,         false),
  ('6700', 'Bank and MoMo charges',                'expense',   null,         false),
  ('6800', 'Office and administration',            'expense',   null,         false),
  ('6900', 'Depreciation',                         'expense',   null,         false),
  ('6950', 'Other expenses',                       'expense',   null,         false)
on conflict (code) do nothing;

create or replace function public.protect_system_accounts()
returns trigger language plpgsql as $$
begin
  if old.is_system then raise exception 'This account is used by automatic postings and cannot be removed.'; end if;
  return old;
end $$;
drop trigger if exists trg_protect_system_accounts on public.accounts;
create trigger trg_protect_system_accounts before delete on public.accounts
  for each row execute function public.protect_system_accounts();

-- Which account money goes in or out of, by payment method
create or replace function public.pay_account(p_method text)
returns text language sql immutable as $$
  select case p_method
    when 'cash' then '1000' when 'momo' then '1010'
    when 'card' then '1020' when 'bank' then '1020'
    when 'credit' then '1100' when 'payable' then '2000'
  end;
$$;

-- ---------------------------------------------------------------------
-- 3. Purchases can be paid now or on credit; supplier payments settle credit
-- ---------------------------------------------------------------------
alter table public.purchases
  add column if not exists payment_method text not null default 'cash'
  check (payment_method in ('cash', 'momo', 'bank', 'card', 'credit'));

create table if not exists public.supplier_payments (
  id           uuid primary key default gen_random_uuid(),
  supplier_id  uuid not null references public.suppliers(id),
  payment_date date not null default current_date,
  amount       numeric(12,2) not null check (amount > 0),
  method       text not null check (method in ('cash', 'momo', 'bank', 'card')),
  ref          text,
  notes        text,
  created_by   uuid references auth.users(id) default auth.uid(),
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. Cost snapshots on stock adjustments and returns, so past values
--    never change when costs move later
-- ---------------------------------------------------------------------
alter table public.stock_adjustments add column if not exists unit_cost numeric(12,4);
alter table public.sale_returns      add column if not exists unit_cost numeric(12,4);

create or replace function public.snapshot_unit_cost()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.unit_cost is null then
    select c.current_unit_cost into new.unit_cost from public.item_current_cost c where c.id = new.item_id;
    new.unit_cost := coalesce(new.unit_cost, 0);
  end if;
  return new;
end $$;
drop trigger if exists trg_snapshot_cost_adj on public.stock_adjustments;
create trigger trg_snapshot_cost_adj before insert on public.stock_adjustments
  for each row execute function public.snapshot_unit_cost();
drop trigger if exists trg_snapshot_cost_ret on public.sale_returns;
create trigger trg_snapshot_cost_ret before insert on public.sale_returns
  for each row execute function public.snapshot_unit_cost();

update public.stock_adjustments a set unit_cost = coalesce(c.current_unit_cost, 0)
from public.item_current_cost c where c.id = a.item_id and a.unit_cost is null;
update public.sale_returns r set unit_cost = coalesce(c.current_unit_cost, 0)
from public.item_current_cost c where c.id = r.item_id and r.unit_cost is null;

-- ---------------------------------------------------------------------
-- 5. Expenses (rent, salaries, utilities …)
-- ---------------------------------------------------------------------
create table if not exists public.expenses (
  id           uuid primary key default gen_random_uuid(),
  expense_date date not null default current_date,
  account_code text not null references public.accounts(code),
  amount       numeric(12,2) not null check (amount > 0),
  paid_from    text not null check (paid_from in ('cash', 'momo', 'bank', 'card', 'payable')),
  supplier_id  uuid references public.suppliers(id),   -- required when unpaid (payable)
  payee        text,
  description  text,
  created_by   uuid references auth.users(id) default auth.uid(),
  created_at   timestamptz not null default now(),
  check (paid_from <> 'payable' or supplier_id is not null)
);

create or replace function public.check_expense_account()
returns trigger language plpgsql as $$
begin
  if (select type from public.accounts where code = new.account_code) <> 'expense' then
    raise exception 'Choose an expense account.';
  end if;
  return new;
end $$;
drop trigger if exists trg_check_expense_account on public.expenses;
create trigger trg_check_expense_account before insert or update on public.expenses
  for each row execute function public.check_expense_account();

-- ---------------------------------------------------------------------
-- 6. Manual journals (capital, loans, equipment, depreciation, opening balances)
--    Created only through post_journal(), which checks they balance.
-- ---------------------------------------------------------------------
create table if not exists public.journals (
  id         uuid primary key default gen_random_uuid(),
  entry_date date not null,
  memo       text not null,
  kind       text not null default 'manual' check (kind in ('manual', 'opening')),
  created_by uuid references auth.users(id) default auth.uid(),
  created_at timestamptz not null default now()
);
create table if not exists public.journal_lines (
  id           uuid primary key default gen_random_uuid(),
  journal_id   uuid not null references public.journals(id) on delete cascade,
  account_code text not null references public.accounts(code),
  debit        numeric(14,2) not null default 0 check (debit >= 0),
  credit       numeric(14,2) not null default 0 check (credit >= 0),
  memo         text,
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0))
);

create or replace function public.post_journal(p_date date, p_memo text, p_kind text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_dr numeric := 0; v_cr numeric := 0; v_line jsonb; v_n int := 0;
begin
  if not public.is_staff(array['admin', 'accounts']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if coalesce(trim(p_memo), '') = '' then raise exception 'Describe the journal.'; end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    if not exists (select 1 from public.accounts where code = v_line->>'account_code' and active) then
      raise exception 'Unknown account %.', v_line->>'account_code';
    end if;
    v_dr := v_dr + coalesce((v_line->>'debit')::numeric, 0);
    v_cr := v_cr + coalesce((v_line->>'credit')::numeric, 0);
    v_n := v_n + 1;
  end loop;
  if v_n < 2 then raise exception 'A journal needs at least two lines.'; end if;
  if round(v_dr, 2) <> round(v_cr, 2) or v_dr = 0 then
    raise exception 'Debits (%) and credits (%) must be equal.', round(v_dr, 2), round(v_cr, 2);
  end if;
  insert into public.journals (entry_date, memo, kind) values (p_date, trim(p_memo), coalesce(p_kind, 'manual'))
  returning id into v_id;
  insert into public.journal_lines (journal_id, account_code, debit, credit, memo)
  select v_id, l->>'account_code', round(coalesce((l->>'debit')::numeric, 0), 2),
         round(coalesce((l->>'credit')::numeric, 0), 2), nullif(trim(l->>'memo'), '')
  from jsonb_array_elements(p_lines) l
  where coalesce((l->>'debit')::numeric, 0) > 0 or coalesce((l->>'credit')::numeric, 0) > 0;
  return v_id;
end $$;
grant execute on function public.post_journal(date, text, text, jsonb) to authenticated;

-- ---------------------------------------------------------------------
-- 7. The general ledger: every line, from every source
-- ---------------------------------------------------------------------
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
  from public.journal_lines l join public.journals j on j.id = l.journal_id;

-- Totals per account: before the period and within it (reports are built from this)
create or replace function public.gl_summary(p_from date, p_to date)
returns table (code text, name text, type text, category text,
               before_debit numeric, before_credit numeric, period_debit numeric, period_credit numeric)
language sql stable as $$
  select a.code, a.name, a.type, a.category,
         coalesce(sum(g.debit)  filter (where g.entry_date <  p_from), 0),
         coalesce(sum(g.credit) filter (where g.entry_date <  p_from), 0),
         coalesce(sum(g.debit)  filter (where g.entry_date >= p_from), 0),
         coalesce(sum(g.credit) filter (where g.entry_date >= p_from), 0)
  from public.accounts a
  left join public.gl_lines g on g.account_code = a.code and g.entry_date <= p_to
  group by a.code, a.name, a.type, a.category
  order by a.code;
$$;
grant execute on function public.gl_summary(date, date) to authenticated;

-- Supplier balances (what we owe each supplier)
create or replace view public.supplier_balances
with (security_invoker = true) as
select s.id as supplier_id, s.name,
  coalesce((select sum(x.t) from (select round(sum(l.qty * l.unit_cost), 2) as t from public.purchases p join public.purchase_lines l on l.purchase_id = p.id
            where p.supplier_id = s.id and p.payment_method = 'credit' group by p.id) x), 0)
+ coalesce((select sum(e.amount) from public.expenses e where e.supplier_id = s.id and e.paid_from = 'payable'), 0)
- coalesce((select sum(sp.amount) from public.supplier_payments sp where sp.supplier_id = s.id), 0) as balance
from public.suppliers s;

-- ---------------------------------------------------------------------
-- 8. Row Level Security
-- ---------------------------------------------------------------------
alter table public.accounts enable row level security;
drop policy if exists accounts_read on public.accounts;
drop policy if exists accounts_write on public.accounts;
create policy accounts_read on public.accounts for select using (public.is_staff());
create policy accounts_write on public.accounts for all
  using (public.is_staff(array['admin', 'accounts'])) with check (public.is_staff(array['admin', 'accounts']));

-- Expenses and journals can include salaries: only admin + accounts see them
do $$
declare t text;
begin
  foreach t in array array['expenses', 'journals'] loop
    execute format('alter table public.%1$s enable row level security', t);
    execute format('drop policy if exists %1$s_all on public.%1$s', t);
    execute format($p$create policy %1$s_all on public.%1$s for all
                     using (public.is_staff(array['admin','accounts']))
                     with check (public.is_staff(array['admin','accounts']))$p$, t);
  end loop;
end $$;
alter table public.journal_lines enable row level security;
drop policy if exists journal_lines_read on public.journal_lines;
create policy journal_lines_read on public.journal_lines for select using (public.is_staff(array['admin', 'accounts']));

alter table public.supplier_payments enable row level security;
drop policy if exists supplier_payments_read  on public.supplier_payments;
drop policy if exists supplier_payments_write on public.supplier_payments;
create policy supplier_payments_read on public.supplier_payments for select using (public.is_staff());
create policy supplier_payments_write on public.supplier_payments for all
  using (public.is_staff(array['admin', 'accounts', 'inventory'])) with check (public.is_staff(array['admin', 'accounts', 'inventory']));

-- ---------------------------------------------------------------------
-- 9. Cash flow (direct method) for a period: money in and out of
--    cash, mobile money and bank, grouped by what caused it
-- ---------------------------------------------------------------------
create or replace function public.cash_flow(p_from date, p_to date)
returns table (section text, label text, money_in numeric, money_out numeric)
language sql stable as $$
  with cashacc as (select code from public.accounts where category = 'cash'),
  lines as (
    select g.*,
      case
        when g.source in ('sale', 'customer_payment', 'spa', 'return', 'purchase', 'supplier_payment', 'expense') then 'Operating'
        when exists (select 1 from public.journal_lines jl join public.accounts a on a.code = jl.account_code
                     where jl.journal_id = g.source_id and (a.type = 'equity' or a.code = '2200')) then 'Financing'
        when exists (select 1 from public.journal_lines jl join public.accounts a on a.code = jl.account_code
                     where jl.journal_id = g.source_id and a.category = 'fixed') then 'Investing'
        when not exists (select 1 from public.journal_lines jl
                         where jl.journal_id = g.source_id and jl.account_code not in (select code from cashacc)) then 'Transfers'
        else 'Operating'
      end as section,
      case g.source
        when 'sale' then 'Sales received'
        when 'customer_payment' then 'Payments from customers'
        when 'spa' then 'Spa treatments'
        when 'return' then 'Refunds to customers'
        when 'purchase' then 'Purchases paid'
        when 'supplier_payment' then 'Payments to suppliers'
        when 'expense' then 'Expenses paid'
        else coalesce((select j.memo from public.journals j where j.id = g.source_id), 'Journal')
      end as label
    from public.gl_lines g
    where g.entry_date between p_from and p_to and g.account_code in (select code from cashacc)
  )
  select section, label, sum(debit), sum(credit)
  from lines where section <> 'Transfers'
  group by section, label
  order by case section when 'Operating' then 1 when 'Investing' then 2 else 3 end, sum(debit) desc, sum(credit) desc;
$$;
grant execute on function public.cash_flow(date, date) to authenticated;

-- One account's lines for a period, with the balance brought forward
create or replace function public.account_ledger(p_code text, p_from date, p_to date)
returns table (entry_date date, source text, source_id uuid, memo text, debit numeric, credit numeric, opening numeric)
language sql stable as $$
  select g.entry_date, g.source, g.source_id, g.memo, g.debit, g.credit,
         (select coalesce(sum(o.debit - o.credit), 0) from public.gl_lines o
          where o.account_code = p_code and o.entry_date < p_from)
  from public.gl_lines g
  where g.account_code = p_code and g.entry_date between p_from and p_to
  order by g.entry_date, g.source, g.source_id;
$$;
grant execute on function public.account_ledger(text, date, date) to authenticated;
