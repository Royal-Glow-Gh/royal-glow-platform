# Royal Glow platform: build log and setup

## Where things live
- GitHub: Royal-Glow-Gh/royal-glow-platform (private monorepo)
  - apps/staff/index.html: production batch costing
  - apps/staff/inventory.html: inventory (stock on hand, purchases, transfers, adjustments, movements, setup)
  - apps/staff/sales.html: sales (new sale, history, customers & credit, returns, price list, reports)
  - apps/staff/staff.html: staff & account (sign-up, forgot password, change password; admins approve staff and set roles)
  - apps/staff/shop-admin.html: online shop management (orders, products shown on the website with photos, delivery/MoMo settings, ship-from and pickup locations)
  - apps/staff/spa.html: spa (day calendar per therapist, phone bookings, confirm/complete/no-show/cancel, treatments, therapists & time off, opening hours & booking rules, spa reports)
  - apps/staff/blog-admin.html: blog (article list, editor with live preview, cover and inline photos, publish/unpublish, copy announcement, subscriber list)
  - apps/staff/accounts.html: accounts (profit and loss, balance sheet, cash flow, trial balance, account ledger, expenses, supplier balances and payments, journals incl. opening balances, chart of accounts); admin + accounts roles only
  - apps/staff/config.js: Supabase URL + publishable key (never the secret key). config.example.js is the template.
  - apps/staff/assets/: logo and favicons
  - supabase/migrations/001_production.sql: staff, items, batches, batch_inputs; views batch_costs, item_current_cost
  - supabase/migrations/002_inventory.sql: locations (Factory auto-created), suppliers, purchases, transfers, stock_adjustments; views stock_ledger, stock_on_hand; item kind 'goods'; reorder levels
  - supabase/migrations/003_sales.sql: retail/wholesale prices on items, customers, sales, sale_lines, customer_payments, sale_returns; stock_ledger includes sales and restocked returns; views sale_totals, customer_balances
  - supabase/migrations/004_staff.sql: admin-only functions list_unassigned_users, staff_directory; trigger keeping at least one admin
  - supabase/migrations/005_multi_roles.sql: staff.roles (a list) replaces staff.role, so one person can hold several roles
  - apps/shop/: the shop website: shop + spa booking + customer accounts (index.html), assets/, config.js with the same Supabase values
  - apps/site/: the main website royalglowgh.com, generated as static HTML by build.mjs (no packages; Node 20). Company text in site.json; articles, products and spa treatments come from the database. Output (dist/) is not committed.
    Pages: / (home), /about/, /contact/, /blog/, /blog/<web address>/, /blog/unsubscribe/, 404, sitemap.xml, robots.txt, feed.xml (RSS). Each article has its own title, description, preview image and Google article markup in the page.
  - supabase/migrations/006_shop.sql: shop fields on items/locations, shop_settings, shop_profiles (auto-created for customer sign-ups), shop_orders + lines, public functions shop_catalog/shop_info/place_order, staff functions set_shop_product/fulfil_order, product-images storage bucket
  - supabase/migrations/007_delivery_zones.sql: delivery_zones (fee, who delivers, fee paid to Royal Glow or rider); orders store zone, fee_confirmed, fee_to_rider; place_order takes a zone (none = "somewhere else", fee confirmed by staff)
  - supabase/migrations/008_spa.sql: spa_services, spa_therapists (+ which treatments each does), spa_hours, spa_time_off, spa_settings, spa_bookings (database blocks double-booking); public functions spa_info/spa_slots/book_spa, cancel_my_spa_booking; new staff role 'spa'
  - supabase/migrations/009_blog.sql: blog_posts (draft/published, simple Markdown body), blog_subscribers; subscribe_blog / unsubscribe_blog (public), list_blog_subscribers (admin/blog staff); blog-images storage bucket; new staff role 'content' (shown as "Blog")
  - supabase/migrations/010_accounting.sql: accounts (chart), gl_lines (ledger derived from all operational records + expenses + supplier payments + journals), gl_summary / cash_flow / account_ledger functions, supplier_balances view, expenses, supplier_payments, journals (+ post_journal, which enforces balance), purchase payment method, cost snapshots on adjustments and returns, new role 'accounts'
  - .github/workflows/publish-staff.yml: on push to main, copies apps/staff to the deploy-staff branch
  - .github/workflows/publish-shop.yml: on push to main, copies apps/shop to the deploy-shop branch
  - .github/workflows/publish-site.yml: builds apps/site and publishes to the deploy-site branch: on push, every 30 minutes, or manually (Actions -> Publish main website -> Run workflow). Publishes only when the site actually changed; if the database can't be reached, nothing is published.
