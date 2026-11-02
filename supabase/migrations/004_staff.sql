-- =====================================================================
-- Royal Glow Platform — 004_staff.sql
-- Staff management from the app: admins see accounts waiting for
-- approval, approve them with a role, change roles, remove access.
-- Requires 001_production.sql. Safe to run more than once.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- Accounts that have signed up but are not on the staff list (admins only).
-- New sign-ups can be staff or, later, shop customers; only admins decide.
create or replace function public.list_unassigned_users()
returns table (user_id uuid, email text, suggested_name text,
               signed_up_at timestamptz, email_confirmed boolean)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_staff(array['admin']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select u.id, u.email::text, (u.raw_user_meta_data->>'full_name')::text,
           u.created_at, u.email_confirmed_at is not null
    from auth.users u
    where not exists (select 1 from public.staff s where s.user_id = u.id)
    order by u.created_at desc;
end $$;

-- Staff list with emails and last sign-in (admins only).
create or replace function public.staff_directory()
returns table (user_id uuid, full_name text, role text, email text,
               last_sign_in_at timestamptz, added_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_staff(array['admin']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select s.user_id, s.full_name, s.role, u.email::text, u.last_sign_in_at, s.created_at
    from public.staff s join auth.users u on u.id = s.user_id
    order by s.full_name;
end $$;

-- Never leave the system without an admin.
create or replace function public.keep_one_admin()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'admin'
     and (tg_op = 'DELETE' or new.role <> 'admin')
     and not exists (select 1 from public.staff
                     where role = 'admin' and user_id <> old.user_id) then
    raise exception 'At least one admin must remain' using errcode = 'P0001';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

drop trigger if exists trg_keep_one_admin on public.staff;
create trigger trg_keep_one_admin
  before update or delete on public.staff
  for each row execute function public.keep_one_admin();

-- Only admins may call these.
revoke all on function public.list_unassigned_users() from public, anon;
revoke all on function public.staff_directory()        from public, anon;
grant execute on function public.list_unassigned_users() to authenticated;
grant execute on function public.staff_directory()        to authenticated;
