-- 06: request to book (migration 0016). The request, offer, approval and confirmation flow with
-- every step allowed and refused; competing offers; the calendar switch; offer expiry; Owner
-- Bookings; billing an insurer; promo codes; reviews; the two calendars; and row-level security
-- for each role on each new table, view and function.
select test.suite('06 request to book');

-- ------------------------------------------------------------------ helpers and fixture
create or replace function test.at(p_local text) returns timestamptz
language sql immutable as $$ select p_local::timestamp at time zone 'America/Toronto' $$;

create table test.rq_ids (k text primary key, id uuid not null);
create table test.rq_times (k text primary key, at timestamptz not null);
grant select on test.rq_ids, test.rq_times to authenticated, anon;

-- the booking saved under a short key, and its status
create function test.b(p_key text) returns uuid language sql stable as $$ select id from test.rq_ids where k = p_key $$;
create function test.st(p_key text) returns text language sql stable security definer as
$$ select status::text from public.bookings where id = (select id from test.rq_ids where k = p_key) $$;

-- a request made by the renter on the website
create function test.rq_new(p_key text, p_renter text, p_vehicle text, p_pickup text, p_return text,
                            p_type booking_type default 'standard') returns uuid
language plpgsql as $$
declare
  v_id uuid;
begin
  v_id := app.request_booking(test.id('renter:' || p_renter), test.id('vehicle:' || p_vehicle), test.at(p_pickup), test.at(p_return),
                              p_type, null, 'web', test.id(p_renter));
  insert into test.rq_ids values (p_key, v_id);
  return v_id;
end $$;

create function test.rq_sign(p_key text) returns void language plpgsql as $$
declare
  v_doc uuid := gen_random_uuid();
  v_sig uuid := gen_random_uuid();
begin
  insert into documents (id, kind, storage_bucket, storage_path, booking_id)
  values (v_doc, 'rental_agreement', 'agreements', 'bookings/' || p_key || '/agreement.pdf', test.b(p_key));
  insert into signature_requests (id, document_id, provider, provider_envelope, status, completed_at)
  values (v_sig, v_doc, 'esign', 'env-rq-' || p_key, 'completed', now());
  update bookings set signature_request_id = v_sig, agreement_document_id = v_doc where id = test.b(p_key);
end $$;

create function test.rq_pay(p_key text) returns void language sql as $$
  insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
  select id, renter_id, 'booking_total', 'charge', 'card', renter_due_at_booking_cents, 'succeeded', now()
    from bookings where id = test.b(p_key) and renter_due_at_booking_cents > 0
$$;

create function test.rq_card(p_key text) returns void language sql as $$
  update bookings b set card_on_file_id = (select pm.id from payment_methods pm where pm.renter_id = b.renter_id limit 1)
   where b.id = test.b(p_key)
$$;

-- offered by customer service, approved by the renter, signed, paid, card saved: ready to confirm
create function test.rq_ready(p_key text) returns void language plpgsql as $$
declare
  b bookings;
begin
  select * into b from bookings where id = test.b(p_key);
  if b.status = 'requested' then perform app.send_offer(b.id, test.id('rq_cs')); end if;
  select * into b from bookings where id = test.b(p_key);
  if b.status = 'offered' then
    perform app.approve_offer(b.id, b.current_offer_version, (select user_id from renters where id = b.renter_id));
  end if;
  perform test.rq_sign(p_key);
  perform test.rq_pay(p_key);
  perform test.rq_card(p_key);
end $$;
grant execute on all functions in schema test to authenticated, anon;

select test.mk_user('rq_cs', 'va', 'cs');
select test.mk_user('rq_fin', 'va', 'finance');
select test.mk_user('rq_fleet', 'va', 'fleet');
select test.mk_user('rq_sales', 'va', 'sales');
select test.mk_user('rq_field', 'field', null, 'driver');
select test.mk_owner('rq_owen');
select test.mk_owner('rq_pam');
select test.mk_vehicle('RQ1', 'rq_owen');
select test.mk_vehicle('RQ2', 'rq_owen');
select test.mk_vehicle('RQ3', 'rq_pam', 'managed', 45000, 2500, 3000);
select test.mk_vehicle('RQ4', 'rq_owen');
select test.mk_vehicle('RQ5', 'rq_owen');
select test.mk_vehicle('RQ6', 'rq_owen');
-- RQ3 is priced differently, so a swap to it can be seen
update rate_cards set daily_rate_cents = 9000, weekend_rate_cents = 11000, weekly_rate_cents = 50000, monthly_rate_cents = 170000,
       deposit_cents = 50000 where vehicle_id = test.id('vehicle:RQ3');
select test.mk_renter(r) from unnest(array['rq_amy', 'rq_ben', 'rq_cat', 'rq_dan', 'rq_eve', 'rq_fay', 'rq_gus']) r;
update renters set legal_name = 'Amy Anderson' where id = test.id('renter:rq_amy');
update renters set legal_name = 'Ben Brown' where id = test.id('renter:rq_ben');
-- the Owner as a renter of their own car
insert into renters (id, user_id, legal_name, is_owner_account) values (test.id('renter:rq_owen'), test.id('rq_owen'), 'Rq Owen', true);
insert into renters (id, user_id, legal_name, is_owner_account) values (test.id('renter:rq_pam'), test.id('rq_pam'), 'Rq Pam', true);
insert into payment_methods (id, renter_id, card_brand, card_last4) values (test.id('card:rq_owen'), test.id('renter:rq_owen'), 'visa', '4242');

-- ------------------------------------------------------------------ structure
select test.eq('S the two new statuses exist and tentative is kept',
  (select string_agg(e.enumlabel, ',' order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid
    where t.typname = 'booking_status' and e.enumlabel in ('requested', 'offered', 'tentative')), 'requested,offered,tentative');
select test.eq('S a booking written with no status starts as a request',
  (select pg_get_expr(d.adbin, d.adrelid) like '%requested%' from pg_attrdef d join pg_attribute a on a.attrelid = d.adrelid and a.attnum = d.adnum
    where d.adrelid = 'public.bookings'::regclass and a.attname = 'status'), true);
select test.eq('S the calendar rule of the table: only confirmed or on rent, with the switch on',
  (select pg_get_constraintdef(oid) ~ 'confirmed.*on_rent.*blocks_calendar' and pg_get_constraintdef(oid) !~ 'tentative|pending_payment'
     from pg_constraint where conrelid = 'public.bookings'::regclass and contype = 'x'), true);
select test.eq('S every new table has row-level security, the admin policy and an audit trigger',
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname in ('insurers', 'promo_codes', 'promo_redemptions', 'booking_offers', 'booking_events', 'reviews', 'insurer_invoices')
      and c.relrowsecurity
      and exists (select 1 from pg_policies p where p.tablename = c.relname and p.policyname = 'admin_all')
      and exists (select 1 from pg_trigger g where g.tgrelid = c.oid and g.tgname = 'audit_' || c.relname)), 7::bigint);
select test.eq('S offers expire after 24 hours unless set otherwise; the turnaround buffer is 0',
  (select offer_expiry_hours || '/' || turnaround_buffer_minutes from app.settings()), '24/0');
select test.eq('S the status flow lists the request steps',
  (select string_agg(from_status || '>' || to_status, ' ' order by from_status, to_status) from status_transitions
    where entity = 'booking' and (from_status in ('requested', 'offered') or to_status in ('requested', 'offered'))),
  'offered>declined offered>pending_payment offered>requested pending_payment>requested requested>declined requested>offered requested>pending_payment');
select test.eq('S state-changing and money functions of this migration are not executable from a browser session',
  (select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))
      and p.proname in ('request_booking', 'adjust_booking', 'send_offer', 'issue_offer', 'approve_offer', 'close_offer',
                        'request_offer_change', 'decline_booking_request', 'withdraw_offer', 'set_blocks_calendar', 'expire_offers',
                        'job_offers_expire', 'apply_promo_code', 'remove_promo_code', 'reprice_booking', 'set_price_line',
                        'submit_review', 'draft_insurer_invoice', 'record_insurer_payment', 'log_booking_event',
                        'booking_insurer_share', 'promo_code_problem', 'promo_discount_cents')), null::text);
