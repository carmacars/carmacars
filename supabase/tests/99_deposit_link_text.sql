-- 99: the deposit hold link texted before pickup (migration 0213). Fixtures start with "dlt"; 555 test numbers.
select test.suite('99 deposit link by text');
select test.mk_user('dlt_admin', 'admin');
select test.mk_owner('dlt_o');
select test.mk_vehicle('DLTA', 'dlt_o');
select test.mk_vehicle('DLTB', 'dlt_o');
select test.mk_vehicle('DLTC', 'dlt_o');
select test.mk_renter('dlt_r');
select test.mk_renter('dlt_n', false);
update renters set mobile = null where id = test.id('renter:dlt_n');
create temp table dlt_phone as select (app.settings()).phone_enabled v;
update program_settings set phone_enabled = true where id = (app.settings()).id;
create or replace function test.dlt_at(p_hours int) returns text language sql as $$
  select to_char((now() + make_interval(hours => p_hours)) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')
$$;
select test.mk_booking('CC-DLT1', 'DLTA', 'dlt_r', test.dlt_at(10), test.dlt_at(58), 'confirmed');
select test.mk_booking('CC-DLT2', 'DLTB', 'dlt_r', test.dlt_at(24 * 5), test.dlt_at(24 * 7), 'confirmed');
select test.mk_booking('CC-DLT3', 'DLTC', 'dlt_n', test.dlt_at(20), test.dlt_at(68), 'confirmed');
update bookings set deposit_pay_method = 'card', deposit_cents = 50000 where booking_number like 'CC-DLT%';
create or replace function test.dlt_due(p_number text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.server_deposit_links_due()) x where x ->> 'booking_number' = p_number)
$$;

select test.ok('on by default, 24 hours before pickup', (select deposit_link_auto and deposit_link_hours = 24 from site_settings where singleton));
select test.ok('a confirmed card-hold booking picked up within 24 hours is due', test.dlt_due('CC-DLT1'));
select test.ok('one picked up in five days is not due yet', not test.dlt_due('CC-DLT2'));
select test.ok('the deposit job runs for it', (app.server_jobs_due() ->> 'deposits')::boolean);

-- the request, as Collect a card > The deposit hold, and the text
create temp table dlt as select 'a'::text k, public.server_deposit_link_payreq((select id from bookings where booking_number = 'CC-DLT1'), encode(sha256('dltabcdefghijklmnopqrstuvwxyz1'::bytea), 'hex')) v;
select test.ok('a hold request for the deposit, made by the job', exists (select 1 from payment_requests q where q.id = (select (v ->> 'id')::uuid from dlt where k = 'a')
  and q.kind = 'hold' and q.covers = 'deposit' and q.amount_cents = 50000 and q.channel = 'text' and q.auto and q.status = 'open' and q.created_by is null));
select test.throws('the link must be this request''s', format($s$select public.server_deposit_link_send(%L, 'https://carmacars.ca/pay/zzzzzzzzzzzzzzzzzzzzzzzz')$s$, (select v ->> 'id' from dlt where k = 'a')), 'not this request');
select test.ok('texted to the renter from the CarmaCars number', (public.server_deposit_link_send((select (v ->> 'id')::uuid from dlt where k = 'a'), 'https://carmacars.ca/pay/dltabcdefghijklmnopqrstuvwxyz1') ->> 'ok')::boolean);
select test.ok('the text: the booking, the amount and the pay link', exists (select 1 from payment_requests q join phone_outbox p on p.id = q.text_id
  where q.id = (select (v ->> 'id')::uuid from dlt where k = 'a') and q.texted_at is not null and p.status = 'queued' and p.sms_kind = 'deposit_link' and p.to_number = '+16475550199'
    and p.body like 'CarmaCars: booking CC-DLT1, pickup %' and p.body like '%$500.00%' and p.body like '%/pay/dltabcdefghijklmnopqrstuvwxyz1'));
