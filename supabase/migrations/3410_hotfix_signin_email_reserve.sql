-- 3410_hotfix_signin_email_reserve.sql
-- Hotfix, November 23 2026 (sign-ins not working; BR-3). SCHEMA_MARKER 3410.
-- What happened: Amazon SES had never sent (its keys are not on the server) and Cloudflare Email is off, so the day's
-- email cap was Resend's free 100. One hour of hiring emails (applicant_referred, applicant_ai_interview), staff digests and
-- renter emails used it by mid-afternoon; every other email, sign-up confirmations included, waited for midnight, and the
-- sign-in page switched to codes by text. The texts then failed too (Quo: no prepaid credits). Nobody was told.
--   1. A daily reserve. Low classes (marketing, digests, staff email, hiring, reminders, owner outreach) stop at
--      email_low_class_stop_pct (60%) of the day's cap; owner and investor email at 85%; booking, payment and account email
--      may use the rest less email_auth_reserve (10, at most a tenth of the cap), kept for the sign-in service's own emails (confirmations, password
--      resets, codes), which go through the same Resend account and are not in the outbox. Site alerts may use the sign-in reserve.
--      What a class may not send now is held 20 minutes at a time (never past midnight) and goes on its own as soon
--      as there is room again (the cap rising: SES or Cloudflare switched on). At the cap itself the claim is as before.
--   2. Alerts: two new site checks. "Sign-in codes by text" fails when the last 3 texts of sign-in codes all failed; "Daily
--      email limit" fails while the day's cap is used. Each raises the Admin To do and emails the alert address at once
--      (app.uptime_notify, like the backup check).
--   3. public.server_email_capped also says whether texts work (sms_ok), so the sign-in page offers the password form
--      instead of a text code that cannot arrive.
--   4. BR-3: an Admin approves a booking's coverage by hand (ops_do coverage_confirm_admin): the policy or card details and
--      a reason, recorded in the booking's history and the audit log. The proof row is confirmed as a review would, so the
--      pay page, the agreement and the handover read it as approved; the renter does not have to upload.
set local check_function_bodies = off;

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3410: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings
alter table program_settings
  add column if not exists email_low_class_stop_pct integer not null default 60 check (email_low_class_stop_pct between 10 and 100),
  add column if not exists email_auth_reserve integer not null default 10 check (email_auth_reserve between 0 and 100),
  add column if not exists email_reserve_from_cap integer not null default 50 check (email_reserve_from_cap >= 0);
comment on column program_settings.email_low_class_stop_pct is 'Daily email reserve (3410): marketing, digests, staff, hiring and reminder emails stop at this share of the day''s cap, so booking, payment and sign-in email always has room.';
comment on column program_settings.email_reserve_from_cap is 'Daily email reserve (3410): on when the day''s cap is at least this many emails. A smaller day (a local or test database) has nothing to reserve: the claim is as before.';
comment on column program_settings.email_auth_reserve is 'Daily email reserve (3410): emails of the day''s cap kept for the sign-in service (confirmations, password resets, codes), which shares the Resend account.';

-- ================================================================ 1. the reserve
-- alert: the site alerts (they may use the sign-in reserve: the alert that the cap is reached must go out); top: booking,
-- payment and account email; mid: owners and investors; low: everything that can wait
create function app.email_class(p_code text, p_category text, p_priority integer) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when p_code in ('staff_site_alert', 'staff_site_recovered') then 'alert'
              when p_category = 'marketing' or coalesce(p_priority, 5) >= 3 or p_code like 'applicant\_%' or p_code like '%\_reminder%'
                   or p_code like 'owner\_recruit%' then 'low'
              when p_priority = 2 then 'mid'
              else 'top' end
$$;

-- the reasons a held email carries, all released by the claim when there is room
create function app.email_held_reasons() returns text[]
language sql immutable set search_path = public, app, pg_temp as $$
  select array['daily email limit', 'held for booking and sign-in email (daily reserve)', 'monthly email limit', 'the day''s email budget is used',
               'the email provider''s daily limit']
$$;