- Supabase project: royal-glow (North EU, Stockholm)
- Hosting: Hostinger deploys branch deploy-staff to staff.royalglowgh.com (/inventory.html, /sales.html, /shop-admin.html, /spa.html, /blog-admin.html, /accounts.html, /staff.html) branch deploy-shop to shop.royalglowgh.com, and branch deploy-site to royalglowgh.com

## Supabase Auth settings (Authentication -> ...)
- Sign In / Providers: "Allow new users to sign up" ON; email confirmation ON.
- URL Configuration: Site URL https://staff.royalglowgh.com ; Redirect URLs include https://staff.royalglowgh.com/** and https://shop.royalglowgh.com/**
- Supabase's built-in email sender is limited and meant for testing. Before go-live, set up custom SMTP (e.g. a Royal Glow mailbox on Hostinger) so confirmation and reset emails are reliable and come from Royal Glow.

## How a change goes live
Edit in Codespace -> commit -> Sync -> GitHub Action updates deploy-staff -> Hostinger redeploys.
Make edits in the Codespace, not on GitHub.com (avoids merge conflicts). If you do edit on the website, Sync the Codespace first.

## Roles (a person can hold several, e.g. production + sales)
- admin: everything, including approving staff and changing roles
- production: batches and items; can view inventory and sales
- inventory: purchases, transfers, adjustments, locations, suppliers, reorder levels
- sales: sales, customers, payments, returns, selling prices, online shop orders
- spa: spa bookings, treatments, therapists, opening hours, spa reports
- content ("Blog"): write, publish and delete articles; see subscribers
- accounts: all accounting reports, expenses, supplier payments, journals, chart of accounts (expenses and journals are hidden from other roles because they include salaries)

## Adding a staff member
1. They open the sign-in page, click "New staff? Create an account", and confirm their email.
2. An admin opens Account (staff.html) -> "Waiting for approval", checks the name, ticks the roles they need, clicks Approve.
3. They sign in again and have access.
Remove access or change roles on the same page (tick/untick; at least one role must stay ticked). The system refuses to remove or demote the last admin.

## Business rules captured
- Walk-in sales need no customer record. Credit sales need a named customer.
- Partner shops / pharmacies: goods sent are credit sales (receivables); unsold goods come back as returns that reduce what they owe.
- Stockists / wholesalers / distributors buy at wholesale prices (customer price tier).
- Payment methods: cash, mobile money, card, bank transfer, credit.
- Sale lines store the unit cost at the time of sale, so margins never change retroactively.
- Online shop: prices and stock are checked in the database (place_order), never trusted from the browser. Orders not yet fulfilled hold their stock. Fulfilling an order records it as a sale (receipt = order number). Delivery fees are on the order, not in sales revenue.
- Delivery: customers pick a delivery area and see its fee. Rider-paid fees are shown but not added to what the customer pays Royal Glow. "Somewhere else" orders get their fee set by staff on the order; an order can't be confirmed or fulfilled until its fee is set.
- Online payment phase 1: MoMo to the Royal Glow number (order number as reference) or cash on delivery/pickup; staff mark orders paid. Phase 2: Paystack.
- Spa: customers book online (treatment, day, therapist or "any", free time); pay at the spa. Staff can book by phone, ignoring the online notice period. A therapist with no treatments ticked does all treatments. Times are Ghana time (GMT, no daylight saving). Spa revenue is recorded on completed bookings (paid amount + method) and reported on the Spa page, separate from product sales.
- Main website text (about, intro, contact details, social links) is edited in apps/site/site.json; blank values are hidden.
- Blog: articles live at royalglowgh.com/blog/<web address>/. They are drafts until published; only published ones are visible to the public. Published changes reach the website at the next rebuild (within ~30 minutes, or run the workflow by hand). Subscribers = blog sign-ups + customers who ticked "Send me new skincare articles". Phase 1: copy the subscriber emails / a ready announcement and send from your email tool or WhatsApp. Phase 2 (later): automatic emails through an email service.
- Accounting (assumptions: not VAT-registered; financial year Jan–Dec; standard chart, renameable):
  - The ledger is derived, not copied: sales (money/receivable vs product sales, discounts; cost of goods sold vs stock), returns (reduce revenue and receivable/cash; restocked goods back to stock at their cost), customer payments, purchases (stock vs cash/MoMo/bank or supplier credit), supplier payments, production (labour/energy 'other costs' moved into stock value), stock adjustments (write-offs; opening stock vs opening balances), completed spa bookings (spa revenue), expenses, journals.
  - Every amount is rounded to the pesewa identically on both sides, so the books always balance exactly.
  - Payment method -> account: cash 1000, MoMo 1010, card and bank 1020, credit 1100 (customers) / 2000 (suppliers).
  - Shop delivery fees are not yet in the books (they sit on the order). Inventory in the ledger is valued at the cost when goods moved; the Inventory page values stock at today's cost, so the two can differ slightly.
  - These are management accounts. Statutory accounts and GRA/VAT filings should be prepared or checked by an accountant.
