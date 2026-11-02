-- =====================================================================
-- Royal Glow Platform — 008_spa.sql
-- Spa: treatments, therapists, opening hours, time off, settings,
-- bookings (no double-booking, enforced by the database), online booking.
-- Requires 001–007. Safe to re-run. Times are Ghana time (Africa/Accra).
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- 1. New staff role: spa
-- ---------------------------------------------------------------------
alter table public.staff drop constraint if exists staff_roles_check;
alter table public.staff add constraint staff_roles_check
  check (cardinality(roles) > 0 and roles <@ array['admin', 'production', 'inventory', 'sales', 'spa']);

-- ---------------------------------------------------------------------
-- 2. Treatments, therapists, who does what
-- ---------------------------------------------------------------------
create table if not exists public.spa_services (
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,
  category     text not null default 'Treatments',
  duration_min int  not null check (duration_min between 10 and 480),
  price        numeric(12,2) not null default 0 check (price >= 0),
  description  text,
  active       boolean not null default true,
  sort_order   int not null default 0,
  created_at   timestamptz not null default now()
);

create table if not exists public.spa_therapists (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,
  staff_user_id uuid references auth.users(id) on delete set null,
  active        boolean not null default true,
  created_at    timestamptz not null default now()
);

-- If a therapist has no rows here, they can do every treatment.
create table if not exists public.spa_therapist_services (
  therapist_id uuid not null references public.spa_therapists(id) on delete cascade,
  service_id   uuid not null references public.spa_services(id) on delete cascade,
  primary key (therapist_id, service_id)
);

-- ---------------------------------------------------------------------
-- 3. Opening hours (0 = Sunday … 6 = Saturday), time off, settings
-- ---------------------------------------------------------------------
create table if not exists public.spa_hours (
  weekday int primary key check (weekday between 0 and 6),
  opens   time not null default '09:00',
  closes  time not null default '18:00',
  closed  boolean not null default false,
  check (closes > opens)
);
insert into public.spa_hours (weekday, opens, closes, closed)
select d, '09:00', '18:00', d = 0 from generate_series(0, 6) d
on conflict (weekday) do nothing;

