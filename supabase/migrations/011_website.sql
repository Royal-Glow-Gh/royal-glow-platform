-- =====================================================================
-- Royal Glow Platform — 011_website.sql
-- Website content edited in the staff app (Website page) instead of site.json:
-- settings (design style, home text, section photos, about, contact, social) with history,
-- hero slides, announcement bar, testimonials, customer feedback links, publish log,
-- site-images storage bucket. Requires 001–010. Safe to re-run.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- 1. Settings: one row holding the website content as JSON (admin only)
create table if not exists public.site_settings (
  id         int primary key default 1 check (id = 1),
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid()
);
insert into public.site_settings (id, data) values (1, $seed${
  "design": {
    "home": "classic",
    "blog": "magazine"
  },
  "company": "Royal Glow Company Limited",
  "brand": "Royal Glow",
  "tagline": "Skincare with a royal glow",
  "intro": "Royal Glow makes, distributes and sells skincare, personal care and spa products, and runs a spa where you can enjoy them. Shop online, visit one of our shops, or book a treatment.",
  "badges": [
    "Made in Ghana",
    "Small-batch production",
    "Spa treatments with our own products",
    "Shop online or in store"
  ],
  "highlights": [
    {
      "title": "Made by Royal Glow",
      "text": "Skincare, personal care and spa products, many made in-house in small batches.",
      "link_label": "Browse the shop",
      "link": "shop"
    },
    {
      "title": "The Royal Glow spa",
      "text": "Facials, massages and body treatments using our own products. Book online in a minute.",
      "link_label": "See treatments",
      "link": "spa"
    },
    {
      "title": "For stockists",
      "text": "We supply partner shops, pharmacies, stockists and distributors at wholesale prices. Get in touch to become a Royal Glow stockist.",
      "link_label": "Contact us",
      "link": "contact"
    }
  ],
  "images": {
    "hero_portrait": "",
    "making": "",
    "spa": "",
    "stockists": "",
    "about": ""
  },
  "about_title": "About Royal Glow",
  "about": [
    "Royal Glow Company Limited is a Ghanaian company in the manufacturing, distribution and sales of skincare, personal care and spa products, as well as their accessories and complementary products.",
    "We make many of our products ourselves, in small batches, including some of the oils that go into them, so we know exactly what is in every jar and bottle.",
    "You can find Royal Glow products in our own shops, online, and through partner shops, pharmacies, stockists and distributors."
  ],
  "partners_title": "Stockists, distributors and partner shops",
  "partners": "We supply partner shops, pharmacies, stockists and distributors at wholesale prices. Get in touch to become a Royal Glow stockist.",
  "contact": {
    "email": "hello@royalglowgh.com",
    "phone": "",
    "whatsapp": "",
    "address": "",
    "hours": ""
  },
  "social": {
    "facebook": "",
    "instagram": "",
    "tiktok": ""
  }
}$seed$::jsonb)
on conflict (id) do nothing;

-- Every save keeps the previous version (last 30 kept), so changes can be undone.
create table if not exists public.site_settings_history (
  id       bigserial primary key,
  data     jsonb not null,
  saved_at timestamptz not null,
  saved_by uuid references auth.users(id) on delete set null
);
create or replace function public.site_settings_keep()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.data is distinct from old.data then
    insert into public.site_settings_history (data, saved_at, saved_by) values (old.data, old.updated_at, old.updated_by);
    delete from public.site_settings_history where id not in (select id from public.site_settings_history order by id desc limit 30);
  end if;
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
drop trigger if exists trg_site_settings_keep on public.site_settings;
create trigger trg_site_settings_keep before update on public.site_settings
  for each row execute function public.site_settings_keep();

