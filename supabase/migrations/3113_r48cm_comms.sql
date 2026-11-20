-- 3113_r48cm_comms.sql
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
-- No applied migration is edited: functions are wrapped (name_pre3113) or replaced as noted.
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
  if position(p_old in d) = 0 then raise exception '3113: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings
alter table program_settings
  add column if not exists text_stale_minutes integer not null default 120 check (text_stale_minutes between 10 and 2880),
  add column if not exists text_retry_paused_minutes integer not null default 30 check (text_retry_paused_minutes between 5 and 1440),
  add column if not exists staff_inactive_grace_from timestamptz;
comment on column program_settings.text_stale_minutes is 'A text still waiting this long is dropped, never sent late (3113); its email fallback covers it when one is due.';
comment on column program_settings.text_retry_paused_minutes is 'While Quo refuses texts (out of credits), one text is tried again this often; the first one that goes ends the pause (3113).';
comment on column program_settings.staff_inactive_grace_from is 'The inactivity days count from this moment at the earliest (3113: the release, after a week staff could not use the portal).';
alter table program_settings alter column staff_inactive_lock_days set default 5, alter column staff_inactive_warn_days set default 3;
update program_settings set staff_inactive_lock_days = 5 where staff_inactive_lock_days = 10;
update program_settings set staff_inactive_warn_days = 3 where staff_inactive_warn_days = 7;
update program_settings set staff_inactive_grace_from = now() where staff_inactive_grace_from is null;
-- a Program settings row saved later keeps the same start (the column's default is this moment)
do $$ begin execute format('alter table program_settings alter column staff_inactive_grace_from set default %L::timestamptz', now()); end $$;
comment on column program_settings.staff_inactive_lock_days is 'A staff account (never an Admin) with no use of the portal for this many days in a row is suspended (3113: 5; 1060: 10). Suspended staff get only the suspension email with its restore link.';

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('texts_not_sending', 'Texts are not going out (they go by email instead)', 'System', '{admin}', 'normal', 'alerts', true, false, 'Quo refused texts, for example its prepaid credits ran out (3113). Once a day while it lasts.', 170),
  ('ses_sandbox', 'Amazon SES is in its sandbox', 'System', '{admin}', 'normal', 'alerts', true, false, 'SES refuses every recipient it has not verified (3113). Once a day while it lasts.', 171),
  ('staff_restore_requested', 'A suspended staff member asks for access back', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'From the restore link of the suspension email (3113). Unlock on Staff approves it.', 172),
  ('interview_no_slot', 'No open interview slot to move a call to', 'Staff', '{admin}', 'normal', 'alerts', true, false, 'A missed interview call could not be moved (3113). Add interview times on Hiring.', 173)
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
comment on table phone_provider_state is 'Texts (3113): Quo refused for its account (credits): texts pause and fall back to email until one goes again.';

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
  perform app.staff_alert('texts_not_sending', 'site_alert', null, to_char(app.local_date(now()), 'YYYYMMDD'),
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
alter function app.server_phone_sent(jsonb) rename to server_phone_sent_pre3113;
create function app.server_phone_sent(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb;
  v_ok boolean := coalesce((p ->> 'ok')::boolean, false);
  v_err text := left(p ->> 'error', 300);
  v_acct boolean := not v_ok and app.quo_account_error(v_err);
  o phone_outbox;
begin
  r := app.server_phone_sent_pre3113(case when v_acct then p || jsonb_build_object('permanent', true) else p end);
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
select pg_temp.copy_grants('app.server_phone_sent(jsonb)'::regprocedure, 'app.server_phone_sent_pre3113(jsonb)'::regprocedure);

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
    if v_code ~ '(pickup|booking_reminder|offer_ready|offer_sent|payment_link|deposit)' and (b.status::text in ('on_rent', 'returned', 'closed') or b.pickup_at < p_now - interval '1 day') then
      return 'not sent: no longer relevant (the pickup has passed)';
    end if;
    if v_code ~ '(return)' and b.status::text in ('returned', 'closed') then
      return 'not sent: no longer relevant (the car is back)';
    end if;
  end if;
  return null;
end $$;

-- before texts are claimed: stale and irrelevant ones are dropped; while Quo is paused every due text falls back at
-- once, except one probe every text_retry_paused_minutes
alter function app.server_phone_due(integer) rename to server_phone_due_pre3113;
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
    r := app.server_phone_due_pre3113(1);
    return r || jsonb_build_object('paused', true, 'probe', true, 'dropped', v_dropped, 'fell_back', v_fell);
  end if;
  return app.server_phone_due_pre3113(p_limit) || jsonb_build_object('dropped', v_dropped);
end $$;
select pg_temp.copy_grants('app.server_phone_due(integer)'::regprocedure, 'app.server_phone_due_pre3113(integer)'::regprocedure);

-- ================================================================ 3. Amazon SES in its sandbox
alter table email_provider_state add column if not exists ses_sandbox_at timestamptz;
comment on column email_provider_state.ses_sandbox_at is 'Last refusal of SES for a recipient it has not verified (3113): the account is in its sandbox until AWS grants production access.';
alter function app.server_ses_email_result(jsonb) rename to server_ses_email_result_pre3113;
create function app.server_ses_email_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if coalesce((p ->> 'sandbox')::boolean, false) then
    insert into email_provider_state default values on conflict do nothing;
    update email_provider_state set ses_sandbox_at = now(), ses_error = left(p ->> 'error', 300), updated_at = now() where id;
    perform app.staff_alert('ses_sandbox', 'site_alert', null, to_char(app.local_date(now()), 'YYYYMMDD'),
      'Amazon SES is in its sandbox: emails go through Resend''s 100 a day',
      'SES refuses every address it has not verified. AWS console, region Canada (Central): Amazon SES > Account dashboard > Request production access (transactional).',
      jsonb_build_object('path_admin', '/admin/settings/usage'));
    return jsonb_build_object('ses_left', app.ses_email_left(now()), 'ses_try', app.ses_email_try(now()), 'sandbox', true);
  end if;
  return app.server_ses_email_result_pre3113(p);
end $$;
select pg_temp.copy_grants('app.server_ses_email_result(jsonb)'::regprocedure, 'app.server_ses_email_result_pre3113(jsonb)'::regprocedure);

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
comment on table push_lost is 'Phone alerts (3113): every device that stopped getting alerts and why (turned_off: the person; expired, refused, another_person, too_many: not them). The portal tells the person; the browser subscribes again by itself unless they turned it off.';

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
alter function app.push_unsubscribe(uuid, jsonb) rename to push_unsubscribe_pre3113;
create function app.push_unsubscribe(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('app.push_lost_reason', 'turned_off', true);
  return app.push_unsubscribe_pre3113(p_user, p);
end $$;
select pg_temp.copy_grants('app.push_unsubscribe(uuid, jsonb)'::regprocedure, 'app.push_unsubscribe_pre3113(uuid, jsonb)'::regprocedure);

-- p.auto: the browser subscribing again by itself (its permission still granted). Refused for a device its person
-- turned off; any subscribe resolves the person's lost devices.
alter function app.push_subscribe(uuid, jsonb) rename to push_subscribe_pre3113;
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
  r := app.push_subscribe_pre3113(p_user, p - 'auto');
  perform set_config('app.push_lost_reason', '', true);
  update push_lost set resolved_at = now() where user_id = p_user and resolved_at is null and reason <> 'turned_off';
  return app.push_state(p_user, v_ep);
end $$;
select pg_temp.copy_grants('app.push_subscribe(uuid, jsonb)'::regprocedure, 'app.push_subscribe_pre3113(uuid, jsonb)'::regprocedure);

-- the push services' answers: a device dropped there is recorded as expired (not turned off)
alter function app.server_push_result(jsonb) rename to server_push_result_pre3113;
create function app.server_push_result(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r jsonb;
begin
  perform set_config('app.push_lost_reason', 'expired', true);
  r := app.server_push_result_pre3113(p);
  perform set_config('app.push_lost_reason', '', true);
  return r;
end $$;
select pg_temp.copy_grants('app.server_push_result(jsonb)'::regprocedure, 'app.server_push_result_pre3113(jsonb)'::regprocedure);

-- the card and the prompt: a device of this person that stopped without them turning it off
alter function app.push_state(uuid, text) rename to push_state_pre3113;
create function app.push_state(p_user uuid, p_endpoint text default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.push_state_pre3113(p_user, p_endpoint) || jsonb_build_object(
    'lost', (select jsonb_build_object('at', l.at, 'reason', l.reason, 'device', l.device, 'this', l.endpoint = p_endpoint)
               from push_lost l where l.user_id = p_user and l.resolved_at is null and l.reason <> 'turned_off' and l.at > now() - interval '30 days'
               order by l.at desc, l.id desc limit 1),
    'turned_off_here', case when p_endpoint is null then null else
      coalesce((select l.reason = 'turned_off' from push_lost l where l.user_id = p_user and l.endpoint = p_endpoint order by l.at desc, l.id desc limit 1), false) end)
$$;
select pg_temp.copy_grants('app.push_state(uuid, text)'::regprocedure, 'app.push_state_pre3113(uuid, text)'::regprocedure);

-- ================================================================ 5 and 6. suspended staff, staff notices off
alter table users add column if not exists staff_notices_off boolean not null default false;
comment on column users.staff_notices_off is 'Staff notifications (emails, texts, phone alerts of staff audiences) turned off for this person (3113).';
alter table staff_profiles add column if not exists restore_token uuid unique;
comment on column staff_profiles.restore_token is 'The restore link of a suspended account (3113): staff-restore?t=<token> asks the Admins for access back.';

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
comment on table staff_restore_requests is 'A suspended staff member asking for access back (3113). Unlock on Staff restores them and closes the request.';

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
                     'server_phone_sent', 'server_phone_sent_pre3113', 'server_phone_due', 'server_phone_due_pre3113', 'server_ses_email_result', 'server_ses_email_result_pre3113',
                     'push_lost_log', 'push_unsubscribe_pre3113', 'push_subscribe_pre3113', 'server_push_result_pre3113', 'push_state_pre3113',
                     'staff_notice_block', 'outbox_staff_block', 'push_staff_block', 'phone_staff_block', 'staff_suspension_mail', 'job_staff_inactivity']))
               or (n.nspname = 'public' and p.proname = any (array['server_staff_restore_request', 'server_staff_restore_token'])) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 9. the academy: Work chats on every staff path; staff who had
-- passed everything get 7 days before it holds them (as 2990), the others are held as before
create temp table r48cm_done on commit drop as select distinct e.user_id from academy_enrollments e where app.academy_done(e.user_id);
-- ACADEMY 3113 START (generated by supabase/seed/3113_gen.mjs; do not edit by hand)
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
-- ACADEMY 3113 END
update academy_enrollments e set lock_from = greatest(e.lock_from, now() + interval '7 days') from r48cm_done d where e.user_id = d.user_id and e.gate;

-- GUIDES 3113 START (generated by supabase/seed/3113_gen.mjs; do not edit by hand)
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
select app.guide_release_section('admin', 'requests-offers-and-bookings', 'chapter', 'people-and-access', 'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## Bookings now: what is out, coming back and owed

Open **Bookings**. It opens on **Now**, one screen that refreshes by itself every 30 seconds. Every time is Toronto time.

1. The numbers at the top: cars out now, due back today, overdue, going out in the next 72 hours, payments due in the next 7 days (with the total) and free cars. Tap one to jump to its list.
2. **Out now**: every car on rent, overdue returns first in red. Each shows the car (photo, code, plate), the renter with **Call** and **Text**, when it was picked up, when it is due back with a countdown, the payment plan and the next payment, the deposit held, and the km and fuel at pickup. Filter by Overdue, Due today or Payment due.
3. A confirmed booking whose pickup time has passed with no check-in recorded is listed as out, with **Out (pickup not recorded)**. The car most likely left. Press **Mark picked up**: it records the pickup at the booked time (change it if the car left at another time), the booking goes on rent, and Fleet gets a task to add the photos, km and fuel. The usual checks stay: the deposit taken (or an Admin waives it with the reason), the renter''s signature (or an Admin''s reason), the agreement''s details, every driver verified and the coverage confirmed. If one is missing, the reason is shown.
4. **Coming back**: overdue, today and tomorrow, by the time each is due.
5. **Going out**: confirmed pickups in the next 72 hours, delivery or pickup, with ticks and crosses for the licence, the signed agreement, the payment, the deposit (a clock until the morning of the pickup day, when the hold is placed on the card on file) and the check-in photos (done at the handover).
6. **Money due**: every rental payment due in the next 7 days or overdue, the amount, the plan and which payment it is (for example 3 of 4).
7. **Free now**: cars available and not out, the longest idle first, with the next pickup; then the cars in maintenance or cleaning. Partners'' cars are counted apart.

> Good to know: Placeholder bookings never show on Now.

### Payment plans

A rental is paid in full at pickup, weekly, every 2 weeks, or monthly. A rental longer than one period (30 days) pays each period by itself. To change it, open the booking, then the **Payment plan** card on Overview or Money, and press **Change the plan**. Each payment is its share of the total by its days, due on the day it starts. An insurer-billed rental shows **Insurer billed** and is never in Money due unless the renter owes a part. Admins, customer service and finance change the plan; fleet sees it.

## All bookings

The **All bookings** tab of Bookings has the search (booking number, name, email, phone, plate or car code), the status (All, Out now, Booked, Returned, Cancelled; closed bookings are found with the search, which also finds the insurer). **Out now** shows the bookings on rent and those whose pickup passed without a check-in, together. Each booking is one row: its number and status in plain words, the car with its photo, the renter with **Call** and **Text**, the dates, the money (paid up, to pay, overdue, insurer billed) and Bill to.

## The request queue

Open **Bookings** > **Requests and offers**. The oldest waiting request is at the top.

1. The numbers at the top: waiting for an offer, past the reply target (red), offers out, accepted but not paid, and offers expired. Each one is a filter: press it and the list shows just those, with the matching chip below marked as chosen.
2. One queue, the most urgent first: the longest wait, then offers accepted but not paid, then offers out by when they expire. Each row has the car with its photo, the dates, the price, the renter with **Call** and **Text**, the licence (verified, to review, or not uploaded yet), who is answering it, and one button: **Send offer**, **Follow up** or **Open**. **Decline** sits beside **Send offer**.
3. Waiting shows how long the renter has waited ("12 min", "3 h", "2 days"); red means past the first reply target (5 minutes, set in Program settings). **Promise** counts down the 2 hours the site promises the renter.
4. Filter by Active, New, Changes asked, Offer out, Accepted, not paid or Expired. The list remembers your last choice on that device; **Active** always shows the whole queue and replaces what it remembered. When the same renter asks for the same car for overlapping dates again and the earlier request or offer expired, only the newest is listed: the older ones are linked to it and leave Requests (they keep their history). An expired offer leaves the active queue 48 hours after it expired, or once its pickup time passed; Expired lists the ones from the last 7 days. After 7 days an expired offer leaves Requests and offers and becomes a renter lead, once, in People > Renters > Leads (Expired offers), with the car and the dates the renter wanted and a To do for Sales to win them back. An offer still out when its pickup time passes expires by itself.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 38.9 29.9, 2 22.2 43.3")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates (under **Show rate card**) and fees, the deposit and extras. A place changed away from a delivery or a collection takes its fee box and its fee with it.
3. Price on the right updates as you change things.
4. Add a message, then press **Send the offer**, the one main button at the bottom (Send the offer under Next step takes you there). How long it stays open, Email or Text and Book it now are under More options.

![](/guides/img/admin-03-booking-review-desktop-353f3707.jpg "desktop; size: 1200 1550; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 1 5.0 6.5, 2 7.5 45.8, 3 74.2 42.6, 4 76.7 98.1")

5. Changed fields but not ready to send? Press **Save without sending**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg "desktop; size: 500 80; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 6 41.2 52.5, 7 18.0 52.5")

Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press **Take over** to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.

## Send an offer without a request

Press **Send an offer** at the top of Bookings, or **Send an offer without a request** on Requests and offers. For a customer on the phone, by text or at the counter: no request needed.

The screen is seven short steps, each with one line saying what to do, and the price beside it (on a phone the total sits at the bottom of the screen: press **See every line**). What most offers never need is under each step''s **More options**, which stays open while something in it is used.

1. **Who is renting and when**: find the renter by name, phone or email, or press **Not on file? Add a new customer** (full legal name, mobile, email for the offer link, date of birth). A customer already on file with the same email or phone is shown with Use: one person, one record. A renter picked from the file shows what is on their record under their name: the licence (class, number, expiry), the home address and the drivers named before, with a licence that has expired or an address over a year old flagged to ask them about. Then the pickup and the return.
2. **Which car**: search by car code, plate or name; each car says Free or Not free for the dates. More options: the rate card and the type and free-only filters.
3. **Where they pick up and return**: at our location, we deliver or collect (the address and distance), an airport or the owner''s location. The fee each one makes shows under it, Automatic or Set by hand.
4. **How damage is covered**: the renter''s own insurance, a credit card or the Protection Plan. More options: another Protection Plan price.
5. **Extras**: add-ons, when the car has any.
6. **The price**: the rate sheet price is filled in. More options: another price (a total for the trip or a rate a day, with why), Amounts I type (before or after HST), the total the renter pays, kilometres, a promo code, the deposit and a discount (an Admin), and **Fees**: press **Change** to set one by hand, **Reset to automatic** to undo it. Below: how it is paid (card online and a card hold unless you change it under More options).
7. **Send it**: who found this client (sales and customer service), a message, and Text or Email. More options: how long the offer is open, the owner''s view, who found the client (an Admin) and the internal note. Above the button, **Ready to send** or **Missing:** with what is left; press Send and each missing field says what it needs. Press **Send the offer to** the renter, or **Save without sending** to keep it as a request for later. **The offer as the renter sees it** is under the price.

> Good to know: Choices drive the charges. Take off a delivery, a collection, the Protection Plan or an add-on and its fee goes with it, even a fee set by hand: there is nothing to remove in a second place. Choose it again and the fee starts from the automatic amount.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Open **More actions** on the booking and press **Edit the offer**.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.
2. Write what changed in Message to the renter. How long the offer is open and Email or Text are under More options.
3. Press **Send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without sending** and tell them yourself. After you save, the screen shows the offer as saved.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Restore a version of a confirmed booking

Once a confirmed booking has been changed, Overview shows **Versions of this booking**: the booking before its first change, then one version after each change (a fee changed on its own too), the newest marked current.

1. Find the version to go back to (its dates, days, car, rental charge and total are listed) and press **Restore this version**.
2. The preview shows what changes: the dates, the car, the rental charge, the total, and what the renter would owe or be owed. Nothing is changed yet.
3. Type why, tick **Tell the renter what changed** if they should know, and press **Restore version** with its number. The dates, the car, the rental charge and every fee go back exactly as they were in that version.
4. It is one more change in the history, with your name and the reason. Payments are never touched: a difference is a balance to collect or a credit to settle, as with any edit.

> Good to know: The same checks as Edit: the car must be free for those dates, and customer service and Sales restore only while Program settings let staff change bookings (and fees). A version kept before Release 45 has no fees with it: its dates, car and rental charge go back and the fees stay as they are; the preview says so.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

> Good to know: Changing the amount of a line on the Money tab changes the booking''s total and balance with it, so no balance appears that nobody owes. An Admin can set the total directly with **Change the total**: the difference goes on the rental charge.

## A renter with only a debit or prepaid card

A credit card is required by default: the deposit must be on a credit card so the deductible can be charged. The pay page tells a renter with only a debit or prepaid card to contact us.

1. On the booking''s Money tab, press **Allow debit and prepaid cards for this booking** and type the reason. Who and when are kept, and the change is in the booking''s history.
2. The booking''s pay page, staff pay links and deposit hold then take a debit or prepaid card, and the renter is told the hold lowers the money available on the card until it is released, which can take several business days.
3. **Require a credit card again** turns it off.

The Money tab shows each card used and its type (credit, debit, prepaid). A booking on credit card rental coverage is always paid on the credit card that carries the coverage, and cannot be allowed. Program settings, **Card types accepted**, can open debit and prepaid cards to every booking.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.
4. The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. **Merge into this record** moves the other record''s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.

## The Money tab: Rental charges and Security deposit

The booking''s Money tab opens on a strip with the three numbers that matter: **Rental due**, **Deposit** (one word: Not collected, Held, Charged, Released or Partly kept) and **Total paid**. Below are two panels, side by side on a computer and one above the other on a phone. Collecting one never touches the other, and every receipt says which one it is.

**Rental charges**: each line of the price and the total, Paid, then Balance due.

1. The one main button, Collect (the amount) rental: choose how. **The card on file** charges it now (Finance or an Admin); **A payment link by text** or **A payment link by email** sends the renter Stripe''s secure form; **On this device: hand it to the renter** opens it for the renter to type; **Cash, e-Transfer or another way (record it)** records money received (an e-Transfer, cheque or transfer needs its reference). For: the rental and fees together by default, or one of them. With the card on file, the rental and fees together are one charge with one receipt that lists both (the rental is paid first, then the fees; an insurer''s part and money already received another way are left out). The renter gets a receipt; **Print** prints one to hand over.
2. **A later charge** (before the return): on the card on file, by a link, on this device, or recorded. Choose the **Reason** from the list (Mileage overage, Fuel, Cleaning, Smoking, Late return, Tolls, Tickets/fines, Damage, Missing items, Other) and add a note; Other needs its note. The renter''s receipt shows the reason.
3. **Save a card** saves the renter''s card without charging it. Card readers, the fees (**Change or add a fee**), failed card payments (**Paid another way**), payments received another way and **Refund** sit in this panel too. The history lists rental payments only.
4. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).

**Security deposit**: the amount, how it is taken (a credit card hold, a debit or prepaid card at the standard multiple, a charge, or cash), its status in one word and the next step.

1. Not collected: the one main button, Collect (the amount) deposit. **Hold on the card on file** places the hold now (Finance or an Admin); **A deposit hold link by text** or **A deposit hold link by email**, or **A hold on this device: hand it to the renter**; **Charge the card on file as the deposit** only when no hold can be placed; **Cash or e-Transfer (record it)**. The rental balance is not touched.
2. Before every pickup the deposit hold link is texted to the renter on its own: 24 hours before (at once when the pickup is sooner), for a confirmed booking whose deposit is a card hold with no hold yet. The panel says **Deposit link texted** and when it was opened. No mobile number, or the text not sent: a task **Deposit link not sent**. **Settings**, then Site settings, Deposit link by text: on or off, and the hours.
3. Held, while the car is out: **Release** (an Admin, with the reason), **Keep part (damage/fees)** with the amount and the reason from the list, or **Re-authorize the hold** on the saved card before it lapses (the panel shows when the hold expires). A job re-authorizes it by itself about 24 hours before it expires; if it cannot, Finance and the Admins get the alert **Deposit hold not re-authorized**.
4. **Hold expired**: a card hold lasts about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. Once it has expired, nothing can be kept from it: the panel says Hold expired, Keep and Release are hidden, and **Charge the card on file instead** opens the later charge with the amount and the reason filled in.
4. After the return: **Settle the deposit** (below).
5. **Waive the deposit** (an Admin, before it is taken), **Change the debit deposit**, and **Allow debit and prepaid cards for this booking** sit in this panel. The history lists deposit payments only.
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## Settle the deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-out statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: **Keep the whole deposit (damage)** turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. **Bill damage** adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Email the renter** and **More actions**, the menu with **Edit the offer**, **Stop blocking the calendar**, **Cancel for the renter**, **Cancel by CarmaCars** and the rest.
5. Under the booking number: **Next step**, what happens next and who does it, with one button for that step (for example **Send the offer**, **Sign on this device** or **Check in the car**); then where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10065; pins: 2 50.0 46.6, 4 85.4 14.5, 5 22.9 26.8")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check in (pickup)** under Check-in, check-out and signing; a booking on rent shows **Check out (return)**. Today lists the check-ins and check-outs due, each with **Check in** or **Check out**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-in, check-out and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-in and check-out, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-out the mileage overage and the fuel or recharging are written to the return charges at once. A late return (after the grace period of the fee defaults) is not: it waits for a choice on the booking (see "A late return is a choice"). The fuel is a suggested line: the car''s tank x the fuel missing x the pump price of its grade (Program settings, updated weekly) x 1.25, plus the refuelling fee; an electric car the battery kWh x the charge missing x the price a kWh, plus the fee. A pump receipt entered later replaces it. Fleet and Finance confirm it on the deposit review; it is never charged to a card by itself.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-out time** (or the check-in time) with the reason: lateness follows, a return that is no longer late loses its late charge, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

### The renter says the car is back

Every overdue email, text and alert (at the return time, at 15 minutes and the final notice) has a one-tap **I''ve returned the car** link, and the renter''s booking page has the button. The renter can add photos, the odometer, the fuel level and the time they returned it. Sending it stops every overdue notice of the booking at once, the booking shows **Returned, waiting for confirmation**, and Fleet gets an urgent To do: "The renter says the car is back".

1. Open the booking. The card **The renter says the car is back** shows what the renter gave, marked renter-provided, with their photos.
2. Check the car: the return place, the tracker, the photos.
3. Press **Confirm** to complete the trip. Correct the odometer, fuel or return time first if they are wrong: the late charges follow the time you confirm. The renter''s photos join the check-out report.
4. Or press **Deny** and say why. The renter gets your reason by email and text, and the overdue notices start again.

Checking the car in the usual way also completes the trip and stops the notices. Admins, Fleet, Sales, Customer service and field staff can Confirm or Deny.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. No agreement made yet (the renter has not saved their details at home)? **Sign now on this device** still shows: press **Prepare the agreement to sign now** and it is made on the spot.
3. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
4. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
5. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-in makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-in report), countersigned by whoever checked the car out; check-out makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-in stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).
8. **Edit the wording** (Admin only) changes CarmaCars'' agreement text for this booking: press **Change** beside a clause, edit its text, say why and press **Save the wording**; **Add** writes Additional terms at the end of Part 2. Only clauses not required by law or the insurer can be removed; the consents are fixed, and Blind Spot''s form (the insurer''s official form) is never changed. Before the renter signs, the agreement is made again; after, the change is a new version they sign, and **Every version** shows each clause before and after.

## Signing that holds up in a dispute

Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner''s link, the partner, investment and staff agreements.

1. The licence on file is shown. A 6-digit code to their phone or email on file is optional: the signer may press **Verify by code (optional)**, and Program settings, E-signing, **ask for a one-time code** makes it a required first step again (off by default). Without the code, the certificate says the identity was not confirmed by a code.
2. They say they read the documents, initial the key terms (each initials box is saved with **Save initials**; **Clear** takes it back to initial again) (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement''s three confirmations, Form C''s acknowledgments, Schedule C, the staff agreement''s confidentiality), two consents and the drawn signature. Form C''s witness still types their name beside the owner.
4. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
5. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-in and check-out reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## The licence reader

Every licence photo is read on upload: the back''s barcode first, else the vision model (within the day''s AI allowance).

1. The renter''s empty licence fields are filled from the read; the renter confirms them. A blurry or cut-off photo is taken again at once.
2. **Review documents** shows what was read and one line per check, Pass or Flag: photos, valid to the return, class accepted, age at pickup, name and date of birth, the Ontario number, front and back, and the main driver''s Ontario licence. Staff still approve.
3. **Settings** > **Program**, Driver''s licence reader: **Approve automatically when every check passes** (off). On: a driver whose front and back both read sharp and every check passes is approved in your name; anything flagged waits for a person.
4. **Primary driver must hold an Ontario licence** (on): a main driver with a licence from elsewhere becomes an additional driver, the booking needs "Primary driver: Ontario licence needed" and pickup is blocked. The renter adds a main driver, who signs on their own link. On the document review, **Admin: undo or let it go**: undo puts the first main driver back; let it go needs a reason.

> Tip: What was read is staff only and is deleted with the licence image. The licence number is never written to the logs.

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. The number in the button is exactly what it approves (an image whose file was removed is not counted), and an image not tied to a driver of the booking is listed under **Other documents**. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.
6. A document already approved or rejected, and each page of the proof of coverage (pink slip, OPCF 27 endorsement page), has **View**: it opens the image (or the PDF) again through a link that lasts one minute, and the view is written to the audit log. After the 90-day removal of identity images the line reads **Removed on** and the date, with nothing to open. Owners never see these documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-in (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer''s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.

## Payments by day

**Money** > **Payments**, the **By day** tab: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. Leave the price empty: a later return costs what a day of this booking costs (rental, fees and coverage, HST included; the preview shows the price a day). To price it by hand, type a New rental charge before tax, or the new total with HST.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-97008b21.jpg "desktop; size: 1200 520; address: carmacars.ca/admin/bookings/CC-10065?tab=changes; pins: 1 17.5 33.7, 2 9.2 50.0, 3 38.3 71.2, 4 12.9 91.9")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Good to know: A request keeps the lead-time adjustment of the moment it came in ("Short-notice pricing +10%" or "Booked ahead −5%"), through the offer and the payment. To change it, open the booking''s review screen, **More options**, **Lead-time pricing (%)**: a number (0 for none), or empty for the tier of the request. A price typed by hand replaces it.

> Good to know: The rental never goes below the car''s minimum daily rate or above its maximum (its price limits, set by the owner or on the car''s Rates tab), whatever the discount, promo code or lead-time pricing: a line "Minimum daily rate for this car" or "Maximum daily rate for this car" brings it back. Only an Admin allows a price outside them: **More options**, **Allow a price outside the car''s price limits (Admin only)**, with the reason.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-out. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement carries each booking that counts toward the owner''s revenue, at its true amounts, and lists each deduction with its reason, so the payout is always right. A booking billed to the renter always counts. Left out: a booking billed to an insurer and hidden from the owner (while Program settings keep only insurance replacements hidden), an insurer-billed rental that does not block the calendar, and a rental with "Counts toward the owner''s revenue" off. The booking page says when a booking is not part of the owner''s revenue and why. When a booking that was left out starts counting (Blocks the calendar turned on, shown to the owner, or billed to the renter), the owner gets the new booking email once, at that moment. Customer service and sales add deductions only while Program settings let them change fees.

## Email the renter or the adjuster

Press **Email the renter** at the top of a booking, or open its **Messages & history** section.

1. Write a **Subject** and a **Message**, or pick a **Quick reply** to start from (Settings > Quick replies keeps them).
2. Press **Email the renter**. It goes from CarmaCars (bookings@carmacars.ca) and replies come back to the bookings inbox. The renter also sees it in their account and can answer there.
3. On a booking an insurer pays, choose **From**: CarmaCars, or Blind Spot Car Rental (insurance). **Email the adjuster** writes to the adjuster''s email on the booking (Insurance claim), always from Blind Spot Car Rental.

The **Messages & history** section is the booking''s Activity log (release 35): what you and the renter wrote, every email of the booking, the texts, chat, calls, notes, events, payments, documents and visits, newest first, with a chip for each type and a search. The email form is under the log; each email you send shows in the log with your name.

> Good to know: Emails go out through the same daily limit as every email (the line under the form shows today''s use). A message to a renter goes before digests and marketing; past the limit it waits until midnight. To write to a renter from **People** > **Renters**, open the renter: Email the renter is at the bottom, about their latest booking or the one you pick.

### Record the pickup or the return now (details later)
When the car went out or came back but the checklist could not be done (no photos, no time, the renter dropped the keys), the booking''s **Check-in, check-out and signing** card has **Record the pickup now (details later)** on a confirmed booking and **Record the return now (details later)** while the car is on rent. Give the actual time (now, or earlier), the odometer and fuel if you know them, and why. The booking moves on (on rent, or returned), late return charges follow the actual time, and Fleet gets the task **Add the photos and readings for CC-...**. A car overdue or due back today also has **Returned**: on the To do list (Check-ins and check-outs today), on Bookings > Now and at the top of the booking page, which the late return alert opens. It asks only the return time (now, or earlier) and the km and fuel if you know them, and records the return the same way. Once returned, the statement can be issued and the deposit settled; releasing the deposit before the photos are in needs an Admin and a reason. A pickup without the deposit taken needs an Admin to waive it with a reason, and without the renter''s signature on the check-in report an Admin''s reason too. Later, **Add the check-in (or check-out) photos and readings** opens the usual checklist (photos, readings, your signature): the task closes when it is saved.

The Agreement card says **Waiting for the renter''s details** when the renter still has blanks to fill (date of birth, address, mobile, licence, coverage): their account asks for them before signing and paying. No email or text is sent.

### Find a booking
**Bookings** has one search box: type the booking number (CC-1042, cc1042 or just 1042), the renter''s or a driver''s name, an email, a phone number in any format, a plate (spaces do not matter) or a car code, then press Enter. The status filters still apply to what is found.

### Record a card payment taken outside the site
A card taken in the Stripe Dashboard, or on a card reader, is recorded on the booking''s **Money** tab with **Record card payment**.

1. Choose what it paid: **Rental and fees**, **Rental**, **Fees**, **Later charges** or **Deposit hold**, and where it was taken.
2. Type the **Last 4 digits** and the amount. A Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard) is optional for a payment: press **Look up** and the amount and last 4 digits are checked against Stripe.
3. Press **Record it**. A payment confirms a booking waiting for payment, as any payment does.

> Good to know: A deposit hold needs its Stripe payment id, so it can be captured or released from **Settle the deposit**. It is recorded as held, with the usual release reminders. A hold on a reader lapses after 2 days, one made online after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise.

### Link a payment taken outside the platform
A charge or a card deposit taken in the Stripe Dashboard or through a Stripe payment link is linked to its booking by an Admin, on the booking''s **Money** tab: **Link a payment taken outside the platform**, in the rental panel or the deposit panel.

1. Paste the Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard). **Look up** shows what Stripe says: the amount, paid or a hold, and the card.
2. Press **Link as a rental payment** or **Link as the deposit**.

> Good to know: It must be in Canadian dollars and not already linked. A rental payment may not be more than is open for the rental and fees. A deposit must be the whole deposit: a hold waiting to be captured is kept as held (settle it as any hold), a charged deposit is kept as captured. **Money** > **Unlinked Stripe** lists, every night, the Stripe payments of the last 60 days that no booking knows, with a best guess of the booking.

### Charge or hold the deposit on the card reader
With the S700 paired (Settings > Card reader), the **Money** tab has **Charge on reader** (everything open, the rental, the fees or a later charge) and **Hold deposit on reader**. Press **Send to the reader**: the amount shows on the reader and the renter taps, inserts or swipes the card. The screen updates by itself; **Cancel** stops the reader and nothing is charged. A deposit hold is captured or released from Settle the deposit like any hold.

### Credit card coverage: the same card
When the renter''s coverage is their credit card, the whole rental (rental and fees) is paid on that same card. The Money tab says which card. Another card on the pay page is refused and refunded at once; on the reader it is refused before the money is taken; a payment by e-Transfer, cash or the like is refused; a card typed by hand needs its last 4 digits and the box **This is the same card**. Deposits and later charges can go on any card. If the renter truly has to use another card or method, press **Allow another card** and give the reason (an Admin).

## Booked as soon as the renter accepts (release 28)

A booking is booked the moment the renter approves the offer. It takes the car on every calendar, the fleet board, the car''s availability and the counts, even before the payment or the pickup is recorded. Payment and the handover show as their own badges: **Booked, payment due** and **Pickup not recorded**. The first renter to approve gets the car: any other open offer on the same car and dates goes back to Requests with a Re-offer To do.

- **Booked, payment due** To do: a booked rental still unpaid within 48 hours of its pickup. Send the pay link, charge the saved card or record the payment.
- Record the pickup To do: a pickup time that passed with nothing recorded, as before.

When you send an offer, **The offer as the renter sees it** sits right under **Send the offer**: check it before you press it.

## Changes after signing: an amended agreement, no new signature

The rental terms (section 15.4) let CarmaCars update a booking after signing: an extension, new dates or times, a price adjustment, a fee, a car swap. The signed agreement keeps applying. Each change makes a new version of the agreement marked **Amended** with the date, carrying the renter''s original signature, and the renter is sent it. Nobody is asked to sign again, except an additional driver who never signed (they sign before driving).

## Check-in and check-out on one screen

On the booking page, **Check in (pickup)** and **Check out (return)** are one screen: the time (now unless you change it), the odometer, the fuel, the photos and a note. Pick many photos at once from the camera roll or take them; tag an angle on any photo if you like. The suggested angles (front, each corner and side, rear, odometer, fuel gauge, interior front and rear, trunk, wheels, any damage) tick themselves as photos are tagged. Nothing is required but the time; the renter''s own photos are added to the same report, each marked with who took it (the renter or staff) and its angle. The one-screen checklist is the button above it.

## Type into the Blind Spot agreement

On the **Rental agreements** card, **Type into the Blind Spot agreement** shows each box as the form prints it. Change a value and **Save the corrections**: it is drawn in that box, and the insured vehicle, the claim number, the adjuster and missing km or fuel go back onto the booking. **Preview the filled form** opens it with your corrections.

## Reopen an expired offer (release 28)

An expired offer reopens in one click: **Reopen offer** on the booking or on the **Expired** filter of Requests. The renter gets the usual offer email and text; the offer stays open 12 hours, and never past 1 hour before the pickup, unless you type other hours. Once the renter accepts, the car is held 2 hours for the payment; then the hold ends and, while the car is still free, the renter gets a fresh offer and a text to pay. When the pickup time has passed, the dialog asks for the new pickup and return first. A renter can also press **Ask to reopen this offer**: you get the To do "Renter wants expired offer reopened" and an alert, as for a new request.

An offer sent after its pickup time no longer expires by itself: it expires at its own expiry time (the pickup only counts when the offer was sent before it and the pickup is 2 hours past). The offer screens say **Pickup time has passed: update it** and do not send until you move the pickup.

## One booking page, six sections (release 31)

A booking has six sections: **Overview** (the next step; the review and offer while it is being arranged), **Money**, **Drivers & documents** (with the agreement), **Car & handovers** (the check-in and check-out, the photo report, signing on this device, what the owner sees), **Messages & history** (with the review request) and **Claims & extras** (changes, extensions, add-ons). Customer service, Sales, Fleet and Finance see the sections their work needs. An old link to a tab opens the section that holds it now.

Admin and staff open the same booking page, the same car page and the same listing review: you see every section and button, each staff function sees the parts it works with (Fleet has no Money section; only customer service and you have **Claims & extras**; refunds are asked for by you or Finance). A staff link to a booking opens the same page in the staff portal.

Every list has one search box (it finds names, numbers, plates, phones, emails and VINs) and one row of at most five chips. **Clear** removes every filter; the last one you used comes back next time on this device.

## Charge the renter after the return

Once the car is back, the Money tab has one action for everything owed after the trip: **Charge the renter**.

1. Press **Charge the renter**.
2. Choose the **Reason** from the list and add a note if it helps (Other needs its note). Enter the **Amount**.
3. Read the line under it: it says where the money comes from before anything moves. The deposit hold while it is still valid and covers the amount (the rest of the hold is released at the same time); otherwise the card on file; otherwise a pay link to the renter by text or email.
4. Press **Charge $...**. If the hold expired meanwhile, the card on file is charged instead, with the same amount and reason.

**Release** stays its own button. The renter''s receipt shows the reason.

## A deposit charged to a debit or prepaid card

When the deposit is charged instead of held on a debit or prepaid card (Charge the card on file as the deposit), the renter also pays the **Card processing fee for a debit deposit** (Program settings, 2.9% and $0.30 by default): a separate, non-refundable amount on the same charge. The Money tab''s history and the receipt show it; the deposit refund returns the deposit only.

## What the renter sees still to do

While a booking waits to be signed and paid, the Next step quotes the renter''s own Sign and pay card, for example: The renter sees: "Two steps left: sign the rental agreement, then pay $...". Signed for an older version of the offer counts as not signed: the renter signs the updated agreement on their Sign and pay page.

## Override a pickup or a return that must go ahead (release 33)
Sometimes the trip has to start (or end) even though a check still stops it. On the booking page, a confirmed booking (or one waiting for payment) and a car on rent show **What stops the pickup now** (or the return) with each check in plain words: the deposit not taken, the rental agreement not signed, no renter signature on the check-in report, a licence or identity not verified, the coverage not confirmed, an additional driver who has not accepted, the payment still due, the calendar switch off, the car not marked available, maintenance overdue, the Ontario licence, the fleet insurance policy (when that rule is on in Program settings), the agreement''s claim details, the tracker; at a return, an odometer lower than at pickup.

1. Press **Override and record the pickup** (or the return).
2. Give the actual time (now, or earlier), the km and fuel if you know them, and why the trip must go ahead. The reason is required.
3. Press the button. The pickup (or the return) is recorded at that time, only the checks listed are passed, for this booking and this once. The booking''s history and the audit log say who, when, why and which checks; every Admin gets the alert Override used. A payment still due is not waived: the booking is confirmed with the balance open, and the deposit is still to collect (it is not waived). The photos and readings come later, as with Record now.

When staff (Fleet, customer service, Sales, field staff) need it, they press **Ask an Admin to override the pickup** (or the return) on the same card with the time they recorded. You get the alert Override asked for and a line on the To do: press **Approve** (one tap) and it is recorded with the time they entered, or **Decline** with a note. The request also shows on the booking page, with Approve and Decline.

## Record a past trip (release 33)
A trip that happened but was never recorded (the pickup and the return both passed): on the booking page press **Record a past trip**. Give the actual pickup and return times, the km and fuel at each if you know them, and the reason. Every check that would stop it is overridden as above, in one step: the booking lands in **Returned**, the late return charges follow the actual return time, and the deposit can be settled. The car''s status today is left as it is, and the renter is not sent a "your rental started" email for a trip long over. Fleet gets the task to add the photos and readings. Staff ask for it the same way; you approve in one tap.

## Book it now: an offer that is a booking at once (release 33)
When you send an offer (answering a request, or **Send an offer** without one), tick **Book it now (no renter approval)** above Send. The offer becomes the approved version at once: the booking waits for payment, the car is held for its dates as for any approved offer, and the renter gets one link to the **Sign and pay** page to sign and pay (the "approve your offer" email is not sent). To have them sign and pay with you, open the booking: **Sign now on this device**, then take the card on this device. When customer service or Sales tick it, the offer goes out and you get the alert Override asked for and a To do line: **Approve** in one tap books it the same way. The booking''s history says who booked it and that the renter did not approve it.

Already sent the offer? Tell Claude or the assistant: "Book the offer of CC-10482 now, the renter agreed by phone". Claude''s connector has the tool **Book an offer now**, and **Send an offer** and **Make an offer** take Book it now too; the assistant (Assistant at the top of the menu) takes it in the same sentence as the offer. Each is two steps: you see what will change (nothing is changed yet), then you confirm, and the booking waits for the renter to sign and pay as above. As an Admin it is done at once; when customer service or Sales ask the assistant, it waits for your one-tap Approve.

## A request replaced by a newer one
When a request or offer expired and the renter made a newer one for the same car and dates, the old one is hidden from Requests and keeps its number and history. Both booking pages say so under the title: **Replaced by #CC-10483** on the old one and **Replaces #CC-10482** on the new one, each a link to the other. Customer service, Sales and the other staff pages show the same note.

## Change protection (release 41)

How damage to the car is covered is one control on the booking page: the **Protection** card at the top (Overview and the Money tab). An Admin, customer service and fleet use it on any booking; sales on a request or an offer.

1. Press **Change protection**. A small window lists the three options: **Own insurance (OPCF 27)**, **Credit card coverage** and **Protection Plan**, each with the price difference (the plan shows its price a day times the days, plus HST), the deposit (no coverage rule changes it) and what the renter provides.
2. The rule is the same as on the renter''s page: credit card coverage needs the renter''s card picked from the coverage list, a card that covers this car, and the renter''s confirmation that they pay with it; OPCF 27 needs the renter''s confirmation that they upload their policy; otherwise the Protection Plan. An Admin can tick Admin override: the reason is recorded on the change and in the booking history.
3. Write the reason (required; the renter reads it) and press **Change protection**.

What happens: the booking is repriced at once. More to pay is a balance to collect on the Money tab; less, when the plan was paid, is a refund for an Admin to approve. No money moves by itself. An offer is sent again as a new version; a confirmed booking or a rental in progress gets the amended agreement (the renter signs the new version when the rules ask) and one email. Proof tasks follow the new option. Changes are refused after damage is reported on the booking.

A renter''s request to leave the Protection Plan shows on the same card with their proof (**Open the proof**). Customer service or an Admin presses **Approve** (the change is made and the coverage confirmed) or **Decline** with a note the renter reads. The task "The renter asks to leave the Protection Plan" opens the booking.

## Change the car before pickup

On a request, an offer or a confirmed booking that is not picked up yet, press **Change the car** at the top of the booking.

1. Choose the new car. Only cars free for the whole booking are listed, each with its new total and the difference.
2. Say why the car changes, then press **Change the car**.
3. The price comes from the new car''s rate sheet (its rates, the km included and the rate per km). The coverage, the drivers and the add-ons stay as they are.
4. An offer is sent again with the new car: that offer is the renter''s one email.
5. On a confirmed booking, more to pay is left open: the renter sees **Pay the balance** on their booking, or you send a pay link or charge the saved card from Money. Less to pay becomes a refund that waits for approval, with a To do for Finance. The renter gets one email, **Booking updated**, with the new car and the money.
6. The open handover and return jobs move to the new car. The agreement gets a new version for the renter to sign; its link goes by text.
7. The booking''s history and the audit log keep who changed it, from which car, to which car and why.

Customer service and Admins change any of them; Sales changes a request or an offer; Fleet changes a confirmed booking. Once the car is out, use **Swap vehicle** instead.

## The accident card of a booking

Every booking from confirmation to the return shows its **Accident card**: the steps after an accident and the coverage this booking uses.

- OPCF 27: the renter''s own insurer and policy number, from the proof they uploaded.
- Credit card coverage: the card and its coverage provider, from their proof.
- Protection Plan: the provider, the policy number and the claims phone from Settings > Program (Tolls and damage), with the renter''s plan reference.

Press **Print the card** for the printable card. The renter has the same card on their booking. It never shows the fleet policy.

## Close ended trips

A back-dated close sends the renter no email or text. Fleet gets a To do when a trip is still open 2 hours after its return time, and the morning digest lists how many are open.

**Bookings** shows a banner when trips have ended and are not closed; **Close ended trips** lists each one: never picked up in the system, on rent after the return, or returned and never closed. Fleet and Finance have the same page.

1. Tick one or several, then **Mark them**: returned on time, returned late (give the time it came back), or a no-show (an Admin or customer service).
2. Choose the deposit: **Deduct the balance owed**, **Deduct the late fee**, or **Release in full**. A card hold that has expired is marked settled at once (released by expiry: no money moves).
3. If no deposit was taken, an Admin fills **Admin: deposit not taken, waive it because** (the same field is in Record a past trip).
4. Nothing is released by itself: the decision waits under **Deposit decisions waiting for an Admin**, and an Admin presses **Release** (or **Release now (tolls window)**).

## Return charges

A late return is charged per started extra day at the booking''s full daily cost (the rental per day after discounts, plus per-day and per-trip fees such as the Protection Plan, never delivery), and only the started hours after the whole days get the hourly late fee. On the booking''s **Money** tab, each renter line not on a statement yet has **Change amount** (lower) and **Waive**, with the reason; it is in the booking history and the next assessment keeps it. An expired card hold after the return has **Mark settled (released by expiry)**.

## Switching a booking to the Protection Plan (release 43)

**Change protection** > **Protection Plan** uses the car''s own plan price, the same amount the window quotes. It is no longer refused when Fees has no flat Protection Plan amount.

## The Protection Plan priced from RentalCover (release 35)

The Protection Plan stays our product: renters never see the RentalCover name. Without the RentalCover partner key it is priced from the Protection Plan table, as before. Once the key is set, its price comes from a real RentalCover quote for the renter (their dates, their age at pickup, their name and email) plus our markup (20% unless **Settings** > **Program** changes it). The request form asks for the quote once the renter''s details are in, and an offer as you choose option 3; a quote is reused for 15 minutes. A price you type for the plan wins. If RentalCover does not answer, the table price applies.

RentalCover covers up to $50,000 an incident, so the plan is offered only for a car worth less. The value used: your override under **Value for the Protection Plan** on the car''s page when set, else the car''s Canadian Black Book value, else an AI estimate from typical listing prices that the site makes by itself (**Refresh the AI estimate** asks again). A car with no value counts as over the limit: the request form, the offer screen and the database then offer only OPCF 27 or credit card coverage.

## Extensions at the all-in price a day (release 35)

An extension costs what the renter already pays, averaged per day: the booking''s total for the booked period (the rental after discounts, every fee, one-time fees like delivery included, and HST) divided by its days, for each added day. A booking of $729.36 for 7 days costs $104.19 for each added day. Added hours under a day cost the hourly late fee with HST, never more than a day. There is no extension discount.

| Where | What happens |
| --- | --- |
| The renter''s **Extend** page | Each option shows the total and the price a day before paying |
| **Edit** on a confirmed or on-trip booking, made longer | The booking''s new total is the all-in price of the longer stay; the per-trip fees stay as booked and the rental charge takes the difference |
| The next period of a long rental | Keeps the rate of the booked period (the rental a day, per-trip fees scaled) |
| An insurer-billed booking | Priced as before |

The extension is one line on the booking, "Extension: 3 days at $104.19/day (all-in)", HST included. Its HST is the booking''s own share of HST, so invoices and the books never add HST on top. Type a rental charge in **Edit** to set another price. Late returns are unchanged: the daily cost of each extra day and the hourly late fee.

## A fixed amount per payment (release 35)

On a weekly, every 2 weeks or monthly plan, an Admin can set **Fixed amount per payment** in **Change the plan**. Each payment is that amount and the last one takes the remainder. The total and the payments already made never change. Leave it empty to split the payments by the days again. A payment of $0 is never shown: when the fixed amount covers the total early, the last period joins the payment before it ($1,850 at $925 every 2 weeks is 2 payments).

## A payment plan''s first payment confirms the booking (release 48)

On a weekly, every 2 weeks or monthly plan, the booking is confirmed once the first payment is paid, by a pay link, the saved card or a payment you record. The rest is collected by the plan, as on a confirmed booking.

## Change the car of a booking partly paid (release 48)

A booking waiting for payment that already has a payment can be changed with **Edit** on its Overview, as a confirmed booking is: another car, the dates, the places. The car changes with the price as it is, new dates are priced at the booking''s own rates, and every payment stays recorded. The new car and dates must be free. Edit the offer is for a booking with nothing paid yet.

> Good to know: Claude''s connector does the same with `change_booking`, and lets a main driver keep a licence from outside Ontario on one booking with `licence_let_go` (your **Let it go**, with the reason). Both show a preview first.

## The request as sent and every offer (release 35)

On a request or a booking, **Original request, as the renter sent it** shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. **Offer history** lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.

1. To go back to an old version, press **Revert to this offer** on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.
2. Check the price, then send it in step 3. Nothing changes until you send.

The **Coverage** line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.

## Send an offer in three steps (release 35)

1. **Car and dates**: the renter, the dates, the car and where they pick it up and return it.
2. **Price**: filled in from the rate sheet with the checkout''s fees and discounts. Change it only if you agreed another price.
3. **Review and send**: what changed, the message and how the link goes.

Rarely used options (billing an insurer, how it is paid, the calendar) are under **More options**. Send waits while the price is being worked out again after a date change, and one tap sends once.

## The owner''s own trip, instant bookings and Book it now (release 35)

- **Owner''s own trip ($0)**: the owner booked their own car. There is nothing to price or send; get the car ready.
- **Instant (repeat renter)**: a Gold renter or above (Rewards, release 40) with a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter''s instant booking away with **Take instant booking away**, on the booking page or on the renter''s page.
- **Any car, any time** (release 40): a Platinum renter asked for dates the car shows as taken. Fleet gets an urgent task due within 4 hours: confirm it, offer an equivalent car or an upgrade, or decline with a reason. Never cancel or move another renter''s confirmed booking for it. The task closes when the request is answered.
- **Book it now** pressed by staff waits for an Admin''s one-tap approval.

## Secondary contact and rideshare documents (release 35)

The booking shows the renter''s **Secondary contact** when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes **rideshare documents** (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.

## Offers, coverage, delivery and fuel (releases 35 and 36)

- Sending an offer is three steps: car and dates, price, review and send. Every request shows the renter''s original request as sent and every offer version, with who sent it and when; reverting loads an old version as a new offer to send.
- Instant booking: a verified Gold renter or above books an available car at once, signs and pays; the booking is marked Instant (repeat renter), and an Admin can take instant booking away from a renter.
- Card coverage is checked against the car: the card, the car''s value, its type and the rental length. A card that does not cover it cannot be approved. OPCF 27 needs both the pink slip and the endorsement page.
- Delivery is priced by distance from the company''s address (1570 Midland Ave, Scarborough): a base, the kilometres included and a rate per km, all in Program settings; a car''s own fee stays as an override.
- The fuel line at the return is suggested from the car''s tank, the weekly pump price and a multiplier, plus the refuelling fee, and checked on the deposit review before any charge.
- Owner price limits: the daily minimum and maximum of a car or an owner hold every price, discount and offer; only an Admin can allow one request outside them, with a reason.
- Rideshare and delivery work is allowed with the documents the renter makes on their booking page (rental agreement copy, coverage letter, vehicle letter); staff get an alert when they are made. The secondary contact shows on the booking.
- Mid-trip review ask: halfway through a trip of several days, the renter gets one short message asking how it is going; a problem they report becomes a To do for customer service.
- A car that has only test bookings can be deleted by an Admin; the test bookings go with it. A car with a real booking cannot be deleted.

## Check-in and check-out on one screen (release 42)

**Start the check-in (pickup)** and **Start the check-out (return)** on the booking, and **Check in** or **Check out** on the To do list, open the same screen field staff use, made for a phone held in one hand:

1. Every part is on one page in the order you do it, with a green tick once it is complete: the ready check, the renter, licence and card (one tap each), the odometer, fuel and keys, the photos, damage, the tracker, then the signatures.
2. What is known is filled in: the odometer and fuel from the Tracker when it reported in the last 30 minutes (else from the car''s last report), the keys, and Standard for the cleanliness of a return. Check each against the car and change what differs.
3. Photos are one tap each: **Take this photo** always shows the next angle.
4. What is optional is folded away: new damage, a note, belongings, a renter who is not there or will not sign.
5. The button at the bottom says what is still needed (for example "Next: Odometer") and takes you to it. When everything is in, press **Hand over the keys** or **Complete the return**.

Nothing was dropped: the condition report still needs every photo, the readings and the signatures, and the database refuses a handover with anything missing. Leave the page and come back: your answers and photos are still there.

**Check in with photos already taken (from the gallery)** is still under the button, for a car that was photographed earlier.

## A late return is a choice (release 42)

A car that comes back after the grace period is never charged by itself. The booking shows **Late return** with how late the car was and five choices, each with what it costs:

1. **Charge as an extension**: every started day late at the booking''s daily rate, as an extension would have cost.
2. **Charge extra days**: you choose the days, from 1 up to the started days, at the daily rate.
3. **Charge the late return fee**: the fee of the rental terms (whole days at the daily rate, the started hours after them at the hourly fee, capped a day).
4. **Charge a custom amount**: type the amount before tax and what it is for. The renter sees the reason.
5. **Waive it**: no charge, with the reason.

Press **Save the late return charge**. The charge goes on the return statement and is taken as every return charge is: from the deposit, then the card on file, then a pay link. The renter gets a message on the booking that says what was chosen, and the booking history keeps who chose and why.

Until someone chooses, nothing is charged for the late return and Fleet has the To do "Late return: choose the charge". Field staff can choose on the return screen as they complete the return.

> Good to know: A custom amount above your single limit, and a waiver by anyone other than an Admin, Finance or Fleet, waits for an Admin: they get the To do "Late return: approve the charge" and press **Approve as asked**, or choose another way. Only an Admin changes a late return that is already decided, and not once it is on a statement or paid.

On **Close ended trips**, marking a trip returned late and choosing **Deduct the late fee** is the same choice of the late return fee, made there. The other deposit choices leave the late return to be chosen on the booking.

## Picked up, deposit pending (release 48)
Staff who record handovers, and you, can let a car go with the deposit still owed, with the reason (Record the pickup now, the one-screen check-in, the field job, or **Deposit not taken: let the car go owing it** before the full check-in). The booking goes on rent and shows **Deposit pending $X** beside its status for every role, with who let it go and why. Each morning from the deposit hold hour the saved card is tried for the hold once; if it fails or there is no card, the deposit link goes to the renter. After 48 hours still unpaid you get the To do **Deposit still owed** and an urgent alert, both opening the booking''s Money tab. Taken, waived or the car back: it ends by itself. Program settings, **A car out with the deposit owed: try the saved card each morning, then send the deposit link**, turns the morning tries off. From Claude''s connector: record_handover with `deposit_pending: true` and `deposit_pending_reason`, previewed then confirmed.

## Long-term rentals paid weekly

For a renter who keeps the car week after week and pays each week:

1. Open the booking (confirmed, or the car already out). On the Overview or Money tab, the **Long-term, paid weekly** card: press **Turn on**. If the car has another booking or a block after the return, the card names it: move that first.
2. From now on the car stays out on the calendar and on the site until the renter gives notice. You never extend the return by hand.
3. Each week, when the renter pays cash or e-Transfer, use **Record a payment** for the rental as usual: the amount is the next week''s price, and the return moves 7 days.
4. 48 hours before the return (Program settings, **Long-term weekly rentals: hours before the return**), if the next week is not paid, the renter gets a pay link by text (else email) and you get a To do. Paying the link moves the return too, and the To do closes by itself.
5. When the renter gives notice, press **End rental on** and pick the last day. The last week stops on that day and the car shows free after it. Leave the date empty to go back to until notice.
6. **Turn off** makes it a normal booking again: the car shows free after the current return.

Claude''s connector does the same: `change_booking` with `changes.rolling_weekly` true or false, and `changes.rolling_end_on` for the last day; `record_payment` records the week.', 'Requests, offers and bookings', 'See what is out, coming back and owed now; send an offer with or without a request, change it in place, take payments by part, run a booking.',
  'A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.

## Bookings now: what is out, coming back and owed

Open **Bookings**. It opens on **Now**, one screen that refreshes by itself every 30 seconds. Every time is Toronto time.

1. The numbers at the top: cars out now, due back today, overdue, going out in the next 72 hours, payments due in the next 7 days (with the total) and free cars. Tap one to jump to its list.
2. **Out now**: every car on rent, overdue returns first in red. Each shows the car (photo, code, plate), the renter with **Call** and **Text**, when it was picked up, when it is due back with a countdown, the payment plan and the next payment, the deposit held, and the km and fuel at pickup. Filter by Overdue, Due today or Payment due.
3. A confirmed booking whose pickup time has passed with no check-in recorded is listed as out, with **Out (pickup not recorded)**. The car most likely left. Press **Mark picked up**: it records the pickup at the booked time (change it if the car left at another time), the booking goes on rent, and Fleet gets a task to add the photos, km and fuel. The usual checks stay: the deposit taken (or an Admin waives it with the reason), the renter''s signature (or an Admin''s reason), the agreement''s details, every driver verified and the coverage confirmed. If one is missing, the reason is shown.
4. **Coming back**: overdue, today and tomorrow, by the time each is due.
5. **Going out**: confirmed pickups in the next 72 hours, delivery or pickup, with ticks and crosses for the licence, the signed agreement, the payment, the deposit (a clock until the morning of the pickup day, when the hold is placed on the card on file) and the check-in photos (done at the handover).
6. **Money due**: every rental payment due in the next 7 days or overdue, the amount, the plan and which payment it is (for example 3 of 4).
7. **Free now**: cars available and not out, the longest idle first, with the next pickup; then the cars in maintenance or cleaning. Partners'' cars are counted apart.

> Good to know: Placeholder bookings never show on Now.

### Payment plans

A rental is paid in full at pickup, weekly, every 2 weeks, or monthly. A rental longer than one period (30 days) pays each period by itself. To change it, open the booking, then the **Payment plan** card on Overview or Money, and press **Change the plan**. Each payment is its share of the total by its days, due on the day it starts. An insurer-billed rental shows **Insurer billed** and is never in Money due unless the renter owes a part. Admins, customer service and finance change the plan; fleet sees it.

## All bookings

The **All bookings** tab of Bookings has the search (booking number, name, email, phone, plate or car code), the status (All, Out now, Booked, Returned, Cancelled; closed bookings are found with the search, which also finds the insurer). **Out now** shows the bookings on rent and those whose pickup passed without a check-in, together. Each booking is one row: its number and status in plain words, the car with its photo, the renter with **Call** and **Text**, the dates, the money (paid up, to pay, overdue, insurer billed) and Bill to.

## The request queue

Open **Bookings** > **Requests and offers**. The oldest waiting request is at the top.

1. The numbers at the top: waiting for an offer, past the reply target (red), offers out, accepted but not paid, and offers expired. Each one is a filter: press it and the list shows just those, with the matching chip below marked as chosen.
2. One queue, the most urgent first: the longest wait, then offers accepted but not paid, then offers out by when they expire. Each row has the car with its photo, the dates, the price, the renter with **Call** and **Text**, the licence (verified, to review, or not uploaded yet), who is answering it, and one button: **Send offer**, **Follow up** or **Open**. **Decline** sits beside **Send offer**.
3. Waiting shows how long the renter has waited ("12 min", "3 h", "2 days"); red means past the first reply target (5 minutes, set in Program settings). **Promise** counts down the 2 hours the site promises the renter.
4. Filter by Active, New, Changes asked, Offer out, Accepted, not paid or Expired. The list remembers your last choice on that device; **Active** always shows the whole queue and replaces what it remembered. When the same renter asks for the same car for overlapping dates again and the earlier request or offer expired, only the newest is listed: the older ones are linked to it and leave Requests (they keep their history). An expired offer leaves the active queue 48 hours after it expired, or once its pickup time passed; Expired lists the ones from the last 7 days. After 7 days an expired offer leaves Requests and offers and becomes a renter lead, once, in People > Renters > Leads (Expired offers), with the car and the dates the renter wanted and a To do for Sales to win them back. An offer still out when its pickup time passes expires by itself.

![](/guides/img/admin-02-requests-desktop-6521282d.jpg "desktop; size: 1440 820; address: carmacars.ca/admin/requests; pins: 1 38.9 29.9, 2 22.2 43.3")

> Good to know: A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless "Email the renter when their request expires that way" is on in Program settings.

## Answer a request with an offer

1. The Review and offer tab shows the request as the renter sent it.
2. Adjust the car, the dates, the rate type, the places, the rates (under **Show rate card**) and fees, the deposit and extras. A place changed away from a delivery or a collection takes its fee box and its fee with it.
3. Price on the right updates as you change things.
4. Add a message, then press **Send the offer**, the one main button at the bottom (Send the offer under Next step takes you there). How long it stays open, Email or Text and Book it now are under More options.

![](/guides/img/admin-03-booking-review-desktop-353f3707.jpg "desktop; size: 1200 1550; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 1 5.0 6.5, 2 7.5 45.8, 3 74.2 42.6, 4 76.7 98.1")

5. Changed fields but not ready to send? Press **Save without sending**. The panel "The offer as the renter sees it" shows the result.
6. Can''t do it? Press **Decline** and fill in Reason and any alternative.
7. Need an answer first? Press **Ask the renter** to send a question.

![](/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg "desktop; size: 500 80; address: carmacars.ca/admin/bookings/CC-10069?tab=review; pins: 6 41.2 52.5, 7 18.0 52.5")

Opening a request takes it for you: everyone else sees "Being answered by" your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press **Take over** to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.

## Send an offer without a request

Press **Send an offer** at the top of Bookings, or **Send an offer without a request** on Requests and offers. For a customer on the phone, by text or at the counter: no request needed.

The screen is seven short steps, each with one line saying what to do, and the price beside it (on a phone the total sits at the bottom of the screen: press **See every line**). What most offers never need is under each step''s **More options**, which stays open while something in it is used.

1. **Who is renting and when**: find the renter by name, phone or email, or press **Not on file? Add a new customer** (full legal name, mobile, email for the offer link, date of birth). A customer already on file with the same email or phone is shown with Use: one person, one record. A renter picked from the file shows what is on their record under their name: the licence (class, number, expiry), the home address and the drivers named before, with a licence that has expired or an address over a year old flagged to ask them about. Then the pickup and the return.
2. **Which car**: search by car code, plate or name; each car says Free or Not free for the dates. More options: the rate card and the type and free-only filters.
3. **Where they pick up and return**: at our location, we deliver or collect (the address and distance), an airport or the owner''s location. The fee each one makes shows under it, Automatic or Set by hand.
4. **How damage is covered**: the renter''s own insurance, a credit card or the Protection Plan. More options: another Protection Plan price.
5. **Extras**: add-ons, when the car has any.
6. **The price**: the rate sheet price is filled in. More options: another price (a total for the trip or a rate a day, with why), Amounts I type (before or after HST), the total the renter pays, kilometres, a promo code, the deposit and a discount (an Admin), and **Fees**: press **Change** to set one by hand, **Reset to automatic** to undo it. Below: how it is paid (card online and a card hold unless you change it under More options).
7. **Send it**: who found this client (sales and customer service), a message, and Text or Email. More options: how long the offer is open, the owner''s view, who found the client (an Admin) and the internal note. Above the button, **Ready to send** or **Missing:** with what is left; press Send and each missing field says what it needs. Press **Send the offer to** the renter, or **Save without sending** to keep it as a request for later. **The offer as the renter sees it** is under the price.

> Good to know: Choices drive the charges. Take off a delivery, a collection, the Protection Plan or an add-on and its fee goes with it, even a fee set by hand: there is nothing to remove in a second place. Choose it again and the fee starts from the automatic amount.

> Good to know: It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No "request received" email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.

## Change an offer that is out

The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Open **More actions** on the booking and press **Edit the offer**.

1. Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.
2. Write what changed in Message to the renter. How long the offer is open and Email or Text are under More options.
3. Press **Send the update**: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press **Save without sending** and tell them yourself. After you save, the screen shows the offer as saved.
4. A confirmed booking is changed with **Change the booking** (Propose a change, below).

> Tip: No need to withdraw first. **Withdraw the offer** is only for taking it back for good; **Send again, later expiry** gives the renter more time, and **Renter approved by phone** records a yes given on a call.

## Edit a booking that has started

On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, **Edit the booking**, **Edit**.

1. Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking''s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.
2. Type why, if you like, and tick **Email the renter what changed**, or leave it off for a silent correction. Press **Save the changes**.
3. What is open now shows at once: **Email a pay link** or **Text a pay link** for exactly that amount, **Charge** the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.

> Good to know: Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking''s history. A closed booking''s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.

## Restore a version of a confirmed booking

Once a confirmed booking has been changed, Overview shows **Versions of this booking**: the booking before its first change, then one version after each change (a fee changed on its own too), the newest marked current.

1. Find the version to go back to (its dates, days, car, rental charge and total are listed) and press **Restore this version**.
2. The preview shows what changes: the dates, the car, the rental charge, the total, and what the renter would owe or be owed. Nothing is changed yet.
3. Type why, tick **Tell the renter what changed** if they should know, and press **Restore version** with its number. The dates, the car, the rental charge and every fee go back exactly as they were in that version.
4. It is one more change in the history, with your name and the reason. Payments are never touched: a difference is a balance to collect or a credit to settle, as with any edit.

> Good to know: The same checks as Edit: the car must be free for those dates, and customer service and Sales restore only while Program settings let staff change bookings (and fees). A version kept before Release 45 has no fees with it: its dates, car and rental charge go back and the fees stay as they are; the preview says so.

## Fees, a forgotten fee and the balance

On the booking''s Money tab, Fees lists each fee. Press **Change or add a fee**.

1. Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.
2. Press **Save the fees**. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.
3. The renter sees the balance on their booking with a Pay button, and pays by card on Stripe''s form.

> Good to know: Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.

> Good to know: Changing the amount of a line on the Money tab changes the booking''s total and balance with it, so no balance appears that nobody owes. An Admin can set the total directly with **Change the total**: the difference goes on the rental charge.

## A renter with only a debit or prepaid card

A credit card is required by default: the deposit must be on a credit card so the deductible can be charged. The pay page tells a renter with only a debit or prepaid card to contact us.

1. On the booking''s Money tab, press **Allow debit and prepaid cards for this booking** and type the reason. Who and when are kept, and the change is in the booking''s history.
2. The booking''s pay page, staff pay links and deposit hold then take a debit or prepaid card, and the renter is told the hold lowers the money available on the card until it is released, which can take several business days.
3. **Require a credit card again** turns it off.

The Money tab shows each card used and its type (credit, debit, prepaid). A booking on credit card rental coverage is always paid on the credit card that carries the coverage, and cannot be allowed. Program settings, **Card types accepted**, can open debit and prepaid cards to every booking.

## Correct a renter''s details

On the renter''s page (People, Renters) or on any of their bookings, **Edit renter**.

1. Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.
2. A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick **Email the renter a link to set a password** to send one there. Unsigned agreements and offers go to the new address.
3. Press **Save the renter**. An email that another renter has is refused with their name; the same phone is a warning.
4. The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. **Merge into this record** moves the other record''s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.

## The Money tab: Rental charges and Security deposit

The booking''s Money tab opens on a strip with the three numbers that matter: **Rental due**, **Deposit** (one word: Not collected, Held, Charged, Released or Partly kept) and **Total paid**. Below are two panels, side by side on a computer and one above the other on a phone. Collecting one never touches the other, and every receipt says which one it is.

**Rental charges**: each line of the price and the total, Paid, then Balance due.

1. The one main button, Collect (the amount) rental: choose how. **The card on file** charges it now (Finance or an Admin); **A payment link by text** or **A payment link by email** sends the renter Stripe''s secure form; **On this device: hand it to the renter** opens it for the renter to type; **Cash, e-Transfer or another way (record it)** records money received (an e-Transfer, cheque or transfer needs its reference). For: the rental and fees together by default, or one of them. With the card on file, the rental and fees together are one charge with one receipt that lists both (the rental is paid first, then the fees; an insurer''s part and money already received another way are left out). The renter gets a receipt; **Print** prints one to hand over.
2. **A later charge** (before the return): on the card on file, by a link, on this device, or recorded. Choose the **Reason** from the list (Mileage overage, Fuel, Cleaning, Smoking, Late return, Tolls, Tickets/fines, Damage, Missing items, Other) and add a note; Other needs its note. The renter''s receipt shows the reason.
3. **Save a card** saves the renter''s card without charging it. Card readers, the fees (**Change or add a fee**), failed card payments (**Paid another way**), payments received another way and **Refund** sit in this panel too. The history lists rental payments only.
4. An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press **Confirm the booking**).

**Security deposit**: the amount, how it is taken (a credit card hold, a debit or prepaid card at the standard multiple, a charge, or cash), its status in one word and the next step.

1. Not collected: the one main button, Collect (the amount) deposit. **Hold on the card on file** places the hold now (Finance or an Admin); **A deposit hold link by text** or **A deposit hold link by email**, or **A hold on this device: hand it to the renter**; **Charge the card on file as the deposit** only when no hold can be placed; **Cash or e-Transfer (record it)**. The rental balance is not touched.
2. Before every pickup the deposit hold link is texted to the renter on its own: 24 hours before (at once when the pickup is sooner), for a confirmed booking whose deposit is a card hold with no hold yet. The panel says **Deposit link texted** and when it was opened. No mobile number, or the text not sent: a task **Deposit link not sent**. **Settings**, then Site settings, Deposit link by text: on or off, and the hours.
3. Held, while the car is out: **Release** (an Admin, with the reason), **Keep part (damage/fees)** with the amount and the reason from the list, or **Re-authorize the hold** on the saved card before it lapses (the panel shows when the hold expires). A job re-authorizes it by itself about 24 hours before it expires; if it cannot, Finance and the Admins get the alert **Deposit hold not re-authorized**.
4. **Hold expired**: a card hold lasts about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. Once it has expired, nothing can be kept from it: the panel says Hold expired, Keep and Release are hidden, and **Charge the card on file instead** opens the later charge with the amount and the reason filled in.
4. After the return: **Settle the deposit** (below).
5. **Waive the deposit** (an Admin, before it is taken), **Change the debit deposit**, and **Allow debit and prepaid cards for this booking** sit in this panel. The history lists deposit payments only.
6. A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press **Returned** with the reference or receipt number.

> Good to know: Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.

## Settle the deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-out statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: **Keep the whole deposit (damage)** turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. **Bill damage** adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## A booking

Open **Bookings** > **Bookings**, then a booking number. Or type the number in the search box.

1. Tabs: Overview, Money, Changes, History, and Drivers and documents.
2. Overview shows the trip, the renter, what is still missing for the handover, and the price.
3. Open tasks for this booking, with the queue and the due time.
4. Top right: **Email the renter** and **More actions**, the menu with **Edit the offer**, **Stop blocking the calendar**, **Cancel for the renter**, **Cancel by CarmaCars** and the rest.
5. Under the booking number: **Next step**, what happens next and who does it, with one button for that step (for example **Send the offer**, **Sign on this device** or **Check in the car**); then where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.

![](/guides/img/admin-04-booking-desktop-b56b668a.jpg "desktop; size: 1440 960; address: carmacars.ca/admin/bookings/CC-10065; pins: 2 50.0 46.6, 4 85.4 14.5, 5 22.9 26.8")

## Check a car out or in

From the booking, with your phone or a tablet: the same checklist field staff use.

1. A confirmed booking shows **Check in (pickup)** under Check-in, check-out and signing; a booking on rent shows **Check out (return)**. Today lists the check-ins and check-outs due, each with **Check in** or **Check out**.
2. The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.
3. Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.
4. A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press **See the photo report**.

> Tip: Fleet, Sales and Customer service check cars out and in the same way from their own booking page.

## The photo report, late returns and the return charges

Under Check-in, check-out and signing, press **Photo report**.

1. The report shows the due-back time, the actual check-in and check-out, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.
2. At check-out the mileage overage and the fuel or recharging are written to the return charges at once. A late return (after the grace period of the fee defaults) is not: it waits for a choice on the booking (see "A late return is a choice"). The fuel is a suggested line: the car''s tank x the fuel missing x the pump price of its grade (Program settings, updated weekly) x 1.25, plus the refuelling fee; an electric car the battery kWh x the charge missing x the price a kWh, plus the fee. A pump receipt entered later replaces it. Fleet and Finance confirm it on the deposit review; it is never charged to a card by itself.
3. Not charging one? Press **Waive** beside it and give the reason: it stays waived if the charges are worked out again.
4. The time was wrong? Press **Correct the check-out time** (or the check-in time) with the reason: lateness follows, a return that is no longer late loses its late charge, and the history keeps both times.
5. The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.

### The renter says the car is back

Every overdue email, text and alert (at the return time, at 15 minutes and the final notice) has a one-tap **I''ve returned the car** link, and the renter''s booking page has the button. The renter can add photos, the odometer, the fuel level and the time they returned it. Sending it stops every overdue notice of the booking at once, the booking shows **Returned, waiting for confirmation**, and Fleet gets an urgent To do: "The renter says the car is back".

1. Open the booking. The card **The renter says the car is back** shows what the renter gave, marked renter-provided, with their photos.
2. Check the car: the return place, the tracker, the photos.
3. Press **Confirm** to complete the trip. Correct the odometer, fuel or return time first if they are wrong: the late charges follow the time you confirm. The renter''s photos join the check-out report.
4. Or press **Deny** and say why. The renter gets your reason by email and text, and the overdue notices start again.

Checking the car in the usual way also completes the trip and stops the notices. Admins, Fleet, Sales, Customer service and field staff can Confirm or Deny.

## Signatures on the spot, or by link

The renter or an additional driver signs the rental agreement on your device, or on their own phone.

1. While a signature is missing, the booking shows **Sign now on this device**, **Email the signing link** and **Text the signing link**.
2. No agreement made yet (the renter has not saved their details at home)? **Sign now on this device** still shows: press **Prepare the agreement to sign now** and it is made on the spot.
3. **Sign now on this device**: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press **Hand the device to** and their name.
4. They read both agreements (CarmaCars'' and Blind Spot''s), tick the statements and sign. Then **Back to the staff view** for the next signer.
5. The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy''s signature record page.

## Rental agreements: every version, every field

The booking''s Rental agreements card: the current version of CarmaCars'' and Blind Spot''s agreements, every earlier one, and what is still blank.

1. Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.
2. A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows "Agreement v3 waiting for signature". A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.
3. Check-in makes the "as picked up" copy (time out, km out, fuel out, the car''s plate and VIN, the check-in report), countersigned by whoever checked the car out; check-out makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.
4. **Every version** lists each one with what changed and both PDFs. **Resend the signing links**, or press the button with their first name beside it to have them sign on your phone or tablet.
5. The card lists what the agreements still print blank (a licence expiry, the insurer''s policy number, the insured vehicle, a VIN). Type the values and press **Save the missing fields**: the agreements follow.
6. Check-in stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press **Override**; the reason is in the booking''s history.
7. **Make the agreements again** checks both against the booking at once (they also follow every change by themselves).
8. **Edit the wording** (Admin only) changes CarmaCars'' agreement text for this booking: press **Change** beside a clause, edit its text, say why and press **Save the wording**; **Add** writes Additional terms at the end of Part 2. Only clauses not required by law or the insurer can be removed; the consents are fixed, and Blind Spot''s form (the insurer''s official form) is never changed. Before the renter signs, the agreement is made again; after, the change is a new version they sign, and **Every version** shows each clause before and after.

## Signing that holds up in a dispute

Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner''s link, the partner, investment and staff agreements.

1. The licence on file is shown. A 6-digit code to their phone or email on file is optional: the signer may press **Verify by code (optional)**, and Program settings, E-signing, **ask for a one-time code** makes it a required first step again (off by default). Without the code, the certificate says the identity was not confirmed by a code.
2. They say they read the documents, initial the key terms (each initials box is saved with **Save initials**; **Clear** takes it back to initial again) (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.
3. Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement''s three confirmations, Form C''s acknowledgments, Schedule C, the staff agreement''s confidentiality), two consents and the drawn signature. Form C''s witness still types their name beside the owner.
4. Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at `carmacars.ca/verify`.
5. Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: **Settings** > **Program**, Esign typed fallback.

## Card disputes: the evidence pack

Everything that proves the rental, in one PDF for Stripe.

1. When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-in and check-out reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute''s evidence, and To do gets an urgent task.
2. Open the booking: the Rental agreements card shows the pack. Press **Download** to check it, then **Submit to Stripe** before the evidence date.
3. **Build the dispute evidence pack** makes one at any time (an Admin or Finance).

## The licence before an offer is accepted

Front, back and a selfie, from the request on.

1. After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.
2. The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.
3. Review the images as usual with **Review documents**: the card Renter documents is on Review and offer too.
4. The switch is in **Settings** > **Program**, Booking requests and offers: Booking licence required (on), with the selfie (on).

## The licence reader

Every licence photo is read on upload: the back''s barcode first, else the vision model (within the day''s AI allowance).

1. The renter''s empty licence fields are filled from the read; the renter confirms them. A blurry or cut-off photo is taken again at once.
2. **Review documents** shows what was read and one line per check, Pass or Flag: photos, valid to the return, class accepted, age at pickup, name and date of birth, the Ontario number, front and back, and the main driver''s Ontario licence. Staff still approve.
3. **Settings** > **Program**, Driver''s licence reader: **Approve automatically when every check passes** (off). On: a driver whose front and back both read sharp and every check passes is approved in your name; anything flagged waits for a person.
4. **Primary driver must hold an Ontario licence** (on): a main driver with a licence from elsewhere becomes an additional driver, the booking needs "Primary driver: Ontario licence needed" and pickup is blocked. The renter adds a main driver, who signs on their own link. On the document review, **Admin: undo or let it go**: undo puts the first main driver back; let it go needs a reason.

> Tip: What was read is staff only and is deleted with the licence image. The licence number is never written to the logs.

## Renter documents: licence and proof of coverage

A renter''s licence photos, selfie and proof of coverage (OPCF 27 or a credit card''s rental coverage) are checked before the handover. You check them yourself; no task is needed.

1. A booking with documents waiting is a line on To do: "Check ''s documents for booking ", marked Now when the pickup is within two days. Press **Review documents**.
2. The pop-up shows each driver''s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.
3. What to check is written once at the top. One wrong? Open **Reject this one** under it, type the reason the renter reads and press **Reject**: they are asked for a new one.
4. Then press **Approve all**: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. The number in the button is exactly what it approves (an image whose file was removed is not counted), and an image not tied to a driver of the booking is listed under **Other documents**. Anything the system refuses is named with the reason.
5. The same pop-up is on the booking: the card Renter documents (**Review documents**) on Overview and on Drivers and documents.
6. A document already approved or rejected, and each page of the proof of coverage (pink slip, OPCF 27 endorsement page), has **View**: it opens the image (or the PDF) again through a link that lasts one minute, and the view is written to the audit log. After the 90-day removal of identity images the line reads **Removed on** and the date, with nothing to open. Owners never see these documents.

> Tip: Each opening of a renter''s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-in (photos and four checks): the history says "checked in person". Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer''s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.

## Payments by day

**Money** > **Payments**, the **By day** tab: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.

1. Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press **Show**.
2. Totals by method and for each day; cards read as the card and its last four digits, never a code.
3. The cash drawer: expected (cash in less cash given back) against the count Finance records with **Record the count**; a difference shows over or short.
4. Refunds waiting: every refund asked for anywhere with the policy maths. **Approve** or **Decline** with the reason in the row, then **Issue the refund**.
5. **Export CSV** for the bookkeeper.

## Propose a change to a confirmed booking

The renter gets an email and answers on their booking. The calendar moves only when they accept.

1. Open the booking''s Changes tab. Under Propose a change, set the new pickup, return or car.
2. Leave the price empty: a later return costs what a day of this booking costs (rental, fees and coverage, HST included; the preview shows the price a day). To price it by hand, type a New rental charge before tax, or the new total with HST.
3. Write the Reason, for the renter. They read it.
4. Press **Preview the price**, then **Send to the renter**.

![](/guides/img/admin-05-booking-changes-desktop-97008b21.jpg "desktop; size: 1200 520; address: carmacars.ca/admin/bookings/CC-10065?tab=changes; pins: 1 17.5 33.7, 2 9.2 50.0, 3 38.3 71.2, 4 12.9 91.9")

## Who a booking is credited to

Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.

1. A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.
2. To give it to someone else, press **Reassign**, choose who (or Nobody), say whether they sourced the client and write the reason. The booking''s history and the audit log keep it, and the deal stays in the same week and month.
3. Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.
4. Someone said they sourced a website request? The credit line shows the claim: press **Credit them** or **Not theirs**, with a reason.
5. A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press **Mark reviewed** once you have looked at it.

> Good to know: A request keeps the lead-time adjustment of the moment it came in ("Short-notice pricing +10%" or "Booked ahead −5%"), through the offer and the payment. To change it, open the booking''s review screen, **More options**, **Lead-time pricing (%)**: a number (0 for none), or empty for the tier of the request. A price typed by hand replaces it.

> Good to know: The rental never goes below the car''s minimum daily rate or above its maximum (its price limits, set by the owner or on the car''s Rates tab), whatever the discount, promo code or lead-time pricing: a line "Minimum daily rate for this car" or "Maximum daily rate for this car" brings it back. Only an Admin allows a price outside them: **More options**, **Allow a price outside the car''s price limits (Admin only)**, with the reason.

> Tip: The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.

## Review requests

Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.

| Message | When |
| --- | --- |
| Mid-trip check | Rentals of 2 days or more, 24 hours after the pickup: "How is the car? Reply or call if anything is off." No review ask. |
| Review request | 1 hour after the check-out. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google. |
| Reminder | 24 hours after the request. |
| Final follow-up | 7 days after the request. Nothing more after it. |

1. The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.
2. **Ask for a review** sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.
3. On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press **Send anyway** to send it now.
4. **Mark reviewed** stops the messages when the renter tells you they already reviewed.

The messages also stop by themselves when the renter presses "I already left a review", leaves a review on the site, unsubscribes, or a Google review is matched to them. **Bookings** > **Reviews** has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.

> Tip: The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees "Something wasn''t right? Tell us directly".

## What the owner sees, and owner deductions

Each booking on an owner''s or partner''s car shows the card What the owner sees at the top of its page.

1. **Hide from the owner** keeps the booking''s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.
2. **Show to the owner** shows it now. Approving the statement shows every hidden booking on it by itself.
3. Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder''s or the owner''s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.
4. Add a rental and Send an offer have What the owner sees. It starts from Settings > Program, Owners and fleet: Owners see a booking''s revenue (right away by default).
5. On the Money tab, Owner deductions on this booking: **Add a booking expense** (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.
6. **Set the Revenue Share for this booking** applies within the car''s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. **Back to the car''s terms** undoes it.
7. Add a rental has the same under The car''s owner.

> Good to know: The owner''s statement carries each booking that counts toward the owner''s revenue, at its true amounts, and lists each deduction with its reason, so the payout is always right. A booking billed to the renter always counts. Left out: a booking billed to an insurer and hidden from the owner (while Program settings keep only insurance replacements hidden), an insurer-billed rental that does not block the calendar, and a rental with "Counts toward the owner''s revenue" off. The booking page says when a booking is not part of the owner''s revenue and why. When a booking that was left out starts counting (Blocks the calendar turned on, shown to the owner, or billed to the renter), the owner gets the new booking email once, at that moment. Customer service and sales add deductions only while Program settings let them change fees.

## Email the renter or the adjuster

Press **Email the renter** at the top of a booking, or open its **Messages & history** section.

1. Write a **Subject** and a **Message**, or pick a **Quick reply** to start from (Settings > Quick replies keeps them).
2. Press **Email the renter**. It goes from CarmaCars (bookings@carmacars.ca) and replies come back to the bookings inbox. The renter also sees it in their account and can answer there.
3. On a booking an insurer pays, choose **From**: CarmaCars, or Blind Spot Car Rental (insurance). **Email the adjuster** writes to the adjuster''s email on the booking (Insurance claim), always from Blind Spot Car Rental.

The **Messages & history** section is the booking''s Activity log (release 35): what you and the renter wrote, every email of the booking, the texts, chat, calls, notes, events, payments, documents and visits, newest first, with a chip for each type and a search. The email form is under the log; each email you send shows in the log with your name.

> Good to know: Emails go out through the same daily limit as every email (the line under the form shows today''s use). A message to a renter goes before digests and marketing; past the limit it waits until midnight. To write to a renter from **People** > **Renters**, open the renter: Email the renter is at the bottom, about their latest booking or the one you pick.

### Record the pickup or the return now (details later)
When the car went out or came back but the checklist could not be done (no photos, no time, the renter dropped the keys), the booking''s **Check-in, check-out and signing** card has **Record the pickup now (details later)** on a confirmed booking and **Record the return now (details later)** while the car is on rent. Give the actual time (now, or earlier), the odometer and fuel if you know them, and why. The booking moves on (on rent, or returned), late return charges follow the actual time, and Fleet gets the task **Add the photos and readings for CC-...**. A car overdue or due back today also has **Returned**: on the To do list (Check-ins and check-outs today), on Bookings > Now and at the top of the booking page, which the late return alert opens. It asks only the return time (now, or earlier) and the km and fuel if you know them, and records the return the same way. Once returned, the statement can be issued and the deposit settled; releasing the deposit before the photos are in needs an Admin and a reason. A pickup without the deposit taken needs an Admin to waive it with a reason, and without the renter''s signature on the check-in report an Admin''s reason too. Later, **Add the check-in (or check-out) photos and readings** opens the usual checklist (photos, readings, your signature): the task closes when it is saved.

The Agreement card says **Waiting for the renter''s details** when the renter still has blanks to fill (date of birth, address, mobile, licence, coverage): their account asks for them before signing and paying. No email or text is sent.

### Find a booking
**Bookings** has one search box: type the booking number (CC-1042, cc1042 or just 1042), the renter''s or a driver''s name, an email, a phone number in any format, a plate (spaces do not matter) or a car code, then press Enter. The status filters still apply to what is found.

### Record a card payment taken outside the site
A card taken in the Stripe Dashboard, or on a card reader, is recorded on the booking''s **Money** tab with **Record card payment**.

1. Choose what it paid: **Rental and fees**, **Rental**, **Fees**, **Later charges** or **Deposit hold**, and where it was taken.
2. Type the **Last 4 digits** and the amount. A Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard) is optional for a payment: press **Look up** and the amount and last 4 digits are checked against Stripe.
3. Press **Record it**. A payment confirms a booking waiting for payment, as any payment does.

> Good to know: A deposit hold needs its Stripe payment id, so it can be captured or released from **Settle the deposit**. It is recorded as held, with the usual release reminders. A hold on a reader lapses after 2 days, one made online after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise.

### Link a payment taken outside the platform
A charge or a card deposit taken in the Stripe Dashboard or through a Stripe payment link is linked to its booking by an Admin, on the booking''s **Money** tab: **Link a payment taken outside the platform**, in the rental panel or the deposit panel.

1. Paste the Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard). **Look up** shows what Stripe says: the amount, paid or a hold, and the card.
2. Press **Link as a rental payment** or **Link as the deposit**.

> Good to know: It must be in Canadian dollars and not already linked. A rental payment may not be more than is open for the rental and fees. A deposit must be the whole deposit: a hold waiting to be captured is kept as held (settle it as any hold), a charged deposit is kept as captured. **Money** > **Unlinked Stripe** lists, every night, the Stripe payments of the last 60 days that no booking knows, with a best guess of the booking.

### Charge or hold the deposit on the card reader
With the S700 paired (Settings > Card reader), the **Money** tab has **Charge on reader** (everything open, the rental, the fees or a later charge) and **Hold deposit on reader**. Press **Send to the reader**: the amount shows on the reader and the renter taps, inserts or swipes the card. The screen updates by itself; **Cancel** stops the reader and nothing is charged. A deposit hold is captured or released from Settle the deposit like any hold.

### Credit card coverage: the same card
When the renter''s coverage is their credit card, the whole rental (rental and fees) is paid on that same card. The Money tab says which card. Another card on the pay page is refused and refunded at once; on the reader it is refused before the money is taken; a payment by e-Transfer, cash or the like is refused; a card typed by hand needs its last 4 digits and the box **This is the same card**. Deposits and later charges can go on any card. If the renter truly has to use another card or method, press **Allow another card** and give the reason (an Admin).

## Booked as soon as the renter accepts (release 28)

A booking is booked the moment the renter approves the offer. It takes the car on every calendar, the fleet board, the car''s availability and the counts, even before the payment or the pickup is recorded. Payment and the handover show as their own badges: **Booked, payment due** and **Pickup not recorded**. The first renter to approve gets the car: any other open offer on the same car and dates goes back to Requests with a Re-offer To do.

- **Booked, payment due** To do: a booked rental still unpaid within 48 hours of its pickup. Send the pay link, charge the saved card or record the payment.
- Record the pickup To do: a pickup time that passed with nothing recorded, as before.

When you send an offer, **The offer as the renter sees it** sits right under **Send the offer**: check it before you press it.

## Changes after signing: an amended agreement, no new signature

The rental terms (section 15.4) let CarmaCars update a booking after signing: an extension, new dates or times, a price adjustment, a fee, a car swap. The signed agreement keeps applying. Each change makes a new version of the agreement marked **Amended** with the date, carrying the renter''s original signature, and the renter is sent it. Nobody is asked to sign again, except an additional driver who never signed (they sign before driving).

## Check-in and check-out on one screen

On the booking page, **Check in (pickup)** and **Check out (return)** are one screen: the time (now unless you change it), the odometer, the fuel, the photos and a note. Pick many photos at once from the camera roll or take them; tag an angle on any photo if you like. The suggested angles (front, each corner and side, rear, odometer, fuel gauge, interior front and rear, trunk, wheels, any damage) tick themselves as photos are tagged. Nothing is required but the time; the renter''s own photos are added to the same report, each marked with who took it (the renter or staff) and its angle. The one-screen checklist is the button above it.

## Type into the Blind Spot agreement

On the **Rental agreements** card, **Type into the Blind Spot agreement** shows each box as the form prints it. Change a value and **Save the corrections**: it is drawn in that box, and the insured vehicle, the claim number, the adjuster and missing km or fuel go back onto the booking. **Preview the filled form** opens it with your corrections.

## Reopen an expired offer (release 28)

An expired offer reopens in one click: **Reopen offer** on the booking or on the **Expired** filter of Requests. The renter gets the usual offer email and text; the offer stays open 12 hours, and never past 1 hour before the pickup, unless you type other hours. Once the renter accepts, the car is held 2 hours for the payment; then the hold ends and, while the car is still free, the renter gets a fresh offer and a text to pay. When the pickup time has passed, the dialog asks for the new pickup and return first. A renter can also press **Ask to reopen this offer**: you get the To do "Renter wants expired offer reopened" and an alert, as for a new request.

An offer sent after its pickup time no longer expires by itself: it expires at its own expiry time (the pickup only counts when the offer was sent before it and the pickup is 2 hours past). The offer screens say **Pickup time has passed: update it** and do not send until you move the pickup.

## One booking page, six sections (release 31)

A booking has six sections: **Overview** (the next step; the review and offer while it is being arranged), **Money**, **Drivers & documents** (with the agreement), **Car & handovers** (the check-in and check-out, the photo report, signing on this device, what the owner sees), **Messages & history** (with the review request) and **Claims & extras** (changes, extensions, add-ons). Customer service, Sales, Fleet and Finance see the sections their work needs. An old link to a tab opens the section that holds it now.

Admin and staff open the same booking page, the same car page and the same listing review: you see every section and button, each staff function sees the parts it works with (Fleet has no Money section; only customer service and you have **Claims & extras**; refunds are asked for by you or Finance). A staff link to a booking opens the same page in the staff portal.

Every list has one search box (it finds names, numbers, plates, phones, emails and VINs) and one row of at most five chips. **Clear** removes every filter; the last one you used comes back next time on this device.

## Charge the renter after the return

Once the car is back, the Money tab has one action for everything owed after the trip: **Charge the renter**.

1. Press **Charge the renter**.
2. Choose the **Reason** from the list and add a note if it helps (Other needs its note). Enter the **Amount**.
3. Read the line under it: it says where the money comes from before anything moves. The deposit hold while it is still valid and covers the amount (the rest of the hold is released at the same time); otherwise the card on file; otherwise a pay link to the renter by text or email.
4. Press **Charge $...**. If the hold expired meanwhile, the card on file is charged instead, with the same amount and reason.

**Release** stays its own button. The renter''s receipt shows the reason.

## A deposit charged to a debit or prepaid card

When the deposit is charged instead of held on a debit or prepaid card (Charge the card on file as the deposit), the renter also pays the **Card processing fee for a debit deposit** (Program settings, 2.9% and $0.30 by default): a separate, non-refundable amount on the same charge. The Money tab''s history and the receipt show it; the deposit refund returns the deposit only.

## What the renter sees still to do

While a booking waits to be signed and paid, the Next step quotes the renter''s own Sign and pay card, for example: The renter sees: "Two steps left: sign the rental agreement, then pay $...". Signed for an older version of the offer counts as not signed: the renter signs the updated agreement on their Sign and pay page.

## Override a pickup or a return that must go ahead (release 33)
Sometimes the trip has to start (or end) even though a check still stops it. On the booking page, a confirmed booking (or one waiting for payment) and a car on rent show **What stops the pickup now** (or the return) with each check in plain words: the deposit not taken, the rental agreement not signed, no renter signature on the check-in report, a licence or identity not verified, the coverage not confirmed, an additional driver who has not accepted, the payment still due, the calendar switch off, the car not marked available, maintenance overdue, the Ontario licence, the fleet insurance policy (when that rule is on in Program settings), the agreement''s claim details, the tracker; at a return, an odometer lower than at pickup.

1. Press **Override and record the pickup** (or the return).
2. Give the actual time (now, or earlier), the km and fuel if you know them, and why the trip must go ahead. The reason is required.
3. Press the button. The pickup (or the return) is recorded at that time, only the checks listed are passed, for this booking and this once. The booking''s history and the audit log say who, when, why and which checks; every Admin gets the alert Override used. A payment still due is not waived: the booking is confirmed with the balance open, and the deposit is still to collect (it is not waived). The photos and readings come later, as with Record now.

When staff (Fleet, customer service, Sales, field staff) need it, they press **Ask an Admin to override the pickup** (or the return) on the same card with the time they recorded. You get the alert Override asked for and a line on the To do: press **Approve** (one tap) and it is recorded with the time they entered, or **Decline** with a note. The request also shows on the booking page, with Approve and Decline.

## Record a past trip (release 33)
A trip that happened but was never recorded (the pickup and the return both passed): on the booking page press **Record a past trip**. Give the actual pickup and return times, the km and fuel at each if you know them, and the reason. Every check that would stop it is overridden as above, in one step: the booking lands in **Returned**, the late return charges follow the actual return time, and the deposit can be settled. The car''s status today is left as it is, and the renter is not sent a "your rental started" email for a trip long over. Fleet gets the task to add the photos and readings. Staff ask for it the same way; you approve in one tap.

## Book it now: an offer that is a booking at once (release 33)
When you send an offer (answering a request, or **Send an offer** without one), tick **Book it now (no renter approval)** above Send. The offer becomes the approved version at once: the booking waits for payment, the car is held for its dates as for any approved offer, and the renter gets one link to the **Sign and pay** page to sign and pay (the "approve your offer" email is not sent). To have them sign and pay with you, open the booking: **Sign now on this device**, then take the card on this device. When customer service or Sales tick it, the offer goes out and you get the alert Override asked for and a To do line: **Approve** in one tap books it the same way. The booking''s history says who booked it and that the renter did not approve it.

Already sent the offer? Tell Claude or the assistant: "Book the offer of CC-10482 now, the renter agreed by phone". Claude''s connector has the tool **Book an offer now**, and **Send an offer** and **Make an offer** take Book it now too; the assistant (Assistant at the top of the menu) takes it in the same sentence as the offer. Each is two steps: you see what will change (nothing is changed yet), then you confirm, and the booking waits for the renter to sign and pay as above. As an Admin it is done at once; when customer service or Sales ask the assistant, it waits for your one-tap Approve.

## A request replaced by a newer one
When a request or offer expired and the renter made a newer one for the same car and dates, the old one is hidden from Requests and keeps its number and history. Both booking pages say so under the title: **Replaced by #CC-10483** on the old one and **Replaces #CC-10482** on the new one, each a link to the other. Customer service, Sales and the other staff pages show the same note.

## Change protection (release 41)

How damage to the car is covered is one control on the booking page: the **Protection** card at the top (Overview and the Money tab). An Admin, customer service and fleet use it on any booking; sales on a request or an offer.

1. Press **Change protection**. A small window lists the three options: **Own insurance (OPCF 27)**, **Credit card coverage** and **Protection Plan**, each with the price difference (the plan shows its price a day times the days, plus HST), the deposit (no coverage rule changes it) and what the renter provides.
2. The rule is the same as on the renter''s page: credit card coverage needs the renter''s card picked from the coverage list, a card that covers this car, and the renter''s confirmation that they pay with it; OPCF 27 needs the renter''s confirmation that they upload their policy; otherwise the Protection Plan. An Admin can tick Admin override: the reason is recorded on the change and in the booking history.
3. Write the reason (required; the renter reads it) and press **Change protection**.

What happens: the booking is repriced at once. More to pay is a balance to collect on the Money tab; less, when the plan was paid, is a refund for an Admin to approve. No money moves by itself. An offer is sent again as a new version; a confirmed booking or a rental in progress gets the amended agreement (the renter signs the new version when the rules ask) and one email. Proof tasks follow the new option. Changes are refused after damage is reported on the booking.

A renter''s request to leave the Protection Plan shows on the same card with their proof (**Open the proof**). Customer service or an Admin presses **Approve** (the change is made and the coverage confirmed) or **Decline** with a note the renter reads. The task "The renter asks to leave the Protection Plan" opens the booking.

## Change the car before pickup

On a request, an offer or a confirmed booking that is not picked up yet, press **Change the car** at the top of the booking.

1. Choose the new car. Only cars free for the whole booking are listed, each with its new total and the difference.
2. Say why the car changes, then press **Change the car**.
3. The price comes from the new car''s rate sheet (its rates, the km included and the rate per km). The coverage, the drivers and the add-ons stay as they are.
4. An offer is sent again with the new car: that offer is the renter''s one email.
5. On a confirmed booking, more to pay is left open: the renter sees **Pay the balance** on their booking, or you send a pay link or charge the saved card from Money. Less to pay becomes a refund that waits for approval, with a To do for Finance. The renter gets one email, **Booking updated**, with the new car and the money.
6. The open handover and return jobs move to the new car. The agreement gets a new version for the renter to sign; its link goes by text.
7. The booking''s history and the audit log keep who changed it, from which car, to which car and why.

Customer service and Admins change any of them; Sales changes a request or an offer; Fleet changes a confirmed booking. Once the car is out, use **Swap vehicle** instead.

## The accident card of a booking

Every booking from confirmation to the return shows its **Accident card**: the steps after an accident and the coverage this booking uses.

- OPCF 27: the renter''s own insurer and policy number, from the proof they uploaded.
- Credit card coverage: the card and its coverage provider, from their proof.
- Protection Plan: the provider, the policy number and the claims phone from Settings > Program (Tolls and damage), with the renter''s plan reference.

Press **Print the card** for the printable card. The renter has the same card on their booking. It never shows the fleet policy.

## Close ended trips

A back-dated close sends the renter no email or text. Fleet gets a To do when a trip is still open 2 hours after its return time, and the morning digest lists how many are open.

**Bookings** shows a banner when trips have ended and are not closed; **Close ended trips** lists each one: never picked up in the system, on rent after the return, or returned and never closed. Fleet and Finance have the same page.

1. Tick one or several, then **Mark them**: returned on time, returned late (give the time it came back), or a no-show (an Admin or customer service).
2. Choose the deposit: **Deduct the balance owed**, **Deduct the late fee**, or **Release in full**. A card hold that has expired is marked settled at once (released by expiry: no money moves).
3. If no deposit was taken, an Admin fills **Admin: deposit not taken, waive it because** (the same field is in Record a past trip).
4. Nothing is released by itself: the decision waits under **Deposit decisions waiting for an Admin**, and an Admin presses **Release** (or **Release now (tolls window)**).

## Return charges

A late return is charged per started extra day at the booking''s full daily cost (the rental per day after discounts, plus per-day and per-trip fees such as the Protection Plan, never delivery), and only the started hours after the whole days get the hourly late fee. On the booking''s **Money** tab, each renter line not on a statement yet has **Change amount** (lower) and **Waive**, with the reason; it is in the booking history and the next assessment keeps it. An expired card hold after the return has **Mark settled (released by expiry)**.

## Switching a booking to the Protection Plan (release 43)

**Change protection** > **Protection Plan** uses the car''s own plan price, the same amount the window quotes. It is no longer refused when Fees has no flat Protection Plan amount.

## The Protection Plan priced from RentalCover (release 35)

The Protection Plan stays our product: renters never see the RentalCover name. Without the RentalCover partner key it is priced from the Protection Plan table, as before. Once the key is set, its price comes from a real RentalCover quote for the renter (their dates, their age at pickup, their name and email) plus our markup (20% unless **Settings** > **Program** changes it). The request form asks for the quote once the renter''s details are in, and an offer as you choose option 3; a quote is reused for 15 minutes. A price you type for the plan wins. If RentalCover does not answer, the table price applies.

RentalCover covers up to $50,000 an incident, so the plan is offered only for a car worth less. The value used: your override under **Value for the Protection Plan** on the car''s page when set, else the car''s Canadian Black Book value, else an AI estimate from typical listing prices that the site makes by itself (**Refresh the AI estimate** asks again). A car with no value counts as over the limit: the request form, the offer screen and the database then offer only OPCF 27 or credit card coverage.

## Extensions at the all-in price a day (release 35)

An extension costs what the renter already pays, averaged per day: the booking''s total for the booked period (the rental after discounts, every fee, one-time fees like delivery included, and HST) divided by its days, for each added day. A booking of $729.36 for 7 days costs $104.19 for each added day. Added hours under a day cost the hourly late fee with HST, never more than a day. There is no extension discount.

| Where | What happens |
| --- | --- |
| The renter''s **Extend** page | Each option shows the total and the price a day before paying |
| **Edit** on a confirmed or on-trip booking, made longer | The booking''s new total is the all-in price of the longer stay; the per-trip fees stay as booked and the rental charge takes the difference |
| The next period of a long rental | Keeps the rate of the booked period (the rental a day, per-trip fees scaled) |
| An insurer-billed booking | Priced as before |

The extension is one line on the booking, "Extension: 3 days at $104.19/day (all-in)", HST included. Its HST is the booking''s own share of HST, so invoices and the books never add HST on top. Type a rental charge in **Edit** to set another price. Late returns are unchanged: the daily cost of each extra day and the hourly late fee.

## A fixed amount per payment (release 35)

On a weekly, every 2 weeks or monthly plan, an Admin can set **Fixed amount per payment** in **Change the plan**. Each payment is that amount and the last one takes the remainder. The total and the payments already made never change. Leave it empty to split the payments by the days again. A payment of $0 is never shown: when the fixed amount covers the total early, the last period joins the payment before it ($1,850 at $925 every 2 weeks is 2 payments).

## A payment plan''s first payment confirms the booking (release 48)

On a weekly, every 2 weeks or monthly plan, the booking is confirmed once the first payment is paid, by a pay link, the saved card or a payment you record. The rest is collected by the plan, as on a confirmed booking.

## Change the car of a booking partly paid (release 48)

A booking waiting for payment that already has a payment can be changed with **Edit** on its Overview, as a confirmed booking is: another car, the dates, the places. The car changes with the price as it is, new dates are priced at the booking''s own rates, and every payment stays recorded. The new car and dates must be free. Edit the offer is for a booking with nothing paid yet.

> Good to know: Claude''s connector does the same with `change_booking`, and lets a main driver keep a licence from outside Ontario on one booking with `licence_let_go` (your **Let it go**, with the reason). Both show a preview first.

## The request as sent and every offer (release 35)

On a request or a booking, **Original request, as the renter sent it** shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. **Offer history** lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.

1. To go back to an old version, press **Revert to this offer** on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.
2. Check the price, then send it in step 3. Nothing changes until you send.

The **Coverage** line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.

## Send an offer in three steps (release 35)

1. **Car and dates**: the renter, the dates, the car and where they pick it up and return it.
2. **Price**: filled in from the rate sheet with the checkout''s fees and discounts. Change it only if you agreed another price.
3. **Review and send**: what changed, the message and how the link goes.

Rarely used options (billing an insurer, how it is paid, the calendar) are under **More options**. Send waits while the price is being worked out again after a date change, and one tap sends once.

## The owner''s own trip, instant bookings and Book it now (release 35)

- **Owner''s own trip ($0)**: the owner booked their own car. There is nothing to price or send; get the car ready.
- **Instant (repeat renter)**: a Gold renter or above (Rewards, release 40) with a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter''s instant booking away with **Take instant booking away**, on the booking page or on the renter''s page.
- **Any car, any time** (release 40): a Platinum renter asked for dates the car shows as taken. Fleet gets an urgent task due within 4 hours: confirm it, offer an equivalent car or an upgrade, or decline with a reason. Never cancel or move another renter''s confirmed booking for it. The task closes when the request is answered.
- **Book it now** pressed by staff waits for an Admin''s one-tap approval.

## Secondary contact and rideshare documents (release 35)

The booking shows the renter''s **Secondary contact** when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes **rideshare documents** (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.

## Offers, coverage, delivery and fuel (releases 35 and 36)

- Sending an offer is three steps: car and dates, price, review and send. Every request shows the renter''s original request as sent and every offer version, with who sent it and when; reverting loads an old version as a new offer to send.
- Instant booking: a verified Gold renter or above books an available car at once, signs and pays; the booking is marked Instant (repeat renter), and an Admin can take instant booking away from a renter.
- Card coverage is checked against the car: the card, the car''s value, its type and the rental length. A card that does not cover it cannot be approved. OPCF 27 needs both the pink slip and the endorsement page.
- Delivery is priced by distance from the company''s address (1570 Midland Ave, Scarborough): a base, the kilometres included and a rate per km, all in Program settings; a car''s own fee stays as an override.
- The fuel line at the return is suggested from the car''s tank, the weekly pump price and a multiplier, plus the refuelling fee, and checked on the deposit review before any charge.
- Owner price limits: the daily minimum and maximum of a car or an owner hold every price, discount and offer; only an Admin can allow one request outside them, with a reason.
- Rideshare and delivery work is allowed with the documents the renter makes on their booking page (rental agreement copy, coverage letter, vehicle letter); staff get an alert when they are made. The secondary contact shows on the booking.
- Mid-trip review ask: halfway through a trip of several days, the renter gets one short message asking how it is going; a problem they report becomes a To do for customer service.
- A car that has only test bookings can be deleted by an Admin; the test bookings go with it. A car with a real booking cannot be deleted.

## Check-in and check-out on one screen (release 42)

**Start the check-in (pickup)** and **Start the check-out (return)** on the booking, and **Check in** or **Check out** on the To do list, open the same screen field staff use, made for a phone held in one hand:

1. Every part is on one page in the order you do it, with a green tick once it is complete: the ready check, the renter, licence and card (one tap each), the odometer, fuel and keys, the photos, damage, the tracker, then the signatures.
2. What is known is filled in: the odometer and fuel from the Tracker when it reported in the last 30 minutes (else from the car''s last report), the keys, and Standard for the cleanliness of a return. Check each against the car and change what differs.
3. Photos are one tap each: **Take this photo** always shows the next angle.
4. What is optional is folded away: new damage, a note, belongings, a renter who is not there or will not sign.
5. The button at the bottom says what is still needed (for example "Next: Odometer") and takes you to it. When everything is in, press **Hand over the keys** or **Complete the return**.

Nothing was dropped: the condition report still needs every photo, the readings and the signatures, and the database refuses a handover with anything missing. Leave the page and come back: your answers and photos are still there.

**Check in with photos already taken (from the gallery)** is still under the button, for a car that was photographed earlier.

## A late return is a choice (release 42)

A car that comes back after the grace period is never charged by itself. The booking shows **Late return** with how late the car was and five choices, each with what it costs:

1. **Charge as an extension**: every started day late at the booking''s daily rate, as an extension would have cost.
2. **Charge extra days**: you choose the days, from 1 up to the started days, at the daily rate.
3. **Charge the late return fee**: the fee of the rental terms (whole days at the daily rate, the started hours after them at the hourly fee, capped a day).
4. **Charge a custom amount**: type the amount before tax and what it is for. The renter sees the reason.
5. **Waive it**: no charge, with the reason.

Press **Save the late return charge**. The charge goes on the return statement and is taken as every return charge is: from the deposit, then the card on file, then a pay link. The renter gets a message on the booking that says what was chosen, and the booking history keeps who chose and why.

Until someone chooses, nothing is charged for the late return and Fleet has the To do "Late return: choose the charge". Field staff can choose on the return screen as they complete the return.

> Good to know: A custom amount above your single limit, and a waiver by anyone other than an Admin, Finance or Fleet, waits for an Admin: they get the To do "Late return: approve the charge" and press **Approve as asked**, or choose another way. Only an Admin changes a late return that is already decided, and not once it is on a statement or paid.

On **Close ended trips**, marking a trip returned late and choosing **Deduct the late fee** is the same choice of the late return fee, made there. The other deposit choices leave the late return to be chosen on the booking.

## Picked up, deposit pending (release 48)
Staff who record handovers, and you, can let a car go with the deposit still owed, with the reason (Record the pickup now, the one-screen check-in, the field job, or **Deposit not taken: let the car go owing it** before the full check-in). The booking goes on rent and shows **Deposit pending $X** beside its status for every role, with who let it go and why. Each morning from the deposit hold hour the saved card is tried for the hold once; if it fails or there is no card, the deposit link goes to the renter. After 48 hours still unpaid you get the To do **Deposit still owed** and an urgent alert, both opening the booking''s Money tab. Taken, waived or the car back: it ends by itself. Program settings, **A car out with the deposit owed: try the saved card each morning, then send the deposit link**, turns the morning tries off. From Claude''s connector: record_handover with `deposit_pending: true` and `deposit_pending_reason`, previewed then confirmed.

## Long-term rentals paid weekly

For a renter who keeps the car week after week and pays each week:

1. Open the booking (confirmed, or the car already out). On the Overview or Money tab, the **Long-term, paid weekly** card: press **Turn on**. If the car has another booking or a block after the return, the card names it: move that first.
2. From now on the car stays out on the calendar and on the site until the renter gives notice. You never extend the return by hand.
3. Each week, when the renter pays cash or e-Transfer, use **Record a payment** for the rental as usual: the amount is the next week''s price, and the return moves 7 days.
4. 48 hours before the return (Program settings, **Long-term weekly rentals: hours before the return**), if the next week is not paid, the renter gets a pay link by text (else email) and you get a To do. Paying the link moves the return too, and the To do closes by itself.
5. When the renter gives notice, press **End rental on** and pick the last day. The last week stops on that day and the car shows free after it. Leave the date empty to go back to until notice.
6. **Turn off** makes it a normal booking again: the car shows free after the current return.

Claude''s connector does the same: `change_booking` with `changes.rolling_weekly` true or false, and `changes.rolling_end_on` for the last day; `record_payment` records the week.

## Payments by e-Transfer or cash, deposits and tips

1. **Record a payment**: a payment of the whole total pays every line of the booking (the rental, short notice, the young driver fee, the Protection Plan), whichever part you record it for. When nothing is open, a booking waiting for payment is confirmed by itself.
2. **The deposit by e-Transfer or cash is doubled**: twice the car''s deposit by default (Program settings). The Security deposit card shows both amounts ("Credit card hold $300.00; e-Transfer or cash $600.00 (2x)"), and the renter sees them on the offer and the pay page before paying.
3. **Collect the deposit** > Cash or e-Transfer: leave the amount empty to take what is owed. Less is recorded as a part (the card says **under, still owed $X** and **Collect the $X still owed** takes the rest); more is held and given back with the deposit (**over, to return $X**).
4. **Change the deposit** on Edit booking (an Admin, with the reason), even while the booking waits for payment: the Money tab, the deposit link and Collect $X deposit follow at once.
5. **Voided a deposit by mistake?** After the void the deposit is **Not collected** again everywhere (the header too): record it again.
6. **Tips**: the renter can add one when paying, on the receipt and from the after-trip email. A tip in cash or by e-Transfer: **Tips** > **Record a tip**. Half goes to the booking''s salesperson and half to the staff member at the handover; with no staff salesperson (a direct booking) CarmaCars keeps that half; one person who did both gets it all. An Admin can give one tip another split (**All to ...**, **Back to the usual split**). A tip is never part of the rental or the owner''s share.
7. A greyed-out button says under it what to do first.
8. **Documents** > **Approve** names what it approves ("Approve the proof of coverage", "Approve all 3: licence front, licence back and selfie"). A booking with one driver reads **No additional drivers** in the checklist, and **Licence and selfie verified** ticks as soon as Documents shows every image approved.
9. Every tip, who got what and CarmaCars'' share: **Money** > **Tips**.
',
  '<p class="gd-p">A booking starts as a request from the website, or as an offer you send yourself to a customer on the phone. You check it, adjust it and send the offer; an offer that is out is changed in place. After that, the booking page holds the money, documents, changes and history.</p><section class="gd-task" id="requests-offers-and-bookings-bookings-now-what-is-out-coming-back-and-owed" data-gd-task><h2 class="gd-h2">Bookings now: what is out, coming back and owed</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b>. It opens on <b class="gd-ui">Now</b>, one screen that refreshes by itself every 30 seconds. Every time is Toronto time.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The numbers at the top: cars out now, due back today, overdue, going out in the next 72 hours, payments due in the next 7 days (with the total) and free cars. Tap one to jump to its list.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Out now</b>: every car on rent, overdue returns first in red. Each shows the car (photo, code, plate), the renter with <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b>, when it was picked up, when it is due back with a countdown, the payment plan and the next payment, the deposit held, and the km and fuel at pickup. Filter by Overdue, Due today or Payment due.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A confirmed booking whose pickup time has passed with no check-in recorded is listed as out, with <b class="gd-ui">Out (pickup not recorded)</b>. The car most likely left. Press <b class="gd-ui">Mark picked up</b>: it records the pickup at the booked time (change it if the car left at another time), the booking goes on rent, and Fleet gets a task to add the photos, km and fuel. The usual checks stay: the deposit taken (or an Admin waives it with the reason), the renter&#39;s signature (or an Admin&#39;s reason), the agreement&#39;s details, every driver verified and the coverage confirmed. If one is missing, the reason is shown.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Coming back</b>: overdue, today and tomorrow, by the time each is due.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Going out</b>: confirmed pickups in the next 72 hours, delivery or pickup, with ticks and crosses for the licence, the signed agreement, the payment, the deposit (a clock until the morning of the pickup day, when the hold is placed on the card on file) and the check-in photos (done at the handover).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Money due</b>: every rental payment due in the next 7 days or overdue, the amount, the plan and which payment it is (for example 3 of 4).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Free now</b>: cars available and not out, the longest idle first, with the next pickup; then the cars in maintenance or cleaning. Partners&#39; cars are counted apart.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Placeholder bookings never show on Now.</div></aside><h3 class="gd-h3">Payment plans</h3><p class="gd-p">A rental is paid in full at pickup, weekly, every 2 weeks, or monthly. A rental longer than one period (30 days) pays each period by itself. To change it, open the booking, then the <b class="gd-ui">Payment plan</b> card on Overview or Money, and press <b class="gd-ui">Change the plan</b>. Each payment is its share of the total by its days, due on the day it starts. An insurer-billed rental shows <b class="gd-ui">Insurer billed</b> and is never in Money due unless the renter owes a part. Admins, customer service and finance change the plan; fleet sees it.</p></section><section class="gd-task" id="requests-offers-and-bookings-all-bookings" data-gd-task><h2 class="gd-h2">All bookings</h2><p class="gd-p">The <b class="gd-ui">All bookings</b> tab of Bookings has the search (booking number, name, email, phone, plate or car code), the status (All, Out now, Booked, Returned, Cancelled; closed bookings are found with the search, which also finds the insurer). <b class="gd-ui">Out now</b> shows the bookings on rent and those whose pickup passed without a check-in, together. Each booking is one row: its number and status in plain words, the car with its photo, the renter with <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b>, the dates, the money (paid up, to pay, overdue, insurer billed) and Bill to.</p></section><section class="gd-task" id="requests-offers-and-bookings-the-request-queue" data-gd-task><h2 class="gd-h2">The request queue</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Requests and offers</b>. The oldest waiting request is at the top.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The numbers at the top: waiting for an offer, past the reply target (red), offers out, accepted but not paid, and offers expired. Each one is a filter: press it and the list shows just those, with the matching chip below marked as chosen.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">One queue, the most urgent first: the longest wait, then offers accepted but not paid, then offers out by when they expire. Each row has the car with its photo, the dates, the price, the renter with <b class="gd-ui">Call</b> and <b class="gd-ui">Text</b>, the licence (verified, to review, or not uploaded yet), who is answering it, and one button: <b class="gd-ui">Send offer</b>, <b class="gd-ui">Follow up</b> or <b class="gd-ui">Open</b>. <b class="gd-ui">Decline</b> sits beside <b class="gd-ui">Send offer</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Waiting shows how long the renter has waited (&quot;12 min&quot;, &quot;3 h&quot;, &quot;2 days&quot;); red means past the first reply target (5 minutes, set in Program settings). <b class="gd-ui">Promise</b> counts down the 2 hours the site promises the renter.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Filter by Active, New, Changes asked, Offer out, Accepted, not paid or Expired. The list remembers your last choice on that device; <b class="gd-ui">Active</b> always shows the whole queue and replaces what it remembered. When the same renter asks for the same car for overlapping dates again and the earlier request or offer expired, only the newest is listed: the older ones are linked to it and leave Requests (they keep their history). An expired offer leaves the active queue 48 hours after it expired, or once its pickup time passed; Expired lists the ones from the last 7 days. After 7 days an expired offer leaves Requests and offers and becomes a renter lead, once, in People &gt; Renters &gt; Leads (Expired offers), with the car and the dates the renter wanted and a To do for Sales to win them back. An offer still out when its pickup time passes expires by itself.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/820"><img src="/guides/img/admin-02-requests-desktop-6521282d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="820"><span class="gd-pin" style="left:38.9%;top:29.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:22.2%;top:43.3%" aria-hidden="true">2</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request whose pickup time passes without an offer expires by itself, with a note in its history. The renter is not emailed unless &quot;Email the renter when their request expires that way&quot; is on in Program settings.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-answer-a-request-with-an-offer" data-gd-task><h2 class="gd-h2">Answer a request with an offer</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The Review and offer tab shows the request as the renter sent it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Adjust the car, the dates, the rate type, the places, the rates (under <b class="gd-ui">Show rate card</b>) and fees, the deposit and extras. A place changed away from a delivery or a collection takes its fee box and its fee with it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Price on the right updates as you change things.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a message, then press <b class="gd-ui">Send the offer</b>, the one main button at the bottom (Send the offer under Next step takes you there). How long it stays open, Email or Text and Book it now are under More options.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1200/1550"><img src="/guides/img/admin-03-booking-review-desktop-353f3707.jpg" alt="" loading="lazy" decoding="async" width="1200" height="1550"><span class="gd-pin" style="left:5%;top:6.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:7.5%;top:45.8%" aria-hidden="true">2</span><span class="gd-pin" style="left:74.2%;top:42.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:76.7%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Changed fields but not ready to send? Press <b class="gd-ui">Save without sending</b>. The panel &quot;The offer as the renter sees it&quot; shows the result.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? Press <b class="gd-ui">Decline</b> and fill in Reason and any alternative.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Need an answer first? Press <b class="gd-ui">Ask the renter</b> to send a question.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10069?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:500/80"><img src="/guides/img/admin-03-booking-review-desktop-4dd4ed06.jpg" alt="" loading="lazy" decoding="async" width="500" height="80"><span class="gd-pin" style="left:41.2%;top:52.5%" aria-hidden="true">6</span><span class="gd-pin" style="left:18%;top:52.5%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Opening a request takes it for you: everyone else sees &quot;Being answered by&quot; your name and since when, with Send the offer and Decline off, until you send, decline or leave (20 minutes, renewed while you work; Program settings). Press <b class="gd-ui">Take over</b> to answer one someone else holds; it is noted in the history. A second answer is refused with who answered and when. A request from the website opens to Sales after 15 minutes (Program settings); until then Admins, customer service and fleet answer it.</p></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-without-a-request" data-gd-task><h2 class="gd-h2">Send an offer without a request</h2><p class="gd-p">Press <b class="gd-ui">Send an offer</b> at the top of Bookings, or <b class="gd-ui">Send an offer without a request</b> on Requests and offers. For a customer on the phone, by text or at the counter: no request needed.</p><p class="gd-p">The screen is seven short steps, each with one line saying what to do, and the price beside it (on a phone the total sits at the bottom of the screen: press <b class="gd-ui">See every line</b>). What most offers never need is under each step&#39;s <b class="gd-ui">More options</b>, which stays open while something in it is used.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Who is renting and when</b>: find the renter by name, phone or email, or press <b class="gd-ui">Not on file? Add a new customer</b> (full legal name, mobile, email for the offer link, date of birth). A customer already on file with the same email or phone is shown with Use: one person, one record. A renter picked from the file shows what is on their record under their name: the licence (class, number, expiry), the home address and the drivers named before, with a licence that has expired or an address over a year old flagged to ask them about. Then the pickup and the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Which car</b>: search by car code, plate or name; each car says Free or Not free for the dates. More options: the rate card and the type and free-only filters.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Where they pick up and return</b>: at our location, we deliver or collect (the address and distance), an airport or the owner&#39;s location. The fee each one makes shows under it, Automatic or Set by hand.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">How damage is covered</b>: the renter&#39;s own insurance, a credit card or the Protection Plan. More options: another Protection Plan price.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Extras</b>: add-ons, when the car has any.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">The price</b>: the rate sheet price is filled in. More options: another price (a total for the trip or a rate a day, with why), Amounts I type (before or after HST), the total the renter pays, kilometres, a promo code, the deposit and a discount (an Admin), and <b class="gd-ui">Fees</b>: press <b class="gd-ui">Change</b> to set one by hand, <b class="gd-ui">Reset to automatic</b> to undo it. Below: how it is paid (card online and a card hold unless you change it under More options).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Send it</b>: who found this client (sales and customer service), a message, and Text or Email. More options: how long the offer is open, the owner&#39;s view, who found the client (an Admin) and the internal note. Above the button, <b class="gd-ui">Ready to send</b> or <b class="gd-ui">Missing:</b> with what is left; press Send and each missing field says what it needs. Press <b class="gd-ui">Send the offer to</b> the renter, or <b class="gd-ui">Save without sending</b> to keep it as a request for later. <b class="gd-ui">The offer as the renter sees it</b> is under the price.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Choices drive the charges. Take off a delivery, a collection, the Protection Plan or an add-on and its fee goes with it, even a fee set by hand: there is nothing to remove in a second place. Choose it again and the fee starts from the automatic amount.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It makes the same request and offer the website makes: the renter approves, signs and pays (or you record the payment), and only then is the car on the calendar. No &quot;request received&quot; email goes to the renter for an offer you send. Staff commissions and statements count it like any other booking.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-change-an-offer-that-is-out" data-gd-task><h2 class="gd-h2">Change an offer that is out</h2><p class="gd-p">The renter has the offer (Offered), or approved it and has not paid (Signing and payment). Open <b class="gd-ui">More actions</b> on the booking and press <b class="gd-ui">Edit the offer</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change anything: the car, the dates, the places, the price, fees, the deposit, add-ons, how it is paid. Each changed field is highlighted and the before and after are listed. Amounts I type (Before tax or After tax) and the Total the renter pays (after tax) work as on Send an offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Write what changed in Message to the renter. How long the offer is open and Email or Text are under More options.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Send the update</b>: the renter gets the new version by email or text (ticked), and the old version no longer counts. Or press <b class="gd-ui">Save without sending</b> and tell them yourself. After you save, the screen shows the offer as saved.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A confirmed booking is changed with <b class="gd-ui">Change the booking</b> (Propose a change, below).</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>No need to withdraw first. <b class="gd-ui">Withdraw the offer</b> is only for taking it back for good; <b class="gd-ui">Send again, later expiry</b> gives the renter more time, and <b class="gd-ui">Renter approved by phone</b> records a yes given on a call.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-edit-a-booking-that-has-started" data-gd-task><h2 class="gd-h2">Edit a booking that has started</h2><p class="gd-p">On a confirmed, on-trip or returned booking (an Admin: a closed one too), Overview, <b class="gd-ui">Edit the booking</b>, <b class="gd-ui">Edit</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Change the pickup or the return (extend or shorten: the rental charge is worked out again at this booking&#39;s rates), the car (on trip: the car it leaves goes to Out of service for Fleet to check), the rental charge for the trip, each fee, the kilometres a day, the deposit (an Admin) and the note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type why, if you like, and tick <b class="gd-ui">Email the renter what changed</b>, or leave it off for a silent correction. Press <b class="gd-ui">Save the changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What is open now shows at once: <b class="gd-ui">Email a pay link</b> or <b class="gd-ui">Text a pay link</b> for exactly that amount, <b class="gd-ui">Charge</b> the saved card (the renter agreed), or record cash or an e-Transfer on the Money tab.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each edit is kept with who, when, why, before and after (Edits, under the form) and in the booking&#39;s history. A closed booking&#39;s owner split and the staff commission follow. To have the renter accept and sign first, use Propose a change instead.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-restore-a-version-of-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Restore a version of a confirmed booking</h2><p class="gd-p">Once a confirmed booking has been changed, Overview shows <b class="gd-ui">Versions of this booking</b>: the booking before its first change, then one version after each change (a fee changed on its own too), the newest marked current.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Find the version to go back to (its dates, days, car, rental charge and total are listed) and press <b class="gd-ui">Restore this version</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The preview shows what changes: the dates, the car, the rental charge, the total, and what the renter would owe or be owed. Nothing is changed yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type why, tick <b class="gd-ui">Tell the renter what changed</b> if they should know, and press <b class="gd-ui">Restore version</b> with its number. The dates, the car, the rental charge and every fee go back exactly as they were in that version.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">It is one more change in the history, with your name and the reason. Payments are never touched: a difference is a balance to collect or a credit to settle, as with any edit.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The same checks as Edit: the car must be free for those dates, and customer service and Sales restore only while Program settings let staff change bookings (and fees). A version kept before Release 45 has no fees with it: its dates, car and rental charge go back and the fees stay as they are; the preview says so.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-fees-a-forgotten-fee-and-the-balance" data-gd-task><h2 class="gd-h2">Fees, a forgotten fee and the balance</h2><p class="gd-p">On the booking&#39;s Money tab, Fees lists each fee. Press <b class="gd-ui">Change or add a fee</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a new amount (for the whole trip, before HST) beside any fee, or choose one not on the booking (the young driver fee shows its price for these dates), or add a charge of its own with or without HST.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Save the fees</b>. The balance shows by part (rental, fees) with the pay link, the saved card and Record a payment beside it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The renter sees the balance on their booking with a Pay button, and pays by card on Stripe&#39;s form.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every change is recorded (Changes to the fees): the amount before and after, who and why. Customer service and sales may change fees while Program settings, Staff may change fees, is on.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Changing the amount of a line on the Money tab changes the booking&#39;s total and balance with it, so no balance appears that nobody owes. An Admin can set the total directly with <b class="gd-ui">Change the total</b>: the difference goes on the rental charge.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-renter-with-only-a-debit-or-prepaid-card" data-gd-task><h2 class="gd-h2">A renter with only a debit or prepaid card</h2><p class="gd-p">A credit card is required by default: the deposit must be on a credit card so the deductible can be charged. The pay page tells a renter with only a debit or prepaid card to contact us.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On the booking&#39;s Money tab, press <b class="gd-ui">Allow debit and prepaid cards for this booking</b> and type the reason. Who and when are kept, and the change is in the booking&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The booking&#39;s pay page, staff pay links and deposit hold then take a debit or prepaid card, and the renter is told the hold lowers the money available on the card until it is released, which can take several business days.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Require a credit card again</b> turns it off.</div></li></ol></div><p class="gd-p">The Money tab shows each card used and its type (credit, debit, prepaid). A booking on credit card rental coverage is always paid on the credit card that carries the coverage, and cannot be allowed. Program settings, <b class="gd-ui">Card types accepted</b>, can open debit and prepaid cards to every booking.</p></section><section class="gd-task" id="requests-offers-and-bookings-correct-a-renter-s-details" data-gd-task><h2 class="gd-h2">Correct a renter&#39;s details</h2><p class="gd-p">On the renter&#39;s page (People, Renters) or on any of their bookings, <b class="gd-ui">Edit renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Correct the name, email, phone, date of birth, licence, home address (start typing to find it) or the staff note.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A new email also becomes their sign-in at once (no confirmation needed for a typo you correct); tick <b class="gd-ui">Email the renter a link to set a password</b> to send one there. Unsigned agreements and offers go to the new address.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Save the renter</b>. An email that another renter has is refused with their name; the same phone is a warning.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same person entered twice? Possible duplicates (same email, same phone, or same name and date of birth) shows under the renter. <b class="gd-ui">Merge into this record</b> moves the other record&#39;s bookings, licences, cards, payments, documents and messages here and fills any detail missing here; the other record stays, blocked, with the merge in both histories.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-money-tab-rental-charges-and-security-deposit" data-gd-task><h2 class="gd-h2">The Money tab: Rental charges and Security deposit</h2><p class="gd-p">The booking&#39;s Money tab opens on a strip with the three numbers that matter: <b class="gd-ui">Rental due</b>, <b class="gd-ui">Deposit</b> (one word: Not collected, Held, Charged, Released or Partly kept) and <b class="gd-ui">Total paid</b>. Below are two panels, side by side on a computer and one above the other on a phone. Collecting one never touches the other, and every receipt says which one it is.</p><p class="gd-p"><b class="gd-ui">Rental charges</b>: each line of the price and the total, Paid, then Balance due.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The one main button, Collect (the amount) rental: choose how. <b class="gd-ui">The card on file</b> charges it now (Finance or an Admin); <b class="gd-ui">A payment link by text</b> or <b class="gd-ui">A payment link by email</b> sends the renter Stripe&#39;s secure form; <b class="gd-ui">On this device: hand it to the renter</b> opens it for the renter to type; <b class="gd-ui">Cash, e-Transfer or another way (record it)</b> records money received (an e-Transfer, cheque or transfer needs its reference). For: the rental and fees together by default, or one of them. With the card on file, the rental and fees together are one charge with one receipt that lists both (the rental is paid first, then the fees; an insurer&#39;s part and money already received another way are left out). The renter gets a receipt; <b class="gd-ui">Print</b> prints one to hand over.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">A later charge</b> (before the return): on the card on file, by a link, on this device, or recorded. Choose the <b class="gd-ui">Reason</b> from the list (Mileage overage, Fuel, Cleaning, Smoking, Late return, Tolls, Tickets/fines, Damage, Missing items, Other) and add a note; Other needs its note. The renter&#39;s receipt shows the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Save a card</b> saves the renter&#39;s card without charging it. Card readers, the fees (<b class="gd-ui">Change or add a fee</b>), failed card payments (<b class="gd-ui">Paid another way</b>), payments received another way and <b class="gd-ui">Refund</b> sit in this panel too. The history lists rental payments only.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An offer paid another way: once the renter approved and signed and the money is recorded, the booking is confirmed (or press <b class="gd-ui">Confirm the booking</b>).</div></li></ol></div><p class="gd-p"><b class="gd-ui">Security deposit</b>: the amount, how it is taken (a credit card hold, a debit or prepaid card at the standard multiple, a charge, or cash), its status in one word and the next step.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Not collected: the one main button, Collect (the amount) deposit. <b class="gd-ui">Hold on the card on file</b> places the hold now (Finance or an Admin); <b class="gd-ui">A deposit hold link by text</b> or <b class="gd-ui">A deposit hold link by email</b>, or <b class="gd-ui">A hold on this device: hand it to the renter</b>; <b class="gd-ui">Charge the card on file as the deposit</b> only when no hold can be placed; <b class="gd-ui">Cash or e-Transfer (record it)</b>. The rental balance is not touched.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Before every pickup the deposit hold link is texted to the renter on its own: 24 hours before (at once when the pickup is sooner), for a confirmed booking whose deposit is a card hold with no hold yet. The panel says <b class="gd-ui">Deposit link texted</b> and when it was opened. No mobile number, or the text not sent: a task <b class="gd-ui">Deposit link not sent</b>. <b class="gd-ui">Settings</b>, then Site settings, Deposit link by text: on or off, and the hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Held, while the car is out: <b class="gd-ui">Release</b> (an Admin, with the reason), <b class="gd-ui">Keep part (damage/fees)</b> with the amount and the reason from the list, or <b class="gd-ui">Re-authorize the hold</b> on the saved card before it lapses (the panel shows when the hold expires). A job re-authorizes it by itself about 24 hours before it expires; if it cannot, Finance and the Admins get the alert <b class="gd-ui">Deposit hold not re-authorized</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Hold expired</b>: a card hold lasts about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. Once it has expired, nothing can be kept from it: the panel says Hold expired, Keep and Release are hidden, and <b class="gd-ui">Charge the card on file instead</b> opens the later charge with the amount and the reason filled in.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">After the return: <b class="gd-ui">Settle the deposit</b> (below).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Waive the deposit</b> (an Admin, before it is taken), <b class="gd-ui">Change the debit deposit</b>, and <b class="gd-ui">Allow debit and prepaid cards for this booking</b> sit in this panel. The history lists deposit payments only.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way after the return: Finance gets a task; press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Statements, reconciliation and the deposit settlement read each payment with its method: a cash deposit is never refunded to a card.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-settle-the-deposit" data-gd-task><h2 class="gd-h2">Settle the deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-out statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: <b class="gd-ui">Keep the whole deposit (damage)</b> turns what is left of the deposit into a damage charge, with what was damaged and the photos; the renter is told. <b class="gd-ui">Bill damage</b> adds a damage charge up to the $2,500 deductible (more goes through a claim): the deposit pays first, then the card on file.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-a-booking" data-gd-task><h2 class="gd-h2">A booking</h2><p class="gd-p">Open <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Bookings</b>, then a booking number. Or type the number in the search box.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tabs: Overview, Money, Changes, History, and Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Overview shows the trip, the renter, what is still missing for the handover, and the price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open tasks for this booking, with the queue and the due time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Top right: <b class="gd-ui">Email the renter</b> and <b class="gd-ui">More actions</b>, the menu with <b class="gd-ui">Edit the offer</b>, <b class="gd-ui">Stop blocking the calendar</b>, <b class="gd-ui">Cancel for the renter</b>, <b class="gd-ui">Cancel by CarmaCars</b> and the rest.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Under the booking number: <b class="gd-ui">Next step</b>, what happens next and who does it, with one button for that step (for example <b class="gd-ui">Send the offer</b>, <b class="gd-ui">Sign on this device</b> or <b class="gd-ui">Check in the car</b>); then where the booking is on its way, from Request to Closed, with the dates, the days, the total and who pays.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10065</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/960"><img src="/guides/img/admin-04-booking-desktop-b56b668a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="960"><span class="gd-pin" style="left:50%;top:46.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:85.4%;top:14.5%" aria-hidden="true">4</span><span class="gd-pin" style="left:22.9%;top:26.8%" aria-hidden="true">5</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-check-a-car-out-or-in" data-gd-task><h2 class="gd-h2">Check a car out or in</h2><p class="gd-p">From the booking, with your phone or a tablet: the same checklist field staff use.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A confirmed booking shows <b class="gd-ui">Check in (pickup)</b> under Check-in, check-out and signing; a booking on rent shows <b class="gd-ui">Check out (return)</b>. Today lists the check-ins and check-outs due, each with <b class="gd-ui">Check in</b> or <b class="gd-ui">Check out</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The checklist opens: the ready check, the renter and their licence and card, the odometer (km) and fuel or charge, the keys, the photo set (every side, the wheels, the interior, the odometer and fuel gauge, the plate), damage marks with close-ups, then the renter and you sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos wait on the device without a connection and upload in the background. Each keeps its time, and the place when the device allows location.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field job of the booking is taken over (the history says so); with no job, one is made for you. When done, press <b class="gd-ui">See the photo report</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Fleet, Sales and Customer service check cars out and in the same way from their own booking page.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-photo-report-late-returns-and-the-return-charges" data-gd-task><h2 class="gd-h2">The photo report, late returns and the return charges</h2><p class="gd-p">Under Check-in, check-out and signing, press <b class="gd-ui">Photo report</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The report shows the due-back time, the actual check-in and check-out, Late by (or Overdue by while the car is out), the odometer and kilometres over the allowance, the fuel or charge out and in, every photo with its time and place, and the damage.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">At check-out the mileage overage and the fuel or recharging are written to the return charges at once. A late return (after the grace period of the fee defaults) is not: it waits for a choice on the booking (see &quot;A late return is a choice&quot;). The fuel is a suggested line: the car&#39;s tank x the fuel missing x the pump price of its grade (Program settings, updated weekly) x 1.25, plus the refuelling fee; an electric car the battery kWh x the charge missing x the price a kWh, plus the fee. A pump receipt entered later replaces it. Fleet and Finance confirm it on the deposit review; it is never charged to a card by itself.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not charging one? Press <b class="gd-ui">Waive</b> beside it and give the reason: it stays waived if the charges are worked out again.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The time was wrong? Press <b class="gd-ui">Correct the check-out time</b> (or the check-in time) with the reason: lateness follows, a return that is no longer late loses its late charge, and the history keeps both times.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The renter gets the same report (without these buttons) by email and in their Documents. Late by shows on the booking and in the Bookings list.</div></li></ol></div><h3 class="gd-h3">The renter says the car is back</h3><p class="gd-p">Every overdue email, text and alert (at the return time, at 15 minutes and the final notice) has a one-tap <b class="gd-ui">I&#39;ve returned the car</b> link, and the renter&#39;s booking page has the button. The renter can add photos, the odometer, the fuel level and the time they returned it. Sending it stops every overdue notice of the booking at once, the booking shows <b class="gd-ui">Returned, waiting for confirmation</b>, and Fleet gets an urgent To do: &quot;The renter says the car is back&quot;.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. The card <b class="gd-ui">The renter says the car is back</b> shows what the renter gave, marked renter-provided, with their photos.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the car: the return place, the tracker, the photos.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Confirm</b> to complete the trip. Correct the odometer, fuel or return time first if they are wrong: the late charges follow the time you confirm. The renter&#39;s photos join the check-out report.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Or press <b class="gd-ui">Deny</b> and say why. The renter gets your reason by email and text, and the overdue notices start again.</div></li></ol></div><p class="gd-p">Checking the car in the usual way also completes the trip and stops the notices. Admins, Fleet, Sales, Customer service and field staff can Confirm or Deny.</p></section><section class="gd-task" id="requests-offers-and-bookings-signatures-on-the-spot-or-by-link" data-gd-task><h2 class="gd-h2">Signatures on the spot, or by link</h2><p class="gd-p">The renter or an additional driver signs the rental agreement on your device, or on their own phone.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">While a signature is missing, the booking shows <b class="gd-ui">Sign now on this device</b>, <b class="gd-ui">Email the signing link</b> and <b class="gd-ui">Text the signing link</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">No agreement made yet (the renter has not saved their details at home)? <b class="gd-ui">Sign now on this device</b> still shows: press <b class="gd-ui">Prepare the agreement to sign now</b> and it is made on the spot.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Sign now on this device</b>: confirm the name matches their licence and that you saw the original licence (photograph it if none is on file), then press <b class="gd-ui">Hand the device to</b> and their name.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">They read both agreements (CarmaCars&#39; and Blind Spot&#39;s), tick the statements and sign. Then <b class="gd-ui">Back to the staff view</b> for the next signer.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The record is the same as signing online, and says it was signed in person, collected by you, on your device. It is printed on the signed copy&#39;s signature record page.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-rental-agreements-every-version-every-field" data-gd-task><h2 class="gd-h2">Rental agreements: every version, every field</h2><p class="gd-p">The booking&#39;s Rental agreements card: the current version of CarmaCars&#39; and Blind Spot&#39;s agreements, every earlier one, and what is still blank.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Once the agreement is signed and countersigned, any change to what it prints makes a new version of both documents by itself: the dates, the price lines, the car, a driver added or corrected, the coverage, the deposit or how it was paid, an address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A change to the dates, the price, the car, the drivers or the coverage option is signed again: the renter (and each driver it affects) gets their link by email and text, and the card shows &quot;Agreement v3 waiting for signature&quot;. A correction (a typo in an address, a plate written differently) is filed without signing; the renter gets the corrected copy by email.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check-in makes the &quot;as picked up&quot; copy (time out, km out, fuel out, the car&#39;s plate and VIN, the check-in report), countersigned by whoever checked the car out; check-out makes the closing copy (time in, km in, driven and charged, fuel in, late hours, damage, the return charges, the final totals). Both go to the renter by email.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Every version</b> lists each one with what changed and both PDFs. <b class="gd-ui">Resend the signing links</b>, or press the button with their first name beside it to have them sign on your phone or tablet.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The card lists what the agreements still print blank (a licence expiry, the insurer&#39;s policy number, the insured vehicle, a VIN). Type the values and press <b class="gd-ui">Save the missing fields</b>: the agreements follow.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Check-in stops while a field a claim needs is blank. An Admin can let it go ahead: type the reason and press <b class="gd-ui">Override</b>; the reason is in the booking&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Make the agreements again</b> checks both against the booking at once (they also follow every change by themselves).</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><b class="gd-ui">Edit the wording</b> (Admin only) changes CarmaCars&#39; agreement text for this booking: press <b class="gd-ui">Change</b> beside a clause, edit its text, say why and press <b class="gd-ui">Save the wording</b>; <b class="gd-ui">Add</b> writes Additional terms at the end of Part 2. Only clauses not required by law or the insurer can be removed; the consents are fixed, and Blind Spot&#39;s form (the insurer&#39;s official form) is never changed. Before the renter signs, the agreement is made again; after, the change is a new version they sign, and <b class="gd-ui">Every version</b> shows each clause before and after.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-signing-that-holds-up-in-a-dispute" data-gd-task><h2 class="gd-h2">Signing that holds up in a dispute</h2><p class="gd-p">Every signature on the site is made the same way: rental agreements, amendments and new versions (remotely or on your device), and the owner agreements, schedules and forms, a co-owner&#39;s link, the partner, investment and staff agreements.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The licence on file is shown. A 6-digit code to their phone or email on file is optional: the signer may press <b class="gd-ui">Verify by code (optional)</b>, and Program settings, E-signing, <b class="gd-ui">ask for a one-time code</b> makes it a required first step again (off by default). Without the code, the certificate says the identity was not confirmed by a code.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">They say they read the documents, initial the key terms (each initials box is saved with <b class="gd-ui">Save initials</b>; <b class="gd-ui">Clear</b> takes it back to initial again) (damage and the deductible, the deposit and later charges, fuel, kilometres and late returns, their coverage, cancellation), give three consents (to sign electronically, to receive records electronically, to card charges under the agreement) and draw their signature.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Owners, partners, investors and staff do the same for their documents: the code, the reading, the key terms of their documents initialled (for example the Enrollment Agreement&#39;s three confirmations, Form C&#39;s acknowledgments, Schedule C, the staff agreement&#39;s confidentiality), two consents and the drawn signature. Form C&#39;s witness still types their name beside the owner.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Each step is recorded with its time, IP address and device, and the place when the device shares it. The signed PDFs end with a certificate of completion; anyone can check a signed file at <span class="gd-url">carmacars.ca/verify</span>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Typed names are off. For a signer who cannot draw, an Admin can turn on the accessibility fallback: <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Esign typed fallback.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-card-disputes-the-evidence-pack" data-gd-task><h2 class="gd-h2">Card disputes: the evidence pack</h2><p class="gd-p">Everything that proves the rental, in one PDF for Stripe.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When a card payment is disputed, the evidence pack is built by itself: the signed agreements with their certificates, the check-in and check-out reports with photos, kilometres and fuel, the licence, the payments and charges, every message to the renter, and the card checks from Stripe. It is staged in Stripe as the dispute&#39;s evidence, and To do gets an urgent task.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open the booking: the Rental agreements card shows the pack. Press <b class="gd-ui">Download</b> to check it, then <b class="gd-ui">Submit to Stripe</b> before the evidence date.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Build the dispute evidence pack</b> makes one at any time (an Admin or Finance).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-before-an-offer-is-accepted" data-gd-task><h2 class="gd-h2">The licence before an offer is accepted</h2><p class="gd-p">Front, back and a selfie, from the request on.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After sending a request the renter is asked for their licence. A licence already on file from an earlier booking is used again while it is valid after the return.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The offer cannot be accepted (by the renter, or by you on their word) and nothing is paid until the licence and its expiry date are on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Review the images as usual with <b class="gd-ui">Review documents</b>: the card Renter documents is on Review and offer too.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The switch is in <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Booking requests and offers: Booking licence required (on), with the selfie (on).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-the-licence-reader" data-gd-task><h2 class="gd-h2">The licence reader</h2><p class="gd-p">Every licence photo is read on upload: the back&#39;s barcode first, else the vision model (within the day&#39;s AI allowance).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The renter&#39;s empty licence fields are filled from the read; the renter confirms them. A blurry or cut-off photo is taken again at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Review documents</b> shows what was read and one line per check, Pass or Flag: photos, valid to the return, class accepted, age at pickup, name and date of birth, the Ontario number, front and back, and the main driver&#39;s Ontario licence. Staff still approve.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>, Driver&#39;s licence reader: <b class="gd-ui">Approve automatically when every check passes</b> (off). On: a driver whose front and back both read sharp and every check passes is approved in your name; anything flagged waits for a person.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Primary driver must hold an Ontario licence</b> (on): a main driver with a licence from elsewhere becomes an additional driver, the booking needs &quot;Primary driver: Ontario licence needed&quot; and pickup is blocked. The renter adds a main driver, who signs on their own link. On the document review, <b class="gd-ui">Admin: undo or let it go</b>: undo puts the first main driver back; let it go needs a reason.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>What was read is staff only and is deleted with the licence image. The licence number is never written to the logs.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-renter-documents-licence-and-proof-of-coverage" data-gd-task><h2 class="gd-h2">Renter documents: licence and proof of coverage</h2><p class="gd-p">A renter&#39;s licence photos, selfie and proof of coverage (OPCF 27 or a credit card&#39;s rental coverage) are checked before the handover. You check them yourself; no task is needed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A booking with documents waiting is a line on To do: &quot;Check &#39;s documents for booking &quot;, marked Now when the pickup is within two days. Press <b class="gd-ui">Review documents</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The pop-up shows each driver&#39;s images and the coverage: the insurer, policy number and expiry, or the card, its type and whether the name matches.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">What to check is written once at the top. One wrong? Open <b class="gd-ui">Reject this one</b> under it, type the reason the renter reads and press <b class="gd-ui">Reject</b>: they are asked for a new one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Then press <b class="gd-ui">Approve all</b>: every image, the proof of coverage and the Protection Plan still waiting are approved in one step. The number in the button is exactly what it approves (an image whose file was removed is not counted), and an image not tied to a driver of the booking is listed under <b class="gd-ui">Other documents</b>. Anything the system refuses is named with the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same pop-up is on the booking: the card Renter documents (<b class="gd-ui">Review documents</b>) on Overview and on Drivers and documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A document already approved or rejected, and each page of the proof of coverage (pink slip, OPCF 27 endorsement page), has <b class="gd-ui">View</b>: it opens the image (or the PDF) again through a link that lasts one minute, and the view is written to the audit log. After the 90-day removal of identity images the line reads <b class="gd-ui">Removed on</b> and the date, with nothing to open. Owners never see these documents.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Each opening of a renter&#39;s documents is logged. The links to the images last one minute. Field staff can also check a licence in person at the check-in (photos and four checks): the history says &quot;checked in person&quot;. Field staff also review the licence images (not the coverage) of bookings on their own jobs in the next 7 days from My jobs, with the same Approve all or a reason to reject: the history says the reviewer&#39;s role, field. Sales review the licence images (not the coverage) of any booking being arranged or under way from their To do or the booking, with the same Approve all or a reason to reject: the history says the role, sales.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payments</b>, the <b class="gd-ui">By day</b> tab: every payment and refund of a day or a range, by method, the cash drawer and the refunds waiting. Finance has the same screen.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To and the methods (card, e-Transfer, cash, cheque, platform payout, insurer, bank transfer, pre-authorized debit, other), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method and for each day; cards read as the card and its last four digits, never a code.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The cash drawer: expected (cash in less cash given back) against the count Finance records with <b class="gd-ui">Record the count</b>; a difference shows over or short.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere with the policy maths. <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the row, then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> for the bookkeeper.</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-propose-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">Propose a change to a confirmed booking</h2><p class="gd-p">The renter gets an email and answers on their booking. The calendar moves only when they accept.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking&#39;s Changes tab. Under Propose a change, set the new pickup, return or car.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Leave the price empty: a later return costs what a day of this booking costs (rental, fees and coverage, HST included; the preview shows the price a day). To price it by hand, type a New rental charge before tax, or the new total with HST.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the Reason, for the renter. They read it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/bookings/CC-10065?tab=changes</span></div><div class="gd-imgwrap" style="aspect-ratio:1200/520"><img src="/guides/img/admin-05-booking-changes-desktop-97008b21.jpg" alt="" loading="lazy" decoding="async" width="1200" height="520"><span class="gd-pin" style="left:17.5%;top:33.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:9.2%;top:50%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.3%;top:71.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:12.9%;top:91.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="requests-offers-and-bookings-who-a-booking-is-credited-to" data-gd-task><h2 class="gd-h2">Who a booking is credited to</h2><p class="gd-p">Overview (and Review and offer) shows the Sales credit: the staff member the booking counts for in their sales.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A quote or a rental is credited to whoever created or added it. A request from the website is credited to whoever sent its first offer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To give it to someone else, press <b class="gd-ui">Reassign</b>, choose who (or Nobody), say whether they sourced the client and write the reason. The booking&#39;s history and the audit log keep it, and the deal stays in the same week and month.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sourced means the staff member chose I sourced this client when they entered it, it came with a field staff referral link, or you credited it. Only a sourced booking earns a staff commission. A website request earns none unless you credit someone.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Someone said they sourced a website request? The credit line shows the claim: press <b class="gd-ui">Credit them</b> or <b class="gd-ui">Not theirs</b>, with a reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A price typed by hand shows beside the rate-sheet price, with the reason. A price under the floor or past the discount limit is flagged: press <b class="gd-ui">Mark reviewed</b> once you have looked at it.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A request keeps the lead-time adjustment of the moment it came in (&quot;Short-notice pricing +10%&quot; or &quot;Booked ahead −5%&quot;), through the offer and the payment. To change it, open the booking&#39;s review screen, <b class="gd-ui">More options</b>, <b class="gd-ui">Lead-time pricing (%)</b>: a number (0 for none), or empty for the tier of the request. A price typed by hand replaces it.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The rental never goes below the car&#39;s minimum daily rate or above its maximum (its price limits, set by the owner or on the car&#39;s Rates tab), whatever the discount, promo code or lead-time pricing: a line &quot;Minimum daily rate for this car&quot; or &quot;Maximum daily rate for this car&quot; brings it back. Only an Admin allows a price outside them: <b class="gd-ui">More options</b>, <b class="gd-ui">Allow a price outside the car&#39;s price limits (Admin only)</b>, with the reason.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The renter has 48 hours to accept (and sign the amendment) or decline, with one reminder. Any extra is charged to their Card on File; a lower price raises a refund for your approval.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-review-requests" data-gd-task><h2 class="gd-h2">Review requests</h2><p class="gd-p">Every renter is asked for a review by email and text, as they chose, only from 9 am to 9 pm Toronto time. Nothing needs setting up.</p><div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table"><table class="gd-table"><thead><tr><th scope="col">Message</th><th scope="col">When</th></tr></thead><tbody><tr><td>Mid-trip check</td><td>Rentals of 2 days or more, 24 hours after the pickup: &quot;How is the car? Reply or call if anything is off.&quot; No review ask.</td></tr><tr><td>Review request</td><td>1 hour after the check-out. It links the review page: the renter taps what they liked, adds a sentence, and gets a short draft to copy and post on Google.</td></tr><tr><td>Reminder</td><td>24 hours after the request.</td></tr><tr><td>Final follow-up</td><td>7 days after the request. Nothing more after it.</td></tr></tbody></table></div><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The booking page has the card Review requests: each message with when it went or when it will go, and why it stopped.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Ask for a review</b> sends the request now (or at 9 am if it is later than 9 pm), on any booking on a trip, returned or closed. Not twice in 24 hours.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On hold: a return or later charge (late return, kilometres, fuel, cleaning, smoking, damage, tolls and tickets) is not settled or waived, or an incident or dispute is open. The request goes by itself once they are. Press <b class="gd-ui">Send anyway</b> to send it now.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Mark reviewed</b> stops the messages when the renter tells you they already reviewed.</div></li></ol></div><p class="gd-p">The messages also stop by themselves when the renter presses &quot;I already left a review&quot;, leaves a review on the site, unsubscribes, or a Google review is matched to them. <b class="gd-ui">Bookings</b> &gt; <b class="gd-ui">Reviews</b> has the numbers (requests sent, on hold, reviews detected, the average rating), the hold list and the Google reviews to match.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The draft is made only from what the renter picked and wrote, and from the booking (the car, how long, delivery or pickup). Everyone gets the Google link, whatever their stars; a renter who gives 3 stars or fewer also sees &quot;Something wasn&#39;t right? Tell us directly&quot;.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-what-the-owner-sees-and-owner-deductions" data-gd-task><h2 class="gd-h2">What the owner sees, and owner deductions</h2><p class="gd-p">Each booking on an owner&#39;s or partner&#39;s car shows the card What the owner sees at the top of its page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Hide from the owner</b> keeps the booking&#39;s revenue from the owner until the car is returned, or until the owner statement covering it is approved. The owner sees the booking as Booked with its dates, and the calendar still shows the car busy. Add a reason if you like: it is kept in the history.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Show to the owner</b> shows it now. Approving the statement shows every hidden booking on it by itself.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not shown to the owner is for a booking with no owner revenue (an insurance placeholder, a shareholder&#39;s or the owner&#39;s own use at no charge): the owner sees only that the car is unavailable for those dates. A booking with revenue cannot be set this way.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a rental and Send an offer have What the owner sees. It starts from Settings &gt; Program, Owners and fleet: Owners see a booking&#39;s revenue (right away by default).</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">On the Money tab, Owner deductions on this booking: <b class="gd-ui">Add a booking expense</b> (cleaning, repair, fuel, platform fee or other, the amount, the reason the owner reads, a receipt number) comes off before Owner Revenue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Set the Revenue Share for this booking</b> applies within the car&#39;s signed terms. Above the terms only an Admin can, with Above the signed terms ticked and the reason. <b class="gd-ui">Back to the car&#39;s terms</b> undoes it.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Add a rental has the same under The car&#39;s owner.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The owner&#39;s statement carries each booking that counts toward the owner&#39;s revenue, at its true amounts, and lists each deduction with its reason, so the payout is always right. A booking billed to the renter always counts. Left out: a booking billed to an insurer and hidden from the owner (while Program settings keep only insurance replacements hidden), an insurer-billed rental that does not block the calendar, and a rental with &quot;Counts toward the owner&#39;s revenue&quot; off. The booking page says when a booking is not part of the owner&#39;s revenue and why. When a booking that was left out starts counting (Blocks the calendar turned on, shown to the owner, or billed to the renter), the owner gets the new booking email once, at that moment. Customer service and sales add deductions only while Program settings let them change fees.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-email-the-renter-or-the-adjuster" data-gd-task><h2 class="gd-h2">Email the renter or the adjuster</h2><p class="gd-p">Press <b class="gd-ui">Email the renter</b> at the top of a booking, or open its <b class="gd-ui">Messages &amp; history</b> section.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Write a <b class="gd-ui">Subject</b> and a <b class="gd-ui">Message</b>, or pick a <b class="gd-ui">Quick reply</b> to start from (Settings &gt; Quick replies keeps them).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Email the renter</b>. It goes from CarmaCars (bookings@carmacars.ca) and replies come back to the bookings inbox. The renter also sees it in their account and can answer there.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On a booking an insurer pays, choose <b class="gd-ui">From</b>: CarmaCars, or Blind Spot Car Rental (insurance). <b class="gd-ui">Email the adjuster</b> writes to the adjuster&#39;s email on the booking (Insurance claim), always from Blind Spot Car Rental.</div></li></ol></div><p class="gd-p">The <b class="gd-ui">Messages &amp; history</b> section is the booking&#39;s Activity log (release 35): what you and the renter wrote, every email of the booking, the texts, chat, calls, notes, events, payments, documents and visits, newest first, with a chip for each type and a search. The email form is under the log; each email you send shows in the log with your name.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Emails go out through the same daily limit as every email (the line under the form shows today&#39;s use). A message to a renter goes before digests and marketing; past the limit it waits until midnight. To write to a renter from <b class="gd-ui">People</b> &gt; <b class="gd-ui">Renters</b>, open the renter: Email the renter is at the bottom, about their latest booking or the one you pick.</div></aside><h3 class="gd-h3">Record the pickup or the return now (details later)</h3><p class="gd-p">When the car went out or came back but the checklist could not be done (no photos, no time, the renter dropped the keys), the booking&#39;s <b class="gd-ui">Check-in, check-out and signing</b> card has <b class="gd-ui">Record the pickup now (details later)</b> on a confirmed booking and <b class="gd-ui">Record the return now (details later)</b> while the car is on rent. Give the actual time (now, or earlier), the odometer and fuel if you know them, and why. The booking moves on (on rent, or returned), late return charges follow the actual time, and Fleet gets the task <b class="gd-ui">Add the photos and readings for CC-...</b>. A car overdue or due back today also has <b class="gd-ui">Returned</b>: on the To do list (Check-ins and check-outs today), on Bookings &gt; Now and at the top of the booking page, which the late return alert opens. It asks only the return time (now, or earlier) and the km and fuel if you know them, and records the return the same way. Once returned, the statement can be issued and the deposit settled; releasing the deposit before the photos are in needs an Admin and a reason. A pickup without the deposit taken needs an Admin to waive it with a reason, and without the renter&#39;s signature on the check-in report an Admin&#39;s reason too. Later, <b class="gd-ui">Add the check-in (or check-out) photos and readings</b> opens the usual checklist (photos, readings, your signature): the task closes when it is saved.</p><p class="gd-p">The Agreement card says <b class="gd-ui">Waiting for the renter&#39;s details</b> when the renter still has blanks to fill (date of birth, address, mobile, licence, coverage): their account asks for them before signing and paying. No email or text is sent.</p><h3 class="gd-h3">Find a booking</h3><p class="gd-p"><b class="gd-ui">Bookings</b> has one search box: type the booking number (CC-1042, cc1042 or just 1042), the renter&#39;s or a driver&#39;s name, an email, a phone number in any format, a plate (spaces do not matter) or a car code, then press Enter. The status filters still apply to what is found.</p><h3 class="gd-h3">Record a card payment taken outside the site</h3><p class="gd-p">A card taken in the Stripe Dashboard, or on a card reader, is recorded on the booking&#39;s <b class="gd-ui">Money</b> tab with <b class="gd-ui">Record card payment</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose what it paid: <b class="gd-ui">Rental and fees</b>, <b class="gd-ui">Rental</b>, <b class="gd-ui">Fees</b>, <b class="gd-ui">Later charges</b> or <b class="gd-ui">Deposit hold</b>, and where it was taken.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Type the <b class="gd-ui">Last 4 digits</b> and the amount. A Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard) is optional for a payment: press <b class="gd-ui">Look up</b> and the amount and last 4 digits are checked against Stripe.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record it</b>. A payment confirms a booking waiting for payment, as any payment does.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A deposit hold needs its Stripe payment id, so it can be captured or released from <b class="gd-ui">Settle the deposit</b>. It is recorded as held, with the usual release reminders. A hold on a reader lapses after 2 days, one made online after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise.</div></aside><h3 class="gd-h3">Link a payment taken outside the platform</h3><p class="gd-p">A charge or a card deposit taken in the Stripe Dashboard or through a Stripe payment link is linked to its booking by an Admin, on the booking&#39;s <b class="gd-ui">Money</b> tab: <b class="gd-ui">Link a payment taken outside the platform</b>, in the rental panel or the deposit panel.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Paste the Stripe payment id (pi_... or ch_..., from the payment in the Stripe Dashboard). <b class="gd-ui">Look up</b> shows what Stripe says: the amount, paid or a hold, and the card.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Link as a rental payment</b> or <b class="gd-ui">Link as the deposit</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It must be in Canadian dollars and not already linked. A rental payment may not be more than is open for the rental and fees. A deposit must be the whole deposit: a hold waiting to be captured is kept as held (settle it as any hold), a charged deposit is kept as captured. <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Unlinked Stripe</b> lists, every night, the Stripe payments of the last 60 days that no booking knows, with a best guess of the booking.</div></aside><h3 class="gd-h3">Charge or hold the deposit on the card reader</h3><p class="gd-p">With the S700 paired (Settings &gt; Card reader), the <b class="gd-ui">Money</b> tab has <b class="gd-ui">Charge on reader</b> (everything open, the rental, the fees or a later charge) and <b class="gd-ui">Hold deposit on reader</b>. Press <b class="gd-ui">Send to the reader</b>: the amount shows on the reader and the renter taps, inserts or swipes the card. The screen updates by itself; <b class="gd-ui">Cancel</b> stops the reader and nothing is charged. A deposit hold is captured or released from Settle the deposit like any hold.</p><h3 class="gd-h3">Credit card coverage: the same card</h3><p class="gd-p">When the renter&#39;s coverage is their credit card, the whole rental (rental and fees) is paid on that same card. The Money tab says which card. Another card on the pay page is refused and refunded at once; on the reader it is refused before the money is taken; a payment by e-Transfer, cash or the like is refused; a card typed by hand needs its last 4 digits and the box <b class="gd-ui">This is the same card</b>. Deposits and later charges can go on any card. If the renter truly has to use another card or method, press <b class="gd-ui">Allow another card</b> and give the reason (an Admin).</p></section><section class="gd-task" id="requests-offers-and-bookings-booked-as-soon-as-the-renter-accepts-release-28" data-gd-task><h2 class="gd-h2">Booked as soon as the renter accepts (release 28)</h2><p class="gd-p">A booking is booked the moment the renter approves the offer. It takes the car on every calendar, the fleet board, the car&#39;s availability and the counts, even before the payment or the pickup is recorded. Payment and the handover show as their own badges: <b class="gd-ui">Booked, payment due</b> and <b class="gd-ui">Pickup not recorded</b>. The first renter to approve gets the car: any other open offer on the same car and dates goes back to Requests with a Re-offer To do.</p><ul class="gd-ul"><li><b class="gd-ui">Booked, payment due</b> To do: a booked rental still unpaid within 48 hours of its pickup. Send the pay link, charge the saved card or record the payment.</li><li>Record the pickup To do: a pickup time that passed with nothing recorded, as before.</li></ul><p class="gd-p">When you send an offer, <b class="gd-ui">The offer as the renter sees it</b> sits right under <b class="gd-ui">Send the offer</b>: check it before you press it.</p></section><section class="gd-task" id="requests-offers-and-bookings-changes-after-signing-an-amended-agreement-no-new-signature" data-gd-task><h2 class="gd-h2">Changes after signing: an amended agreement, no new signature</h2><p class="gd-p">The rental terms (section 15.4) let CarmaCars update a booking after signing: an extension, new dates or times, a price adjustment, a fee, a car swap. The signed agreement keeps applying. Each change makes a new version of the agreement marked <b class="gd-ui">Amended</b> with the date, carrying the renter&#39;s original signature, and the renter is sent it. Nobody is asked to sign again, except an additional driver who never signed (they sign before driving).</p></section><section class="gd-task" id="requests-offers-and-bookings-check-in-and-check-out-on-one-screen" data-gd-task><h2 class="gd-h2">Check-in and check-out on one screen</h2><p class="gd-p">On the booking page, <b class="gd-ui">Check in (pickup)</b> and <b class="gd-ui">Check out (return)</b> are one screen: the time (now unless you change it), the odometer, the fuel, the photos and a note. Pick many photos at once from the camera roll or take them; tag an angle on any photo if you like. The suggested angles (front, each corner and side, rear, odometer, fuel gauge, interior front and rear, trunk, wheels, any damage) tick themselves as photos are tagged. Nothing is required but the time; the renter&#39;s own photos are added to the same report, each marked with who took it (the renter or staff) and its angle. The one-screen checklist is the button above it.</p></section><section class="gd-task" id="requests-offers-and-bookings-type-into-the-blind-spot-agreement" data-gd-task><h2 class="gd-h2">Type into the Blind Spot agreement</h2><p class="gd-p">On the <b class="gd-ui">Rental agreements</b> card, <b class="gd-ui">Type into the Blind Spot agreement</b> shows each box as the form prints it. Change a value and <b class="gd-ui">Save the corrections</b>: it is drawn in that box, and the insured vehicle, the claim number, the adjuster and missing km or fuel go back onto the booking. <b class="gd-ui">Preview the filled form</b> opens it with your corrections.</p></section><section class="gd-task" id="requests-offers-and-bookings-reopen-an-expired-offer-release-28" data-gd-task><h2 class="gd-h2">Reopen an expired offer (release 28)</h2><p class="gd-p">An expired offer reopens in one click: <b class="gd-ui">Reopen offer</b> on the booking or on the <b class="gd-ui">Expired</b> filter of Requests. The renter gets the usual offer email and text; the offer stays open 12 hours, and never past 1 hour before the pickup, unless you type other hours. Once the renter accepts, the car is held 2 hours for the payment; then the hold ends and, while the car is still free, the renter gets a fresh offer and a text to pay. When the pickup time has passed, the dialog asks for the new pickup and return first. A renter can also press <b class="gd-ui">Ask to reopen this offer</b>: you get the To do &quot;Renter wants expired offer reopened&quot; and an alert, as for a new request.</p><p class="gd-p">An offer sent after its pickup time no longer expires by itself: it expires at its own expiry time (the pickup only counts when the offer was sent before it and the pickup is 2 hours past). The offer screens say <b class="gd-ui">Pickup time has passed: update it</b> and do not send until you move the pickup.</p></section><section class="gd-task" id="requests-offers-and-bookings-one-booking-page-six-sections-release-31" data-gd-task><h2 class="gd-h2">One booking page, six sections (release 31)</h2><p class="gd-p">A booking has six sections: <b class="gd-ui">Overview</b> (the next step; the review and offer while it is being arranged), <b class="gd-ui">Money</b>, <b class="gd-ui">Drivers &amp; documents</b> (with the agreement), <b class="gd-ui">Car &amp; handovers</b> (the check-in and check-out, the photo report, signing on this device, what the owner sees), <b class="gd-ui">Messages &amp; history</b> (with the review request) and <b class="gd-ui">Claims &amp; extras</b> (changes, extensions, add-ons). Customer service, Sales, Fleet and Finance see the sections their work needs. An old link to a tab opens the section that holds it now.</p><p class="gd-p">Admin and staff open the same booking page, the same car page and the same listing review: you see every section and button, each staff function sees the parts it works with (Fleet has no Money section; only customer service and you have <b class="gd-ui">Claims &amp; extras</b>; refunds are asked for by you or Finance). A staff link to a booking opens the same page in the staff portal.</p><p class="gd-p">Every list has one search box (it finds names, numbers, plates, phones, emails and VINs) and one row of at most five chips. <b class="gd-ui">Clear</b> removes every filter; the last one you used comes back next time on this device.</p></section><section class="gd-task" id="requests-offers-and-bookings-charge-the-renter-after-the-return" data-gd-task><h2 class="gd-h2">Charge the renter after the return</h2><p class="gd-p">Once the car is back, the Money tab has one action for everything owed after the trip: <b class="gd-ui">Charge the renter</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Charge the renter</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the <b class="gd-ui">Reason</b> from the list and add a note if it helps (Other needs its note). Enter the <b class="gd-ui">Amount</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Read the line under it: it says where the money comes from before anything moves. The deposit hold while it is still valid and covers the amount (the rest of the hold is released at the same time); otherwise the card on file; otherwise a pay link to the renter by text or email.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Charge $...</b>. If the hold expired meanwhile, the card on file is charged instead, with the same amount and reason.</div></li></ol></div><p class="gd-p"><b class="gd-ui">Release</b> stays its own button. The renter&#39;s receipt shows the reason.</p></section><section class="gd-task" id="requests-offers-and-bookings-a-deposit-charged-to-a-debit-or-prepaid-card" data-gd-task><h2 class="gd-h2">A deposit charged to a debit or prepaid card</h2><p class="gd-p">When the deposit is charged instead of held on a debit or prepaid card (Charge the card on file as the deposit), the renter also pays the <b class="gd-ui">Card processing fee for a debit deposit</b> (Program settings, 2.9% and $0.30 by default): a separate, non-refundable amount on the same charge. The Money tab&#39;s history and the receipt show it; the deposit refund returns the deposit only.</p></section><section class="gd-task" id="requests-offers-and-bookings-what-the-renter-sees-still-to-do" data-gd-task><h2 class="gd-h2">What the renter sees still to do</h2><p class="gd-p">While a booking waits to be signed and paid, the Next step quotes the renter&#39;s own Sign and pay card, for example: The renter sees: &quot;Two steps left: sign the rental agreement, then pay $...&quot;. Signed for an older version of the offer counts as not signed: the renter signs the updated agreement on their Sign and pay page.</p></section><section class="gd-task" id="requests-offers-and-bookings-override-a-pickup-or-a-return-that-must-go-ahead-release-33" data-gd-task><h2 class="gd-h2">Override a pickup or a return that must go ahead (release 33)</h2><p class="gd-p">Sometimes the trip has to start (or end) even though a check still stops it. On the booking page, a confirmed booking (or one waiting for payment) and a car on rent show <b class="gd-ui">What stops the pickup now</b> (or the return) with each check in plain words: the deposit not taken, the rental agreement not signed, no renter signature on the check-in report, a licence or identity not verified, the coverage not confirmed, an additional driver who has not accepted, the payment still due, the calendar switch off, the car not marked available, maintenance overdue, the Ontario licence, the fleet insurance policy (when that rule is on in Program settings), the agreement&#39;s claim details, the tracker; at a return, an odometer lower than at pickup.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Override and record the pickup</b> (or the return).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Give the actual time (now, or earlier), the km and fuel if you know them, and why the trip must go ahead. The reason is required.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press the button. The pickup (or the return) is recorded at that time, only the checks listed are passed, for this booking and this once. The booking&#39;s history and the audit log say who, when, why and which checks; every Admin gets the alert Override used. A payment still due is not waived: the booking is confirmed with the balance open, and the deposit is still to collect (it is not waived). The photos and readings come later, as with Record now.</div></li></ol></div><p class="gd-p">When staff (Fleet, customer service, Sales, field staff) need it, they press <b class="gd-ui">Ask an Admin to override the pickup</b> (or the return) on the same card with the time they recorded. You get the alert Override asked for and a line on the To do: press <b class="gd-ui">Approve</b> (one tap) and it is recorded with the time they entered, or <b class="gd-ui">Decline</b> with a note. The request also shows on the booking page, with Approve and Decline.</p></section><section class="gd-task" id="requests-offers-and-bookings-record-a-past-trip-release-33" data-gd-task><h2 class="gd-h2">Record a past trip (release 33)</h2><p class="gd-p">A trip that happened but was never recorded (the pickup and the return both passed): on the booking page press <b class="gd-ui">Record a past trip</b>. Give the actual pickup and return times, the km and fuel at each if you know them, and the reason. Every check that would stop it is overridden as above, in one step: the booking lands in <b class="gd-ui">Returned</b>, the late return charges follow the actual return time, and the deposit can be settled. The car&#39;s status today is left as it is, and the renter is not sent a &quot;your rental started&quot; email for a trip long over. Fleet gets the task to add the photos and readings. Staff ask for it the same way; you approve in one tap.</p></section><section class="gd-task" id="requests-offers-and-bookings-book-it-now-an-offer-that-is-a-booking-at-once-release-33" data-gd-task><h2 class="gd-h2">Book it now: an offer that is a booking at once (release 33)</h2><p class="gd-p">When you send an offer (answering a request, or <b class="gd-ui">Send an offer</b> without one), tick <b class="gd-ui">Book it now (no renter approval)</b> above Send. The offer becomes the approved version at once: the booking waits for payment, the car is held for its dates as for any approved offer, and the renter gets one link to the <b class="gd-ui">Sign and pay</b> page to sign and pay (the &quot;approve your offer&quot; email is not sent). To have them sign and pay with you, open the booking: <b class="gd-ui">Sign now on this device</b>, then take the card on this device. When customer service or Sales tick it, the offer goes out and you get the alert Override asked for and a To do line: <b class="gd-ui">Approve</b> in one tap books it the same way. The booking&#39;s history says who booked it and that the renter did not approve it.</p><p class="gd-p">Already sent the offer? Tell Claude or the assistant: &quot;Book the offer of CC-10482 now, the renter agreed by phone&quot;. Claude&#39;s connector has the tool <b class="gd-ui">Book an offer now</b>, and <b class="gd-ui">Send an offer</b> and <b class="gd-ui">Make an offer</b> take Book it now too; the assistant (Assistant at the top of the menu) takes it in the same sentence as the offer. Each is two steps: you see what will change (nothing is changed yet), then you confirm, and the booking waits for the renter to sign and pay as above. As an Admin it is done at once; when customer service or Sales ask the assistant, it waits for your one-tap Approve.</p></section><section class="gd-task" id="requests-offers-and-bookings-a-request-replaced-by-a-newer-one" data-gd-task><h2 class="gd-h2">A request replaced by a newer one</h2><p class="gd-p">When a request or offer expired and the renter made a newer one for the same car and dates, the old one is hidden from Requests and keeps its number and history. Both booking pages say so under the title: <b class="gd-ui">Replaced by #CC-10483</b> on the old one and <b class="gd-ui">Replaces #CC-10482</b> on the new one, each a link to the other. Customer service, Sales and the other staff pages show the same note.</p></section><section class="gd-task" id="requests-offers-and-bookings-change-protection-release-41" data-gd-task><h2 class="gd-h2">Change protection (release 41)</h2><p class="gd-p">How damage to the car is covered is one control on the booking page: the <b class="gd-ui">Protection</b> card at the top (Overview and the Money tab). An Admin, customer service and fleet use it on any booking; sales on a request or an offer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Change protection</b>. A small window lists the three options: <b class="gd-ui">Own insurance (OPCF 27)</b>, <b class="gd-ui">Credit card coverage</b> and <b class="gd-ui">Protection Plan</b>, each with the price difference (the plan shows its price a day times the days, plus HST), the deposit (no coverage rule changes it) and what the renter provides.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The rule is the same as on the renter&#39;s page: credit card coverage needs the renter&#39;s card picked from the coverage list, a card that covers this car, and the renter&#39;s confirmation that they pay with it; OPCF 27 needs the renter&#39;s confirmation that they upload their policy; otherwise the Protection Plan. An Admin can tick Admin override: the reason is recorded on the change and in the booking history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Write the reason (required; the renter reads it) and press <b class="gd-ui">Change protection</b>.</div></li></ol></div><p class="gd-p">What happens: the booking is repriced at once. More to pay is a balance to collect on the Money tab; less, when the plan was paid, is a refund for an Admin to approve. No money moves by itself. An offer is sent again as a new version; a confirmed booking or a rental in progress gets the amended agreement (the renter signs the new version when the rules ask) and one email. Proof tasks follow the new option. Changes are refused after damage is reported on the booking.</p><p class="gd-p">A renter&#39;s request to leave the Protection Plan shows on the same card with their proof (<b class="gd-ui">Open the proof</b>). Customer service or an Admin presses <b class="gd-ui">Approve</b> (the change is made and the coverage confirmed) or <b class="gd-ui">Decline</b> with a note the renter reads. The task &quot;The renter asks to leave the Protection Plan&quot; opens the booking.</p></section><section class="gd-task" id="requests-offers-and-bookings-change-the-car-before-pickup" data-gd-task><h2 class="gd-h2">Change the car before pickup</h2><p class="gd-p">On a request, an offer or a confirmed booking that is not picked up yet, press <b class="gd-ui">Change the car</b> at the top of the booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the new car. Only cars free for the whole booking are listed, each with its new total and the difference.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Say why the car changes, then press <b class="gd-ui">Change the car</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The price comes from the new car&#39;s rate sheet (its rates, the km included and the rate per km). The coverage, the drivers and the add-ons stay as they are.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">An offer is sent again with the new car: that offer is the renter&#39;s one email.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">On a confirmed booking, more to pay is left open: the renter sees <b class="gd-ui">Pay the balance</b> on their booking, or you send a pay link or charge the saved card from Money. Less to pay becomes a refund that waits for approval, with a To do for Finance. The renter gets one email, <b class="gd-ui">Booking updated</b>, with the new car and the money.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">The open handover and return jobs move to the new car. The agreement gets a new version for the renter to sign; its link goes by text.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">The booking&#39;s history and the audit log keep who changed it, from which car, to which car and why.</div></li></ol></div><p class="gd-p">Customer service and Admins change any of them; Sales changes a request or an offer; Fleet changes a confirmed booking. Once the car is out, use <b class="gd-ui">Swap vehicle</b> instead.</p></section><section class="gd-task" id="requests-offers-and-bookings-the-accident-card-of-a-booking" data-gd-task><h2 class="gd-h2">The accident card of a booking</h2><p class="gd-p">Every booking from confirmation to the return shows its <b class="gd-ui">Accident card</b>: the steps after an accident and the coverage this booking uses.</p><ul class="gd-ul"><li>OPCF 27: the renter&#39;s own insurer and policy number, from the proof they uploaded.</li><li>Credit card coverage: the card and its coverage provider, from their proof.</li><li>Protection Plan: the provider, the policy number and the claims phone from Settings &gt; Program (Tolls and damage), with the renter&#39;s plan reference.</li></ul><p class="gd-p">Press <b class="gd-ui">Print the card</b> for the printable card. The renter has the same card on their booking. It never shows the fleet policy.</p></section><section class="gd-task" id="requests-offers-and-bookings-close-ended-trips" data-gd-task><h2 class="gd-h2">Close ended trips</h2><p class="gd-p">A back-dated close sends the renter no email or text. Fleet gets a To do when a trip is still open 2 hours after its return time, and the morning digest lists how many are open.</p><p class="gd-p"><b class="gd-ui">Bookings</b> shows a banner when trips have ended and are not closed; <b class="gd-ui">Close ended trips</b> lists each one: never picked up in the system, on rent after the return, or returned and never closed. Fleet and Finance have the same page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Tick one or several, then <b class="gd-ui">Mark them</b>: returned on time, returned late (give the time it came back), or a no-show (an Admin or customer service).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the deposit: <b class="gd-ui">Deduct the balance owed</b>, <b class="gd-ui">Deduct the late fee</b>, or <b class="gd-ui">Release in full</b>. A card hold that has expired is marked settled at once (released by expiry: no money moves).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">If no deposit was taken, an Admin fills <b class="gd-ui">Admin: deposit not taken, waive it because</b> (the same field is in Record a past trip).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Nothing is released by itself: the decision waits under <b class="gd-ui">Deposit decisions waiting for an Admin</b>, and an Admin presses <b class="gd-ui">Release</b> (or <b class="gd-ui">Release now (tolls window)</b>).</div></li></ol></div></section><section class="gd-task" id="requests-offers-and-bookings-return-charges" data-gd-task><h2 class="gd-h2">Return charges</h2><p class="gd-p">A late return is charged per started extra day at the booking&#39;s full daily cost (the rental per day after discounts, plus per-day and per-trip fees such as the Protection Plan, never delivery), and only the started hours after the whole days get the hourly late fee. On the booking&#39;s <b class="gd-ui">Money</b> tab, each renter line not on a statement yet has <b class="gd-ui">Change amount</b> (lower) and <b class="gd-ui">Waive</b>, with the reason; it is in the booking history and the next assessment keeps it. An expired card hold after the return has <b class="gd-ui">Mark settled (released by expiry)</b>.</p></section><section class="gd-task" id="requests-offers-and-bookings-switching-a-booking-to-the-protection-plan-release-43" data-gd-task><h2 class="gd-h2">Switching a booking to the Protection Plan (release 43)</h2><p class="gd-p"><b class="gd-ui">Change protection</b> &gt; <b class="gd-ui">Protection Plan</b> uses the car&#39;s own plan price, the same amount the window quotes. It is no longer refused when Fees has no flat Protection Plan amount.</p></section><section class="gd-task" id="requests-offers-and-bookings-the-protection-plan-priced-from-rentalcover-release-35" data-gd-task><h2 class="gd-h2">The Protection Plan priced from RentalCover (release 35)</h2><p class="gd-p">The Protection Plan stays our product: renters never see the RentalCover name. Without the RentalCover partner key it is priced from the Protection Plan table, as before. Once the key is set, its price comes from a real RentalCover quote for the renter (their dates, their age at pickup, their name and email) plus our markup (20% unless <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b> changes it). The request form asks for the quote once the renter&#39;s details are in, and an offer as you choose option 3; a quote is reused for 15 minutes. A price you type for the plan wins. If RentalCover does not answer, the table price applies.</p><p class="gd-p">RentalCover covers up to $50,000 an incident, so the plan is offered only for a car worth less. The value used: your override under <b class="gd-ui">Value for the Protection Plan</b> on the car&#39;s page when set, else the car&#39;s Canadian Black Book value, else an AI estimate from typical listing prices that the site makes by itself (<b class="gd-ui">Refresh the AI estimate</b> asks again). A car with no value counts as over the limit: the request form, the offer screen and the database then offer only OPCF 27 or credit card coverage.</p></section><section class="gd-task" id="requests-offers-and-bookings-extensions-at-the-all-in-price-a-day-release-35" data-gd-task><h2 class="gd-h2">Extensions at the all-in price a day (release 35)</h2><p class="gd-p">An extension costs what the renter already pays, averaged per day: the booking&#39;s total for the booked period (the rental after discounts, every fee, one-time fees like delivery included, and HST) divided by its days, for each added day. A booking of $729.36 for 7 days costs $104.19 for each added day. Added hours under a day cost the hourly late fee with HST, never more than a day. There is no extension discount.</p><div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table"><table class="gd-table"><thead><tr><th scope="col">Where</th><th scope="col">What happens</th></tr></thead><tbody><tr><td>The renter&#39;s <b class="gd-ui">Extend</b> page</td><td>Each option shows the total and the price a day before paying</td></tr><tr><td><b class="gd-ui">Edit</b> on a confirmed or on-trip booking, made longer</td><td>The booking&#39;s new total is the all-in price of the longer stay; the per-trip fees stay as booked and the rental charge takes the difference</td></tr><tr><td>The next period of a long rental</td><td>Keeps the rate of the booked period (the rental a day, per-trip fees scaled)</td></tr><tr><td>An insurer-billed booking</td><td>Priced as before</td></tr></tbody></table></div><p class="gd-p">The extension is one line on the booking, &quot;Extension: 3 days at $104.19/day (all-in)&quot;, HST included. Its HST is the booking&#39;s own share of HST, so invoices and the books never add HST on top. Type a rental charge in <b class="gd-ui">Edit</b> to set another price. Late returns are unchanged: the daily cost of each extra day and the hourly late fee.</p></section><section class="gd-task" id="requests-offers-and-bookings-a-fixed-amount-per-payment-release-35" data-gd-task><h2 class="gd-h2">A fixed amount per payment (release 35)</h2><p class="gd-p">On a weekly, every 2 weeks or monthly plan, an Admin can set <b class="gd-ui">Fixed amount per payment</b> in <b class="gd-ui">Change the plan</b>. Each payment is that amount and the last one takes the remainder. The total and the payments already made never change. Leave it empty to split the payments by the days again. A payment of $0 is never shown: when the fixed amount covers the total early, the last period joins the payment before it ($1,850 at $925 every 2 weeks is 2 payments).</p></section><section class="gd-task" id="requests-offers-and-bookings-a-payment-plan-s-first-payment-confirms-the-booking-release-" data-gd-task><h2 class="gd-h2">A payment plan&#39;s first payment confirms the booking (release 48)</h2><p class="gd-p">On a weekly, every 2 weeks or monthly plan, the booking is confirmed once the first payment is paid, by a pay link, the saved card or a payment you record. The rest is collected by the plan, as on a confirmed booking.</p></section><section class="gd-task" id="requests-offers-and-bookings-change-the-car-of-a-booking-partly-paid-release-48" data-gd-task><h2 class="gd-h2">Change the car of a booking partly paid (release 48)</h2><p class="gd-p">A booking waiting for payment that already has a payment can be changed with <b class="gd-ui">Edit</b> on its Overview, as a confirmed booking is: another car, the dates, the places. The car changes with the price as it is, new dates are priced at the booking&#39;s own rates, and every payment stays recorded. The new car and dates must be free. Edit the offer is for a booking with nothing paid yet.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Claude&#39;s connector does the same with <span class="gd-url">change_booking</span>, and lets a main driver keep a licence from outside Ontario on one booking with <span class="gd-url">licence_let_go</span> (your <b class="gd-ui">Let it go</b>, with the reason). Both show a preview first.</div></aside></section><section class="gd-task" id="requests-offers-and-bookings-the-request-as-sent-and-every-offer-release-35" data-gd-task><h2 class="gd-h2">The request as sent and every offer (release 35)</h2><p class="gd-p">On a request or a booking, <b class="gd-ui">Original request, as the renter sent it</b> shows the car, dates, places, coverage, add-ons, note and the price the renter saw, exactly as sent; staff changes never touch it. <b class="gd-ui">Offer history</b> lists every offer version, newest first: its status, who sent it and when, the car and dates, the message, how the total moved, and the price breakdown.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">To go back to an old version, press <b class="gd-ui">Revert to this offer</b> on it. Its car, dates, price, deposit, discount and fees load into the review as a new offer, highlighted.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the price, then send it in step 3. Nothing changes until you send.</div></li></ol></div><p class="gd-p">The <b class="gd-ui">Coverage</b> line at the top says what the renter chose (own insurance OPCF 27, credit card, Protection Plan) and its proof: not sent yet, waiting for review, confirmed, or rejected with the reason.</p></section><section class="gd-task" id="requests-offers-and-bookings-send-an-offer-in-three-steps-release-35" data-gd-task><h2 class="gd-h2">Send an offer in three steps (release 35)</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Car and dates</b>: the renter, the dates, the car and where they pick it up and return it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Price</b>: filled in from the rate sheet with the checkout&#39;s fees and discounts. Change it only if you agreed another price.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Review and send</b>: what changed, the message and how the link goes.</div></li></ol></div><p class="gd-p">Rarely used options (billing an insurer, how it is paid, the calendar) are under <b class="gd-ui">More options</b>. Send waits while the price is being worked out again after a date change, and one tap sends once.</p></section><section class="gd-task" id="requests-offers-and-bookings-the-owner-s-own-trip-instant-bookings-and-book-it-now-releas" data-gd-task><h2 class="gd-h2">The owner&#39;s own trip, instant bookings and Book it now (release 35)</h2><ul class="gd-ul"><li><b class="gd-ui">Owner&#39;s own trip ($0)</b>: the owner booked their own car. There is nothing to price or send; get the car ready.</li><li><b class="gd-ui">Instant (repeat renter)</b>: a Gold renter or above (Rewards, release 40) with a verified licence and nothing owing booked an available car at once and went straight to sign and pay. An Admin can take a renter&#39;s instant booking away with <b class="gd-ui">Take instant booking away</b>, on the booking page or on the renter&#39;s page.</li><li><b class="gd-ui">Any car, any time</b> (release 40): a Platinum renter asked for dates the car shows as taken. Fleet gets an urgent task due within 4 hours: confirm it, offer an equivalent car or an upgrade, or decline with a reason. Never cancel or move another renter&#39;s confirmed booking for it. The task closes when the request is answered.</li><li><b class="gd-ui">Book it now</b> pressed by staff waits for an Admin&#39;s one-tap approval.</li></ul></section><section class="gd-task" id="requests-offers-and-bookings-secondary-contact-and-rideshare-documents-release-35" data-gd-task><h2 class="gd-h2">Secondary contact and rideshare documents (release 35)</h2><p class="gd-p">The booking shows the renter&#39;s <b class="gd-ui">Secondary contact</b> when they gave one: call them when the renter cannot be reached. Rideshare and delivery driving are welcome (rental agreement, section 10.3): never tell a renter it is not allowed. When a renter makes <b class="gd-ui">rideshare documents</b> (Uber, Lyft, DoorDash and others), you get an alert and the booking shows the letters they made.</p></section><section class="gd-task" id="requests-offers-and-bookings-offers-coverage-delivery-and-fuel-releases-35-and-36" data-gd-task><h2 class="gd-h2">Offers, coverage, delivery and fuel (releases 35 and 36)</h2><ul class="gd-ul"><li>Sending an offer is three steps: car and dates, price, review and send. Every request shows the renter&#39;s original request as sent and every offer version, with who sent it and when; reverting loads an old version as a new offer to send.</li><li>Instant booking: a verified Gold renter or above books an available car at once, signs and pays; the booking is marked Instant (repeat renter), and an Admin can take instant booking away from a renter.</li><li>Card coverage is checked against the car: the card, the car&#39;s value, its type and the rental length. A card that does not cover it cannot be approved. OPCF 27 needs both the pink slip and the endorsement page.</li><li>Delivery is priced by distance from the company&#39;s address (1570 Midland Ave, Scarborough): a base, the kilometres included and a rate per km, all in Program settings; a car&#39;s own fee stays as an override.</li><li>The fuel line at the return is suggested from the car&#39;s tank, the weekly pump price and a multiplier, plus the refuelling fee, and checked on the deposit review before any charge.</li><li>Owner price limits: the daily minimum and maximum of a car or an owner hold every price, discount and offer; only an Admin can allow one request outside them, with a reason.</li><li>Rideshare and delivery work is allowed with the documents the renter makes on their booking page (rental agreement copy, coverage letter, vehicle letter); staff get an alert when they are made. The secondary contact shows on the booking.</li><li>Mid-trip review ask: halfway through a trip of several days, the renter gets one short message asking how it is going; a problem they report becomes a To do for customer service.</li><li>A car that has only test bookings can be deleted by an Admin; the test bookings go with it. A car with a real booking cannot be deleted.</li></ul></section><section class="gd-task" id="requests-offers-and-bookings-check-in-and-check-out-on-one-screen-release-42" data-gd-task><h2 class="gd-h2">Check-in and check-out on one screen (release 42)</h2><p class="gd-p"><b class="gd-ui">Start the check-in (pickup)</b> and <b class="gd-ui">Start the check-out (return)</b> on the booking, and <b class="gd-ui">Check in</b> or <b class="gd-ui">Check out</b> on the To do list, open the same screen field staff use, made for a phone held in one hand:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every part is on one page in the order you do it, with a green tick once it is complete: the ready check, the renter, licence and card (one tap each), the odometer, fuel and keys, the photos, damage, the tracker, then the signatures.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">What is known is filled in: the odometer and fuel from the Tracker when it reported in the last 30 minutes (else from the car&#39;s last report), the keys, and Standard for the cleanliness of a return. Check each against the car and change what differs.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Photos are one tap each: <b class="gd-ui">Take this photo</b> always shows the next angle.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">What is optional is folded away: new damage, a note, belongings, a renter who is not there or will not sign.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The button at the bottom says what is still needed (for example &quot;Next: Odometer&quot;) and takes you to it. When everything is in, press <b class="gd-ui">Hand over the keys</b> or <b class="gd-ui">Complete the return</b>.</div></li></ol></div><p class="gd-p">Nothing was dropped: the condition report still needs every photo, the readings and the signatures, and the database refuses a handover with anything missing. Leave the page and come back: your answers and photos are still there.</p><p class="gd-p"><b class="gd-ui">Check in with photos already taken (from the gallery)</b> is still under the button, for a car that was photographed earlier.</p></section><section class="gd-task" id="requests-offers-and-bookings-a-late-return-is-a-choice-release-42" data-gd-task><h2 class="gd-h2">A late return is a choice (release 42)</h2><p class="gd-p">A car that comes back after the grace period is never charged by itself. The booking shows <b class="gd-ui">Late return</b> with how late the car was and five choices, each with what it costs:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Charge as an extension</b>: every started day late at the booking&#39;s daily rate, as an extension would have cost.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Charge extra days</b>: you choose the days, from 1 up to the started days, at the daily rate.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Charge the late return fee</b>: the fee of the rental terms (whole days at the daily rate, the started hours after them at the hourly fee, capped a day).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge a custom amount</b>: type the amount before tax and what it is for. The renter sees the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Waive it</b>: no charge, with the reason.</div></li></ol></div><p class="gd-p">Press <b class="gd-ui">Save the late return charge</b>. The charge goes on the return statement and is taken as every return charge is: from the deposit, then the card on file, then a pay link. The renter gets a message on the booking that says what was chosen, and the booking history keeps who chose and why.</p><p class="gd-p">Until someone chooses, nothing is charged for the late return and Fleet has the To do &quot;Late return: choose the charge&quot;. Field staff can choose on the return screen as they complete the return.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A custom amount above your single limit, and a waiver by anyone other than an Admin, Finance or Fleet, waits for an Admin: they get the To do &quot;Late return: approve the charge&quot; and press <b class="gd-ui">Approve as asked</b>, or choose another way. Only an Admin changes a late return that is already decided, and not once it is on a statement or paid.</div></aside><p class="gd-p">On <b class="gd-ui">Close ended trips</b>, marking a trip returned late and choosing <b class="gd-ui">Deduct the late fee</b> is the same choice of the late return fee, made there. The other deposit choices leave the late return to be chosen on the booking.</p></section><section class="gd-task" id="requests-offers-and-bookings-picked-up-deposit-pending-release-48" data-gd-task><h2 class="gd-h2">Picked up, deposit pending (release 48)</h2><p class="gd-p">Staff who record handovers, and you, can let a car go with the deposit still owed, with the reason (Record the pickup now, the one-screen check-in, the field job, or <b class="gd-ui">Deposit not taken: let the car go owing it</b> before the full check-in). The booking goes on rent and shows <b class="gd-ui">Deposit pending $X</b> beside its status for every role, with who let it go and why. Each morning from the deposit hold hour the saved card is tried for the hold once; if it fails or there is no card, the deposit link goes to the renter. After 48 hours still unpaid you get the To do <b class="gd-ui">Deposit still owed</b> and an urgent alert, both opening the booking&#39;s Money tab. Taken, waived or the car back: it ends by itself. Program settings, <b class="gd-ui">A car out with the deposit owed: try the saved card each morning, then send the deposit link</b>, turns the morning tries off. From Claude&#39;s connector: record_handover with <span class="gd-url">deposit_pending: true</span> and <span class="gd-url">deposit_pending_reason</span>, previewed then confirmed.</p></section><section class="gd-task" id="requests-offers-and-bookings-long-term-rentals-paid-weekly" data-gd-task><h2 class="gd-h2">Long-term rentals paid weekly</h2><p class="gd-p">For a renter who keeps the car week after week and pays each week:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking (confirmed, or the car already out). On the Overview or Money tab, the <b class="gd-ui">Long-term, paid weekly</b> card: press <b class="gd-ui">Turn on</b>. If the car has another booking or a block after the return, the card names it: move that first.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">From now on the car stays out on the calendar and on the site until the renter gives notice. You never extend the return by hand.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each week, when the renter pays cash or e-Transfer, use <b class="gd-ui">Record a payment</b> for the rental as usual: the amount is the next week&#39;s price, and the return moves 7 days.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">48 hours before the return (Program settings, <b class="gd-ui">Long-term weekly rentals: hours before the return</b>), if the next week is not paid, the renter gets a pay link by text (else email) and you get a To do. Paying the link moves the return too, and the To do closes by itself.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">When the renter gives notice, press <b class="gd-ui">End rental on</b> and pick the last day. The last week stops on that day and the car shows free after it. Leave the date empty to go back to until notice.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Turn off</b> makes it a normal booking again: the car shows free after the current return.</div></li></ol></div><p class="gd-p">Claude&#39;s connector does the same: <span class="gd-url">change_booking</span> with <span class="gd-url">changes.rolling_weekly</span> true or false, and <span class="gd-url">changes.rolling_end_on</span> for the last day; <span class="gd-url">record_payment</span> records the week.</p></section><section class="gd-task" id="requests-offers-and-bookings-payments-by-e-transfer-or-cash-deposits-and-tips" data-gd-task><h2 class="gd-h2">Payments by e-Transfer or cash, deposits and tips</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: a payment of the whole total pays every line of the booking (the rental, short notice, the young driver fee, the Protection Plan), whichever part you record it for. When nothing is open, a booking waiting for payment is confirmed by itself.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">The deposit by e-Transfer or cash is doubled</b>: twice the car&#39;s deposit by default (Program settings). The Security deposit card shows both amounts (&quot;Credit card hold $300.00; e-Transfer or cash $600.00 (2x)&quot;), and the renter sees them on the offer and the pay page before paying.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Collect the deposit</b> &gt; Cash or e-Transfer: leave the amount empty to take what is owed. Less is recorded as a part (the card says <b class="gd-ui">under, still owed $X</b> and <b class="gd-ui">Collect the $X still owed</b> takes the rest); more is held and given back with the deposit (<b class="gd-ui">over, to return $X</b>).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Change the deposit</b> on Edit booking (an Admin, with the reason), even while the booking waits for payment: the Money tab, the deposit link and Collect $X deposit follow at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Voided a deposit by mistake?</b> After the void the deposit is <b class="gd-ui">Not collected</b> again everywhere (the header too): record it again.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Tips</b>: the renter can add one when paying, on the receipt and from the after-trip email. A tip in cash or by e-Transfer: <b class="gd-ui">Tips</b> &gt; <b class="gd-ui">Record a tip</b>. Half goes to the booking&#39;s salesperson and half to the staff member at the handover; with no staff salesperson (a direct booking) CarmaCars keeps that half; one person who did both gets it all. An Admin can give one tip another split (<b class="gd-ui">All to ...</b>, <b class="gd-ui">Back to the usual split</b>). A tip is never part of the rental or the owner&#39;s share.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">A greyed-out button says under it what to do first.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t"><b class="gd-ui">Documents</b> &gt; <b class="gd-ui">Approve</b> names what it approves (&quot;Approve the proof of coverage&quot;, &quot;Approve all 3: licence front, licence back and selfie&quot;). A booking with one driver reads <b class="gd-ui">No additional drivers</b> in the checklist, and <b class="gd-ui">Licence and selfie verified</b> ticks as soon as Documents shows every image approved.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Every tip, who got what and CarmaCars&#39; share: <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Tips</b>.</div></li></ol></div></section>');
select app.guide_release_section('admin', 'owner-money', 'chapter', 'owners-and-onboarding', 'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner money**, the **Invoices** tab. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Already paid outside the platform** on the invoice: choose how (e-Transfer, cash, cheque, bank transfer or card outside the platform), the date and the reference. A draft is issued without the invoice email first, the payment is recorded, and the owner gets no email unless you tick **Email the owner a receipt**. To record a smaller or extra payment, press **Record payment**. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for payments the bank sends back and owners with no bank debit set up.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each owner''s bank debit. Use **Pause**, **Resume**, **Send a notice now** or, with no bank debit set up, **Send the sign-up link**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task. Any debit missed (returned for another reason, too late to retry, or a retry still waiting) comes off the owner''s next revenue statement by itself: when the statement is built, the invoice goes in arrears (a waiting retry is cancelled) and the statement deducts it. Nothing to do.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no bank debit set up gets an email on the notice day and you get a task; nothing is debited for them.

## Before the debit day: the Debit preview

The top of the Debits tab shows the coming debit day.

1. **Debit preview** lists each owner with something to debit: the total, whether a bank debit is set up, whether the notice went, and each invoice in one line: the amount, the car, the fee (monthly fee, first and last month, tracker install, adjustment, late fee), the period and how it was worked out, such as "prorated: 20 of 30 days". The line opens the invoice.
2. Something looks wrong? Press **Hold** beside the owner and give the reason. Nothing is debited for that owner until you press **Resume**.
3. **Fee check** compares the month''s invoices with each car''s signed terms: no monthly fee on a flat monthly payment, a Turo-Only car, a shareholder''s car or a company car, nothing before the Enrollment Date, and the amount the terms give. It changes nothing: void and reissue an invoice that does not match. Each production deploy prints the same check.

## When a debit can''t go ahead

You get one email: "Can''t collect $X from the owner: the reason". The reasons are the words of the owner guide: no bank debit set up, owner cancelled the debit at their bank, amount went up after the notice, the bank sent the payment back. The email lists each amount in one line and has one button that fixes it.

1. **Send the sign-up link** opens the Debits tab on that owner. Press **Send the sign-up link** again there: the owner gets the email to set up their bank debit.
2. **Send a new notice** opens the same place with **Send a new notice** for the new amount.
3. **Open the invoice** opens the invoice to record a payment made another way.

## Owner statements

**Money** > **Owner money**, the **Statements** tab

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/2eedf660-50ce-4bd9-86d6-01bbe149c000; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Company**, the **Commissions** tab. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.
5. **Owner requests** lists the commission each salesperson asks for an owner they brought in: a flat amount, or a percent of the company''s share or of the cars'' rental revenue, for a number of months or for as long as the car is with us. Press **Approve**, **Change and approve** (your terms, with a note) or **Decline**. Nothing accrues before you approve. A flat amount is earned at the owner''s first paid rental, once; a percent on each paid rental of the owner''s cars in the time approved. Each then comes to the list above for approval.
6. Who sourced an owner: the owner''s page, **Sourced by**. Only an Admin changes it, with a reason. A waiting request of the person before is withdrawn; an approved one, with what it has not paid yet, goes to the new person.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| An owner a salesperson brought in | The request you approved. A CarmaCars expense, never deducted before Owner Revenue; none on CarmaCars'', a partner''s or a shareholder''s cars |
| Field staff | 10% (also the field referral fee). Customer service, Fleet and Finance staff get no sales credit or commission, ever: their help is credited as Helped by on the booking and on their scorecard |
| Base | The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Field pay

**Money** > **Company**, the **Field pay** tab. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.

:::flow
Clocked in and out | Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out
Pay run started | Hours times the hourly rate, plus the approved commissions
Approved | The figures are frozen, the period''s hours are locked, the statements are numbered
Paid | You recorded how each person was paid; they get their statement by email
:::

1. The tab **Pay run** shows the current two-week period (Sunday to Saturday: the first day is Settings > Program, Field pay). **Earlier period** and **Later period** move between periods.
2. After the period ends, press **Start the payroll**: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). **Refresh the figures** takes in a change made since.
3. Press **Approve**. The period''s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under **Hours** first. **Withdraw** takes an approved run back while no payment is recorded.
4. Press **Record payment** on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email (**Send again** repeats it). The statement''s number opens its PDF; **CSV** gives the run for your accountant.
5. **Hours** lists everyone''s shifts of the period. **Add hours** enters a shift for someone who forgot to clock in, **Change** fixes one and **Remove** takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.
6. **Hourly rates** shows each person''s rate: CA$18.00 an hour unless you give them their own with **Set the rate** (a reason is needed). A pay run keeps the rate it was started with.

|  | Field pay |
| --- | --- |
| Overtime | Off. Settings > Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate |
| Vacation pay | Off. Settings > Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement |
| Deductions | None are worked out: income tax, CPP, EI and the employer''s contributions are for your accountant. Each statement says so |
| Commissions that net to nothing | A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next |

> Tip: A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.

## Company model

Money > **Company model** is the CarmaCars model workbook, live: the actuals, the forecast and the pro forma on one page. Admins only (not Finance). Never share it: investors have their own sheets in the investor portal.

1. **Forecast**: the latest actual month, the EBITDA break-even month, the next 12 months'' EBITDA and the lowest cash, a chart of EBITDA and cash, and 36 months marked A (actual) or F (forecast): cars, utilization, revenue per rented day, revenue, costs, EBITDA, investor returns, tax and cash.
2. **Actuals**: filled in by themselves every hour from the bookings, payments, payouts, expenses and investments. Rental earned is spread over each rental''s days (before HST, insurer-billed and renter-billed apart, placeholders left out), with fees by kind, cash received by method, rentals and rented days, owner and partner shares, commissions, kickbacks, expenses by category and investor payouts. **Refresh actuals now** recomputes them at once.
3. **Pro forma 5 years**: each year''s income statement, cash flow and key figures.
4. **Assumptions**: growth, the utilization ramp, rates, monthly costs, hires, planned capital raises, the fleet insurance premium and tax. Press **Save the assumptions**; the forecast, the pro forma and the download use them at once. A field marked "From the actuals" left blank uses the latest complete month.
5. **Download as Excel**: the full internal workbook with live formulas and the current actuals.

> Tip: Enter the fleet insurance premium under Assumptions; until then it counts as $0 and profit is overstated. Enter each month''s costs in Money > Expenses: a cost line with nothing entered for an actual month uses the assumption, marked est.

## Payroll for everyone (release 35)

**Money** > **Payroll** is one run every two weeks for the field staff (hours) and for customer service, Fleet and Finance (salary).

1. A salaried person is paid their monthly salary x 12 / 26, for the days they were employed in the period. The salary is their own (**Set the salary**, with a reason), else the monthly pay they were hired at, else their role''s (Program settings, va_salary_defaults), in US dollars unless set otherwise.
2. Finance prepares it: **Start the payroll**, **Add a bonus or deduction** with the reason, then **Send for approval**. You get an alert.
3. You press **Approve**, then **Record all payments** (one method and reference; each stub number is added to it) or **Record payment** line by line. Each person gets their stub by email and in their portal.

> Tip: Admin > Team also has **Schedules** (each role''s days and hours, anyone''s own, who is late today) and **KPIs** (every staff member''s KPIs for a week against the targets in Program settings).

> Good to know: The townhall page: pick the craziest story, enter the week''s social media figures, add the recording link, and mark anyone present or absent. Staff who miss two townhalls in a row are locked until you press **Unlock** on the staff list.

> Good to know: Meetings, on the townhall page, lists the last eight townhalls and the next four. A townhall nobody attended is recorded as not held and counts nobody absent. **This townhall did not happen** does the same for a past one (its absences and alerts are cleared, and a lockout it caused is lifted). **Cancel this townhall** on an upcoming one sends no reminders for it; **Put it back on** undoes that.

> Good to know: Each renter and lead shows an Intent card (hot, warm or cold, with the budget, car, length, dates, urgency, delivery and coverage they mentioned). The live map shows it on each pin. An AI reading fills the gaps within the free daily allowance only (Program settings, intent_ai_enabled).

> Good to know: Investors see Search traction under the deck: Google clicks and impressions of the last 28 days, indexed pages and the weekly trend. Type the indexed pages from Search Console on the investor deck page under Investors (no API exists for it).

## Company statements

**Money** > **Company**, the **Monthly statements** tab: CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")

### Fees taken from the revenue statement
On an owner''s page, the **Fees** button sets **How fees are paid**: **Bank debit** (the default) or **Take from revenue statement**. Taken from the statement, the owner''s invoices (not the upfront one) are not debited: the next owner statement pays each one from the payout, as far as it goes, with the line "Invoice INV-..., paid from statement". Approved, the invoice reads **Paid from statement**, or part paid with the rest on the next statement. An invoice still owing 2 months after its billing date goes back to the bank debit after the usual notice, and you get the task **Invoice ... back to the bank debit**.

### The flat-rate agreements
An owner whose every car is on a flat monthly payment signs the **Flat-Rate Vehicle Enrollment Agreement** instead of the standard one (the Title-Holding and Lease Agreement and Forms A to D are the same). The owner''s page says which set applies. When the pay model changes, the signed Enrollment Agreement ends and the owner signs the new one in the owner portal; changed back before signing, the signed one is in force again. The lawyer approved the flat-rate set: Program settings > **Flat-rate agreements awaiting lawyer OK** is off, and is turned on only to mark a new text still under review. Owners can sign either way.

## How it''s paid: bank debit or deducted from payouts

Every owner invoice is paid one of two ways: **Bank debit on the 15th**, or **Deduct from payouts** (taken from the owner''s monthly payouts until paid, never debited).

1. On an invoice, **How it''s paid**, **Change**. A draft changed to Deduct from payouts is issued without the debit email.
2. Each monthly statement deducts as much as the payout allows and shows it to the owner as a deduction; the rest waits for the next statement. The invoice screen shows what was deducted and what is left.
3. For the first and last month, choose **Deduct from payouts** on the Terms tab (or at approval).
4. On the Terms tab, **Charge the agreed one-off fees** makes one invoice for a car from the one-off fees agreed on the owner''s terms (all, or the ones you name), deducted from payouts or debited.

## Referral links between owners (release 28)

When one owner referred another, open the referrer''s **Terms** tab, **Referral links**, **This owner referred another owner**: choose the owner referred and the share in basis points (1000 = 10 points of the revenue the management fee is taken from). Set the referred owner''s own fee on their Terms as usual (for example a 40% management fee and $350 a month per car). Every statement of the referrer then has a **Referral share** line per referred car; it is paid from CarmaCars'' share, never the referred owner''s payout. With **sees the cars** on, the referrer finds **Cars you referred** in their owner portal: bookings, use and revenue, read only, without the other owner''s details. **End** stops the link; shares already earned are still paid.

## Statement periods (release 35)

Statements run from the 8th of one month to the 7th of the next, and the payout on the 10th covers them. A rental that crosses the cutoff, or a long weekly or biweekly rental, is paid for the days inside each period, never twice. Each statement lists amounts still uncollected from the renter separately; they are paid on the statement after they are collected.', 'Owner money', 'Owner invoices (drafts, void and reissue, credit notes), the automatic debit, statements, payouts and the company statement.',
  'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner money**, the **Invoices** tab. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Already paid outside the platform** on the invoice: choose how (e-Transfer, cash, cheque, bank transfer or card outside the platform), the date and the reference. A draft is issued without the invoice email first, the payment is recorded, and the owner gets no email unless you tick **Email the owner a receipt**. To record a smaller or extra payment, press **Record payment**. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for payments the bank sends back and owners with no bank debit set up.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each owner''s bank debit. Use **Pause**, **Resume**, **Send a notice now** or, with no bank debit set up, **Send the sign-up link**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task. Any debit missed (returned for another reason, too late to retry, or a retry still waiting) comes off the owner''s next revenue statement by itself: when the statement is built, the invoice goes in arrears (a waiting retry is cancelled) and the statement deducts it. Nothing to do.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no bank debit set up gets an email on the notice day and you get a task; nothing is debited for them.

## Before the debit day: the Debit preview

The top of the Debits tab shows the coming debit day.

1. **Debit preview** lists each owner with something to debit: the total, whether a bank debit is set up, whether the notice went, and each invoice in one line: the amount, the car, the fee (monthly fee, first and last month, tracker install, adjustment, late fee), the period and how it was worked out, such as "prorated: 20 of 30 days". The line opens the invoice.
2. Something looks wrong? Press **Hold** beside the owner and give the reason. Nothing is debited for that owner until you press **Resume**.
3. **Fee check** compares the month''s invoices with each car''s signed terms: no monthly fee on a flat monthly payment, a Turo-Only car, a shareholder''s car or a company car, nothing before the Enrollment Date, and the amount the terms give. It changes nothing: void and reissue an invoice that does not match. Each production deploy prints the same check.

## When a debit can''t go ahead

You get one email: "Can''t collect $X from the owner: the reason". The reasons are the words of the owner guide: no bank debit set up, owner cancelled the debit at their bank, amount went up after the notice, the bank sent the payment back. The email lists each amount in one line and has one button that fixes it.

1. **Send the sign-up link** opens the Debits tab on that owner. Press **Send the sign-up link** again there: the owner gets the email to set up their bank debit.
2. **Send a new notice** opens the same place with **Send a new notice** for the new amount.
3. **Open the invoice** opens the invoice to record a payment made another way.

## Owner statements

**Money** > **Owner money**, the **Statements** tab

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/2eedf660-50ce-4bd9-86d6-01bbe149c000; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Company**, the **Commissions** tab. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.
5. **Owner requests** lists the commission each salesperson asks for an owner they brought in: a flat amount, or a percent of the company''s share or of the cars'' rental revenue, for a number of months or for as long as the car is with us. Press **Approve**, **Change and approve** (your terms, with a note) or **Decline**. Nothing accrues before you approve. A flat amount is earned at the owner''s first paid rental, once; a percent on each paid rental of the owner''s cars in the time approved. Each then comes to the list above for approval.
6. Who sourced an owner: the owner''s page, **Sourced by**. Only an Admin changes it, with a reason. A waiting request of the person before is withdrawn; an approved one, with what it has not paid yet, goes to the new person.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| An owner a salesperson brought in | The request you approved. A CarmaCars expense, never deducted before Owner Revenue; none on CarmaCars'', a partner''s or a shareholder''s cars |
| Field staff | 10% (also the field referral fee). Customer service, Fleet and Finance staff get no sales credit or commission, ever: their help is credited as Helped by on the booking and on their scorecard |
| Base | The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Field pay

**Money** > **Company**, the **Field pay** tab. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.

:::flow
Clocked in and out | Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out
Pay run started | Hours times the hourly rate, plus the approved commissions
Approved | The figures are frozen, the period''s hours are locked, the statements are numbered
Paid | You recorded how each person was paid; they get their statement by email
:::

1. The tab **Pay run** shows the current two-week period (Sunday to Saturday: the first day is Settings > Program, Field pay). **Earlier period** and **Later period** move between periods.
2. After the period ends, press **Start the payroll**: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). **Refresh the figures** takes in a change made since.
3. Press **Approve**. The period''s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under **Hours** first. **Withdraw** takes an approved run back while no payment is recorded.
4. Press **Record payment** on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email (**Send again** repeats it). The statement''s number opens its PDF; **CSV** gives the run for your accountant.
5. **Hours** lists everyone''s shifts of the period. **Add hours** enters a shift for someone who forgot to clock in, **Change** fixes one and **Remove** takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.
6. **Hourly rates** shows each person''s rate: CA$18.00 an hour unless you give them their own with **Set the rate** (a reason is needed). A pay run keeps the rate it was started with.

|  | Field pay |
| --- | --- |
| Overtime | Off. Settings > Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate |
| Vacation pay | Off. Settings > Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement |
| Deductions | None are worked out: income tax, CPP, EI and the employer''s contributions are for your accountant. Each statement says so |
| Commissions that net to nothing | A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next |

> Tip: A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.

## Company model

Money > **Company model** is the CarmaCars model workbook, live: the actuals, the forecast and the pro forma on one page. Admins only (not Finance). Never share it: investors have their own sheets in the investor portal.

1. **Forecast**: the latest actual month, the EBITDA break-even month, the next 12 months'' EBITDA and the lowest cash, a chart of EBITDA and cash, and 36 months marked A (actual) or F (forecast): cars, utilization, revenue per rented day, revenue, costs, EBITDA, investor returns, tax and cash.
2. **Actuals**: filled in by themselves every hour from the bookings, payments, payouts, expenses and investments. Rental earned is spread over each rental''s days (before HST, insurer-billed and renter-billed apart, placeholders left out), with fees by kind, cash received by method, rentals and rented days, owner and partner shares, commissions, kickbacks, expenses by category and investor payouts. **Refresh actuals now** recomputes them at once.
3. **Pro forma 5 years**: each year''s income statement, cash flow and key figures.
4. **Assumptions**: growth, the utilization ramp, rates, monthly costs, hires, planned capital raises, the fleet insurance premium and tax. Press **Save the assumptions**; the forecast, the pro forma and the download use them at once. A field marked "From the actuals" left blank uses the latest complete month.
5. **Download as Excel**: the full internal workbook with live formulas and the current actuals.

> Tip: Enter the fleet insurance premium under Assumptions; until then it counts as $0 and profit is overstated. Enter each month''s costs in Money > Expenses: a cost line with nothing entered for an actual month uses the assumption, marked est.

## Payroll for everyone (release 35)

**Money** > **Payroll** is one run every two weeks for the field staff (hours) and for customer service, Fleet and Finance (salary).

1. A salaried person is paid their monthly salary x 12 / 26, for the days they were employed in the period. The salary is their own (**Set the salary**, with a reason), else the monthly pay they were hired at, else their role''s (Program settings, va_salary_defaults), in US dollars unless set otherwise.
2. Finance prepares it: **Start the payroll**, **Add a bonus or deduction** with the reason, then **Send for approval**. You get an alert.
3. You press **Approve**, then **Record all payments** (one method and reference; each stub number is added to it) or **Record payment** line by line. Each person gets their stub by email and in their portal.

> Tip: Admin > Team also has **Schedules** (each role''s days and hours, anyone''s own, who is late today) and **KPIs** (every staff member''s KPIs for a week against the targets in Program settings).

> Good to know: The townhall page: pick the craziest story, enter the week''s social media figures, add the recording link, and mark anyone present or absent. Staff who miss two townhalls in a row are locked until you press **Unlock** on the staff list.

> Good to know: Meetings, on the townhall page, lists the last eight townhalls and the next four. A townhall nobody attended is recorded as not held and counts nobody absent. **This townhall did not happen** does the same for a past one (its absences and alerts are cleared, and a lockout it caused is lifted). **Cancel this townhall** on an upcoming one sends no reminders for it; **Put it back on** undoes that.

> Good to know: Each renter and lead shows an Intent card (hot, warm or cold, with the budget, car, length, dates, urgency, delivery and coverage they mentioned). The live map shows it on each pin. An AI reading fills the gaps within the free daily allowance only (Program settings, intent_ai_enabled).

> Good to know: Investors see Search traction under the deck: Google clicks and impressions of the last 28 days, indexed pages and the weekly trend. Type the indexed pages from Search Console on the investor deck page under Investors (no API exists for it).

## Company statements

**Money** > **Company**, the **Monthly statements** tab: CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")

### Fees taken from the revenue statement
On an owner''s page, the **Fees** button sets **How fees are paid**: **Bank debit** (the default) or **Take from revenue statement**. Taken from the statement, the owner''s invoices (not the upfront one) are not debited: the next owner statement pays each one from the payout, as far as it goes, with the line "Invoice INV-..., paid from statement". Approved, the invoice reads **Paid from statement**, or part paid with the rest on the next statement. An invoice still owing 2 months after its billing date goes back to the bank debit after the usual notice, and you get the task **Invoice ... back to the bank debit**.

### The flat-rate agreements
An owner whose every car is on a flat monthly payment signs the **Flat-Rate Vehicle Enrollment Agreement** instead of the standard one (the Title-Holding and Lease Agreement and Forms A to D are the same). The owner''s page says which set applies. When the pay model changes, the signed Enrollment Agreement ends and the owner signs the new one in the owner portal; changed back before signing, the signed one is in force again. The lawyer approved the flat-rate set: Program settings > **Flat-rate agreements awaiting lawyer OK** is off, and is turned on only to mark a new text still under review. Owners can sign either way.

## How it''s paid: bank debit or deducted from payouts

Every owner invoice is paid one of two ways: **Bank debit on the 15th**, or **Deduct from payouts** (taken from the owner''s monthly payouts until paid, never debited).

1. On an invoice, **How it''s paid**, **Change**. A draft changed to Deduct from payouts is issued without the debit email.
2. Each monthly statement deducts as much as the payout allows and shows it to the owner as a deduction; the rest waits for the next statement. The invoice screen shows what was deducted and what is left.
3. For the first and last month, choose **Deduct from payouts** on the Terms tab (or at approval).
4. On the Terms tab, **Charge the agreed one-off fees** makes one invoice for a car from the one-off fees agreed on the owner''s terms (all, or the ones you name), deducted from payouts or debited.

## Referral links between owners (release 28)

When one owner referred another, open the referrer''s **Terms** tab, **Referral links**, **This owner referred another owner**: choose the owner referred and the share in basis points (1000 = 10 points of the revenue the management fee is taken from). Set the referred owner''s own fee on their Terms as usual (for example a 40% management fee and $350 a month per car). Every statement of the referrer then has a **Referral share** line per referred car; it is paid from CarmaCars'' share, never the referred owner''s payout. With **sees the cars** on, the referrer finds **Cars you referred** in their owner portal: bookings, use and revenue, read only, without the other owner''s details. **End** stops the link; shares already earned are still paid.

## Statement periods (release 35)

Statements run from the 8th of one month to the 7th of the next, and the payout on the 10th covers them. A rental that crosses the cutoff, or a long weekly or biweekly rental, is paid for the days inside each period, never twice. Each statement lists amounts still uncollected from the renter separately; they are paid on the statement after they are collected.

## The owner forecast (release 48)

Each owner sees a **Forecast** on their Home: the next 12 months of each car, projected occupancy and projected owner revenue (before fees). Open an owner in **Owners**: the **Overview** shows the same **Forecast**.

1. Every car starts from the GTA seasonal curve: **Settings** > **Program settings**, **Owner forecast: the GTA seasonal curve** (a factor for each month, jan to dec, 1.00 is an average month) and **Owner forecast: the occupancy of an average month** (60% by default). A month''s curve is the average month times its factor.
2. Once a car has 3 full months on the program, its own occupancy is blended in: its own level (each month''s occupancy divided by that month''s factor) times the month''s factor, weighted half after 3 months, two thirds after 6, four fifths after 12. The season always stays in.
3. Bookings hidden from the owner (an insurer replacement hidden from them, or one never shown), test bookings and the owner''s own trips are not counted.
4. Projected owner revenue: occupancy times the days of the month times the car''s owner revenue per booked day, from its own statements of the last 12 months, else its daily rate less the Revenue Share.

Every owner statement (the owner''s page, yours and the PDF) has a **Forecast** line: next month against the statement''s month, higher or lower, by how many points and about how much owner revenue, and why (the season).

> Tip: Change a factor when the season moves (a big event, a new airport route): every owner''s forecast follows on their next visit.',
  '<p class="gd-p">Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.</p><section class="gd-task" id="owner-money-owner-invoices" data-gd-task><h2 class="gd-h2">Owner invoices</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner money</b>, the <b class="gd-ui">Invoices</b> tab. Every owner invoice, drafts and voids included. The same list is on each owner&#39;s and each application&#39;s Invoices tab.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">New invoice</b> makes an invoice of any amount for an owner&#39;s car, for example a registration fee of $123.45.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The monthly run and tracker invoices: <b class="gd-ui">Run the monthly invoices</b> issues the invoices for the 15th by hand, for a missed month (never twice); <b class="gd-ui">Issue all tracker invoices</b> bills the Tracker Install for each car waiting for its tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/invoices</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:83.3%;top:22.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:41.7%;top:35.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:29%;top:43.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owner-money-make-edit-and-issue-an-invoice" data-gd-task><h2 class="gd-h2">Make, edit and issue an invoice</h2><p class="gd-p">A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. <b class="gd-ui">Add a line</b> for more.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Save as draft</b> to come back to it, or <b class="gd-ui">Save and issue</b> to send it now. On a draft&#39;s page, <b class="gd-ui">Issue and email</b> sends it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid another way? Press <b class="gd-ui">Already paid outside the platform</b> on the invoice: choose how (e-Transfer, cash, cheque, bank transfer or card outside the platform), the date and the reference. A draft is issued without the invoice email first, the payment is recorded, and the owner gets no email unless you tick <b class="gd-ui">Email the owner a receipt</b>. To record a smaller or extra payment, press <b class="gd-ui">Record payment</b>. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Resend email</b> sends the invoice again. <b class="gd-ui">PDF</b> opens it as a PDF.</div></li></ol></div></section><section class="gd-task" id="owner-money-correct-an-issued-invoice" data-gd-task><h2 class="gd-h2">Correct an issued invoice</h2><p class="gd-p">An issued invoice is never edited. You void it and issue a corrected one.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Void</b>, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press <b class="gd-ui">Void the invoice</b>. Its scheduled debit is cancelled and the owner is told.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The corrected invoice opens as a draft with the same lines. Fix the amounts and press <b class="gd-ui">Save and issue</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Already paid? Void the payment first, or press <b class="gd-ui">Credit note</b> for the amount to give back: it gets its own number and the owner sees it.</div></li></ol></div><p class="gd-p">Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.</p></section><section class="gd-task" id="owner-money-the-automatic-debit" data-gd-task><h2 class="gd-h2">The automatic debit</h2><p class="gd-p">The debit runs by itself. Your job is to watch for payments the bank sends back and owners with no bank debit set up.</p><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>Invoices issued, one notice per owner, 10 days before</em></li><li><b>2</b><span>Debit day</span><em>The 15th from 6:00: one debit per invoice</em></li><li><b>3</b><span>Cleared</span><em>The invoice is paid</em></li><li><b>4</b><span>Returned, insufficient funds</span><em>The $50.00 Late Fee is added once; the same amount is tried again within 30 days</em></li><li><b>5</b><span>Returned for another reason</span><em>No retry and no Late Fee: the debit pauses and you get a task</em></li></ol><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">How it runs explains the policy in words, read from Program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Scheduled and processing lists each debit. <b class="gd-ui">Pause</b> holds one (a reason is needed).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owners lists each owner&#39;s bank debit. Use <b class="gd-ui">Pause</b>, <b class="gd-ui">Resume</b>, <b class="gd-ui">Send a notice now</b> or, with no bank debit set up, <b class="gd-ui">Send the sign-up link</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/920"><img src="/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="920"><span class="gd-pin" style="left:21.8%;top:21.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:21.5%;top:35.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.5%;top:75.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:84.7%;top:94.7%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Results: each debit, cleared or returned, with the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Run log: each notice and debit run, with its counts.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Notices sent: who was told what, for which debit day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/520"><img src="/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="520"><span class="gd-pin" style="left:11%;top:14.4%" aria-hidden="true">5</span><span class="gd-pin" style="left:10.2%;top:52.3%" aria-hidden="true">6</span><span class="gd-pin" style="left:15.4%;top:89.8%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner&#39;s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task. Any debit missed (returned for another reason, too late to retry, or a retry still waiting) comes off the owner&#39;s next revenue statement by itself: when the statement is built, the invoice goes in arrears (a waiting retry is cancelled) and the statement deducts it. Nothing to do.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner&#39;s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no bank debit set up gets an email on the notice day and you get a task; nothing is debited for them.</div></aside></section><section class="gd-task" id="owner-money-before-the-debit-day-the-debit-preview" data-gd-task><h2 class="gd-h2">Before the debit day: the Debit preview</h2><p class="gd-p">The top of the Debits tab shows the coming debit day.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Debit preview</b> lists each owner with something to debit: the total, whether a bank debit is set up, whether the notice went, and each invoice in one line: the amount, the car, the fee (monthly fee, first and last month, tracker install, adjustment, late fee), the period and how it was worked out, such as &quot;prorated: 20 of 30 days&quot;. The line opens the invoice.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Something looks wrong? Press <b class="gd-ui">Hold</b> beside the owner and give the reason. Nothing is debited for that owner until you press <b class="gd-ui">Resume</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Fee check</b> compares the month&#39;s invoices with each car&#39;s signed terms: no monthly fee on a flat monthly payment, a Turo-Only car, a shareholder&#39;s car or a company car, nothing before the Enrollment Date, and the amount the terms give. It changes nothing: void and reissue an invoice that does not match. Each production deploy prints the same check.</div></li></ol></div></section><section class="gd-task" id="owner-money-when-a-debit-can-t-go-ahead" data-gd-task><h2 class="gd-h2">When a debit can&#39;t go ahead</h2><p class="gd-p">You get one email: &quot;Can&#39;t collect $X from the owner: the reason&quot;. The reasons are the words of the owner guide: no bank debit set up, owner cancelled the debit at their bank, amount went up after the notice, the bank sent the payment back. The email lists each amount in one line and has one button that fixes it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Send the sign-up link</b> opens the Debits tab on that owner. Press <b class="gd-ui">Send the sign-up link</b> again there: the owner gets the email to set up their bank debit.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Send a new notice</b> opens the same place with <b class="gd-ui">Send a new notice</b> for the new amount.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Open the invoice</b> opens the invoice to record a payment made another way.</div></li></ol></div></section><section class="gd-task" id="owner-money-owner-statements" data-gd-task><h2 class="gd-h2">Owner statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner money</b>, the <b class="gd-ui">Statements</b> tab</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Build all for a month</b> (or <b class="gd-ui">Build one</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open each draft. Check it, <b class="gd-ui">Rebuild</b> after a correction, <b class="gd-ui">Preview PDF</b>, then <b class="gd-ui">Approve</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Issue to the owner</b>. <b class="gd-ui">Reissue</b> sends a corrected copy; <b class="gd-ui">CSV</b> exports it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/400"><img src="/guides/img/admin-16-statements-desktop-43a313ea.jpg" alt="" loading="lazy" decoding="async" width="1440" height="400"><span class="gd-pin" style="left:79.9%;top:27.3%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements/2eedf660-50ce-4bd9-86d6-01bbe149c000</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/520"><img src="/guides/img/admin-17-statement-desktop-106ee57f.jpg" alt="An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts." loading="lazy" decoding="async" width="1440" height="520"><span class="gd-pin" style="left:86%;top:22.7%" aria-hidden="true">3</span></div></div><figcaption>An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.</figcaption></figure></div></section><section class="gd-task" id="owner-money-staff-commissions" data-gd-task><h2 class="gd-h2">Staff commissions</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Company</b>, the <b class="gd-ui">Commissions</b> tab. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Not earned yet</span><em>The rental is ahead, or not paid in full</em></li><li><b>2</b><span>Pending approval</span><em>Completed and paid in full; a Sales month once it has ended</em></li><li><b>3</b><span>Approved</span><em>You approved it; the staff member is told</em></li><li><b>4</b><span>Paid</span><em>You recorded the payment; the staff member is told</em></li><li><b>5</b><span>Reversed</span><em>Cancelled, refunded or charged back; after payment it comes off the next payment</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">By person shows each staff member&#39;s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b> on a person (everything that may be approved now) or on one commission.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record a payment</b>: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Prices to review</b> lists prices typed by hand; <b class="gd-ui">Sourcing claims</b> lists staff who say they sourced a website request; <b class="gd-ui">Payments made</b> lists each payment.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Owner requests</b> lists the commission each salesperson asks for an owner they brought in: a flat amount, or a percent of the company&#39;s share or of the cars&#39; rental revenue, for a number of months or for as long as the car is with us. Press <b class="gd-ui">Approve</b>, <b class="gd-ui">Change and approve</b> (your terms, with a note) or <b class="gd-ui">Decline</b>. Nothing accrues before you approve. A flat amount is earned at the owner&#39;s first paid rental, once; a percent on each paid rental of the owner&#39;s cars in the time approved. Each then comes to the list above for approval.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Who sourced an owner: the owner&#39;s page, <b class="gd-ui">Sourced by</b>. Only an Admin changes it, with a reason. A waiting request of the person before is withdrawn; an approved one, with what it has not paid yet, goes to the new person.</div></li></ol></div><div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month&#39;s rentals</td></tr><tr><td>An owner a salesperson brought in</td><td>The request you approved. A CarmaCars expense, never deducted before Owner Revenue; none on CarmaCars&#39;, a partner&#39;s or a shareholder&#39;s cars</td></tr><tr><td>Field staff</td><td>10% (also the field referral fee). Customer service, Fleet and Finance staff get no sales credit or commission, ever: their help is credited as Helped by on the booking and on their scorecard</td></tr><tr><td>Base</td><td>The rental charge before tax, after discounts, with late extra days; never delivery, kilometres, add-ons or anything else bought. Only a refund of the rental charge comes off</td></tr><tr><td>On the owner statement</td><td>An owner&#39;s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner&#39;s car: from CarmaCars&#39; commission. A CarmaCars-owned car: a CarmaCars expense</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A commission that changes after an owner statement was built (a refund, or the month&#39;s Sales tier) goes on the owner&#39;s next statement as an adjustment line.</div></aside></section><section class="gd-task" id="owner-money-field-pay" data-gd-task><h2 class="gd-h2">Field pay</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Company</b>, the <b class="gd-ui">Field pay</b> tab. Field staff clock in and out on their phones (My hours); you run the pay every two weeks. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Clocked in and out</span><em>Field staff press Clock in and Clock out; Fleet or you fix a forgotten clock-out</em></li><li><b>2</b><span>Pay run started</span><em>Hours times the hourly rate, plus the approved commissions</em></li><li><b>3</b><span>Approved</span><em>The figures are frozen, the period&#39;s hours are locked, the statements are numbered</em></li><li><b>4</b><span>Paid</span><em>You recorded how each person was paid; they get their statement by email</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tab <b class="gd-ui">Pay run</b> shows the current two-week period (Sunday to Saturday: the first day is Settings &gt; Program, Field pay). <b class="gd-ui">Earlier period</b> and <b class="gd-ui">Later period</b> move between periods.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">After the period ends, press <b class="gd-ui">Start the payroll</b>: one line for each person with hours times their hourly rate, plus the staff commissions and referral fees approved by the end of the period (see Staff commissions). <b class="gd-ui">Refresh the figures</b> takes in a change made since.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The period&#39;s hours are locked, each line gets a statement number and the figures are frozen. Someone still clocked in blocks it: fix their shift under <b class="gd-ui">Hours</b> first. <b class="gd-ui">Withdraw</b> takes an approved run back while no payment is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record payment</b> on a line: choose e-Transfer, bank transfer or cash, the reference (not needed for cash) and the date. The commissions in the line are marked paid and the person gets their pay statement by email (<b class="gd-ui">Send again</b> repeats it). The statement&#39;s number opens its PDF; <b class="gd-ui">CSV</b> gives the run for your accountant.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Hours</b> lists everyone&#39;s shifts of the period. <b class="gd-ui">Add hours</b> enters a shift for someone who forgot to clock in, <b class="gd-ui">Change</b> fixes one and <b class="gd-ui">Remove</b> takes one out. Each needs a reason and is kept in a log. Fleet does the same under Field hours but sees no pay.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Hourly rates</b> shows each person&#39;s rate: CA$18.00 an hour unless you give them their own with <b class="gd-ui">Set the rate</b> (a reason is needed). A pay run keeps the rate it was started with.</div></li></ol></div><div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Field pay</th></tr></thead><tbody><tr><td>Overtime</td><td>Off. Settings &gt; Program, Field pay: pay overtime, after 44 hours in a week, at 150% of the rate</td></tr><tr><td>Vacation pay</td><td>Off. Settings &gt; Program, Field pay: vacation pay (Ontario: 4%) adds that share of wages, overtime and commissions to each statement</td></tr><tr><td>Deductions</td><td>None are worked out: income tax, CPP, EI and the employer&#39;s contributions are for your accountant. Each statement says so</td></tr><tr><td>Commissions that net to nothing</td><td>A person whose approved commissions add up to nothing or less (a clawback) is not paid them this period: they carry to the next</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A shift of more than 16 hours (a setting) is refused, and so are hours that overlap another shift of the same person. The field staff member sees their hours and statements under My hours on their phone.</div></aside></section><section class="gd-task" id="owner-money-company-model" data-gd-task><h2 class="gd-h2">Company model</h2><p class="gd-p">Money &gt; <b class="gd-ui">Company model</b> is the CarmaCars model workbook, live: the actuals, the forecast and the pro forma on one page. Admins only (not Finance). Never share it: investors have their own sheets in the investor portal.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Forecast</b>: the latest actual month, the EBITDA break-even month, the next 12 months&#39; EBITDA and the lowest cash, a chart of EBITDA and cash, and 36 months marked A (actual) or F (forecast): cars, utilization, revenue per rented day, revenue, costs, EBITDA, investor returns, tax and cash.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Actuals</b>: filled in by themselves every hour from the bookings, payments, payouts, expenses and investments. Rental earned is spread over each rental&#39;s days (before HST, insurer-billed and renter-billed apart, placeholders left out), with fees by kind, cash received by method, rentals and rented days, owner and partner shares, commissions, kickbacks, expenses by category and investor payouts. <b class="gd-ui">Refresh actuals now</b> recomputes them at once.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Pro forma 5 years</b>: each year&#39;s income statement, cash flow and key figures.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Assumptions</b>: growth, the utilization ramp, rates, monthly costs, hires, planned capital raises, the fleet insurance premium and tax. Press <b class="gd-ui">Save the assumptions</b>; the forecast, the pro forma and the download use them at once. A field marked &quot;From the actuals&quot; left blank uses the latest complete month.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Download as Excel</b>: the full internal workbook with live formulas and the current actuals.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Enter the fleet insurance premium under Assumptions; until then it counts as $0 and profit is overstated. Enter each month&#39;s costs in Money &gt; Expenses: a cost line with nothing entered for an actual month uses the assumption, marked est.</div></aside></section><section class="gd-task" id="owner-money-payroll-for-everyone-release-35" data-gd-task><h2 class="gd-h2">Payroll for everyone (release 35)</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Payroll</b> is one run every two weeks for the field staff (hours) and for customer service, Fleet and Finance (salary).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A salaried person is paid their monthly salary x 12 / 26, for the days they were employed in the period. The salary is their own (<b class="gd-ui">Set the salary</b>, with a reason), else the monthly pay they were hired at, else their role&#39;s (Program settings, va_salary_defaults), in US dollars unless set otherwise.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Finance prepares it: <b class="gd-ui">Start the payroll</b>, <b class="gd-ui">Add a bonus or deduction</b> with the reason, then <b class="gd-ui">Send for approval</b>. You get an alert.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">You press <b class="gd-ui">Approve</b>, then <b class="gd-ui">Record all payments</b> (one method and reference; each stub number is added to it) or <b class="gd-ui">Record payment</b> line by line. Each person gets their stub by email and in their portal.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Admin &gt; Team also has <b class="gd-ui">Schedules</b> (each role&#39;s days and hours, anyone&#39;s own, who is late today) and <b class="gd-ui">KPIs</b> (every staff member&#39;s KPIs for a week against the targets in Program settings).</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>The townhall page: pick the craziest story, enter the week&#39;s social media figures, add the recording link, and mark anyone present or absent. Staff who miss two townhalls in a row are locked until you press <b class="gd-ui">Unlock</b> on the staff list.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Meetings, on the townhall page, lists the last eight townhalls and the next four. A townhall nobody attended is recorded as not held and counts nobody absent. <b class="gd-ui">This townhall did not happen</b> does the same for a past one (its absences and alerts are cleared, and a lockout it caused is lifted). <b class="gd-ui">Cancel this townhall</b> on an upcoming one sends no reminders for it; <b class="gd-ui">Put it back on</b> undoes that.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each renter and lead shows an Intent card (hot, warm or cold, with the budget, car, length, dates, urgency, delivery and coverage they mentioned). The live map shows it on each pin. An AI reading fills the gaps within the free daily allowance only (Program settings, intent_ai_enabled).</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Investors see Search traction under the deck: Google clicks and impressions of the last 28 days, indexed pages and the weekly trend. Type the indexed pages from Search Console on the investor deck page under Investors (no API exists for it).</div></aside></section><section class="gd-task" id="owner-money-company-statements" data-gd-task><h2 class="gd-h2">Company statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Company</b>, the <b class="gd-ui">Monthly statements</b> tab: CarmaCars&#39; own monthly statement, in twelve sections.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between Total, Per owner and Per vehicle.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Download <b class="gd-ui">PDF</b>, <b class="gd-ui">PDF by owner</b> or <b class="gd-ui">PDF by vehicle</b>, or press <b class="gd-ui">Email me the PDFs</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Finalize</b> freezes the month. <b class="gd-ui">Rebuild</b> works until then.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/reports</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:20.8%;top:28%" aria-hidden="true">1</span><span class="gd-pin" style="left:19.4%;top:59.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.1%;top:15.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:46.9%;top:15.5%" aria-hidden="true">4</span></div></div></figure></div><h3 class="gd-h3">Fees taken from the revenue statement</h3><p class="gd-p">On an owner&#39;s page, the <b class="gd-ui">Fees</b> button sets <b class="gd-ui">How fees are paid</b>: <b class="gd-ui">Bank debit</b> (the default) or <b class="gd-ui">Take from revenue statement</b>. Taken from the statement, the owner&#39;s invoices (not the upfront one) are not debited: the next owner statement pays each one from the payout, as far as it goes, with the line &quot;Invoice INV-..., paid from statement&quot;. Approved, the invoice reads <b class="gd-ui">Paid from statement</b>, or part paid with the rest on the next statement. An invoice still owing 2 months after its billing date goes back to the bank debit after the usual notice, and you get the task <b class="gd-ui">Invoice ... back to the bank debit</b>.</p><h3 class="gd-h3">The flat-rate agreements</h3><p class="gd-p">An owner whose every car is on a flat monthly payment signs the <b class="gd-ui">Flat-Rate Vehicle Enrollment Agreement</b> instead of the standard one (the Title-Holding and Lease Agreement and Forms A to D are the same). The owner&#39;s page says which set applies. When the pay model changes, the signed Enrollment Agreement ends and the owner signs the new one in the owner portal; changed back before signing, the signed one is in force again. The lawyer approved the flat-rate set: Program settings &gt; <b class="gd-ui">Flat-rate agreements awaiting lawyer OK</b> is off, and is turned on only to mark a new text still under review. Owners can sign either way.</p></section><section class="gd-task" id="owner-money-how-it-s-paid-bank-debit-or-deducted-from-payouts" data-gd-task><h2 class="gd-h2">How it&#39;s paid: bank debit or deducted from payouts</h2><p class="gd-p">Every owner invoice is paid one of two ways: <b class="gd-ui">Bank debit on the 15th</b>, or <b class="gd-ui">Deduct from payouts</b> (taken from the owner&#39;s monthly payouts until paid, never debited).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">On an invoice, <b class="gd-ui">How it&#39;s paid</b>, <b class="gd-ui">Change</b>. A draft changed to Deduct from payouts is issued without the debit email.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each monthly statement deducts as much as the payout allows and shows it to the owner as a deduction; the rest waits for the next statement. The invoice screen shows what was deducted and what is left.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">For the first and last month, choose <b class="gd-ui">Deduct from payouts</b> on the Terms tab (or at approval).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On the Terms tab, <b class="gd-ui">Charge the agreed one-off fees</b> makes one invoice for a car from the one-off fees agreed on the owner&#39;s terms (all, or the ones you name), deducted from payouts or debited.</div></li></ol></div></section><section class="gd-task" id="owner-money-referral-links-between-owners-release-28" data-gd-task><h2 class="gd-h2">Referral links between owners (release 28)</h2><p class="gd-p">When one owner referred another, open the referrer&#39;s <b class="gd-ui">Terms</b> tab, <b class="gd-ui">Referral links</b>, <b class="gd-ui">This owner referred another owner</b>: choose the owner referred and the share in basis points (1000 = 10 points of the revenue the management fee is taken from). Set the referred owner&#39;s own fee on their Terms as usual (for example a 40% management fee and $350 a month per car). Every statement of the referrer then has a <b class="gd-ui">Referral share</b> line per referred car; it is paid from CarmaCars&#39; share, never the referred owner&#39;s payout. With <b class="gd-ui">sees the cars</b> on, the referrer finds <b class="gd-ui">Cars you referred</b> in their owner portal: bookings, use and revenue, read only, without the other owner&#39;s details. <b class="gd-ui">End</b> stops the link; shares already earned are still paid.</p></section><section class="gd-task" id="owner-money-statement-periods-release-35" data-gd-task><h2 class="gd-h2">Statement periods (release 35)</h2><p class="gd-p">Statements run from the 8th of one month to the 7th of the next, and the payout on the 10th covers them. A rental that crosses the cutoff, or a long weekly or biweekly rental, is paid for the days inside each period, never twice. Each statement lists amounts still uncollected from the renter separately; they are paid on the statement after they are collected.</p></section><section class="gd-task" id="owner-money-the-owner-forecast-release-48" data-gd-task><h2 class="gd-h2">The owner forecast (release 48)</h2><p class="gd-p">Each owner sees a <b class="gd-ui">Forecast</b> on their Home: the next 12 months of each car, projected occupancy and projected owner revenue (before fees). Open an owner in <b class="gd-ui">Owners</b>: the <b class="gd-ui">Overview</b> shows the same <b class="gd-ui">Forecast</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every car starts from the GTA seasonal curve: <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program settings</b>, <b class="gd-ui">Owner forecast: the GTA seasonal curve</b> (a factor for each month, jan to dec, 1.00 is an average month) and <b class="gd-ui">Owner forecast: the occupancy of an average month</b> (60% by default). A month&#39;s curve is the average month times its factor.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once a car has 3 full months on the program, its own occupancy is blended in: its own level (each month&#39;s occupancy divided by that month&#39;s factor) times the month&#39;s factor, weighted half after 3 months, two thirds after 6, four fifths after 12. The season always stays in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Bookings hidden from the owner (an insurer replacement hidden from them, or one never shown), test bookings and the owner&#39;s own trips are not counted.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Projected owner revenue: occupancy times the days of the month times the car&#39;s owner revenue per booked day, from its own statements of the last 12 months, else its daily rate less the Revenue Share.</div></li></ol></div><p class="gd-p">Every owner statement (the owner&#39;s page, yours and the PDF) has a <b class="gd-ui">Forecast</b> line: next month against the statement&#39;s month, higher or lower, by how many points and about how much owner revenue, and why (the season).</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Change a factor when the season moves (a big event, a new airport route): every owner&#39;s forecast follows on their next visit.</div></aside></section>');
select app.guide_release_section('admin', 'settings', 'chapter', 'search-car-pages-landing-pages-and-guides', 'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, My profile, Staff and roles, Promo codes, Quick replies and Call helper.

**My profile**: the greeting name of this login. To do greets it whole ("Good morning, Abbas and Mahad" on a login the owners share) and the assistant uses it; empty, the first name of the account. Press **Change the greeting name**, type it and save.

## Program settings

1. Buffer between trips (90 minutes): the time held before and after every trip, in every availability and conflict check (requests, offers, date changes, extensions, the calendar). The cleaning block after a trip is this time; Turnaround between trips is the same number. A booking already closer than this is not changed: the calendar rings it.
1. Late fee and extensions (Booking requests and offers): the late fee per started hour (17.5% of the daily rate, at least $25; new bookings and offers only), the extension discounts (no longer applied since release 35: an extension costs the booking''s all-in price a day) and **Approve a renter''s extension at once when nothing needs a person** (on). A car''s own switch is in Fleet, the car, **Edit details**: **Renters extend themselves**.
1. RentalCover (the Protection Plan): whether quotes price the plan once the key is set (on), the markup (on, 20%, no fixed amount), how long a quote is reused, the car value limit ($50,000) and whether a car with no value may have the plan (off).
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%, field staff only: customer service, Fleet and Finance earn none), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-in besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Shifts published by themselves (on): the shift template (one shift of 10:00 to 17:00 for one person, every second day from November 23, 2026), how many days ahead (14) and the first day they may be published for; a handover or return no shift covers gets a shift of its own. Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")


## Lead-time pricing

A car booked at short notice costs a little more and one booked well ahead a little less. Open **Settings**, then **Program settings**: Lead-time pricing is at the top.

1. The switch turns it on or off for every car (on by default).
2. The table holds the tiers: when the pickup is that many hours away, the rental charge changes by that percentage. By default: under 24 hours +15%, 24 to 72 hours +10%, 3 to 13 days 0%, 14 days or more −5%. Type the hours and the percentage on each row (a minus for less); **Add a tier** adds one, **Remove** takes one off. Each row shows what it does to a $500 rental.
3. **Also adjust bookings billed to an insurer** is off by default: an insurer pays its own rate, never a short-notice premium.
4. Press **Save lead-time pricing**. New quotes and requests use it; bookings already made keep theirs.

| What it touches | How |
| --- | --- |
| The rental charge | The percentage of the rental charge only, before tax: one line in the price, "Short-notice pricing +10%" or "Booked ahead −5%". Never the fees, the deposit or add-ons |
| When it is worked out | When the quote is made (the car page, the cars list once dates are chosen, the request), from that moment to the pickup on Toronto clocks. "From $X a day" stays at the base rate |
| When it is locked | On the request: the offer, a change of dates and the payment keep the same percentage |
| Other discounts | The non-refundable discount, a promo code and a staff discount are worked out on the rental charge from the rates, as before, and show beside it |
| Owner revenue and commissions | Count the rental charge after it, as they count the discounts |
| Staff | Change it on a booking under **More options** on the review screen; a price typed by hand replaces it. Rentals added by hand, Owner Bookings and placeholders are not adjusted |

> Tip: A car can turn it off or have its own tiers: **Vehicles** > the car > **Rates** > Lead-time pricing for this car.
## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled; its own text and layout are never changed. A form whose stored PDF is not the publisher''s download (or your upload of it) gives owners the data sheet instead. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Choose **Preview with**: a sample car (made-up values) or one of the cars. Press **Download a filled preview** and check each value against the form. The preview uses the mapping on screen, saved or not.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Write what you changed and press Save the mapping. **Earlier mappings** lists every save, with who and when; **Load** puts one back on screen to preview and save again. Fleet can map the forms too (Owners > Government forms), but only an Admin uploads a form.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record an official form signed in ink**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the rate rows (days, weeks or months @ the rate = the amount; a rental counted by the day, such as 31 days at the monthly rate, shows its daily rate rounded to the cent, and box 14 says how the charge was made), the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST (13% of the subtotal), total and deposit, the deposit received and the day it was taken (before pickup, the amount due at pickup), and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. The boxes filled at check-in and check-out stay blank until then. The fuel gauges are covered and the level of the check-in report (fuel out) and the check-out report (fuel in) is written in words, blank with no reading.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with the day they signed beside box 20 and a signature record page. Each later version (as picked up, as returned, corrected) carries the same signature and day. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, with the e-signature (never on paper).

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Team**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Already sent or signed with old terms? Press **Send a new agreement** beside the person: it is filled with the current terms (for staff who live in Canada: Canada, CAD, Interac e-Transfer or direct deposit) and sent to sign the same way. The one waiting is withdrawn; a signed one stays on file, marked superseded, and keeps their portal open until they sign the new one. Someone in Canada still on the old terms (the Philippines, USD, OnlineJobs.ph) shows **Lives in Canada: needs the Canadian terms**, and a To do lists them.
7. Your own PDF instead? **Send a PDF to sign** still works.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurers**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-out (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-out), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.

### Pair the card reader
**Settings** > **Card reader**. On the Stripe S700, swipe from the left edge, open **Settings**, then **Generate pairing code**. Type the three words in **Pairing code**, name the reader (Front desk) and press **Pair reader**. The first time, a Stripe Terminal location is made from the mailing address in Site settings: write it as street, city, province and postal code. **Remove** takes a reader off the list. Card statements read 18122211 Canada Inc., the Stripe account''s statement descriptor.

### Rewards
**Settings** > **Rewards**. CarmaCars Rewards is on: 1 point per dollar of the rental charge after discounts (never fees, add-ons, coverage, tax or the deposit), 100 points = $1, redeemed from 500 points as a code of the renter''s own, valid 90 days. Points end 12 months after the last rental or redemption, with a reminder email 30 days before.

1. **Ways to earn**: each on or off with its points. Referral (500 to the referrer, 250 to the friend, at the friend''s first completed rental), a follow on Instagram, TikTok or Facebook (50 each, once, granted on the click from the Rewards page, since a follow cannot be checked; a platform shows only with its page in Site settings), a review on carmacars.ca (100, any rating; the review shows "Received reward points"), a Google review (100 a rental, any rating, on the renter''s word: they press I posted my review and give the name on it; hidden until the Google review page is set here), a damage-free rental (200: no damage, claim, cleaning or smoking fee, back on time), the birthday (100) and the first rental (100).
2. **Tiers**: Gold from 1,000 points earned in 12 months, Platinum from 15,000, Black from 60,000 (below Gold a renter is a Member). Points earned count, so using points never lowers a tier. Press **Change** on a tier for its name and points. Tiers give perks, not discounts; tier codes issued before release 40 work until they end.
3. **Perks**: Instant Book (Gold), Any car, any time (Platinum) and a free rental day a year (Black). Each tier keeps the perks below it. **Change** a perk to move it to another tier, reword it or switch it off. **Change the response time** sets how fast Fleet answers an Any car request (4 hours); the open ones are listed with their answer-by time.
4. Points and codes come off the rental charge only and reduce Owner Revenue like any promo code, except the Black tier''s free day: CarmaCars pays for it, and the owner''s payout is worked out on the price before it.
4. **Google reviews claimed** lists every claim; **Reverse** takes the points back with a reason. **A renter''s points**: find the renter, then **Add or take off points** with a reason, or reverse any entry (for example, referral fraud).
5. **Emails and notices to renters**: every Rewards email, each also a notice in the renter''s portal (a text only when they have no email): the welcome, points earned, a new tier, the free day, close to the next tier, points waiting, the 7-day reminder, the free day ending, the monthly statement and the birthday and holiday rewards. Each shows how many went in the last 30 days. **Preview** shows the email with sample values; **Turn off** stops it; **Change** sets the timings or switches them all off. Marketing ones carry an unsubscribe link and never go to someone who unsubscribed.
6. **Birthday and holiday rewards**: a percent off the rental charge by tier for a pickup near the renter''s birthday (7 days either side) or on a holiday weekend: Platinum 10%, Black 20%; Gold is off (0%) until you give it a percent. The bigger one applies, never both, never below the car''s lowest daily price, never on insurer or Owner Bookings. The request or offer keeps it. **Change** a tier for its percents or to switch it off; the holidays are listed with their next weekend: **Turn off**, **Remove** or **Add a holiday** by its date rule.

### Setup checklist
**Settings** shows what still needs a key from one of CarmaCars'' own accounts. **Add to Apple Wallet** stays hidden until the Apple Pass Type ID certificate is added (WALLET_PASS_CERT, WALLET_PASS_KEY, WALLET_WWDR_CERT, WALLET_PASS_TYPE_ID and WALLET_TEAM_ID in the Worker''s secrets); then it shows on every confirmed booking.


Program: **Call and Text buttons go through Quo** (on) makes every Call and Text button use the CarmaCars number in Quo (chapter Texts and calls). Off, they open the device''s own phone and messages apps.

## Stuck? help

**Settings** > **Program settings** > **Stuck? help**: turn it on or off, the minutes on a page without a successful action (3), and the errors (3) before the box offers the guide and the Academy lesson. **Where people get stuck**, on the same page, lists the pages it showed on most in the last 30 days, with how often the guide and the lesson were opened.

### API access (Claude and scripts)

Settings > **API access** connects Claude so you (or Mahad) can run CarmaCars from a Claude chat: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, invoices, staff and hiring ("hire Ana as customer service"). **Connect from Claude**: in Claude, Settings > Connectors > Add custom connector, paste https://carmacars.ca/api/mcp, then sign in to CarmaCars and press **Allow**. Every change is two steps: Claude first shows what will change (nothing is changed yet), and does it only when you agree. Keys and connections made with every scope got the Admin scopes in release 33; a key with fewer scopes keeps them. For Claude Code or a script, **Make a key**: copy it at once, it is shown only once. Each key or connection acts as its Admin, with the scopes chosen; **Revoke** stops it at once. The **Call log** lists every call (the previews too) with the values before and after. The database checks each action exactly as the Admin screens do.

### The logo

The site, every portal, every email and the documents show the brand logo. To use another, upload it under Settings > **Site settings**, the Logo card (PNG or JPEG for emails and documents).

## Deposits stay as holds (release 28)

Every deposit by card is a hold (an authorization) that stays with Stripe: it is never captured by itself, so nothing is paid out and nothing has to be refunded. Capture only what is owed, and release the rest from the booking. The booking''s Security deposit panel shows Hold expires with the date Stripe gives. When a hold nears its expiry while the car is out or tickets can still come in, Finance gets a To do with **Re-authorize the hold**: a new hold on the saved card, then the old one is released.

**Program settings**: **Extended deposit holds (up to about 30 days)** is on: Stripe approved it for the account. Every deposit hold (the pay link, the saved card, **Re-authorize the hold**, the reader) asks for a longer authorization, about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise; a card that cannot gets the standard hold by itself. It never touches the rental payment. Capturing a deposit hold by itself is off. The heavy cleaning fee (an excessively dirty or smoked-in car) is $300 in **Fees**, editable as every fee.

## Updated terms to accept

**Settings** > **Updated terms**. When the terms of use, the privacy policy or an agreement template changes, publish the new version here; with **Requires acceptance** on, each person it binds accepts it before using their portal.

1. Press **Publish a version**. Choose the Document (the terms of use and the privacy policy bind everyone with a portal; each agreement binds the people who sign it: renters, owners, fleet suppliers, partners, investors, or staff and field).
2. Give the Version (for example the date it takes effect) and **What changed**: people read this summary first.
3. Paste **The new text**. For the terms of use or the privacy policy, leave it empty to use the site''s current text; a text you paste also replaces the site''s page.
4. Leave **Requires acceptance** on and press **Publish a version**.
5. Everyone it binds whose account was opened before sees **We''ve updated our terms** full screen on their next visit, with your summary and the text, and presses Accept. The acceptance is recorded with the time, the IP address, the device and the version.
6. **Accepted** on each version opens who accepted it and when.

> Good to know: It is a click-through acceptance of the new version: no signed agreement is voided and no renter signs the agreement of a past booking again. An Admin account is never asked.

> Good to know: Every agreement is signed with the e-signature only (the identity steps, the IP address, the audit trail): a signature on paper is never recorded. Only an official ServiceOntario form, which the government requires signed in ink, is recorded from its scan.

### Card processing fee for a debit deposit
Program settings: **Card processing fee for a debit deposit: percent (hundredths: 290 is 2.9%)** and **Card processing fee for a debit deposit: fixed part (cents)** (30 is $0.30). When a deposit is charged instead of held on a debit or prepaid card, the renter pays this fee on it, as a separate non-refundable amount shown before they pay, on the receipt and on the Money tab. Set both to 0 to charge no fee.

## My profile and name changes (release 34)
Settings > **My profile** has your display name, **Request a name change** for your legal name, your phone number and **Change my password**. When someone else asks to change the legal name on their agreements, it comes to To do with Approve and Decline, and shows on their page (owner, investor or renter). Approving changes the name on their account and record; agreements already signed keep the name they were signed with.

## AI auto-replies (release 36)

**Settings** > **Program settings**, the AI auto-replies group, answers common questions by itself, only from the FAQ (**Site content**), within Workers AI''s free daily allowance. Each channel has its switch, on by default: texts to the CarmaCars number, emails to the inboxes listed (help@in.carmacars.ca), the website live chat, WhatsApp, Facebook Page messages and Instagram messages.

1. A question the FAQ answers gets the answer at once. A text asked between 1 am and 5 am is answered at 5 am (the quiet hours are settings).
2. When the FAQ does not answer it, or the model is not sure enough (70%), nothing is sent: a text stays in Messages for staff, and an email or a Meta message becomes a To do for customer service, **Answer** and the question.
3. Each person gets at most 5 automatic answers a day, never while a staff member texted them in the last 2 hours, and none once the day''s free AI allowance is used.
4. The card **AI auto-replies: the last answers** shows today''s answers and the last questions, with what was sent or why not.

Messenger, Instagram and WhatsApp need the Meta app''s webhook set to https://carmacars.ca/api/webhooks/meta with the verify token shown in the settings, and the Worker secrets META_APP_SECRET (and WHATSAPP_TOKEN with the WhatsApp number id). TikTok has no inbound message path for businesses, so it is not answered.

## Address suggestions (release 36)

The address fields suggest Canadian addresses from the site''s own address database (Statistics Canada''s Open Database of Addresses, loaded by the addresses workflow, Ontario first). Google is asked only for what the database does not have, and only when its key is set.

## Card coverage: the facts the booking check uses (release 35)

Each card also has: **Network** (Visa, Mastercard, American Express), **Includes rental car damage coverage (CDW)** (Yes, No or Unknown), **Vehicle types not covered** (comma separated: exotic, luxury, truck, van, off_road, antique, motorcycle, limousine, rv), **Must decline the rental company''s CDW** and **Must pay the full rental on the card**. A renter on card coverage picks their card from this list; the site checks it against the car''s value (the Black Book value or the estimate on the car), the car''s type and the length of the rental, and refuses a card that does not cover it. Unknown sends the renter to staff review. Exotic makes are listed in **Program** > **Coverage checks**.

## Fuel prices and delivery (release 35)

- **Program** > **Fuel and charging at the return**: the local pump prices of regular, premium and diesel (a litre), the multiplier (1.25), the refuelling fee ($20), the price a kWh for electric cars ($0.40), and the tank and battery sizes for a car without its own. Update the pump prices every week: **Today** reminds you after 7 days.
- **Airports and delivery** > **Delivery rate and origin**: the base fee each way ($75), the km it includes from the company''s location (15), the rate per km after them ($2), and the straight line to road distance factor (1.3) used when the maps service gives no road distance. A car whose rate card has its own delivery or pickup fee keeps it; every other car follows the base.

## Automatic answers and email budgets (release 36)

- Automatic answers: each channel (text, email, chat, social messages) switches on or off, with the quiet hours, the daily limit per person and how sure the answer must be. The last answers and the questions left for a person show in settings and under renter messages; a question it cannot answer becomes a To do. They stay inside the free daily AI allowance.
- Email budgets: Settings, Usage shows the real daily email capacity of all our sending services together (Cloudflare included), and when a service is not sending, why. Receipts, signed copies and staff messages always go.
- First photo: each listing chooses its first photo, the plain car, a car-show photo with a model, or a flyer with the live price; the flyer is made again when the price changes.
- Rewards: points for a photo with a review and for every rental after the first; every way to earn is on the renter''s Rewards page.

## Owner emails: trips and the week (release 41)

Owners are not emailed when a booking comes in, is confirmed or changes, because many bookings are cancelled (owner_new_booking, owner_booking_confirmed and owner_booking_changed are off, with their texts and notices). They are emailed when a trip is complete and the car is back (owner_trip_completed: the car, dates, days, distance driven if recorded and their share, which says it shows on the next statement while the booking''s revenue is hidden from them), and every Monday at about 9:00 Toronto time (owner_weekly_summary: per car, last week''s trips with their share, the confirmed bookings of the next 14 days with dates only, and the month so far, provisional), only when there was activity. Only bookings that count toward the owner''s revenue are used, never Owner Bookings or Turo trips. The Monday email has a switch in Program settings: **Weekly summary email to owners** (on by default).

## Call helper (release 43)

**Settings**, **Call helper**: what staff read inside the caller pop-up while on a call. A change shows on the next call.

1. **Greetings**: one for each kind of caller (a caller we do not know, a renter with a booking, a renter with no booking now, a lead, a car owner, a staff member). Press **Change** and type what to say. `{staff}` becomes the first name of the person on the phone, `{caller}` the caller''s first name, `{booking}` the booking number and `{car}` the car. A greeting that is off, or that needs a name we do not have, falls back to the one for a caller we do not know, which stays on.
2. **Situations**: one button each. **Add a situation** or **Change**: the name on the button, then the steps, one a line (3 to 6 is best, 8 at most). Write a link to a page as `[Bookings](/bookings)`: an Admin gets the Admin page and staff get their own. Words in "quotes" are shown as what to say. **Order** sets the place of the button; switch **On** off to hide one, or **Remove** it.
3. **Quick answers**: the question, the answer, and more search words staff might type.
4. **Numbers from the settings**: never type an amount, a number of days or a percentage. Write its word in braces from this list, for example `{late_grace}` or `{deposit_tiers}`: staff read today''s value from Program settings, Fee defaults and Deposit tiers, and it changes the day the setting does. A word in braces that is not in the list is refused when you save.

Every change is in the audit log with the words before and after.

## Texts and email by message type (release 48)
Program settings, **Texts and email by message type**, lists each message that can go by text with how many texts it sent in the last 30 days. Turn on **Email ready for production** once Amazon SES is out of its sandbox: then only the urgent messages keep their texts (the pickup details and codes, a late return, a failed payment, a declined deposit), and every other message goes by email, by text only when the person has no email address or their email bounced. Press **Change** on a row to send that message by email only, text only, or text and email (the person''s choice). The deposit link, sign-in codes, staff alerts and texts typed by staff always stay texts. While the switch is off nothing changes.', 'Settings', 'Site, program settings, official forms mapping, insurers and the other lists.',
  'Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.

## The Settings page

1. Site setup lists what is still missing on the public site, with **Open site settings**.
2. Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.
3. Program settings: every timing and policy value.
4. Forms: Blind Spot''s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.
5. Insurers: insurance companies billed for bookings.

![](/guides/img/admin-24-settings-desktop-89b31691.jpg "desktop; size: 1440 900; address: carmacars.ca/admin/settings; pins: 1 32.6 33.0, 2 25.8 40.2, 3 77.4 40.2, 4 25.8 73.2, 5 25.8 84.9")

The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company''s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, My profile, Staff and roles, Promo codes, Quick replies and Call helper.

**My profile**: the greeting name of this login. To do greets it whole ("Good morning, Abbas and Mahad" on a login the owners share) and the assistant uses it; empty, the first name of the account. Press **Change the greeting name**, type it and save.

## Program settings

1. Buffer between trips (90 minutes): the time held before and after every trip, in every availability and conflict check (requests, offers, date changes, extensions, the calendar). The cleaning block after a trip is this time; Turnaround between trips is the same number. A booking already closer than this is not changed: the calendar rings it.
1. Late fee and extensions (Booking requests and offers): the late fee per started hour (17.5% of the daily rate, at least $25; new bookings and offers only), the extension discounts (no longer applied since release 35: an extension costs the booking''s all-in price a day) and **Approve a renter''s extension at once when nothing needs a person** (on). A car''s own switch is in Fleet, the car, **Edit details**: **Renters extend themselves**.
1. RentalCover (the Protection Plan): whether quotes price the plan once the key is set (on), the markup (on, 20%, no fixed amount), how long a quote is reused, the car value limit ($50,000) and whether a car with no value may have the plan (off).
2. Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.
3. First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.
4. Staff commissions and prices typed by hand: the commission outside Sales (10%, field staff only: customer service, Fleet and Finance earn none), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month''s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).
5. Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press **Save the defaults**.
6. Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.
7. Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).
8. Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.
9. Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-in besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Shifts published by themselves (on): the shift template (one shift of 10:00 to 17:00 for one person, every second day from November 23, 2026), how many days ahead (14) and the first day they may be published for; a handover or return no shift covers gets a shift of its own. Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).
10. Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.
11. Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.
12. Change a value and press **Save**. It is saved as a new row from today; the rows before stay as they were.

![](/guides/img/admin-25-program-settings-desktop-d16b066c.jpg "desktop; size: 1440 1000; address: carmacars.ca/admin/settings/program; pins: 1 25.8 22.0, 2 27.8 49.0")


## Lead-time pricing

A car booked at short notice costs a little more and one booked well ahead a little less. Open **Settings**, then **Program settings**: Lead-time pricing is at the top.

1. The switch turns it on or off for every car (on by default).
2. The table holds the tiers: when the pickup is that many hours away, the rental charge changes by that percentage. By default: under 24 hours +15%, 24 to 72 hours +10%, 3 to 13 days 0%, 14 days or more −5%. Type the hours and the percentage on each row (a minus for less); **Add a tier** adds one, **Remove** takes one off. Each row shows what it does to a $500 rental.
3. **Also adjust bookings billed to an insurer** is off by default: an insurer pays its own rate, never a short-notice premium.
4. Press **Save lead-time pricing**. New quotes and requests use it; bookings already made keep theirs.

| What it touches | How |
| --- | --- |
| The rental charge | The percentage of the rental charge only, before tax: one line in the price, "Short-notice pricing +10%" or "Booked ahead −5%". Never the fees, the deposit or add-ons |
| When it is worked out | When the quote is made (the car page, the cars list once dates are chosen, the request), from that moment to the pickup on Toronto clocks. "From $X a day" stays at the base rate |
| When it is locked | On the request: the offer, a change of dates and the payment keep the same percentage |
| Other discounts | The non-refundable discount, a promo code and a staff discount are worked out on the rental charge from the rates, as before, and show beside it |
| Owner revenue and commissions | Count the rental charge after it, as they count the discounts |
| Staff | Change it on a booking under **More options** on the review screen; a price typed by hand replaces it. Rentals added by hand, Owner Bookings and placeholders are not adjusted |

> Tip: A car can turn it off or have its own tiers: **Vehicles** > the car > **Rates** > Lead-time pricing for this car.
## Vehicle class rules

Open **Settings**, then **Vehicle class rules**. How a new car''s class is decided from its VIN: the first rule that matches wins.

1. The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.
2. Press **Add a rule** or **Change**: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.
3. **Try a car** gives the class the rules decide for a year, make, model, trim and body, and why.
4. **Delete** removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.

> Tip: A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.

## Official ServiceOntario forms

The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled; its own text and layout are never changed. A form whose stored PDF is not the publisher''s download (or your upload of it) gives owners the data sheet instead. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.

1. Open **Settings** > **Forms**. Each form shows "Mapping to check" (a draft is ready) or "Official PDF in use". Its notes say what the form is for and which boxes are left blank on purpose.
2. Choose **Preview with**: a sample car (made-up values) or one of the cars. Press **Download a filled preview** and check each value against the form. The preview uses the mapping on screen, saved or not.
3. Change a field if needed: What goes in it (or "Signed here by hand, in ink"), a Format (for example YYYY/MM/DD) and Only when. Write what you changed and press Save the mapping. **Earlier mappings** lists every save, with who and when; **Load** puts one back on screen to preview and save again. Fleet can map the forms too (Owners > Government forms), but only an Admin uploads a form.
4. Press **Checked: use for owners**. Every owner''s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with **Record an official form signed in ink**. Each form not checked yet is also a line on To do with the same button and Preview it.
5. A new version from ServiceOntario? Press **Upload the official fillable PDF**: the fields of the same name keep their mapping.

> Good to know: SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company''s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner''s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form''s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.

## Blind Spot rental agreement

We rent under Blind Spot Car Rental''s insurance, so every booking has two agreements: CarmaCars'' rental agreement and Blind Spot''s own. Blind Spot''s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.

1. Open **Settings** > **Forms**. The Blind Spot Car Rental agreement card is first. Press **Upload Blind Spot''s PDF** and choose Blind Spot''s blank form (2 pages, A4).
2. Press **Download the filled sample**: a made-up booking on the form. **Sample billed to an insurer** also fills the claim number, the adjuster and the insurance company. Check every box.
3. On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars'' HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative''s signature instead of Sam''s.
4. Press **Checked: use for bookings**. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.
5. Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.
6. A new version of Blind Spot''s form? Upload it the same way: it waits for **Checked: use for bookings**, and bookings keep the version in use until then.

> Good to know: Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the rate rows (days, weeks or months @ the rate = the amount; a rental counted by the day, such as 31 days at the monthly rate, shows its daily rate rounded to the cent, and box 14 says how the charge was made), the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST (13% of the subtotal), total and deposit, the deposit received and the day it was taken (before pickup, the amount due at pickup), and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. The boxes filled at check-in and check-out stay blank until then. The fuel gauges are covered and the level of the check-in report (fuel out) and the check-out report (fuel in) is written in words, blank with no reading.

The renter''s signature goes in boxes 16, 17 and 20 of the signed copy, with the day they signed beside box 20 and a signature record page. Each later version (as picked up, as returned, corrected) carries the same signature and day. Both agreements are in the booking''s Drivers and documents tab, in the renter''s Documents, and the signed Blind Spot agreement is attached to the "Your signed rental agreement" email. Admin > Today lists the HST number, the upload and the check until they are done.

## Agreements to sign: investors and staff

Investment agreements and staff agreements are made from the person''s record and signed in their own portal, with the e-signature (never on paper).

1. Investor: open **People** > **Investors** and the investor. Under Investment agreement, press **Send the agreement to sign**. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press **Send to sign**.
2. Once the investor signs, the agreement shows **Awaiting countersignature** on the investor''s page and on To do. It is not countersigned automatically: check it and press **Countersign**. CarmaCars is bound once it has countersigned and the funds clear.
3. Staff: open **People** > **Team**. Under Staff agreements, press **Send the agreement to sign** beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.
4. A field staff member''s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.
5. They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.
6. Already sent or signed with old terms? Press **Send a new agreement** beside the person: it is filled with the current terms (for staff who live in Canada: Canada, CAD, Interac e-Transfer or direct deposit) and sent to sign the same way. The one waiting is withdrawn; a signed one stays on file, marked superseded, and keeps their portal open until they sign the new one. Someone in Canada still on the old terms (the Philippines, USD, OnlineJobs.ph) shows **Lives in Canada: needs the Canadian terms**, and a To do lists them.
7. Your own PDF instead? **Send a PDF to sign** still works.
8. Sent by mistake? Press **Withdraw** and give the reason.

## The user guides

**Settings** > **Guides**. The guide of each portal, as people read it under Guide.

1. Each guide shows its version, when it was published and whether there are unpublished changes.
2. Open a guide and press a section. Change its text and press **Show the preview** to see it as people will. Press **Save the draft**; each save is kept in the section''s history.
3. Move a section with the arrows, hide it, or press **Add a chapter**. Upload a screenshot under Screenshots and paste the line it gives you.
4. Press **Publish version** (the next number). The portals show the new version at once.
5. The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.

## The guides keep up by themselves

After every update of the site that changes the portals, the guides are checked without anyone asking.

1. Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.
2. The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal''s own labels and menu, checked, and published. The PDFs of those guides are printed again.
3. Such a section says **Changed automatically on** and the date, in the list of guides and in the guide''s editor. Not right? Open the section and press **Revert**: the text it replaced comes back, published at once.
4. This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section''s history. There is nothing to review.
5. A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.

> Tip: The card "The guides keep up by themselves" at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.

## Insurers and the other lists

1. Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in **Money** > **Insurers**.
2. To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press **Add**.
3. Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.

## Promo codes: end dates and reminders

**Settings**, **Promo codes**.

- Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.
- A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.
- A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with "This code has expired".
- A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.
- The list shows each code''s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.

## Card coverage: which credit cards include rental car coverage

**Settings** > **Card coverage** is the list renters see at `carmacars.ca/credit-card-rental-coverage` and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.

1. The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer''s own document, and when it was last checked.
2. Open a card under Change a card, open its official guide, correct what changed and press **Save**. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.
3. A card whose numbers come from a published summary has Read in the issuer''s own document unticked and the summary''s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer''s guide.
4. Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.

> Tip: A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer''s guide.

## Reviews: review requests and Google

**Settings** > **Reviews**: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.

1. When review requests go: the check-out (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-out), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.
2. The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile''s own review link.
3. Google Business Profile: press **Connect Google** and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.
4. A clear match stops that renter''s reminders at once. A possible match waits in Reviews: press **Confirm**, **Not this renter** or **Match to a booking**.

> Tip: Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and "I already left a review", Mark reviewed and on-site reviews still stop the messages.

### Pair the card reader
**Settings** > **Card reader**. On the Stripe S700, swipe from the left edge, open **Settings**, then **Generate pairing code**. Type the three words in **Pairing code**, name the reader (Front desk) and press **Pair reader**. The first time, a Stripe Terminal location is made from the mailing address in Site settings: write it as street, city, province and postal code. **Remove** takes a reader off the list. Card statements read 18122211 Canada Inc., the Stripe account''s statement descriptor.

### Rewards
**Settings** > **Rewards**. CarmaCars Rewards is on: 1 point per dollar of the rental charge after discounts (never fees, add-ons, coverage, tax or the deposit), 100 points = $1, redeemed from 500 points as a code of the renter''s own, valid 90 days. Points end 12 months after the last rental or redemption, with a reminder email 30 days before.

1. **Ways to earn**: each on or off with its points. Referral (500 to the referrer, 250 to the friend, at the friend''s first completed rental), a follow on Instagram, TikTok or Facebook (50 each, once, granted on the click from the Rewards page, since a follow cannot be checked; a platform shows only with its page in Site settings), a review on carmacars.ca (100, any rating; the review shows "Received reward points"), a Google review (100 a rental, any rating, on the renter''s word: they press I posted my review and give the name on it; hidden until the Google review page is set here), a damage-free rental (200: no damage, claim, cleaning or smoking fee, back on time), the birthday (100) and the first rental (100).
2. **Tiers**: Gold from 1,000 points earned in 12 months, Platinum from 15,000, Black from 60,000 (below Gold a renter is a Member). Points earned count, so using points never lowers a tier. Press **Change** on a tier for its name and points. Tiers give perks, not discounts; tier codes issued before release 40 work until they end.
3. **Perks**: Instant Book (Gold), Any car, any time (Platinum) and a free rental day a year (Black). Each tier keeps the perks below it. **Change** a perk to move it to another tier, reword it or switch it off. **Change the response time** sets how fast Fleet answers an Any car request (4 hours); the open ones are listed with their answer-by time.
4. Points and codes come off the rental charge only and reduce Owner Revenue like any promo code, except the Black tier''s free day: CarmaCars pays for it, and the owner''s payout is worked out on the price before it.
4. **Google reviews claimed** lists every claim; **Reverse** takes the points back with a reason. **A renter''s points**: find the renter, then **Add or take off points** with a reason, or reverse any entry (for example, referral fraud).
5. **Emails and notices to renters**: every Rewards email, each also a notice in the renter''s portal (a text only when they have no email): the welcome, points earned, a new tier, the free day, close to the next tier, points waiting, the 7-day reminder, the free day ending, the monthly statement and the birthday and holiday rewards. Each shows how many went in the last 30 days. **Preview** shows the email with sample values; **Turn off** stops it; **Change** sets the timings or switches them all off. Marketing ones carry an unsubscribe link and never go to someone who unsubscribed.
6. **Birthday and holiday rewards**: a percent off the rental charge by tier for a pickup near the renter''s birthday (7 days either side) or on a holiday weekend: Platinum 10%, Black 20%; Gold is off (0%) until you give it a percent. The bigger one applies, never both, never below the car''s lowest daily price, never on insurer or Owner Bookings. The request or offer keeps it. **Change** a tier for its percents or to switch it off; the holidays are listed with their next weekend: **Turn off**, **Remove** or **Add a holiday** by its date rule.

### Setup checklist
**Settings** shows what still needs a key from one of CarmaCars'' own accounts. **Add to Apple Wallet** stays hidden until the Apple Pass Type ID certificate is added (WALLET_PASS_CERT, WALLET_PASS_KEY, WALLET_WWDR_CERT, WALLET_PASS_TYPE_ID and WALLET_TEAM_ID in the Worker''s secrets); then it shows on every confirmed booking.


Program: **Call and Text buttons go through Quo** (on) makes every Call and Text button use the CarmaCars number in Quo (chapter Texts and calls). Off, they open the device''s own phone and messages apps.

## Stuck? help

**Settings** > **Program settings** > **Stuck? help**: turn it on or off, the minutes on a page without a successful action (3), and the errors (3) before the box offers the guide and the Academy lesson. **Where people get stuck**, on the same page, lists the pages it showed on most in the last 30 days, with how often the guide and the lesson were opened.

### API access (Claude and scripts)

Settings > **API access** connects Claude so you (or Mahad) can run CarmaCars from a Claude chat: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, invoices, staff and hiring ("hire Ana as customer service"). **Connect from Claude**: in Claude, Settings > Connectors > Add custom connector, paste https://carmacars.ca/api/mcp, then sign in to CarmaCars and press **Allow**. Every change is two steps: Claude first shows what will change (nothing is changed yet), and does it only when you agree. Keys and connections made with every scope got the Admin scopes in release 33; a key with fewer scopes keeps them. For Claude Code or a script, **Make a key**: copy it at once, it is shown only once. Each key or connection acts as its Admin, with the scopes chosen; **Revoke** stops it at once. The **Call log** lists every call (the previews too) with the values before and after. The database checks each action exactly as the Admin screens do.

### The logo

The site, every portal, every email and the documents show the brand logo. To use another, upload it under Settings > **Site settings**, the Logo card (PNG or JPEG for emails and documents).

## Deposits stay as holds (release 28)

Every deposit by card is a hold (an authorization) that stays with Stripe: it is never captured by itself, so nothing is paid out and nothing has to be refunded. Capture only what is owed, and release the rest from the booking. The booking''s Security deposit panel shows Hold expires with the date Stripe gives. When a hold nears its expiry while the car is out or tickets can still come in, Finance gets a To do with **Re-authorize the hold**: a new hold on the saved card, then the old one is released.

**Program settings**: **Extended deposit holds (up to about 30 days)** is on: Stripe approved it for the account. Every deposit hold (the pay link, the saved card, **Re-authorize the hold**, the reader) asks for a longer authorization, about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise; a card that cannot gets the standard hold by itself. It never touches the rental payment. Capturing a deposit hold by itself is off. The heavy cleaning fee (an excessively dirty or smoked-in car) is $300 in **Fees**, editable as every fee.

## Updated terms to accept

**Settings** > **Updated terms**. When the terms of use, the privacy policy or an agreement template changes, publish the new version here; with **Requires acceptance** on, each person it binds accepts it before using their portal.

1. Press **Publish a version**. Choose the Document (the terms of use and the privacy policy bind everyone with a portal; each agreement binds the people who sign it: renters, owners, fleet suppliers, partners, investors, or staff and field).
2. Give the Version (for example the date it takes effect) and **What changed**: people read this summary first.
3. Paste **The new text**. For the terms of use or the privacy policy, leave it empty to use the site''s current text; a text you paste also replaces the site''s page.
4. Leave **Requires acceptance** on and press **Publish a version**.
5. Everyone it binds whose account was opened before sees **We''ve updated our terms** full screen on their next visit, with your summary and the text, and presses Accept. The acceptance is recorded with the time, the IP address, the device and the version.
6. **Accepted** on each version opens who accepted it and when.

> Good to know: It is a click-through acceptance of the new version: no signed agreement is voided and no renter signs the agreement of a past booking again. An Admin account is never asked.

> Good to know: Every agreement is signed with the e-signature only (the identity steps, the IP address, the audit trail): a signature on paper is never recorded. Only an official ServiceOntario form, which the government requires signed in ink, is recorded from its scan.

### Card processing fee for a debit deposit
Program settings: **Card processing fee for a debit deposit: percent (hundredths: 290 is 2.9%)** and **Card processing fee for a debit deposit: fixed part (cents)** (30 is $0.30). When a deposit is charged instead of held on a debit or prepaid card, the renter pays this fee on it, as a separate non-refundable amount shown before they pay, on the receipt and on the Money tab. Set both to 0 to charge no fee.

## My profile and name changes (release 34)
Settings > **My profile** has your display name, **Request a name change** for your legal name, your phone number and **Change my password**. When someone else asks to change the legal name on their agreements, it comes to To do with Approve and Decline, and shows on their page (owner, investor or renter). Approving changes the name on their account and record; agreements already signed keep the name they were signed with.

## AI auto-replies (release 36)

**Settings** > **Program settings**, the AI auto-replies group, answers common questions by itself, only from the FAQ (**Site content**), within Workers AI''s free daily allowance. Each channel has its switch, on by default: texts to the CarmaCars number, emails to the inboxes listed (help@in.carmacars.ca), the website live chat, WhatsApp, Facebook Page messages and Instagram messages.

1. A question the FAQ answers gets the answer at once. A text asked between 1 am and 5 am is answered at 5 am (the quiet hours are settings).
2. When the FAQ does not answer it, or the model is not sure enough (70%), nothing is sent: a text stays in Messages for staff, and an email or a Meta message becomes a To do for customer service, **Answer** and the question.
3. Each person gets at most 5 automatic answers a day, never while a staff member texted them in the last 2 hours, and none once the day''s free AI allowance is used.
4. The card **AI auto-replies: the last answers** shows today''s answers and the last questions, with what was sent or why not.

Messenger, Instagram and WhatsApp need the Meta app''s webhook set to https://carmacars.ca/api/webhooks/meta with the verify token shown in the settings, and the Worker secrets META_APP_SECRET (and WHATSAPP_TOKEN with the WhatsApp number id). TikTok has no inbound message path for businesses, so it is not answered.

## Address suggestions (release 36)

The address fields suggest Canadian addresses from the site''s own address database (Statistics Canada''s Open Database of Addresses, loaded by the addresses workflow, Ontario first). Google is asked only for what the database does not have, and only when its key is set.

## Card coverage: the facts the booking check uses (release 35)

Each card also has: **Network** (Visa, Mastercard, American Express), **Includes rental car damage coverage (CDW)** (Yes, No or Unknown), **Vehicle types not covered** (comma separated: exotic, luxury, truck, van, off_road, antique, motorcycle, limousine, rv), **Must decline the rental company''s CDW** and **Must pay the full rental on the card**. A renter on card coverage picks their card from this list; the site checks it against the car''s value (the Black Book value or the estimate on the car), the car''s type and the length of the rental, and refuses a card that does not cover it. Unknown sends the renter to staff review. Exotic makes are listed in **Program** > **Coverage checks**.

## Fuel prices and delivery (release 35)

- **Program** > **Fuel and charging at the return**: the local pump prices of regular, premium and diesel (a litre), the multiplier (1.25), the refuelling fee ($20), the price a kWh for electric cars ($0.40), and the tank and battery sizes for a car without its own. Update the pump prices every week: **Today** reminds you after 7 days.
- **Airports and delivery** > **Delivery rate and origin**: the base fee each way ($75), the km it includes from the company''s location (15), the rate per km after them ($2), and the straight line to road distance factor (1.3) used when the maps service gives no road distance. A car whose rate card has its own delivery or pickup fee keeps it; every other car follows the base.

## Automatic answers and email budgets (release 36)

- Automatic answers: each channel (text, email, chat, social messages) switches on or off, with the quiet hours, the daily limit per person and how sure the answer must be. The last answers and the questions left for a person show in settings and under renter messages; a question it cannot answer becomes a To do. They stay inside the free daily AI allowance.
- Email budgets: Settings, Usage shows the real daily email capacity of all our sending services together (Cloudflare included), and when a service is not sending, why. Receipts, signed copies and staff messages always go.
- First photo: each listing chooses its first photo, the plain car, a car-show photo with a model, or a flyer with the live price; the flyer is made again when the price changes.
- Rewards: points for a photo with a review and for every rental after the first; every way to earn is on the renter''s Rewards page.

## Owner emails: trips and the week (release 41)

Owners are not emailed when a booking comes in, is confirmed or changes, because many bookings are cancelled (owner_new_booking, owner_booking_confirmed and owner_booking_changed are off, with their texts and notices). They are emailed when a trip is complete and the car is back (owner_trip_completed: the car, dates, days, distance driven if recorded and their share, which says it shows on the next statement while the booking''s revenue is hidden from them), and every Monday at about 9:00 Toronto time (owner_weekly_summary: per car, last week''s trips with their share, the confirmed bookings of the next 14 days with dates only, and the month so far, provisional), only when there was activity. Only bookings that count toward the owner''s revenue are used, never Owner Bookings or Turo trips. The Monday email has a switch in Program settings: **Weekly summary email to owners** (on by default).

## Call helper (release 43)

**Settings**, **Call helper**: what staff read inside the caller pop-up while on a call. A change shows on the next call.

1. **Greetings**: one for each kind of caller (a caller we do not know, a renter with a booking, a renter with no booking now, a lead, a car owner, a staff member). Press **Change** and type what to say. `{staff}` becomes the first name of the person on the phone, `{caller}` the caller''s first name, `{booking}` the booking number and `{car}` the car. A greeting that is off, or that needs a name we do not have, falls back to the one for a caller we do not know, which stays on.
2. **Situations**: one button each. **Add a situation** or **Change**: the name on the button, then the steps, one a line (3 to 6 is best, 8 at most). Write a link to a page as `[Bookings](/bookings)`: an Admin gets the Admin page and staff get their own. Words in "quotes" are shown as what to say. **Order** sets the place of the button; switch **On** off to hide one, or **Remove** it.
3. **Quick answers**: the question, the answer, and more search words staff might type.
4. **Numbers from the settings**: never type an amount, a number of days or a percentage. Write its word in braces from this list, for example `{late_grace}` or `{deposit_tiers}`: staff read today''s value from Program settings, Fee defaults and Deposit tiers, and it changes the day the setting does. A word in braces that is not in the list is refused when you save.

Every change is in the audit log with the words before and after.

## Texts and email by message type (release 48)
Program settings, **Texts and email by message type**, lists each message that can go by text with how many texts it sent in the last 30 days. Turn on **Email ready for production** once Amazon SES is out of its sandbox: then only the urgent messages keep their texts (the pickup details and codes, a late return, a failed payment, a declined deposit), and every other message goes by email, by text only when the person has no email address or their email bounced. Press **Change** on a row to send that message by email only, text only, or text and email (the person''s choice). The deposit link, sign-in codes, staff alerts and texts typed by staff always stay texts. While the switch is off nothing changes.

## Deposits by e-Transfer or cash, and tips

1. **Deposit by e-Transfer or cash: a multiple of the deposit** (on) and its multiplier (2): a $300 deposit is $600 by e-Transfer or cash. A debit or prepaid card keeps its own multiplier. An amount set on one booking wins.
2. **Tips** (on): the pay page, the receipt and the after-trip email offer 10, 15 or 20% or an amount; **the salesperson''s share** (5000: half, the rest to the handover).
',
  '<p class="gd-p">Settings change the public site and the rules of the program at once. Program settings are kept as dated rows, so earlier values stay on record.</p><section class="gd-task" id="settings-the-settings-page" data-gd-task><h2 class="gd-h2">The Settings page</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Site setup lists what is still missing on the public site, with <b class="gd-ui">Open site settings</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Site settings: contact details, hours, tagline, logo, socials, Google place id and featured cars.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Program settings: every timing and policy value.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms: Blind Spot&#39;s rental agreement for every booking, and the official ServiceOntario PDFs and what goes in each field.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Insurers: insurance companies billed for bookings.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-24-settings-desktop-89b31691.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:32.6%;top:33%" aria-hidden="true">1</span><span class="gd-pin" style="left:25.8%;top:40.2%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:40.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:25.8%;top:73.2%" aria-hidden="true">4</span><span class="gd-pin" style="left:25.8%;top:84.9%" aria-hidden="true">5</span></div></div></figure></div><p class="gd-p">The other tiles: Site content (headings, FAQs, legal text), Fee defaults, Deposit tiers, Kilometre choices, Vehicle classes, Vehicle class rules, Airports and delivery, Protection Plan prices, Card coverage, Reviews, Quo contacts (everyone with a phone number as a contact in Quo: see Texts and calls), Text alerts, Partners (each partner company&#39;s CRM link: see Partners, company cars and rentals added by hand), Email aliases and reply-to, My profile, Staff and roles, Promo codes, Quick replies and Call helper.</p><p class="gd-p"><b class="gd-ui">My profile</b>: the greeting name of this login. To do greets it whole (&quot;Good morning, Abbas and Mahad&quot; on a login the owners share) and the assistant uses it; empty, the first name of the account. Press <b class="gd-ui">Change the greeting name</b>, type it and save.</p></section><section class="gd-task" id="settings-program-settings" data-gd-task><h2 class="gd-h2">Program settings</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Buffer between trips (90 minutes): the time held before and after every trip, in every availability and conflict check (requests, offers, date changes, extensions, the calendar). The cleaning block after a trip is this time; Turnaround between trips is the same number. A booking already closer than this is not changed: the calendar rings it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Late fee and extensions (Booking requests and offers): the late fee per started hour (17.5% of the daily rate, at least $25; new bookings and offers only), the extension discounts (no longer applied since release 35: an extension costs the booking&#39;s all-in price a day) and <b class="gd-ui">Approve a renter&#39;s extension at once when nothing needs a person</b> (on). A car&#39;s own switch is in Fleet, the car, <b class="gd-ui">Edit details</b>: <b class="gd-ui">Renters extend themselves</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">RentalCover (the Protection Plan): whether quotes price the plan once the key is set (on), the markup (on, 20%, no fixed amount), how long a quote is reused, the car value limit ($50,000) and whether a car with no value may have the plan (off).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Settings come in groups such as Company, Booking requests and offers, Owner debits and statement emails, Deposits, Delivery, Owners and fleet, and Tolls and damage. Open one to see its fields.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">First reply target for customer service and sales (minutes), under Booking requests and offers: 5 by default. New booking requests, enquiries, changes renters ask for and renter messages are due that many minutes after they come in; the scorecard and the staff screens use it. What renters are told (Reply wording, in Site settings) is separate.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Staff commissions and prices typed by hand: the commission outside Sales (10%, field staff only: customer service, Fleet and Finance earn none), the three Sales tiers and their days (10%, 15% from 50 days, 20% from 100 days, the month&#39;s target), the price floor a day (empty: none) and the discount from the rate sheet that flags a price (20%). The owner confirmed these values in October 2026. The remote Sales values follow: the three remote tiers (5%, 10%, 15%), the touches a month (400), the drop under it (one tier) and its floor (2.5%), the peak hours a week (20), the reply target (15 minutes) and the peak hours (noon to 6 pm, Thursday to Sunday).</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Staff agreement defaults by function, at the bottom: pay (a month, an hour or commission only), the rate, the schedule (full time, part time or flexible), days a week and hours a day for Customer service, Fleet, Finance and Sales, the values every assistant shares, and the field staff wage. Sales is commission only: no rate and a flexible schedule. Press <b class="gd-ui">Save the defaults</b>.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Live visitors and live chat: recording visits, the signal thresholds, follow-up tasks, the chat and its assistant, and how long visits and chats are kept.</div></li><li><span class="gd-n" aria-hidden="true">9</span><div class="gd-t">Discount games: the same values as Settings, Discount games (the prize table and the games are easier to change there).</div></li><li><span class="gd-n" aria-hidden="true">10</span><div class="gd-t">Deposits: the toll and ticket window after the return (7 days: settling sooner suggests a hold-back), the longest hold-back (30 days after the return), how long before a card hold lapses it is collected (36 hours), and collecting what is owed after the deposit by itself (the card on file, then a pay link, then a Finance task). A deposit is never released by itself.</div></li><li><span class="gd-n" aria-hidden="true">11</span><div class="gd-t">Field jobs and handovers: field jobs made from each confirmed booking (on) and who gets them (the least busy field staff member, or nobody so Fleet assigns), how field staff may take a deposit at the check-in besides a card (e-Transfer and cash), and whether they may release a car whose tracker is not reporting, with a reason (on; you get an urgent task). Shifts published by themselves (on): the shift template (one shift of 10:00 to 17:00 for one person, every second day from November 23, 2026), how many days ahead (14) and the first day they may be published for; a handover or return no shift covers gets a shift of its own. Field pay: the first day of a pay period (every period is two weeks), the default hourly rate (CA$18.00), whether overtime is paid (off), after how many hours in a week (44) and at what share of the rate (150%), vacation pay added to each statement (off; Ontario 4%) and the longest shift (16 hours).</div></li><li><span class="gd-n" aria-hidden="true">12</span><div class="gd-t">Sign-in by phone: codes by text from the CarmaCars number (on), US numbers (off until the Quo number is registered for US texting, A2P 10DLC), codes per number and per connection an hour, and whether a verified phone confirms an account like a confirmed email. Accepting an offer, signing and paying need a confirmed account; an account made by phone gives its email on the pay page before its first payment.</div></li><li><span class="gd-n" aria-hidden="true">13</span><div class="gd-t">Calendar sync, Turo by email, Booking recovery emails and Site check: how often calendar links are read, the Turo inbound address and who may forward to it, the reminder delays and sending hours, and the site check with the address its alerts go to (rent@carmacars.ca), the minutes before an email, the daily limit and the quiet hours.</div></li><li><span class="gd-n" aria-hidden="true">14</span><div class="gd-t">Change a value and press <b class="gd-ui">Save</b>. It is saved as a new row from today; the rows before stay as they were.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/settings/program</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/admin-25-program-settings-desktop-d16b066c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:25.8%;top:22%" aria-hidden="true">1</span><span class="gd-pin" style="left:27.8%;top:49%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="settings-lead-time-pricing" data-gd-task><h2 class="gd-h2">Lead-time pricing</h2><p class="gd-p">A car booked at short notice costs a little more and one booked well ahead a little less. Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Program settings</b>: Lead-time pricing is at the top.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The switch turns it on or off for every car (on by default).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The table holds the tiers: when the pickup is that many hours away, the rental charge changes by that percentage. By default: under 24 hours +15%, 24 to 72 hours +10%, 3 to 13 days 0%, 14 days or more −5%. Type the hours and the percentage on each row (a minus for less); <b class="gd-ui">Add a tier</b> adds one, <b class="gd-ui">Remove</b> takes one off. Each row shows what it does to a $500 rental.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Also adjust bookings billed to an insurer</b> is off by default: an insurer pays its own rate, never a short-notice premium.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Save lead-time pricing</b>. New quotes and requests use it; bookings already made keep theirs.</div></li></ol></div><div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table"><table class="gd-table"><thead><tr><th scope="col">What it touches</th><th scope="col">How</th></tr></thead><tbody><tr><td>The rental charge</td><td>The percentage of the rental charge only, before tax: one line in the price, &quot;Short-notice pricing +10%&quot; or &quot;Booked ahead −5%&quot;. Never the fees, the deposit or add-ons</td></tr><tr><td>When it is worked out</td><td>When the quote is made (the car page, the cars list once dates are chosen, the request), from that moment to the pickup on Toronto clocks. &quot;From $X a day&quot; stays at the base rate</td></tr><tr><td>When it is locked</td><td>On the request: the offer, a change of dates and the payment keep the same percentage</td></tr><tr><td>Other discounts</td><td>The non-refundable discount, a promo code and a staff discount are worked out on the rental charge from the rates, as before, and show beside it</td></tr><tr><td>Owner revenue and commissions</td><td>Count the rental charge after it, as they count the discounts</td></tr><tr><td>Staff</td><td>Change it on a booking under <b class="gd-ui">More options</b> on the review screen; a price typed by hand replaces it. Rentals added by hand, Owner Bookings and placeholders are not adjusted</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A car can turn it off or have its own tiers: <b class="gd-ui">Vehicles</b> &gt; the car &gt; <b class="gd-ui">Rates</b> &gt; Lead-time pricing for this car.</div></aside></section><section class="gd-task" id="settings-vehicle-class-rules" data-gd-task><h2 class="gd-h2">Vehicle class rules</h2><p class="gd-p">Open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Vehicle class rules</b>. How a new car&#39;s class is decided from its VIN: the first rule that matches wins.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table lists each rule: its rank, what the car must be (a make, and patterns for the model, the trim and the body), the class it gets, the class once the car is old enough, a note and whether it is on. The lowest rank that matches is used; a car that matches no rule is Standard.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Add a rule</b> or <b class="gd-ui">Change</b>: a rank, at least one condition, the class, optionally the years old after which an older class applies, and a note (it is shown as the reason for the class). A pattern is not case sensitive: ^911 matches models that start with 911. A rule with no condition, a pattern that does not compile and an older class equal to the class are refused.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Try a car</b> gives the class the rules decide for a year, make, model, trim and body, and why.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Delete</b> removes a rule; switch it off instead to keep it. Every add, change and delete is in the audit log, with before and after.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A rule changes the cars entered from then on. A car already listed keeps its class until you change it on the car.</div></aside></section><section class="gd-task" id="settings-official-serviceontario-forms" data-gd-task><h2 class="gd-h2">Official ServiceOntario forms</h2><p class="gd-p">The five official forms are loaded with a mapping to the owner, car, company and lender details. Each is the form exactly as ServiceOntario publishes it: only its empty text boxes are filled; its own text and layout are never changed. A form whose stored PDF is not the publisher&#39;s download (or your upload of it) gives owners the data sheet instead. Its checkboxes, drop-downs and signatures are done by hand at the counter, in ink. Until you check a form, owners get a data sheet with the values.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. Each form shows &quot;Mapping to check&quot; (a draft is ready) or &quot;Official PDF in use&quot;. Its notes say what the form is for and which boxes are left blank on purpose.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Preview with</b>: a sample car (made-up values) or one of the cars. Press <b class="gd-ui">Download a filled preview</b> and check each value against the form. The preview uses the mapping on screen, saved or not.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Change a field if needed: What goes in it (or &quot;Signed here by hand, in ink&quot;), a Format (for example YYYY/MM/DD) and Only when. Write what you changed and press Save the mapping. <b class="gd-ui">Earlier mappings</b> lists every save, with who and when; <b class="gd-ui">Load</b> puts one back on screen to preview and save again. Fleet can map the forms too (Owners &gt; Government forms), but only an Admin uploads a form.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for owners</b>. Every owner&#39;s form of that kind is filled again, except ones already signed or filed. Owners download it, print it and sign it in ink; record it with <b class="gd-ui">Record an official form signed in ink</b>. Each form not checked yet is also a line on To do with the same button and Preview it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A new version from ServiceOntario? Press <b class="gd-ui">Upload the official fillable PDF</b>: the fields of the same name keep their mapping.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>SR-LV-006 (registration), SR-LV-012 (two registrants), ON00453 (a company&#39;s RIN), 013-1155 and 013-0169 (the tax-exempt transfer into an owner&#39;s corporation). 013-1155 is sworn before a commissioner, so it is printed and signed in person. ON00453 is an Adobe form: it opens in Adobe Acrobat Reader. Each form&#39;s notes list what to tick or choose at the counter. A car gets only the forms its onboarding method needs: no form for a Transfer of a car owned outright or financed (the sign-back on the permit), 013-1155 and 013-0169 only for a Lease through a new Owner Corporation.</div></aside></section><section class="gd-task" id="settings-blind-spot-rental-agreement" data-gd-task><h2 class="gd-h2">Blind Spot rental agreement</h2><p class="gd-p">We rent under Blind Spot Car Rental&#39;s insurance, so every booking has two agreements: CarmaCars&#39; rental agreement and Blind Spot&#39;s own. Blind Spot&#39;s is filled in from the booking, the renter and the car, and the renter signs both with one signature. Its PDF is stored privately, never on the website.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Forms</b>. The Blind Spot Car Rental agreement card is first. Press <b class="gd-ui">Upload Blind Spot&#39;s PDF</b> and choose Blind Spot&#39;s blank form (2 pages, A4).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled sample</b>: a made-up booking on the form. <b class="gd-ui">Sample billed to an insurer</b> also fills the claim number, the adjuster and the insurance company. Check every box.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the form the old address (top left and twice in box 15) is replaced by the mailing address of Site settings, box 1 by CarmaCars&#39; HST number (Program settings, Company HST number; blank until it is entered), and box 21 has the representative&#39;s signature instead of Sam&#39;s.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked: use for bookings</b>. From then on each booking gets it when its rental agreement is made; a renter whose agreement is already open gets it the next time they open the signing page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Box 21: Ahmad is written in a script hand, as Blind Spot asked. To use a real signature instead, upload a PNG under Authorized company representative; Remove the image goes back to the written name. Full name is for the signature record page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">A new version of Blind Spot&#39;s form? Upload it the same way: it waits for <b class="gd-ui">Checked: use for bookings</b>, and bookings keep the version in use until then.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Each box is filled only when the booking has the value: the renter and their licence, the additional drivers, the car (plate, make and model, the fleet number as vehicle number), the pickup as time and date out, the due-back date and time, the kilometres allowed, the rate rows (days, weeks or months @ the rate = the amount; a rental counted by the day, such as 31 days at the monthly rate, shows its daily rate rounded to the cent, and box 14 says how the charge was made), the underage fee, the Protection Plan as CDW, winter tires, the subtotal, HST (13% of the subtotal), total and deposit, the deposit received and the day it was taken (before pickup, the amount due at pickup), and for a booking billed to an insurer the insurer, claim number and adjuster. Other charges, such as delivery, are listed in box 14. The boxes filled at check-in and check-out stay blank until then. The fuel gauges are covered and the level of the check-in report (fuel out) and the check-out report (fuel in) is written in words, blank with no reading.</div></aside><p class="gd-p">The renter&#39;s signature goes in boxes 16, 17 and 20 of the signed copy, with the day they signed beside box 20 and a signature record page. Each later version (as picked up, as returned, corrected) carries the same signature and day. Both agreements are in the booking&#39;s Drivers and documents tab, in the renter&#39;s Documents, and the signed Blind Spot agreement is attached to the &quot;Your signed rental agreement&quot; email. Admin &gt; Today lists the HST number, the upload and the check until they are done.</p></section><section class="gd-task" id="settings-agreements-to-sign-investors-and-staff" data-gd-task><h2 class="gd-h2">Agreements to sign: investors and staff</h2><p class="gd-p">Investment agreements and staff agreements are made from the person&#39;s record and signed in their own portal, with the e-signature (never on paper).</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Investor: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Investors</b> and the investor. Under Investment agreement, press <b class="gd-ui">Send the agreement to sign</b>. Check the values it is filled with (amount, yearly percentage, dates, exemption) and press <b class="gd-ui">Send to sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Once the investor signs, the agreement shows <b class="gd-ui">Awaiting countersignature</b> on the investor&#39;s page and on To do. It is not countersigned automatically: check it and press <b class="gd-ui">Countersign</b>. CarmaCars is bound once it has countersigned and the funds clear.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Staff: open <b class="gd-ui">People</b> &gt; <b class="gd-ui">Team</b>. Under Staff agreements, press <b class="gd-ui">Send the agreement to sign</b> beside the person. Pay, schedule, hours and the other values start from the staff profile and the defaults of their function in Program settings; change any before sending. For Sales the Pay is Commission only: the agreement then has no rate, schedule or hours, and pays the commission of section 3.4.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A field staff member&#39;s agreement prints the home address they entered themselves. Staff enter their home address at their first sign-in, before they sign, or in their profile.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">They get a notice, check the key values and sign in their portal in a few taps (their name is the signature, or they draw it). The signed copy is filed with their documents.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Already sent or signed with old terms? Press <b class="gd-ui">Send a new agreement</b> beside the person: it is filled with the current terms (for staff who live in Canada: Canada, CAD, Interac e-Transfer or direct deposit) and sent to sign the same way. The one waiting is withdrawn; a signed one stays on file, marked superseded, and keeps their portal open until they sign the new one. Someone in Canada still on the old terms (the Philippines, USD, OnlineJobs.ph) shows <b class="gd-ui">Lives in Canada: needs the Canadian terms</b>, and a To do lists them.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Your own PDF instead? <b class="gd-ui">Send a PDF to sign</b> still works.</div></li><li><span class="gd-n" aria-hidden="true">8</span><div class="gd-t">Sent by mistake? Press <b class="gd-ui">Withdraw</b> and give the reason.</div></li></ol></div></section><section class="gd-task" id="settings-the-user-guides" data-gd-task><h2 class="gd-h2">The user guides</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Guides</b>. The guide of each portal, as people read it under Guide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each guide shows its version, when it was published and whether there are unpublished changes.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a guide and press a section. Change its text and press <b class="gd-ui">Show the preview</b> to see it as people will. Press <b class="gd-ui">Save the draft</b>; each save is kept in the section&#39;s history.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Move a section with the arrows, hide it, or press <b class="gd-ui">Add a chapter</b>. Upload a screenshot under Screenshots and paste the line it gives you.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Publish version</b> (the next number). The portals show the new version at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The stored PDF is printed again by the guides-pdf workflow. Until then the guide says the web guide has newer edits.</div></li></ol></div></section><section class="gd-task" id="settings-the-guides-keep-up-by-themselves" data-gd-task><h2 class="gd-h2">The guides keep up by themselves</h2><p class="gd-p">After every update of the site that changes the portals, the guides are checked without anyone asking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Every screenshot is taken again on the new version of the site. One whose screen changed replaces the old one in the guide.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The text of each section whose screen changed, or that names a button the portals no longer show, is rewritten from the portal&#39;s own labels and menu, checked, and published. The PDFs of those guides are printed again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Such a section says <b class="gd-ui">Changed automatically on</b> and the date, in the list of guides and in the guide&#39;s editor. Not right? Open the section and press <b class="gd-ui">Revert</b>: the text it replaced comes back, published at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">This includes sections you edited: the newest automatic text is published, and every earlier version stays in the section&#39;s history. There is nothing to review.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">A rewrite that does not pass the checks is asked again, more strictly. If it still does not pass, the screenshots and button names are updated, the rest of the text stays as it was, and the next run tries again.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>The card &quot;The guides keep up by themselves&quot; at the top of Guides lists the last runs: when, how many screenshots were replaced, how many sections were rewritten, and how many PDFs were printed.</div></aside></section><section class="gd-task" id="settings-insurers-and-the-other-lists" data-gd-task><h2 class="gd-h2">Insurers and the other lists</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Insurers. Each insurer on file opens to edit its billing contact, email, phone, address and notes. Its rates by car class are in <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Insurers</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">To add one, fill in the Add form (Name, Billing contact, Billing email and the rest) and press <b class="gd-ui">Add</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Deposit tiers, Kilometre choices, Vehicle classes, Airports, Promo codes and Quick replies work the same way.</div></li></ol></div></section><section class="gd-task" id="settings-promo-codes-end-dates-and-reminders" data-gd-task><h2 class="gd-h2">Promo codes: end dates and reminders</h2><p class="gd-p"><b class="gd-ui">Settings</b>, <b class="gd-ui">Promo codes</b>.</p><ul class="gd-ul"><li>Every code made for a person has an end date: a game prize 7 days, a come-back offer 30, a Live visitors code 3 and a code made for one renter 30 unless you set another. The first card of Promo codes holds the 30 days and the two reminders.</li><li>A code for everyone may have no end date: empty Valid until. The Add form starts with an end date 30 days ahead.</li><li>A code that ended is refused wherever it is typed (the request form, an offer, Add a rental, a booking edit) with &quot;This code has expired&quot;.</li><li>A person who has not used a code is reminded 3 days before its last day and the day before, by email and by text as they chose, never once they used it, unsubscribed or the code ended, and never twice. A game code reminder always goes; a reminder of any other code needs their consent to offers.</li><li>The list shows each code&#39;s end date and the reminders sent. The card Codes sent to people lists game prizes, come-back offers and Live visitors codes the same way.</li></ul></section><section class="gd-task" id="settings-card-coverage-which-credit-cards-include-rental-car-coverage" data-gd-task><h2 class="gd-h2">Card coverage: which credit cards include rental car coverage</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card coverage</b> is the list renters see at <span class="gd-url">carmacars.ca/credit-card-rental-coverage</span> and staff see under Card coverage in their portal. It starts filled in with 48 Canadian and US cards, each checked on October 23, 2026.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The table shows each card: who pays first (Primary, Secondary, or not stated), the car value limit (MSRP), the longest rental, whether the numbers were read in the issuer&#39;s own document, and when it was last checked.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open a card under Change a card, open its official guide, correct what changed and press <b class="gd-ui">Save</b>. Changing the facts without a date marks the card checked today; type a Last checked date to record another day.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A card whose numbers come from a published summary has Read in the issuer&#39;s own document unticked and the summary&#39;s link under Where the numbers came from. The page shows it as Unverified. Tick it once you have read the issuer&#39;s guide.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add a card with the Add form; untick Shown to hide one. Changes reach the public page at once.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A card not checked for 6 months shows on Today until it is checked again. The page tells renters to confirm with their card issuer and says CarmaCars decides no claims: keep the list to facts from the issuer&#39;s guide.</div></aside></section><section class="gd-task" id="settings-reviews-review-requests-and-google" data-gd-task><h2 class="gd-h2">Reviews: review requests and Google</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Reviews</b>: when review requests go, the Google review link and the Google Business Profile connection. Review requests are on from the start.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">When review requests go: the check-out (on or off, the shortest rental, hours after the pickup), the request (minutes after the check-out), the reminder (hours) and the final follow-up (days), the sending hours (9 am to 9 pm), and the hold while charges are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The Google review link: the Google place id (Site settings) makes it, or paste the Business Profile&#39;s own review link.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Google Business Profile: press <b class="gd-ui">Connect Google</b> and sign in with rent@carmacars.ca, then allow access. Reviews are read every 6 hours and matched to renters by name within 30 days after their return.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">A clear match stops that renter&#39;s reminders at once. A possible match waits in Reviews: press <b class="gd-ui">Confirm</b>, <b class="gd-ui">Not this renter</b> or <b class="gd-ui">Match to a booking</b>.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Until Google approves the Business Profile API for the project, the status says so and nothing else changes: renters still get the review link, and &quot;I already left a review&quot;, Mark reviewed and on-site reviews still stop the messages.</div></aside><h3 class="gd-h3">Pair the card reader</h3><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Card reader</b>. On the Stripe S700, swipe from the left edge, open <b class="gd-ui">Settings</b>, then <b class="gd-ui">Generate pairing code</b>. Type the three words in <b class="gd-ui">Pairing code</b>, name the reader (Front desk) and press <b class="gd-ui">Pair reader</b>. The first time, a Stripe Terminal location is made from the mailing address in Site settings: write it as street, city, province and postal code. <b class="gd-ui">Remove</b> takes a reader off the list. Card statements read 18122211 Canada Inc., the Stripe account&#39;s statement descriptor.</p><h3 class="gd-h3">Rewards</h3><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Rewards</b>. CarmaCars Rewards is on: 1 point per dollar of the rental charge after discounts (never fees, add-ons, coverage, tax or the deposit), 100 points = $1, redeemed from 500 points as a code of the renter&#39;s own, valid 90 days. Points end 12 months after the last rental or redemption, with a reminder email 30 days before.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Ways to earn</b>: each on or off with its points. Referral (500 to the referrer, 250 to the friend, at the friend&#39;s first completed rental), a follow on Instagram, TikTok or Facebook (50 each, once, granted on the click from the Rewards page, since a follow cannot be checked; a platform shows only with its page in Site settings), a review on carmacars.ca (100, any rating; the review shows &quot;Received reward points&quot;), a Google review (100 a rental, any rating, on the renter&#39;s word: they press I posted my review and give the name on it; hidden until the Google review page is set here), a damage-free rental (200: no damage, claim, cleaning or smoking fee, back on time), the birthday (100) and the first rental (100).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Tiers</b>: Gold from 1,000 points earned in 12 months, Platinum from 15,000, Black from 60,000 (below Gold a renter is a Member). Points earned count, so using points never lowers a tier. Press <b class="gd-ui">Change</b> on a tier for its name and points. Tiers give perks, not discounts; tier codes issued before release 40 work until they end.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Perks</b>: Instant Book (Gold), Any car, any time (Platinum) and a free rental day a year (Black). Each tier keeps the perks below it. <b class="gd-ui">Change</b> a perk to move it to another tier, reword it or switch it off. <b class="gd-ui">Change the response time</b> sets how fast Fleet answers an Any car request (4 hours); the open ones are listed with their answer-by time.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Points and codes come off the rental charge only and reduce Owner Revenue like any promo code, except the Black tier&#39;s free day: CarmaCars pays for it, and the owner&#39;s payout is worked out on the price before it.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Google reviews claimed</b> lists every claim; <b class="gd-ui">Reverse</b> takes the points back with a reason. <b class="gd-ui">A renter&#39;s points</b>: find the renter, then <b class="gd-ui">Add or take off points</b> with a reason, or reverse any entry (for example, referral fraud).</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Emails and notices to renters</b>: every Rewards email, each also a notice in the renter&#39;s portal (a text only when they have no email): the welcome, points earned, a new tier, the free day, close to the next tier, points waiting, the 7-day reminder, the free day ending, the monthly statement and the birthday and holiday rewards. Each shows how many went in the last 30 days. <b class="gd-ui">Preview</b> shows the email with sample values; <b class="gd-ui">Turn off</b> stops it; <b class="gd-ui">Change</b> sets the timings or switches them all off. Marketing ones carry an unsubscribe link and never go to someone who unsubscribed.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t"><b class="gd-ui">Birthday and holiday rewards</b>: a percent off the rental charge by tier for a pickup near the renter&#39;s birthday (7 days either side) or on a holiday weekend: Platinum 10%, Black 20%; Gold is off (0%) until you give it a percent. The bigger one applies, never both, never below the car&#39;s lowest daily price, never on insurer or Owner Bookings. The request or offer keeps it. <b class="gd-ui">Change</b> a tier for its percents or to switch it off; the holidays are listed with their next weekend: <b class="gd-ui">Turn off</b>, <b class="gd-ui">Remove</b> or <b class="gd-ui">Add a holiday</b> by its date rule.</div></li></ol></div><h3 class="gd-h3">Setup checklist</h3><p class="gd-p"><b class="gd-ui">Settings</b> shows what still needs a key from one of CarmaCars&#39; own accounts. <b class="gd-ui">Add to Apple Wallet</b> stays hidden until the Apple Pass Type ID certificate is added (WALLET_PASS_CERT, WALLET_PASS_KEY, WALLET_WWDR_CERT, WALLET_PASS_TYPE_ID and WALLET_TEAM_ID in the Worker&#39;s secrets); then it shows on every confirmed booking.</p><p class="gd-p">Program: <b class="gd-ui">Call and Text buttons go through Quo</b> (on) makes every Call and Text button use the CarmaCars number in Quo (chapter Texts and calls). Off, they open the device&#39;s own phone and messages apps.</p></section><section class="gd-task" id="settings-stuck-help" data-gd-task><h2 class="gd-h2">Stuck? help</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program settings</b> &gt; <b class="gd-ui">Stuck? help</b>: turn it on or off, the minutes on a page without a successful action (3), and the errors (3) before the box offers the guide and the Academy lesson. <b class="gd-ui">Where people get stuck</b>, on the same page, lists the pages it showed on most in the last 30 days, with how often the guide and the lesson were opened.</p><h3 class="gd-h3">API access (Claude and scripts)</h3><p class="gd-p">Settings &gt; <b class="gd-ui">API access</b> connects Claude so you (or Mahad) can run CarmaCars from a Claude chat: bookings, offers, payments, refunds, returns, cars, rates, listings, owners, invoices, staff and hiring (&quot;hire Ana as customer service&quot;). <b class="gd-ui">Connect from Claude</b>: in Claude, Settings &gt; Connectors &gt; Add custom connector, paste https://carmacars.ca/api/mcp, then sign in to CarmaCars and press <b class="gd-ui">Allow</b>. Every change is two steps: Claude first shows what will change (nothing is changed yet), and does it only when you agree. Keys and connections made with every scope got the Admin scopes in release 33; a key with fewer scopes keeps them. For Claude Code or a script, <b class="gd-ui">Make a key</b>: copy it at once, it is shown only once. Each key or connection acts as its Admin, with the scopes chosen; <b class="gd-ui">Revoke</b> stops it at once. The <b class="gd-ui">Call log</b> lists every call (the previews too) with the values before and after. The database checks each action exactly as the Admin screens do.</p><h3 class="gd-h3">The logo</h3><p class="gd-p">The site, every portal, every email and the documents show the brand logo. To use another, upload it under Settings &gt; <b class="gd-ui">Site settings</b>, the Logo card (PNG or JPEG for emails and documents).</p></section><section class="gd-task" id="settings-deposits-stay-as-holds-release-28" data-gd-task><h2 class="gd-h2">Deposits stay as holds (release 28)</h2><p class="gd-p">Every deposit by card is a hold (an authorization) that stays with Stripe: it is never captured by itself, so nothing is paid out and nothing has to be refunded. Capture only what is owed, and release the rest from the booking. The booking&#39;s Security deposit panel shows Hold expires with the date Stripe gives. When a hold nears its expiry while the car is out or tickets can still come in, Finance gets a To do with <b class="gd-ui">Re-authorize the hold</b>: a new hold on the saved card, then the old one is released.</p><p class="gd-p"><b class="gd-ui">Program settings</b>: <b class="gd-ui">Extended deposit holds (up to about 30 days)</b> is on: Stripe approved it for the account. Every deposit hold (the pay link, the saved card, <b class="gd-ui">Re-authorize the hold</b>, the reader) asks for a longer authorization, about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise; a card that cannot gets the standard hold by itself. It never touches the rental payment. Capturing a deposit hold by itself is off. The heavy cleaning fee (an excessively dirty or smoked-in car) is $300 in <b class="gd-ui">Fees</b>, editable as every fee.</p></section><section class="gd-task" id="settings-updated-terms-to-accept" data-gd-task><h2 class="gd-h2">Updated terms to accept</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Updated terms</b>. When the terms of use, the privacy policy or an agreement template changes, publish the new version here; with <b class="gd-ui">Requires acceptance</b> on, each person it binds accepts it before using their portal.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Publish a version</b>. Choose the Document (the terms of use and the privacy policy bind everyone with a portal; each agreement binds the people who sign it: renters, owners, fleet suppliers, partners, investors, or staff and field).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Give the Version (for example the date it takes effect) and <b class="gd-ui">What changed</b>: people read this summary first.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paste <b class="gd-ui">The new text</b>. For the terms of use or the privacy policy, leave it empty to use the site&#39;s current text; a text you paste also replaces the site&#39;s page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Leave <b class="gd-ui">Requires acceptance</b> on and press <b class="gd-ui">Publish a version</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Everyone it binds whose account was opened before sees <b class="gd-ui">We&#39;ve updated our terms</b> full screen on their next visit, with your summary and the text, and presses Accept. The acceptance is recorded with the time, the IP address, the device and the version.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Accepted</b> on each version opens who accepted it and when.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>It is a click-through acceptance of the new version: no signed agreement is voided and no renter signs the agreement of a past booking again. An Admin account is never asked.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Every agreement is signed with the e-signature only (the identity steps, the IP address, the audit trail): a signature on paper is never recorded. Only an official ServiceOntario form, which the government requires signed in ink, is recorded from its scan.</div></aside><h3 class="gd-h3">Card processing fee for a debit deposit</h3><p class="gd-p">Program settings: <b class="gd-ui">Card processing fee for a debit deposit: percent (hundredths: 290 is 2.9%)</b> and <b class="gd-ui">Card processing fee for a debit deposit: fixed part (cents)</b> (30 is $0.30). When a deposit is charged instead of held on a debit or prepaid card, the renter pays this fee on it, as a separate non-refundable amount shown before they pay, on the receipt and on the Money tab. Set both to 0 to charge no fee.</p></section><section class="gd-task" id="settings-my-profile-and-name-changes-release-34" data-gd-task><h2 class="gd-h2">My profile and name changes (release 34)</h2><p class="gd-p">Settings &gt; <b class="gd-ui">My profile</b> has your display name, <b class="gd-ui">Request a name change</b> for your legal name, your phone number and <b class="gd-ui">Change my password</b>. When someone else asks to change the legal name on their agreements, it comes to To do with Approve and Decline, and shows on their page (owner, investor or renter). Approving changes the name on their account and record; agreements already signed keep the name they were signed with.</p></section><section class="gd-task" id="settings-ai-auto-replies-release-36" data-gd-task><h2 class="gd-h2">AI auto-replies (release 36)</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program settings</b>, the AI auto-replies group, answers common questions by itself, only from the FAQ (<b class="gd-ui">Site content</b>), within Workers AI&#39;s free daily allowance. Each channel has its switch, on by default: texts to the CarmaCars number, emails to the inboxes listed (help@in.carmacars.ca), the website live chat, WhatsApp, Facebook Page messages and Instagram messages.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A question the FAQ answers gets the answer at once. A text asked between 1 am and 5 am is answered at 5 am (the quiet hours are settings).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the FAQ does not answer it, or the model is not sure enough (70%), nothing is sent: a text stays in Messages for staff, and an email or a Meta message becomes a To do for customer service, <b class="gd-ui">Answer</b> and the question.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each person gets at most 5 automatic answers a day, never while a staff member texted them in the last 2 hours, and none once the day&#39;s free AI allowance is used.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The card <b class="gd-ui">AI auto-replies: the last answers</b> shows today&#39;s answers and the last questions, with what was sent or why not.</div></li></ol></div><p class="gd-p">Messenger, Instagram and WhatsApp need the Meta app&#39;s webhook set to https://carmacars.ca/api/webhooks/meta with the verify token shown in the settings, and the Worker secrets META_APP_SECRET (and WHATSAPP_TOKEN with the WhatsApp number id). TikTok has no inbound message path for businesses, so it is not answered.</p></section><section class="gd-task" id="settings-address-suggestions-release-36" data-gd-task><h2 class="gd-h2">Address suggestions (release 36)</h2><p class="gd-p">The address fields suggest Canadian addresses from the site&#39;s own address database (Statistics Canada&#39;s Open Database of Addresses, loaded by the addresses workflow, Ontario first). Google is asked only for what the database does not have, and only when its key is set.</p></section><section class="gd-task" id="settings-card-coverage-the-facts-the-booking-check-uses-release-35" data-gd-task><h2 class="gd-h2">Card coverage: the facts the booking check uses (release 35)</h2><p class="gd-p">Each card also has: <b class="gd-ui">Network</b> (Visa, Mastercard, American Express), <b class="gd-ui">Includes rental car damage coverage (CDW)</b> (Yes, No or Unknown), <b class="gd-ui">Vehicle types not covered</b> (comma separated: exotic, luxury, truck, van, off_road, antique, motorcycle, limousine, rv), <b class="gd-ui">Must decline the rental company&#39;s CDW</b> and <b class="gd-ui">Must pay the full rental on the card</b>. A renter on card coverage picks their card from this list; the site checks it against the car&#39;s value (the Black Book value or the estimate on the car), the car&#39;s type and the length of the rental, and refuses a card that does not cover it. Unknown sends the renter to staff review. Exotic makes are listed in <b class="gd-ui">Program</b> &gt; <b class="gd-ui">Coverage checks</b>.</p></section><section class="gd-task" id="settings-fuel-prices-and-delivery-release-35" data-gd-task><h2 class="gd-h2">Fuel prices and delivery (release 35)</h2><ul class="gd-ul"><li><b class="gd-ui">Program</b> &gt; <b class="gd-ui">Fuel and charging at the return</b>: the local pump prices of regular, premium and diesel (a litre), the multiplier (1.25), the refuelling fee ($20), the price a kWh for electric cars ($0.40), and the tank and battery sizes for a car without its own. Update the pump prices every week: <b class="gd-ui">Today</b> reminds you after 7 days.</li><li><b class="gd-ui">Airports and delivery</b> &gt; <b class="gd-ui">Delivery rate and origin</b>: the base fee each way ($75), the km it includes from the company&#39;s location (15), the rate per km after them ($2), and the straight line to road distance factor (1.3) used when the maps service gives no road distance. A car whose rate card has its own delivery or pickup fee keeps it; every other car follows the base.</li></ul></section><section class="gd-task" id="settings-automatic-answers-and-email-budgets-release-36" data-gd-task><h2 class="gd-h2">Automatic answers and email budgets (release 36)</h2><ul class="gd-ul"><li>Automatic answers: each channel (text, email, chat, social messages) switches on or off, with the quiet hours, the daily limit per person and how sure the answer must be. The last answers and the questions left for a person show in settings and under renter messages; a question it cannot answer becomes a To do. They stay inside the free daily AI allowance.</li><li>Email budgets: Settings, Usage shows the real daily email capacity of all our sending services together (Cloudflare included), and when a service is not sending, why. Receipts, signed copies and staff messages always go.</li><li>First photo: each listing chooses its first photo, the plain car, a car-show photo with a model, or a flyer with the live price; the flyer is made again when the price changes.</li><li>Rewards: points for a photo with a review and for every rental after the first; every way to earn is on the renter&#39;s Rewards page.</li></ul></section><section class="gd-task" id="settings-owner-emails-trips-and-the-week-release-41" data-gd-task><h2 class="gd-h2">Owner emails: trips and the week (release 41)</h2><p class="gd-p">Owners are not emailed when a booking comes in, is confirmed or changes, because many bookings are cancelled (owner_new_booking, owner_booking_confirmed and owner_booking_changed are off, with their texts and notices). They are emailed when a trip is complete and the car is back (owner_trip_completed: the car, dates, days, distance driven if recorded and their share, which says it shows on the next statement while the booking&#39;s revenue is hidden from them), and every Monday at about 9:00 Toronto time (owner_weekly_summary: per car, last week&#39;s trips with their share, the confirmed bookings of the next 14 days with dates only, and the month so far, provisional), only when there was activity. Only bookings that count toward the owner&#39;s revenue are used, never Owner Bookings or Turo trips. The Monday email has a switch in Program settings: <b class="gd-ui">Weekly summary email to owners</b> (on by default).</p></section><section class="gd-task" id="settings-call-helper-release-43" data-gd-task><h2 class="gd-h2">Call helper (release 43)</h2><p class="gd-p"><b class="gd-ui">Settings</b>, <b class="gd-ui">Call helper</b>: what staff read inside the caller pop-up while on a call. A change shows on the next call.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Greetings</b>: one for each kind of caller (a caller we do not know, a renter with a booking, a renter with no booking now, a lead, a car owner, a staff member). Press <b class="gd-ui">Change</b> and type what to say. <span class="gd-url">{staff}</span> becomes the first name of the person on the phone, <span class="gd-url">{caller}</span> the caller&#39;s first name, <span class="gd-url">{booking}</span> the booking number and <span class="gd-url">{car}</span> the car. A greeting that is off, or that needs a name we do not have, falls back to the one for a caller we do not know, which stays on.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Situations</b>: one button each. <b class="gd-ui">Add a situation</b> or <b class="gd-ui">Change</b>: the name on the button, then the steps, one a line (3 to 6 is best, 8 at most). Write a link to a page as <span class="gd-url">[Bookings](/bookings)</span>: an Admin gets the Admin page and staff get their own. Words in &quot;quotes&quot; are shown as what to say. <b class="gd-ui">Order</b> sets the place of the button; switch <b class="gd-ui">On</b> off to hide one, or <b class="gd-ui">Remove</b> it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Quick answers</b>: the question, the answer, and more search words staff might type.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Numbers from the settings</b>: never type an amount, a number of days or a percentage. Write its word in braces from this list, for example <span class="gd-url">{late_grace}</span> or <span class="gd-url">{deposit_tiers}</span>: staff read today&#39;s value from Program settings, Fee defaults and Deposit tiers, and it changes the day the setting does. A word in braces that is not in the list is refused when you save.</div></li></ol></div><p class="gd-p">Every change is in the audit log with the words before and after.</p></section><section class="gd-task" id="settings-texts-and-email-by-message-type-release-48" data-gd-task><h2 class="gd-h2">Texts and email by message type (release 48)</h2><p class="gd-p">Program settings, <b class="gd-ui">Texts and email by message type</b>, lists each message that can go by text with how many texts it sent in the last 30 days. Turn on <b class="gd-ui">Email ready for production</b> once Amazon SES is out of its sandbox: then only the urgent messages keep their texts (the pickup details and codes, a late return, a failed payment, a declined deposit), and every other message goes by email, by text only when the person has no email address or their email bounced. Press <b class="gd-ui">Change</b> on a row to send that message by email only, text only, or text and email (the person&#39;s choice). The deposit link, sign-in codes, staff alerts and texts typed by staff always stay texts. While the switch is off nothing changes.</p></section><section class="gd-task" id="settings-deposits-by-e-transfer-or-cash-and-tips" data-gd-task><h2 class="gd-h2">Deposits by e-Transfer or cash, and tips</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Deposit by e-Transfer or cash: a multiple of the deposit</b> (on) and its multiplier (2): a $300 deposit is $600 by e-Transfer or cash. A debit or prepaid card keeps its own multiplier. An amount set on one booking wins.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Tips</b> (on): the pay page, the receipt and the after-trip email offer 10, 15 or 20% or an amount; <b class="gd-ui">the salesperson&#39;s share</b> (5000: half, the rest to the handover).</div></li></ol></div></section>');
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
select app.guide_release_section('va', 'finance', 'chapter', 'chauffeur-requests', 'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips. There is no commission for Finance, but your help is credited on the booking (Helped by) and on your scorecard.

Your rail: Queue, Today, Money, Tolls and tickets, Turo trips, Find a renter, Calendar and Scorecard. **Money** opens with a row of tabs on top, as in Admin: **To handle** (payments, deposits, refunds), **By day** (with Today, 7 days, 30 days and 90 days), **All payments**, **Refunds**, **Deposits**, **Reconciliation** and **Unlinked Stripe** (the Stripe payments of the last 60 days that no booking knows, checked every night, with a best guess of the booking: an Admin links one from the booking''s Money tab; put one aside with the reason when it is not a booking''s payment). **Owner money** lists every owner invoice and owner statement. The old Payments by day and Reconciliation addresses open their tabs.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.](/guides/img/va-finance-01-queue-desktop-2f37513d.jpg "desktop; size: 1230 940; address: carmacars.ca/va; pins: 1 20.3 24.3")

## Payments by day

**Money**, the **By day** tab, is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.

1. Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press **Show**.
2. Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.
3. At the end of the day count the drawer and press **Record the count**. The difference shows "balanced", or "over" or "short" with the amount.
4. Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press **Approve** or **Decline** with the reason in the same row; above your limit it says an Admin approves. Approved: **Issue the refund**.
5. **Export CSV** gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.

## Payments, deposits, refunds

**Money**, the **To handle** tab.

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-486a8fbc.jpg "desktop; size: 1230 865; address: carmacars.ca/va/money; pins: 1 10.6 60.3, 2 72.4 21.6, 3 73.2 33.8, 4 11.0 45.9")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: in Rental charges press Collect (the amount) rental, or in Security deposit Collect (the amount) deposit, choose **Cash, e-Transfer or another way (record it)** and how it was paid, then record it. Each panel collects its own part only.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.


A pay link for the rental, the fees or the balance asks for what is owed and never more (release 48): the booking''s total less every payment of it, refunds counted back. After a change to the total, the link is for the difference. A booking paid in full gets no balance link: anything on top is a later charge, with its reason. A new link replaces any open one for the booking''s money, and a link still open when a payment lands is cancelled by itself (the booking history says so), so the renter is never charged twice.
## Cards, holds and deposits given back

On the booking''s Money tab.

1. After the return, **Charge the renter**: the Reason from the list (Other with its note), the Amount, and the line that says where the money comes from (the deposit hold while it is valid, else the card on file, else a pay link) before you press **Charge $...**. Before the return, Rental charges, **A later charge**, with the same reason list on the renter''s receipt. A deposit that cannot be held: Security deposit, **Charge the card on file as the deposit**.
2. A deposit hold, in the Security deposit panel: **Keep part (damage/fees)** with the amount and the reason from the list (the rest is released), or **Release**. **Hold expired**: nothing can be kept from it; press **Charge the card on file instead** (the amount and the reason are filled in). While the car is out, inside the toll window or while something is open, both wait for the settlement; an Admin may do it with the reason.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Settle a deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-out statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: an Admin keeps the whole deposit (**Keep the whole deposit (damage)**) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Money**, the **Reconciliation** tab: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")

## Deposits to release

A deposit is never released by itself. Each morning the system puts one task in your queue for every deposit due back: "Release the deposit for" the booking, with the amount and the day it is due (7 business days after the check-out, or after the return when no check-out was recorded). On the day, and every day after, you and the Admins also get a notice in the portal. Nothing is emailed.

1. Open the task: it opens the booking''s **Money** tab.
2. Settle the deposit: apply what is owed, hold back what an open item needs, release the rest.
3. The task closes by itself once nothing is left to give back.

### Card payments outside the site and the card reader
On a booking''s **Money** tab: **Record card payment** records a card taken in the Stripe Dashboard or on a reader (the last 4 digits always; a Stripe payment id, pi_..., checks it, and a deposit hold needs it). **Charge on reader** and **Hold deposit on reader** send the amount to the S700; the renter taps the card and the screen updates by itself. On a credit card coverage rental the whole rental is paid on the same card: another card is refused with the reason, and only an Admin can allow another one.

## Deposit holds and partner invoices (release 28)

Deposits stay as holds with Stripe and are never captured by itself. A job re-authorizes a hold by itself about 24 hours before it expires; when it cannot, you get the alert **Deposit hold not re-authorized**. A **The deposit hold expires soon** To do opens the booking: **Re-authorize the hold** places a new hold on the saved card and releases the old one; or **Keep part (damage/fees)** for only what is owed. A deposit not taken yet: in the Security deposit panel, **Hold on the card on file**. Under **Money** > **Partner invoices** you write invoices to body shops, tow trucks and storage yards for their kickback, send them, record the cheques and e-Transfers that come in, and export the CSV for the bookkeeper.

## Kickbacks and repairs

**Money** > **Kickbacks and repairs**: the kickbacks received on partner invoices (before HST) and the repair costs paid by CarmaCars for a period, by owner and by car, with the CSV. An invoice with no car counts nowhere until you choose it: open the invoice under **Partner invoices** and press **Choose the car**. Add a repair cost with **Add a repair cost**; Fleet adds them on the car''s page too.

### A debit deposit''s card fee
A deposit charged (not held) on a debit or prepaid card carries the non-refundable **Card processing fee for a debit deposit**, shown on its line in the history and on the receipt. The deposit refund returns the deposit only.

## Partners, the timesheet and ended trips

1. **More finance** > **Partners**: the rental partners (their pages, cars, rates, invoices) and the referral partners (kickbacks, payments), with every action an Admin has there.
2. **Hours** > **Timesheet**: the hours customer service, Fleet and Finance clocked. Add forgotten hours or void a wrong entry, with the reason.
3. **Close ended trips**: mark trips that ended and were never closed, and choose the deposit decision. An Admin presses Release; nothing is released by itself.


## Deposit review: double-check, tolls and tickets, then bill or release

Once Fleet signed every item of a returned booking you get a To do to double-check the deposit review. The deposit stays held until you signed every item too; only an Admin can release it earlier, with the reason.

1. Open **Money** > **Deposit reviews** and open the booking.
2. Press **Double-check** on each item: read Fleet''s finding and the photos, then **OK** or **Issue** with the amount to bill. Someone else double-checks an item you signed for Fleet.
3. **Highway tolls**: open the toll operator''s site from the review, search the plate for the rental dates, then double-check the item.
4. **Tickets**: open each place in the list (its official lookup link), search the plate, and press **None found** or **A ticket**. A ticket is logged in **Tolls and tickets** with the place and the plate and matched to the booking there. The Tickets item waits until every place is checked.
5. Then open **Money** on the booking: bill what is owed with the charge after the return, or release the deposit.

### The sweep, Monday, Wednesday and Friday
On each sweep day a To do **Deposit check sweep** lists every plate returned since the last sweep and every booking still inside the toll and ticket window. **Deposit reviews** > **This sweep** shows them by plate with every link, so you check them in one go. The days are in Program settings.

### Countdowns
**Money** > **Countdowns** (and the top of **To handle**, and each booking) shows the time left before each deposit hold expires (with when the automatic re-authorization runs, 24 hours before), before each deposit is due back to the renter, and before the next payment of a weekly, biweekly or monthly plan. Red is within 24 hours or late, amber within 48. Sort by any column. You get an alert at 48 and 24 hours, and the counts are in your morning digest.

### Do sales too
Under **My numbers** > **Do sales too**, press **I want to do sales too**: the Sales path is added to your academy (your Finance work is never held by it), and the Sales pages open once you pass it.


## The fuel line on the deposit review (release 35)

The fuel item shows **Suggested** with its working: the tank x the fuel missing x the pump price x 1.25, plus the $20 refuelling fee. It is a line on the return charges, never charged by itself: sign the item, then bill it with the rest from the booking''s Money. A pump receipt still wins: enter it when the car was filled up.

## Statements and payroll (release 35)

- Statements cover the 8th to the 7th, paid on the 10th; amounts not yet collected from the renter are listed apart and paid on the statement after they come in.
- Payroll every two weeks: prepare the run with any bonus or deduction and its reason, then send it for approval. An Admin approves and records the payments.
- Email: Settings, Usage shows the real daily capacity of our sending services together; nothing to count by hand.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A late return is a choice (release 42)

A car that comes back after the grace period is never charged by itself. The booking shows **Late return** with how late the car was and five choices, each with what it costs:

1. **Charge as an extension**: every started day late at the booking''s daily rate, as an extension would have cost.
2. **Charge extra days**: you choose the days, from 1 up to the started days, at the daily rate.
3. **Charge the late return fee**: the fee of the rental terms (whole days at the daily rate, the started hours after them at the hourly fee, capped a day).
4. **Charge a custom amount**: type the amount before tax and what it is for. The renter sees the reason.
5. **Waive it**: no charge, with the reason.

Press **Save the late return charge**. The charge goes on the return statement and is taken as every return charge is: from the deposit, then the card on file, then a pay link. The renter gets a message on the booking that says what was chosen, and the booking history keeps who chose and why.

Until someone chooses, nothing is charged for the late return and Fleet has the To do "Late return: choose the charge". Field staff can choose on the return screen as they complete the return.

> Good to know: A custom amount above your single limit, and a waiver by anyone other than an Admin, Finance or Fleet, waits for an Admin: they get the To do "Late return: approve the charge" and press **Approve as asked**, or choose another way. Only an Admin changes a late return that is already decided, and not once it is on a statement or paid.', 'Finance', 'Payments, deposits and refunds, tolls and tickets, reconciliation and Turo trips.',
  'You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips. There is no commission for Finance, but your help is credited on the booking (Helped by) and on your scorecard.

Your rail: Queue, Today, Money, Tolls and tickets, Turo trips, Find a renter, Calendar and Scorecard. **Money** opens with a row of tabs on top, as in Admin: **To handle** (payments, deposits, refunds), **By day** (with Today, 7 days, 30 days and 90 days), **All payments**, **Refunds**, **Deposits**, **Reconciliation** and **Unlinked Stripe** (the Stripe payments of the last 60 days that no booking knows, checked every night, with a best guess of the booking: an Admin links one from the booking''s Money tab; put one aside with the reason when it is not a booking''s payment). **Owner money** lists every owner invoice and owner statement. The old Payments by day and Reconciliation addresses open their tabs.

## Your queue

Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.

![The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.](/guides/img/va-finance-01-queue-desktop-2f37513d.jpg "desktop; size: 1230 940; address: carmacars.ca/va; pins: 1 20.3 24.3")

## Payments by day

**Money**, the **By day** tab, is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.

1. Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press **Show**.
2. Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.
3. At the end of the day count the drawer and press **Record the count**. The difference shows "balanced", or "over" or "short" with the amount.
4. Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press **Approve** or **Decline** with the reason in the same row; above your limit it says an Admin approves. Approved: **Issue the refund**.
5. **Export CSV** gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.

## Payments, deposits, refunds

**Money**, the **To handle** tab.

1. Failed payments: each with the purpose, amount and the bank''s reason.
2. Deposits to take before pickup, and deposits due back.
3. Refunds in progress. Press **Request the refund** and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then **Issue the refund**.
4. Owner invoices that failed, and owner statements to prepare.

![](/guides/img/va-finance-02-money-desktop-486a8fbc.jpg "desktop; size: 1230 865; address: carmacars.ca/va/money; pins: 1 10.6 60.3, 2 72.4 21.6, 3 73.2 33.8, 4 11.0 45.9")

## A payment received another way

An owner or renter paid by e-Transfer, cheque, cash or bank transfer.

1. Owner invoice: on **Payments, deposits, refunds**, find it under Owner invoices owing and press **Record payment**.
2. Renter: beside the failed payment, press **Paid another way**. Or open the booking''s Money tab: in Rental charges press Collect (the amount) rental, or in Security deposit Collect (the amount) deposit, choose **Cash, e-Transfer or another way (record it)** and how it was paid, then record it. Each panel collects its own part only.
3. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.
4. Add the proof if you have it (a screenshot or a photo of the cheque), then press **Record payment**.

The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.

Each month''s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.


A pay link for the rental, the fees or the balance asks for what is owed and never more (release 48): the booking''s total less every payment of it, refunds counted back. After a change to the total, the link is for the difference. A booking paid in full gets no balance link: anything on top is a later charge, with its reason. A new link replaces any open one for the booking''s money, and a link still open when a payment lands is cancelled by itself (the booking history says so), so the renter is never charged twice.
## Cards, holds and deposits given back

On the booking''s Money tab.

1. After the return, **Charge the renter**: the Reason from the list (Other with its note), the Amount, and the line that says where the money comes from (the deposit hold while it is valid, else the card on file, else a pay link) before you press **Charge $...**. Before the return, Rental charges, **A later charge**, with the same reason list on the renter''s receipt. A deposit that cannot be held: Security deposit, **Charge the card on file as the deposit**.
2. A deposit hold, in the Security deposit panel: **Keep part (damage/fees)** with the amount and the reason from the list (the rest is released), or **Release**. **Hold expired**: nothing can be kept from it; press **Charge the card on file instead** (the amount and the reason are filled in). While the car is out, inside the toll window or while something is open, both wait for the settlement; an Admin may do it with the reason.
3. A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press **Returned** with the reference or receipt number.

## Settle a deposit

The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking''s Money tab, under Deposit, press **Settle the deposit**. Issue the Check-out statement first.

1. The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.
2. Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.
3. Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.
4. Damage: an Admin keeps the whole deposit (**Keep the whole deposit (damage)**) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.
5. Press **Settle**. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.

> Good to know: A card hold lapses after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.

## Read a toll notice

1. Open **Tolls and tickets** and press **Read a notice**.
2. Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.
3. Press **Read it**. Then check each line beside the notice and fix what was read wrong.
4. Press **Checked against the notice** on each line (**Leave out** to skip one), then **Save as checked** and **Confirm and import**.

![](/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg "desktop; size: 1230 580; address: carmacars.ca/va/tolls/read; pins: 2 19.5 44.1, 3 4.1 64.8, 4 4.1 89.7")

> Tip: In the work queue, **Match again** retries the match after a fix, and **Dispute** marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.

![The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice''s plate, date, amount and match.](/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg "desktop; size: 1230 540; address: carmacars.ca/va/tolls; pins: 1 23.6 12.2")

## Reconciliation and Turo trips

1. **Money**, the **Reconciliation** tab: press **Record a processor payout**, then **Match** it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.
2. **Turo trips**: press **Add a trip** for one trip, or paste CSV rows and press **Import**.

![](/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg "desktop; size: 1230 540; address: carmacars.ca/va/turo; pins: 2 95.1 14.8")

## Deposits to release

A deposit is never released by itself. Each morning the system puts one task in your queue for every deposit due back: "Release the deposit for" the booking, with the amount and the day it is due (7 business days after the check-out, or after the return when no check-out was recorded). On the day, and every day after, you and the Admins also get a notice in the portal. Nothing is emailed.

1. Open the task: it opens the booking''s **Money** tab.
2. Settle the deposit: apply what is owed, hold back what an open item needs, release the rest.
3. The task closes by itself once nothing is left to give back.

### Card payments outside the site and the card reader
On a booking''s **Money** tab: **Record card payment** records a card taken in the Stripe Dashboard or on a reader (the last 4 digits always; a Stripe payment id, pi_..., checks it, and a deposit hold needs it). **Charge on reader** and **Hold deposit on reader** send the amount to the S700; the renter taps the card and the screen updates by itself. On a credit card coverage rental the whole rental is paid on the same card: another card is refused with the reason, and only an Admin can allow another one.

## Deposit holds and partner invoices (release 28)

Deposits stay as holds with Stripe and are never captured by itself. A job re-authorizes a hold by itself about 24 hours before it expires; when it cannot, you get the alert **Deposit hold not re-authorized**. A **The deposit hold expires soon** To do opens the booking: **Re-authorize the hold** places a new hold on the saved card and releases the old one; or **Keep part (damage/fees)** for only what is owed. A deposit not taken yet: in the Security deposit panel, **Hold on the card on file**. Under **Money** > **Partner invoices** you write invoices to body shops, tow trucks and storage yards for their kickback, send them, record the cheques and e-Transfers that come in, and export the CSV for the bookkeeper.

## Kickbacks and repairs

**Money** > **Kickbacks and repairs**: the kickbacks received on partner invoices (before HST) and the repair costs paid by CarmaCars for a period, by owner and by car, with the CSV. An invoice with no car counts nowhere until you choose it: open the invoice under **Partner invoices** and press **Choose the car**. Add a repair cost with **Add a repair cost**; Fleet adds them on the car''s page too.

### A debit deposit''s card fee
A deposit charged (not held) on a debit or prepaid card carries the non-refundable **Card processing fee for a debit deposit**, shown on its line in the history and on the receipt. The deposit refund returns the deposit only.

## Partners, the timesheet and ended trips

1. **More finance** > **Partners**: the rental partners (their pages, cars, rates, invoices) and the referral partners (kickbacks, payments), with every action an Admin has there.
2. **Hours** > **Timesheet**: the hours customer service, Fleet and Finance clocked. Add forgotten hours or void a wrong entry, with the reason.
3. **Close ended trips**: mark trips that ended and were never closed, and choose the deposit decision. An Admin presses Release; nothing is released by itself.


## Deposit review: double-check, tolls and tickets, then bill or release

Once Fleet signed every item of a returned booking you get a To do to double-check the deposit review. The deposit stays held until you signed every item too; only an Admin can release it earlier, with the reason.

1. Open **Money** > **Deposit reviews** and open the booking.
2. Press **Double-check** on each item: read Fleet''s finding and the photos, then **OK** or **Issue** with the amount to bill. Someone else double-checks an item you signed for Fleet.
3. **Highway tolls**: open the toll operator''s site from the review, search the plate for the rental dates, then double-check the item.
4. **Tickets**: open each place in the list (its official lookup link), search the plate, and press **None found** or **A ticket**. A ticket is logged in **Tolls and tickets** with the place and the plate and matched to the booking there. The Tickets item waits until every place is checked.
5. Then open **Money** on the booking: bill what is owed with the charge after the return, or release the deposit.

### The sweep, Monday, Wednesday and Friday
On each sweep day a To do **Deposit check sweep** lists every plate returned since the last sweep and every booking still inside the toll and ticket window. **Deposit reviews** > **This sweep** shows them by plate with every link, so you check them in one go. The days are in Program settings.

### Countdowns
**Money** > **Countdowns** (and the top of **To handle**, and each booking) shows the time left before each deposit hold expires (with when the automatic re-authorization runs, 24 hours before), before each deposit is due back to the renter, and before the next payment of a weekly, biweekly or monthly plan. Red is within 24 hours or late, amber within 48. Sort by any column. You get an alert at 48 and 24 hours, and the counts are in your morning digest.

### Do sales too
Under **My numbers** > **Do sales too**, press **I want to do sales too**: the Sales path is added to your academy (your Finance work is never held by it), and the Sales pages open once you pass it.


## The fuel line on the deposit review (release 35)

The fuel item shows **Suggested** with its working: the tank x the fuel missing x the pump price x 1.25, plus the $20 refuelling fee. It is a line on the return charges, never charged by itself: sign the item, then bill it with the rest from the booking''s Money. A pump receipt still wins: enter it when the car was filled up.

## Statements and payroll (release 35)

- Statements cover the 8th to the 7th, paid on the 10th; amounts not yet collected from the renter are listed apart and paid on the statement after they come in.
- Payroll every two weeks: prepare the run with any bonus or deduction and its reason, then send it for approval. An Admin approves and records the payments.
- Email: Settings, Usage shows the real daily capacity of our sending services together; nothing to count by hand.

## Calls first, texts after (release 37)

Your main priority is always to be on the phone with people.

1. Answer a ringing call before anything else, and return a missed call at once.
2. **Call before you text.** On a lead, a renter or a booking, **Call** is the first button and **Text** the second.
3. A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.
4. On your To do and on **Unanswered**, missed calls and call-backs are listed above unanswered texts.

## A late return is a choice (release 42)

A car that comes back after the grace period is never charged by itself. The booking shows **Late return** with how late the car was and five choices, each with what it costs:

1. **Charge as an extension**: every started day late at the booking''s daily rate, as an extension would have cost.
2. **Charge extra days**: you choose the days, from 1 up to the started days, at the daily rate.
3. **Charge the late return fee**: the fee of the rental terms (whole days at the daily rate, the started hours after them at the hourly fee, capped a day).
4. **Charge a custom amount**: type the amount before tax and what it is for. The renter sees the reason.
5. **Waive it**: no charge, with the reason.

Press **Save the late return charge**. The charge goes on the return statement and is taken as every return charge is: from the deposit, then the card on file, then a pay link. The renter gets a message on the booking that says what was chosen, and the booking history keeps who chose and why.

Until someone chooses, nothing is charged for the late return and Fleet has the To do "Late return: choose the charge". Field staff can choose on the return screen as they complete the return.

> Good to know: A custom amount above your single limit, and a waiver by anyone other than an Admin, Finance or Fleet, waits for an Admin: they get the To do "Late return: approve the charge" and press **Approve as asked**, or choose another way. Only an Admin changes a late return that is already decided, and not once it is on a statement or paid.

## Payments by e-Transfer or cash, deposits and tips

1. **Record a payment**: a payment of the whole total pays every line of the booking (the rental, short notice, the young driver fee, the Protection Plan), whichever part you record it for. When nothing is open, a booking waiting for payment is confirmed by itself.
2. **The deposit by e-Transfer or cash is doubled**: twice the car''s deposit by default (Program settings). The Security deposit card shows both amounts ("Credit card hold $300.00; e-Transfer or cash $600.00 (2x)"), and the renter sees them on the offer and the pay page before paying.
3. **Collect the deposit** > Cash or e-Transfer: leave the amount empty to take what is owed. Less is recorded as a part (the card says **under, still owed $X** and **Collect the $X still owed** takes the rest); more is held and given back with the deposit (**over, to return $X**).
4. **Change the deposit** on Edit booking (an Admin, with the reason), even while the booking waits for payment: the Money tab, the deposit link and Collect $X deposit follow at once.
5. **Voided a deposit by mistake?** After the void the deposit is **Not collected** again everywhere (the header too): record it again.
6. **Tips**: the renter can add one when paying, on the receipt and from the after-trip email. A tip in cash or by e-Transfer: **Tips** > **Record a tip**. Half goes to the booking''s salesperson and half to the staff member at the handover; with no staff salesperson (a direct booking) CarmaCars keeps that half; one person who did both gets it all. An Admin can give one tip another split (**All to ...**, **Back to the usual split**). A tip is never part of the rental or the owner''s share.
7. A greyed-out button says under it what to do first.
',
  '<p class="gd-p">You keep the money right: payments, deposits and refunds, toll notices, processor payouts and Turo trips. There is no commission for Finance, but your help is credited on the booking (Helped by) and on your scorecard.</p><p class="gd-p">Your rail: Queue, Today, Money, Tolls and tickets, Turo trips, Find a renter, Calendar and Scorecard. <b class="gd-ui">Money</b> opens with a row of tabs on top, as in Admin: <b class="gd-ui">To handle</b> (payments, deposits, refunds), <b class="gd-ui">By day</b> (with Today, 7 days, 30 days and 90 days), <b class="gd-ui">All payments</b>, <b class="gd-ui">Refunds</b>, <b class="gd-ui">Deposits</b>, <b class="gd-ui">Reconciliation</b> and <b class="gd-ui">Unlinked Stripe</b> (the Stripe payments of the last 60 days that no booking knows, checked every night, with a best guess of the booking: an Admin links one from the booking&#39;s Money tab; put one aside with the reason when it is not a booking&#39;s payment). <b class="gd-ui">Owner money</b> lists every owner invoice and owner statement. The old Payments by day and Reconciliation addresses open their tabs.</p><section class="gd-task" id="finance-your-queue" data-gd-task><h2 class="gd-h2">Your queue</h2><p class="gd-p">Finance tasks include failed owner debits, toll notices with no match, statements to review and refunds to issue.</p><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/940"><img src="/guides/img/va-finance-01-queue-desktop-2f37513d.jpg" alt="The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below." loading="lazy" decoding="async" width="1230" height="940"><span class="gd-pin" style="left:20.3%;top:24.3%" aria-hidden="true">1</span></div></div><figcaption>The lanes show what Finance handles: payments to fix, refunds waiting, tolls and tickets, deposits to settle and owner statements. Money today counts them below.</figcaption></figure></div></section><section class="gd-task" id="finance-payments-by-day" data-gd-task><h2 class="gd-h2">Payments by day</h2><p class="gd-p"><b class="gd-ui">Money</b>, the <b class="gd-ui">By day</b> tab, is your day in one screen: every payment and refund, by method, with the cash drawer and the refunds to decide.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose From and To (today by default) and tick the methods you want (card, e-Transfer, cash, cheque, platform payout, insurer and others; none ticked shows all), then press <b class="gd-ui">Show</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Totals by method: received, refunded and net. Each day: the same by method, the cash expected in the drawer (cash received less cash given back) and the cash counted.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">At the end of the day count the drawer and press <b class="gd-ui">Record the count</b>. The difference shows &quot;balanced&quot;, or &quot;over&quot; or &quot;short&quot; with the amount.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Refunds waiting: every refund asked for anywhere (a cancellation, a booking, Finance), with the policy maths (paid, the tier, the percentage back, what is kept). Press <b class="gd-ui">Approve</b> or <b class="gd-ui">Decline</b> with the reason in the same row; above your limit it says an Admin approves. Approved: <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Export CSV</b> gives the same rows for the bank or the bookkeeper: refunds as negative amounts, holds marked as not money in.</div></li></ol></div></section><section class="gd-task" id="finance-payments-deposits-refunds" data-gd-task><h2 class="gd-h2">Payments, deposits, refunds</h2><p class="gd-p"><b class="gd-ui">Money</b>, the <b class="gd-ui">To handle</b> tab.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Failed payments: each with the purpose, amount and the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Deposits to take before pickup, and deposits due back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Refunds in progress. Press <b class="gd-ui">Request the refund</b> and choose What it refunds (the rental charge, delivery or pickup, kilometres, add-ons or other charges); above your limit it waits for an Admin. Then <b class="gd-ui">Issue the refund</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owner invoices that failed, and owner statements to prepare.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/money</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/865"><img src="/guides/img/va-finance-02-money-desktop-486a8fbc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="865"><span class="gd-pin" style="left:10.6%;top:60.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.4%;top:21.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:73.2%;top:33.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:11%;top:45.9%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="finance-a-payment-received-another-way" data-gd-task><h2 class="gd-h2">A payment received another way</h2><p class="gd-p">An owner or renter paid by e-Transfer, cheque, cash or bank transfer.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Owner invoice: on <b class="gd-ui">Payments, deposits, refunds</b>, find it under Owner invoices owing and press <b class="gd-ui">Record payment</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Renter: beside the failed payment, press <b class="gd-ui">Paid another way</b>. Or open the booking&#39;s Money tab: in Rental charges press Collect (the amount) rental, or in Security deposit Collect (the amount) deposit, choose <b class="gd-ui">Cash, e-Transfer or another way (record it)</b> and how it was paid, then record it. Each panel collects its own part only.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance; type less for a partial payment.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Add the proof if you have it (a screenshot or a photo of the cheque), then press <b class="gd-ui">Record payment</b>.</div></li></ol></div><p class="gd-p">The invoice is marked paid or partly paid, the automatic debit stops for that amount and the owner gets a receipt. Above your single limit the payment needs an Admin. Recorded something wrong? Ask an Admin to void it; you cannot void a payment.</p><p class="gd-p">Each month&#39;s payments recorded by hand are listed under Reconciliation, with the totals by method, to check against the bank.</p><p class="gd-p">A pay link for the rental, the fees or the balance asks for what is owed and never more (release 48): the booking&#39;s total less every payment of it, refunds counted back. After a change to the total, the link is for the difference. A booking paid in full gets no balance link: anything on top is a later charge, with its reason. A new link replaces any open one for the booking&#39;s money, and a link still open when a payment lands is cancelled by itself (the booking history says so), so the renter is never charged twice.</p></section><section class="gd-task" id="finance-cards-holds-and-deposits-given-back" data-gd-task><h2 class="gd-h2">Cards, holds and deposits given back</h2><p class="gd-p">On the booking&#39;s Money tab.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">After the return, <b class="gd-ui">Charge the renter</b>: the Reason from the list (Other with its note), the Amount, and the line that says where the money comes from (the deposit hold while it is valid, else the card on file, else a pay link) before you press <b class="gd-ui">Charge $...</b>. Before the return, Rental charges, <b class="gd-ui">A later charge</b>, with the same reason list on the renter&#39;s receipt. A deposit that cannot be held: Security deposit, <b class="gd-ui">Charge the card on file as the deposit</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">A deposit hold, in the Security deposit panel: <b class="gd-ui">Keep part (damage/fees)</b> with the amount and the reason from the list (the rest is released), or <b class="gd-ui">Release</b>. <b class="gd-ui">Hold expired</b>: nothing can be kept from it; press <b class="gd-ui">Charge the card on file instead</b> (the amount and the reason are filled in). While the car is out, inside the toll window or while something is open, both wait for the settlement; an Admin may do it with the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A deposit taken in cash or by e-Transfer is given back the same way: the task Give the deposit back the way it came; then press <b class="gd-ui">Returned</b> with the reference or receipt number.</div></li></ol></div></section><section class="gd-task" id="finance-settle-a-deposit" data-gd-task><h2 class="gd-h2">Settle a deposit</h2><p class="gd-p">The deposit is never given back by itself. Finance or an Admin settles it after the return: on the booking&#39;s Money tab, under Deposit, press <b class="gd-ui">Settle the deposit</b>. Issue the Check-out statement first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The form shows the deposit, what is still available, the charges owed from the statement and what is taken from the deposit for them. What the deposit does not cover is charged to the card on file; with no card (or a card declined), the renter gets a pay link by email and text, and Finance has a task until it is paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Tolls and tickets can take up to 7 days to come in. Inside that window the whole rest of the deposit is filled in as the hold-back, until the window ends. To give it back sooner, tick Release now anyway: a toll that comes in later is charged to the card on file.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something still open keeps the whole deposit: an incident, a claim, new damage at the return not priced, damage found later not billed, a toll or ticket on the car during the rental not matched or not charged, a card dispute, or charges not on a statement yet. The form lists them. Only an Admin can release part of it, with the reason; it is recorded.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Damage: an Admin keeps the whole deposit (<b class="gd-ui">Keep the whole deposit (damage)</b>) or bills a damage charge up to the $2,500 deductible. Ask an Admin, with the photos.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Settle</b>. The money moves at Stripe at once: the charges are collected and what is not owed is refunded or the hold released. A step Stripe refuses is tried again by itself, and Finance gets a task if it keeps failing.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A card hold lapses after about 30 days on Visa, Mastercard, Amex and Discover cards, and about 7 days otherwise. While the car is out, or returned and not settled, the hold is collected in full a day and a half before it lapses: that keeps the money, and the settlement refunds what is not owed. A hold that lapses anyway is charged to the saved card, and Finance is told at once.</div></aside></section><section class="gd-task" id="finance-read-a-toll-notice" data-gd-task><h2 class="gd-h2">Read a toll notice</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Tolls and tickets</b> and press <b class="gd-ui">Read a notice</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the file: a PDF, a photo or a CSV, under 15 MB. Leave the reading profile to find it from the text.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Read it</b>. Then check each line beside the notice and fix what was read wrong.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Checked against the notice</b> on each line (<b class="gd-ui">Leave out</b> to skip one), then <b class="gd-ui">Save as checked</b> and <b class="gd-ui">Confirm and import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls/read</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/580"><img src="/guides/img/va-finance-04-tolls-read-desktop-aa04a6b2.jpg" alt="" loading="lazy" decoding="async" width="1230" height="580"><span class="gd-pin" style="left:19.5%;top:44.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:4.1%;top:64.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:4.1%;top:89.7%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>In the work queue, <b class="gd-ui">Match again</b> retries the match after a fix, and <b class="gd-ui">Dispute</b> marks a notice you think is wrong. Renters matched with high confidence are charged at import, with the notice and our fee.</div></aside><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/tolls</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-03-tolls-desktop-37b6f99c.jpg" alt="The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match." loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:23.6%;top:12.2%" aria-hidden="true">1</span></div></div><figcaption>The work queue: Unmatched, Needs review, Matched not charged and Disputed, with each notice&#39;s plate, date, amount and match.</figcaption></figure></div></section><section class="gd-task" id="finance-reconciliation-and-turo-trips" data-gd-task><h2 class="gd-h2">Reconciliation and Turo trips</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Money</b>, the <b class="gd-ui">Reconciliation</b> tab: press <b class="gd-ui">Record a processor payout</b>, then <b class="gd-ui">Match</b> it to the payments it contains. Anything still unmatched at the closing check goes to an Admin.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Turo trips</b>: press <b class="gd-ui">Add a trip</b> for one trip, or paste CSV rows and press <b class="gd-ui">Import</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/turo</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/540"><img src="/guides/img/va-finance-06-turo-desktop-b59cc7f9.jpg" alt="" loading="lazy" decoding="async" width="1230" height="540"><span class="gd-pin" style="left:95.1%;top:14.8%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="finance-deposits-to-release" data-gd-task><h2 class="gd-h2">Deposits to release</h2><p class="gd-p">A deposit is never released by itself. Each morning the system puts one task in your queue for every deposit due back: &quot;Release the deposit for&quot; the booking, with the amount and the day it is due (7 business days after the check-out, or after the return when no check-out was recorded). On the day, and every day after, you and the Admins also get a notice in the portal. Nothing is emailed.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the task: it opens the booking&#39;s <b class="gd-ui">Money</b> tab.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Settle the deposit: apply what is owed, hold back what an open item needs, release the rest.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The task closes by itself once nothing is left to give back.</div></li></ol></div><h3 class="gd-h3">Card payments outside the site and the card reader</h3><p class="gd-p">On a booking&#39;s <b class="gd-ui">Money</b> tab: <b class="gd-ui">Record card payment</b> records a card taken in the Stripe Dashboard or on a reader (the last 4 digits always; a Stripe payment id, pi_..., checks it, and a deposit hold needs it). <b class="gd-ui">Charge on reader</b> and <b class="gd-ui">Hold deposit on reader</b> send the amount to the S700; the renter taps the card and the screen updates by itself. On a credit card coverage rental the whole rental is paid on the same card: another card is refused with the reason, and only an Admin can allow another one.</p></section><section class="gd-task" id="finance-deposit-holds-and-partner-invoices-release-28" data-gd-task><h2 class="gd-h2">Deposit holds and partner invoices (release 28)</h2><p class="gd-p">Deposits stay as holds with Stripe and are never captured by itself. A job re-authorizes a hold by itself about 24 hours before it expires; when it cannot, you get the alert <b class="gd-ui">Deposit hold not re-authorized</b>. A <b class="gd-ui">The deposit hold expires soon</b> To do opens the booking: <b class="gd-ui">Re-authorize the hold</b> places a new hold on the saved card and releases the old one; or <b class="gd-ui">Keep part (damage/fees)</b> for only what is owed. A deposit not taken yet: in the Security deposit panel, <b class="gd-ui">Hold on the card on file</b>. Under <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Partner invoices</b> you write invoices to body shops, tow trucks and storage yards for their kickback, send them, record the cheques and e-Transfers that come in, and export the CSV for the bookkeeper.</p></section><section class="gd-task" id="finance-kickbacks-and-repairs" data-gd-task><h2 class="gd-h2">Kickbacks and repairs</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Kickbacks and repairs</b>: the kickbacks received on partner invoices (before HST) and the repair costs paid by CarmaCars for a period, by owner and by car, with the CSV. An invoice with no car counts nowhere until you choose it: open the invoice under <b class="gd-ui">Partner invoices</b> and press <b class="gd-ui">Choose the car</b>. Add a repair cost with <b class="gd-ui">Add a repair cost</b>; Fleet adds them on the car&#39;s page too.</p><h3 class="gd-h3">A debit deposit&#39;s card fee</h3><p class="gd-p">A deposit charged (not held) on a debit or prepaid card carries the non-refundable <b class="gd-ui">Card processing fee for a debit deposit</b>, shown on its line in the history and on the receipt. The deposit refund returns the deposit only.</p></section><section class="gd-task" id="finance-partners-the-timesheet-and-ended-trips" data-gd-task><h2 class="gd-h2">Partners, the timesheet and ended trips</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">More finance</b> &gt; <b class="gd-ui">Partners</b>: the rental partners (their pages, cars, rates, invoices) and the referral partners (kickbacks, payments), with every action an Admin has there.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Hours</b> &gt; <b class="gd-ui">Timesheet</b>: the hours customer service, Fleet and Finance clocked. Add forgotten hours or void a wrong entry, with the reason.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Close ended trips</b>: mark trips that ended and were never closed, and choose the deposit decision. An Admin presses Release; nothing is released by itself.</div></li></ol></div></section><section class="gd-task" id="finance-deposit-review-double-check-tolls-and-tickets-then-bill-or-r" data-gd-task><h2 class="gd-h2">Deposit review: double-check, tolls and tickets, then bill or release</h2><p class="gd-p">Once Fleet signed every item of a returned booking you get a To do to double-check the deposit review. The deposit stays held until you signed every item too; only an Admin can release it earlier, with the reason.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Money</b> &gt; <b class="gd-ui">Deposit reviews</b> and open the booking.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Double-check</b> on each item: read Fleet&#39;s finding and the photos, then <b class="gd-ui">OK</b> or <b class="gd-ui">Issue</b> with the amount to bill. Someone else double-checks an item you signed for Fleet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Highway tolls</b>: open the toll operator&#39;s site from the review, search the plate for the rental dates, then double-check the item.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Tickets</b>: open each place in the list (its official lookup link), search the plate, and press <b class="gd-ui">None found</b> or <b class="gd-ui">A ticket</b>. A ticket is logged in <b class="gd-ui">Tolls and tickets</b> with the place and the plate and matched to the booking there. The Tickets item waits until every place is checked.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Then open <b class="gd-ui">Money</b> on the booking: bill what is owed with the charge after the return, or release the deposit.</div></li></ol></div><h3 class="gd-h3">The sweep, Monday, Wednesday and Friday</h3><p class="gd-p">On each sweep day a To do <b class="gd-ui">Deposit check sweep</b> lists every plate returned since the last sweep and every booking still inside the toll and ticket window. <b class="gd-ui">Deposit reviews</b> &gt; <b class="gd-ui">This sweep</b> shows them by plate with every link, so you check them in one go. The days are in Program settings.</p><h3 class="gd-h3">Countdowns</h3><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Countdowns</b> (and the top of <b class="gd-ui">To handle</b>, and each booking) shows the time left before each deposit hold expires (with when the automatic re-authorization runs, 24 hours before), before each deposit is due back to the renter, and before the next payment of a weekly, biweekly or monthly plan. Red is within 24 hours or late, amber within 48. Sort by any column. You get an alert at 48 and 24 hours, and the counts are in your morning digest.</p><h3 class="gd-h3">Do sales too</h3><p class="gd-p">Under <b class="gd-ui">My numbers</b> &gt; <b class="gd-ui">Do sales too</b>, press <b class="gd-ui">I want to do sales too</b>: the Sales path is added to your academy (your Finance work is never held by it), and the Sales pages open once you pass it.</p></section><section class="gd-task" id="finance-the-fuel-line-on-the-deposit-review-release-35" data-gd-task><h2 class="gd-h2">The fuel line on the deposit review (release 35)</h2><p class="gd-p">The fuel item shows <b class="gd-ui">Suggested</b> with its working: the tank x the fuel missing x the pump price x 1.25, plus the $20 refuelling fee. It is a line on the return charges, never charged by itself: sign the item, then bill it with the rest from the booking&#39;s Money. A pump receipt still wins: enter it when the car was filled up.</p></section><section class="gd-task" id="finance-statements-and-payroll-release-35" data-gd-task><h2 class="gd-h2">Statements and payroll (release 35)</h2><ul class="gd-ul"><li>Statements cover the 8th to the 7th, paid on the 10th; amounts not yet collected from the renter are listed apart and paid on the statement after they come in.</li><li>Payroll every two weeks: prepare the run with any bonus or deduction and its reason, then send it for approval. An Admin approves and records the payments.</li><li>Email: Settings, Usage shows the real daily capacity of our sending services together; nothing to count by hand.</li></ul></section><section class="gd-task" id="finance-calls-first-texts-after-release-37" data-gd-task><h2 class="gd-h2">Calls first, texts after (release 37)</h2><p class="gd-p">Your main priority is always to be on the phone with people.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Answer a ringing call before anything else, and return a missed call at once.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Call before you text.</b> On a lead, a renter or a booking, <b class="gd-ui">Call</b> is the first button and <b class="gd-ui">Text</b> the second.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A text is a follow-up: after a call attempt (no answer, a voicemail left), or when the person asked for a text.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your To do and on <b class="gd-ui">Unanswered</b>, missed calls and call-backs are listed above unanswered texts.</div></li></ol></div></section><section class="gd-task" id="finance-a-late-return-is-a-choice-release-42" data-gd-task><h2 class="gd-h2">A late return is a choice (release 42)</h2><p class="gd-p">A car that comes back after the grace period is never charged by itself. The booking shows <b class="gd-ui">Late return</b> with how late the car was and five choices, each with what it costs:</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Charge as an extension</b>: every started day late at the booking&#39;s daily rate, as an extension would have cost.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Charge extra days</b>: you choose the days, from 1 up to the started days, at the daily rate.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Charge the late return fee</b>: the fee of the rental terms (whole days at the daily rate, the started hours after them at the hourly fee, capped a day).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Charge a custom amount</b>: type the amount before tax and what it is for. The renter sees the reason.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Waive it</b>: no charge, with the reason.</div></li></ol></div><p class="gd-p">Press <b class="gd-ui">Save the late return charge</b>. The charge goes on the return statement and is taken as every return charge is: from the deposit, then the card on file, then a pay link. The renter gets a message on the booking that says what was chosen, and the booking history keeps who chose and why.</p><p class="gd-p">Until someone chooses, nothing is charged for the late return and Fleet has the To do &quot;Late return: choose the charge&quot;. Field staff can choose on the return screen as they complete the return.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>A custom amount above your single limit, and a waiver by anyone other than an Admin, Finance or Fleet, waits for an Admin: they get the To do &quot;Late return: approve the charge&quot; and press <b class="gd-ui">Approve as asked</b>, or choose another way. Only an Admin changes a late return that is already decided, and not once it is on a statement or paid.</div></aside></section><section class="gd-task" id="finance-payments-by-e-transfer-or-cash-deposits-and-tips" data-gd-task><h2 class="gd-h2">Payments by e-Transfer or cash, deposits and tips</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Record a payment</b>: a payment of the whole total pays every line of the booking (the rental, short notice, the young driver fee, the Protection Plan), whichever part you record it for. When nothing is open, a booking waiting for payment is confirmed by itself.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">The deposit by e-Transfer or cash is doubled</b>: twice the car&#39;s deposit by default (Program settings). The Security deposit card shows both amounts (&quot;Credit card hold $300.00; e-Transfer or cash $600.00 (2x)&quot;), and the renter sees them on the offer and the pay page before paying.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t"><b class="gd-ui">Collect the deposit</b> &gt; Cash or e-Transfer: leave the amount empty to take what is owed. Less is recorded as a part (the card says <b class="gd-ui">under, still owed $X</b> and <b class="gd-ui">Collect the $X still owed</b> takes the rest); more is held and given back with the deposit (<b class="gd-ui">over, to return $X</b>).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Change the deposit</b> on Edit booking (an Admin, with the reason), even while the booking waits for payment: the Money tab, the deposit link and Collect $X deposit follow at once.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Voided a deposit by mistake?</b> After the void the deposit is <b class="gd-ui">Not collected</b> again everywhere (the header too): record it again.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Tips</b>: the renter can add one when paying, on the receipt and from the after-trip email. A tip in cash or by e-Transfer: <b class="gd-ui">Tips</b> &gt; <b class="gd-ui">Record a tip</b>. Half goes to the booking&#39;s salesperson and half to the staff member at the handover; with no staff salesperson (a direct booking) CarmaCars keeps that half; one person who did both gets it all. An Admin can give one tip another split (<b class="gd-ui">All to ...</b>, <b class="gd-ui">Back to the usual split</b>). A tip is never part of the rental or the owner&#39;s share.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">A greyed-out button says under it what to do first.</div></li></ol></div></section>');
select app.guide_release_section('va', 'commissions', 'chapter', 'add-a-rental-by-hand', 'Sales (and field staff) earn a commission on the rentals they source: a renter you found yourself. Say so when you enter the rental, the quote or the offer. Customer service, Fleet and Finance earn no commission and no sales credit: your help is credited on the booking (Helped by) and on your scorecard.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay. By the rental days of the month, on all of that month''s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales) |
| Customer service, Fleet, Finance | No commission and no sales credit, whichever you choose above. Your help is credited as Helped by on the booking and counted on your scorecard |
| An owner you bring in (Sales) | What you ask for and an Admin approves: a flat amount at the owner''s first paid rental, or a percent of their cars'' rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner''s revenue |
| How much | The rate on the rental charge before tax, after discounts, with late extra days, plus the add-ons (release 35: the same rate on each confirmed add-on''s own charge before tax; not prepaid fuel). Never on delivery, kilometres, young driver, the Protection Plan or other fees. Only a refund of the rental charge, or an add-on removed after booking, comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.
', 'Commissions', 'I sourced this client, your rate, when it is earned, approved and paid.',
  'Sales (and field staff) earn a commission on the rentals they source: a renter you found yourself. Say so when you enter the rental, the quote or the offer. Customer service, Fleet and Finance earn no commission and no sales credit: your help is credited on the booking (Helped by) and on your scorecard.

## Mark who found the client

Every rental, quote and offer you enter asks: **I sourced this client** or **Entered for CarmaCars**.

1. Choose **I sourced this client** when you found the renter yourself: someone you know, your own post or your own outreach.
2. Choose **Entered for CarmaCars** when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.
3. A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.

|  | Commission |
| --- | --- |
| Sales | Commission only, with no base pay. By the rental days of the month, on all of that month''s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales) |
| Customer service, Fleet, Finance | No commission and no sales credit, whichever you choose above. Your help is credited as Helped by on the booking and counted on your scorecard |
| An owner you bring in (Sales) | What you ask for and an Admin approves: a flat amount at the owner''s first paid rental, or a percent of their cars'' rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner''s revenue |
| How much | The rate on the rental charge before tax, after discounts, with late extra days, plus the add-ons (release 35: the same rate on each confirmed add-on''s own charge before tax; not prepaid fuel). Never on delivery, kilometres, young driver, the Protection Plan or other fees. Only a refund of the rental charge, or an add-on removed after booking, comes off |
| When earned | When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental |
| Your home address | It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client |
| Paid | After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed |

> Tip: A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.

## Your tips

**My sales** shows **My tips**: your share of each tip, half when you sold the rental, half when you did the handover, all of it when you did both. Paid with your pay.
',
  '<p class="gd-p">Sales (and field staff) earn a commission on the rentals they source: a renter you found yourself. Say so when you enter the rental, the quote or the offer. Customer service, Fleet and Finance earn no commission and no sales credit: your help is credited on the booking (Helped by) and on your scorecard.</p><section class="gd-task" id="commissions-mark-who-found-the-client" data-gd-task><h2 class="gd-h2">Mark who found the client</h2><p class="gd-p">Every rental, quote and offer you enter asks: <b class="gd-ui">I sourced this client</b> or <b class="gd-ui">Entered for CarmaCars</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose <b class="gd-ui">I sourced this client</b> when you found the renter yourself: someone you know, your own post or your own outreach.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose <b class="gd-ui">Entered for CarmaCars</b> when the renter came to CarmaCars: the website, the phone line, a walk-in, a partner.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A website request earns nothing by itself. If you sourced it anyway, choose I sourced this client on its offer: an Admin decides.</div></li></ol></div><div class="gd-tablewrap" tabindex="0" role="region" aria-label="Table"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>Commission only, with no base pay. By the rental days of the month, on all of that month&#39;s rentals: in person under 50 days 10%, from 50 days 15%, from 100 days 20%; remote 5%, 10% and 15%, one tier lower in a month under 400 touches (chapter Sales)</td></tr><tr><td>Customer service, Fleet, Finance</td><td>No commission and no sales credit, whichever you choose above. Your help is credited as Helped by on the booking and counted on your scorecard</td></tr><tr><td>An owner you bring in (Sales)</td><td>What you ask for and an Admin approves: a flat amount at the owner&#39;s first paid rental, or a percent of their cars&#39; rentals for a time (chapter Sales). A CarmaCars expense: it never changes the owner&#39;s revenue</td></tr><tr><td>How much</td><td>The rate on the rental charge before tax, after discounts, with late extra days, plus the add-ons (release 35: the same rate on each confirmed add-on&#39;s own charge before tax; not prepaid fuel). Never on delivery, kilometres, young driver, the Protection Plan or other fees. Only a refund of the rental charge, or an add-on removed after booking, comes off</td></tr><tr><td>When earned</td><td>When the rental is completed and paid in full. Never on a cancelled, refunded, unpaid or charged-back rental, or on your own or a household rental</td></tr><tr><td>Your home address</td><td>It must be in your profile. Until it is, a commission waits as not earned yet, and you cannot add a rental or mark I sourced this client</td></tr><tr><td>Paid</td><td>After an Admin approves it, by transfer or on your pay statement. My sales shows each step: not earned yet, pending approval, approved, paid, reversed</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A refund or chargeback after a commission was paid comes off your next payment. Your staff agreement has the full rule.</div></aside></section><section class="gd-task" id="commissions-your-tips" data-gd-task><h2 class="gd-h2">Your tips</h2><p class="gd-p"><b class="gd-ui">My sales</b> shows <b class="gd-ui">My tips</b>: your share of each tip, half when you sold the rental, half when you did the handover, all of it when you did both. Paid with your pay.</p></section>');
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
select app.guide_release_section('field', 'my-hours-and-pay', 'chapter', 'photo-shoots', 'Jobs are put on shifts: claim a shift and its jobs are yours. Your hours are paid every two weeks at your hourly rate (CA$18.00 an hour unless your agreement says another rate), with the commissions an Admin has approved.

## My shifts

Shifts are published by themselves, up to 14 days ahead: one shift of 10:00 to 17:00 every second day, and a shift of its own for a handover or return no shift covers. Fleet may add or cancel shifts too.

1. **Free to claim**: shifts someone gave up (first to claim takes it) and open shifts. Each shows the jobs already on it, for example "On it: 3 pickups, 1 return, 2 cleans". Press **Claim this shift**: its jobs are yours on **Today** and here. You can claim once you passed the academy.
2. **Coming up**: your shifts, each with the shift''s jobs and the work planned for you. It updates as bookings come in. Sharing a shift? Its jobs are split between you, least busy first; the others'' show on **Today** under **Also on your shift**, and **Take it** takes one.
3. Cannot work one? Press **Give this shift up** and say why. It is offered at once to everyone free then, and its jobs go with it to whoever claims it. Under 24 hours before the start it is marked late on your record.
4. **Swap with someone**: choose their shift and press **Ask for the swap**. They press **Accept the swap** or **Decline**. Each of you takes the other shift''s jobs.
5. **Past shifts**: each day with your hours, the jobs, the photos and the money you spent.
6. **Money you spent**: each one with where it stands. No receipt yet? Take the photo and press **Add the receipt**.

## Clock in and out

Clock in and out on **Today**, with your shift. Forgot to clock out, or a time is wrong? Tell Fleet: they fix it, say why, and the change is written in a log.

## Pay details

Before your first pay, **My pay** asks for your pay details: your full legal name, email, phone, SIN and a photo of a void cheque. Press **Save my pay details**. Your SIN is kept encrypted: only Finance and Admin can see it, every look is recorded, and you see only its last 3 digits. How you are paid (bank, e-Transfer) is just below.

## Your pay and your pay statements

A pay period is two weeks, Sunday to Saturday. An Admin runs the pay after it ends.

1. The pay is your hours times your hourly rate, plus the commissions and referral fees an Admin approved by the end of the period (see Commissions). Overtime and vacation pay are added only if CarmaCars has switched them on.
2. An Admin approves the pay run, pays you (by e-Transfer, bank transfer or cash) and records it. You get an email with the amount and how you were paid.
3. Under Pay statements on **My pay**, press **PDF** for the statement of a period: your hours day by day, the amounts, the commissions in it and how it was paid.

> Tip: A pay statement shows no income tax, CPP or EI. They are not worked out in the portal: for your tax slips, ask CarmaCars or your accountant.

## Where you clock in and out

The phone asks for your location once when you clock in and once when you clock out, and never in between. Allow it. If it is off, or you are more than 500 m from the lot, you can still clock in or out: write why in the box that appears, and Fleet sees it.

## Availability, standing shifts and the minimum (release 35)

1. Set when you can work (mornings, afternoons and evenings for each weekday, plus a note) on Welcome; change it later on My shifts or Profile.
2. My shifts opens as a week calendar: tap a shift to claim it. The cards are on the List tab.
3. A standing weekly shift, such as every Saturday 10 to 6, claims each matching published shift by itself up to two weeks ahead. Drop one date (the give-up rules apply) or end it.
4. Hold at least the minimum (2 shifts in 7 days by default). Under it, you get a daily reminder and a To do.
5. Pay stubs come every two weeks under My pay, with a PDF and an email once paid.', 'My shifts and My pay', 'Claim, give up and swap shifts, what you did on each, your hours, pay statements and pay details.',
  'Jobs are put on shifts: claim a shift and its jobs are yours. Your hours are paid every two weeks at your hourly rate (CA$18.00 an hour unless your agreement says another rate), with the commissions an Admin has approved.

## My shifts

Shifts are published by themselves, up to 14 days ahead: one shift of 10:00 to 17:00 every second day, and a shift of its own for a handover or return no shift covers. Fleet may add or cancel shifts too.

1. **Free to claim**: shifts someone gave up (first to claim takes it) and open shifts. Each shows the jobs already on it, for example "On it: 3 pickups, 1 return, 2 cleans". Press **Claim this shift**: its jobs are yours on **Today** and here. You can claim once you passed the academy.
2. **Coming up**: your shifts, each with the shift''s jobs and the work planned for you. It updates as bookings come in. Sharing a shift? Its jobs are split between you, least busy first; the others'' show on **Today** under **Also on your shift**, and **Take it** takes one.
3. Cannot work one? Press **Give this shift up** and say why. It is offered at once to everyone free then, and its jobs go with it to whoever claims it. Under 24 hours before the start it is marked late on your record.
4. **Swap with someone**: choose their shift and press **Ask for the swap**. They press **Accept the swap** or **Decline**. Each of you takes the other shift''s jobs.
5. **Past shifts**: each day with your hours, the jobs, the photos and the money you spent.
6. **Money you spent**: each one with where it stands. No receipt yet? Take the photo and press **Add the receipt**.

## Clock in and out

Clock in and out on **Today**, with your shift. Forgot to clock out, or a time is wrong? Tell Fleet: they fix it, say why, and the change is written in a log.

## Pay details

Before your first pay, **My pay** asks for your pay details: your full legal name, email, phone, SIN and a photo of a void cheque. Press **Save my pay details**. Your SIN is kept encrypted: only Finance and Admin can see it, every look is recorded, and you see only its last 3 digits. How you are paid (bank, e-Transfer) is just below.

## Your pay and your pay statements

A pay period is two weeks, Sunday to Saturday. An Admin runs the pay after it ends.

1. The pay is your hours times your hourly rate, plus the commissions and referral fees an Admin approved by the end of the period (see Commissions). Overtime and vacation pay are added only if CarmaCars has switched them on.
2. An Admin approves the pay run, pays you (by e-Transfer, bank transfer or cash) and records it. You get an email with the amount and how you were paid.
3. Under Pay statements on **My pay**, press **PDF** for the statement of a period: your hours day by day, the amounts, the commissions in it and how it was paid.

> Tip: A pay statement shows no income tax, CPP or EI. They are not worked out in the portal: for your tax slips, ask CarmaCars or your accountant.

## Where you clock in and out

The phone asks for your location once when you clock in and once when you clock out, and never in between. Allow it. If it is off, or you are more than 500 m from the lot, you can still clock in or out: write why in the box that appears, and Fleet sees it.

## Availability, standing shifts and the minimum (release 35)

1. Set when you can work (mornings, afternoons and evenings for each weekday, plus a note) on Welcome; change it later on My shifts or Profile.
2. My shifts opens as a week calendar: tap a shift to claim it. The cards are on the List tab.
3. A standing weekly shift, such as every Saturday 10 to 6, claims each matching published shift by itself up to two weeks ahead. Drop one date (the give-up rules apply) or end it.
4. Hold at least the minimum (2 shifts in 7 days by default). Under it, you get a daily reminder and a To do.
5. Pay stubs come every two weeks under My pay, with a PDF and an email once paid.

## Your tips

**My pay** shows **My tips**: your half of each tip on a car you handed over (all of it when you also sold the rental). A tip given to you in cash: tell the office, they record it on the booking''s Money tab.
',
  '<p class="gd-p">Jobs are put on shifts: claim a shift and its jobs are yours. Your hours are paid every two weeks at your hourly rate (CA$18.00 an hour unless your agreement says another rate), with the commissions an Admin has approved.</p><section class="gd-task" id="my-hours-and-pay-my-shifts" data-gd-task><h2 class="gd-h2">My shifts</h2><p class="gd-p">Shifts are published by themselves, up to 14 days ahead: one shift of 10:00 to 17:00 every second day, and a shift of its own for a handover or return no shift covers. Fleet may add or cancel shifts too.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Free to claim</b>: shifts someone gave up (first to claim takes it) and open shifts. Each shows the jobs already on it, for example &quot;On it: 3 pickups, 1 return, 2 cleans&quot;. Press <b class="gd-ui">Claim this shift</b>: its jobs are yours on <b class="gd-ui">Today</b> and here. You can claim once you passed the academy.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Coming up</b>: your shifts, each with the shift&#39;s jobs and the work planned for you. It updates as bookings come in. Sharing a shift? Its jobs are split between you, least busy first; the others&#39; show on <b class="gd-ui">Today</b> under <b class="gd-ui">Also on your shift</b>, and <b class="gd-ui">Take it</b> takes one.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Cannot work one? Press <b class="gd-ui">Give this shift up</b> and say why. It is offered at once to everyone free then, and its jobs go with it to whoever claims it. Under 24 hours before the start it is marked late on your record.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Swap with someone</b>: choose their shift and press <b class="gd-ui">Ask for the swap</b>. They press <b class="gd-ui">Accept the swap</b> or <b class="gd-ui">Decline</b>. Each of you takes the other shift&#39;s jobs.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t"><b class="gd-ui">Past shifts</b>: each day with your hours, the jobs, the photos and the money you spent.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t"><b class="gd-ui">Money you spent</b>: each one with where it stands. No receipt yet? Take the photo and press <b class="gd-ui">Add the receipt</b>.</div></li></ol></div></section><section class="gd-task" id="my-hours-and-pay-clock-in-and-out" data-gd-task><h2 class="gd-h2">Clock in and out</h2><p class="gd-p">Clock in and out on <b class="gd-ui">Today</b>, with your shift. Forgot to clock out, or a time is wrong? Tell Fleet: they fix it, say why, and the change is written in a log.</p></section><section class="gd-task" id="my-hours-and-pay-pay-details" data-gd-task><h2 class="gd-h2">Pay details</h2><p class="gd-p">Before your first pay, <b class="gd-ui">My pay</b> asks for your pay details: your full legal name, email, phone, SIN and a photo of a void cheque. Press <b class="gd-ui">Save my pay details</b>. Your SIN is kept encrypted: only Finance and Admin can see it, every look is recorded, and you see only its last 3 digits. How you are paid (bank, e-Transfer) is just below.</p></section><section class="gd-task" id="my-hours-and-pay-your-pay-and-your-pay-statements" data-gd-task><h2 class="gd-h2">Your pay and your pay statements</h2><p class="gd-p">A pay period is two weeks, Sunday to Saturday. An Admin runs the pay after it ends.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The pay is your hours times your hourly rate, plus the commissions and referral fees an Admin approved by the end of the period (see Commissions). Overtime and vacation pay are added only if CarmaCars has switched them on.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">An Admin approves the pay run, pays you (by e-Transfer, bank transfer or cash) and records it. You get an email with the amount and how you were paid.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Under Pay statements on <b class="gd-ui">My pay</b>, press <b class="gd-ui">PDF</b> for the statement of a period: your hours day by day, the amounts, the commissions in it and how it was paid.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A pay statement shows no income tax, CPP or EI. They are not worked out in the portal: for your tax slips, ask CarmaCars or your accountant.</div></aside></section><section class="gd-task" id="my-hours-and-pay-where-you-clock-in-and-out" data-gd-task><h2 class="gd-h2">Where you clock in and out</h2><p class="gd-p">The phone asks for your location once when you clock in and once when you clock out, and never in between. Allow it. If it is off, or you are more than 500 m from the lot, you can still clock in or out: write why in the box that appears, and Fleet sees it.</p></section><section class="gd-task" id="my-hours-and-pay-availability-standing-shifts-and-the-minimum-release-35" data-gd-task><h2 class="gd-h2">Availability, standing shifts and the minimum (release 35)</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Set when you can work (mornings, afternoons and evenings for each weekday, plus a note) on Welcome; change it later on My shifts or Profile.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">My shifts opens as a week calendar: tap a shift to claim it. The cards are on the List tab.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A standing weekly shift, such as every Saturday 10 to 6, claims each matching published shift by itself up to two weeks ahead. Drop one date (the give-up rules apply) or end it.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Hold at least the minimum (2 shifts in 7 days by default). Under it, you get a daily reminder and a To do.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Pay stubs come every two weeks under My pay, with a PDF and an email once paid.</div></li></ol></div></section><section class="gd-task" id="my-hours-and-pay-your-tips" data-gd-task><h2 class="gd-h2">Your tips</h2><p class="gd-p"><b class="gd-ui">My pay</b> shows <b class="gd-ui">My tips</b>: your half of each tip on a car you handed over (all of it when you also sold the rental). A tip given to you in cash: tell the office, they record it on the booking&#39;s Money tab.</p></section>');
-- GUIDES 3113 END

-- CATALOGUE 3113 START (generated by supabase/seed/3113_gen.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('staff_access_restored', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars access is back', 'You can sign in again.', 'Immediate, once', 'An Admin restored a suspended staff account (Unlock on Staff, or approving the person''s restore request; release 48, migration 3113). Sent once.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"sign_in_url","type":"url"}]'::jsonb, 'templates/staff_access_restored.html', 'templates/staff_access_restored.txt'),
  ('staff_access_suspended', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'You no longer have access to CarmaCars', 'Click here to restore it.', 'Immediate, once', 'A staff account (never an Admin) was suspended: no use of the staff portal for the days of Program settings (5 by default), or two weekly townhalls missed in a row (release 48, migration 3113). Sent once per suspension. While suspended this is the only kind of message the person gets (with the restored email), nothing else.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"restore_url","type":"url"}]'::jsonb, 'templates/staff_access_suspended.html', 'templates/staff_access_suspended.txt'),
  ('staff_inactivity_warning', 'staff_field', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'Your CarmaCars staff access ends on {{lock_on}}', 'Sign in before then to keep it.', 'On the warning day, once', 'A staff account (never an Admin) has had no sign-in or use of the staff portal for the warning days of Program settings (3 by default since release 48, migration 3113; 7 before). Sent once per idle stretch.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"days_idle","type":"string"},{"name":"first_name","type":"string"},{"name":"lock_days","type":"string"},{"name":"lock_on","type":"string"},{"name":"sign_in_url","type":"url"}]'::jsonb, 'templates/staff_inactivity_warning.html', 'templates/staff_inactivity_warning.txt'),
  ('text_fell_back', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'A message from CarmaCars', '{{message_body}}', 'Immediate, once per text', 'A text CarmaCars meant to send could not go (the texting service refused it, for example when its prepaid credits ran out) and the person has an email address: the same words come by email instead, once, and the text is marked "not sent: fell back to email" (release 48, migration 3113). A text whose own email already went, or that is no longer relevant, is never sent this way.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"message_body","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/text_fell_back.html', 'templates/text_fell_back.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
update notification_catalogue set emitted_by = 'app.text_fall_back (3113)', no_text = true where code = 'text_fell_back';
update notification_catalogue set emitted_by = 'app.staff_suspension_mail (3113)' where code in ('staff_access_suspended', 'staff_access_restored');
select app.notification_catalogue_refresh();
-- CATALOGUE 3113 END
