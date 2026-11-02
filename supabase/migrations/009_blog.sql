-- =====================================================================
-- Royal Glow Platform — 009_blog.sql
-- Blog: posts (draft/published), cover and inline photos, subscribers.
-- New staff role 'content' (shown as "Blog"). Requires 001–008. Safe to re-run.
-- Run in Supabase: SQL Editor -> New query -> paste -> Run.
-- =====================================================================

-- 1. New staff role
alter table public.staff drop constraint if exists staff_roles_check;
alter table public.staff add constraint staff_roles_check
  check (cardinality(roles) > 0 and roles <@ array['admin', 'production', 'inventory', 'sales', 'spa', 'content']);

-- 2. Posts
create table if not exists public.blog_posts (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title          text not null,
  excerpt        text,                     -- one or two sentences for lists and sharing
  body           text not null default '', -- simple markdown
  category       text not null default 'Skincare',
  cover_path     text,                     -- file in the blog-images bucket
  author_name    text,
  author_user_id uuid references auth.users(id) on delete set null default auth.uid(),
  status         text not null default 'draft' check (status in ('draft', 'published')),
  published_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index if not exists blog_posts_pub_idx on public.blog_posts (status, published_at desc);

-- Publishing stamps the date once; unpublishing keeps it for history.
create or replace function public.blog_stamp()
returns trigger language plpgsql as $$
begin
  if new.status = 'published' and new.published_at is null then new.published_at := now(); end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists trg_blog_stamp on public.blog_posts;
create trigger trg_blog_stamp before insert or update on public.blog_posts
  for each row execute function public.blog_stamp();

-- 3. Subscribers who signed up on the blog (customers with accounts opt in on their profile)
create table if not exists public.blog_subscribers (
  email      text primary key check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  name       text,
  created_at timestamptz not null default now()
);

create or replace function public.subscribe_blog(p_email text, p_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if coalesce(trim(p_email), '') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Please enter a valid email address.';
  end if;
  insert into public.blog_subscribers (email, name)
  values (lower(trim(p_email)), nullif(trim(p_name), ''))
  on conflict (email) do update set name = coalesce(excluded.name, public.blog_subscribers.name);
end $$;

create or replace function public.unsubscribe_blog(p_email text)
returns void language sql security definer set search_path = public as $$
  delete from public.blog_subscribers where email = lower(trim(p_email));
$$;

-- Everyone who wants articles: blog sign-ups + customers who ticked the box (admin/blog staff only)
create or replace function public.list_blog_subscribers()
returns table (email text, name text, source text, since timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not public.is_staff(array['admin', 'content']) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  return query
    select distinct on (x.email) x.email, x.name, x.source, x.since from (
      select s.email, s.name, 'Blog sign-up'::text as source, s.created_at as since from public.blog_subscribers s
      union all
      select lower(u.email::text), p.full_name, 'Customer account', p.created_at
      from public.shop_profiles p join auth.users u on u.id = p.user_id
      where p.wants_articles and u.email is not null
    ) x order by x.email, x.since;
end $$;

grant execute on function public.subscribe_blog(text, text) to anon, authenticated;
grant execute on function public.unsubscribe_blog(text) to anon, authenticated;
revoke all on function public.list_blog_subscribers() from public, anon;
grant execute on function public.list_blog_subscribers() to authenticated;

-- 4. Row Level Security
alter table public.blog_posts enable row level security;
drop policy if exists blog_posts_public on public.blog_posts;
drop policy if exists blog_posts_staff_read on public.blog_posts;
drop policy if exists blog_posts_write on public.blog_posts;
create policy blog_posts_public on public.blog_posts for select to anon, authenticated
  using (status = 'published' and published_at <= now());
create policy blog_posts_staff_read on public.blog_posts for select using (public.is_staff());
create policy blog_posts_write on public.blog_posts for all
  using (public.is_staff(array['admin', 'content'])) with check (public.is_staff(array['admin', 'content']));

alter table public.blog_subscribers enable row level security;
drop policy if exists blog_subscribers_staff on public.blog_subscribers;
create policy blog_subscribers_staff on public.blog_subscribers for all
  using (public.is_staff(array['admin', 'content'])) with check (public.is_staff(array['admin', 'content']));

-- 5. Photos: public bucket, admin/blog staff upload.
--    If this part reports a notice, create the bucket and policies in Storage instead.
do $$
begin
  insert into storage.buckets (id, name, public) values ('blog-images', 'blog-images', true)
  on conflict (id) do update set public = true;
  drop policy if exists blog_images_insert on storage.objects;
  drop policy if exists blog_images_update on storage.objects;
  drop policy if exists blog_images_delete on storage.objects;
  create policy blog_images_insert on storage.objects for insert to authenticated
    with check (bucket_id = 'blog-images' and public.is_staff(array['admin', 'content']));
  create policy blog_images_update on storage.objects for update to authenticated
    using (bucket_id = 'blog-images' and public.is_staff(array['admin', 'content']));
  create policy blog_images_delete on storage.objects for delete to authenticated
    using (bucket_id = 'blog-images' and public.is_staff(array['admin', 'content']));
exception when others then
  raise notice 'Storage setup skipped (%). Create the blog-images bucket and its policies in Storage.', sqlerrm;
end $$;