-- 2. Hero slides (Classic and Showcase home pages; 1–3 shown)
create table if not exists public.site_slides (
  id                uuid primary key default gen_random_uuid(),
  sort              int not null default 0,
  image_path        text,           -- wide 2400 x 1200, in site-images
  image_mobile_path text,           -- phone 1080 x 1620 (optional)
  headline          text check (char_length(headline) <= 80),
  text              text check (char_length(text) <= 260),
  button_label      text check (char_length(button_label) <= 30),
  button_link       text,           -- shop, spa, blog, about, contact or https://...
  active            boolean not null default true,
  created_at        timestamptz not null default now()
);

-- 3. Announcement bar (loads live on the website, so changes show at once)
create table if not exists public.site_announcements (
  id         uuid primary key default gen_random_uuid(),
  message    text not null check (char_length(message) between 3 and 120),
  link       text,
  starts_on  date,
  ends_on    date,
  active     boolean not null default true,
  sort       int not null default 0,
  created_at timestamptz not null default now(),
  check (ends_on is null or starts_on is null or ends_on >= starts_on)
);

-- 4. Testimonials: real customer quotes only, published only with the customer's agreement
create table if not exists public.testimonials (
  id         uuid primary key default gen_random_uuid(),
  quote      text not null check (char_length(quote) between 10 and 600),
  name       text not null check (char_length(name) between 1 and 60),   -- first name or initials
  town       text check (char_length(town) <= 60),
  about      text check (char_length(about) <= 80),                      -- treatment or product
  service_id uuid references public.spa_services(id) on delete set null, -- shown with that treatment
  consent    boolean not null default false,
  status     text not null default 'draft' check (status in ('draft', 'published', 'hidden')),
  source     text not null default 'staff' check (source in ('staff', 'customer')),
  reference  text,                                                        -- booking or order number
  sort       int not null default 0,
  created_at timestamptz not null default now(),
  constraint testimonials_consent_to_publish check (status <> 'published' or consent)
);

