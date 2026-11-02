-- =====================================================================
-- Royal Glow Platform — 005_multi_roles.sql
-- Staff can hold several roles (e.g. production + sales).
-- Replaces staff.role (one role) with staff.roles (a list).
-- Requires 001 and 004. Safe to run more than once.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- 1. New column, filled from the old one
alter table public.staff add column if not exists roles text[];

do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'staff' and column_name = 'role') then
    execute 'update public.staff set roles = array[role] where roles is null';
  end if;
end $$;

update public.staff set roles = array['production'] where roles is null or cardinality(roles) = 0;
alter table public.staff alter column roles set not null;
alter table public.staff alter column roles set default array['production'];
alter table public.staff drop constraint if exists staff_roles_check;
alter table public.staff add constraint staff_roles_check
  check (cardinality(roles) > 0 and roles <@ array['admin', 'production', 'inventory', 'sales']);

-- 2. Access check: does the signed-in person hold ANY of the given roles?
--    (Argument is used as $1 so it can't be confused with the column.)
create or replace function public.is_staff(roles text[] default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.staff s
    where s.user_id = auth.uid()
      and ($1 is null or s.roles && $1)
  );
$$;

-- 3. Never leave the system without an admin
create or replace function public.keep_one_admin()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if 'admin' = any(old.roles)
     and (tg_op = 'DELETE' or not ('admin' = any(new.roles)))
     and not exists (select 1 from public.staff
                     where 'admin' = any(roles) and user_id <> old.user_id) then
    raise exception 'At least one admin must remain' using errcode = 'P0001';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

-- 4. Staff directory now returns the list of roles
drop function if exists public.staff_directory();
create function public.staff_directory()
returns table (user_id uuid, full_name text, roles text[], email text,
               last_sign_in_at timestamptz, added_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_staff(array['admin']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select s.user_id, s.full_name, s.roles, u.email::text, u.last_sign_in_at, s.created_at
    from public.staff s join auth.users u on u.id = s.user_id
    order by s.full_name;
end $$;
revoke all on function public.staff_directory() from public, anon;
grant execute on function public.staff_directory() to authenticated;

-- 5. Retire the old single-role column
alter table public.staff drop column if exists role;
