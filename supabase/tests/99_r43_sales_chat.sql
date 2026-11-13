-- 99: release 43, the closing Sales person keeps the customer's conversations (2750) and the AI auto-reply waits after a
-- person replied (2751). Fixtures start with "sc43".
select test.suite('99 r43 sales chat');

select test.mk_user('sc43_sales', 'va', 'sales');
select test.mk_user('sc43_other', 'va', 'sales');
select test.mk_user('sc43_cs', 'va', 'cs');
select test.mk_owner('sc43_o');
select test.mk_vehicle('SC43V', 'sc43_o');
select test.mk_renter('sc43_r');
create function test.sc43_t(p interval) returns text language sql stable as $$
  select to_char((now() + p) at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') $$;
-- the sale she closed, long over, and the renter's next booking, on the car now
select test.mk_booking('SC43-1', 'SC43V', 'sc43_r', test.sc43_t(- interval '200 days'), test.sc43_t(- interval '197 days'), 'closed');
select test.mk_booking('SC43-2', 'SC43V', 'sc43_r', test.sc43_t(- interval '1 day'), test.sc43_t(interval '2 days'), 'on_rent');
alter table bookings disable trigger bookings_guard_sales_columns;
update bookings set sales_staff_id = test.id('sc43_sales'), sales_source = 'quote', sales_attributed_at = now() - interval '200 days'
 where booking_number = 'SC43-1';
alter table bookings enable trigger bookings_guard_sales_columns;

select test.ok('closer: the Sales person who closed the sale owns the customer',
  app.sales_owns_customer(test.id('sc43_sales'), test.id('renter:sc43_r')));
select test.ok('closer: another Sales person does not',
  not app.sales_owns_customer(test.id('sc43_other'), test.id('renter:sc43_r')));
select test.ok('closer: the conversation of the renter''s later booking is open to the closer',
  public.door(test.id('sc43_sales'), null, 'ops_read', 'booking_conversation', jsonb_build_object('booking', 'SC43-2', '_va', 'sales')) ->> 'booking' = 'SC43-2');
select test.ok('closer: and of the closed sale itself',
  public.door(test.id('sc43_sales'), null, 'ops_read', 'booking_conversation', jsonb_build_object('booking', 'SC43-1', '_va', 'sales')) ->> 'booking' = 'SC43-1');
select test.throws('closer: another Sales person is still kept to requests and offers',
  $$select public.door(test.id('sc43_other'), null, 'ops_read', 'booking_conversation', jsonb_build_object('booking', 'SC43-2', '_va', 'sales'))$$,
  'requests and offers');
select test.ok('closer: the booking page reads for the closer, without the money',
  (select v ->> 'booking_number' = 'SC43-2' and not (v ? 'payments') from (select public.door(test.id('sc43_sales'), null, 'va_read', 'booking', jsonb_build_object('number', 'SC43-2', '_va', 'sales')) v) x));
select test.lives('closer: the activity log of the later booking reads',
  $$select public.door(test.id('sc43_sales'), null, 'ops_read', 'renter_activity', jsonb_build_object('booking', 'SC43-2', '_va', 'sales'))$$);
select test.ok('privileges: only the server calls the new functions',
  not has_function_privilege('authenticated', 'app.sales_owns_customer(uuid, uuid)', 'execute')
  and not has_function_privilege('anon', 'app.auto_reply_staff_replied(text, text, timestamptz)', 'execute'));

-- ---------------------------------------------------------------- 2751: the AI waits after a person replied
insert into messages (direction, channel, body, to_address, sent_by, status, occurred_at)
values ('outbound', 'email', 'A reply by hand', 'sc43-asker@example.test', test.id('sc43_cs'), 'sent', now() - interval '5 minutes');
select test.eq('auto-reply: no automatic answer right after a person replied by email',
  public.server_auto_reply_gate(jsonb_build_object('channel', 'email', 'sender', 'SC43-Asker@example.test')) ->> 'reason', 'a person is talking with them');
select test.ok('auto-reply: the helper sees no reply once the window passed',
  not app.auto_reply_staff_replied('email', 'sc43-asker@example.test', now() + interval '40 minutes'));
select test.ok('auto-reply: another sender is not held',
  not app.auto_reply_staff_replied('email', 'sc43-someone@example.test'));
insert into phone_threads (number) values ('+15550004343');
insert into phone_activity (thread_id, kind, direction, quo_id, body, started_at)
values ((select id from phone_threads where number = '+15550004343'), 'text', 'out', 'sc43-quo-1', 'Sent from the Quo app', now() - interval '3 minutes');
select test.ok('auto-reply: a text sent by hand from the Quo app counts as a person replying',
  app.auto_reply_staff_replied('sms', '+15550004343'));
update program_settings set auto_reply_after_staff_minutes = 0;
select test.ok('auto-reply: the window is a setting (0: no pause)', not app.auto_reply_staff_replied('sms', '+15550004343'));
update program_settings set auto_reply_after_staff_minutes = 30;
