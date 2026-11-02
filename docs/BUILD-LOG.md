# Royal Glow platform: build log and setup

## Where things live
- GitHub: Royal-Glow-Gh/royal-glow-platform (private monorepo)
  - apps/production/index.html: production batch costing
  - apps/production/inventory.html: inventory (stock on hand, purchases, transfers, adjustments, movements, setup)
  - apps/production/sales.html: sales (new sale, history, customers & credit, returns, price list, reports)
  - apps/production/staff.html: staff & account (sign-up, forgot password, change password; admins approve staff and set roles)
  - apps/production/config.js: Supabase URL + publishable key (never the secret key). config.example.js is the template.
  - apps/production/assets/: logo and favicons
  - supabase/migrations/001_production.sql: staff, items, batches, batch_inputs; views batch_costs, item_current_cost
  - supabase/migrations/002_inventory.sql: locations (Factory auto-created), suppliers, purchases, transfers, stock_adjustments; views stock_ledger, stock_on_hand; item kind 'goods'; reorder levels
  - supabase/migrations/003_sales.sql: retail/wholesale prices on items, customers, sales, sale_lines, customer_payments, sale_returns; stock_ledger includes sales and restocked returns; views sale_totals, customer_balances
  - supabase/migrations/004_staff.sql: admin-only functions list_unassigned_users, staff_directory; trigger keeping at least one admin
  - supabase/migrations/005_multi_roles.sql: staff.roles (a list) replaces staff.role, so one person can hold several roles
  - .github/workflows/publish-production.yml: on push to main, copies apps/production to the deploy-production branch
- Supabase project: royal-glow (North EU, Stockholm)
- Hosting: Hostinger deploys branch deploy-production to production.royalglowgh.com (/inventory.html, /sales.html, /staff.html)

## Supabase Auth settings (Authentication -> ...)
- Sign In / Providers: "Allow new users to sign up" ON; email confirmation ON.
- URL Configuration: Site URL https://production.royalglowgh.com ; Redirect URLs include https://production.royalglowgh.com/**
- Supabase's built-in email sender is limited and meant for testing. Before go-live, set up custom SMTP (e.g. a Royal Glow mailbox on Hostinger) so confirmation and reset emails are reliable and come from Royal Glow.

## How a change goes live
Edit in Codespace -> commit -> Sync -> GitHub Action updates deploy-production -> Hostinger redeploys.
Make edits in the Codespace, not on GitHub.com (avoids merge conflicts). If you do edit on the website, Sync the Codespace first.

## Roles (a person can hold several, e.g. production + sales)
- admin: everything, including approving staff and changing roles
- production: batches and items; can view inventory and sales
- inventory: purchases, transfers, adjustments, locations, suppliers, reorder levels
- sales: sales, customers, payments, returns, selling prices

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

## Data status
- Decision: the database holds SAMPLE data while the apps are being built. Clear all sample data once the build is finished, before entering real data.
- Clearing sample data (extend this list as new tables are added):
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
- [ ] Custom SMTP for auth emails (before go-live)
- [ ] Storefront and customer accounts
- [ ] Spa bookings
- [ ] Blog
- [ ] Decide how distributors fit in (e.g. pickup points)
- [ ] Go-live: clear all sample data, enter real data