- Customer sign-ups (account_type 'customer') get a shop profile and never appear in the staff approval list.

## Data status
- Decision: the database holds SAMPLE data while the apps are being built. Clear all sample data once the build is finished, before entering real data.
- Clearing sample data (extend this list as new tables are added):
   delete from public.expenses where payee like '%(sample)%';
   delete from public.journals where memo like '%(sample)%';
   delete from public.supplier_payments;
   delete from public.blog_posts where author_name like '%(sample)%';
   delete from public.blog_subscribers;   -- only if they are test sign-ups
   delete from public.spa_bookings;
   delete from public.spa_time_off;
   delete from public.spa_therapists where name like '%(sample)%';   -- then add your therapists
   delete from public.spa_services where name like '%(sample)%';     -- then add your treatments
   delete from public.shop_orders;        -- also removes shop_order_lines
   delete from public.sale_returns;
   delete from public.customer_payments;
   delete from public.sales;              -- also removes sale_lines
   delete from public.customers;
   delete from public.stock_adjustments;
   delete from public.transfers;          -- also removes transfer_lines
   delete from public.purchases;          -- also removes purchase_lines
   delete from public.suppliers;
   delete from public.batches;            -- also removes batch_inputs
   delete from public.items;
   delete from public.locations where kind <> 'factory';
   delete from public.delivery_zones where name like '%(sample)%';   -- then add your real areas
   update public.shop_settings set delivery_fee = 0, momo_number = null, momo_name = null, whatsapp = null;

## Milestones
- [x] Production batch costing prototype
- [x] Supabase schema 001 (production)
- [x] Production app connected to Supabase with staff login
- [x] Deployed to production.royalglowgh.com (since moved to staff.royalglowgh.com)
- [x] Branding: logo, crown favicons, gold theme
- [x] Inventory and purchases (002)
- [x] Sales, customers, credit, payments, returns, price list, reports (003)
- [x] Staff management: self sign-up, admin approval and roles, forgot/change password (004)
- [x] Multiple roles per person (005)
- [ ] Custom SMTP for auth emails (before go-live): sender "Royal Glow" <hello@royalglowgh.com>, a real monitored Hostinger mailbox
- [x] Online storefront, customer accounts, online orders (006)
- [x] Delivery areas with their own fees (007)
- [ ] Paystack online payments (MoMo + card) (deferred)
- [x] Spa bookings: online booking, staff calendar, treatments, therapists, hours, reports (008)
- [ ] Booking/order reminders by SMS or WhatsApp (later)
- [ ] Spa deposits via Paystack (with Paystack)
- [x] Blog: editor, publishing, public blog page, subscribe/unsubscribe, subscriber list (009)
- [ ] Automatic new-article emails via an email service (later)
- [x] Main website royalglowgh.com: home, about, contact, SEO-ready blog, sitemap, RSS (static, rebuilt automatically)
- [ ] Fill in real contact details, address and social links in apps/site/site.json
- [ ] Instant website rebuild when an article is published (later; now every 30 min or manual)
- [ ] Submit sitemap to Google Search Console
- [x] Accounting release 1: ledger, chart of accounts, expenses, supplier credit and payments, journals and opening balances, P&L, balance sheet, cash flow, trial balance, account ledger (010)
- [ ] Accounting release 2: month-end close (lock past periods), receivables/payables ageing, VAT if registered, depreciation schedule, delivery fees into the books, budgets
- [ ] Decide how distributors fit in (e.g. pickup points)
- [ ] Go-live: clear all sample data, enter real data

## Next up
- [ ] Move the staff apps to staff.royalglowgh.com: files done (folder apps/production -> apps/staff, workflow publish-staff.yml -> branch deploy-staff). Remaining: Hostinger subdomain staff.royalglowgh.com on deploy-staff, Supabase Site URL + Redirect URLs, delete production subdomain and deploy-production branch. No redirect.

## Later (backlog)
- [ ] Design templates: several per site, switchable by a setting (corporate: 3 home-page styles; shop: 2; blog: 2), plus a design guide for designers (sections, what goes in each, text limits, banner and image sizes, safe areas)
- [ ] Excel/CSV import and export for accounts (expenses, opening balances, journals, chart of accounts; report exports to .xlsx)
- [ ] Other items as they come up
