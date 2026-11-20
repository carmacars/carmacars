-- 3110_r48cm_comms.sql
-- Release 48, part CM (comms; docs/changes/2026-11-20-r48cm-comms.md). The owner (Nov 18): Twilio, Amazon SES and Quo all
-- not working; Sales (Nov 19): calls from the site not working; Quo is out of text credits.
--   1. A text that cannot go (Quo out of credits, or any refusal) falls back to email for that message: the replaced email
--      of a notification goes again (0096), any other text is emailed as text_fell_back, and the text says
--      "not sent: fell back to email". Quo refusing for credits pauses texts (phone_provider_state): while paused nothing
--      is tried, every due text falls back at once; one text is tried again every 30 minutes, and the first one that goes
--      ends the pause. Admins get one alert a day for it, never one per text (rule texts_not_sending).
--   2. Never a late text: a text queued longer than text_stale_minutes (Program settings, 2 hours by default), one whose
--      email already went, and a reminder that is no longer relevant (the booking cancelled, picked up, returned, or the
--      moment passed) are dropped, never sent when credits return.
--   3. Amazon SES in its sandbox (it refuses every recipient it has not verified) is recorded (ses_sandbox_at) and the
--      Admins get one alert a day with the AWS console step (rule ses_sandbox).
--   4. Phone alerts stay on: a device the push service drops (expired, refused, another person signed in on it, more
--      than 10 devices) is recorded in push_lost; the portal tells the person and the browser subscribes again by itself
--      when its permission is still granted. Only the person's own Turn off keeps a device off.
--   5. Staff inactivity: 5 days in a row without using the portal suspends a staff account (was 10; the warning on day 3).
--      The days count from this migration (staff_inactive_grace_from), not from the week staff could not use the portal.
--      A suspended person gets only staff_access_suspended (with a restore link) and staff_access_restored; nothing else
--      (emails, texts and phone alerts of staff audiences are suppressed). The restore link asks the Admins
--      (staff_restore_requests, rule staff_restore_requested); Unlock on Staff approves it.
--   6. users.staff_notices_off: a staff member's notifications turned off (Dwight Laird asked for it).
--   7. Once: this week's townhall (Wednesday Nov 18) is recorded as not held; nobody is marked missed for it.
--   8. Once: an interview call of this week the owner missed is moved to the next open slot; the candidate gets the
--      branded "Moved:" email (applicant_booked).
--   9. Academy: the section Work chats (every staff path): all work communication in the group work chats, never in
--      private messages. The staff guides say it too.
-- No applied migration is edited: functions are wrapped (name_pre3110) or replaced as noted.
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
  if position(p_old in d) = 0 then raise exception '3110: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings
alter table program_settings
  add column if not exists text_stale_minutes integer not null default 120 check (text_stale_minutes between 10 and 2880),
  add column if not exists text_retry_paused_minutes integer not null default 30 check (text_retry_paused_minutes between 5 and 1440),
  add column if not exists staff_inactive_grace_from timestamptz;
comment on column program_settings.text_stale_minutes is 'A text still waiting this long is dropped, never sent late (3110); its email fallback covers it when one is due.';
comment on column program_settings.text_retry_paused_minutes is 'While Quo refuses texts (out of credits), one text is tried again this often; the first one that goes ends the pause (3110).';
comment on column program_settings.staff_inactive_grace_from is 'The inactivity days count from this moment at the earliest (3110: the release, after a week staff could not use the portal).';
alter table program_settings alter column staff_inactive_lock_days set default 5, alter column staff_inactive_warn_days set default 3;
update program_settings set staff_inactive_lock_days = 5 where staff_inactive_lock_days = 10;
update program_settings set staff_inactive_warn_days = 3 where staff_inactive_warn_days = 7;
update program_settings set staff_inactive_grace_from = now() where staff_inactive_grace_from is null;
comment on column program_settings.staff_inactive_lock_days is 'A staff account (never an Admin) with no use of the portal for this many days in a row is suspended (3110: 5; 1060: 10). Suspended staff get only the suspension email with its restore link.';

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('texts_not_sending', 'Texts are not going out (they go by email instead)', 'System', '{admin}', 'normal', 'alerts', true, false, 'Quo refused texts, for example its prepaid credits ran out (3110). Once a day while it lasts.', 170),
  ('ses_sandbox', 'Amazon SES is in its sandbox', 'System', '{admin}', 'normal', 'alerts', true, false, 'SES refuses every recipient it has not verified (3110). Once a day while it lasts.', 171),
  ('staff_restore_requested', 'A suspended staff member asks for access back', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'From the restore link of the suspension email (3110). Unlock on Staff approves it.', 172),
  ('interview_no_slot', 'No open interview slot to move a call to', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'A missed interview call could not be moved (3110). Add interview times on Hiring.', 173)
on conflict (rule) do nothing;

-- ================================================================ 1. texts: the provider's state and the email fallback
create table if not exists phone_provider_state (
  id            boolean primary key default true check (id),
  quo_failed_at timestamptz,
  quo_error     text,
  quo_ok_at     timestamptz,
  quo_probe_at  timestamptz,
  updated_at    timestamptz not null default now()
);
insert into phone_provider_state default values on conflict do nothing;
alter table phone_provider_state enable row level security;
revoke all on phone_provider_state from anon, authenticated;
grant all on phone_provider_state to service_role;
create policy admin_all on phone_provider_state for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_phone_provider_state after insert or update or delete on phone_provider_state for each row execute function app.audit_row();
comment on table phone_provider_state is 'Texts (3110): Quo refused for its account (credits): texts pause and fall back to email until one goes again.';

-- an error that is the account's, not the text's (Quo 402, prepaid credits, a suspended or unpaid account)
create function app.quo_account_error(p_error text) returns boolean
language sql immutable as $$
  select coalesce(p_error, '') ~* '(Quo 402|prepaid credit|insufficient (funds|credit|balance)|out of credit|payment required|billing|account (is )?(suspended|inactive))'
$$;