-- where each class stops today, and how many are used (the sign-in service's own emails counted)
create function app.email_reserve(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  v_cap integer := app.email_day_cap(p_now);
  v_auth integer := coalesce(app.auth_emails_today(p_now), 0);
begin
  return jsonb_build_object('cap', v_cap, 'auth_today', v_auth, 'on', v_cap >= coalesce(s.email_reserve_from_cap, 50) and (coalesce(s.email_low_class_stop_pct, 60) < 100 or coalesce(s.email_auth_reserve, 10) > 0),
    'used', app.emails_since(app.local_midnight(app.local_date(p_now)), p_now),
    'low', floor(v_cap * coalesce(s.email_low_class_stop_pct, 60) / 100.0)::integer,
    'mid', floor(v_cap * greatest(coalesce(s.email_low_class_stop_pct, 60), 85) / 100.0)::integer,
    'top', v_cap - least(coalesce(s.email_auth_reserve, 10), v_cap / 10));
end $$;

alter function app.outbox_claim(integer, timestamptz) rename to outbox_claim_pre3410;
create function app.outbox_claim(p_limit integer default 20, p_now timestamptz default now())
returns table (id uuid, code text, category text, to_address text, to_name text, from_address text, reply_to text, subject text, payload jsonb,
               attempts integer, unsubscribe_url text, template_html text, template_text text)
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  x jsonb := app.email_reserve(p_now);
  v_used integer := (x ->> 'used')::integer;
  v_stop jsonb := jsonb_build_object('alert', (x ->> 'cap')::integer, 'top', (x ->> 'top')::integer, 'mid', (x ->> 'mid')::integer, 'low', (x ->> 'low')::integer);
  v_next timestamptz := least(app.local_midnight(app.local_date(p_now) + 1), p_now + interval '20 minutes');
  v_class text;
  v_room integer;
  r record;
begin
  if not coalesce((x ->> 'on')::boolean, true) then
    return query select * from app.outbox_claim_pre3410(p_limit, p_now);
    return;
  end if;
  -- room again (a higher cap, SES or Cloudflare switched on): what the reserve held goes now, by class and priority (what
  -- the cap itself held goes at midnight, or at once with app.email_release_held, as before)
  foreach v_class in array array['alert', 'top', 'mid', 'low'] loop
    v_room := (v_stop ->> v_class)::integer - v_used;
    continue when v_room <= 0;
    update notification_outbox o set status = 'queued', status_reason = null, send_after = p_now
     where o.id in (select h.id from notification_outbox h
                     where h.status = 'delayed' and coalesce(h.channel, 'email') = 'email' and h.send_after > p_now
                       and h.status_reason = 'held for booking and sign-in email (daily reserve)'
                       and app.email_class(h.code, h.category, h.priority) = v_class
                     order by h.priority, h.created_at limit v_room);
  end loop;
  -- a class at its stop waits (20 minutes at a time, never past midnight), so the rest keeps its room; at the cap
  -- itself the claim of 0583 holds everything for the next day as before ('daily email limit')
  if v_used >= (x ->> 'cap')::integer then
    return query select * from app.outbox_claim_pre3410(p_limit, p_now);
    return;
  end if;
  update notification_outbox o set status = 'delayed', status_reason = 'held for booking and sign-in email (daily reserve)', send_after = v_next
   where o.status = 'queued' and o.send_after <= p_now and coalesce(o.channel, 'email') = 'email'
     and v_used >= (v_stop ->> app.email_class(o.code, o.category, o.priority))::integer;
  for r in select * from app.outbox_claim_pre3410(p_limit, p_now) loop
    select app.email_class(o.code, o.category, o.priority) into v_class from notification_outbox o where o.id = r.id;
    if v_used < (x ->> 'cap')::integer and v_used >= (v_stop ->> coalesce(v_class, 'top'))::integer then
      update notification_outbox o set status = 'delayed', status_reason = 'held for booking and sign-in email (daily reserve)',
             attempts = greatest(o.attempts - 1, 0), locked_at = null, send_after = v_next where o.id = r.id;
      continue;
    end if;
    v_used := v_used + 1;
    id := r.id; code := r.code; category := r.category; to_address := r.to_address; to_name := r.to_name; from_address := r.from_address;
    reply_to := r.reply_to; subject := r.subject; payload := r.payload; attempts := r.attempts; unsubscribe_url := r.unsubscribe_url;
    template_html := r.template_html; template_text := r.template_text;
    return next;
  end loop;
end $$;
select pg_temp.copy_grants('app.outbox_claim(integer, timestamptz)'::regprocedure, 'app.outbox_claim_pre3410(integer, timestamptz)'::regprocedure);

-- ================================================================ 2. alerts: texts of sign-in codes, the daily email limit
insert into uptime_checks (key, label, kind, path, sort, advice) values
  ('sms_signin', 'Sign-in codes by text', 'internal', null, 9,
   'The last 3 sign-in codes by text could not be sent. Open Settings > Usage (the text provider: prepaid credits, the number). People can still sign in with their email and password.'),
  ('email_cap', 'Daily email limit', 'internal', null, 10,
   'Today''s email limit is used: booking and sign-in emails wait. Switch on Amazon SES or Cloudflare Email (Program settings) or wait for midnight; held emails then go on their own.')
on conflict (key) do nothing;

-- true while the last 3 sign-in texts all failed (the newest reason with it)
create function app.sms_signin_failing(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  with l as (select s.status, s.reason from app.auth_sms_log s where s.status in ('sent', 'failed') and s.created_at > p_now - interval '7 days'
              order by s.created_at desc limit 3)
  select jsonb_build_object('failing', (select count(*) from l) = 3 and not exists (select 1 from l where l.status = 'sent'),
                            'reason', (select l.reason from l limit 1))
$$;

alter function app.uptime_internal(timestamptz) rename to uptime_internal_pre3410;
create function app.uptime_internal(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v jsonb := app.uptime_internal_pre3410(p_now);
  sms jsonb := app.sms_signin_failing(p_now);
  x jsonb := app.email_reserve(p_now);
  -- full: booking and account email can no longer go today (the sign-in reserve is all that is left)
  v_email_full boolean := (x ->> 'used')::integer >= (x ->> 'top')::integer;
begin
  perform app.uptime_record('sms_signin', not (sms ->> 'failing')::boolean, null, null,
    case when (sms ->> 'failing')::boolean then left('The last 3 sign-in codes by text failed: ' || coalesce(sms ->> 'reason', 'no reason given'), 500) end, p_now);
  perform app.uptime_record('email_cap', not v_email_full, null, null,
    case when v_email_full then format('%s of %s emails used today (and %s by the sign-in service); booking and sign-in email is down to its reserve; %s emails wait.', x ->> 'used', x ->> 'cap', x ->> 'auth_today',
      (select count(*) from notification_outbox o where o.status = 'delayed' and o.status_reason = any (app.email_held_reasons()))) end, p_now);
  return coalesce(v, '{}'::jsonb) || jsonb_build_object('sms_signin', sms, 'email_full', v_email_full);
end $$;
select pg_temp.copy_grants('app.uptime_internal(timestamptz)'::regprocedure, 'app.uptime_internal_pre3410(timestamptz)'::regprocedure);

-- both alert at once (a task on Admin > To do, and the alert email within the day's alert rules)
select pg_temp.patch_fn('app.uptime_notify(timestamptz)'::regprocedure,
  $o$when r.key = 'backup' then 0 end;$o$,
  $n$when r.key in ('backup', 'sms_signin', 'email_cap') then 0 end;$n$);

-- the moment a text of a sign-in code fails for the third time running, not only at the next round
select pg_temp.patch_fn('app.server_auth_sms_result(jsonb)'::regprocedure,
  $o$  return jsonb_build_object('ok', found);$o$,
  $n$  if not found then return jsonb_build_object('ok', false); end if;
  if not coalesce((p ->> 'ok')::boolean, false) and (app.sms_signin_failing() ->> 'failing')::boolean then
    perform app.uptime_record('sms_signin', false, null, null, left('The last 3 sign-in codes by text failed: ' || coalesce(p ->> 'error', 'no reason given'), 500));
  elsif coalesce((p ->> 'ok')::boolean, false) then
    perform app.uptime_record('sms_signin', true);
  end if;
  return jsonb_build_object('ok', true);$n$);

-- ================================================================ 3. the sign-in page: do texts work?
alter function public.server_email_capped() rename to server_email_capped_pre3410;
alter function public.server_email_capped_pre3410() set schema app;
create function public.server_email_capped() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.server_email_capped_pre3410() || jsonb_build_object('sms_ok', not coalesce((app.sms_signin_failing() ->> 'failing')::boolean, false))
$$;
revoke all on function public.server_email_capped() from public, anon, authenticated;
grant execute on function public.server_email_capped() to service_role;

-- ================================================================ 4. BR-3: an Admin approves the coverage by hand
create function app.coverage_confirm_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  cp coverage_proofs;
  v_reason text := left(btrim(coalesce(p ->> 'reason', '')), 500);
  v_ins text := nullif(left(btrim(coalesce(p ->> 'insurer_name', '')), 120), '');
  v_pol text := nullif(left(btrim(coalesce(p ->> 'policy_number', '')), 120), '');
  v_exp date;
  v_issuer text := nullif(left(btrim(coalesce(p ->> 'card_issuer', '')), 80), '');
  v_last4 text := nullif(btrim(coalesce(p ->> 'card_last4', '')), '');
  v_ready jsonb;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin approves coverage by hand' using errcode = '42501'; end if;
  select * into b from bookings where id::text = p ->> 'booking' or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if length(v_reason) < 5 then raise exception 'Say why you approve the coverage (kept in the history)' using errcode = '22023'; end if;
  if b.booking_type = 'owner' then raise exception 'An Owner Booking needs no Coverage Option' using errcode = '23514'; end if;
  if b.status::text in ('cancelled', 'declined', 'expired', 'closed') then
    raise exception 'Booking % is %: nothing to approve', b.booking_number, replace(b.status::text, '_', ' ') using errcode = '23514';
  end if;
  if b.coverage_option is null then raise exception 'Choose the coverage option on the booking first' using errcode = '23514'; end if;
  if b.coverage_option = 3 then raise exception 'The Protection Plan is confirmed with Confirm the Protection Plan, once it is paid' using errcode = '23514'; end if;
  begin
    v_exp := nullif(btrim(coalesce(p ->> 'policy_expiry', '')), '')::date;
  exception when others then
    raise exception 'Give the policy expiry as a date' using errcode = '22023';
  end;
  if v_last4 is not null and v_last4 !~ '^[0-9]{4}$' then raise exception 'The card''s last 4 digits are 4 numbers' using errcode = '22023'; end if;
  select * into cp from coverage_proofs c where c.booking_id = b.id and c.coverage_option = b.coverage_option and c.status in ('submitted', 'confirmed')
   order by c.created_at desc limit 1;
  if b.coverage_confirmed_at is not null and cp.status = 'confirmed' then return app.booking_readiness(b.id); end if;
  -- the facts the confirmed proof must carry (0005): the policy for option 1, the card for option 2
  v_ins := coalesce(v_ins, cp.insurer_name); v_pol := coalesce(v_pol, cp.policy_number); v_exp := coalesce(v_exp, cp.policy_expiry);
  v_issuer := coalesce(v_issuer, cp.card_issuer); v_last4 := coalesce(v_last4, cp.card_last4);
  if b.coverage_option = 1 and (v_ins is null or v_pol is null or v_exp is null) then
    raise exception 'Give the insurer, the policy number and the policy expiry of the renter''s own policy' using errcode = '22023';
  end if;
  if b.coverage_option = 2 and (v_issuer is null or v_last4 is null) then
    raise exception 'Give the card issuer and the card''s last 4 digits' using errcode = '22023';
  end if;
  if cp.id is null then
    insert into coverage_proofs (booking_id, coverage_option, status, insurer_name, policy_number, policy_expiry, card_issuer, card_last4,
                                 covers_vehicle_and_drivers, confirmed_by, confirmed_at, submitted_by, submitted_at, reviewed_checks)
    values (b.id, b.coverage_option, 'confirmed', v_ins, v_pol, v_exp, v_issuer, v_last4, true, p_by, now(), p_by, now(),
            jsonb_build_object('by_hand', true, 'reason', v_reason))
    returning * into cp;
  else
    update coverage_proofs set status = 'confirmed', insurer_name = v_ins, policy_number = v_pol, policy_expiry = v_exp, card_issuer = v_issuer,
           card_last4 = v_last4, covers_vehicle_and_drivers = true, confirmed_by = p_by, confirmed_at = now(), rejection_reason = null,
           reviewed_checks = coalesce(reviewed_checks, '{}'::jsonb) || jsonb_build_object('by_hand', true, 'reason', v_reason)
     where id = cp.id returning * into cp;
    update verification_uploads set status = 'approved', reviewed_by = p_by, reviewed_at = now()
     where coverage_proof_id = cp.id and status = 'submitted';
  end if;
  update bookings set coverage_confirmed_at = now() where id = b.id;
  perform app.log_booking_event(b.id, 'verification', b.status::text, b.status::text, null, 'Coverage approved by hand by an Admin: ' || v_reason, p_by, 'staff',
    jsonb_build_object('coverage_proof_id', cp.id, 'kind', 'coverage_proof', 'coverage_option', b.coverage_option, 'decision', 'approved', 'by_hand', true));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'coverage_confirmed_by_hand', 'bookings', b.id::text, jsonb_build_object('coverage_confirmed_at', b.coverage_confirmed_at),
          jsonb_build_object('coverage_confirmed_at', now(), 'coverage_proof_id', cp.id, 'coverage_option', b.coverage_option, 'reason', v_reason));
  v_ready := app.booking_readiness(b.id);
  if (v_ready ->> 'identity_and_coverage_confirmed')::boolean then
    perform app.emit_event('renter_identity_approved', 'booking', b.id,
      jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'pickup_at', b.pickup_at),
      'renter_identity_approved:' || b.id || ':verified');
  end if;
  return v_ready;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3410;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_call = 'ops_do' and p_name = 'coverage_confirm_admin' then
    perform app.door_begin(p_user, p_aal);
    return app.coverage_confirm_admin(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre3410(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3410(uuid, text, text, text, jsonb)'::regprocedure);

do $$
declare f text;
begin
  foreach f in array array['app.email_reserve(timestamptz)', 'app.outbox_claim_pre3410(integer, timestamptz)', 'app.sms_signin_failing(timestamptz)',
    'app.uptime_internal_pre3410(timestamptz)', 'app.server_email_capped_pre3410()', 'app.coverage_confirm_admin(uuid, jsonb)',
    'app.door_pre3410(uuid, text, text, text, jsonb)', 'app.email_class(text, text, integer)', 'app.email_held_reasons()'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