select test.eq('S the server may run every one of them',
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute')), 0::bigint);

-- ------------------------------------------------------------------ a request: no payment, no card, nothing blocked
select test.rq_new('c1', 'rq_amy', 'RQ1', '2029-03-05 10:00', '2029-03-08 10:00');
select test.eq('Q a request starts as requested, priced from the rate card: 3 weekdays = $300 + HST = $339.00',
  (select status || '/' || rental_charge_cents || '/' || total_due_at_booking_cents || '/' || renter_due_at_booking_cents
     from bookings where id = test.b('c1')), 'requested/30000/33900/33900');
select test.eq('Q no payment and no card are taken when a renter asks',
  (select (select count(*) from payments where booking_id = b.id) || '/' || coalesce(b.card_on_file_id::text, 'no card') from bookings b where id = test.b('c1')),
  '0/no card');
select test.eq('Q the rental charge is on the booking as a charge line with its HST',
  (select string_agg(charge_type || '=' || amount_cents || '+' || hst_cents, ',') from booking_line_items where booking_id = test.b('c1') and voided_at is null),
  'rental_charge=30000+3900');
select test.eq('Q the request snapshots the owner and Revenue Share and gets a booking number',
  (select (owner_id = test.id('owner:rq_owen')) || '/' || company_share_bps || '/' || (booking_number like 'CC-%') || '/' || source
     from bookings where id = test.b('c1')), 'true/3500/true/web');
select test.eq('Q the request is logged as made by the renter, and customer service gets a task',
  (select string_agg(kind || ':' || actor_type, ',') from booking_events where booking_id = test.b('c1'))
  || ' ' || (select count(*) || ':' || min(queue) from tasks where booking_id = test.b('c1') and task_type = 'booking_request'), 'requested:renter 1:cs');
select test.lives('Q several requests for the same car and dates may coexist',
  $$select test.rq_new('c2', 'rq_ben', 'RQ1', '2029-03-05 10:00', '2029-03-08 10:00');
    select test.rq_new('c3', 'rq_cat', 'RQ1', '2029-03-06 10:00', '2029-03-09 10:00')$$);
select test.eq('Q a request never blocks the calendar',
  app.vehicle_is_available(test.id('vehicle:RQ1'), test.at('2029-03-05 10:00'), test.at('2029-03-08 10:00')), true);
select test.throws('Q a request over 30 days is refused',
  $$select test.rq_new('c31', 'rq_amy', 'RQ1', '2029-03-05 10:00', '2029-04-06 10:00')$$, '1 to 30 days');
select test.throws('Q the return must be after the pickup',
  $$select test.rq_new('c00', 'rq_amy', 'RQ1', '2029-03-05 10:00', '2029-03-05 10:00')$$, 'after the pickup');

-- ------------------------------------------------------------------ every step refused from "requested"
select test.throws('F requested cannot jump to confirmed',
  $$update bookings set status = 'confirmed' where id = test.b('c2')$$, 'cannot go from requested to confirmed');
select test.throws('F requested cannot jump to on rent',
  $$update bookings set status = 'on_rent' where id = test.b('c2')$$, 'cannot go from requested to on_rent');
select test.throws('F requested cannot jump to returned', $$update bookings set status = 'returned' where id = test.b('c2')$$, 'cannot go from requested to returned');
select test.throws('F requested cannot jump to closed', $$update bookings set status = 'closed' where id = test.b('c2')$$, 'cannot go from requested to closed');
select test.throws('F requested does not go to the old hold', $$update bookings set status = 'tentative' where id = test.b('c2')$$, 'cannot go from requested to tentative');
select test.throws('F requested is not cancelled (it is declined)', $$update bookings set status = 'cancelled' where id = test.b('c2')$$, 'cannot go from requested to cancelled');
select test.throws('F requested does not expire', $$update bookings set status = 'expired' where id = test.b('c2')$$, 'cannot go from requested to expired');
select test.throws('F a standard request does not go to signing and payment without an offer',
  $$update bookings set status = 'pending_payment' where id = test.b('c2')$$, 'Only an Owner Booking');
select test.throws('F a booking becomes offered only by sending an offer',
  $$update bookings set status = 'offered', current_offer_version = 1, offer_expires_at = now() + interval '1 day' where id = test.b('c2')$$, 'only by sending an offer');

-- ------------------------------------------------------------------ staff adjust the request
select test.throws('ADJ a renter cannot adjust the booking',
  $$select app.adjust_booking(test.b('c1'), test.id('rq_amy'), '{"deposit_cents": 0}')$$, 'Only staff');
select test.throws('ADJ an unknown change is refused',
  $$select app.adjust_booking(test.b('c1'), test.id('rq_cs'), '{"company_share_bps": 0}')$$, 'Unknown change');
select app.adjust_booking(test.b('c1'), test.id('rq_cs'), jsonb_build_object('return_at', test.at('2029-03-09 10:00')), 'customer wants one more day');
select test.eq('ADJ new dates: 4 days, repriced at the stored rates, mileage allowance and totals follow ($400 + HST)',
  (select billable_days || '/' || rental_charge_cents || '/' || km_allowance_total || '/' || total_due_at_booking_cents || '/' || (original_return_at = return_at)
     from bookings where id = test.b('c1')), '4/40000/800/45200/true');
select test.throws('ADJ only an Admin gives a discount',
  $$select app.adjust_booking(test.b('c1'), test.id('rq_cs'), '{"staff_discount_cents": 4000, "staff_discount_reason": "x"}')$$, 'Only an Admin');
select test.throws('ADJ a discount needs its reason',
  $$select app.adjust_booking(test.b('c1'), test.id('admin_abbas'), '{"staff_discount_cents": 4000}')$$, 'bookings_staff_discount_reason');
select app.adjust_booking(test.b('c1'), test.id('admin_abbas'), '{"staff_discount_cents": 4000, "staff_discount_reason": "returning customer"}');
select test.eq('ADJ an Admin''s discount comes off the rental charge as its own line: $400 - $40 = $360 + HST $46.80',
  (select subtotal_at_booking_cents || '/' || hst_at_booking_cents || '/' || total_due_at_booking_cents from bookings where id = test.b('c1'))
  || ' ' || (select amount_cents || '+' || hst_cents || ':' || revenue_class from booking_line_items where booking_id = test.b('c1') and charge_type = 'staff_discount' and voided_at is null),
  '36000/4680/40680 -4000+-520:owner_revenue');
select test.throws('ADJ the discounts cannot exceed the rental charge',
  $$select app.adjust_booking(test.b('c1'), test.id('admin_abbas'), '{"staff_discount_cents": 40001, "staff_discount_reason": "x"}')$$, 'bookings_discounts_within_rental');
select app.adjust_booking(test.b('c1'), test.id('rq_cs'), jsonb_build_object('vehicle_id', test.id('vehicle:RQ3')), 'swap: first car is in demand');
select test.eq('ADJ a swap to another car takes that car''s owner, Revenue Share, rates and Deposit (4 x $90 = $360, less $40, + HST)',
  (select (owner_id = test.id('owner:rq_pam')) || '/' || company_share_bps || '/' || daily_rate_cents || '/' || rental_charge_cents || '/' || deposit_cents
          || '/' || total_due_at_booking_cents from bookings where id = test.b('c1')), 'true/3000/9000/36000/50000/36160');
select app.adjust_booking(test.b('c1'), test.id('rq_cs'),
  '{"deposit_cents": 75000, "km_allowance_per_day": 250, "pickup_method": "delivered", "pickup_place": "12 Elm St", "notes": "called, prefers mornings"}');
select test.eq('ADJ Deposit, mileage allowance, delivery (fee from the rate card) and notes can be set',
  (select deposit_cents || '/' || km_allowance_total || '/' || pickup_method || '/' || notes || '/' || total_due_at_booking_cents from bookings where id = test.b('c1'))
  || ' ' || (select amount_cents from booking_line_items where booking_id = test.b('c1') and charge_type = 'delivery' and voided_at is null),
  '75000/1000/delivered/called, prefers mornings/44635 7500');
select app.adjust_booking(test.b('c1'), test.id('rq_cs'), '{"pickup_method": "collected", "pickup_place": null}');
select test.eq('ADJ taking delivery off voids its line (lines are never deleted) and the total follows',
  (select total_due_at_booking_cents from bookings where id = test.b('c1')) || '/'
  || (select count(*) filter (where voided_at is null) || '/' || count(*) from booking_line_items where booking_id = test.b('c1') and charge_type = 'delivery'), '36160/0/1');
select test.eq('ADJ every adjustment is in the booking''s history with who made it and what changed',
  (select count(*) || '/' || bool_and(actor_type = 'staff' and actor_user_id is not null and details is not null)
     from booking_events where booking_id = test.b('c1') and kind = 'adjusted'), '5/true');
select test.throws('ADJ a customer service assistant cannot move a request to another owner''s car by editing the row (the server does it)',
  format($$select test.login(%L); update bookings set vehicle_id = %L where id = %L$$, test.id('rq_cs'), test.id('vehicle:RQ1'), test.b('c1')), 'Only an Admin changes');
select test.logout();

-- ------------------------------------------------------------------ the offer and its versions
select test.throws('O a renter cannot send an offer',
  $$select app.send_offer(test.b('c1'), test.id('rq_amy'))$$, 'Only staff');
select test.eq('O staff send the offer: version 1', app.send_offer(test.b('c1'), test.id('rq_cs'), 'Hello Amy, here is your offer.'), 1);
select test.eq('O the booking is offered, and the offer records who sent it, the message, the terms and the price',
  (select b.status || '/' || b.current_offer_version || '/' || (o.sent_by = test.id('rq_cs')) || '/' || o.message || '/' || o.total_cents || '/' || o.renter_due_cents
          || '/' || o.deposit_cents || '/' || o.discount_cents || '/' || (o.vehicle_id = test.id('vehicle:RQ3')) || '/' || (o.terms ->> 'daily_rate_cents')
          || '/' || jsonb_array_length(o.line_items)
     from bookings b join booking_offers o on o.booking_id = b.id and o.version = b.current_offer_version where b.id = test.b('c1')),
  'offered/1/true/Hello Amy, here is your offer./36160/36160/75000/4000/true/9000/2');
select test.eq('O the offer expires 24 hours after it is sent',
  (select (o.expires_at - o.sent_at = interval '24 hours') || '/' || (b.offer_expires_at = o.expires_at) from bookings b join booking_offers o on o.booking_id = b.id where b.id = test.b('c1')),
  'true/true');
select test.eq('O an offer still does not block the calendar',
  app.vehicle_is_available(test.id('vehicle:RQ3'), test.at('2029-03-05 10:00'), test.at('2029-03-09 10:00')), true);
select test.throws('O the terms of an open offer stand still',
  $$update bookings set deposit_cents = 1 where id = test.b('c1')$$, 'withdraw it');
select test.throws('O and staff cannot adjust it without withdrawing it',
  $$select app.adjust_booking(test.b('c1'), test.id('rq_cs'), '{"deposit_cents": 1}')$$, 'withdraw it');
select test.throws('O an offer that was sent cannot be rewritten',
  $$update booking_offers set total_cents = 1 where booking_id = test.b('c1')$$, 'cannot be rewritten');
select test.throws('O offered cannot jump to confirmed', $$update bookings set status = 'confirmed' where id = test.b('c1')$$, 'cannot go from offered to confirmed');
select test.throws('O offered cannot jump to on rent', $$update bookings set status = 'on_rent' where id = test.b('c1')$$, 'cannot go from offered to on_rent');
select test.throws('O offered does not go to signing and payment before the renter approves',
  $$update bookings set status = 'pending_payment' where id = test.b('c1')$$, 'must approve the current offer');
select test.throws('O an approval cannot be typed in: the offer itself must be approved',
  $$update bookings set status = 'pending_payment', offer_approved_version = 1, offer_approved_at = now(), offer_approved_by = test.id('rq_amy') where id = test.b('c1')$$,
  'must approve the current offer');

-- staff change the offer: withdraw, adjust, send again
select test.throws('O a renter cannot withdraw staff''s offer', $$select app.withdraw_offer(test.b('c1'), test.id('rq_amy'))$$, 'Not permitted');
select app.withdraw_offer(test.b('c1'), test.id('rq_cs'), 'customer called: lower deposit agreed');
select test.eq('O withdrawn: back to requested, the offer marked withdrawn, the deadline cleared',
  (select b.status || '/' || o.status || '/' || coalesce(b.offer_expires_at::text, 'none') from bookings b join booking_offers o on o.booking_id = b.id and o.version = 1 where b.id = test.b('c1')),
  'requested/withdrawn/none');
select app.adjust_booking(test.b('c1'), test.id('rq_cs'), '{"deposit_cents": 50000}');
select test.eq('O sent again: version 2', app.send_offer(test.b('c1'), test.id('rq_cs'), 'Deposit lowered as agreed.'), 2);
select test.eq('O sending once more without withdrawing: version 3', app.send_offer(test.b('c1'), test.id('rq_cs'), 'Same terms, sent again.'), 3);
select test.eq('O every version is kept: 1 withdrawn, 2 superseded, 3 with the renter',
  (select string_agg(version || ':' || status || ':' || deposit_cents, ' ' order by version) from booking_offers where booking_id = test.b('c1')),
  '1:withdrawn:75000 2:superseded:50000 3:sent:50000');

-- approval
select test.throws('AP approving a stale version is refused',
  $$select app.approve_offer(test.b('c1'), 2, test.id('rq_amy'))$$, 'has been replaced: the current offer is version 3');
select test.throws('AP another renter cannot approve it',
  $$select app.approve_offer(test.b('c1'), 3, test.id('rq_ben'))$$, 'Only the renter of this booking');
select test.throws('AP nobody in particular cannot approve it',
  $$select app.approve_offer(test.b('c1'), 3, null)$$, 'Only the renter of this booking');
select test.throws('AP an offer past its expiry cannot be approved',
  $$select app.approve_offer(test.b('c1'), 3, test.id('rq_amy'), now() + interval '2 days')$$, 'expired');
select test.lives('AP the renter approves the current version', $$select app.approve_offer(test.b('c1'), 3, test.id('rq_amy'))$$);
select test.eq('AP approved: signing and payment in progress, with who, when and which version',
  (select b.status || '/' || b.offer_approved_version || '/' || (b.offer_approved_by = test.id('rq_amy')) || '/' || (b.offer_approved_at is not null)
          || '/' || o.status || '/' || (o.responded_by = test.id('rq_amy'))
     from bookings b join booking_offers o on o.booking_id = b.id and o.version = 3 where b.id = test.b('c1')), 'pending_payment/3/true/true/approved/true');
select test.throws('AP it cannot be approved twice', $$select app.approve_offer(test.b('c1'), 3, test.id('rq_amy'))$$, 'no open offer');
select test.throws('AP approved terms stand still too', $$update bookings set rental_charge_cents = 1 where id = test.b('c1')$$, 'withdraw it');
select test.throws('AP pending payment does not go back to offered', $$update bookings set status = 'offered' where id = test.b('c1')$$, 'cannot go from pending_payment to offered');
select test.eq('AP approval alone does not block the calendar',
  app.vehicle_is_available(test.id('vehicle:RQ3'), test.at('2029-03-05 10:00'), test.at('2029-03-09 10:00')), true);

-- signed and paid: confirmed, and only now on the calendar
select test.throws('CF not confirmed until the agreement is signed', $$update bookings set status = 'confirmed' where id = test.b('c1')$$, 'agreement is signed');
select test.rq_sign('c1');
select test.throws('CF not confirmed until payment succeeds', $$update bookings set status = 'confirmed' where id = test.b('c1')$$, 'payment succeeds');
select test.rq_pay('c1');
select test.throws('CF not confirmed without a saved card', $$update bookings set status = 'confirmed' where id = test.b('c1')$$, 'No saved card');
select test.rq_card('c1');
select test.lives('CF approved, signed and paid: confirmed', $$update bookings set status = 'confirmed' where id = test.b('c1')$$);
select test.eq('CF only now does the booking block the car',
  app.vehicle_is_available(test.id('vehicle:RQ3'), test.at('2029-03-05 10:00'), test.at('2029-03-09 10:00')), false);
select test.eq('CF the whole path is in the status history',
  (select string_agg(to_status, ' > ' order by id) from status_history where entity = 'booking' and entity_id = test.b('c1')),
  'requested > offered > requested > offered > requested > offered > pending_payment > confirmed');
select test.eq('CF and in the booking''s own history, with who did each step',
  (select string_agg(kind, ' ' order by id) from booking_events where booking_id = test.b('c1') and kind <> 'adjusted'),
  'requested offer_sent offer_withdrawn offer_sent offer_sent offer_approved');

-- ------------------------------------------------------------------ the renter asks for a change, or declines
select app.send_offer(test.b('c2'), test.id('rq_cs'));
select test.throws('CH a change request needs a note', $$select app.request_offer_change(test.b('c2'), test.id('rq_ben'), '  ')$$, 'Say what should change');
select test.throws('CH another renter cannot ask for a change', $$select app.request_offer_change(test.b('c2'), test.id('rq_amy'), 'x')$$, 'Not permitted');
select app.request_offer_change(test.b('c2'), test.id('rq_ben'), 'Can I return a day later?');
select test.eq('CH a change request sends it back to requested with the renter''s note, and customer service gets a task',
  (select b.status || '/' || b.request_note || '/' || o.status || '/' || o.response_note from bookings b join booking_offers o on o.booking_id = b.id where b.id = test.b('c2'))
  || ' ' || (select count(*) from tasks where booking_id = test.b('c2') and task_type = 'offer_change_requested'),
  'requested/Can I return a day later?/change_requested/Can I return a day later? 1');
select test.eq('CH logged as the renter''s act',
  (select actor_type || '/' || (actor_user_id = test.id('rq_ben')) from booking_events where booking_id = test.b('c2') and kind = 'change_requested'), 'renter/true');
select app.adjust_booking(test.b('c2'), test.id('rq_cs'), jsonb_build_object('return_at', test.at('2029-03-09 10:00')));
select app.send_offer(test.b('c2'), test.id('rq_cs'));
select app.approve_offer(test.b('c2'), 2, test.id('rq_ben'));
select test.lives('CH after approving, and before paying, the renter may still ask for a change',
  $$select app.request_offer_change(test.b('c2'), test.id('rq_ben'), 'Sorry, the first dates were right.')$$);
select test.eq('CH back to requested, and the earlier approval no longer stands',
  (select status || '/' || coalesce(offer_approved_version::text, 'none') || '/' || coalesce(offer_approved_by::text, 'none') from bookings where id = test.b('c2')),
  'requested/none/none');
select app.send_offer(test.b('c2'), test.id('rq_cs'));
select test.lives('CH the renter declines the offer', $$select app.decline_booking_request(test.b('c2'), test.id('rq_ben'), 'Found another car')$$);
select test.eq('CH declined, with the offer marked declined',
  (select b.status || '/' || o.status from bookings b join booking_offers o on o.booking_id = b.id and o.version = 3 where b.id = test.b('c2')), 'declined/declined');
select test.throws('CH a declined request does not come back', $$update bookings set status = 'requested' where id = test.b('c2')$$, 'cannot go from declined');
select test.throws('CH and cannot be offered again', $$select app.send_offer(test.b('c2'), test.id('rq_cs'))$$, 'an offer is sent on a request');
select test.lives('CH CarmaCars declines a request that was never offered',
  $$select app.decline_booking_request(test.b('c3'), test.id('rq_cs'), 'No car of this class on those dates')$$);
select test.eq('CH declined by staff', test.st('c3') || '/' || (select actor_type from booking_events where booking_id = test.b('c3') and kind = 'declined'), 'declined/staff');
-- paid but not yet signed: no way back without a refund
select test.rq_new('c4', 'rq_dan', 'RQ1', '2029-03-12 10:00', '2029-03-15 10:00');
select app.send_offer(test.b('c4'), test.id('rq_cs'));
select app.approve_offer(test.b('c4'), 1, test.id('rq_dan'));
select test.rq_pay('c4');
select test.throws('CH once paid, a change or a decline needs the payment refunded first',
  $$select app.request_offer_change(test.b('c4'), test.id('rq_dan'), 'another day')$$, 'already been paid');
select test.throws('CH the same for a withdrawal by staff', $$select app.withdraw_offer(test.b('c4'), test.id('rq_cs'))$$, 'already been paid');

-- ------------------------------------------------------------------ competing offers, and the overlap rule
-- RQ2, June 4 to 7, 2029 (Monday to Thursday). A will be confirmed.
select test.rq_new('A', 'rq_amy', 'RQ2', '2029-06-04 10:00', '2029-06-07 10:00');
select test.rq_new('X', 'rq_ben', 'RQ2', '2029-06-04 10:00', '2029-06-07 10:00');   -- offered
select test.rq_new('Y', 'rq_cat', 'RQ2', '2029-06-06 10:00', '2029-06-09 10:00');   -- approved and paid, overlapping in part
select test.rq_new('Z', 'rq_dan', 'RQ2', '2029-06-04 10:00', '2029-06-07 10:00');   -- still a request
select test.rq_new('W', 'rq_eve', 'RQ2', '2029-06-04 10:00', '2029-06-07 10:00');   -- offered, calendar switch off
select test.rq_new('V', 'rq_fay', 'RQ2', '2029-06-11 10:00', '2029-06-14 10:00');   -- offered, other dates
select test.rq_new('T', 'rq_gus', 'RQ2', '2029-06-05 10:00', '2029-06-08 10:00');   -- approved, calendar switch off
select app.send_offer(test.b('X'), test.id('rq_cs'));
select app.send_offer(test.b('Y'), test.id('rq_cs'));
select app.approve_offer(test.b('Y'), 1, test.id('rq_cat'));
select test.rq_pay('Y');
select app.set_blocks_calendar(test.b('W'), false, test.id('rq_cs'), 'dates not final');
select app.send_offer(test.b('W'), test.id('rq_cs'));
select app.send_offer(test.b('V'), test.id('rq_cs'));
select app.set_blocks_calendar(test.b('T'), false, test.id('rq_cs'), 'dates not final');
select app.send_offer(test.b('T'), test.id('rq_cs'));
select app.approve_offer(test.b('T'), 1, test.id('rq_gus'));
select test.rq_ready('A');
select test.eq('K before anything is confirmed: offered, offered, pending payment, requested, offered, offered, pending payment',
  test.st('A') || ' ' || test.st('X') || ' ' || test.st('Y') || ' ' || test.st('Z') || ' ' || test.st('W') || ' ' || test.st('V') || ' ' || test.st('T'),
  'pending_payment offered pending_payment requested offered offered pending_payment');
select test.lives('K the first booking is confirmed', $$update bookings set status = 'confirmed' where id = test.b('A')$$);
select test.eq('K confirming it sends every other offered or pending payment booking on those dates back to requested',
  test.st('X') || ' ' || test.st('Y'), 'requested requested');
select test.eq('K a plain request, an offer on other dates, and bookings whose calendar switch is off are left alone',
  test.st('Z') || ' ' || test.st('V') || ' ' || test.st('W') || ' ' || test.st('T'), 'requested offered offered pending_payment');
select test.eq('K their offers are withdrawn, saying why, and the approval is cleared',
  (select string_agg(o.status || ':' || (o.response_note like 'Booking % was confirmed on this vehicle for overlapping dates'), ' ' order by k.k)
     from test.rq_ids k join booking_offers o on o.booking_id = k.id where k.k in ('X', 'Y'))
  || ' ' || (select coalesce(offer_approved_version::text, 'none') || '/' || coalesce(offer_expires_at::text, 'none') from bookings where id = test.b('Y')),
  'withdrawn:true withdrawn:true none/none');
select test.eq('K each carries a system note in its history',
  (select count(*) || '/' || bool_and(actor_type = 'system' and actor_user_id is null and note like '%back with staff: offer another vehicle or other dates%')
     from booking_events where kind = 'pushed_back' and booking_id in (test.b('X'), test.b('Y'))), '2/true');
select test.eq('K and staff get a task to re-offer; urgent, saying so, where a payment was already taken',
  (select string_agg(k.k || ':' || t.queue || ':' || t.priority || ':' || (t.detail like '%PAYMENT WAS ALREADY TAKEN%'), ' ' order by k.k)
     from test.rq_ids k join tasks t on t.booking_id = k.id and t.task_type = 'reoffer_booking'), 'X:cs:high:false Y:cs:urgent:true');
select test.throws('K the same car cannot be offered again for those dates',
  $$select app.send_offer(test.b('X'), test.id('rq_cs'))$$, 'change the vehicle or the dates');
select app.adjust_booking(test.b('X'), test.id('rq_cs'), jsonb_build_object('vehicle_id', test.id('vehicle:RQ1')));
select test.eq('K staff re-offer another car: version 2', app.send_offer(test.b('X'), test.id('rq_cs'), 'The first car was taken; here is the same class.'), 2);

-- the calendar switch on, pending payment: confirming over a confirmed booking is refused
select test.throws('SW the switch does not change without a reason',
  $$select app.set_blocks_calendar(test.b('T'), true, test.id('rq_cs'), ' ')$$, 'needs who is changing it and a reason');
select test.throws('SW nor without a named member of staff',
  $$select app.set_blocks_calendar(test.b('T'), true, test.id('rq_gus'), 'I want it')$$, 'Only staff');
select test.throws('SW nor by editing the row without saying who and why',
  $$update bookings set blocks_calendar = true where id = test.b('T')$$, 'needs who is changing it and a reason');
select test.lives('SW staff turn the switch back on while the booking waits for payment',
  $$select app.set_blocks_calendar(test.b('T'), true, test.id('rq_cs'), 'adjuster confirmed the dates')$$);
select test.rq_sign('T'); select test.rq_pay('T'); select test.rq_card('T');
select test.throws('SW confirming a booking that overlaps a confirmed one is refused by the database',
  $$update bookings set status = 'confirmed' where id = test.b('T')$$, 'not available for these dates');
select test.eq('SW it stays unconfirmed', test.st('T'), 'pending_payment');
select app.set_blocks_calendar(test.b('T'), false, test.id('rq_fleet'), 'insurer booking: dates still moving');
select test.lives('SW with the switch off the same booking can be confirmed over the other one',
  $$update bookings set status = 'confirmed' where id = test.b('T')$$);
select test.eq('SW and it does not take the car from anyone: the confirmed, blocking booking is the only one that counts',
  app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-06-07 10:00'), test.at('2029-06-08 10:00')), true);
select test.throws('SW turning the switch on runs the same overlap check as confirmation',
  $$select app.set_blocks_calendar(test.b('T'), true, test.id('rq_cs'), 'dates are now final')$$, 'not available for these dates');
select test.eq('SW so the switch stays off', (select blocks_calendar from bookings where id = test.b('T')), false);
select test.eq('SW every flip is in the booking''s history with who and why',
  (select string_agg((details ->> 'blocks_calendar') || ':' || note || ':' || (actor_user_id is not null), ' | ' order by id)
     from booking_events where booking_id = test.b('T') and kind = 'calendar_switch'),
  'false:dates not final:true | true:adjuster confirmed the dates:true | false:insurer booking: dates still moving:true');
select test.eq('SW and in the audit log, before and after',
  (select count(*) from audit_log where entity_table = 'bookings' and entity_id = test.b('T')::text and action = 'UPDATE'
      and (before ->> 'blocks_calendar') is distinct from (after ->> 'blocks_calendar')), 3::bigint);
select test.eq('SW the row keeps the last who, why and when',
  (select (blocks_calendar_changed_by = test.id('rq_fleet')) || '/' || blocks_calendar_reason || '/' || (blocks_calendar_changed_at is not null)
     from bookings where id = test.b('T')), 'true/insurer booking: dates still moving/true');
select test.throws('SW the table itself refuses two blocking bookings at one moment (import path)',
  $$select test.mk_booking('RQDUP', 'RQ2', 'rq_dan', '2029-06-06 10:00', '2029-06-08 10:00', 'confirmed')$$, 'bookings_no_double_booking');

-- a switch turned on where the car is free takes the car, and competing offers go back
select test.rq_new('P', 'rq_gus', 'RQ2', '2029-06-18 10:00', '2029-06-21 10:00');
select test.rq_new('U', 'rq_dan', 'RQ2', '2029-06-19 10:00', '2029-06-22 10:00');
select app.set_blocks_calendar(test.b('P'), false, test.id('rq_cs'), 'dates not final');
select test.rq_ready('P');
update bookings set status = 'confirmed' where id = test.b('P');
select app.send_offer(test.b('U'), test.id('rq_cs'));
select test.eq('SW a confirmed booking with the switch off leaves other offers alone', test.st('P') || ' ' || test.st('U'), 'confirmed offered');
select test.lives('SW the switch is turned on where the car is free',
  $$select app.set_blocks_calendar(test.b('P'), true, test.id('rq_cs'), 'dates confirmed')$$);
select test.eq('SW and the overlapping offer goes back to requested, like at confirmation', test.st('U'), 'requested');
select test.throws('SW moving a blocking booking onto another one is refused',
  $$update bookings set pickup_at = pickup_at - interval '14 days', return_at = return_at - interval '14 days' where id = test.b('P')$$, 'not available for these dates');

-- ------------------------------------------------------------------ availability
select test.eq('AV false across a confirmed, blocking booking; true for the time right after it; true when that booking is ignored',
  app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-06-06 10:00'), test.at('2029-06-07 12:00')) || '/'
  || app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-06-07 10:00'), test.at('2029-06-08 10:00')) || '/'
  || app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-06-04 10:00'), test.at('2029-06-07 10:00'), test.b('A')), 'false/true/true');
select test.eq('AV an empty or backwards range is never available',
  app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-07-01 10:00'), test.at('2029-07-01 10:00')) || '/'
  || app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-07-02 10:00'), test.at('2029-07-01 10:00')), 'false/false');
insert into program_settings (effective_from, turnaround_buffer_minutes) values (app.today(), 120)
  on conflict (effective_from) do update set turnaround_buffer_minutes = 120;
select test.eq('AV with a 2-hour turnaround buffer set, the two hours after a return are not available, and the time after that is',
  app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-06-07 10:00'), test.at('2029-06-08 10:00')) || '/'
  || app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-06-07 12:00'), test.at('2029-06-08 10:00')), 'false/true');
update program_settings set turnaround_buffer_minutes = 0 where effective_from = app.today();
-- calendar blocks
select test.rq_new('k1', 'rq_eve', 'RQ1', '2029-07-02 10:00', '2029-07-05 10:00');
select test.rq_ready('k1');
insert into vehicle_calendar_blocks (id, vehicle_id, reason, starts_at, ends_at, note, created_by)
values (test.id('blk:RQ1'), test.id('vehicle:RQ1'), 'service', test.at('2029-07-04 08:00'), test.at('2029-07-06 17:00'), 'brakes', test.id('rq_fleet'));
select test.eq('AV a calendar block makes the car unavailable', app.vehicle_is_available(test.id('vehicle:RQ1'), test.at('2029-07-02 10:00'), test.at('2029-07-05 10:00')), false);
select test.throws('AV confirming over a calendar block is refused',
  $$update bookings set status = 'confirmed' where id = test.b('k1')$$, 'not available for these dates');
select test.rq_new('k2', 'rq_fay', 'RQ1', '2029-07-05 10:00', '2029-07-07 10:00');
select test.throws('AV an offer cannot be sent for dates a block covers', $$select app.send_offer(test.b('k2'), test.id('rq_cs'))$$, 'change the vehicle or the dates');
update vehicle_calendar_blocks set removed_at = now(), removed_by = test.id('rq_fleet'), removed_reason = 'service moved' where id = test.id('blk:RQ1');
select test.lives('AV once the block is removed the booking is confirmed', $$update bookings set status = 'confirmed' where id = test.b('k1')$$);
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at) values (test.id('vehicle:RQ1'), 'exit', test.at('2029-12-01 00:00'), null);
select test.eq('AV an open-ended block covers everything after it starts',
  app.vehicle_is_available(test.id('vehicle:RQ1'), test.at('2029-11-28 10:00'), test.at('2029-11-30 10:00')) || '/'
  || app.vehicle_is_available(test.id('vehicle:RQ1'), test.at('2030-05-01 10:00'), test.at('2030-05-02 10:00')), 'true/false');

-- ------------------------------------------------------------------ offers expire
select test.rq_new('x1', 'rq_fay', 'RQ4', '2029-08-06 10:00', '2029-08-09 10:00');
select test.rq_new('x2', 'rq_gus', 'RQ4', '2029-08-06 10:00', '2029-08-09 10:00');
select test.rq_new('x3', 'rq_eve', 'RQ4', '2029-08-13 10:00', '2029-08-16 10:00');
insert into test.rq_times values ('t0', now());
select app.send_offer(test.b('x1'), test.id('rq_cs'), 'Answer within the hour please', (select at + interval '1 hour' from test.rq_times where k = 't0'));
select app.send_offer(test.b('x3'), test.id('rq_cs'));
select test.eq('X an offer can carry its own expiry',
  (select expires_at - (select at from test.rq_times where k = 't0') from booking_offers where booking_id = test.b('x1')), interval '1 hour');
select test.throws('X an expiry in the past is refused',
  $$select app.send_offer(test.b('x2'), test.id('rq_cs'), null, now() - interval '1 minute')$$, 'expire in the future');
delete from job_runs where job_name = 'offers-expire';
select test.eq('X the job does nothing while no offer is due, and records nothing',
  app.job_offers_expire((select at from test.rq_times where k = 't0')) || '/' || (select count(*) from job_runs where job_name = 'offers-expire'), 'not_due/0');
select test.eq('X ninety minutes later the offer is due: the job runs',
  app.job_offers_expire((select at + interval '90 minutes' from test.rq_times where k = 't0')), 'succeeded');
select test.eq('X the expired offer goes back to requested, the offer is marked expired, the deadline cleared',
  (select b.status || '/' || o.status || '/' || coalesce(b.offer_expires_at::text, 'none') from bookings b join booking_offers o on o.booking_id = b.id where b.id = test.b('x1')),
  'requested/expired/none');
select test.eq('X with a system note and a follow-up task for customer service',
  (select actor_type || ':' || (note like 'Offer version 1 was not answered by%') from booking_events where booking_id = test.b('x1') and kind = 'offer_expired')
  || ' ' || (select count(*) || ':' || min(queue) from tasks where booking_id = test.b('x1') and task_type = 'offer_expired'), 'system:true 1:cs');
select test.eq('X an offer that is not yet due is left alone (24 hours)', test.st('x3'), 'offered');
select test.eq('X the run is recorded with what it did',
  (select count(*) || '/' || min(status) || '/' || min(summary ->> 'offers_expired') from job_runs where job_name = 'offers-expire'), '1/succeeded/1');
select test.eq('X run again for the same instant, the job finds nothing to do',
  app.job_offers_expire((select at + interval '90 minutes' from test.rq_times where k = 't0')), 'not_due');
select test.eq('X and the function itself is safe to repeat: nothing more expires',
  app.expire_offers((select at + interval '90 minutes' from test.rq_times where k = 't0')), 0);
select test.eq('X and nothing was written twice: one note, one task, one change of status',
  (select count(*) from booking_events where booking_id = test.b('x1') and kind = 'offer_expired') || '/'
  || (select count(*) from tasks where booking_id = test.b('x1') and task_type = 'offer_expired') || '/'
  || (select count(*) from status_history where entity = 'booking' and entity_id = test.b('x1')), '1/1/3');
select app.send_offer(test.b('x2'), test.id('rq_cs'), null, (select at + interval '80 minutes' from test.rq_times where k = 't0'));
select test.eq('X a second call inside a minute that already ran waits for the next run',
  app.job_offers_expire((select at + interval '90 minutes' from test.rq_times where k = 't0')), 'already_run');
select test.eq('X so that offer is still open', test.st('x2'), 'offered');
select test.eq('X and the next run expires it', app.job_offers_expire((select at + interval '95 minutes' from test.rq_times where k = 't0')), 'succeeded');
select test.eq('X back to requested', test.st('x2'), 'requested');
select test.lives('X staff send an expired offer again with one call: version 2',
  $$select app.send_offer(test.b('x1'), test.id('rq_cs'), 'Still interested?')$$);
update program_settings set offer_expiry_hours = 48 where effective_from = (select effective_from from app.settings());
select app.send_offer(test.b('x2'), test.id('rq_cs'));
select test.eq('X the standard expiry is a program setting',
  (select o.expires_at - o.sent_at from booking_offers o where o.booking_id = test.b('x2') and o.status = 'sent'), interval '48 hours');
update program_settings set offer_expiry_hours = 24 where effective_from = (select effective_from from app.settings());

-- ------------------------------------------------------------------ Owner Bookings: an agreement, nothing to pay
select test.throws('OB an Owner Booking is made by the vehicle''s own Owner',
  $$select test.rq_new('ob0', 'rq_pam', 'RQ4', '2029-09-03 10:00', '2029-09-06 10:00', 'owner')$$, 'own Owner');
select test.rq_new('ob1', 'rq_owen', 'RQ4', '2029-09-03 10:00', '2029-09-06 10:00', 'owner');
select test.eq('OB an Owner Booking is a request with nothing to pay: no rental charge, Deposit, split or charge line',
  (select status || '/' || rental_charge_cents || '/' || deposit_cents || '/' || company_share_bps || '/' || total_due_at_booking_cents || '/' || rate_applied
          || '/' || (select count(*) from booking_line_items where booking_id = b.id) from bookings b where id = test.b('ob1')), 'requested/0/0/0/0/none/0');
select test.throws('OB it still cannot skip the agreement', $$update bookings set status = 'confirmed' where id = test.b('ob1')$$, 'cannot go from requested to confirmed');
select test.lives('OB it goes to signing without an offer', $$update bookings set status = 'pending_payment' where id = test.b('ob1')$$);
select test.throws('OB not confirmed until the agreement is signed', $$update bookings set status = 'confirmed' where id = test.b('ob1')$$, 'agreement is signed');
select test.rq_sign('ob1');
select test.lives('OB signed: confirmed, with no payment and no card', $$update bookings set status = 'confirmed' where id = test.b('ob1')$$);
select test.eq('OB and it blocks the car like any confirmed booking',
  (select count(*) from payments where booking_id = test.b('ob1')) || '/'
  || app.vehicle_is_available(test.id('vehicle:RQ4'), test.at('2029-09-04 10:00'), test.at('2029-09-05 10:00')), '0/false');
-- created by staff for the Owner
insert into test.rq_ids values ('ob2', app.request_booking(test.id('renter:rq_owen'), test.id('vehicle:RQ4'), test.at('2029-09-10 10:00'),
  test.at('2029-09-12 10:00'), 'owner', 'Owner phoned', 'staff', test.id('rq_cs')));
select test.eq('OB a staff-created Owner Booking is logged as made by staff',
  (select b.status || '/' || b.source || '/' || e.actor_type from bookings b join booking_events e on e.booking_id = b.id and e.kind = 'requested' where b.id = test.b('ob2')),
  'requested/staff/staff');
select test.throws('OB an Owner Booking over a confirmed booking is refused like any other',
  $$select app.adjust_booking(test.b('ob2'), test.id('rq_cs'), jsonb_build_object('pickup_at', test.at('2029-09-05 10:00'), 'return_at', test.at('2029-09-07 10:00')));
    update bookings set status = 'pending_payment' where id = test.b('ob2');
    select test.rq_sign('ob2');
    update bookings set status = 'confirmed' where id = test.b('ob2')$$, 'not available for these dates');

-- ------------------------------------------------------------------ billing an insurer
insert into insurers (id, name, billing_contact_name, billing_email, billing_phone, billing_address, notes)
values (test.id('ins:one'), 'Test Insurer One', 'Claims Payables', 'payables@insurer-one.example.test', '416-555-0111', '1 Test Way, Toronto', 'net 30');
select test.throws('I an insurer''s name is kept once', $$insert into insurers (name) values ('test insurer one')$$, 'insurers_name_key');
-- 10 days from Monday October 1, 2029: the weekly rate applies, 10 x $560 / 7 = $800
select test.rq_new('i1', 'rq_gus', 'RQ5', '2029-10-01 10:00', '2029-10-11 10:00');
select test.throws('I a bill cannot go to an insurer without naming it',
  $$select app.adjust_booking(test.b('i1'), test.id('rq_cs'), '{"bill_to": "insurer"}')$$, 'bookings_bill_to_insurer');
select app.adjust_booking(test.b('i1'), test.id('rq_cs'), jsonb_build_object('bill_to', 'insurer', 'insurer_id', test.id('ins:one'),
  'insurer_claim_number', 'CLM-1001', 'insurer_adjuster_name', 'Alex Adjuster', 'insurer_adjuster_email', 'alex@insurer-one.example.test',
  'insurer_adjuster_phone', '416-555-0112', 'insurer_authorized_daily_rate_cents', 6000, 'insurer_authorized_days', 7));
select test.eq('I the insurer pays what it authorized (7 days x $60 = $420 + HST $54.60); the rest of the $800 + HST falls to the renter',
  (select rental_charge_cents || '/' || total_due_at_booking_cents || '/' || insurer_share_cents || '/' || insurer_hst_cents || '/' || renter_due_at_booking_cents
     from bookings where id = test.b('i1')), '80000/90400/42000/5460/42940');
select app.adjust_booking(test.b('i1'), test.id('rq_cs'), '{"pickup_method": "delivered"}');
select test.eq('I billed to the insurer: it also pays the fees charged at booking ($75 delivery + HST), so the renter owes the same',
  (select total_due_at_booking_cents || '/' || insurer_share_cents || '/' || insurer_hst_cents || '/' || renter_due_at_booking_cents
     from bookings where id = test.b('i1')), '98875/49500/6435/42940');
select app.adjust_booking(test.b('i1'), test.id('rq_cs'), '{"bill_to": "split"}');
select test.eq('I split: the insurer pays the authorized rental only; the fees are the renter''s as well',
  (select insurer_share_cents || '/' || insurer_hst_cents || '/' || renter_due_at_booking_cents from bookings where id = test.b('i1')), '42000/5460/51415');
select app.adjust_booking(test.b('i1'), test.id('rq_cs'), '{"insurer_authorized_until": "2029-10-04"}');
select test.eq('I "authorized until October 4" covers the 4 rental days that start by then, even with 7 days authorized: 4 x $60',
  (select s.covered_days || '/' || s.rental_share_cents || '/' || s.hst_cents || '/' || b.renter_due_at_booking_cents
     from bookings b, app.booking_insurer_share(b.id) s where b.id = test.b('i1')), '4/24000/3120/71755');
select app.adjust_booking(test.b('i1'), test.id('rq_cs'),
  '{"bill_to": "insurer", "insurer_authorized_until": null, "insurer_authorized_daily_rate_cents": null, "insurer_authorized_days": 5}');
select test.eq('I days authorized with no daily rate: the insurer pays that share of the rental (5 of 10 days = $400) and the fees',
  (select insurer_share_cents || '/' || insurer_hst_cents || '/' || renter_due_at_booking_cents from bookings where id = test.b('i1')), '47500/6175/45200');
select app.adjust_booking(test.b('i1'), test.id('rq_cs'), '{"insurer_authorized_days": null, "dates_provisional": true}');
select test.eq('I nothing limited: the whole bill at booking is the insurer''s and the renter owes nothing now',
  (select insurer_share_cents || '/' || insurer_hst_cents || '/' || renter_due_at_booking_cents || '/' || dates_provisional from bookings where id = test.b('i1')),
  '87500/11375/0/true');
select test.rq_new('i0', 'rq_fay', 'RQ5', '2029-10-29 10:00', '2029-11-01 10:00');
select app.adjust_booking(test.b('i0'), test.id('rq_cs'), jsonb_build_object('bill_to', 'insurer', 'insurer_id', test.id('ins:one')));
select app.adjust_booking(test.b('i0'), test.id('rq_cs'), '{"bill_to": "renter"}');
select test.eq('I a bill moved back to the renter carries no insurer part',
  (select bill_to || '/' || insurer_share_cents || '/' || insurer_hst_cents || '/' || renter_due_at_booking_cents from bookings where id = test.b('i0')), 'renter/0/0/33900');
select test.throws('I an insurer is invoiced only for a confirmed booking', $$select app.draft_insurer_invoice(test.b('i1'))$$, 'invoiced for a confirmed booking');
select test.throws('I a booking billed to the renter has no insurer invoice', $$select app.draft_insurer_invoice(test.b('A'))$$, 'not billed to an insurer');
select app.set_blocks_calendar(test.b('i1'), false, test.id('rq_cs'), 'replacement rental: dates not yet right');
select app.send_offer(test.b('i1'), test.id('rq_cs'), 'Your insurer is billed directly.');
select test.eq('I the offer shows who pays what',
  (select o.version || '/' || o.total_cents || '/' || o.insurer_share_cents || '/' || o.renter_due_cents || '/' || (o.terms -> 'insurer' ->> 'name') || '/' || (o.terms ->> 'bill_to')
     from booking_offers o where o.booking_id = test.b('i1')), '1/98875/98875/0/Test Insurer One/insurer');
select test.lives('I staff record the approval the driver gave them', $$select app.approve_offer(test.b('i1'), 1, test.id('rq_cs'))$$);
select test.eq('I logged as approved by staff', (select actor_type from booking_events where booking_id = test.b('i1') and kind = 'offer_approved'), 'staff');
select test.rq_sign('i1');
select test.throws('I the driver is still a renter: a saved card is needed', $$update bookings set status = 'confirmed' where id = test.b('i1')$$, 'No saved card');
select test.rq_card('i1');
select test.lives('I signed, card saved, nothing due from the renter: confirmed with no card payment',
  $$update bookings set status = 'confirmed' where id = test.b('i1')$$);
select test.eq('I confirmed, yet the car is not blocked: the switch is off', test.st('i1') || '/' ||
  app.vehicle_is_available(test.id('vehicle:RQ5'), test.at('2029-10-01 10:00'), test.at('2029-10-11 10:00')), 'confirmed/true');
select test.rq_new('i2', 'rq_amy', 'RQ5', '2029-10-03 10:00', '2029-10-06 10:00');
select test.rq_ready('i2');
select test.lives('I so another booking can be confirmed on the same car and dates', $$update bookings set status = 'confirmed' where id = test.b('i2')$$);
-- the dates become known
select test.throws('I on a confirmed booking with provisional dates only the dates and the authorization can be corrected',
  $$select app.adjust_booking(test.b('i1'), test.id('rq_cs'), '{"deposit_cents": 0}')$$, 'only the dates');
select app.adjust_booking(test.b('i1'), test.id('rq_cs'), jsonb_build_object('pickup_at', test.at('2029-10-15 10:00'), 'return_at', test.at('2029-10-22 10:00'),
  'dates_provisional', false), 'adjuster confirmed the repair dates');
select test.eq('I the dates are corrected and made final, and the price follows (7 days = $560 + $75 delivery + HST)',
  (select billable_days || '/' || rental_charge_cents || '/' || total_due_at_booking_cents || '/' || insurer_share_cents || '/' || insurer_hst_cents || '/' || dates_provisional
     from bookings where id = test.b('i1')), '7/56000/71755/63500/8255/false');
select test.throws('I once the dates are final the booking is no longer adjusted this way',
  $$select app.adjust_booking(test.b('i1'), test.id('rq_cs'), jsonb_build_object('return_at', test.at('2029-10-23 10:00')))$$, 'can no longer be adjusted');
select test.lives('I and the switch is turned on, now that the dates are right and free',
  $$select app.set_blocks_calendar(test.b('i1'), true, test.id('rq_cs'), 'dates final')$$);
-- the invoice
select app.compute_booking_split(test.b('i1'));
select test.eq('I until the insurer pays, the Owner Revenue of the rental is not collected', (select uncollected_cents from booking_splits where booking_id = test.b('i1')), 56000::bigint);
insert into test.rq_ids values ('inv1', app.draft_insurer_invoice(test.b('i1'), test.id('rq_fin')));
select test.eq('I the invoice is drafted from the booking''s lines for the insurer''s share: $635.00 + HST $82.55',
  (select (invoice_number like 'INS-%') || '/' || status || '/' || amount_cents || '/' || hst_cents || '/' || total_cents || '/' || balance_cents || '/' || claim_number
          || '/' || period_start || '/' || period_end || '/' || (insurer_id = test.id('ins:one')) || '/' || jsonb_array_length(lines)
     from insurer_invoices where id = test.b('inv1')), 'true/draft/63500/8255/71755/71755/CLM-1001/2029-10-15/2029-10-22/true/2');
select test.eq('I drafting again refreshes the same draft',
  (app.draft_insurer_invoice(test.b('i1')) = test.b('inv1')) || '/' || (select count(*) from insurer_invoices where booking_id = test.b('i1')), 'true/1');
select test.throws('I a payment is not recorded on a draft', $$select app.record_insurer_payment(test.b('inv1'), 1000)$$, 'recorded on a sent invoice');
select test.throws('I an invoice is not sent without the time it was sent', $$update insurer_invoices set status = 'sent' where id = test.b('inv1')$$, 'check');
update insurer_invoices set status = 'sent', sent_at = now(), sent_by = test.id('rq_fin') where id = test.b('inv1');
select test.eq('I a part payment', app.record_insurer_payment(test.b('inv1'), 30000, test.id('rq_fin'), 'bank_transfer', now(), 'EFT 1'), 'part_paid');
select test.throws('I more than the balance is refused', $$select app.record_insurer_payment(test.b('inv1'), 41756)$$, 'no more than the balance');
select test.throws('I a paid amount cannot be typed in beyond the total', $$update insurer_invoices set paid_cents = 99999999 where id = test.b('inv1')$$, 'check');
select test.eq('I the balance', app.record_insurer_payment(test.b('inv1'), 41755, test.id('rq_fin'), 'e_transfer', now(), 'EFT 2'), 'paid');
select test.eq('I paid in full: amounts, time and reference are on the invoice',
  (select status || '/' || paid_cents || '/' || balance_cents || '/' || (paid_at is not null) || '/' || last_payment_reference from insurer_invoices where id = test.b('inv1')),
  'paid/71755/0/true/EFT 2');
select test.eq('I each receipt is a payment on the booking, outside the card processor',
  (select string_agg(amount_cents || ':' || method || ':' || status || ':' || purpose, ' ' order by amount_cents) from payments where booking_id = test.b('i1')),
  '30000:bank_transfer:succeeded:other 41755:e_transfer:succeeded:other');
select app.compute_booking_split(test.b('i1'));
select test.eq('I and the rental now counts as collected for the Owner''s statement',
  (select uncollected_cents || '/' || rental_charge_cents || '/' || collected_cents from booking_splits where booking_id = test.b('i1')), '0/56000/71755');
select test.throws('I nothing is left to invoice', $$select app.draft_insurer_invoice(test.b('i1'))$$, 'Nothing is left to invoice');
select test.throws('I a write-off needs who and why', $$update insurer_invoices set status = 'written_off' where id = test.b('inv1')$$, 'check');

-- ------------------------------------------------------------------ promo codes
insert into promo_codes (id, code, percent_bps, max_uses, source) values (test.id('promo:10'), 'RQ10', 1000, 1, 'followup_7d');
insert into promo_codes (id, code, percent_bps, max_uses, source) values (test.id('promo:multi'), 'RQMULTI', 2000, 5, 'followup_30d');
insert into promo_codes (id, code, amount_cents, renter_id, source) values (test.id('promo:fix'), 'RQFIX', 2500, test.id('renter:rq_amy'), 'manual');
insert into promo_codes (id, code, amount_cents, once_per_renter) values (test.id('promo:big'), 'RQBIG', 9999900, false);
insert into promo_codes (code, percent_bps, valid_from, valid_until) values ('RQOLD', 1000, now() - interval '30 days', now() - interval '1 day');
insert into promo_codes (code, percent_bps, valid_from) values ('RQSOON', 1000, now() + interval '7 days');
insert into promo_codes (code, percent_bps, is_active) values ('RQOFF', 1000, false);
select test.throws('PR a code is a percentage or a fixed amount, not both', $$insert into promo_codes (code, percent_bps, amount_cents) values ('RQBOTH', 1000, 500)$$, 'check');
select test.throws('PR and not neither', $$insert into promo_codes (code) values ('RQNONE')$$, 'check');
select test.throws('PR a code is unique', $$insert into promo_codes (code, percent_bps) values ('RQ10', 500)$$, 'promo_codes_code_key');
select test.throws('PR a code is stored in capitals', $$insert into promo_codes (code, percent_bps) values ('rq-lower', 500)$$, 'check');
select test.rq_new('p1', 'rq_amy', 'RQ6', '2029-11-05 10:00', '2029-11-08 10:00');
select test.rq_new('p2', 'rq_ben', 'RQ6', '2029-11-05 10:00', '2029-11-08 10:00');
select test.rq_new('p3', 'rq_amy', 'RQ6', '2029-11-12 10:00', '2029-11-15 10:00');
select test.rq_new('p4', 'rq_amy', 'RQ6', '2029-11-19 10:00', '2029-11-22 10:00');
select test.eq('PR validation: unknown, expired, not yet valid, switched off, issued to someone else, and valid',
  app.promo_code_problem('NOPE', test.id('renter:rq_amy')) || ' | ' || app.promo_code_problem('RQOLD', test.id('renter:rq_amy')) || ' | '
  || app.promo_code_problem('RQSOON', test.id('renter:rq_amy')) || ' | ' || app.promo_code_problem('RQOFF', test.id('renter:rq_amy')) || ' | '
  || app.promo_code_problem('RQFIX', test.id('renter:rq_ben')) || ' | ' || coalesce(app.promo_code_problem(' rq10 ', test.id('renter:rq_amy'), test.b('p1')), 'valid'),
  'This code is not known | This code has expired | This code is not valid yet | This code is no longer active | This code was issued to another customer | valid');
select test.throws('PR an expired code is refused on a request', $$select app.apply_promo_code(test.b('p1'), 'RQOLD', test.id('rq_amy'))$$, 'has expired');
select test.eq('PR a valid code: 10% off the $300 rental charge', app.apply_promo_code(test.b('p1'), ' rq10 ', test.id('rq_amy')), 3000::bigint);
select test.eq('PR the discount is a line on the rental charge, and the totals follow ($270 + HST $35.10)',
  (select promo_discount_cents || '/' || (promo_code_id = test.id('promo:10')) || '/' || subtotal_at_booking_cents || '/' || total_due_at_booking_cents from bookings where id = test.b('p1'))
  || ' ' || (select amount_cents || '+' || hst_cents || ':' || revenue_class from booking_line_items where booking_id = test.b('p1') and charge_type = 'promo_discount' and voided_at is null),
  '3000/true/27000/30510 -3000+-390:owner_revenue');
select test.eq('PR the use is tracked against the booking',
  (select status || '/' || discount_cents || '/' || (renter_id = test.id('renter:rq_amy')) || '/' || (applied_by = test.id('rq_amy')) from promo_redemptions where booking_id = test.b('p1')),
  'applied/3000/true/true');
select test.throws('PR used up: the one use is taken', $$select app.apply_promo_code(test.b('p2'), 'RQ10', test.id('rq_ben'))$$, 'used up');
select test.throws('PR wrong renter: the code was issued to someone else', $$select app.apply_promo_code(test.b('p2'), 'RQFIX', test.id('rq_ben'))$$, 'issued to another customer');
select test.throws('PR another renter cannot put a code on this booking', $$select app.apply_promo_code(test.b('p2'), 'RQMULTI', test.id('rq_amy'))$$, 'Not permitted');
select test.eq('PR a second renter uses a code with uses left: 20% of $300', app.apply_promo_code(test.b('p2'), 'RQMULTI', test.id('rq_ben')), 6000::bigint);
select test.eq('PR and so does the first renter, on another booking', app.apply_promo_code(test.b('p3'), 'RQMULTI', test.id('rq_amy')), 6000::bigint);
select test.throws('PR but only once each', $$select app.apply_promo_code(test.b('p4'), 'RQMULTI', test.id('rq_amy'))$$, 'already been used by this customer');
select test.eq('PR a fixed amount, for the renter it was issued to: $25 off', app.apply_promo_code(test.b('p4'), 'RQFIX', test.id('rq_amy')), 2500::bigint);
select test.eq('PR a fixed amount never takes more than the rental charge', app.apply_promo_code(test.b('p4'), 'RQBIG', test.id('rq_cs')), 30000::bigint);
select test.eq('PR a booking carries one code at a time: the new one replaces the old, under one use record',
  (select total_due_at_booking_cents || '/' || (promo_code_id = test.id('promo:big')) from bookings where id = test.b('p4'))
  || '/' || (select count(*) from promo_redemptions where booking_id = test.b('p4')), '0/true/1');
select app.adjust_booking(test.b('p2'), test.id('rq_cs'), jsonb_build_object('return_at', test.at('2029-11-09 10:00')));
select test.eq('PR a percentage follows the rental charge when staff change the booking (20% of $400)',
  (select b.promo_discount_cents || '/' || r.discount_cents || '/' || b.total_due_at_booking_cents from bookings b join promo_redemptions r on r.booking_id = b.id where b.id = test.b('p2')),
  '8000/8000/36160');
-- with other discounts: the code applies to what is left of the rental charge
select test.rq_new('p7', 'rq_eve', 'RQ6', '2029-11-26 10:00', '2029-11-29 10:00');
select app.adjust_booking(test.b('p7'), test.id('admin_abbas'), '{"staff_discount_cents": 5000, "staff_discount_reason": "goodwill"}');
select test.eq('PR after a staff discount of $50: 20% of $250', app.apply_promo_code(test.b('p7'), 'RQMULTI', test.id('rq_eve')), 5000::bigint);
select test.rq_new('p8', 'rq_fay', 'RQ6', '2029-12-03 10:00', '2029-12-06 10:00', 'non_refundable');
select test.eq('PR on a non-refundable booking (10% off already): 20% of $270', app.apply_promo_code(test.b('p8'), 'RQMULTI', test.id('rq_fay')), 5400::bigint);
select test.eq('PR both discounts stand: $300 - $30 - $54 = $216 + HST',
  (select discount_cents || '/' || promo_discount_cents || '/' || total_due_at_booking_cents from bookings where id = test.b('p8')), '3000/5400/24408');
select test.throws('PR an Owner Booking has nothing to discount', $$select app.apply_promo_code(test.b('ob2'), 'RQBIG', test.id('rq_cs'))$$, 'no rental charge to discount');
-- on an open offer: a new version at once, so the renter approves the price they see
select test.rq_new('p6', 'rq_dan', 'RQ6', '2029-12-10 10:00', '2029-12-13 10:00');
select app.send_offer(test.b('p6'), test.id('rq_cs'));
select test.eq('PR a code put on an open offer', app.apply_promo_code(test.b('p6'), 'RQMULTI', test.id('rq_dan')), 6000::bigint);
select test.eq('PR issues the next version with the new price and the same expiry; the earlier one is superseded',
  (select b.status || '/' || b.current_offer_version || '/' || (b.offer_expires_at = o1.expires_at) || '/' || o1.status || ':' || o1.total_cents
          || '/' || o2.status || ':' || o2.total_cents || ':' || coalesce(o2.sent_by::text, 'system') || ':' || (o2.terms ->> 'promo_code')
     from bookings b join booking_offers o1 on o1.booking_id = b.id and o1.version = 1 join booking_offers o2 on o2.booking_id = b.id and o2.version = 2
    where b.id = test.b('p6')), 'offered/2/true/superseded:33900/sent:27120:system:RQMULTI');
select test.throws('PR approving the price from before the code is refused', $$select app.approve_offer(test.b('p6'), 1, test.id('rq_dan'))$$, 'has been replaced');
select app.approve_offer(test.b('p6'), 2, test.id('rq_dan'));
select test.throws('PR a code does not go on a booking already approved', $$select app.apply_promo_code(test.b('p6'), 'RQBIG', test.id('rq_dan'))$$, 'goes on a request or an open offer');
select test.rq_ready('p6');
update bookings set status = 'confirmed' where id = test.b('p6');
select test.eq('PR once the booking is confirmed the code is redeemed', (select status || '/' || (redeemed_at is not null) from promo_redemptions where booking_id = test.b('p6')), 'redeemed/true');
select app.compute_booking_split(test.b('p6'));
select test.eq('PR the discount comes off before the split, like the existing discount: Owner Revenue $240, CarmaCars 35% = $84, Owner $156',
  (select rental_charge_cents || '/' || owner_revenue_cents || '/' || company_share_cents || '/' || owner_payout_cents from booking_splits where booking_id = test.b('p6')),
  '24000/24000/8400/15600');
-- released when the booking does not go ahead, or the code is taken off
select app.decline_booking_request(test.b('p1'), test.id('rq_amy'), 'changed plans');
select test.eq('PR a declined request gives its use back, so the code works for the next customer',
  (select status from promo_redemptions where booking_id = test.b('p1')) || '/' || coalesce(app.promo_code_problem('RQ10', test.id('renter:rq_ben')), 'valid'), 'released/valid');
select test.throws('PR a renter cannot remove a code', $$select app.remove_promo_code(test.b('p7'), test.id('rq_eve'))$$, 'Only staff');
select app.remove_promo_code(test.b('p7'), test.id('rq_cs'));
select test.eq('PR staff take a code off a request: no discount, use released, price back ($250 + HST)',
  (select b.promo_discount_cents || '/' || coalesce(b.promo_code_id::text, 'none') || '/' || b.total_due_at_booking_cents || '/' || r.status
     from bookings b join promo_redemptions r on r.booking_id = b.id where b.id = test.b('p7')), '0/none/28250/released');

-- ------------------------------------------------------------------ reviews
select test.mk_booking('RQREV1', 'RQ6', 'rq_amy', '2026-08-03 10:00', '2026-08-05 10:00', 'closed');
select test.mk_booking('RQREV2', 'RQ6', 'rq_ben', '2026-08-10 10:00', '2026-08-12 10:00', 'closed');
select test.mk_booking('RQREV3', 'RQ6', 'rq_cat', '2026-08-17 10:00', '2026-08-19 10:00', 'returned');
select test.mk_booking('RQREVO', 'RQ6', 'rq_owen', '2026-08-24 10:00', '2026-08-26 10:00', 'closed', null, 'owner');
select test.throws('RV only the renter of the booking may review it',
  $$select app.submit_review(test.id('booking:RQREV1'), test.id('rq_ben'), 5, 'Great', 'Clean car')$$, 'Only the renter of a booking');
select test.throws('RV not before the booking is closed',
  $$select app.submit_review(test.id('booking:RQREV3'), test.id('rq_cat'), 5)$$, 'only once the booking is closed');
select test.throws('RV not on a request either', $$select app.submit_review(test.b('p3'), test.id('rq_amy'), 5)$$, 'only once the booking is closed');
select test.throws('RV an Owner Booking is not reviewed', $$select app.submit_review(test.id('booking:RQREVO'), test.id('rq_owen'), 5)$$, 'Owner Booking is not reviewed');
select test.throws('RV the rating is 1 to 5', $$select app.submit_review(test.id('booking:RQREV1'), test.id('rq_amy'), 6)$$, 'check');
select test.throws('RV and not 0', $$select app.submit_review(test.id('booking:RQREV1'), test.id('rq_amy'), 0)$$, 'check');
insert into test.rq_ids values ('rev1', app.submit_review(test.id('booking:RQREV1'), test.id('rq_amy'), 5, 'Great car', 'Spotless and on time.'));
select test.eq('RV a review waits as pending, tied to the booking, the renter and the vehicle',
  (select status || '/' || rating || '/' || (renter_id = test.id('renter:rq_amy')) || '/' || (vehicle_id = test.id('vehicle:RQ6')) || '/' || coalesce(published_at::text, 'not published')
     from reviews where id = test.b('rev1')), 'pending/5/true/true/not published');
select test.throws('RV one review per booking', $$select app.submit_review(test.id('booking:RQREV1'), test.id('rq_amy'), 4)$$, 'already been reviewed');
select test.throws('RV the table itself refuses a review written for someone else''s booking',
  format($$insert into reviews (booking_id, renter_id, vehicle_id, rating) values (%L, %L, %L, 1)$$,
         test.id('booking:RQREV2'), test.id('renter:rq_amy'), test.id('vehicle:RQ6')), 'Only the renter of a booking');
select test.throws('RV and a second row for the same booking',
  format($$insert into reviews (booking_id, renter_id, vehicle_id, rating) values (%L, %L, %L, 1)$$,
         test.id('booking:RQREV1'), test.id('renter:rq_amy'), test.id('vehicle:RQ6')), 'reviews_booking_id_key');
insert into test.rq_ids values ('rev2', app.submit_review(test.id('booking:RQREV2'), test.id('rq_ben'), 2, 'Late', 'The car was late.'));
select test.eq('RV nothing is public until it is published', (select count(*) from app.public_reviews(test.id('vehicle:RQ6'))), 0::bigint);
update reviews set status = 'published', moderated_by = test.id('rq_cs'), staff_reply = 'Thank you, Amy.', staff_reply_by = test.id('rq_cs') where id = test.b('rev1');
select test.eq('RV published: shown with the first name and the month only, and the reply',
  (select rating || '/' || title || '/' || reviewer_first_name || '/' || review_month || '/' || staff_reply || '/' || vehicle_label
     from app.public_reviews(test.id('vehicle:RQ6'))), '5/Great car/Amy/' || app.month_start(app.today()) || '/Thank you, Amy./2023 Mercedes-Benz C 300 RQ6');
select test.eq('RV the public list carries no surname, contact, renter or booking column',
  (select pg_get_function_result('app.public_reviews(uuid, integer, integer)'::regprocedure) ~ '(legal_name|email|mobile|renter_id|booking_id|created_at)'), false);
select test.eq('RV publishing stamps the time, and the reply its own',
  (select (published_at is not null) || '/' || (staff_reply_at is not null) from reviews where id = test.b('rev1')), 'true/true');
select test.eq('RV listed for every vehicle too, and only published ones', (select count(*) from app.public_reviews()), 1::bigint);
update reviews set status = 'hidden' where id = test.b('rev1');
select test.eq('RV a hidden review is public no more', (select count(*) from app.public_reviews()), 0::bigint);
update reviews set status = 'published' where id = test.b('rev1');
select test.throws('RV a review stays with its booking',
  format($$update reviews set booking_id = %L where id = %L$$, test.id('booking:RQREV3'), test.b('rev1')), 'stays with its booking');

-- ------------------------------------------------------------------ the public calendar of one car
insert into vehicle_listings (vehicle_id, slug, headline, status, published_at) values (test.id('vehicle:RQ2'), 'c300-rq2', 'Mercedes C 300', 'published', now());
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, note, created_by)
values (test.id('vehicle:RQ2'), 'service', test.at('2029-06-07 10:00'), test.at('2029-06-08 10:00'), 'oil change, shop: Main St', test.id('rq_fleet'));
insert into vehicle_calendar_blocks (vehicle_id, reason, starts_at, ends_at, removed_at, removed_by)
values (test.id('vehicle:RQ2'), 'repair', test.at('2029-06-25 10:00'), test.at('2029-06-26 10:00'), now(), test.id('rq_fleet'));
select test.eq('PC June 2029: the confirmed booking and the service block right after it are one stretch; then the second blocking booking. Nothing else.',
  (select string_agg(to_char(unavailable_from at time zone 'America/Toronto', 'MM-DD HH24:MI') || '>' || to_char(unavailable_to at time zone 'America/Toronto', 'MM-DD HH24:MI')
                     || ' ' || first_date || '..' || last_date, ' | ' order by unavailable_from)
     from app.public_vehicle_calendar(test.id('vehicle:RQ2'), date '2029-06-01', date '2029-06-30')),
  '06-04 10:00>06-08 10:00 2029-06-04..2029-06-08 | 06-18 10:00>06-21 10:00 2029-06-18..2029-06-21');
select test.eq('PC requests, offers, a removed block and a confirmed booking with the switch off are not on it',
  (select count(*) from app.public_vehicle_calendar(test.id('vehicle:RQ2'), date '2029-06-09', date '2029-06-17'))
  + (select count(*) from app.public_vehicle_calendar(test.id('vehicle:RQ2'), date '2029-06-22', date '2029-06-30')), 0::bigint);
select test.eq('PC a range is cut to the days asked for (Toronto days)',
  (select to_char(unavailable_from at time zone 'America/Toronto', 'MM-DD HH24:MI') || '>' || to_char(unavailable_to at time zone 'America/Toronto', 'MM-DD HH24:MI')
     from app.public_vehicle_calendar(test.id('vehicle:RQ2'), date '2029-06-05', date '2029-06-06')), '06-05 00:00>06-07 00:00');
select test.eq('PC it returns times and dates only: no booking, person or reason',
  pg_get_function_result('app.public_vehicle_calendar(uuid, date, date)'::regprocedure),
  'TABLE(unavailable_from timestamp with time zone, unavailable_to timestamp with time zone, first_date date, last_date date)');
select test.eq('PC a car that is not on the public listing has no public calendar',
  (select count(*) from app.public_vehicle_calendar(test.id('vehicle:RQ3'), date '2029-03-01', date '2029-03-31')), 0::bigint);
select test.throws('PC at most 366 days at a time', $$select * from app.public_vehicle_calendar(test.id('vehicle:RQ2'), date '2029-01-01', date '2030-06-30')$$, '1 to 366 days');

-- ------------------------------------------------------------------ the master calendar (as an admin)
select test.login(test.id('admin_abbas'));
select test.eq('MC every booking on the car in every status, flagged blocking or not, requests and offers shown as pending',
  (select string_agg(k.k || '=' || m.status || ':' || m.calendar_state || ':' || m.blocks_calendar || ':' || m.is_blocking, ' ' order by k.k)
     from app.master_calendar(test.at('2029-06-01 00:00'), test.at('2029-06-17 00:00')) m join test.rq_ids k on k.id = m.booking_id
    where m.vehicle_id = test.id('vehicle:RQ2')),
  'A=confirmed:booked:true:true T=confirmed:booked:false:false V=offered:pending:true:false W=offered:pending:false:false Y=requested:pending:true:false Z=requested:pending:true:false');
select test.eq('MC with what a calendar needs: vehicle label, plate, renter name, booking number, bill to, start and end',
  (select vehicle_label || '/' || (plate is not null) || '/' || renter_name || '/' || (booking_number like 'CC-%') || '/' || bill_to || '/' || booking_type
          || '/' || (starts_at = test.at('2029-06-04 10:00')) || '/' || (ends_at = test.at('2029-06-07 10:00')) || '/' || vehicle_status
     from app.master_calendar(test.at('2029-06-01 00:00'), test.at('2029-06-17 00:00')) where booking_id = test.b('A')),
  '2023 Mercedes-Benz C 300 RQ2/true/Amy Anderson/true/renter/standard/true/true/available');
select test.eq('MC calendar blocks, with their reason and note; a removed block is gone',
  (select string_agg(entry_type || ':' || status || ':' || block_reason || ':' || note || ':' || is_blocking, ' ')
     from app.master_calendar(test.at('2029-06-01 00:00'), test.at('2029-06-30 00:00')) where vehicle_id = test.id('vehicle:RQ2') and entry_type = 'block'),
  'block:blocked:service:oil change, shop: Main St:true');
select test.eq('MC an insurer booking shows who is billed, and an Owner Booking shows as one',
  (select bill_to || ':' || insurer_name || ':' || dates_provisional from app.master_calendar(test.at('2029-10-01 00:00'), test.at('2029-10-31 00:00')) where booking_id = test.b('i1'))
  || ' ' || (select booking_type || ':' || calendar_state from app.master_calendar(test.at('2029-09-01 00:00'), test.at('2029-09-05 00:00')) where booking_id = test.b('ob1')),
  'insurer:Test Insurer One:false owner:booked');
select test.eq('MC only entries that touch the range',
  (select count(*) from app.master_calendar(test.at('2029-06-10 00:00'), test.at('2029-06-17 00:00')) where vehicle_id = test.id('vehicle:RQ2') and entry_type is not null), 1::bigint);
select test.eq('MC every vehicle in the program is on it, with or without entries',
  (select count(distinct vehicle_id) || '/' || (count(*) filter (where entry_type is null) > 0)
     from app.master_calendar(test.at('2029-06-01 00:00'), test.at('2029-06-17 00:00'))),
  (select count(*) from vehicles where status not in ('declined', 'exited')) || '/true');
select test.logout();

-- ------------------------------------------------------------------ row-level security: RENTER
select test.login(test.id('rq_amy'));
select test.eq('renter: sees her own requests and bookings through the renter view, with the offer and who pays',
  (select string_agg(k.k || ':' || r.status || ':' || coalesce(r.current_offer_version::text, '-') || ':' || r.renter_due_at_booking_cents, ' ' order by k.k)
     from renter_bookings r join test.rq_ids k on k.id = r.id where k.k in ('A', 'c1', 'p3')), 'A:confirmed:1:33900 c1:confirmed:3:36160 p3:requested:-:27120');
select test.eq('renter: none of another renter''s requests', test.visible(format('select 1 from renter_bookings where id in (%L, %L)', test.b('c2'), test.b('X'))), 0::bigint);
select test.eq('renter: reads every version of her own offers', (select string_agg(version::text, ',' order by version) from booking_offers where booking_id = test.b('c1')), '1,2,3');
select test.eq('renter: and no one else''s offers', (select count(*) from booking_offers o where not app.is_my_booking(o.booking_id)), 0::bigint);
select test.eq('renter: not the staff history of a booking', test.visible('select * from booking_events'), 0::bigint);
select test.eq('renter: her own promo code use only', (select bool_and(renter_id = app.my_renter_id()) || '/' || (count(*) > 0) from promo_redemptions), 'true/true');
select test.eq('renter: her own review only', (select string_agg(title, ',') from reviews), 'Great car');
select test.eq('renter: no insurers, no insurer invoices, no list of promo codes',
  test.visible('select * from insurers') + test.visible('select * from insurer_invoices') + test.visible('select * from promo_codes'), 0::bigint);
select test.eq('renter: the master calendar shows her nothing',
  test.visible('select * from calendar_entries') + test.visible($$select * from app.master_calendar(now(), now() + interval '5 years')$$), 0::bigint);
select test.eq('renter: may ask whether a car is free, read a public calendar and the published reviews',
  app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-06-04 10:00'), test.at('2029-06-05 10:00')) || '/'
  || (select count(*) from app.public_vehicle_calendar(test.id('vehicle:RQ2'), date '2029-06-01', date '2029-06-30')) || '/' || (select count(*) from app.public_reviews()), 'false/2/1');
select test.throws('renter: cannot approve an offer from the browser (the server does it for her)',
  $$select app.approve_offer(test.b('p3'), 1, test.id('rq_amy'))$$, 'permission denied');
select test.throws('renter: cannot make a request, send an offer or use a code from the browser',
  $$select app.send_offer(test.b('p3'), test.id('rq_amy'))$$, 'permission denied');
select test.throws('renter: cannot call the request function', $$select test.rq_new('hack', 'rq_amy', 'RQ1', '2030-01-07 10:00', '2030-01-08 10:00')$$, 'permission denied');
select test.throws('renter: cannot apply a promo code herself', $$select app.apply_promo_code(test.b('p3'), 'RQBIG', test.id('rq_amy'))$$, 'permission denied');
select test.throws('renter: cannot write a review straight into the table',
  format($$insert into reviews (booking_id, renter_id, vehicle_id, rating) values (%L, %L, %L, 5)$$, test.id('booking:RQREV1'), test.id('renter:rq_amy'), test.id('vehicle:RQ6')), 'permission denied');
select test.eq('renter: cannot publish or edit her review', test.affected($$update reviews set status = 'published', rating = 1$$), 0::bigint);
select test.throws('renter: cannot write an offer', format($$update booking_offers set status = 'approved' where booking_id = %L$$, test.b('p3')), 'permission denied');
select test.eq('renter: cannot change her booking', test.affected(format($$update bookings set blocks_calendar = false, blocks_calendar_reason = 'x' where id = %L$$, test.b('A'))), 0::bigint);
select test.logout();

-- ------------------------------------------------------------------ OWNER
select test.login(test.id('rq_owen'));
select test.eq('owner: none of the new tables',
  test.visible('select * from booking_offers') + test.visible('select * from booking_events') + test.visible('select * from insurers')
  + test.visible('select * from insurer_invoices') + test.visible('select * from promo_codes') + test.visible('select * from promo_redemptions')
  + test.visible('select * from reviews'), 0::bigint);
select test.eq('owner: the calendar of his own vehicles only', (select bool_and(app.owns_vehicle(vehicle_id)) || '/' || (count(*) > 10) from calendar_entries), 'true/true');
select test.eq('owner: never another owner''s vehicle', test.visible(format('select 1 from calendar_entries where vehicle_id = %L', test.id('vehicle:RQ3'))), 0::bigint);
select test.eq('owner: on his calendar a renter is a first name; no insurer, no internal note',
  (select renter_name || '/' || coalesce(insurer_name, '-') || '/' || coalesce(note, '-') || '/' || status || '/' || is_blocking from calendar_entries where booking_id = test.b('A'))
  || ' ' || (select renter_name || '/' || bill_to || '/' || coalesce(insurer_name, '-') from calendar_entries where booking_id = test.b('i1')), 'Amy/-/-/confirmed/true Rq/insurer/-');
select test.eq('owner: the calendar has no contact, licence or renter id column',
  (select count(*) from information_schema.columns where table_name = 'calendar_entries' and column_name ~ '(email|mobile|phone|address|licence|birth|renter_id|card)'), 0::bigint);
select test.eq('owner: sees a block on his car, without the staff note',
  (select block_reason || '/' || coalesce(note, '-') from calendar_entries where entry_type = 'block' and vehicle_id = test.id('vehicle:RQ2')), 'service/-');
select test.eq('owner: the master calendar function gives him the same, his vehicles only',
  (select bool_and(app.owns_vehicle(vehicle_id)) || '/' || count(distinct vehicle_id) from app.master_calendar(test.at('2029-01-01 00:00'), test.at('2030-01-01 00:00'))), 'true/5');
select test.eq('owner: his bookings view lists confirmed bookings, and no request or offer',
  (select count(*) filter (where id = test.b('A')) || '/' || count(*) filter (where status::text in ('requested', 'offered')) from owner_bookings), '1/0');
select test.eq('owner: the rental charge he sees is after every discount ($300 less the $60 promo code)',
  (select rental_charge_cents from owner_bookings where id = test.b('p6')), 24000::bigint);
select test.throws('owner: cannot flip the calendar switch', $$select app.set_blocks_calendar(test.b('A'), false, test.id('rq_owen'), 'mine')$$, 'permission denied');
select test.eq('owner: cannot edit or remove a calendar block', test.affected('update vehicle_calendar_blocks set removed_at = now()'), 0::bigint);
select test.logout();
select test.login(test.id('rq_pam'));
select test.eq('owner 2: sees her own car on the calendar and nothing of the first owner''s',
  (select string_agg(distinct fleet_number, ',') from calendar_entries), 'F-RQ3');
select test.logout();

-- ------------------------------------------------------------------ VA: customer service
select test.login(test.id('rq_cs'));
select test.eq('cs: reads requests, offers and their history',
  test.visible(format('select 1 from bookings where id = %L', test.b('Z'))) || '/' || (test.visible('select * from booking_offers') > 10) || '/' || (test.visible('select * from booking_events') > 10), '1/true/true');
select test.eq('cs: the full master calendar, with names', (select renter_name || '/' || insurer_name from calendar_entries where booking_id = test.b('i1')), 'Rq Gus/Test Insurer One');
select test.eq('cs: reads promo codes and their use, and reviews; not insurer invoices',
  (test.visible('select * from promo_codes') > 0) || '/' || (test.visible('select * from promo_redemptions') > 0) || '/' || test.visible('select * from reviews') || '/' || test.visible('select * from insurer_invoices'),
  'true/true/2/0');
select test.throws('cs: cannot create a promo code (a discount is an Admin''s decision)', $$insert into promo_codes (code, percent_bps) values ('RQCS', 5000)$$, 'row-level security');
select test.eq('cs: cannot change one', test.affected($$update promo_codes set percent_bps = 9000$$), 0::bigint);
select test.lives('cs: keeps the list of insurers', $$insert into insurers (name, billing_email) values ('Test Insurer Two', 'ap@insurer-two.example.test')$$);
select test.eq('cs: and edits it', test.affected($$update insurers set notes = 'net 45' where name = 'Test Insurer Two'$$), 1::bigint);
select test.throws('cs: cannot write an offer by hand (offers are sent by the server)',
  format($$insert into booking_offers (booking_id, version, expires_at, vehicle_id, pickup_at, return_at, billable_days, rental_charge_cents, discount_cents, deposit_cents,
             subtotal_cents, hst_cents, total_cents, renter_due_cents, terms, line_items)
           select id, 99, now() + interval '1 day', vehicle_id, pickup_at, return_at, 1, 0, 0, 0, 0, 0, 0, 0, '{}', '[]' from bookings where id = %L$$, test.b('Z')), 'permission denied');
select test.throws('cs: cannot add to the history by hand', format($$insert into booking_events (booking_id, kind, actor_type) values (%L, 'requested', 'staff')$$, test.b('Z')), 'permission denied');
select test.throws('cs: cannot mark a booking offered without an offer',
  format($$update bookings set status = 'offered' where id = %L$$, test.b('Z')), 'only by sending an offer');
select test.throws('cs: cannot give a discount by editing the booking',
  format($$update bookings set staff_discount_cents = 1000, staff_discount_reason = 'x' where id = %L$$, test.b('Z')), 'Only an Admin changes staff_discount_cents');
select test.throws('cs: cannot type in a renter''s approval',
  format($$update bookings set offer_approved_version = 1, offer_approved_at = now(), offer_approved_by = %L where id = %L$$, test.id('rq_cs'), test.b('x3')), 'Only an Admin changes offer_approved_version');
select test.throws('cs: cannot pull an offer back by editing the status (the server withdraws it, with a note)',
  format($$update bookings set status = 'requested' where id = %L$$, test.b('x3')), 'Only an Admin changes offer_expires_at');
select test.eq('cs: may mark an offered booking declined', test.affected(format($$update bookings set status = 'declined' where id = %L$$, test.b('x3'))), 1::bigint);
select test.eq('cs: and its open offer is closed with it', (select status from booking_offers where booking_id = test.b('x3')), 'declined');
select test.throws('cs: flipping the calendar switch in the portal needs a reason',
  format($$update bookings set blocks_calendar = false where id = %L$$, test.b('A')), 'needs who is changing it and a reason');
select test.eq('cs: with a reason, the switch flips and the flip is signed with her own name, whatever she types',
  test.affected(format($$update bookings set blocks_calendar = false, blocks_calendar_reason = 'customer may move dates', blocks_calendar_changed_by = %L where id = %L$$,
                       test.id('admin_abbas'), test.b('A'))), 1::bigint);
select test.eq('cs: who and why are on the history', (select (actor_user_id = test.id('rq_cs')) || '/' || note from booking_events where booking_id = test.b('A') and kind = 'calendar_switch'),
  'true/customer may move dates');
select test.throws('cs: cannot turn it back on over what took the dates meanwhile (the service block)',
  format($$update bookings set blocks_calendar = true, blocks_calendar_reason = 'back on', pickup_at = pickup_at + interval '1 day', return_at = return_at + interval '1 day' where id = %L$$, test.b('A')),
  'not available for these dates');
select test.eq('cs: turns it back on where the car is free',
  test.affected(format($$update bookings set blocks_calendar = true, blocks_calendar_reason = 'dates stay' where id = %L$$, test.b('A'))), 1::bigint);
select test.eq('cs: moderates a review: publishes it and replies',
  test.affected(format($$update reviews set status = 'published', moderated_by = %L, staff_reply = 'Sorry about that, Ben.', staff_reply_by = %L where id = %L$$,
                       test.id('rq_cs'), test.id('rq_cs'), test.b('rev2'))), 1::bigint);
select test.throws('cs: but never rewrites the renter''s words or rating', format($$update reviews set rating = 5 where id = %L$$, test.b('rev2')), 'Only an Admin changes rating');
select test.throws('cs: cannot delete a review', 'delete from reviews', 'permission denied');
select test.lives('cs: may enter a request (the old hold is no longer the way in)',
  format($$insert into bookings (booking_number, vehicle_id, renter_id, pickup_at, return_at, original_return_at, billable_days, daily_rate_cents, weekend_rate_cents,
             weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, rental_charge_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents)
           values ('RQ-CS-1', %L, %L, %L, %L, %L, 1, 10000, 12000, 56000, 180000, 'daily', 1, 10000, 200, 200, 35, 100000)$$,
         test.id('vehicle:RQ1'), test.id('renter:rq_cat'), test.at('2030-02-04 10:00'), test.at('2030-02-05 10:00'), test.at('2030-02-05 10:00')));
select test.eq('cs: and it starts as a request', (select status::text from bookings where booking_number = 'RQ-CS-1'), 'requested');
select test.throws('cs: cannot call the server''s functions', $$select app.send_offer(test.b('Z'), test.id('rq_cs'))$$, 'permission denied');
select test.logout();

-- ------------------------------------------------------------------ VA: fleet (calendar blocks)
select test.login(test.id('rq_fleet'));
select test.lives('fleet: creates a calendar block',
  format($$insert into vehicle_calendar_blocks (id, vehicle_id, reason, starts_at, ends_at, note, created_by) values (%L, %L, 'repair', %L, %L, 'windshield', %L)$$,
         test.id('blk:fleet'), test.id('vehicle:RQ4'), test.at('2030-03-04 08:00'), test.at('2030-03-05 17:00'), test.id('rq_fleet')));
select test.eq('fleet: edits it', test.affected(format($$update vehicle_calendar_blocks set ends_at = %L, note = 'windshield and wipers' where id = %L$$, test.at('2030-03-06 17:00'), test.id('blk:fleet'))), 1::bigint);
select test.eq('fleet: the block takes the car', app.vehicle_is_available(test.id('vehicle:RQ4'), test.at('2030-03-06 10:00'), test.at('2030-03-07 10:00')), false);
select test.throws('fleet: removing a block is signed with their own name',
  format($$update vehicle_calendar_blocks set removed_at = now(), removed_by = %L where id = %L$$, test.id('admin_abbas'), test.id('blk:fleet')), 'your own approval');
select test.eq('fleet: removes it (marked removed; nothing is deleted from a browser)',
  test.affected(format($$update vehicle_calendar_blocks set removed_at = now(), removed_by = %L, removed_reason = 'done early' where id = %L$$, test.id('rq_fleet'), test.id('blk:fleet'))), 1::bigint);
select test.eq('fleet: and the car is free again', app.vehicle_is_available(test.id('vehicle:RQ4'), test.at('2030-03-06 10:00'), test.at('2030-03-07 10:00')), true);
select test.throws('fleet: still cannot delete one', 'delete from vehicle_calendar_blocks', 'permission denied');
select test.eq('fleet: sees the master calendar and the offers; no promo codes, reviews or insurer invoices',
  (test.visible('select * from calendar_entries') > 10) || '/' || (test.visible('select * from booking_offers') > 10) || '/'
  || test.visible('select * from promo_codes') + test.visible('select * from promo_redemptions') + test.visible('select * from reviews') + test.visible('select * from insurer_invoices'), 'true/true/0');
select test.eq('fleet: reads the insurers, cannot change them', test.visible('select * from insurers') || '/' || test.affected($$update insurers set notes = 'x'$$), '2/0');
select test.logout();

-- ------------------------------------------------------------------ VA: finance (insurer invoices)
select test.login(test.id('rq_fin'));
select test.eq('finance: reads insurer invoices and insurers', test.visible('select * from insurer_invoices') || '/' || test.visible('select * from insurers'), '1/2');
select test.eq('finance: a paid invoice is closed to them', test.affected($$update insurer_invoices set notes = 'x'$$), 0::bigint);
select test.logout();
-- a second invoice to work on: i2 becomes a split booking by import, for the finance checks only
insert into insurer_invoices (id, booking_id, insurer_id, period_start, period_end, amount_cents, hst_cents)
values (test.id('insinv:2'), test.b('i2'), test.id('ins:one'), date '2029-10-03', date '2029-10-06', 10000, 1300);
select test.login(test.id('rq_fin'));
select test.eq('finance: corrects a draft', test.affected(format($$update insurer_invoices set notes = 'attention: claims payables' where id = %L$$, test.id('insinv:2'))), 1::bigint);
select test.throws('finance: cannot sign the sending in someone else''s name',
  format($$update insurer_invoices set status = 'sent', sent_at = now(), sent_by = %L where id = %L$$, test.id('admin_abbas'), test.id('insinv:2')), 'your own approval');
select test.eq('finance: marks it sent', test.affected(format($$update insurer_invoices set status = 'sent', sent_at = now(), sent_by = %L where id = %L$$, test.id('rq_fin'), test.id('insinv:2'))), 1::bigint);
select test.throws('finance: cannot type in a payment (the server records it)',
  format($$update insurer_invoices set paid_cents = 100 where id = %L$$, test.id('insinv:2')), 'Only an Admin changes paid_cents');
select test.throws('finance: cannot mark it paid', format($$update insurer_invoices set status = 'paid' where id = %L$$, test.id('insinv:2')), 'row-level security');
select test.throws('finance: cannot write it off', format($$update insurer_invoices set status = 'written_off', written_off_reason = 'x' where id = %L$$, test.id('insinv:2')), null);
select test.throws('finance: cannot create an invoice by hand',
  format($$insert into insurer_invoices (booking_id, insurer_id, period_start, period_end, amount_cents) values (%L, %L, current_date, current_date, 1)$$, test.b('i2'), test.id('ins:one')), 'permission denied');
select test.throws('finance: cannot call the money functions', format($$select app.record_insurer_payment(%L, 100)$$, test.id('insinv:2')), 'permission denied');
select test.eq('finance: reads promo codes and their use; no reviews',
  (test.visible('select * from promo_codes') > 0) || '/' || (test.visible('select * from promo_redemptions') > 0) || '/' || test.visible('select * from reviews'), 'true/true/0');
select test.logout();

-- ------------------------------------------------------------------ VA: sales
select test.login(test.id('rq_sales'));
select test.eq('sales: sees requests and offers (the new quotes), nothing confirmed',
  (test.visible($$select * from bookings where status::text in ('requested', 'offered')$$) > 0) || '/' || test.visible($$select * from bookings where status in ('confirmed', 'on_rent', 'returned', 'closed')$$), 'true/0');
select test.eq('sales: the calendar to quote from, with first names only and no insurer or note',
  (select renter_name || '/' || coalesce(insurer_name, '-') || '/' || coalesce(note, '-') from calendar_entries where booking_id = test.b('i1')), 'Rq/-/-');
select test.eq('sales: reads offers, promo codes and insurers; no reviews, no insurer invoices',
  (test.visible('select * from booking_offers') > 0) || '/' || (test.visible('select * from promo_codes') > 0) || '/' || test.visible('select * from insurers') || '/'
  || test.visible('select * from reviews') + test.visible('select * from insurer_invoices'), 'true/true/2/0');
select test.throws('sales: cannot add an insurer', $$insert into insurers (name) values ('Test Insurer Three')$$, 'row-level security');
select test.eq('sales: may note on a request', test.affected(format($$update bookings set notes = 'asked about child seat' where id = %L$$, test.b('Z'))), 1::bigint);
select test.eq('sales: cannot touch a confirmed booking', test.affected(format($$update bookings set notes = 'x' where id = %L$$, test.b('A'))), 0::bigint);
select test.logout();

-- ------------------------------------------------------------------ FIELD STAFF
select test.login(test.id('rq_field'));
select test.eq('field: none of the new tables, no calendar',
  test.visible('select * from booking_offers') + test.visible('select * from booking_events') + test.visible('select * from insurers')
  + test.visible('select * from insurer_invoices') + test.visible('select * from promo_codes') + test.visible('select * from promo_redemptions')
  + test.visible('select * from reviews') + test.visible('select * from calendar_entries')
  + test.visible($$select * from app.master_calendar(now(), now() + interval '5 years')$$), 0::bigint);
select test.logout();

-- ------------------------------------------------------------------ ANONYMOUS (the public site)
set role anon;
select test.eq('anon: reads the public calendar of a listed car',
  (select count(*) from app.public_vehicle_calendar(test.id('vehicle:RQ2'), date '2029-06-01', date '2029-06-30')), 2::bigint);
select test.eq('anon: reads the published reviews, first names only',
  (select string_agg(reviewer_first_name || ':' || rating, ',' order by rating) from app.public_reviews(test.id('vehicle:RQ6'))), 'Ben:2,Amy:5');
select test.eq('anon: may ask whether a car is free',
  app.vehicle_is_available(test.id('vehicle:RQ2'), test.at('2029-06-18 10:00'), test.at('2029-06-19 10:00')), false);
select test.eq('anon: no privilege at all on any new table or on the master calendar',
  test.visible('select * from booking_offers') + test.visible('select * from booking_events') + test.visible('select * from insurers')
  + test.visible('select * from insurer_invoices') + test.visible('select * from promo_codes') + test.visible('select * from promo_redemptions')
  + test.visible('select * from reviews') + test.visible('select * from calendar_entries')
  + test.visible($$select * from app.master_calendar(now(), now() + interval '1 day')$$), -9::bigint);
select test.throws('anon: cannot make a request straight into the database (the server does, after its checks)',
  $$select app.request_booking(test.id('renter:rq_amy'), test.id('vehicle:RQ1'), now() + interval '900 days', now() + interval '901 days')$$, 'permission denied');
select test.throws('anon: cannot test a promo code against the database', $$select app.promo_code_problem('RQ10', test.id('renter:rq_amy'))$$, 'permission denied');
reset role;
select test.eq('anon: still reads exactly one table or view; the calendar and reviews are functions',
  (select string_agg(table_name || ':' || privilege_type, ',') from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon'),
  'public_vehicle_listings:SELECT');

-- ------------------------------------------------------------------ ADMIN
select test.login(test.id('admin_abbas'));
select test.eq('admin: reads every new table',
  (test.visible('select * from booking_offers') > 10) and (test.visible('select * from booking_events') > 50) and test.visible('select * from insurers') = 2
  and test.visible('select * from insurer_invoices') = 2 and test.visible('select * from promo_codes') = 7 and (test.visible('select * from promo_redemptions') > 5)
  and test.visible('select * from reviews') = 2, true);
select test.lives('admin: creates a promo code', $$insert into promo_codes (code, percent_bps, source, created_by) values ('RQADMIN', 1500, 'manual', app.uid())$$);
select test.lives('admin: writes off an insurer invoice, with who and why',
  format($$update insurer_invoices set status = 'written_off', written_off_at = now(), written_off_by = %L, written_off_reason = 'insurer insolvent' where id = %L$$,
         test.id('admin_abbas'), test.id('insinv:2')));
select test.throws('admin: the history of a booking cannot be edited, even by an admin', $$update booking_events set note = 'x'$$, 'permission denied');
select test.throws('admin: nor can a sent offer be written from the browser', $$update booking_offers set message = 'x'$$, 'permission denied');
select test.throws('admin: still cannot delete', 'delete from promo_codes', 'permission denied');
select test.logout();
select test.throws('H the history is append-only for the server too', $$update booking_events set note = 'x'$$, 'append-only');
select test.throws('H and cannot be deleted', $$delete from booking_events$$, 'append-only');

-- ------------------------------------------------------------------ the rest of the life of a booking is unchanged
select test.rq_new('L', 'rq_cat', 'RQ6', '2030-04-01 10:00', '2030-04-04 10:00');
select test.rq_ready('L');
update bookings set status = 'confirmed' where id = test.b('L');
insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band, identity_method, identity_verified_on)
values (test.b('L'), test.id('driver:rq_cat'), 'renter', 'Rq Cat', date '1990-05-05', 39, '26_plus', 'staff_review', date '2030-03-30');
insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (test.b('L'), 2, 'confirmed', 'Bank', '4242', now());
update bookings set coverage_option = 2, coverage_confirmed_at = now() where id = test.b('L');
insert into deposits (booking_id, amount_cents, method, status, taken_at, hold_expires_at) values (test.b('L'), 100000, 'card_hold', 'held', now(), now() + interval '7 days');
insert into condition_reports (vehicle_id, booking_id, kind, odometer_km, fuel_pct, tracker_reporting, licence_seen, card_seen)
values (test.id('vehicle:RQ6'), test.b('L'), 'pickup', 20000, 100, true, true, true);
select test.lives('L a booking that came through request, offer and approval is handed over as before',
  $$update bookings set status = 'on_rent', handed_over_at = pickup_at where id = test.b('L')$$);
select test.eq('L on rent it still blocks the car', app.vehicle_is_available(test.id('vehicle:RQ6'), test.at('2030-04-02 10:00'), test.at('2030-04-03 10:00')), false);
insert into condition_reports (vehicle_id, booking_id, kind, odometer_km, fuel_pct) values (test.id('vehicle:RQ6'), test.b('L'), 'return', 20300, 100);
select test.lives('L checked in', $$update bookings set status = 'returned', checked_in_at = return_at where id = test.b('L')$$);
select test.lives('L and closed', $$update bookings set status = 'closed' where id = test.b('L')$$);
select test.eq('L once returned it no longer blocks the car', app.vehicle_is_available(test.id('vehicle:RQ6'), test.at('2030-04-02 10:00'), test.at('2030-04-03 10:00')), true);
select test.eq('L the full path',
  (select string_agg(to_status, ' > ' order by id) from status_history where entity = 'booking' and entity_id = test.b('L')),
  'requested > offered > pending_payment > confirmed > on_rent > returned > closed');
