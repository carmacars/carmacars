-- 1870_r35gaps4_review_preask.sql
-- The owner, October 24, 2026 (message 1938): ask for the review before the booking ends as well. A soft ask in the mid-trip
-- check-in of the last full day of the rental, with the review link and the Rewards points. The review check that stops the
-- sequence (app.review_found: on the site, on Google, "already reviewed", staff declined) runs first, so nobody who reviewed gets it,
-- and the after-return steps (+1 h, +24 h, +7 d) stop the same way once a review exists.
--   * Program settings: review_preask_enabled (on), review_preask_days_before (1 = the day before the return date).
--   * review_requests.preask_sent_at; notification renter_review_preask (email) and its text.
--   * app.review_step sends it (instead of the check-in that day) when the rental is long enough for a check-in.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter table program_settings
  add column if not exists review_preask_enabled boolean not null default true,
  add column if not exists review_preask_days_before integer not null default 1 check (review_preask_days_before between 1 and 7);
comment on column program_settings.review_preask_enabled is 'Review requests (1870): a soft review ask with the review link and the Rewards points on the last full day of the rental (replaces the mid-trip check-in that day). Never to a renter who reviewed or unsubscribed.';
comment on column program_settings.review_preask_days_before is 'Review requests (1870): the soft ask goes this many days before the return date (1 is the last full day).';
alter table review_requests add column if not exists preask_sent_at timestamptz;
comment on column review_requests.preask_sent_at is 'The soft review ask of the last full day of the rental was sent (1870).';