select test.ok('sent once', (public.server_deposit_link_send((select (v ->> 'id')::uuid from dlt where k = 'a'), 'https://carmacars.ca/pay/dltabcdefghijklmnopqrstuvwxyz1') ->> 'already')::boolean);
select test.ok('no longer due: a live request exists', not test.dlt_due('CC-DLT1'));
select test.eq('a second request is refused', public.server_deposit_link_payreq((select id from bookings where booking_number = 'CC-DLT1'), encode(sha256('dltother'::bytea), 'hex')) ->> 'reason', 'a live request exists');

-- the Money tab and the ready check
select public.server_payreq_opened(encode(sha256('dltabcdefghijklmnopqrstuvwxyz1'::bytea), 'hex'));
select test.ok('the Money tab: texted and opened, and the renter has a mobile', (select (m #>> '{deposit_link,texted_at}') is not null and (m #>> '{deposit_link,opened_at}') is not null and (m ->> 'renter_has_mobile')::boolean
  from (select app.booking_money(test.id('dlt_admin'), '{"booking": "CC-DLT1"}') m) x));

-- an older amount is replaced; a waived or offline deposit is not asked for
update bookings set deposit_cents = 60000 where booking_number = 'CC-DLT1';
select test.ok('the deposit changed: due again', test.dlt_due('CC-DLT1'));
select test.ok('a new request for the new amount', (public.server_deposit_link_payreq((select id from bookings where booking_number = 'CC-DLT1'), encode(sha256('dltnewer'::bytea), 'hex')) ->> 'ok')::boolean);
select test.eq('it replaces the old one', (select status from payment_requests where id = (select (v ->> 'id')::uuid from dlt where k = 'a')), 'cancelled');
select test.ok('CC-DLT2 needs its hold', app.deposit_link_needed((select b from bookings b where b.booking_number = 'CC-DLT2')));
update bookings set deposit_pay_method = 'e_transfer' where booking_number = 'CC-DLT2';
select test.ok('a deposit taken another way is not asked for', not app.deposit_link_needed((select b from bookings b where b.booking_number = 'CC-DLT2')));
update bookings set deposit_pay_method = 'card', deposit_waived_at = now(), deposit_waived_by = test.id('dlt_admin'), deposit_waived_reason = 'Long-time renter' where booking_number = 'CC-DLT2';
select test.ok('a waived deposit is not asked for', not app.deposit_link_needed((select b from bookings b where b.booking_number = 'CC-DLT2')));
update site_settings set deposit_link_auto = false where singleton;
select test.ok('the switch off: nothing is due', not test.dlt_due('CC-DLT3'));
update site_settings set deposit_link_auto = true where singleton;

-- no mobile: the task "Deposit link not sent"
insert into dlt select 'n', public.server_deposit_link_payreq((select id from bookings where booking_number = 'CC-DLT3'), encode(sha256('dltnomobileabcdefghijklmnop'::bytea), 'hex'));
select test.eq('no mobile: not sent', public.server_deposit_link_send((select (v ->> 'id')::uuid from dlt where k = 'n'), 'https://carmacars.ca/pay/dltnomobileabcdefghijklmnop') ->> 'reason', 'no mobile');
select test.ok('a task "Deposit link not sent" on the booking, and the Admins told', exists (select 1 from tasks t where t.booking_id = (select id from bookings where booking_number = 'CC-DLT3')
    and t.title like 'Deposit link not sent%' and t.completed_at is null)
  and exists (select 1 from notifications n where n.user_id = test.id('dlt_admin') and n.code = 'staff_deposit_link_not_sent'));

update program_settings set phone_enabled = (select v from dlt_phone) where id = (app.settings()).id;
update payment_requests set status = 'cancelled' where booking_id in (select id from bookings where booking_number like 'CC-DLT%') and status = 'open';
update bookings set deposit_pay_method = 'cash' where booking_number like 'CC-DLT%';
