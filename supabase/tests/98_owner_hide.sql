-- 98: a booking's revenue hidden from the owner until it is revealed, and the documented owner deductions on a booking
-- (migration 0156, docs/changes/2026-10-25-hide-revenue-from-owner.md). Fixtures start with "oh".
select test.suite('98 owner hide and booking deductions');
grant usage on schema test to service_role;
grant execute on all functions in schema test to authenticated, anon, service_role;

select test.eq('setting: owners see a booking''s revenue right away by default',
  (select column_default from information_schema.columns where table_name = 'program_settings' and column_name = 'owner_revenue_visibility'), '''right_away''::text');
select test.eq('every booking made before 0156 is shown', (select count(*) from bookings where owner_visibility <> 'shown'), 0::bigint);

select test.mk_user('oh_admin', 'admin');
select test.mk_user('oh_cs', 'va', 'cs');
select test.mk_user('oh_sales', 'va', 'sales');
select test.mk_user('oh_fin', 'va', 'finance');
select test.mk_owner('oh_o');
select test.mk_vehicle('OHA', 'oh_o');
select test.mk_vehicle('OHB', 'oh_o');
select test.mk_renter('oh_r');
-- a Toronto wall-clock time p_days from today (the finished rentals end yesterday: the month of yesterday is the month checked)
create function test.ohl(p_days integer, p_hour text default '10:00') returns text language sql stable as $$
  select to_char((now() at time zone 'America/Toronto')::date + p_days, 'YYYY-MM-DD') || ' ' || p_hour $$;
create function test.ohm() returns date language sql stable as $$ select app.month_start(app.today() - 1) $$;
create function test.ohb(p text) returns uuid language sql stable as $$ select test.id('booking:' || p) $$;
create function test.ohrow(p text) returns jsonb language sql stable as $$
  select b from jsonb_array_elements(public.owner_portal_bookings(test.id('oh_o'))) b where b ->> 'booking_id' = test.ohb(p)::text $$;
create function test.ohvis(p_user text, p jsonb) returns jsonb language sql as $$ select app.door(test.id(p_user), 'aal2', 'ops_do', 'booking_owner_visibility_set', p) $$;

select test.mk_booking('OH-1', 'OHA', 'oh_r', test.ohl(-2, '09:00'), test.ohl(-1, '09:00'), 'closed', 30000);
select test.mk_booking('OH-2', 'OHB', 'oh_r', test.ohl(-2, '12:00'), test.ohl(-1, '12:00'), 'closed', 20000);
select test.mk_booking('OH-3', 'OHA', 'oh_r', test.ohl(10), test.ohl(12), 'confirmed');
select test.mk_booking('OH-4', 'OHB', 'oh_r', test.ohl(10), test.ohl(12), 'confirmed', 0);

-- ================================================================ 1. the default and who may change it
select test.eq('a new booking takes the setting: right away', (select owner_visibility from bookings where id = test.ohb('OH-3')), 'shown');
update program_settings set owner_revenue_visibility = 'statement';
select test.mk_booking('OH-5', 'OHA', 'oh_r', test.ohl(20), test.ohl(22), 'confirmed');
update program_settings set owner_revenue_visibility = 'after_return';
select test.mk_booking('OH-6', 'OHA', 'oh_r', test.ohl(30), test.ohl(32), 'confirmed');
update program_settings set owner_revenue_visibility = 'right_away';
select test.eq('the setting "when the statement is approved", "after the return"; the owner''s own booking is always theirs',
  (select string_agg(booking_number || '=' || owner_visibility, ' ' order by booking_number) from bookings where booking_number in ('OH-5', 'OH-6')) || ' owner=' || app.owner_visibility_default('owner'),
  'OH-5=until_statement OH-6=until_return owner=shown');
select test.eq('the forms'' default from the door', (app.door(test.id('oh_cs'), 'aal2', 'ops_read', 'owner_visibility_defaults', '{}') ->> 'may'), 'true');

select test.throws('sales may not hide a booking from the owner', $$select test.ohvis('oh_sales', jsonb_build_object('booking', 'OH-2', 'visibility', 'until_statement'))$$, 'Only an Admin, customer service or fleet');
select test.throws('finance may not either', $$select test.ohvis('oh_fin', jsonb_build_object('booking', 'OH-2', 'visibility', 'until_statement'))$$, 'Only an Admin, customer service or fleet');
select test.lives('customer service hides OH-2 until the statement, with a reason',
  $$select test.ohvis('oh_cs', jsonb_build_object('booking', 'OH-2', 'visibility', 'until_statement', 'reason', 'Price under review with the owner'))$$);
select test.eq('logged: the change, who and why, and in the booking history',
  (select visibility_from || '>' || visibility_to || '/' || reason || '/' || (changed_by = test.id('oh_cs')) from booking_owner_visibility_log where booking_id = test.ohb('OH-2')) || '/' ||
  (select count(*) from booking_events where booking_id = test.ohb('OH-2') and kind = 'owner_visibility'), 'shown>until_statement/Price under review with the owner/true/1');
select test.eq('the booking page says it plainly',
  (app.door(test.id('oh_admin'), 'aal2', 'ops_read', 'booking_owner_visibility', '{"booking": "OH-2"}') ->> 'label'),
  'Hidden from the owner until the owner statement covering it is approved: they see the dates as Booked, not the amounts.');
select test.throws('the log is kept as recorded', $$delete from booking_owner_visibility_log$$, 'kept as it was recorded');

-- ================================================================ 2. the owner's reads never carry a hidden booking's amounts
select test.eq('owner bookings: a shown booking with its amount', (test.ohrow('OH-1') ->> 'owner_view') || '/' || (test.ohrow('OH-1') ->> 'rental_charge_cents'), 'full/30000');
select test.eq('owner bookings: the hidden one as Booked with its dates, no amount',
  (test.ohrow('OH-2') ->> 'owner_view') || '/' || coalesce(test.ohrow('OH-2') ->> 'rental_charge_cents', 'none') || '/' || (test.ohrow('OH-2') ->> 'booking_number') || '/' || (test.ohrow('OH-2') ->> 'pickup_at' is not null),
  'booked/none/OH-2/true');
select test.eq('owner bookings: "after the return" hides until the car is back', (test.ohrow('OH-6') ->> 'owner_view') || '/' || coalesce(test.ohrow('OH-6') ->> 'rental_charge_cents', 'none'), 'booked/none');
update bookings set owner_visibility = 'until_return' where id = test.ohb('OH-1');
select test.eq('owner bookings: "after the return" on a returned booking shows it', test.ohrow('OH-1') ->> 'owner_view', 'full');
update bookings set owner_visibility = 'shown' where id = test.ohb('OH-1');
select test.eq('owner bookings: no amount anywhere in a hidden booking''s row',
  (select count(*) from jsonb_each(test.ohrow('OH-2')) e where e.key ~ '(cents|share|expense)' and jsonb_typeof(e.value) = 'number'), 0::bigint);

-- the split exists for the finished rentals (the statement's own step)
select app.compute_booking_split(test.ohb('OH-1'));
select app.compute_booking_split(test.ohb('OH-2'));
select test.login(test.id('oh_o'));
select test.eq('owner view: the hidden booking''s amounts are empty, the shown one''s there',
  (select string_agg(booking_number || ':' || coalesce(rental_charge_cents::text, '-') || ':' || coalesce(owner_payout_cents::text, '-') || ':' || owner_view, ' ' order by booking_number)
     from owner_bookings where booking_number in ('OH-1', 'OH-2')), 'OH-1:30000:' || (select owner_payout_cents from booking_splits where booking_id = test.ohb('OH-1')) || ':full OH-2:-:-:booked');
select test.eq('owner rows: the hidden booking''s split is not readable', test.visible(format('select * from booking_splits where booking_id = %L', test.ohb('OH-2'))), 0::bigint);
select test.eq('owner rows: the shown booking''s split is', test.visible(format('select * from booking_splits where booking_id = %L', test.ohb('OH-1'))), 1::bigint);
select test.logout();

-- the month to date leaves the hidden booking out of the provisional figures
create table test.ohseq as select last_value from pg_sequences where sequencename = 'owner_statement_number_seq';
create table test.ohmtd as select public.owner_portal_month_to_date(test.id('oh_o'), test.ohm()) x;
select test.eq('month to date: provisional, OH-1 in it, OH-2 not, and one held back',
  (select (x ->> 'provisional') || '/' || (x::text like '%OH-1%') || '/' || (x::text like '%OH-2%') || '/' || (x ->> 'held_back') from test.ohmtd), 'true/true/false/1');
select test.eq('month to date: the Owner Revenue is OH-1''s alone',
  (select (x #>> '{totals,owner_revenue_cents}')::bigint from test.ohmtd), (select owner_revenue_cents from booking_splits where booking_id = test.ohb('OH-1')));
select test.eq('month to date: nothing kept, the hidden split untouched',
  (select count(*) from owner_statements where owner_id = test.id('owner:oh_o')) || '/' ||
  ((select last_value from pg_sequences where sequencename = 'owner_statement_number_seq') is not distinct from (select last_value from test.ohseq)) || '/' ||
  (select payout_month = test.ohm() from booking_splits where booking_id = test.ohb('OH-2')), '0/true/true');

-- ================================================================ 3. not shown at all: only a booking with no owner revenue
select test.throws('never: refused on a booking with owner revenue', $$select test.ohvis('oh_admin', jsonb_build_object('booking', 'OH-1', 'visibility', 'never'))$$, 'no owner revenue');
select app.ntf_emit('owner_new_booking', 'booking', test.ohb('OH-4'), 'oh-test', jsonb_build_object('booking_id', test.ohb('OH-4'), 'owner_id', test.id('owner:oh_o')));
select test.lives('never: an insurance placeholder at no charge', $$select test.ohvis('oh_admin', jsonb_build_object('booking', 'OH-4', 'visibility', 'never', 'reason', 'Insurance placeholder'))$$);
select test.eq('never: the owner sees only that the car is unavailable (no number, no amount, no renter)',
  (test.ohrow('OH-4') ->> 'owner_view') || '/' || coalesce(test.ohrow('OH-4') ->> 'booking_number', 'none') || '/' || coalesce(test.ohrow('OH-4') ->> 'rental_charge_cents', 'none') || '/' || (test.ohrow('OH-4') ->> 'return_at' is not null),
  'unavailable/none/none/true');
select test.eq('never: the owner booking notice waiting is not sent',
  (select process_note from app_events where code = 'owner_new_booking' and entity_id = test.ohb('OH-4')), 'not shown to the owner (0156)');
select app.ntf_emit('owner_booking_changed', 'booking', test.ohb('OH-4'), 'oh-test2', jsonb_build_object('booking_id', test.ohb('OH-4'), 'owner_id', test.id('owner:oh_o')));
select test.eq('never: a later owner notice is not sent either',
  (select processed_at is not null from app_events where code = 'owner_booking_changed' and entity_id = test.ohb('OH-4')), true);
update bookings set rental_charge_cents = 5000, subtotal_at_booking_cents = 5000 where id = test.ohb('OH-4');
select test.eq('never: once it carries owner revenue it is only hidden (Booked), never shown lower', test.ohrow('OH-4') ->> 'owner_view', 'booked');
update bookings set rental_charge_cents = 0, subtotal_at_booking_cents = 0 where id = test.ohb('OH-4');

-- the owner email of a hidden booking: no amount
select app.ntf_emit('owner_new_booking', 'booking', test.ohb('OH-5'), 'oh-test3', jsonb_build_object('booking_id', test.ohb('OH-5'), 'owner_id', test.id('owner:oh_o')));
select test.eq('email: show_amounts off and no rental charge for a hidden booking',
  (select (x ->> 'show_amounts') || '/' || coalesce(x ->> 'rental_charge', 'none') from app_events e,
     lateral (select app.notification_payload('owner_new_booking', e, jsonb_build_object('audience', 'owner', 'owner_id', test.id('owner:oh_o'), 'user_id', test.id('oh_o'))) x) y
    where e.code = 'owner_new_booking' and e.entity_id = test.ohb('OH-5')), 'false/');
select test.eq('email: the catalogue preheader carries no amount',
  (select preheader from notification_catalogue where code = 'owner_new_booking') || ' | ' || (select preheader from notification_catalogue where code = 'owner_booking_changed'),
  'Booking {{booking_number}}: {{pickup_date}} to {{return_date}}. | The new details of booking {{booking_number}}.');

-- ================================================================ 4. documented owner deductions
update program_settings set staff_may_edit_fees = false;
select test.throws('deduction: sales may not while Program settings do not let them change fees',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_expense_add', '{"booking": "OH-1", "category": "cleaning", "amount_cents": 5000, "reason": "Smoke smell"}')$$, test.id('oh_sales')), 'Only an Admin');
update program_settings set staff_may_edit_fees = true;
select test.throws('deduction: the reason is written', format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_expense_add', '{"booking": "OH-1", "category": "cleaning", "amount_cents": 5000}')$$, test.id('oh_cs')), 'reason');
select test.lives('deduction: a cleaning expense with its reason and receipt',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_expense_add', '{"booking": "OH-1", "category": "cleaning", "amount_cents": 5000, "reason": "Smoke smell, ozone treatment", "receipt_ref": "RCPT-77"}')$$, test.id('oh_cs')));
select test.lives('deduction: a fuel expense, then removed with a reason',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_expense_void', jsonb_build_object('id', (app.door(%L, 'aal2', 'ops_do', 'booking_owner_expense_add', '{"booking": "OH-1", "category": "fuel", "amount_cents": 1500, "reason": "Refill to full"}') #>> '{expenses,1,id}'), 'reason', 'Renter paid the fuel'))$$,
    test.id('oh_admin'), test.id('oh_admin')));
select test.eq('deduction: the split takes the expense off before Owner Revenue, and the share on what is left',
  (select owner_expense_cents || '/' || owner_revenue_cents || '/' || company_share_cents || '/' || owner_payout_cents from booking_splits where booking_id = test.ohb('OH-1')),
  '5000/25000/' || public.calc_bps(25000, 3500) || '/' || (25000 - public.calc_bps(25000, 3500)));
select test.throws('share: above the car''s signed terms is refused for customer service',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_share_set', '{"booking": "OH-1", "bps": 4000, "reason": "Extra handling"}')$$, test.id('oh_cs')), 'above the car''s signed terms');
select test.throws('share: and for an Admin without "Above the signed terms"',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_share_set', '{"booking": "OH-1", "bps": 4000, "reason": "Extra handling"}')$$, test.id('oh_admin')), 'above the car''s signed terms');
select test.lives('share: within the terms (customer service)',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_share_set', '{"booking": "OH-1", "bps": 3000, "reason": "Owner referred this renter"}')$$, test.id('oh_cs')));
select test.lives('share: above the terms by an Admin with the override and the reason',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_share_set', '{"booking": "OH-1", "bps": 4000, "reason": "Delivery handled by us, agreed with the owner", "above_terms": true}')$$, test.id('oh_admin')));
select test.eq('share: the split uses it',
  (select company_share_bps || '/' || company_share_cents || '/' || owner_payout_cents || '/' || booking_share_override from booking_splits where booking_id = test.ohb('OH-1')),
  '4000/' || public.calc_bps(25000, 4000) || '/' || (25000 - public.calc_bps(25000, 4000)) || '/true');
select test.eq('history: each step in the booking history',
  (select string_agg(kind, ',' order by id) from booking_events where booking_id = test.ohb('OH-1') and kind in ('owner_expense', 'owner_share')), 'owner_expense,owner_expense,owner_expense,owner_share,owner_share');
select test.eq('portal: the owner sees each deduction on the booking (category, amount, reason) and the share',
  (select (test.ohrow('OH-1') #>> '{owner_expenses,0,category}') || '/' || (test.ohrow('OH-1') #>> '{owner_expenses,0,amount_cents}') || '/' || (test.ohrow('OH-1') #>> '{owner_expenses,0,reason}')
     || '/' || jsonb_array_length(test.ohrow('OH-1') -> 'owner_expenses') || '/' || (test.ohrow('OH-1') ->> 'booking_share_bps')),
  'cleaning/5000/Smoke smell, ozone treatment/1/4000');
select test.eq('portal: a hidden booking shows no deduction', jsonb_array_length(test.ohrow('OH-2') -> 'owner_expenses'), 0);

-- ================================================================ 5. the statement: every booking, true amounts, every deduction itemized; approving reveals
create table test.ohst as select app.build_owner_statement(test.id('owner:oh_o'), test.ohm()) as id;
select test.eq('statement: the hidden booking is on it at its true amount',
  (select owner_revenue_cents::text from owner_statement_lines where owner_statement_id = (select id from test.ohst) and booking_id = test.ohb('OH-2')),
  (select owner_revenue_cents::text from booking_splits where booking_id = test.ohb('OH-2')));
select test.eq('statement: OH-1''s line: Owner Revenue after the expense, the booking''s share, the payout',
  (select owner_expense_cents || '/' || owner_revenue_cents || '/' || revenue_share_cents || '/' || amount_cents || '/' || booking_share_bps
     from owner_statement_lines where owner_statement_id = (select id from test.ohst) and booking_id = test.ohb('OH-1')),
  '5000/25000/' || public.calc_bps(25000, 4000) || '/' || (25000 - public.calc_bps(25000, 4000)) || '/4000');
select test.eq('statement: the line names each deduction and the reason',
  (select description like '%booking expenses $50.00 (Cleaning $50.00: Smoke smell, ozone treatment)%' and description like '%Revenue Share for this booking 40%(Delivery handled by us, agreed with the owner)%'
     from owner_statement_lines where owner_statement_id = (select id from test.ohst) and booking_id = test.ohb('OH-1')), true);
select test.eq('statement: the totals add up from the lines',
  (select owner_revenue_cents = (select sum(owner_revenue_cents) from owner_statement_lines l where l.owner_statement_id = s.id and l.line_type in ('rental', 'turo_trip')) from owner_statements s where s.id = (select id from test.ohst)), true);
select app.approve_owner_statement((select id from test.ohst), test.id('oh_admin'));
select test.eq('approved: the hidden booking is revealed, logged as the statement''s',
  (select owner_visibility from bookings where id = test.ohb('OH-2')) || '/' || (test.ohrow('OH-2') ->> 'owner_view') || '/' || (test.ohrow('OH-2') ->> 'rental_charge_cents') || '/' ||
  (select how from booking_owner_visibility_log where booking_id = test.ohb('OH-2') order by id desc limit 1), 'shown/full/20000/statement');
select test.eq('approved: the not-shown booking (no owner revenue) stays as it is', test.ohrow('OH-4') ->> 'owner_view', 'unavailable');
select test.throws('approved: a booking on an approved statement cannot be hidden again', $$select test.ohvis('oh_admin', jsonb_build_object('booking', 'OH-2', 'visibility', 'until_statement'))$$, 'already sees it');
select test.throws('approved: no deduction added after it is paid out',
  format($$select app.door(%L, 'aal2', 'ops_do', 'booking_owner_expense_add', '{"booking": "OH-1", "category": "repair", "amount_cents": 100, "reason": "Late find"}')$$, test.id('oh_admin')), 'approved owner statement');
select test.eq('approved: the owner''s statement read shows the deduction', (select (public.owner_portal_statement(test.id('oh_o'), (select id from test.ohst)))::text like '%Smoke smell%'), true);

-- ================================================================ privileges
set role authenticated;
select test.throws('authenticated: no door', $$select app.booking_owner_visibility_set(gen_random_uuid(), '{}')$$, null);
reset role;