create or replace function app.review_step(p_booking uuid, p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  b bookings;
  rr review_requests;
  v_found text;
  v_reasons text[];
  v_back timestamptz;
  v_open boolean := app.review_in_window(p_now, s.review_send_from_hour, s.review_send_until_hour);
  v_start timestamptz;
  v_pre boolean := false;
begin
  if not s.review_program_enabled then return null; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' or b.status not in ('on_rent', 'returned', 'closed') then return null; end if;
  rr := app.review_request_row(p_booking);
  if rr.status in ('stopped', 'finished') then return null; end if;
  -- reviewed already: stop
  v_found := app.review_found(p_booking);
  if v_found is not null then
    perform app.review_stop(p_booking, v_found);
    return 'stopped:' || v_found;
  end if;

  -- the mid-trip check-in (no review ask, no hold, not marketing)
  if b.status = 'on_rent' then
    v_start := coalesce(b.handed_over_at, b.pickup_at);
    -- the soft review ask of the last full day (1870): it takes the place of the check-in that day, and goes to nobody who reviewed
    -- (stopped above), is unsubscribed or already got it
    v_pre := s.review_preask_enabled and rr.preask_sent_at is null and v_open
             and b.return_at - v_start >= make_interval(days => s.review_checkin_min_days)
             and app.local_date(p_now) = app.local_date(b.return_at) - s.review_preask_days_before
             and p_now > v_start and p_now <= b.return_at - interval '6 hours'
             and app.review_may_ask(p_booking);
    if v_pre then
      if app.review_emit('renter_review_preask', p_booking, 'preask') then
        update review_requests set preask_sent_at = p_now, checkin_sent_at = coalesce(checkin_sent_at, p_now) where booking_id = p_booking;
        return 'preask';
      end if;
    end if;
    if s.review_checkin_enabled and rr.checkin_sent_at is null and v_open
       and b.return_at - v_start >= make_interval(days => s.review_checkin_min_days)
       and p_now >= v_start + make_interval(hours => s.review_checkin_after_hours)
       and p_now <= b.return_at - interval '6 hours' then
      if app.review_emit('renter_trip_checkin', p_booking, 'checkin') then
        update review_requests set checkin_sent_at = p_now where booking_id = p_booking;
        return 'checkin';
      end if;
    end if;
    return null;
  end if;

  v_back := app.review_returned_at(p_booking);
  -- a request that could not go within the window (held all that time): no more
  if rr.ask_sent_at is null and not rr.manual_pending and p_now > v_back + make_interval(days => s.review_ask_max_days) then
    perform app.review_stop(p_booking, 'too_late');
    return 'stopped:too_late';
  end if;
  -- held: open charges (only when the hold is on); staff's Send anyway overrides
  v_reasons := case when s.review_hold_incidentals and rr.send_anyway_at is null then app.review_hold_reasons(p_booking) else '{}' end;
  if cardinality(v_reasons) > 0 and rr.final_sent_at is null then
    update review_requests set status = 'held', hold_reasons = v_reasons, held_since = coalesce(held_since, p_now), manual_pending = false
     where booking_id = p_booking;
    return 'held';
  end if;
  if rr.status = 'held' then
    update review_requests set status = case when ask_sent_at is null then 'waiting' else 'asked' end, hold_reasons = '{}', released_at = p_now
     where booking_id = p_booking returning * into rr;
  end if;

  -- the request
  if rr.ask_sent_at is null then
    if not rr.manual_pending and p_now < v_back + make_interval(mins => s.review_ask_after_minutes) then return null; end if;
    if not app.review_may_ask(p_booking) then
      perform app.review_stop(p_booking, 'unsubscribed');
      return 'stopped:unsubscribed';
    end if;
    if not v_open then return null; end if;
    perform app.review_emit('renter_review_ask', p_booking, 'ask');
    update review_requests set ask_sent_at = p_now, status = 'asked', manual_pending = false where booking_id = p_booking;
    return case when rr.manual_pending then 'manual' else 'ask' end;
  end if;

  -- a staff member's ask again (after the request): once, inside the sending hours
  if rr.manual_pending then
    if not v_open then return null; end if;
    if not app.review_may_ask(p_booking) then
      perform app.review_stop(p_booking, 'unsubscribed');
      return 'stopped:unsubscribed';
    end if;
    perform app.review_emit('renter_review_ask', p_booking, 'manual:' || rr.manual_asks);
    update review_requests set manual_pending = false where booking_id = p_booking;
    return 'manual';
  end if;

  -- the reminder, then the final follow-up
  if rr.reminder_sent_at is null and p_now >= rr.ask_sent_at + make_interval(hours => s.review_reminder_hours) then
    if not v_open then return null; end if;
    if not app.review_may_ask(p_booking) then perform app.review_stop(p_booking, 'unsubscribed'); return 'stopped:unsubscribed'; end if;
    perform app.review_emit('renter_review_reminder', p_booking, 'reminder');
    update review_requests set reminder_sent_at = p_now where booking_id = p_booking;
    return 'reminder';
  end if;
  if rr.final_sent_at is null and p_now >= rr.ask_sent_at + make_interval(days => s.review_final_days) then
    if not v_open then return null; end if;
    if not app.review_may_ask(p_booking) then perform app.review_stop(p_booking, 'unsubscribed'); return 'stopped:unsubscribed'; end if;
    perform app.review_emit('renter_review_final', p_booking, 'final');
    update review_requests set final_sent_at = p_now, status = 'finished' where booking_id = p_booking;
    return 'final';
  end if;
  return null;
end $$;



-- the values of the new email: the review page of the booking
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre1870;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre1870(p_code, p_event, p_to);
  v_base text;
  v_token uuid;
begin
  if p_code = 'renter_review_preask' and p_event.entity = 'booking' then
    v_base := rtrim(coalesce((app.settings()).notify_base_url, 'https://carmacars.ca'), '/');
    select token into v_token from review_requests where booking_id = p_event.entity_id;
    x := x || jsonb_build_object('review_url', v_base || '/review/' || v_token, 'review_done_url', v_base || '/review/' || v_token || '?done=1',
                                 'google_review_url', coalesce(app.google_review_url(), v_base || '/review/' || v_token),
                                 '_url', v_base || '/review/' || v_token);
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload(text, app_events, jsonb)'::regprocedure, 'app.ntf_payload_pre1870(text, app_events, jsonb)'::regprocedure);

-- CATALOGUE 1870 START (generated by supabase/seed/1870_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_review_preask', 'renter', '{}'::text[], 'marketing', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Last day with the {{vehicle_name}}', 'If it has been good, a review takes a minute. It also earns Rewards points.', 'The last full day of the rental, 9 am to 9 pm', 'Review requests (migration 1870, app.job_review_requests every 10 minutes): booking status is on_rent and today is the last full day of the rental (review_preask_days_before, 1 by default, before the return date). It takes the place of the mid-trip check-in that day. Only from review_send_from_hour to review_send_until_hour Toronto time (9 am to 9 pm by default). Never sent when the renter already reviewed (on the site, on Google matched by name, "I already left a review", or marked by staff) or unsubscribed. Once per booking. The after-return requests (1 hour, 24 hours, 7 days) still follow unless a review exists by then.', null, null, '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"review_done_url","type":"url"},{"name":"review_url","type":"url"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"unsubscribe_url","type":"url"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_review_preask.html', 'templates/renter_review_preask.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 1870 END
update notification_catalogue set emitted_by = 'app.job_review_requests through app.review_step (1870)' where code = 'renter_review_preask';

insert into sms_templates (code, label, body, urgent, sort_order) values
  ('renter_review_preask', 'Review, last day', 'CarmaCars: last day with the {{vehicle_name}}, {{first_name}}. If the trip went well, a quick review takes a minute and earns Rewards points: {{link}}', false, 88)
on conflict (code) do nothing;
