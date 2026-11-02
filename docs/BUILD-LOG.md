# Royal Glow platform: build log and setup

## Where things live
- GitHub: Royal-Glow-Gh/royal-glow-platform (private monorepo)
  - apps/production/index.html: production batch costing
  - apps/production/inventory.html: inventory (stock on hand, purchases, transfers, adjustments, movements, setup)
  - apps/production/sales.html: sales (new sale, history, customers & credit, returns, price list, reports)
  - apps/production/staff.html: staff & account (sign-up, forgot password, change password; admins approve staff and set roles)
  - apps/production/shop-admin.html: online shop management (orders, products shown on the website with photos, delivery/MoMo settings, ship-from and pickup locations)
  - apps/production/spa.html: spa (day calendar per therapist, phone bookings, confirm/complete/no-show/cancel, treatments, therapists & time off, opening hours & booking rules, spa reports)
  - apps/production/config.js: Supabase URL + publishable key (never the secret key). config.example.js is the template.
  - apps/production/assets/: logo and favicons
  - supabase/migrations/001_production.sql: staff, items, batches, batch_inputs; views batch_costs, item_current_cost
  - supabase/migrations/002_inventory.sql: locations (Factory auto-created), suppliers, purchases, transfers, stock_adjustments; views stock_ledger, stock_on_hand; item kind 'goods'; reorder levels
  - supabase/migrations/003_sales.sql: retail/wholesale prices on items, customers, sales, sale_lines, customer_payments, sale_returns; stock_ledger includes sales and restocked returns; views sale_totals, customer_balances
  - supabase/migrations/004_staff.sql: admin-only functions list_unassigned_users, staff_directory; trigger keeping at least one admin
  - supabase/migrations/005_multi_roles.sql: staff.roles (a list) replaces staff.role, so one person can hold several roles
  - apps/shop/: the public website: shop + spa booking + customer accounts (index.html, assets/, config.js with the same Supabase values)
  - supabase/migrations/006_shop.sql: shop fields on items/locations, shop_settings, shop_profiles (auto-created for customer sign-ups), shop_orders + lines, public functions shop_catalog/shop_info/place_order, staff functions set_shop_product/fulfil_order, product-images storage bucket
  - supabase/migrations/007_delivery_zones.sql: delivery_zones (fee, who delivers, fee paid to Royal Glow or rider); orders store zone, fee_confirmed, fee_to_rider; place_order takes a zone (none = "somewhere else", fee confirmed by staff)
  - supabase/migrations/008_spa.sql: spa_services, spa_therapists (+ which treatments each does), spa_hours, spa_time_off, spa_settings, spa_bookings (database blocks double-booking); public functions spa_info/spa_slots/book_spa, cancel_my_spa_booking; new staff role 'spa'
  - .github/workflows/publish-production.yml: on push to main, copies apps/production to the deploy-production branch
  - .github/workflows/publish-shop.yml: on push to main, copies apps/shop to the deploy-shop branch
- Supabase project: royal-glow (North EU, Stockholm)
- Hosting: Hostinger deploys branch deploy-production to production.royalglowgh.com (/inventory.html, /sales.html, /shop-admin.html, /spa.html, /staff.html) and branch deploy-shop to shop.royalglowgh.com

## Supabase Auth settings (Authentication -> ...)
- Sign In / Providers: "Allow new users to sign up" ON; email confirmation ON.
- URL Configuration: Site URL https://production.royalglowgh.com ; Redirect URLs include https://production.royalglowgh.com/** and https://shop.royalglowgh.com/**
- Supabase's built-in email sender is limited and meant for testing. Before go-live, set up custom SMTP (e.g. a Royal Glow mailbox on Hostinger) so confirmation and reset emails are reliable and come from Royal Glow.

## How a change goes live
Edit in Codespace -> commit -> Sync -> GitHub Action updates deploy-production -> Hostinger redeploys.
Make edits in the Codespace, not on GitHub.com (avoids merge conflicts). If you do edit on the website, Sync the Codespace first.

## Roles (a person can hold several, e.g. production + sales)
- admin: everything, including approving staff and changing roles
- production: batches and items; can view inventory and sales
- inventory: purchases, transfers, adjustments, locations, suppliers, reorder levels
- sales: sales, customers, payments, returns, selling prices, online shop orders
- spa: spa bookings, treatments, therapists, opening hours, spa reports

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
- Customer sign-ups (account_type 'customer') get a shop profile and never appear in the staff approval list.

## Data status
- Decision: the database holds SAMPLE data while the apps are being built. Clear all sample data once the build is finished, before entering real data.
- Clearing sample data (extend this list as new tables are added):
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
- [x] Deployed to production.royalglowgh.com
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
- [ ] Blog
- [ ] Decide how distributors fit in (e.g. pickup points)
- [ ] Go-live: clear all sample data, enter real data
