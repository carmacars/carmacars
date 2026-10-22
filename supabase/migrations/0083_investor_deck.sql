-- 0083_investor_deck.sql
-- The investor deck (the owner's request of October 21, 2026; docs/changes/2026-10-21-investor-deck.md): a slide deck
-- in the investor portal (/investor/deck) and its Admin preview (/admin/investors/deck).
--   1. `deck_settings` (one row): "Show the deck to investors" (on: the lawyer approved the deck and the 3.2x wording
--      on October 21, 2026), the company's multiplier figure shown on the profitability slide (3.2), and the yearly
--      percentage of the current offer used by the return examples and the calculator (30%, 3000 basis points; each
--      investor's own percentage is the one in their agreement).
--   2. `app.deck_figures()`: every number the deck shows, read from the database at the time it is shown: the owner fee
--      tiers, the partner commission, the deductible and deposits, the real cars' public rates and delivery fee, the
--      add-ons and renter fees, the investment terms of Program settings, the number of automated emails, and the
--      sample 3-day rental built from those public prices with its split by supply type. No internal cost, no fleet
--      count, no utilization: the owner's direction of October 21, 2026.
--   3. The door: `admin_read` "investor_deck" (Admin, always), `investor_read` "deck" (an investor, only while the
--      switch is on) and "deck_visible", `admin_do` "deck_settings_save" (Admin).
-- No applied migration is edited.

-- ================================================================ 1. the settings
create table deck_settings (
  id                 boolean primary key default true check (id),
  show_to_investors  boolean not null default true,
  deck_multiplier    numeric(5,2) not null default 3.2 check (deck_multiplier > 0 and deck_multiplier < 100),
  deck_return_bps    integer not null default 3000 check (deck_return_bps between 1 and 10000),
  updated_by         uuid references users (id),
  updated_at         timestamptz not null default now()
);
comment on table deck_settings is 'The investor deck (0083): shown to investors or not, the company''s multiplier figure, the yearly percentage of the current offer for the examples. One row.';
comment on column deck_settings.deck_multiplier is 'CarmaCars'' own figure: the multiplier on the money the company invests in the fleet (internal, not audited). Shown as "3.2x".';
comment on column deck_settings.deck_return_bps is 'The yearly percentage of the current offer, for the deck''s worked examples and calculator only. Each investor''s percentage is the one in their Schedule A.';
insert into deck_settings default values;

alter table deck_settings enable row level security;
create policy admin_all on deck_settings for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_deck_settings after insert or update or delete on deck_settings for each row execute function app.audit_row();
revoke all on deck_settings from anon;

-- ================================================================ 2. the figures
-- The median of a set of amounts (the lower middle value for an even count, so the example never rounds up).
create or replace function app.deck_median(p bigint[]) returns bigint
language sql immutable as $$
  select x from (select x, row_number() over (order by x) n, count(*) over () c from unnest(p) x where x is not null) s
   where n = (c + 1) / 2
$$;

create or replace function app.deck_figures() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  d deck_settings;
  ss site_settings;
  v_rates bigint[];
  v_delivery bigint[];
  v_rate bigint;
  v_rate_source text := 'real';
  v_del bigint;
  v_days integer := 3;  -- the sample rental: a 3-day trip
  v_addon record;
  v_addon_cents bigint := 0;
  v_young bigint;
  v_rental bigint;
  v_company_only bigint;
  v_tiers jsonb;
  v_splits jsonb;
begin
  select * into d from deck_settings limit 1;
  select * into ss from site_settings limit 1;

  -- the real cars' public prices (sample cars left out); the default rate of a standard car when no real car is listed
  select array_agg(p.daily_rate_cents::bigint order by p.daily_rate_cents), array_agg(p.delivery_fee_cents::bigint order by p.delivery_fee_cents)
    into v_rates, v_delivery
    from public_vehicle_listings p join vehicles v on v.id = p.vehicle_id
   where not v.is_sample and p.daily_rate_cents > 0;
  v_rate := app.deck_median(v_rates);
  if v_rate is null then
    v_rate := coalesce((s.listing_default_daily_rate_cents ->> 'standard')::bigint, 0);
    v_rate_source := 'default';
  end if;
  v_del := coalesce(app.deck_median(array(select x from unnest(v_delivery) x where x > 0)), 0);

  -- one per-day add-on (the first of the catalogue's order), for the days of the trip, within its cap
  select a.name, a.price_cents, a.cap_cents into v_addon
    from addons a where a.active and a.pricing_unit = 'per_day' and a.price_cents > 0 order by a.sort_order, a.name limit 1;
  if v_addon.price_cents is not null then v_addon_cents := least(v_addon.price_cents * v_days, coalesce(v_addon.cap_cents, v_addon.price_cents * v_days)); end if;
  v_young := coalesce((select f.amount_cents from fee_defaults f where f.fee_type_code = 'young_driver_21_25' and f.vehicle_class is null
                          and f.effective_from <= app.today() and (f.effective_to is null or f.effective_to > app.today())
                        order by f.effective_from desc limit 1), 0) * v_days;
  v_rental := v_rate * v_days;
  v_company_only := v_del + v_addon_cents + v_young;

  -- the owner program's published tiers (the newest grid in effect)
  select coalesce(jsonb_agg(jsonb_build_object('min_vehicles', g.min_vehicles, 'max_vehicles', g.max_vehicles,
           'insurance_fee_cents', g.insurance_fee_cents, 'tracker_fee_cents', g.tracker_fee_cents, 'revenue_share_bps', g.revenue_share_bps,
           'monthly_fees_cents', g.insurance_fee_cents + g.tracker_fee_cents) order by g.min_vehicles), '[]'::jsonb)
    into v_tiers
    from owner_fee_grid g
   where g.effective_from = (select max(x.effective_from) from owner_fee_grid x where x.effective_from <= app.today());

  -- how the sample rental splits: an owner car at each tier, a company car, a brokered partner car
  select jsonb_agg(x order by ord) into v_splits from (
    select 1 + (t ->> 'min_vehicles')::int as ord, jsonb_build_object(
             'kind', 'program_owner', 'label', format('Owner car, %s', case when t ->> 'max_vehicles' is null then format('%s or more cars', t ->> 'min_vehicles')
                                                                       else format('%s to %s cars', t ->> 'min_vehicles', t ->> 'max_vehicles') end),
             'share_bps', (t ->> 'revenue_share_bps')::int,
             'company_rental_cents', round(v_rental * (t ->> 'revenue_share_bps')::numeric / 10000)::bigint,
             'owner_cents', v_rental - round(v_rental * (t ->> 'revenue_share_bps')::numeric / 10000)::bigint,
             'company_cents', round(v_rental * (t ->> 'revenue_share_bps')::numeric / 10000)::bigint + v_company_only,
             'monthly_fees_cents', (t ->> 'monthly_fees_cents')::bigint) x
      from jsonb_array_elements(v_tiers) t
    union all
    select 1000, jsonb_build_object('kind', 'company', 'label', 'Company car', 'share_bps', 10000, 'company_rental_cents', v_rental,
             'owner_cents', 0, 'company_cents', v_rental + v_company_only, 'monthly_fees_cents', 0)
    union all
    select 1001, jsonb_build_object('kind', 'partner', 'label', 'Brokered partner car', 'share_bps', coalesce(s.partner_commission_bps, 0),
             'company_rental_cents', round(v_rental * coalesce(s.partner_commission_bps, 0)::numeric / 10000)::bigint,
             'owner_cents', v_rental - round(v_rental * coalesce(s.partner_commission_bps, 0)::numeric / 10000)::bigint,
             'company_cents', round(v_rental * coalesce(s.partner_commission_bps, 0)::numeric / 10000)::bigint + v_company_only, 'monthly_fees_cents', 0)
  ) z;

  return jsonb_build_object(
    'settings', jsonb_build_object('show_to_investors', d.show_to_investors, 'deck_multiplier', d.deck_multiplier, 'deck_return_bps', d.deck_return_bps,
                                   'updated_at', d.updated_at, 'updated_by', (select u.full_name from users u where u.id = d.updated_by)),
    'brand', jsonb_build_object('name', coalesce(ss.brand_name, 'CarmaCars'), 'tagline', ss.tagline, 'city', ss.city, 'service_area', ss.service_area,
                                'phone', coalesce(ss.phone_display, ss.phone), 'phone_href', ss.phone, 'email', coalesce(ss.public_email, s.company_email),
                                'incident_phone', coalesce(ss.roadside_phone_display, ss.phone_display), 'site_url', ss.site_url),
    'investment', jsonb_build_object('min_cents', s.investor_min_cents, 'lockup_months', s.investor_lockup_months,
                                     'redemption_notice_months', s.investor_redemption_notice_months, 'payment_day', s.investor_payment_day,
                                     'election_notice_days', 10),
    'owner_tiers', v_tiers,
    'install_fee_cents', s.install_fee_cents,
    'partner_commission_bps', s.partner_commission_bps,
    'deductible_cents', s.deductible_cents,
    'deposits', (select jsonb_build_object('min_cents', min(f.amount_cents), 'max_cents', max(f.amount_cents)) from fee_defaults f
                  where f.fee_type_code = 'deposit' and f.effective_from <= app.today() and (f.effective_to is null or f.effective_to > app.today())),
    'rates', jsonb_build_object('source', v_rate_source, 'min_daily_cents', v_rates[1], 'max_daily_cents', v_rates[cardinality(v_rates)],
                                'median_daily_cents', v_rate, 'delivery_cents', v_del),
    'addons', coalesce((select jsonb_agg(jsonb_build_object('name', a.name, 'unit', a.pricing_unit, 'price_cents', a.price_cents, 'cap_cents', a.cap_cents)
                          order by a.sort_order, a.name) from addons a where a.active and a.price_cents > 0), '[]'::jsonb),
    'fees', (select jsonb_object_agg(f.fee_type_code, jsonb_build_object('amount_cents', f.amount_cents, 'percent_bps', f.percent_bps))
               from (select distinct on (fee_type_code) * from fee_defaults
                      where vehicle_class is null and effective_from <= app.today() and (effective_to is null or effective_to > app.today())
                        and fee_type_code in ('young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'late_return_fee', 'cleaning',
                                              'toll_admin_fee', 'ticket_admin_fee', 'fuel_service_fee', 'lost_key_fee', 'smoking', 'pet_cleaning')
                      order by fee_type_code, effective_from desc) f),
    'emails', (select count(*) from notification_catalogue c where c.has_email and c.is_enabled),
    'sample', jsonb_build_object('days', v_days, 'daily_rate_cents', v_rate, 'rental_cents', v_rental, 'delivery_cents', v_del,
                                 'addon_name', v_addon.name, 'addon_cents', v_addon_cents, 'young_driver_cents', v_young,
                                 'company_only_cents', v_company_only, 'total_cents', v_rental + v_company_only, 'splits', coalesce(v_splits, '[]'::jsonb)));
end $$;

-- ================================================================ 3. the reads and the save
create or replace function app.deck_read(p_user uuid, p_as text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i investors;
begin
  if p_as = 'admin' then
    perform app.assert_admin(p_user);
    return app.deck_figures() || jsonb_build_object('viewer', 'admin');
  end if;
  i := app.investor_of(p_user);
  if not coalesce((select show_to_investors from deck_settings limit 1), false) then
    raise exception 'The investor deck is not open yet' using errcode = '42501';
  end if;
  return app.deck_figures() || jsonb_build_object('viewer', 'investor', 'investor_name', i.legal_name);
end $$;

-- p: any of show_to_investors (boolean), deck_multiplier (number above 0 and under 100), deck_return_bps (1 to 10000)
create or replace function app.deck_settings_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_mult numeric;
  v_bps integer;
begin
  perform app.assert_admin(p_user);
  if p_ ? 'show_to_investors' and jsonb_typeof(p_ -> 'show_to_investors') <> 'boolean' then
    raise exception 'Choose whether investors see the deck' using errcode = '22023';
  end if;
  if p_ ? 'deck_multiplier' then
    begin v_mult := (p_ ->> 'deck_multiplier')::numeric; exception when others then v_mult := null; end;
    if v_mult is null or v_mult <= 0 or v_mult >= 100 then raise exception 'Enter the multiplier as a number, such as 3.2' using errcode = '22023'; end if;
  end if;
  if p_ ? 'deck_return_bps' then
    begin v_bps := (p_ ->> 'deck_return_bps')::numeric::integer; exception when others then v_bps := null; end;
    if v_bps is null or v_bps < 1 or v_bps > 10000 then raise exception 'Enter the yearly percentage, between 0.01%% and 100%%' using errcode = '22023'; end if;
  end if;
  update deck_settings set
    show_to_investors = case when p_ ? 'show_to_investors' then (p_ ->> 'show_to_investors')::boolean else show_to_investors end,
    deck_multiplier = coalesce(round(v_mult, 2), deck_multiplier),
    deck_return_bps = coalesce(v_bps, deck_return_bps),
    updated_by = p_user, updated_at = now();
  return (select jsonb_build_object('show_to_investors', show_to_investors, 'deck_multiplier', deck_multiplier, 'deck_return_bps', deck_return_bps)
            from deck_settings limit 1);
end $$;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0083;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'investor_deck' then
    perform app.door_begin(p_user, p_aal);
    return app.deck_read(p_user, 'admin');
  elsif p_call = 'investor_read' and p_name = 'deck' then
    perform app.door_begin(p_user, p_aal);
    return app.deck_read(p_user, 'investor');
  elsif p_call = 'investor_read' and p_name = 'deck_visible' then
    perform app.door_begin(p_user, p_aal);
    perform app.investor_of(p_user);
    return jsonb_build_object('visible', coalesce((select show_to_investors from deck_settings limit 1), false));
  elsif p_call = 'admin_do' and p_name = 'deck_settings_save' then
    perform app.door_begin(p_user, p_aal);
    return app.deck_settings_save(p_user, p);
  end if;
  return app.door_pre0083(p_user, p_aal, p_call, p_name, p);
end $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['deck_median', 'deck_figures', 'deck_read', 'deck_settings_save', 'door'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- The renamed door keeps its privileges; the door in its place gets the same.
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, oidvectortypes(p.proargtypes) as args from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = 'door_pre0083' loop
    v_new := format('app.door(%s)', r.args)::regprocedure;
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;

-- ================================================================ 5. the guides for this release
-- GUIDES 0083 START (generated by supabase/seed/0083_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('investor', 'the-investor-deck', 'chapter', 'how-your-returns-work', null, 'The investor deck', 'What CarmaCars built, how it makes money, and a calculator for your Return.',
  'The investor deck tells the CarmaCars story in slides: the problem we solve, how the business makes money, every feature of the platform with its real screen, the investment offer, its risks, and how your Return builds.

## Open the deck

1. On **Investments**, press **Open the deck**, or press **Investor deck** in the menu.
2. Move with **Previous** and **Next**, the arrow keys, or a swipe left or right on a phone. The list at the top jumps to any slide.
3. Press **Download PDF** to save or print it: each slide prints on its own landscape page.

## The calculator

1. Enter an amount (at least the minimum investment) and choose **Paid monthly**, **Reinvested** or **Reinvest, then paid**.
2. Choose how many years to show and the Investment Date.
3. You see when the lockup ends, your first payment date, what a full month pays, what is paid to you for the period, and your Invested Amount at the end, with a chart and a month-by-month table.

The calculator follows your agreement exactly: no Return for the lockup, then one twelfth of the Yearly Percentage on the Invested Amount each month, by days for a part month, paid on the 15th of the next month or added to the Invested Amount at month end.

> Good to know: The examples use the yearly percentage of our current offer. Your own percentage is the one in your agreement. Every example and figure in the deck is an illustration, not a forecast or a promise, and is not part of any offering memorandum.
',
  '<p class="gd-p">The investor deck tells the CarmaCars story in slides: the problem we solve, how the business makes money, every feature of the platform with its real screen, the investment offer, its risks, and how your Return builds.</p><section class="gd-task" id="the-investor-deck-open-the-deck" data-gd-task><h2 class="gd-h2">Open the deck</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On <b class="gd-ui">Investments</b>, press <b class="gd-ui">Open the deck</b>, or press <b class="gd-ui">Investor deck</b> in the menu.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Move with <b class="gd-ui">Previous</b> and <b class="gd-ui">Next</b>, the arrow keys, or a swipe left or right on a phone. The list at the top jumps to any slide.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Download PDF</b> to save or print it: each slide prints on its own landscape page.</div></li></ol></div></section><section class="gd-task" id="the-investor-deck-the-calculator" data-gd-task><h2 class="gd-h2">The calculator</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Enter an amount (at least the minimum investment) and choose <b class="gd-ui">Paid monthly</b>, <b class="gd-ui">Reinvested</b> or <b class="gd-ui">Reinvest, then paid</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how many years to show and the Investment Date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">You see when the lockup ends, your first payment date, what a full month pays, what is paid to you for the period, and your Invested Amount at the end, with a chart and a month-by-month table.</div></li></ol></div><p class="gd-p">The calculator follows your agreement exactly: no Return for the lockup, then one twelfth of the Yearly Percentage on the Invested Amount each month, by days for a part month, paid on the 15th of the next month or added to the Invested Amount at month end.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The examples use the yearly percentage of our current offer. Your own percentage is the one in your agreement. Every example and figure in the deck is an illustration, not a forecast or a promise, and is not part of any offering memorandum.</div></aside></section>');
select app.guide_release_section('admin', 'the-investor-deck', 'chapter', 'add-ons', null, 'The investor deck', 'Preview the deck, show or hide it, and set its multiplier and percentage.',
  'The investor deck is a slide deck in the investor portal at `/investor/deck`. Signed-in investors see it while it is shown; Admins always see it. Its figures come from the database when it opens: the owner fee tiers, the partner commission, the real cars'' public rates, delivery, add-ons and renter fees, the deductible and deposits, and the investment terms of Program settings.

## Preview and settings

1. Go to **Investors** and press **Investor deck**. The button says whether investors see it now.
2. The page shows the settings, then the whole deck as investors see it.
3. **Show the deck to investors**: on, investors see it under Investor deck and on their Investments page; off, only Admins see it.
4. **Multiplier on the money we invest (x)**: the company''s own figure, shown large on the profitability slide with its footnote (internal, not audited).
5. **Yearly percentage of the current offer (%)**: used by the worked examples and the calculator. Each investor''s own percentage is the one in their agreement.
6. Press **Save deck settings**. Every change is in the audit log.

To hide or show it in one click, use **Hide the deck from investors** or **Show the deck to investors** on Investors.

> Good to know: The deck shows no internal costs, fleet counts or staff pay. Every example is labelled as an illustration, with the forward-looking statements notice on every slide and in the PDF.
',
  '<p class="gd-p">The investor deck is a slide deck in the investor portal at <span class="gd-url">/investor/deck</span>. Signed-in investors see it while it is shown; Admins always see it. Its figures come from the database when it opens: the owner fee tiers, the partner commission, the real cars&#39; public rates, delivery, add-ons and renter fees, the deductible and deposits, and the investment terms of Program settings.</p><section class="gd-task" id="the-investor-deck-preview-and-settings" data-gd-task><h2 class="gd-h2">Preview and settings</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Go to <b class="gd-ui">Investors</b> and press <b class="gd-ui">Investor deck</b>. The button says whether investors see it now.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The page shows the settings, then the whole deck as investors see it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Show the deck to investors</b>: on, investors see it under Investor deck and on their Investments page; off, only Admins see it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Multiplier on the money we invest (x)</b>: the company&#39;s own figure, shown large on the profitability slide with its footnote (internal, not audited).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Yearly percentage of the current offer (%)</b>: used by the worked examples and the calculator. Each investor&#39;s own percentage is the one in their agreement.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Press <b class="gd-ui">Save deck settings</b>. Every change is in the audit log.</div></li></ol></div><p class="gd-p">To hide or show it in one click, use <b class="gd-ui">Hide the deck from investors</b> or <b class="gd-ui">Show the deck to investors</b> on Investors.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The deck shows no internal costs, fleet counts or staff pay. Every example is labelled as an illustration, with the forward-looking statements notice on every slide and in the PDF.</div></aside></section>');
-- GUIDES 0083 END
