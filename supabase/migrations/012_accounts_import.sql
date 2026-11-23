-- =====================================================================
-- Royal Glow Platform — 012_accounts_import.sql
-- Importing from Excel/CSV on the Accounts page: expenses, opening balances, journals and the
-- chart of accounts. Each import is all-or-nothing (one bad row and nothing is saved), is
-- recorded in account_imports, and expense/journal imports can be undone in one click.
-- Requires 001–011. Safe to re-run. Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

alter table public.expenses add column if not exists import_id uuid;
alter table public.journals add column if not exists import_id uuid;
create index if not exists expenses_import_idx on public.expenses (import_id) where import_id is not null;
create index if not exists journals_import_idx on public.journals (import_id) where import_id is not null;

create table if not exists public.account_imports (
  id         uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('expenses', 'opening', 'journals', 'accounts')),
  file_name  text,
  row_count  int not null default 0,
  total      numeric(14,2) not null default 0,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  undone_at  timestamptz,
  undone_by  uuid references auth.users(id) on delete set null
);
alter table public.account_imports enable row level security;
drop policy if exists account_imports_read on public.account_imports;
create policy account_imports_read on public.account_imports for select using (public.is_staff(array['admin', 'accounts']));

-- ---------------------------------------------------------------------
-- Expenses. p_rows: [{row, expense_date, account_code, amount, paid_from, supplier_id, payee, description}]
-- "row" is the spreadsheet row number, used in error messages.
-- ---------------------------------------------------------------------
create or replace function public.import_expenses(p_file text, p_rows jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := gen_random_uuid(); r jsonb; v_n int := 0; v_total numeric := 0; a public.accounts;
begin
  if not public.is_staff(array['admin', 'accounts']) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'There are no rows to import.'; end if;
  insert into public.account_imports (id, kind, file_name) values (v_id, 'expenses', left(p_file, 200));
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      select * into a from public.accounts where code = r->>'account_code';
      if not found then raise exception 'unknown account %', r->>'account_code'; end if;
      if a.type <> 'expense' or a.category = 'cogs' or not a.active then
        raise exception 'account % (%) is not an expense account you can use here', a.code, a.name;
      end if;
      insert into public.expenses (expense_date, account_code, amount, paid_from, supplier_id, payee, description, import_id)
      values ((r->>'expense_date')::date, a.code, round((r->>'amount')::numeric, 2), r->>'paid_from',
              nullif(r->>'supplier_id', '')::uuid, nullif(trim(r->>'payee'), ''), nullif(trim(r->>'description'), ''), v_id);
      v_n := v_n + 1; v_total := v_total + round((r->>'amount')::numeric, 2);
    exception when others then
      raise exception 'Row %: %', coalesce(r->>'row', '?'), sqlerrm;
    end;
  end loop;
  update public.account_imports set row_count = v_n, total = v_total where id = v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Journals and opening balances. p_journals: [{label, entry_date, memo, lines:[{account_code, debit, credit, memo}]}]
-- Each journal goes through post_journal, which checks accounts and that debits equal credits.
-- ---------------------------------------------------------------------
create or replace function public.import_journals(p_file text, p_kind text, p_journals jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := gen_random_uuid(); j jsonb; v_jid uuid; v_n int := 0; v_total numeric := 0;
begin
  if not public.is_staff(array['admin', 'accounts']) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if p_kind not in ('journals', 'opening') then raise exception 'Unknown import type.'; end if;
  if jsonb_typeof(p_journals) <> 'array' or jsonb_array_length(p_journals) = 0 then raise exception 'There are no journals to import.'; end if;
  insert into public.account_imports (id, kind, file_name) values (v_id, p_kind, left(p_file, 200));
  for j in select * from jsonb_array_elements(p_journals) loop
    begin
      v_jid := public.post_journal((j->>'entry_date')::date, j->>'memo', case when p_kind = 'opening' then 'opening' else 'manual' end, j->'lines');
    exception when others then
      raise exception '%: %', coalesce(j->>'label', 'Journal'), sqlerrm;
    end;
    update public.journals set import_id = v_id where id = v_jid;
    v_n := v_n + 1;
    v_total := v_total + (select coalesce(sum(debit), 0) from public.journal_lines where journal_id = v_jid);
  end loop;
  update public.account_imports set row_count = v_n, total = v_total where id = v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Chart of accounts. p_rows: [{row, code, name, type, active}]
-- New codes are added; existing codes are renamed (and shown/hidden). A type can't be changed here.
-- Not undoable (names can simply be changed back on the Chart of accounts tab).
-- ---------------------------------------------------------------------
create or replace function public.import_accounts(p_file text, p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb; a public.accounts; v_new int := 0; v_upd int := 0; v_id uuid := gen_random_uuid();
begin
  if not public.is_staff(array['admin', 'accounts']) then raise exception 'Not allowed' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'There are no rows to import.'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      if coalesce(r->>'code', '') !~ '^[0-9]{4}$' then raise exception 'the code must be 4 digits'; end if;
      if coalesce(trim(r->>'name'), '') = '' then raise exception 'the name is missing'; end if;
      select * into a from public.accounts where code = r->>'code';
      if found then
        if r->>'type' is not null and r->>'type' <> a.type then
          raise exception 'account % is already of type %; the type can''t be changed', a.code, a.type;
        end if;
        update public.accounts set name = trim(r->>'name'),
          active = case when a.is_system or r->'active' is null or r->'active' = 'null'::jsonb then a.active else (r->>'active')::boolean end
        where code = a.code and (name is distinct from trim(r->>'name') or (not a.is_system and r->'active' is not null and r->'active' <> 'null'::jsonb and active <> (r->>'active')::boolean));
        if found then v_upd := v_upd + 1; end if;
      else
        if coalesce(r->>'type', '') not in ('asset', 'liability', 'equity', 'income', 'expense') then
          raise exception 'the type must be asset, liability, equity, income or expense';
        end if;
        insert into public.accounts (code, name, type, active)
        values (r->>'code', trim(r->>'name'), r->>'type', coalesce((nullif(r->>'active', ''))::boolean, true));
        v_new := v_new + 1;
      end if;
    exception when others then
      raise exception 'Row %: %', coalesce(r->>'row', '?'), sqlerrm;
    end;
  end loop;
  insert into public.account_imports (id, kind, file_name, row_count) values (v_id, 'accounts', left(p_file, 200), v_new + v_upd);
  return jsonb_build_object('import_id', v_id, 'added', v_new, 'updated', v_upd);
end $$;

-- ---------------------------------------------------------------------
-- Undo an expense, journal or opening-balance import: removes everything it created.
-- ---------------------------------------------------------------------
create or replace function public.undo_account_import(p_id uuid)
returns int language plpgsql security definer set search_path = public as $$
declare i public.account_imports; v_n int := 0; v_m int := 0;
begin
  if not public.is_staff(array['admin', 'accounts']) then raise exception 'Not allowed' using errcode = '42501'; end if;
  select * into i from public.account_imports where id = p_id for update;
  if not found then raise exception 'Import not found.'; end if;
  if i.undone_at is not null then raise exception 'This import has already been undone.'; end if;
  if i.kind = 'accounts' then raise exception 'Chart of accounts imports can''t be undone; change the names back on the Chart of accounts tab.'; end if;
  delete from public.expenses where import_id = p_id; get diagnostics v_n = row_count;
  delete from public.journals where import_id = p_id; get diagnostics v_m = row_count;
  update public.account_imports set undone_at = now(), undone_by = auth.uid() where id = p_id;
  return v_n + v_m;
end $$;

grant execute on function public.import_expenses(text, jsonb) to authenticated;
grant execute on function public.import_journals(text, text, jsonb) to authenticated;
grant execute on function public.import_accounts(text, jsonb) to authenticated;
grant execute on function public.undo_account_import(uuid) to authenticated;