-- 5. "How was your visit?" links: one-time links staff send to a customer
create table if not exists public.feedback_links (
  token      uuid primary key default gen_random_uuid(),
  reference  text,                 -- booking or order number
  about      text,                 -- treatment or product, filled in on the testimonial
  service_id uuid references public.spa_services(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '60 days',
  used_at    timestamptz
);

create or replace function public.feedback_info(p_token uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case
    when f.token is null then jsonb_build_object('ok', false, 'message', 'This link is not valid.')
    when f.used_at is not null then jsonb_build_object('ok', false, 'message', 'Thank you — we have already received your feedback.')
    when f.expires_at < now() then jsonb_build_object('ok', false, 'message', 'This link has expired.')
    else jsonb_build_object('ok', true, 'about', f.about) end
  from (select 1) x left join public.feedback_links f on f.token = p_token;
$$;

create or replace function public.submit_feedback(p_token uuid, p_quote text, p_name text, p_town text, p_consent boolean)
returns void language plpgsql security definer set search_path = public as $$
declare f public.feedback_links;
begin
  select * into f from public.feedback_links where token = p_token for update;
  if not found or f.expires_at < now() then raise exception 'This link is not valid or has expired.'; end if;
  if f.used_at is not null then raise exception 'Thank you — we have already received your feedback.'; end if;
  if char_length(coalesce(trim(p_quote), '')) < 10 then raise exception 'Please write a little more (at least 10 characters).'; end if;
  if char_length(trim(p_quote)) > 600 then raise exception 'Please keep it under 600 characters.'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'Please enter your name.'; end if;
  insert into public.testimonials (quote, name, town, about, service_id, consent, status, source, reference)
  values (trim(p_quote), left(trim(p_name), 60), left(nullif(trim(p_town), ''), 60), f.about, f.service_id,
          coalesce(p_consent, false), 'draft', 'customer', f.reference);
  update public.feedback_links set used_at = now() where token = p_token;
end $$;

grant execute on function public.feedback_info(uuid) to anon, authenticated;
grant execute on function public.submit_feedback(uuid, text, text, text, boolean) to anon, authenticated;

-- 6. Publish log (written by the publish-site function; used for its one-minute cooldown)
create table if not exists public.site_publish_log (
  id           bigserial primary key,
  requested_at timestamptz not null default now(),
  requested_by uuid references auth.users(id) on delete set null,
  ok           boolean not null,
  message      text
);

-- 7. Row Level Security
--    Public: settings, active slides, current announcements, published testimonials.
--    Settings: admin. Slides, announcements, testimonials: admin + Blog role.
--    Feedback links: admin, Blog, Spa and Sales staff (they send them after visits and orders).
alter table public.site_settings enable row level security;
drop policy if exists site_settings_public on public.site_settings;
drop policy if exists site_settings_admin on public.site_settings;
create policy site_settings_public on public.site_settings for select to anon, authenticated using (true);
create policy site_settings_admin on public.site_settings for update
  using (public.is_staff(array['admin'])) with check (public.is_staff(array['admin']));

alter table public.site_settings_history enable row level security;
drop policy if exists site_settings_history_admin on public.site_settings_history;
create policy site_settings_history_admin on public.site_settings_history for select using (public.is_staff(array['admin']));

alter table public.site_slides enable row level security;
drop policy if exists site_slides_public on public.site_slides;
drop policy if exists site_slides_staff on public.site_slides;
create policy site_slides_public on public.site_slides for select to anon, authenticated using (active);
create policy site_slides_staff on public.site_slides for all
  using (public.is_staff(array['admin', 'content'])) with check (public.is_staff(array['admin', 'content']));

alter table public.site_announcements enable row level security;
drop policy if exists site_announcements_public on public.site_announcements;
drop policy if exists site_announcements_staff on public.site_announcements;
create policy site_announcements_public on public.site_announcements for select to anon, authenticated
  using (active and (starts_on is null or starts_on <= (now() at time zone 'Africa/Accra')::date)
                and (ends_on is null or ends_on >= (now() at time zone 'Africa/Accra')::date));
create policy site_announcements_staff on public.site_announcements for all
  using (public.is_staff(array['admin', 'content'])) with check (public.is_staff(array['admin', 'content']));

alter table public.testimonials enable row level security;
drop policy if exists testimonials_public on public.testimonials;
drop policy if exists testimonials_staff on public.testimonials;
create policy testimonials_public on public.testimonials for select to anon, authenticated using (status = 'published' and consent);
create policy testimonials_staff on public.testimonials for all
  using (public.is_staff(array['admin', 'content'])) with check (public.is_staff(array['admin', 'content']));

alter table public.feedback_links enable row level security;
drop policy if exists feedback_links_staff on public.feedback_links;
create policy feedback_links_staff on public.feedback_links for all
  using (public.is_staff(array['admin', 'content', 'spa', 'sales'])) with check (public.is_staff(array['admin', 'content', 'spa', 'sales']));

alter table public.site_publish_log enable row level security;
drop policy if exists site_publish_log_staff on public.site_publish_log;
create policy site_publish_log_staff on public.site_publish_log for select using (public.is_staff(array['admin', 'content']));

-- 8. Photos: public bucket, admin/Blog staff upload.
--    If this part reports a notice, create the site-images bucket and policies in Storage instead.
do $$
begin
  insert into storage.buckets (id, name, public) values ('site-images', 'site-images', true)
  on conflict (id) do update set public = true;
  drop policy if exists site_images_insert on storage.objects;
  drop policy if exists site_images_update on storage.objects;
  drop policy if exists site_images_delete on storage.objects;
  create policy site_images_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'site-images' and public.is_staff(array['admin', 'content']));
  create policy site_images_update on storage.objects for update to authenticated
    using (bucket_id = 'site-images' and public.is_staff(array['admin', 'content']));
  create policy site_images_delete on storage.objects for delete to authenticated
    using (bucket_id = 'site-images' and public.is_staff(array['admin', 'content']));
exception when others then
  raise notice 'Storage setup skipped (%). Create the site-images bucket and its policies in Storage.', sqlerrm;
end $$;