create table if not exists public.spa_time_off (
  id           uuid primary key default gen_random_uuid(),
  therapist_id uuid not null references public.spa_therapists(id) on delete cascade,
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  reason       text,
  created_at   timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists public.spa_settings (
  id               int primary key default 1 check (id = 1),
  slot_step_min    int not null default 30 check (slot_step_min between 5 and 120),
  min_notice_hours int not null default 2  check (min_notice_hours between 0 and 72),
  max_days_ahead   int not null default 30 check (max_days_ahead between 1 and 180),
  phone            text,
  address          text,
  note             text,              -- shown to customers, e.g. "Please arrive 10 minutes early"
  updated_at       timestamptz not null default now()
);
insert into public.spa_settings (id, note)
values (1, 'Please arrive 10 minutes before your appointment.')
on conflict (id) do nothing;

-- Sample treatments and therapists (only if none exist). Edit them on the Spa page.
insert into public.spa_services (name, category, duration_min, price, description, sort_order)
select * from (values
  ('Signature Glow Facial (sample)',  'Facials',      60, 250.00, 'Cleanse, exfoliate, mask and massage for a radiant glow.', 1),
  ('Deep Cleansing Facial (sample)',  'Facials',      45, 180.00, 'A thorough cleanse for congested or oily skin.',          2),
  ('Swedish Massage (sample)',        'Massage',      60, 300.00, 'Relaxing full-body massage with warm oils.',               3),
  ('Deep Tissue Massage (sample)',    'Massage',      60, 350.00, 'Firm pressure to ease tight muscles.',                     4),
  ('Body Scrub and Glow (sample)',    'Body',         45, 220.00, 'Shea and sugar scrub followed by our body butter.',       5),
  ('Manicure (sample)',               'Hands & feet', 30,  80.00, 'Shape, cuticle care and polish.',                          6),
  ('Pedicure (sample)',               'Hands & feet', 45, 100.00, 'Soak, scrub, shape and polish.',                           7)
) v(name, category, duration_min, price, description, sort_order)
where not exists (select 1 from public.spa_services);

insert into public.spa_therapists (name)
select * from (values ('Abena (sample)'), ('Efua (sample)'), ('Kwabena (sample)')) v(name)
where not exists (select 1 from public.spa_therapists);

-- ---------------------------------------------------------------------
-- 4. Bookings — the exclusion constraint makes double-booking impossible
-- ---------------------------------------------------------------------
create sequence if not exists public.spa_booking_seq;

create table if not exists public.spa_bookings (
  id               uuid primary key default gen_random_uuid(),
  booking_no       text not null unique
                   default 'SPA-' || lpad(nextval('public.spa_booking_seq')::text, 5, '0'),
  service_id       uuid references public.spa_services(id) on delete set null,
  service_name     text not null,                  -- snapshot
  therapist_id     uuid not null references public.spa_therapists(id),
  starts_at        timestamptz not null,
  ends_at          timestamptz not null,
  price            numeric(12,2) not null default 0,
  customer_user_id uuid references auth.users(id) on delete set null,
  full_name        text not null,
  phone            text not null,
  email            text,
  notes            text,
  source           text not null default 'online' check (source in ('online', 'staff')),
  status           text not null default 'booked'
                   check (status in ('booked', 'confirmed', 'completed', 'cancelled', 'no_show')),
  paid_amount      numeric(12,2),
  payment_method   text check (payment_method in ('cash', 'momo', 'card', 'bank')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists spa_bookings_start_idx on public.spa_bookings (starts_at);

alter table public.spa_bookings drop constraint if exists spa_no_double_booking;
alter table public.spa_bookings add constraint spa_no_double_booking
  exclude using gist (therapist_id with =, tstzrange(starts_at, ends_at) with &&)
  where (status in ('booked', 'confirmed', 'completed'));

-- ---------------------------------------------------------------------
-- 5. Public functions
-- ---------------------------------------------------------------------
create or replace function public.spa_info()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'services', coalesce((select json_agg(json_build_object('id', s.id, 'name', s.name, 'category', s.category,
                                 'duration_min', s.duration_min, 'price', s.price, 'description', s.description)
                                 order by s.sort_order, s.name)
                          from public.spa_services s where s.active), '[]'::json),
    'therapists', coalesce((select json_agg(json_build_object('id', t.id, 'name', t.name,
                                 'services', (select coalesce(json_agg(x.service_id), '[]'::json)
                                              from public.spa_therapist_services x where x.therapist_id = t.id))
                                 order by t.name)
                            from public.spa_therapists t where t.active), '[]'::json),
    'hours', (select json_agg(json_build_object('weekday', h.weekday, 'opens', to_char(h.opens, 'HH24:MI'),
                                                'closes', to_char(h.closes, 'HH24:MI'), 'closed', h.closed)
                              order by h.weekday) from public.spa_hours h),
    'max_days_ahead', st.max_days_ahead, 'min_notice_hours', st.min_notice_hours,
    'phone', st.phone, 'address', st.address, 'note', st.note,
    'today', (now() at time zone 'Africa/Accra')::date)
  from public.spa_settings st where st.id = 1;
$$;

-- Free start times for a treatment on a day. p_therapist null = any therapist.
-- p_staff = true lets spa staff ignore the minimum-notice rule (phone bookings).
create or replace function public.spa_slots(p_service uuid, p_date date,
                                            p_therapist uuid default null, p_staff boolean default false)
returns table (starts_at timestamptz, therapist_id uuid, therapist_name text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare
  v_svc public.spa_services; v_h public.spa_hours; v_set public.spa_settings;
  v_t record; v_start timestamptz; v_end timestamptz; v_open timestamptz; v_close timestamptz;
  v_today date := (now() at time zone 'Africa/Accra')::date;
  v_notice interval;
begin
  select * into v_svc from public.spa_services s where s.id = p_service and s.active;
  if not found then return; end if;
  select * into v_set from public.spa_settings st where st.id = 1;
  if p_date < v_today or p_date > v_today + v_set.max_days_ahead then return; end if;
  select * into v_h from public.spa_hours h where h.weekday = extract(dow from p_date)::int;
  if not found or v_h.closed then return; end if;

  v_notice := case when p_staff and public.is_staff(array['admin', 'spa']) then interval '0'
                   else make_interval(hours => v_set.min_notice_hours) end;
  v_open  := (p_date + v_h.opens)  at time zone 'Africa/Accra';
  v_close := (p_date + v_h.closes) at time zone 'Africa/Accra';

  for v_t in
    select t.id, t.name from public.spa_therapists t
    where t.active and (p_therapist is null or t.id = p_therapist)
      and (not exists (select 1 from public.spa_therapist_services x where x.therapist_id = t.id)
           or exists (select 1 from public.spa_therapist_services x
                      where x.therapist_id = t.id and x.service_id = p_service))
    order by t.name
  loop
    v_start := v_open;
    while v_start + make_interval(mins => v_svc.duration_min) <= v_close loop
      v_end := v_start + make_interval(mins => v_svc.duration_min);
      if v_start >= now() + v_notice
         and not exists (select 1 from public.spa_bookings b
                         where b.therapist_id = v_t.id and b.status in ('booked', 'confirmed', 'completed')
                           and tstzrange(b.starts_at, b.ends_at) && tstzrange(v_start, v_end))
         and not exists (select 1 from public.spa_time_off o
                         where o.therapist_id = v_t.id
                           and tstzrange(o.starts_at, o.ends_at) && tstzrange(v_start, v_end)) then
        starts_at := v_start; therapist_id := v_t.id; therapist_name := v_t.name;
        return next;
      end if;
      v_start := v_start + make_interval(mins => v_set.slot_step_min);
    end loop;
  end loop;
end $$;

-- Book a treatment. Availability is re-checked here; the constraint is the final guard.
create or replace function public.book_spa(p_service uuid, p_starts_at timestamptz, p_therapist uuid,
                                           p_name text, p_phone text, p_email text, p_notes text,
                                           p_staff boolean default false)
returns json language plpgsql security definer set search_path = public as $$
declare
  v_svc public.spa_services; v_tid uuid; v_tname text; v_b public.spa_bookings;
  v_is_staff boolean := p_staff and public.is_staff(array['admin', 'spa']);
begin
  if coalesce(trim(p_name), '') = '' or coalesce(trim(p_phone), '') = '' then
    raise exception 'Please give your name and phone number.';
  end if;
  select * into v_svc from public.spa_services where id = p_service and active;
  if not found then raise exception 'That treatment is not available.'; end if;

  select s.therapist_id, s.therapist_name into v_tid, v_tname
  from public.spa_slots(p_service, (p_starts_at at time zone 'Africa/Accra')::date, p_therapist, v_is_staff) s
  where s.starts_at = p_starts_at
  limit 1;
  if v_tid is null then raise exception 'Sorry, that time is no longer available. Please choose another.'; end if;

  begin
    insert into public.spa_bookings (service_id, service_name, therapist_id, starts_at, ends_at, price,
                                     customer_user_id, full_name, phone, email, notes, source)
    values (v_svc.id, v_svc.name, v_tid, p_starts_at, p_starts_at + make_interval(mins => v_svc.duration_min),
            v_svc.price, case when v_is_staff then null else auth.uid() end,
            trim(p_name), trim(p_phone), nullif(trim(p_email), ''), nullif(trim(p_notes), ''),
            case when v_is_staff then 'staff' else 'online' end)
    returning * into v_b;
  exception when exclusion_violation then
    raise exception 'Sorry, that time was just taken. Please choose another.';
  end;

  return json_build_object('booking_no', v_b.booking_no, 'service', v_b.service_name, 'therapist', v_tname,
                           'starts_at', v_b.starts_at, 'ends_at', v_b.ends_at, 'price', v_b.price);
end $$;

-- Customers can cancel their own booking up to the notice period before it starts.
create or replace function public.cancel_my_spa_booking(p_booking_no text)
returns void language plpgsql security definer set search_path = public as $$
declare v_b public.spa_bookings; v_notice int;
begin
  select * into v_b from public.spa_bookings where booking_no = p_booking_no and customer_user_id = auth.uid();
  if not found then raise exception 'Booking not found.'; end if;
  if v_b.status not in ('booked', 'confirmed') then raise exception 'This booking can no longer be cancelled.'; end if;
  select min_notice_hours into v_notice from public.spa_settings where id = 1;
  if v_b.starts_at < now() + make_interval(hours => v_notice) then
    raise exception 'It is too close to your appointment to cancel online. Please call us.';
  end if;
  update public.spa_bookings set status = 'cancelled', updated_at = now() where id = v_b.id;
end $$;

grant execute on function public.spa_info() to anon, authenticated;
grant execute on function public.spa_slots(uuid, date, uuid, boolean) to anon, authenticated;
grant execute on function public.book_spa(uuid, timestamptz, uuid, text, text, text, text, boolean) to anon, authenticated;
grant execute on function public.cancel_my_spa_booking(text) to authenticated;

-- ---------------------------------------------------------------------
-- 6. Row Level Security: staff read; admin + spa manage.
--    Customers read their own bookings; bookings are created via book_spa().
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['spa_services', 'spa_therapists', 'spa_therapist_services',
                           'spa_hours', 'spa_time_off', 'spa_settings'] loop
    execute format('alter table public.%1$s enable row level security', t);
    execute format('drop policy if exists %1$s_read  on public.%1$s', t);
    execute format('drop policy if exists %1$s_write on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select using (public.is_staff())', t);
    execute format($p$create policy %1$s_write on public.%1$s for all
                     using (public.is_staff(array['admin','spa']))
                     with check (public.is_staff(array['admin','spa']))$p$, t);
  end loop;
end $$;

alter table public.spa_bookings enable row level security;
drop policy if exists spa_bookings_own         on public.spa_bookings;
drop policy if exists spa_bookings_staff_read  on public.spa_bookings;
drop policy if exists spa_bookings_staff_write on public.spa_bookings;
create policy spa_bookings_own on public.spa_bookings for select using (customer_user_id = auth.uid());
create policy spa_bookings_staff_read on public.spa_bookings for select using (public.is_staff());
create policy spa_bookings_staff_write on public.spa_bookings for update
  using (public.is_staff(array['admin', 'spa'])) with check (public.is_staff(array['admin', 'spa']));
