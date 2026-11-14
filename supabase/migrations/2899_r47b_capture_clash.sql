-- 2899 (release 47, part B): a capture that clashed with another request is not a failed payment. When the renter's
-- browser and Stripe's webhook settled the same payment at once, the second capture got Stripe's "another in-progress
-- request using this Idempotent Key"; the first one took the money, yet the booking's payment was marked failed and an
-- urgent "payment could not be captured" To do opened. The web now reads the PaymentIntent again before recording a
-- failure (web/src/server/portal/capture-check.ts, as r44's settleIntent already did once). Here:
--   public.server_booking_payment_captured(booking, processor): Stripe says the intent is captured (succeeded): a
--     booking_total payment of that intent recorded as failed by a capture is recorded as paid again, and the open
--     capture_failed To do's of the booking are closed with a note. Called by settleIntent whenever the intent shows
--     succeeded; does nothing otherwise.
--   Once: an open capture_failed To do is closed only when what is stored shows the payment succeeded (Stripe's
--     payment_intent.succeeded event for that intent, kept in webhook_events); the others are left for the Admin.
-- docs/changes/2026-11-14-r47b-crash-alerts-photo-standard.md.

create or replace function app.booking_payment_captured(p_booking uuid, p_intent text, p_note text) returns integer
language plpgsql security definer set search_path = public, app as $$
declare v_pay uuid; n integer := 0;
begin
  if nullif(p_intent, '') is null then return 0; end if;
  select p.id into v_pay from payments p join payment_processor_details d on d.payment_id = p.id
   where p.booking_id = p_booking and p.purpose = 'booking_total' and p.status = 'failed' and d.processor = 'stripe' and d.processor_payment_id = p_intent
   order by p.created_at desc limit 1;
  if v_pay is null then return 0; end if;
  update payments set status = 'succeeded', last_decline_code = null where id = v_pay;
  update tasks set status = 'done', completed_at = now(), completion_note = p_note
   where booking_id = p_booking and task_type = 'capture_failed' and status in ('open', 'in_progress', 'waiting');
  get diagnostics n = row_count;
  -- the payment's own audit row (audit_payments) keeps the change
  return n;
end $$;

create or replace function public.server_booking_payment_captured(p_booking uuid, p_processor jsonb) returns integer
language sql security definer set search_path = public, app as $$
  select app.booking_payment_captured(p_booking, p_processor ->> 'payment_id',
    'Closed by itself (2899): Stripe shows this payment captured; the failure was a clash with another request capturing it at the same time.')
$$;
revoke all on function app.booking_payment_captured(uuid, text, text), public.server_booking_payment_captured(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.server_booking_payment_captured(uuid, jsonb), app.booking_payment_captured(uuid, text, text) to service_role;

-- ================================================================ once: only where the stored state shows the money taken
do $$
declare t record; n integer := 0;
begin
  for t in
    select distinct x.booking_id, d.processor_payment_id as intent
      from tasks x
      join payments p on p.booking_id = x.booking_id and p.purpose = 'booking_total' and p.status = 'failed'
      join payment_processor_details d on d.payment_id = p.id and d.processor = 'stripe'
     where x.task_type = 'capture_failed' and x.status in ('open', 'in_progress', 'waiting')
       and exists (select 1 from webhook_events w where w.provider = 'stripe' and w.event_type = 'payment_intent.succeeded' and w.summary ->> 'id' = d.processor_payment_id)
  loop
    n := n + app.booking_payment_captured(t.booking_id, t.intent,
      'Closed by release 47 (2899): Stripe''s payment_intent.succeeded for this payment is on file, so it was captured; the failure was a clash with another request capturing it at the same time.');
  end loop;
  raise notice '2899: % capture_failed To do''s closed (payment captured)', n;
end $$;