-- is Quo paused now (refused for its account after its last good send), and may one text be tried again
create function app.quo_paused(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((select q.quo_failed_at is not null and q.quo_failed_at > coalesce(q.quo_ok_at, '-infinity') from phone_provider_state q), false)
$$;

-- the email address a text could go to instead: its person, renter, owner or lead
create function app.text_email_of(o phone_outbox) returns table (email text, name text, user_id uuid)
language sql stable security definer set search_path = public, app as $$
  select e, n, u from (
    select nullif(btrim(us.email), '') e, coalesce(nullif(btrim(us.greeting_name), ''), split_part(btrim(coalesce(us.full_name, '')), ' ', 1)) n, us.id u, 1 k
      from users us where us.id = o.user_id
    union all
    select nullif(btrim(coalesce(nullif(r.email, ''), ru.email)), ''), split_part(btrim(coalesce(r.legal_name, '')), ' ', 1), r.user_id, 2
      from renters r left join users ru on ru.id = r.user_id where r.id = coalesce(o.renter_id, (select t.renter_id from phone_threads t where t.id = o.thread_id))
    union all
    select nullif(btrim(coalesce(nullif(ow.email, ''), ou.email)), ''), split_part(btrim(coalesce(ow.legal_name, '')), ' ', 1), ow.user_id, 3
      from owners ow left join users ou on ou.id = ow.user_id where ow.id = (select t.owner_id from phone_threads t where t.id = o.thread_id)
    union all
    select nullif(btrim(l.email), ''), split_part(btrim(coalesce(l.name, '')), ' ', 1), null::uuid, 4
      from leads l where l.id = (select t.lead_id from phone_threads t where t.id = o.thread_id)
  ) x where e is not null and e ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' order by k limit 1
$$;

-- one text that will not go by text: its email instead (once), and the text says so. p_why is kept on the text.
create function app.text_fall_back(p_id uuid, p_why text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  o phone_outbox;
  n notification_outbox;
  m record;
  v_reason text;
begin
  select * into o from phone_outbox where id = p_id for update;
  if o.id is null or o.status in ('sent', 'skipped') or coalesce(o.status_reason, '') like 'not sent:%' then return null; end if;
  if o.kind = 'opt_confirm' then
    update phone_outbox set status = 'skipped', locked_at = null, status_reason = left('not sent: ' || coalesce(p_why, 'refused'), 300) where id = o.id;
    return 'skipped';
  end if;
  if o.notification_id is not null then select * into n from notification_outbox where id = o.notification_id; end if;
  if n.id is not null and n.status in ('queued', 'delayed', 'sending', 'sent') and coalesce(n.status_reason, '') like 'By email: the text was not sent%' then
    -- the 0096 trigger already queued the email this text replaced
    v_reason := 'not sent: fell back to email';
  elsif n.id is not null and n.status in ('sent', 'sending', 'queued', 'delayed') then
    -- its own email went (or goes): nothing more
    v_reason := 'not sent: the email already covers it';
  elsif n.id is not null and n.status = 'skipped' and coalesce(n.status_reason, '') like 'Sent by text%' and nullif(btrim(coalesce(n.to_address, '')), '') is not null then
    -- the email this text replaced goes after all (the 0096 trigger queues it on the status change below)
    v_reason := 'not sent: fell back to email';
  else
    select * into m from app.text_email_of(o);
    if m.email is null then
      v_reason := 'not sent: no email to fall back to';
    else
      perform app.emit_event('text_fell_back', 'phone_outbox', o.id, jsonb_build_object(
        'signer_email', m.email, 'signer_user_id', m.user_id, 'signer_name', m.name, 'first_name', coalesce(nullif(m.name, ''), 'there'),
        'message_body', o.body, '_email_only', true, 'booking_id', o.booking_id), 'text_fell_back:' || o.id);
      v_reason := 'not sent: fell back to email';
    end if;
  end if;
  -- a text Quo refused stays failed (with the reason); one that was waiting is skipped
  update phone_outbox set status = case when o.status = 'failed' then 'failed' else 'skipped' end, locked_at = null,
         status_reason = left(v_reason || ' (' || coalesce(nullif(btrim(p_why), ''), 'refused') || ')', 300)
   where id = o.id;
  return v_reason;
end $$;

-- Admins: one alert a Toronto day while texts do not go
create function app.texts_alert(p_error text) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.staff_alert('texts_not_sending', 'phone_provider_state', null, to_char(app.local_date(now()), 'YYYYMMDD'),
    'Texts are not going out: they go by email instead',
    left(case when app.quo_account_error(p_error) then 'Quo refused for its account (' || coalesce(p_error, '') || '). Top up Quo: Settings > Billing > Add credits. Texts waiting fall back to email; none is sent late.'
              else 'Quo refused: ' || coalesce(p_error, '') || '. Texts that cannot go are emailed instead.' end, 240),
    jsonb_build_object('path_admin', '/admin/messages'));
end $$;

-- the 0096 fallback trigger leaves the drops of this migration alone (a stale or irrelevant text gets no late email)
select pg_temp.patch_fn('app.sms_fallback_email()'::regprocedure,
  $o$if new.kind = 'notify' and new.notification_id is not null and new.status in ('skipped', 'failed') and old.status not in ('skipped', 'failed') then$o$,
  $n$if new.kind = 'notify' and new.notification_id is not null and new.status in ('skipped', 'failed') and old.status not in ('skipped', 'failed')
     and coalesce(new.status_reason, '') not like 'not sent: stale%' and coalesce(new.status_reason, '') not like 'not sent: no longer relevant%'
     and coalesce(new.status_reason, '') not like 'not sent: the email already%' and coalesce(new.status_reason, '') not like 'not sent: staff%' then$n$);

-- the result of a send: a refusal that ends the text falls back to email; Quo's account refusal pauses texts
alter function app.server_phone_sent(jsonb) rename to server_phone_sent_pre3110;
create function app.server_phone_sent(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_err text := left(p ->> 'error', 300);
  v_acct boolean := not v_ok and app.quo_account_error(v_err);
  o phone_outbox;
begin
  r := app.server_phone_sent_pre3110(case when v_acct then p || jsonb_build_object('permanent', true) else p end);
  if v_ok then
    update phone_provider_state set quo_ok_at = now(), updated_at = now() where id and app.quo_paused();
    return r;
  end if;
  if v_acct then
    update phone_provider_state set quo_failed_at = now(), quo_error = v_err, updated_at = now() where id;
    perform app.texts_alert(v_err);
  end if;
  select * into o from phone_outbox where id = (p ->> 'id')::uuid;
  -- a staff member's own text (kind staff) is answered on their screen at once; it is not emailed without them
  if o.id is not null and o.status = 'failed' and o.kind <> 'staff' then
    perform app.text_fall_back(o.id, v_err);
    if not v_acct then perform app.texts_alert(v_err); end if;
    r := r || jsonb_build_object('status', 'skipped', 'fell_back', true);
  end if;
  return r;
end $$;
select pg_temp.copy_grants('app.server_phone_sent(jsonb)'::regprocedure, 'app.server_phone_sent_pre3110(jsonb)'::regprocedure);

-- is this waiting text still worth sending
create function app.text_drop_reason(o phone_outbox, p_now timestamptz default now()) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  b bookings;
  n notification_outbox;
  v_code text := coalesce(o.sms_kind, '');
begin
  if o.kind = 'staff' then return null; end if;
  if o.created_at < p_now - make_interval(mins => s.text_stale_minutes) and o.send_after < p_now - make_interval(mins => s.text_stale_minutes) then
    return 'not sent: stale (waited over ' || s.text_stale_minutes || ' minutes; never sent late)';
  end if;
  if o.notification_id is not null then
    select * into n from notification_outbox where id = o.notification_id;
    if n.status = 'sent' then return 'not sent: the email already covers it'; end if;
  end if;
  if o.booking_id is not null then
    select * into b from bookings where id = o.booking_id;
    if b.status::text in ('cancelled', 'no_show', 'expired', 'declined') then return 'not sent: no longer relevant (booking ' || b.status::text || ')'; end if;
    if v_code ~ '(pickup|booking_reminder|offer_ready|offer_sent|payment_link|deposit)' and (b.status::text in ('on_rent', 'returned', 'closed') or b.pickup_at < p_now) then
      return 'not sent: no longer relevant (the pickup has passed)';
    end if;
    if v_code ~ '(return)' and (b.status::text in ('returned', 'closed') or b.return_at < p_now - interval '1 hour') then
      return 'not sent: no longer relevant (the car is back)';
    end if;
  end if;
  return null;
end $$;

-- before texts are claimed: stale and irrelevant ones are dropped; while Quo is paused every due text falls back at
-- once, except one probe every text_retry_paused_minutes
alter function app.server_phone_due(integer) rename to server_phone_due_pre3110;
create function app.server_phone_due(p_limit integer default 20) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  o phone_outbox;
  v_why text;
  v_probe boolean := false;
  v_dropped integer := 0;
  v_fell integer := 0;
  r jsonb;
begin
  for o in select * from phone_outbox where status = 'queued' and send_after <= now() order by send_after limit greatest(p_limit, 1) * 5 for update skip locked loop
    v_why := app.text_drop_reason(o);
    if v_why is not null then
      update phone_outbox set status = 'skipped', locked_at = null, status_reason = left(v_why, 300) where id = o.id;
      v_dropped := v_dropped + 1;
    end if;
  end loop;
  if app.quo_paused() then
    select coalesce(q.quo_probe_at, '-infinity') < now() - make_interval(mins => s.text_retry_paused_minutes) into v_probe from phone_provider_state q;
    for o in select * from phone_outbox where status = 'queued' and send_after <= now() and kind <> 'staff'
              order by send_after offset case when v_probe then 1 else 0 end limit greatest(p_limit, 1) * 5 for update skip locked loop
      perform app.text_fall_back(o.id, 'Quo is refusing texts: ' || coalesce((select quo_error from phone_provider_state), 'its account'));
      v_fell := v_fell + 1;
    end loop;
    if not v_probe then
      return jsonb_build_object('texts', '[]'::jsonb, 'summaries', '[]'::jsonb, 'ai', app.phone_ai_budget(), 'from', app.phone_our_number(), 'paused', true, 'dropped', v_dropped, 'fell_back', v_fell);
    end if;
    update phone_provider_state set quo_probe_at = now() where id;
    r := app.server_phone_due_pre3110(1);
    return r || jsonb_build_object('paused', true, 'probe', true, 'dropped', v_dropped, 'fell_back', v_fell);
  end if;
  return app.server_phone_due_pre3110(p_limit) || jsonb_build_object('dropped', v_dropped);
end $$;
select pg_temp.copy_grants('app.server_phone_due(integer)'::regprocedure, 'app.server_phone_due_pre3110(integer)'::regprocedure);

-- ================================================================ 3. Amazon SES in its sandbox
alter table email_provider_state add column if not exists ses_sandbox_at timestamptz;
comment on column email_provider_state.ses_sandbox_at is 'Last refusal of SES for a recipient it has not verified (3110): the account is in its sandbox until AWS grants production access.';
alter function app.server_ses_email_result(jsonb) rename to server_ses_email_result_pre3110;
create function app.server_ses_email_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce((p ->> 'sandbox')::boolean, false) then
    insert into email_provider_state default values on conflict do nothing;
    update email_provider_state set ses_sandbox_at = now(), ses_error = left(p ->> 'error', 300), updated_at = now() where id;
    perform app.staff_alert('ses_sandbox', 'email_provider_state', null, to_char(app.local_date(now()), 'YYYYMMDD'),
      'Amazon SES is in its sandbox: emails go through Resend''s 100 a day',
      'SES refuses every address it has not verified. AWS console, region Canada (Central): Amazon SES > Account dashboard > Request production access (transactional).',
      jsonb_build_object('path_admin', '/admin/settings/usage'));
    return jsonb_build_object('ses_left', app.ses_email_left(now()), 'ses_try', app.ses_email_try(now()), 'sandbox', true);
  end if;
  return app.server_ses_email_result_pre3110(p);
end $$;
select pg_temp.copy_grants('app.server_ses_email_result(jsonb)'::regprocedure, 'app.server_ses_email_result_pre3110(jsonb)'::regprocedure);

-- ================================================================ 4. phone alerts stay on
create table if not exists push_lost (
  id          bigserial primary key,
  user_id     uuid not null references users (id) on delete cascade,
  endpoint    text not null,
  device      text,
  reason      text not null,
  at          timestamptz not null default now(),
  resolved_at timestamptz
);
create index if not exists push_lost_user_idx on push_lost (user_id, at desc);
create index if not exists push_lost_endpoint_idx on push_lost (endpoint, at desc);
alter table push_lost enable row level security;
revoke all on push_lost from anon, authenticated;
grant all on push_lost to service_role;
create policy admin_all on push_lost for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_push_lost after insert or update or delete on push_lost for each row execute function app.audit_row('redact');
comment on table push_lost is 'Phone alerts (3110): every device that stopped getting alerts and why (turned_off: the person; expired, refused, another_person, too_many: not them). The portal tells the person; the browser subscribes again by itself unless they turned it off.';

create function app.push_lost_log() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if tg_op = 'DELETE' then
    insert into push_lost (user_id, endpoint, device, reason)
    values (old.user_id, old.endpoint, old.device, coalesce(nullif(current_setting('app.push_lost_reason', true), ''), 'removed'));
    return old;
  end if;
  if new.user_id is distinct from old.user_id then
    insert into push_lost (user_id, endpoint, device, reason) values (old.user_id, old.endpoint, old.device, 'another_person');
  end if;
  return new;
end $$;
drop trigger if exists push_subscriptions_lost on push_subscriptions;
create trigger push_subscriptions_lost after delete or update of user_id on push_subscriptions for each row execute function app.push_lost_log();

-- the person's own Turn off (or Remove on another device) is the only reason a device stays off
alter function app.push_unsubscribe(uuid, jsonb) rename to push_unsubscribe_pre3110;
create function app.push_unsubscribe(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('app.push_lost_reason', 'turned_off', true);
  return app.push_unsubscribe_pre3110(p_user, p);
end $$;
select pg_temp.copy_grants('app.push_unsubscribe(uuid, jsonb)'::regprocedure, 'app.push_unsubscribe_pre3110(uuid, jsonb)'::regprocedure);

-- p.auto: the browser subscribing again by itself (its permission still granted). Refused for a device its person
-- turned off; any subscribe resolves the person's lost devices.
alter function app.push_subscribe(uuid, jsonb) rename to push_subscribe_pre3110;
create function app.push_subscribe(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_ep text := case when p ->> 'kind' = 'fcm' then 'fcm:' || btrim(coalesce(p ->> 'token', '')) else btrim(coalesce(p ->> 'endpoint', '')) end;
  r jsonb;
begin
  if coalesce((p ->> 'auto')::boolean, false)
     and (select l.reason from push_lost l where l.user_id = p_user and l.endpoint = v_ep order by l.at desc, l.id desc limit 1) = 'turned_off'
     and not exists (select 1 from push_subscriptions s where s.endpoint = v_ep and s.user_id = p_user) then
    return app.push_state(p_user, v_ep) || jsonb_build_object('auto_refused', true);
  end if;
  perform set_config('app.push_lost_reason', 'too_many', true);
  r := app.push_subscribe_pre3110(p_user, p - 'auto');
  perform set_config('app.push_lost_reason', '', true);
  update push_lost set resolved_at = now() where user_id = p_user and resolved_at is null and reason <> 'turned_off';
  return app.push_state(p_user, v_ep);
end $$;
select pg_temp.copy_grants('app.push_subscribe(uuid, jsonb)'::regprocedure, 'app.push_subscribe_pre3110(uuid, jsonb)'::regprocedure);

-- the push services' answers: a device dropped there is recorded as expired (not turned off)
alter function app.server_push_result(jsonb) rename to server_push_result_pre3110;
create function app.server_push_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb;
begin
  perform set_config('app.push_lost_reason', 'expired', true);
  r := app.server_push_result_pre3110(p);
  perform set_config('app.push_lost_reason', '', true);
  return r;
end $$;
select pg_temp.copy_grants('app.server_push_result(jsonb)'::regprocedure, 'app.server_push_result_pre3110(jsonb)'::regprocedure);

-- the card and the prompt: a device of this person that stopped without them turning it off
alter function app.push_state(uuid, text) rename to push_state_pre3110;
create function app.push_state(p_user uuid, p_endpoint text default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.push_state_pre3110(p_user, p_endpoint) || jsonb_build_object(
    'lost', (select jsonb_build_object('at', l.at, 'reason', l.reason, 'device', l.device, 'this', l.endpoint = p_endpoint)
               from push_lost l where l.user_id = p_user and l.resolved_at is null and l.reason <> 'turned_off' and l.at > now() - interval '30 days'
               order by l.at desc, l.id desc limit 1),
    'turned_off_here', case when p_endpoint is null then null else
      coalesce((select l.reason = 'turned_off' from push_lost l where l.user_id = p_user and l.endpoint = p_endpoint order by l.at desc, l.id desc limit 1), false) end)
$$;
select pg_temp.copy_grants('app.push_state(uuid, text)'::regprocedure, 'app.push_state_pre3110(uuid, text)'::regprocedure);

-- ================================================================ 5 and 6. suspended staff, staff notices off
alter table users add column if not exists staff_notices_off boolean not null default false;
comment on column users.staff_notices_off is 'Staff notifications (emails, texts, phone alerts of staff audiences) turned off for this person (3110).';
alter table staff_profiles add column if not exists restore_token uuid unique;
comment on column staff_profiles.restore_token is 'The restore link of a suspended account (3110): staff-restore?t=<token> asks the Admins for access back.';

create table if not exists staff_restore_requests (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references users (id) on delete cascade,
  requested_at timestamptz not null default now(),
  decided_at   timestamptz,
  decided_by   uuid references users (id),
  decision     text check (decision in ('restored', 'closed'))
);
create unique index if not exists staff_restore_requests_open on staff_restore_requests (user_id) where decided_at is null;
alter table staff_restore_requests enable row level security;
revoke all on staff_restore_requests from anon, authenticated;
grant all on staff_restore_requests to service_role;
create policy admin_all on staff_restore_requests for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_staff_restore_requests after insert or update or delete on staff_restore_requests for each row execute function app.audit_row();
comment on table staff_restore_requests is 'A suspended staff member asking for access back (3110). Unlock on Staff restores them and closes the request.';

-- why this staff notice must not reach this person (null: it may)
create function app.staff_notice_block(p_user uuid, p_code text) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when p_user is null or app.user_is_admin(p_user) then null
    when coalesce((select u.staff_notices_off from users u where u.id = p_user), false) then 'not sent: staff notifications turned off'
    when p_code in ('staff_access_suspended', 'staff_access_restored') then null
    when exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.inactive_locked_at is not null) then 'not sent: staff access suspended'
  end
$$;

create function app.outbox_staff_block() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_why text;
begin
  if new.audience like 'staff%' and new.recipient_user_id is not null and new.status in ('queued', 'delayed', 'skipped') then
    v_why := app.staff_notice_block(new.recipient_user_id, new.code);
    if v_why is not null then new.status := 'suppressed'; new.status_reason := v_why; new.sms_planned := false; end if;
  end if;
  return new;
end $$;
drop trigger if exists notification_outbox_zz_staff_block on notification_outbox;
create trigger notification_outbox_zz_staff_block before insert on notification_outbox for each row execute function app.outbox_staff_block();

create function app.push_staff_block() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from push_subscriptions ps where ps.id = new.subscription_id and coalesce(ps.portal, 'staff') in ('staff', 'field', 'admin'))
     and app.staff_notice_block(new.user_id, null) is not null then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists push_outbox_staff_block on push_outbox;
create trigger push_outbox_staff_block before insert on push_outbox for each row execute function app.push_staff_block();

-- a staff text (a notice to a staff member) waiting for someone suspended or with notices off is dropped
create function app.phone_staff_block() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_why text;
begin
  if new.status = 'queued' and new.user_id is not null and new.kind = 'notify'
     and (new.notification_id is null or exists (select 1 from notification_outbox n where n.id = new.notification_id and n.audience like 'staff%')) then
    v_why := app.staff_notice_block(new.user_id, new.sms_kind);
    if v_why is not null then new.status := 'skipped'; new.status_reason := left(v_why, 300); end if;
  end if;
  return new;
end $$;
drop trigger if exists phone_outbox_zz_staff_block on phone_outbox;
create trigger phone_outbox_zz_staff_block before insert or update of user_id, status on phone_outbox for each row execute function app.phone_staff_block();

-- suspended: the restore link and the one email; restored: the other email, the request closed
create function app.staff_suspension_mail() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_first text;
begin
  if app.user_is_admin(new.user_id) then return new; end if;
  select coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'there') into v_first from users u where u.id = new.user_id;
  if old.inactive_locked_at is null and new.inactive_locked_at is not null then
    update staff_profiles set restore_token = gen_random_uuid() where user_id = new.user_id and restore_token is null;
    perform app.emit_event('staff_access_suspended', 'user', new.user_id, jsonb_build_object('recipient_user_id', new.user_id, 'first_name', v_first,
      'restore_url', rtrim(s.notify_base_url, '/') || '/staff-restore?t=' || (select restore_token from staff_profiles where user_id = new.user_id)),
      'staff_access_suspended:' || new.user_id || ':' || to_char(new.inactive_locked_at, 'YYYYMMDDHH24MISS'));
  elsif old.inactive_locked_at is not null and new.inactive_locked_at is null then
    update staff_profiles set restore_token = null where user_id = new.user_id;
    update staff_restore_requests set decided_at = now(), decided_by = new.inactive_unlocked_by, decision = 'restored' where user_id = new.user_id and decided_at is null;
    perform app.emit_event('staff_access_restored', 'user', new.user_id, jsonb_build_object('recipient_user_id', new.user_id, 'first_name', v_first,
      'sign_in_url', rtrim(s.notify_base_url, '/') || '/sign-in?next=/staff'), 'staff_access_restored:' || new.user_id || ':' || to_char(now(), 'YYYYMMDDHH24MISS'));
  end if;
  return new;
end $$;
drop trigger if exists staff_profiles_suspension_mail on staff_profiles;
create trigger staff_profiles_suspension_mail after update of inactive_locked_at on staff_profiles for each row execute function app.staff_suspension_mail();

-- the restore link: a request to the Admins (one open request a person; the answer is the same whether or not the
-- token is good, so the page reveals nothing)
create function public.server_staff_restore_request(p_token uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  sp staff_profiles;
  v_name text;
  v_new boolean := false;
begin
  select * into sp from staff_profiles where restore_token = p_token and inactive_locked_at is not null;
  if sp.user_id is null then return jsonb_build_object('ok', true); end if;
  insert into staff_restore_requests (user_id) values (sp.user_id) on conflict do nothing returning true into v_new;
  if coalesce(v_new, false) then
    select coalesce(u.full_name, u.email) into v_name from users u where u.id = sp.user_id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (sp.user_id, 'staff_restore_requested', 'staff_profiles', sp.user_id::text, '{}'::jsonb);
    perform app.staff_alert('staff_restore_requested', 'user', sp.user_id, 'restore:' || sp.user_id || ':' || to_char(now(), 'YYYYMMDD'),
      left(format('%s asks for staff access back', v_name), 140), format('Suspended since %s. Unlock on Staff restores them.', app.fmt_at(sp.inactive_locked_at)),
      jsonb_build_object('path_admin', '/admin/staff'));
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- after a sign-in refused for a suspended account: its restore link
create function public.server_staff_restore_token(p_user uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v uuid;
begin
  update staff_profiles set restore_token = coalesce(restore_token, gen_random_uuid()) where user_id = p_user and inactive_locked_at is not null returning restore_token into v;
  return v;
end $$;

-- the inactivity job of 1060: 5 days, counted from staff_inactive_grace_from at the earliest; "suspended" in its words
create or replace function app.job_staff_inactivity(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r record;
  n_warn integer := 0;
  n_lock integer := 0;
begin
  for r in select sp.user_id, greatest(app.staff_last_active(sp), coalesce(s.staff_inactive_grace_from, '-infinity')) last_at, sp.inactive_warned_at,
                  coalesce(u.full_name, u.email) name,
                  coalesce(nullif(btrim(u.greeting_name), ''), split_part(btrim(coalesce(u.full_name, '')), ' ', 1)) first_name
             from staff_profiles sp join users u on u.id = sp.user_id
            where sp.inactive_locked_at is null and app.staff_is_member(sp.user_id) and not app.user_is_admin(sp.user_id) loop
    if r.last_at < p_now - make_interval(days => s.staff_inactive_lock_days) then
      update staff_profiles set inactive_locked_at = p_now, lock_reason = 'inactivity' where user_id = r.user_id;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
      values (null, 'staff_inactive_locked', 'staff_profiles', r.user_id::text, jsonb_build_object('last_active', r.last_at, 'days', s.staff_inactive_lock_days));
      perform app.staff_alert('staff_inactive_locked', 'user', r.user_id, 'locked:' || to_char(p_now, 'YYYYMMDD'),
        left(format('%s was suspended for inactivity', r.name), 140), format('No use of the portal since %s. They can ask for access back; Unlock on Staff restores them.', app.fmt_at(r.last_at)),
        jsonb_build_object('path_admin', '/admin/staff'));
      n_lock := n_lock + 1;
    elsif r.last_at < p_now - make_interval(days => s.staff_inactive_warn_days) and (r.inactive_warned_at is null or r.inactive_warned_at < r.last_at) then
      perform app.emit_event('staff_inactivity_warning', 'user', r.user_id, jsonb_build_object('recipient_user_id', r.user_id, 'first_name', coalesce(nullif(r.first_name, ''), 'there'),
        'days_idle', s.staff_inactive_warn_days::text, 'lock_days', s.staff_inactive_lock_days::text,
        'lock_on', to_char((r.last_at + make_interval(days => s.staff_inactive_lock_days)) at time zone 'America/Toronto', 'FMDay, FMMonth FMDD'),
        'sign_in_url', rtrim(s.notify_base_url, '/') || '/sign-in?next=/staff'), 'staff_inactivity_warning:' || r.user_id || ':' || to_char(r.last_at, 'YYYYMMDDHH24'));
      update staff_profiles set inactive_warned_at = p_now where user_id = r.user_id;
      n_warn := n_warn + 1;
    end if;
  end loop;
  return format('%s warned, %s suspended for inactivity', n_warn, n_lock);
end $$;

-- the suspension, restored and warning emails go by themselves, never folded into the staff email digest (a suspended
-- person's digest is not sent)
select pg_temp.patch_fn('app.staff_email_own(text)'::regprocedure,
  $o$'staff_commission_paid')$o$, $n$'staff_commission_paid', 'staff_access_suspended', 'staff_access_restored', 'staff_inactivity_warning')$n$);

-- ================================================================ 6. Dwight Laird: staff notifications off (he asked)
do $$
declare v uuid;
begin
  select id into v from users where lower(email) = 'dwightlair@gmail.com';
  if v is null then return; end if;
  update users set staff_notices_off = true where id = v and not staff_notices_off;
  if found then
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'staff_notices_off', 'users', v::text, jsonb_build_object('reason', 'He asked to stop getting staff notifications (the owner, release 48 CM)'));
    update notification_outbox set status = 'suppressed', status_reason = 'not sent: staff notifications turned off'
     where recipient_user_id = v and audience like 'staff%' and status in ('queued', 'delayed');
    update phone_outbox set status = 'skipped', status_reason = 'not sent: staff notifications turned off' where user_id = v and kind = 'notify' and status = 'queued';
    delete from push_outbox where user_id = v and status = 'queued';
  end if;
end $$;

-- ================================================================ 7. this week's townhall did not happen: nobody missed it
do $$
declare
  v_at timestamptz := timestamptz '2026-11-18 13:00 America/Toronto';
  m record;
begin
  for m in select meeting_at from townhall_meetings
            where meeting_at >= timestamptz '2026-11-16 00:00 America/Toronto' and meeting_at < timestamptz '2026-11-23 00:00 America/Toronto' and not not_held loop
    perform app.townhall_not_held_apply(m.meeting_at, null, 'Most staff could not use the portal this week (release 48 CM)');
  end loop;
  if not exists (select 1 from townhall_meetings where meeting_at = v_at) then
    perform app.townhall_not_held_apply(v_at, null, 'Most staff could not use the portal this week (release 48 CM)');
  end if;
end $$;

-- ================================================================ 8. the interview the owner missed this week: the next open slot
do $$
declare
  a job_applications;
  sl record;
  r jsonb;
  v_done boolean;
begin
  for a in select x.* from job_applications x join interview_slots y on y.id = x.slot_id
            where y.starts_at >= timestamptz '2026-11-16 00:00 America/Toronto' and y.starts_at < least(now(), timestamptz '2026-11-23 00:00 America/Toronto')
              and x.purged_at is null and x.interviewed_at is null
              and (x.status = 'booked' or (x.status = 'no_show' and x.decided_by is null)) loop
    if a.status = 'no_show' then update job_applications set status = 'booked', updated_at = now() where id = a.id; end if;
    v_done := false;
    for sl in select s.id from interview_slots s join interview_days d on d.id = s.day_id
               where d.active and s.starts_at > now() + interval '1 hour' and (d.role_ids is null or a.role_id = any (d.role_ids))
                 and (select count(*) from job_applications z where z.slot_id = s.id and z.status = 'booked') < s.capacity
               order by s.starts_at limit 20 loop
      r := app.hiring_book(a.token, sl.id);
      if coalesce((r ->> 'ok')::boolean, false) then
        insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
        values (null, 'interview_moved', 'job_applications', a.id::text, jsonb_build_object('reason', 'the owner missed the call (release 48 CM)', 'starts_at', r ->> 'starts_at'));
        v_done := true;
        exit;
      end if;
    end loop;
    if not v_done then
      perform app.staff_alert('interview_no_slot', 'job_application', a.id, a.id::text,
        left(format('No open interview slot to move %s''s call to', a.full_name), 140), 'Add interview times on Hiring; the candidate keeps their booking link to pick one.',
        jsonb_build_object('path_admin', '/admin/hiring/' || a.id));
    end if;
  end loop;
end $$;

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['quo_account_error', 'quo_paused', 'text_email_of', 'text_fall_back', 'texts_alert', 'text_drop_reason',
                     'server_phone_sent', 'server_phone_sent_pre3110', 'server_phone_due', 'server_phone_due_pre3110', 'server_ses_email_result', 'server_ses_email_result_pre3110',
                     'push_lost_log', 'push_unsubscribe_pre3110', 'push_subscribe_pre3110', 'server_push_result_pre3110', 'push_state_pre3110',
                     'staff_notice_block', 'outbox_staff_block', 'push_staff_block', 'phone_staff_block', 'staff_suspension_mail', 'job_staff_inactivity']))
               or (n.nspname = 'public' and p.proname = any (array['server_staff_restore_request', 'server_staff_restore_token'])) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 9. the academy: Work chats on every staff path; staff who had
-- passed everything get 7 days before it holds them (as 2990), the others are held as before
create temp table r48cm_done on commit drop as select distinct e.user_id from academy_enrollments e where app.academy_done(e.user_id);
-- ACADEMY 3110 START (generated by supabase/seed/3110_gen.mjs; do not edit by hand)
insert into academy_sections (slug, title, blurb, guide_refs) values ('r48-work-chats', 'Work chats', 'All work communication happens in the group work chats, never in private messages.', array['va/start-here', 'field/start-here']::text[]) on conflict (slug) do update set title = excluded.title, blurb = excluded.blurb, guide_refs = excluded.guide_refs, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'r48-work-chats'), 1, 'Work talk goes in the group', '[{"caption":"One place for work","say":"Every work conversation happens in the group work chats: the CarmaCars Team and Sales WhatsApp groups, and the chats in the portal. Never in private messages.","visual":{"kind":"title","heading":"Work chats only","text":"Groups, never private messages"}},{"caption":"Why","say":"In the group the whole team sees the question, the answer and the customer details. When someone is off, nothing is lost and nobody waits for one person.","visual":{"kind":"list","heading":"In the group","items":["Questions and answers","Handovers and problems","Customer details and bookings","Shift changes"]}},{"caption":"A private message about work","say":"If a colleague or an Admin writes to you privately about work, answer in the group so everyone sees it.","visual":{"kind":"chat","lines":[{"who":"colleague","text":"(private) Can you cover the 3 pm handover?"},{"who":"you","text":"Answering in the Team group so everyone sees it: yes, I can take the 3 pm handover."}]}},{"caption":"The rule","say":"Work communication in the group work chats, every time.","visual":{"kind":"rule","heading":"Group work chats only","text":"Never private messages for work.","tone":"warn"}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r48-work-chats'), 1, 'Where does work communication happen?', '["In private messages to the person","In the group work chats","By personal email","Wherever is fastest"]'::jsonb, 1, 'All work communication happens in the group work chats, never in private messages.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r48-work-chats'), 2, 'A colleague messages you privately about a handover. What do you do?', '["Answer privately","Ignore it","Answer in the group work chat","Call them on your own phone"]'::jsonb, 2, 'Answer in the group so the whole team sees it.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r48-work-chats'), 3, 'Why does work talk go in the group?', '["It is faster to type","The whole team sees it and nothing is lost when someone is away","Admins like long chats","Private messages cost money"]'::jsonb, 1, 'In the group everyone sees the question, the answer and the details, so nobody waits for one person.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r48-work-chats'), 4, 'A renter''s booking details need to reach a colleague. Where do you share them?', '["In a private message","In the group work chat or the booking in the portal","By text from your own phone","Nowhere"]'::jsonb, 1, 'Customer details go in the group work chats or the portal, never in private messages.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'r48-work-chats'), 5, 'Which chats count as work chats?', '["Any chat app","The CarmaCars Team and Sales WhatsApp groups and the chats in the portal","Private messages with your lead","Your personal email"]'::jsonb, 1, 'The group work chats: the Team and Sales WhatsApp groups, and the chats in the portal.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_path_sections (path_code, section_id, sort) select 'cs', (select id from academy_sections where slug = 'r48-work-chats'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'cs' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'fleet', (select id from academy_sections where slug = 'r48-work-chats'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'fleet' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'finance', (select id from academy_sections where slug = 'r48-work-chats'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'finance' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'sales_in_person', (select id from academy_sections where slug = 'r48-work-chats'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'sales_in_person' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'sales_remote', (select id from academy_sections where slug = 'r48-work-chats'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'sales_remote' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'field', (select id from academy_sections where slug = 'r48-work-chats'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'field' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'admin', (select id from academy_sections where slug = 'r48-work-chats'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'admin' on conflict (path_code, section_id) do nothing;
-- ACADEMY 3110 END
update academy_enrollments e set lock_from = greatest(e.lock_from, now() + interval '7 days') from r48cm_done d where e.user_id = d.user_id and e.gate;

-- GUIDES 3110 START (generated by supabase/seed/3110_gen.mjs; do not edit by hand)
select app.guide_release_section('admin', 'people-and-access', 'chapter', 'getting-around-admin', 'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

> Good to know: The site''s own test accounts (verify- addresses and Resend''s test inboxes) are marked "Test account" in People who can sign in. They sign in like anyone, but no real work is ever given to them (see Data health).

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Add an investor

1. Open **People** > **Investors** and press **Add an investor**.
2. Fill in the Legal name and the Type: Individual, or Corporation with the Person who signs for the corporation. Then the Email, the Phone and the Address (start typing and choose it).
3. Optional: the Amount committed, and the Yearly return offered (the investor offer''s, 30% unless you change it; the investment agreement sets the one that applies).
4. Invite now is ticked: press **Add and invite**. The record is added and the investor gets the invitation to choose a password for the investor portal. Untick it to add the record only, and invite later from the list.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Logs**, the **Changes** tab, shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Team** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. **Home address** here changes it if it is wrong.
7. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |

## Sales staff: in person or remote

Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.

1. Press **Work mode** on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.
2. The list shows the mode, the rate now, the rate the month would end at, and for remote this month''s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.
3. On a remote person''s Sales page, Remote duties shows their checklist, touches, blocks and reply time. **Void** beside a touch logged by mistake takes it off, with a reason.
4. When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.

|  | Rule |
| --- | --- |
| Rates | In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15% |
| Credit | In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing |
| Remote minimum | 400 touches a month. Under it, when the month ends, the month''s rate is one tier lower (5% becomes 2.5%). Settings > Program settings, Staff commissions, changes the minimum, the drop and the floor |

## An Admin has every staff page

An Admin account is only an Admin: it already has every page of the staff portals, so no office or field role can be added to it, and the invite form and Staff and roles refuse it. To work as staff, use a separate account. An Admin can still be given a field job and opens it on the field portal.
## Two records of one person

When two renter records are clearly the same person (the same phone verified with a code, or the same name, date of birth and phone), the site merges them by itself within 15 minutes, into the record with more bookings. Bookings, licences, cards, payments, documents and messages move. The person can then sign in with either email or with their phone number and a code, and gets one short note: "Your CarmaCars accounts are now one". A match on the name alone stays a task for you, and **Merge into this record** under the renter still works as before.

1. Open the renter. The Merged records card lists each merge, automatic or by staff, with what moved and the emails that now sign in there.
2. Two different people after all? Press **Undo** and say why. Everything moved goes back and both records are as they were.

## New staff: the academy, then the agreement, then the portal

Every staff member (never an Admin) opens their portal in this order: the academy first, then their staff agreement, then everything else. Until the academy is passed they open only the academy, the guide, their profile and **Welcome**; after it, until the agreement is signed, only Welcome, their profile and their documents to sign.

1. The agreement is sent by itself to everyone without one, filled from their record and their hire''s pay and start date: the Field Staff Agreement for field work, the contractor agreement for customer service, Fleet, Finance and Sales (in person or remote). One reminder goes 3 days after it was sent.
2. **Team** > **Staff and roles**, **Staff agreements**: who has not signed, what the automatic send waits for (for example a field hire''s licence number), and **Waive** with the reason.
3. Welcome also asks for the name they go by (the preferred name, shown across the portals and on the staff list), and, once the academy and the agreement are done, shows the team''s WhatsApp group (Program settings, **WhatsApp team group link** and **WhatsApp Sales group link**; empty until you set them). The same link goes by email, once.

## Accounts locked for inactivity

A staff account with no sign-in or use for 10 days (Program settings, **Staff inactive lock days**) is locked; the person is warned by email on day 7 and sees "Account locked for inactivity" when they sign in. You get an alert. On **Team** > **Staff and roles** the row says **Locked for inactivity**: press **Unlock**. The staff list shows each person''s last sign-in. Admin accounts are never locked.

## Hours and the townhall

**Team** > **Timesheet**: the hours customer service, Fleet and Finance clocked (Clock in and out on their home page). Add hours someone forgot, or void a wrong entry, with the reason. A person not clocked in 15 minutes after their start time (customer service 9:00, Fleet 11:00, Toronto) is reminded.

**Breaks and idle time (release 35).** Customer service, Fleet and Finance press **Start break** and **End break** next to the clock; breaks have no fixed length. On **Timesheet**, each person''s days show the hours clocked and worked, their breaks (how many, the total and the longest) and their idle time, with every break and idle stretch listed. **Edit** or **Remove** a break with the reason (in the audit log). Finance sees the breaks but never the idle time. A break open past 30 minutes reminds the person and you. Whether breaks are paid is **Program settings** > va_breaks_paid (on: salaried; off: breaks come off the hours on the payroll, where each line shows the period''s breaks).

While someone is clocked in, not on a break and within their scheduled hours, the portal notes the fact of their activity (never keys, pages or screens), at most once a minute; their actions count too. With no activity for more than va_idle_alert_minutes (10), you get one alert, "Name (role) inactive since 10:42, 12 min", and one more at va_idle_followup_minutes (30). A call they are on (their Quo user, set with **Set Quo user** on Timesheet; the **Call** button; a note in the caller pop-up) and the townhall (joined or present, to its end plus 10 minutes) pause it. **KPIs** shows **Idle minutes** against kpi_idle_minutes_week.

**Team** > **Townhall**: the weekly staff call (Wednesdays at 1:00 pm Toronto). The deck builds itself every Sunday night from the week''s data: the week, platform updates, fleet, staff, sales with the leaderboard, finances and claims (the last two for Admins only). Add a note to any slide; **Build again** refreshes the numbers. Set the call link in Program settings; staff add the call to their calendar from the page.

## The townhall day, attendance and the team slide (release 35)

1. The townhall is every Wednesday at 1:00 pm Toronto time. To change it, press **Change the day or time** on the Townhall page. Beside it, a table shows the website''s visitor sessions of the last 8 weeks for each day, as information. Field applicants'' live calls always take the hour before.
2. Every staff member is invited and reminded an hour before. **Join the call** on the townhall page, or **Check in** from 15 minutes before, counts them as there.
3. When the call ends, the people who missed it are recorded, the staff list shows "Missed N townhalls" for the last 8 weeks, and you get an alert with the names.
4. The deck''s last slide is the team: a tile per person with their role''s numbers for the week. Press **Add a shout-out** on a tile to add yours.

## Where staff live (release 35)

Welcome asks every hire for their city and country. In the Toronto area Sales keep the mode they were hired in; elsewhere Sales is remote. The staff list shows the location.

## Staff onboarding, breaks and shifts (release 35)

- New staff open their portal after four steps in order: the academy, the staff agreement, confirming the team''s WhatsApp groups, then an Admin''s or a Fleet VA''s approval (or a rejection with a reason the person sees). Everyone already working waits for the same approval once.
- Each person''s row on the Staff onboarding card in Settings and on the Fleet approvals list says exactly what is missing, for example "Waiting on: Academy (3 of 11 sections), Staff agreement signature". **Mark WhatsApp joined** records only the WhatsApp groups, at any step: it never passes the academy or signs the agreement, and it counts when the person reaches that step. Once the academy and the agreement are done, **Confirm WhatsApp and approve** marks the groups and approves in one press (Admins only, recorded in the audit log).
- Schedules: customer service, Fleet and Finance have a schedule per role, and an Admin can give one person their own. Today''s duty board shows who is working, late or absent.
- Breaks: office staff log a break from their home page, and the time on break is kept on their timesheet. While someone is on a break, on a call or in the townhall, the idle alert is paused; otherwise a person with no activity for a while on a shift gets an alert, then the Admins do.
- Quiet hours: staff alerts held by a person''s quiet hours arrive as one summary when they end, and no text goes to a renter at night (an answer asked for then arrives in the morning).
- Field staff set their availability (mornings, afternoons and evenings for each weekday) on Welcome and later on My shifts or Profile; Fleet and Admin see it on the shift board.
- Standing weekly shifts are claimed by themselves up to two weeks ahead; the minimum shifts a week is a Program setting (2 in 7 days), and anyone under it gets a reminder and a To do.
- Shifts are published by themselves every hour from the shift template in Program settings (Field jobs and handovers: one shift of 10:00 to 17:00 for one person, every second day, up to 14 days ahead, only forward from the latest shift already published and never before the start date set there). A handover or return no shift covers gets a shift of its own, 90 minutes either side.
- A published shift nobody has claimed 48 hours before it starts alerts Fleet and the Admins with the people to ask.
- Payroll runs every two weeks: Finance prepares it, an Admin approves it and records the payments. KPIs per role are on Team, KPIs, each against a target in Program settings.
- The townhall is every Wednesday at 1:00 pm Toronto time; two missed in a row lock the account until an Admin restores it. A townhall that did not happen (nobody attended, cancelled ahead, or marked by an Admin) counts nobody absent.', 'People and access', 'Portals and sign-in, invitations, password links, View as, staff and scorecards.',
  'Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.

## Portals and sign-in

Open **People** > **Portals and view as**. Every portal has a card.

1. Each card links to **Its sign-in page**, the address to send that person.
2. Choose a person in the list on the card.
3. Press **Open as this person** to see that portal as they see it.

> Good to know: The site''s own test accounts (verify- addresses and Resend''s test inboxes) are marked "Test account" in People who can sign in. They sign in like anyone, but no real work is ever given to them (see Data health).

![](/guides/img/admin-27-portals-desktop-0361bf61.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/portals; pins: 1 65.9 30.2, 2 58.1 39.4, 3 51.6 45.6")

## Invite a person

Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.

1. Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.
2. Fill in the Name and Email.
3. For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.
4. Press **Invite**. The link in the email works for 24 hours.

![](/guides/img/admin-27-portals-desktop-c10725cb.jpg "desktop; size: 1230 360; address: carmacars.ca/admin/portals; pins: 1 18.8 40.8, 2 50.0 40.8, 3 18.8 66.7, 4 9.8 87.8")

> Tip: Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People > Owners and People > Investors also have a one-click invite for a record without a sign-in.

## Add an investor

1. Open **People** > **Investors** and press **Add an investor**.
2. Fill in the Legal name and the Type: Individual, or Corporation with the Person who signs for the corporation. Then the Email, the Phone and the Address (start typing and choose it).
3. Optional: the Amount committed, and the Yearly return offered (the investor offer''s, 30% unless you change it; the investment agreement sets the one that applies).
4. Invite now is ticked: press **Add and invite**. The record is added and the investor gets the invitation to choose a password for the investor portal. Untick it to add the record only, and invite later from the list.

## Send a password link

For anyone who forgot their password or let their invitation expire.

1. Under People who can sign in, search by name or email.
2. On their row, press **Send password link**. They get "Reset your CarmaCars password", valid for 24 hours.
3. **View as (...)** on the same row opens their portal, read only.

![](/guides/img/admin-27-portals-desktop-ee9b3e94.jpg "desktop; size: 1230 440; address: carmacars.ca/admin/portals; pins: 1 74.8 6.6, 2 68.2 28.6, 3 84.1 28.6")

## View as: see what someone sees

1. A red banner says "Viewing as Name (email), read only." on every page.
2. Click around their portal. Nothing can be changed: every save is refused.
3. Press **Exit** to come back. A view also ends by itself after 30 minutes.

![](/guides/img/admin-28-view-as-desktop-f858e38c.jpg "desktop; size: 1440 620; address: carmacars.ca/owner; pins: 1 48.6 4.5, 3 94.4 4.5")

> Watch out: Can''t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.

## The audit log

**Settings** > **Logs**, the **Changes** tab, shows who changed what, and when.

1. Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.
2. Every View as is recorded (view_as_start), with the person viewed.
3. Search by table, record id or value.

![](/guides/img/admin-29-audit-desktop-b7504100.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/audit; pins: 1 22.6 31.1, 2 39.0 46.4, 3 89.6 20.7")

## Staff and roles

**People** > **Team** opens Staff and roles.

1. Invite staff here too: Role, Name, Email, Main function and Also covers, then **Invite**.
2. Each row has **Send password link**, **View as (...)** and Limits (how much they may approve or refund).
3. Press **End access** to close their staff portal at once. **Restore** undoes it.

![](/guides/img/admin-26-staff-desktop-72287d0b.jpg "desktop; size: 1440 780; address: carmacars.ca/admin/settings/staff; pins: 1 20.8 59.0, 2 94.4 86.7, 3 83.3 92.6")

## Admin access

**Settings**, then Admin access. Who may hold the Admin role.

1. The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site''s nightly checks sign in with.
2. Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.
3. Change the list only if the business''s Admin address changes.

## Staff scorecards

See how each assistant is doing against the targets.

1. On a staff member''s row in Staff and roles, press **Scorecard**.
2. By week shows each measure (for example quote sent within 5 minutes) and the result for each week.
3. A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.

![](/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg "desktop; size: 1230 350; address: carmacars.ca/va/scorecard; pins: 2 21.1 42.9")

## Sales by staff member

See each person''s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.

1. On a staff member''s row in Staff and roles, press **Sales**. Press **By week** or **By month**.
2. The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.
3. Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.
4. A deal credited to the wrong person, or marked sourced when it was not? Press **Reassign** beside it, choose who, say whether they sourced the client, and write the reason.
5. **Commission rate** gives this person their own flat rate (empty: the Program settings). **Reverse** beside a commission stops it, for example for a household rental found later.
6. Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. **Home address** here changes it if it is wrong.
7. The whole team: **Today** > **Overview**, the Sales card at the bottom. Choose another month and press **Show**.

| Figure | How it is counted |
| --- | --- |
| Credited to | Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it. |
| Conversion | Of the deals credited in the period, the share confirmed so far. |
| Booked revenue | The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off. |

## Sales staff: in person or remote

Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.

1. Press **Work mode** on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.
2. The list shows the mode, the rate now, the rate the month would end at, and for remote this month''s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.
3. On a remote person''s Sales page, Remote duties shows their checklist, touches, blocks and reply time. **Void** beside a touch logged by mistake takes it off, with a reason.
4. When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.

|  | Rule |
| --- | --- |
| Rates | In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15% |
| Credit | In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing |
| Remote minimum | 400 touches a month. Under it, when the month ends, the month''s rate is one tier lower (5% becomes 2.5%). Settings > Program settings, Staff commissions, changes the minimum, the drop and the floor |

## An Admin has every staff page

An Admin account is only an Admin: it already has every page of the staff portals, so no office or field role can be added to it, and the invite form and Staff and roles refuse it. To work as staff, use a separate account. An Admin can still be given a field job and opens it on the field portal.
## Two records of one person

When two renter records are clearly the same person (the same phone verified with a code, or the same name, date of birth and phone), the site merges them by itself within 15 minutes, into the record with more bookings. Bookings, licences, cards, payments, documents and messages move. The person can then sign in with either email or with their phone number and a code, and gets one short note: "Your CarmaCars accounts are now one". A match on the name alone stays a task for you, and **Merge into this record** under the renter still works as before.

1. Open the renter. The Merged records card lists each merge, automatic or by staff, with what moved and the emails that now sign in there.
2. Two different people after all? Press **Undo** and say why. Everything moved goes back and both records are as they were.

## New staff: the academy, then the agreement, then the portal

Every staff member (never an Admin) opens their portal in this order: the academy first, then their staff agreement, then everything else. Until the academy is passed they open only the academy, the guide, their profile and **Welcome**; after it, until the agreement is signed, only Welcome, their profile and their documents to sign.

1. The agreement is sent by itself to everyone without one, filled from their record and their hire''s pay and start date: the Field Staff Agreement for field work, the contractor agreement for customer service, Fleet, Finance and Sales (in person or remote). One reminder goes 3 days after it was sent.
2. **Team** > **Staff and roles**, **Staff agreements**: who has not signed, what the automatic send waits for (for example a field hire''s licence number), and **Waive** with the reason.
3. Welcome also asks for the name they go by (the preferred name, shown across the portals and on the staff list), and, once the academy and the agreement are done, shows the team''s WhatsApp group (Program settings, **WhatsApp team group link** and **WhatsApp Sales group link**; empty until you set them). The same link goes by email, once.

## Accounts locked for inactivity

A staff account with no sign-in or use for 10 days (Program settings, **Staff inactive lock days**) is locked; the person is warned by email on day 7 and sees "Account locked for inactivity" when they sign in. You get an alert. On **Team** > **Staff and roles** the row says **Locked for inactivity**: press **Unlock**. The staff list shows each person''s last sign-in. Admin accounts are never locked.

## Hours and the townhall

**Team** > **Timesheet**: the hours customer service, Fleet and Finance clocked (Clock in and out on their home page). Add hours someone forgot, or void a wrong entry, with the reason. A person not clocked in 15 minutes after their start time (customer service 9:00, Fleet 11:00, Toronto) is reminded.

**Breaks and idle time (release 35).** Customer service, Fleet and Finance press **Start break** and **End break** next to the clock; breaks have no fixed length. On **Timesheet**, each person''s days show the hours clocked and worked, their breaks (how many, the total and the longest) and their idle time, with every break and idle stretch listed. **Edit** or **Remove** a break with the reason (in the audit log). Finance sees the breaks but never the idle time. A break open past 30 minutes reminds the person and you. Whether breaks are paid is **Program settings** > va_breaks_paid (on: salaried; off: breaks come off the hours on the payroll, where each line shows the period''s breaks).

While someone is clocked in, not on a break and within their scheduled hours, the portal notes the fact of their activity (never keys, pages or screens), at most once a minute; their actions count too. With no activity for more than va_idle_alert_minutes (10), you get one alert, "Name (role) inactive since 10:42, 12 min", and one more at va_idle_followup_minutes (30). A call they are on (their Quo user, set with **Set Quo user** on Timesheet; the **Call** button; a note in the caller pop-up) and the townhall (joined or present, to its end plus 10 minutes) pause it. **KPIs** shows **Idle minutes** against kpi_idle_minutes_week.

**Team** > **Townhall**: the weekly staff call (Wednesdays at 1:00 pm Toronto). The deck builds itself every Sunday night from the week''s data: the week, platform updates, fleet, staff, sales with the leaderboard, finances and claims (the last two for Admins only). Add a note to any slide; **Build again** refreshes the numbers. Set the call link in Program settings; staff add the call to their calendar from the page.

## The townhall day, attendance and the team slide (release 35)

1. The townhall is every Wednesday at 1:00 pm Toronto time. To change it, press **Change the day or time** on the Townhall page. Beside it, a table shows the website''s visitor sessions of the last 8 weeks for each day, as information. Field applicants'' live calls always take the hour before.
2. Every staff member is invited and reminded an hour before. **Join the call** on the townhall page, or **Check in** from 15 minutes before, counts them as there.
3. When the call ends, the people who missed it are recorded, the staff list shows "Missed N townhalls" for the last 8 weeks, and you get an alert with the names.
4. The deck''s last slide is the team: a tile per person with their role''s numbers for the week. Press **Add a shout-out** on a tile to add yours.

## Where staff live (release 35)

Welcome asks every hire for their city and country. In the Toronto area Sales keep the mode they were hired in; elsewhere Sales is remote. The staff list shows the location.

## Staff onboarding, breaks and shifts (release 35)

- New staff open their portal after four steps in order: the academy, the staff agreement, confirming the team''s WhatsApp groups, then an Admin''s or a Fleet VA''s approval (or a rejection with a reason the person sees). Everyone already working waits for the same approval once.
- Each person''s row on the Staff onboarding card in Settings and on the Fleet approvals list says exactly what is missing, for example "Waiting on: Academy (3 of 11 sections), Staff agreement signature". **Mark WhatsApp joined** records only the WhatsApp groups, at any step: it never passes the academy or signs the agreement, and it counts when the person reaches that step. Once the academy and the agreement are done, **Confirm WhatsApp and approve** marks the groups and approves in one press (Admins only, recorded in the audit log).
- Schedules: customer service, Fleet and Finance have a schedule per role, and an Admin can give one person their own. Today''s duty board shows who is working, late or absent.
- Breaks: office staff log a break from their home page, and the time on break is kept on their timesheet. While someone is on a break, on a call or in the townhall, the idle alert is paused; otherwise a person with no activity for a while on a shift gets an alert, then the Admins do.
- Quiet hours: staff alerts held by a person''s quiet hours arrive as one summary when they end, and no text goes to a renter at night (an answer asked for then arrives in the morning).
- Field staff set their availability (mornings, afternoons and evenings for each weekday) on Welcome and later on My shifts or Profile; Fleet and Admin see it on the shift board.
- Standing weekly shifts are claimed by themselves up to two weeks ahead; the minimum shifts a week is a Program setting (2 in 7 days), and anyone under it gets a reminder and a To do.
- Shifts are published by themselves every hour from the shift template in Program settings (Field jobs and handovers: one shift of 10:00 to 17:00 for one person, every second day, up to 14 days ahead, only forward from the latest shift already published and never before the start date set there). A handover or return no shift covers gets a shift of its own, 90 minutes either side.
- A published shift nobody has claimed 48 hours before it starts alerts Fleet and the Admins with the people to ask.
- Payroll runs every two weeks: Finance prepares it, an Admin approves it and records the payments. KPIs per role are on Team, KPIs, each against a target in Program settings.
- The townhall is every Wednesday at 1:00 pm Toronto time; two missed in a row lock the account until an Admin restores it. A townhall that did not happen (nobody attended, cancelled ahead, or marked by an Admin) counts nobody absent.

## Work chats only

All staff work communication happens in the group work chats (the CarmaCars Team and Sales WhatsApp groups, and the chats in the portal), never in private messages. It is in every staff guide and in the academy (Work chats). Answer a private work message in the group.
',
  '<p class="gd-p">Let people in, help them back in when they are locked out, and see exactly what they see. Every step is recorded in the audit log.</p><section class="gd-task" id="people-and-access-portals-and-sign-in" data-gd-task><h2 class="gd-h2">Portals and sign-in</h2><p class="gd-p">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Portals and view as</b>. Every portal has a card.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each card links to <b class="gd-ui">Its sign-in page</b>, the address to send that person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose a person in the list on the card.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Open as this person</b> to see that portal as they see it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The site&#39;s own test accounts (verify- addresses and Resend&#39;s test inboxes) are marked &quot;Test account&quot; in People who can sign in. They sign in like anyone, but no real work is ever given to them (see Data health).</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-27-portals-desktop-0361bf61.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:65.9%;top:30.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:58.1%;top:39.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:51.6%;top:45.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-invite-a-person" data-gd-task><h2 class="gd-h2">Invite a person</h2><p class="gd-p">Invitations work for staff, field staff, owners and investors. The person gets our invitation email and chooses a password.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under Invite a person, choose the Role: Staff (assistant), Field staff, Owner on file or Investor on file. Admin is not offered: only rent@carmacars.ca can be an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in the Name and Email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For staff, pick the Main function, and tick Also covers for any other function they help with. For field staff, pick the Field function.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Invite</b>. The link in the email works for 24 hours.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/360"><img src="/guides/img/admin-27-portals-desktop-c10725cb.jpg" alt="" loading="lazy" decoding="async" width="1230" height="360"><span class="gd-pin" style="left:18.8%;top:40.8%" aria-hidden="true">1</span><span class="gd-pin" style="left:50%;top:40.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.8%;top:66.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:9.8%;top:87.8%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Someone who already signs in gets the new role at once, with no email. Owners and investors must be on file first: People &gt; Owners and People &gt; Investors also have a one-click invite for a record without a sign-in.</div></aside></section><section class="gd-task" id="people-and-access-add-an-investor" data-gd-task><h2 class="gd-h2">Add an investor</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and press <b class="gd-ui">Add an investor</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in the Legal name and the Type: Individual, or Corporation with the Person who signs for the corporation. Then the Email, the Phone and the Address (start typing and choose it).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Optional: the Amount committed, and the Yearly return offered (the investor offer&#39;s, 30% unless you change it; the investment agreement sets the one that applies).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Invite now is ticked: press <b class="gd-ui">Add and invite</b>. The record is added and the investor gets the invitation to choose a password for the investor portal. Untick it to add the record only, and invite later from the list.</div></li></ol></div></section><section class="gd-task" id="people-and-access-send-a-password-link" data-gd-task><h2 class="gd-h2">Send a password link</h2><p class="gd-p">For anyone who forgot their password or let their invitation expire.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Under People who can sign in, search by name or email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">On their row, press <b class="gd-ui">Send password link</b>. They get &quot;Reset your CarmaCars password&quot;, valid for 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">View as (...)</b> on the same row opens their portal, read only.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/portals</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/440"><img src="/guides/img/admin-27-portals-desktop-ee9b3e94.jpg" alt="" loading="lazy" decoding="async" width="1230" height="440"><span class="gd-pin" style="left:74.8%;top:6.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:68.2%;top:28.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.1%;top:28.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-view-as-see-what-someone-sees" data-gd-task><h2 class="gd-h2">View as: see what someone sees</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A red banner says &quot;Viewing as Name (email), read only.&quot; on every page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Click around their portal. Nothing can be changed: every save is refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Exit</b> to come back. A view also ends by itself after 30 minutes.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/620"><img src="/guides/img/admin-28-view-as-desktop-f858e38c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="620"><span class="gd-pin" style="left:48.6%;top:4.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:4.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Can&#39;t change anything in Admin? You may still be viewing as someone. Look for the red banner and press Exit.</div></aside></section><section class="gd-task" id="people-and-access-the-audit-log" data-gd-task><h2 class="gd-h2">The audit log</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Logs</b>, the <b class="gd-ui">Changes</b> tab, shows who changed what, and when.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Changes lists every change with the person, the action, the table and the record. Data access lists lookups of private data.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every View as is recorded (view_as_start), with the person viewed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Search by table, record id or value.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/audit</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-29-audit-desktop-b7504100.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:22.6%;top:31.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:39%;top:46.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:89.6%;top:20.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-staff-and-roles" data-gd-task><h2 class="gd-h2">Staff and roles</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Team</b> opens Staff and roles.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Invite staff here too: Role, Name, Email, Main function and Also covers, then <b class="gd-ui">Invite</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row has <b class="gd-ui">Send password link</b>, <b class="gd-ui">View as (...)</b> and Limits (how much they may approve or refund).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">End access</b> to close their staff portal at once. <b class="gd-ui">Restore</b> undoes it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/staff</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/780"><img src="/guides/img/admin-26-staff-desktop-72287d0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="780"><span class="gd-pin" style="left:20.8%;top:59%" aria-hidden="true">1</span><span class="gd-pin" style="left:94.4%;top:86.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:83.3%;top:92.6%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-admin-access" data-gd-task><h2 class="gd-h2">Admin access</h2><p class="gd-p"><b class="gd-ui">Settings</b>, then Admin access. Who may hold the Admin role.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list holds rent@carmacars.ca, and verify-admin@carmacars.ca, the automated test account the site&#39;s nightly checks sign in with.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Below it: everyone who holds the Admin role now. Each must be on the list; the database refuses the Admin role to any other address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change the list only if the business&#39;s Admin address changes.</div></li></ol></div></section><section class="gd-task" id="people-and-access-staff-scorecards" data-gd-task><h2 class="gd-h2">Staff scorecards</h2><p class="gd-p">See how each assistant is doing against the targets.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure (for example quote sent within 5 minutes) and the result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when it is done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/350"><img src="/guides/img/va-sales-05-scorecard-desktop-956a5a9e.jpg" alt="" loading="lazy" decoding="async" width="1230" height="350"><span class="gd-pin" style="left:21.1%;top:42.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="people-and-access-sales-by-staff-member" data-gd-task><h2 class="gd-h2">Sales by staff member</h2><p class="gd-p">See each person&#39;s commissions, quotes, offers, rentals added, bookings confirmed and booked revenue.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On a staff member&#39;s row in Staff and roles, press <b class="gd-ui">Sales</b>. Press <b class="gd-ui">By week</b> or <b class="gd-ui">By month</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The tiles show the current week or month. By week (or By month) lists each period: quotes created, offers sent, rentals added, bookings confirmed, conversion and booked revenue.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Follow-ups due lists their open deals with the next step. Deals lists each booking they created, added or sent an offer on, with what it counts.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A deal credited to the wrong person, or marked sourced when it was not? Press <b class="gd-ui">Reassign</b> beside it, choose who, say whether they sourced the client, and write the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Commission rate</b> gives this person their own flat rate (empty: the Program settings). <b class="gd-ui">Reverse</b> beside a commission stops it, for example for a household rental found later.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Staff enter their own home address (at their first sign-in, before they sign their agreement, or in their profile). It is needed before they add a rental or earn a commission, and spots a household rental. <b class="gd-ui">Home address</b> here changes it if it is wrong.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The whole team: <b class="gd-ui">Today</b> &gt; <b class="gd-ui">Overview</b>, the Sales card at the bottom. Choose another month and press <b class="gd-ui">Show</b>.</div></li></ol></div><div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table"><table class="gd-table"><thead><tr><th scope="col">Figure</th><th scope="col">How it is counted</th></tr></thead><tbody><tr><td>Credited to</td><td>Whoever created the quote or added the rental; for a website request, whoever sent its first offer. An Admin can reassign it.</td></tr><tr><td>Conversion</td><td>Of the deals credited in the period, the share confirmed so far.</td></tr><tr><td>Booked revenue</td><td>The rental charge before tax, after discounts, for bookings confirmed in the period. A cancelled booking counts only what was kept; refunds come off.</td></tr></tbody></table></div></section><section class="gd-task" id="people-and-access-sales-staff-in-person-or-remote" data-gd-task><h2 class="gd-h2">Sales staff: in person or remote</h2><p class="gd-p">Each Sales person works in person (Toronto) or remote (anywhere, a contractor). Staff and roles lists them under Sales staff: in person or remote.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Work mode</b> on a person (or on their Sales page), choose In person or Remote and give the reason. A new Sales person starts in person.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The list shows the mode, the rate now, the rate the month would end at, and for remote this month&#39;s touches against 400, the peak hours scheduled this week (20 needed, Thursday to Sunday afternoons) and the replies on time.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On a remote person&#39;s Sales page, Remote duties shows their checklist, touches, blocks and reply time. <b class="gd-ui">Void</b> beside a touch logged by mistake takes it off, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">When you approve a Sales month, its mode, rates, touches and any drop are locked: a later change of mode or settings does not change it. Their My sales shows each month in one line.</div></li></ol></div><div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Rule</th></tr></thead><tbody><tr><td>Rates</td><td>In person 10%, 15% from 50 rental days, 20% from 100. Remote 5 points lower on every tier: 5%, 10%, 15%</td></tr><tr><td>Credit</td><td>In person: walk-ins, handovers, partner visits and the rentals they source. Remote: only the rentals they source; a website request they answer with the first offer during their blocks is credited to them; a walk-in or a partner deal earns them nothing</td></tr><tr><td>Remote minimum</td><td>400 touches a month. Under it, when the month ends, the month&#39;s rate is one tier lower (5% becomes 2.5%). Settings &gt; Program settings, Staff commissions, changes the minimum, the drop and the floor</td></tr></tbody></table></div></section><section class="gd-task" id="people-and-access-an-admin-has-every-staff-page" data-gd-task><h2 class="gd-h2">An Admin has every staff page</h2><p class="gd-p">An Admin account is only an Admin: it already has every page of the staff portals, so no office or field role can be added to it, and the invite form and Staff and roles refuse it. To work as staff, use a separate account. An Admin can still be given a field job and opens it on the field portal.</p></section><section class="gd-task" id="people-and-access-two-records-of-one-person" data-gd-task><h2 class="gd-h2">Two records of one person</h2><p class="gd-p">When two renter records are clearly the same person (the same phone verified with a code, or the same name, date of birth and phone), the site merges them by itself within 15 minutes, into the record with more bookings. Bookings, licences, cards, payments, documents and messages move. The person can then sign in with either email or with their phone number and a code, and gets one short note: &quot;Your CarmaCars accounts are now one&quot;. A match on the name alone stays a task for you, and <b class="gd-ui">Merge into this record</b> under the renter still works as before.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the renter. The Merged records card lists each merge, automatic or by staff, with what moved and the emails that now sign in there.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Two different people after all? Press <b class="gd-ui">Undo</b> and say why. Everything moved goes back and both records are as they were.</div></li></ol></div></section><section class="gd-task" id="people-and-access-new-staff-the-academy-then-the-agreement-then-the-portal" data-gd-task><h2 class="gd-h2">New staff: the academy, then the agreement, then the portal</h2><p class="gd-p">Every staff member (never an Admin) opens their portal in this order: the academy first, then their staff agreement, then everything else. Until the academy is passed they open only the academy, the guide, their profile and <b class="gd-ui">Welcome</b>; after it, until the agreement is signed, only Welcome, their profile and their documents to sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The agreement is sent by itself to everyone without one, filled from their record and their hire&#39;s pay and start date: the Field Staff Agreement for field work, the contractor agreement for customer service, Fleet, Finance and Sales (in person or remote). One reminder goes 3 days after it was sent.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Team</b> &gt; <b class="gd-ui">Staff and roles</b>, <b class="gd-ui">Staff agreements</b>: who has not signed, what the automatic send waits for (for example a field hire&#39;s licence number), and <b class="gd-ui">Waive</b> with the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Welcome also asks for the name they go by (the preferred name, shown across the portals and on the staff list), and, once the academy and the agreement are done, shows the team&#39;s WhatsApp group (Program settings, <b class="gd-ui">WhatsApp team group link</b> and <b class="gd-ui">WhatsApp Sales group link</b>; empty until you set them). The same link goes by email, once.</div></li></ol></div></section><section class="gd-task" id="people-and-access-accounts-locked-for-inactivity" data-gd-task><h2 class="gd-h2">Accounts locked for inactivity</h2><p class="gd-p">A staff account with no sign-in or use for 10 days (Program settings, <b class="gd-ui">Staff inactive lock days</b>) is locked; the person is warned by email on day 7 and sees &quot;Account locked for inactivity&quot; when they sign in. You get an alert. On <b class="gd-ui">Team</b> &gt; <b class="gd-ui">Staff and roles</b> the row says <b class="gd-ui">Locked for inactivity</b>: press <b class="gd-ui">Unlock</b>. The staff list shows each person&#39;s last sign-in. Admin accounts are never locked.</p></section><section class="gd-task" id="people-and-access-hours-and-the-townhall" data-gd-task><h2 class="gd-h2">Hours and the townhall</h2><p class="gd-p"><b class="gd-ui">Team</b> &gt; <b class="gd-ui">Timesheet</b>: the hours customer service, Fleet and Finance clocked (Clock in and out on their home page). Add hours someone forgot, or void a wrong entry, with the reason. A person not clocked in 15 minutes after their start time (customer service 9:00, Fleet 11:00, Toronto) is reminded.</p><p class="gd-p"><b class="gd-ui">Breaks and idle time (release 35).</b> Customer service, Fleet and Finance press <b class="gd-ui">Start break</b> and <b class="gd-ui">End break</b> next to the clock; breaks have no fixed length. On <b class="gd-ui">Timesheet</b>, each person&#39;s days show the hours clocked and worked, their breaks (how many, the total and the longest) and their idle time, with every break and idle stretch listed. <b class="gd-ui">Edit</b> or <b class="gd-ui">Remove</b> a break with the reason (in the audit log). Finance sees the breaks but never the idle time. A break open past 30 minutes reminds the person and you. Whether breaks are paid is <b class="gd-ui">Program settings</b> &gt; va_breaks_paid (on: salaried; off: breaks come off the hours on the payroll, where each line shows the period&#39;s breaks).</p><p class="gd-p">While someone is clocked in, not on a break and within their scheduled hours, the portal notes the fact of their activity (never keys, pages or screens), at most once a minute; their actions count too. With no activity for more than va_idle_alert_minutes (10), you get one alert, &quot;Name (role) inactive since 10:42, 12 min&quot;, and one more at va_idle_followup_minutes (30). A call they are on (their Quo user, set with <b class="gd-ui">Set Quo user</b> on Timesheet; the <b class="gd-ui">Call</b> button; a note in the caller pop-up) and the townhall (joined or present, to its end plus 10 minutes) pause it. <b class="gd-ui">KPIs</b> shows <b class="gd-ui">Idle minutes</b> against kpi_idle_minutes_week.</p><p class="gd-p"><b class="gd-ui">Team</b> &gt; <b class="gd-ui">Townhall</b>: the weekly staff call (Wednesdays at 1:00 pm Toronto). The deck builds itself every Sunday night from the week&#39;s data: the week, platform updates, fleet, staff, sales with the leaderboard, finances and claims (the last two for Admins only). Add a note to any slide; <b class="gd-ui">Build again</b> refreshes the numbers. Set the call link in Program settings; staff add the call to their calendar from the page.</p></section><section class="gd-task" id="people-and-access-the-townhall-day-attendance-and-the-team-slide-release-35" data-gd-task><h2 class="gd-h2">The townhall day, attendance and the team slide (release 35)</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The townhall is every Wednesday at 1:00 pm Toronto time. To change it, press <b class="gd-ui">Change the day or time</b> on the Townhall page. Beside it, a table shows the website&#39;s visitor sessions of the last 8 weeks for each day, as information. Field applicants&#39; live calls always take the hour before.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Every staff member is invited and reminded an hour before. <b class="gd-ui">Join the call</b> on the townhall page, or <b class="gd-ui">Check in</b> from 15 minutes before, counts them as there.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When the call ends, the people who missed it are recorded, the staff list shows &quot;Missed N townhalls&quot; for the last 8 weeks, and you get an alert with the names.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The deck&#39;s last slide is the team: a tile per person with their role&#39;s numbers for the week. Press <b class="gd-ui">Add a shout-out</b> on a tile to add yours.</div></li></ol></div></section><section class="gd-task" id="people-and-access-where-staff-live-release-35" data-gd-task><h2 class="gd-h2">Where staff live (release 35)</h2><p class="gd-p">Welcome asks every hire for their city and country. In the Toronto area Sales keep the mode they were hired in; elsewhere Sales is remote. The staff list shows the location.</p></section><section class="gd-task" id="people-and-access-staff-onboarding-breaks-and-shifts-release-35" data-gd-task><h2 class="gd-h2">Staff onboarding, breaks and shifts (release 35)</h2><ul class="gd-ul"><li>New staff open their portal after four steps in order: the academy, the staff agreement, confirming the team&#39;s WhatsApp groups, then an Admin&#39;s or a Fleet VA&#39;s approval (or a rejection with a reason the person sees). Everyone already working waits for the same approval once.</li><li>Each person&#39;s row on the Staff onboarding card in Settings and on the Fleet approvals list says exactly what is missing, for example &quot;Waiting on: Academy (3 of 11 sections), Staff agreement signature&quot;. <b class="gd-ui">Mark WhatsApp joined</b> records only the WhatsApp groups, at any step: it never passes the academy or signs the agreement, and it counts when the person reaches that step. Once the academy and the agreement are done, <b class="gd-ui">Confirm WhatsApp and approve</b> marks the groups and approves in one press (Admins only, recorded in the audit log).</li><li>Schedules: customer service, Fleet and Finance have a schedule per role, and an Admin can give one person their own. Today&#39;s duty board shows who is working, late or absent.</li><li>Breaks: office staff log a break from their home page, and the time on break is kept on their timesheet. While someone is on a break, on a call or in the townhall, the idle alert is paused; otherwise a person with no activity for a while on a shift gets an alert, then the Admins do.</li><li>Quiet hours: staff alerts held by a person&#39;s quiet hours arrive as one summary when they end, and no text goes to a renter at night (an answer asked for then arrives in the morning).</li><li>Field staff set their availability (mornings, afternoons and evenings for each weekday) on Welcome and later on My shifts or Profile; Fleet and Admin see it on the shift board.</li><li>Standing weekly shifts are claimed by themselves up to two weeks ahead; the minimum shifts a week is a Program setting (2 in 7 days), and anyone under it gets a reminder and a To do.</li><li>Shifts are published by themselves every hour from the shift template in Program settings (Field jobs and handovers: one shift of 10:00 to 17:00 for one person, every second day, up to 14 days ahead, only forward from the latest shift already published and never before the start date set there). A handover or return no shift covers gets a shift of its own, 90 minutes either side.</li><li>A published shift nobody has claimed 48 hours before it starts alerts Fleet and the Admins with the people to ask.</li><li>Payroll runs every two weeks: Finance prepares it, an Admin approves it and records the payments. KPIs per role are on Team, KPIs, each against a target in Program settings.</li><li>The townhall is every Wednesday at 1:00 pm Toronto time; two missed in a row lock the account until an Admin restores it. A townhall that did not happen (nobody attended, cancelled ahead, or marked by an Admin) counts nobody absent.</li></ul></section><section class="gd-task" id="people-and-access-work-chats-only" data-gd-task><h2 class="gd-h2">Work chats only</h2><p class="gd-p">All staff work communication happens in the group work chats (the CarmaCars Team and Sales WhatsApp groups, and the chats in the portal), never in private messages. It is in every staff guide and in the academy (Work chats). Answer a private work message in the group.</p></section>');
select app.guide_release_section('va', 'start-here', 'start', null, '### Who this guide is for

CarmaCars staff in Customer service, Finance, Fleet and Sales, in the office, remote or in person. Everyone works in one staff portal: its menu shows a group for each function you hold. Read chapter 1, then the chapter for each of your functions. If you also do field work (handovers, returns, moving cars), read the Field Guide too: your jobs are under **Field work** in the same menu.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Once you are hired

You are not working a shift right away. First your training (the academy), then you claim your shifts online in the portal.

1. Say hello in the team chat: the CarmaCars Team WhatsApp group (the link is in your portal once the academy and your agreement are done).
2. In each WhatsApp group you are in, set your member tag as "Name - Position", for example "Maria - Sales", so everyone knows who you are and what you do.

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Then on **Profile**, **Pay details**: choose how you are paid (bank account, GCash, PayPal, Wise, e-Transfer or through OnlineJobs.ph) and press **Save my pay details**. Only the last 4 digits of an account number are ever shown; an Admin confirms new details with you.
5. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
6. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.
7. Sign in with your phone: on **Profile**, press **Add and verify my phone number** and enter the 6-digit code we text you. Then press **Use my phone number instead** on the sign-in page. Two-step sign-in still asks for your authenticator code.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.

## Stuck on a page?

If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks **Need a hand with** the page. **Open the guide section** opens this guide at the chapter for that page beside it (a sheet from the bottom on a phone); **Back to what I was doing** closes it and everything you typed is still there. **Open the Academy lesson** opens the lesson in a new tab. **Not now** quiets it on that page for a day.

> Good to know: When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows **We''ve updated our terms**: a short summary of what changed and the new text. Tick that you read it and press **Accept** to continue. It does not change an agreement you already signed or a past booking.

## Your name and password (release 34)
Open Profile. **Save my display name** changes how you are greeted, at once. Your legal name is the one on your signed agreements, so it is not edited freely: press **Request a name change**, write the full name and why, and an Admin approves it. Until then the name on file stays. To change your email, use Change my email under Sign-in; to add or change your phone, use the phone box under Sign-in (we text a code). **Change my password** sends you to the password page.

## Report a bug (release 37)
Something not working? Press **Report a bug** at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (**Blocks my work** alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. **My bug reports** shows each report and its status: new, being looked at, fixed or won''t fix.', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars staff in Customer service, Finance, Fleet and Sales, in the office, remote or in person. Everyone works in one staff portal: its menu shows a group for each function you hold. Read chapter 1, then the chapter for each of your functions. If you also do field work (handovers, returns, moving cars), read the Field Guide too: your jobs are under **Field work** in the same menu.

### What you need

- The invitation email from CarmaCars (the link works for 24 hours)
- A computer for your shift. The portal also works on a phone
- An authenticator app on your phone, if your Admin turns on two-step sign-in

## Once you are hired

You are not working a shift right away. First your training (the academy), then you claim your shifts online in the portal.

1. Say hello in the team chat: the CarmaCars Team WhatsApp group (the link is in your portal once the academy and your agreement are done).
2. In each WhatsApp group you are in, set your member tag as "Name - Position", for example "Maria - Sales", so everyone knows who you are and what you do.

## Your first sign-in

1. Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press **Save the new password**.
2. You land in your portal, on **To do**, working as your main function.
3. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission. Change it later under **Profile**, at the top of the menu.
4. Then on **Profile**, **Pay details**: choose how you are paid (bank account, GCash, PayPal, Wise, e-Transfer or through OnlineJobs.ph) and press **Save my pay details**. Only the last 4 digits of an account number are ever shown; an Admin confirms new details with you.
5. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password, then **Sign in**.
6. Link expired? Press **Send me a new link** on the page it opens, or ask an Admin for a password link.
7. Sign in with your phone: on **Profile**, press **Add and verify my phone number** and enter the 6-digit code we text you. Then press **Use my phone number instead** on the sign-in page. Two-step sign-in still asks for your authenticator code.

![](/guides/img/public-09-sign-in-phone-1f766061.jpg "phone; size: 390 645; pins: 3 95.4 78.4")

> Good to know: Recommended: open your profile and press **Set up two-step sign-in**. Scan the code with your authenticator app, type the 6 digits and press **Continue**. After that every sign-in asks for a code.

## Stuck on a page?

If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks **Need a hand with** the page. **Open the guide section** opens this guide at the chapter for that page beside it (a sheet from the bottom on a phone); **Back to what I was doing** closes it and everything you typed is still there. **Open the Academy lesson** opens the lesson in a new tab. **Not now** quiets it on that page for a day.

> Good to know: When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows **We''ve updated our terms**: a short summary of what changed and the new text. Tick that you read it and press **Accept** to continue. It does not change an agreement you already signed or a past booking.

## Your name and password (release 34)
Open Profile. **Save my display name** changes how you are greeted, at once. Your legal name is the one on your signed agreements, so it is not edited freely: press **Request a name change**, write the full name and why, and an Admin approves it. Until then the name on file stays. To change your email, use Change my email under Sign-in; to add or change your phone, use the phone box under Sign-in (we text a code). **Change my password** sends you to the password page.

## Report a bug (release 37)
Something not working? Press **Report a bug** at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (**Blocks my work** alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. **My bug reports** shows each report and its status: new, being looked at, fixed or won''t fix.

## Work chats only

All work communication happens in the group work chats (the CarmaCars Team and Sales WhatsApp groups, and the chats in the portal), never in private messages. Questions, handovers, problems and customer details go in the group, so the whole team sees them and nothing is lost when someone is away. If a colleague or an Admin writes to you privately about work, answer in the group.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars staff in Customer service, Finance, Fleet and Sales, in the office, remote or in person. Everyone works in one staff portal: its menu shows a group for each function you hold. Read chapter 1, then the chapter for each of your functions. If you also do field work (handovers, returns, moving cars), read the Field Guide too: your jobs are under <b class="gd-ui">Field work</b> in the same menu.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A computer for your shift. The portal also works on a phone</li><li>An authenticator app on your phone, if your Admin turns on two-step sign-in</li></ul><section class="gd-task" id="start-here-once-you-are-hired" data-gd-task><h2 class="gd-h2">Once you are hired</h2><p class="gd-p">You are not working a shift right away. First your training (the academy), then you claim your shifts online in the portal.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Say hello in the team chat: the CarmaCars Team WhatsApp group (the link is in your portal once the academy and your agreement are done).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">In each WhatsApp group you are in, set your member tag as &quot;Name - Position&quot;, for example &quot;Maria - Sales&quot;, so everyone knows who you are and what you do.</div></li></ol></div></section><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email and press its link within 24 hours. Choose a password of 8 characters or more and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land in your portal, on <b class="gd-ui">To do</b>, working as your main function.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission. Change it later under <b class="gd-ui">Profile</b>, at the top of the menu.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then on <b class="gd-ui">Profile</b>, <b class="gd-ui">Pay details</b>: choose how you are paid (bank account, GCash, PayPal, Wise, e-Transfer or through OnlineJobs.ph) and press <b class="gd-ui">Save my pay details</b>. Only the last 4 digits of an account number are ever shown; an Admin confirms new details with you.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password, then <b class="gd-ui">Sign in</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Link expired? Press <b class="gd-ui">Send me a new link</b> on the page it opens, or ask an Admin for a password link.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Sign in with your phone: on <b class="gd-ui">Profile</b>, press <b class="gd-ui">Add and verify my phone number</b> and enter the 6-digit code we text you. Then press <b class="gd-ui">Use my phone number instead</b> on the sign-in page. Two-step sign-in still asks for your authenticator code.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/645"><img src="/guides/img/public-09-sign-in-phone-1f766061.jpg" alt="" loading="lazy" decoding="async" width="390" height="645"><span class="gd-pin" style="left:95.4%;top:78.4%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: open your profile and press <b class="gd-ui">Set up two-step sign-in</b>. Scan the code with your authenticator app, type the 6 digits and press <b class="gd-ui">Continue</b>. After that every sign-in asks for a code.</div></aside></section><section class="gd-task" id="start-here-stuck-on-a-page" data-gd-task><h2 class="gd-h2">Stuck on a page?</h2><p class="gd-p">If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks <b class="gd-ui">Need a hand with</b> the page. <b class="gd-ui">Open the guide section</b> opens this guide at the chapter for that page beside it (a sheet from the bottom on a phone); <b class="gd-ui">Back to what I was doing</b> closes it and everything you typed is still there. <b class="gd-ui">Open the Academy lesson</b> opens the lesson in a new tab. <b class="gd-ui">Not now</b> quiets it on that page for a day.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows <b class="gd-ui">We&#39;ve updated our terms</b>: a short summary of what changed and the new text. Tick that you read it and press <b class="gd-ui">Accept</b> to continue. It does not change an agreement you already signed or a past booking.</div></aside></section><section class="gd-task" id="start-here-your-name-and-password-release-34" data-gd-task><h2 class="gd-h2">Your name and password (release 34)</h2><p class="gd-p">Open Profile. <b class="gd-ui">Save my display name</b> changes how you are greeted, at once. Your legal name is the one on your signed agreements, so it is not edited freely: press <b class="gd-ui">Request a name change</b>, write the full name and why, and an Admin approves it. Until then the name on file stays. To change your email, use Change my email under Sign-in; to add or change your phone, use the phone box under Sign-in (we text a code). <b class="gd-ui">Change my password</b> sends you to the password page.</p></section><section class="gd-task" id="start-here-report-a-bug-release-37" data-gd-task><h2 class="gd-h2">Report a bug (release 37)</h2><p class="gd-p">Something not working? Press <b class="gd-ui">Report a bug</b> at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (<b class="gd-ui">Blocks my work</b> alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. <b class="gd-ui">My bug reports</b> shows each report and its status: new, being looked at, fixed or won&#39;t fix.</p></section><section class="gd-task" id="start-here-work-chats-only" data-gd-task><h2 class="gd-h2">Work chats only</h2><p class="gd-p">All work communication happens in the group work chats (the CarmaCars Team and Sales WhatsApp groups, and the chats in the portal), never in private messages. Questions, handovers, problems and customer details go in the group, so the whole team sees them and nothing is lost when someone is away. If a colleague or an Admin writes to you privately about work, answer in the group.</p></section>');
select app.guide_release_section('field', 'start-here', 'start', null, '### Who this guide is for

CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone. Your jobs are under **Field work** in the staff portal; if you also hold another function (Sales, for example), its pages are in the same menu.

### What you need

- Your phone, charged, with a data connection (photos and signatures save as you take them)
- The invitation email from CarmaCars (the link works for 24 hours)
- A car charger and a cloth for the camera lens

## Once you are hired

You are not working a shift right away. First your training (the academy), then you claim your shifts online in the portal.

1. Say hello in the team chat: the CarmaCars Team WhatsApp group (the link is in your portal once the academy and your agreement are done).
2. In each WhatsApp group you are in, set your member tag as "Name - Position", for example "Ali - Field".

## Your first sign-in

1. Open the invitation email on your phone and press its link within 24 hours. Choose a password and press **Save the new password**.
2. You land on **Today**. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password.
3. In your browser''s menu, choose **Add to Home Screen**. The portal then opens full screen, like an app.
4. Open **Profile**, add your mobile number and press **Save my phone**.
5. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission.

![](/guides/img/field-04-profile-phone-f05000e2.jpg "phone; size: 390 920; pins: 4 92.3 78.3")

> Good to know: Recommended: on Profile, press **Set up two-step sign-in** and follow the steps with an authenticator app.

## Stuck on a page?

If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks **Need a hand with** the page. **Open the guide section** opens this guide at the right chapter in a sheet from the bottom of the screen; **Back to what I was doing** closes it and everything you typed is still there. **Open the Academy lesson** opens the lesson in a new tab. **Not now** quiets it on that page for a day. It never shows while a renter signs.

> Good to know: When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows **We''ve updated our terms**: a short summary of what changed and the new text. Tick that you read it and press **Accept** to continue. It does not change an agreement you already signed or a past booking.

## Your first days

Your portal opens in order: the academy (Training) first, then your staff agreement, then your jobs. Welcome shows each step and asks for the name you go by. Once both are done, Welcome and Today show the team''s WhatsApp group: join it, then press **I joined**.

## The weekly townhall (release 35)

Every Wednesday at 1:00 pm Toronto time, and everyone attends. Open **Townhall**: **Join the call** there, or **Check in** from 15 minutes before, counts you as there. You get a reminder an hour before.

## Report a bug (release 37)
Something not working? Press **Report a bug** at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (**Blocks my work** alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. **My bug reports** shows each report and its status: new, being looked at, fixed or won''t fix.

## The weekly townhall card (release 41)

From the day before the weekly townhall until it ends, your home page shows the **Townhall** card: the day and time (Toronto), a countdown, **Join / check in** (it opens 15 minutes before; joining through it checks you in), **Add to calendar**, and a red line if you missed the last townhall: one more miss locks your account. You also get a reminder the day before at 10:00 am, the morning of at 9:00 am, an hour before, and 15 minutes before with the join link.', 'Start here', 'Who this is for and your first sign-in.',
  '### Who this guide is for

CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone. Your jobs are under **Field work** in the staff portal; if you also hold another function (Sales, for example), its pages are in the same menu.

### What you need

- Your phone, charged, with a data connection (photos and signatures save as you take them)
- The invitation email from CarmaCars (the link works for 24 hours)
- A car charger and a cloth for the camera lens

## Once you are hired

You are not working a shift right away. First your training (the academy), then you claim your shifts online in the portal.

1. Say hello in the team chat: the CarmaCars Team WhatsApp group (the link is in your portal once the academy and your agreement are done).
2. In each WhatsApp group you are in, set your member tag as "Name - Position", for example "Ali - Field".

## Your first sign-in

1. Open the invitation email on your phone and press its link within 24 hours. Choose a password and press **Save the new password**.
2. You land on **Today**. Next time, sign in at `carmacars.ca/sign-in` with your Email and Password.
3. In your browser''s menu, choose **Add to Home Screen**. The portal then opens full screen, like an app.
4. Open **Profile**, add your mobile number and press **Save my phone**.
5. At the top of the page, fill in your Home address and Postal code and press **Save my home address**. You need it before you add a rental or earn a commission.

![](/guides/img/field-04-profile-phone-f05000e2.jpg "phone; size: 390 920; pins: 4 92.3 78.3")

> Good to know: Recommended: on Profile, press **Set up two-step sign-in** and follow the steps with an authenticator app.

## Stuck on a page?

If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks **Need a hand with** the page. **Open the guide section** opens this guide at the right chapter in a sheet from the bottom of the screen; **Back to what I was doing** closes it and everything you typed is still there. **Open the Academy lesson** opens the lesson in a new tab. **Not now** quiets it on that page for a day. It never shows while a renter signs.

> Good to know: When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows **We''ve updated our terms**: a short summary of what changed and the new text. Tick that you read it and press **Accept** to continue. It does not change an agreement you already signed or a past booking.

## Your first days

Your portal opens in order: the academy (Training) first, then your staff agreement, then your jobs. Welcome shows each step and asks for the name you go by. Once both are done, Welcome and Today show the team''s WhatsApp group: join it, then press **I joined**.

## The weekly townhall (release 35)

Every Wednesday at 1:00 pm Toronto time, and everyone attends. Open **Townhall**: **Join the call** there, or **Check in** from 15 minutes before, counts you as there. You get a reminder an hour before.

## Report a bug (release 37)
Something not working? Press **Report a bug** at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (**Blocks my work** alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. **My bug reports** shows each report and its status: new, being looked at, fixed or won''t fix.

## The weekly townhall card (release 41)

From the day before the weekly townhall until it ends, your home page shows the **Townhall** card: the day and time (Toronto), a countdown, **Join / check in** (it opens 15 minutes before; joining through it checks you in), **Add to calendar**, and a red line if you missed the last townhall: one more miss locks your account. You also get a reminder the day before at 10:00 am, the morning of at 9:00 am, an hour before, and 15 minutes before with the join link.

## Work chats only

All work communication happens in the group work chats (the CarmaCars Team and Sales WhatsApp groups, and the chats in the portal), never in private messages. Questions, handovers, problems and customer details go in the group, so the whole team sees them and nothing is lost when someone is away. If a colleague or an Admin writes to you privately about work, answer in the group.
',
  '<h3 class="gd-h3">Who this guide is for</h3><p class="gd-p">CarmaCars field staff: drivers, detailers, and drivers who also detail. You hand cars over, take them back, move them and shoot listing photos. Everything is on your phone. Your jobs are under <b class="gd-ui">Field work</b> in the staff portal; if you also hold another function (Sales, for example), its pages are in the same menu.</p><h3 class="gd-h3">What you need</h3><ul class="gd-ul"><li>Your phone, charged, with a data connection (photos and signatures save as you take them)</li><li>The invitation email from CarmaCars (the link works for 24 hours)</li><li>A car charger and a cloth for the camera lens</li></ul><section class="gd-task" id="start-here-once-you-are-hired" data-gd-task><h2 class="gd-h2">Once you are hired</h2><p class="gd-p">You are not working a shift right away. First your training (the academy), then you claim your shifts online in the portal.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Say hello in the team chat: the CarmaCars Team WhatsApp group (the link is in your portal once the academy and your agreement are done).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">In each WhatsApp group you are in, set your member tag as &quot;Name - Position&quot;, for example &quot;Ali - Field&quot;.</div></li></ol></div></section><section class="gd-task" id="start-here-your-first-sign-in" data-gd-task><h2 class="gd-h2">Your first sign-in</h2><div class="gd-stepblock gd-stepblock--side"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the invitation email on your phone and press its link within 24 hours. Choose a password and press <b class="gd-ui">Save the new password</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">You land on <b class="gd-ui">Today</b>. Next time, sign in at <span class="gd-url">carmacars.ca/sign-in</span> with your Email and Password.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">In your browser&#39;s menu, choose <b class="gd-ui">Add to Home Screen</b>. The portal then opens full screen, like an app.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Open <b class="gd-ui">Profile</b>, add your mobile number and press <b class="gd-ui">Save my phone</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">At the top of the page, fill in your Home address and Postal code and press <b class="gd-ui">Save my home address</b>. You need it before you add a rental or earn a commission.</div></li></ol></div><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/920"><img src="/guides/img/field-04-profile-phone-f05000e2.jpg" alt="" loading="lazy" decoding="async" width="390" height="920"><span class="gd-pin" style="left:92.3%;top:78.3%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Recommended: on Profile, press <b class="gd-ui">Set up two-step sign-in</b> and follow the steps with an authenticator app.</div></aside></section><section class="gd-task" id="start-here-stuck-on-a-page" data-gd-task><h2 class="gd-h2">Stuck on a page?</h2><p class="gd-p">If you work on a page for a few minutes without anything saving, see the same error three times, or go back and forth between the same two steps, a small box asks <b class="gd-ui">Need a hand with</b> the page. <b class="gd-ui">Open the guide section</b> opens this guide at the right chapter in a sheet from the bottom of the screen; <b class="gd-ui">Back to what I was doing</b> closes it and everything you typed is still there. <b class="gd-ui">Open the Academy lesson</b> opens the lesson in a new tab. <b class="gd-ui">Not now</b> quiets it on that page for a day. It never shows while a renter signs.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>When we update our terms of use, our privacy policy or an agreement you signed with us, the next time you open your portal it shows <b class="gd-ui">We&#39;ve updated our terms</b>: a short summary of what changed and the new text. Tick that you read it and press <b class="gd-ui">Accept</b> to continue. It does not change an agreement you already signed or a past booking.</div></aside></section><section class="gd-task" id="start-here-your-first-days" data-gd-task><h2 class="gd-h2">Your first days</h2><p class="gd-p">Your portal opens in order: the academy (Training) first, then your staff agreement, then your jobs. Welcome shows each step and asks for the name you go by. Once both are done, Welcome and Today show the team&#39;s WhatsApp group: join it, then press <b class="gd-ui">I joined</b>.</p></section><section class="gd-task" id="start-here-the-weekly-townhall-release-35" data-gd-task><h2 class="gd-h2">The weekly townhall (release 35)</h2><p class="gd-p">Every Wednesday at 1:00 pm Toronto time, and everyone attends. Open <b class="gd-ui">Townhall</b>: <b class="gd-ui">Join the call</b> there, or <b class="gd-ui">Check in</b> from 15 minutes before, counts you as there. You get a reminder an hour before.</p></section><section class="gd-task" id="start-here-report-a-bug-release-37" data-gd-task><h2 class="gd-h2">Report a bug (release 37)</h2><p class="gd-p">Something not working? Press <b class="gd-ui">Report a bug</b> at the top of any page. A picture of the page is taken first (passwords and card fields are hidden); write what happened (at least 30 characters), what you expected and the steps if you know them, choose how bad it is (<b class="gd-ui">Blocks my work</b> alerts the Admins at once) and add or paste more pictures. The page, your browser and its recent errors go with it. <b class="gd-ui">My bug reports</b> shows each report and its status: new, being looked at, fixed or won&#39;t fix.</p></section><section class="gd-task" id="start-here-the-weekly-townhall-card-release-41" data-gd-task><h2 class="gd-h2">The weekly townhall card (release 41)</h2><p class="gd-p">From the day before the weekly townhall until it ends, your home page shows the <b class="gd-ui">Townhall</b> card: the day and time (Toronto), a countdown, <b class="gd-ui">Join / check in</b> (it opens 15 minutes before; joining through it checks you in), <b class="gd-ui">Add to calendar</b>, and a red line if you missed the last townhall: one more miss locks your account. You also get a reminder the day before at 10:00 am, the morning of at 9:00 am, an hour before, and 15 minutes before with the join link.</p></section><section class="gd-task" id="start-here-work-chats-only" data-gd-task><h2 class="gd-h2">Work chats only</h2><p class="gd-p">All work communication happens in the group work chats (the CarmaCars Team and Sales WhatsApp groups, and the chats in the portal), never in private messages. Questions, handovers, problems and customer details go in the group, so the whole team sees them and nothing is lost when someone is away. If a colleague or an Admin writes to you privately about work, answer in the group.</p></section>');
-- GUIDES 3110 END

-- CATALOGUE 3110 START (generated by supabase/seed/3110_gen.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_access_restored', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars access is back', 'You can sign in again.', 'Immediate, once', 'An Admin restored a suspended staff account (Unlock on Staff, or approving the person''s restore request; release 48, migration 3110). Sent once.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"sign_in_url","type":"url"}]'::jsonb, 'templates/staff_access_restored.html', 'templates/staff_access_restored.txt'),
  ('staff_access_suspended', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'You no longer have access to CarmaCars', 'Click here to restore it.', 'Immediate, once', 'A staff account (never an Admin) was suspended: no use of the staff portal for the days of Program settings (5 by default), or two weekly townhalls missed in a row (release 48, migration 3110). Sent once per suspension. While suspended this is the only kind of message the person gets (with the restored email), nothing else.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"restore_url","type":"url"}]'::jsonb, 'templates/staff_access_suspended.html', 'templates/staff_access_suspended.txt'),
  ('staff_inactivity_warning', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars staff access ends on {{lock_on}}', 'Sign in before then to keep it.', 'On the warning day, once', 'A staff account (never an Admin) has had no sign-in or use of the staff portal for the warning days of Program settings (3 by default since release 48, migration 3110; 7 before). Sent once per idle stretch.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"days_idle","type":"string"},{"name":"first_name","type":"string"},{"name":"lock_days","type":"string"},{"name":"lock_on","type":"string"},{"name":"sign_in_url","type":"url"}]'::jsonb, 'templates/staff_inactivity_warning.html', 'templates/staff_inactivity_warning.txt'),
  ('text_fell_back', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'A message from CarmaCars', '{{message_body}}', 'Immediate, once per text', 'A text CarmaCars meant to send could not go (the texting service refused it, for example when its prepaid credits ran out) and the person has an email address: the same words come by email instead, once, and the text is marked "not sent: fell back to email" (release 48, migration 3110). A text whose own email already went, or that is no longer relevant, is never sent this way.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"message_body","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/text_fell_back.html', 'templates/text_fell_back.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
update notification_catalogue set emitted_by = 'app.text_fall_back (3110)', no_text = true where code = 'text_fell_back';
update notification_catalogue set emitted_by = 'app.staff_suspension_mail (3110)' where code in ('staff_access_suspended', 'staff_access_restored');
select app.notification_catalogue_refresh();
-- CATALOGUE 3110 END
