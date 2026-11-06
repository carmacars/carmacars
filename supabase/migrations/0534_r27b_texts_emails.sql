-- 0534 (hotfix r27b, 2026-11-06, docs/changes/2026-11-06-r27b-load-texts-emails.md)
-- 1. A text from a Text button is sent once, however often Send is pressed: the dialog sends one key per text
--    (p.key); the outbox row carries it as its dedupe key. A second try of a text already sent answers "sent" without
--    sending; one being sent right now answers "being sent"; one that failed (Quo refused it) is sent again.
-- 2. Cloudflare email first, for real: Resend's daily limits held every email until Cloudflare had sent once in the last
--    day, and Cloudflare was only tried for emails the claim released, so after one refusal (14:11 UTC) nothing reached
--    Cloudflare again and 213 emails waited for midnight. Now Resend's limits hold nothing while Cloudflare may send
--    (switched on, its day's budget of 200 and the month's 3,000 not used, no refusal in the last 15 minutes), and an
--    email held by a limit waits 15 minutes, not until midnight, while Cloudflare still has budget today. The emails
--    held now go out at once.
-- No applied migration is edited.

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if (length(d) - length(replace(d, p_old, ''))) / greatest(length(p_old), 1) <> 1 then
    raise exception '0534: the text to change is not found exactly once in %: %', p_sig, left(p_old, 120);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. one text per key
create or replace function app.phone_compose(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_number text := app.phone_e164(p ->> 'number');
  v_body text := btrim(coalesce(p ->> 'body', ''));
  v_booking uuid := app.phone_booking_of(p);
  v_key text := nullif(btrim(coalesce(p ->> 'key', '')), '');
  v_dedupe text;
  t phone_threads;
  o phone_outbox;
begin
  if v_number is null then raise exception 'That is not a phone number we can text' using errcode = '22023'; end if;
  if not app.phone_button_ok(p_by, v_number) then raise exception 'You can text the people of your work only' using errcode = '42501'; end if;
  if v_body = '' then raise exception 'Write the text first' using errcode = '22023'; end if;
  if length(v_body) > 1600 then raise exception 'A text is at most 1,600 characters' using errcode = '22023'; end if;
  if v_key is not null and v_key !~ '^[A-Za-z0-9-]{8,64}$' then raise exception 'Close the dialog and write the text again' using errcode = '22023'; end if;
  if not (app.settings()).phone_enabled then raise exception 'Phone and texts are off in Program settings' using errcode = '23514'; end if;
  t := app.phone_thread_for(v_number);
  if t.opted_out_at is not null then raise exception 'This number opted out of texts. They can text START to allow them again.' using errcode = '23514'; end if;
  if v_key is not null then
    v_dedupe := 'compose:' || p_by::text || ':' || v_key;
    select * into o from phone_outbox where dedupe_key = v_dedupe for update;
    if o.id is not null then
      if o.status = 'sent' then
        return jsonb_build_object('ok', true, 'thread_id', o.thread_id, 'already', true, 'note', 'It had already gone; it was not sent twice.');
      end if;
      if o.status = 'sending' and o.locked_at > now() - interval '2 minutes' then
        return jsonb_build_object('ok', true, 'thread_id', o.thread_id, 'pending', true, 'note', 'It is being sent now; it was not sent twice.');
      end if;
      if o.status = 'sending' then
        raise exception 'We could not confirm that this text went. Check the conversation, then close this dialog and write it again if it is not there.' using errcode = '23514';
      end if;
      if o.status = 'skipped' then raise exception '%', coalesce(o.status_reason, 'This text cannot be sent') using errcode = '23514'; end if;
      -- it failed (Quo refused it) or waits: sent again now, with the text as it is now
      update phone_outbox set status = 'sending', locked_at = now(), body = left(v_body, 1600), last_error = null, send_after = now()
       where id = o.id returning * into o;
      return jsonb_build_object('ok', true, 'thread_id', o.thread_id, 'retry', true, 'send', jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body), 'from', app.phone_our_number());
    end if;
  end if;
  o := app.phone_outbox_put(t.number, v_body, 'staff', coalesce(v_booking, t.booking_id), t.renter_id, null, null, v_dedupe, now(), 'sending', p_by);
  if o.status = 'skipped' then raise exception '%', coalesce(o.status_reason, 'This text cannot be sent') using errcode = '23514'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'phone_compose', 'phone_threads', t.id::text, jsonb_build_object('outbox', o.id, 'booking', v_booking, 'chars', length(v_body)));
  return jsonb_build_object('ok', true, 'thread_id', t.id, 'send', jsonb_build_object('id', o.id, 'to', o.to_number, 'body', o.body), 'from', app.phone_our_number());
end $$;

-- ================================================================ 2. Cloudflare email first, held emails soon
create or replace function app.cf_emails_today(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  select app.cf_emails_between(app.local_midnight(app.local_date(p_now)), p_now + interval '1 second')
$$;

-- Resend's limits are lifted while Cloudflare may send and has budget left today (0531: 200 a day). Before 0534 they
-- were lifted only after a Cloudflare send in the last day, which never came once the claim held every email.
create or replace function app.cf_email_available(p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.cf_email_try(p_now) and app.cf_emails_today(p_now) < coalesce((select s.notify_cf_daily_budget from app.settings(app.local_date(p_now)) s), 200)
$$;

-- How long an email held by a daily limit waits: 15 minutes while Cloudflare is switched on with budget left today and
-- this month (it may be resting after a refusal), else until midnight.
create or replace function app.email_hold_until(p_now timestamptz, p_midnight timestamptz) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case when coalesce(s.cf_email_enabled, false)
                   and app.cf_emails_today(p_now) < s.notify_cf_daily_budget
                   and app.cf_emails_between(app.local_midnight(app.month_start(app.local_date(p_now))), p_now + interval '1 second') < s.cf_email_monthly_included
              then least(p_midnight, p_now + interval '15 minutes') else p_midnight end
    from app.settings(app.local_date(p_now)) s
$$;

select pg_temp.patch_fn('app.outbox_claim_0018(integer, timestamptz)'::regprocedure,
  $o$send_after = v_midnight$o$,
  $n$send_after = case when r.category = 'marketing' and v_mkt >= s.notify_marketing_daily_max then v_midnight else app.email_hold_until(p_now, v_midnight) end$n$);

revoke all on function app.cf_emails_today(timestamptz), app.email_hold_until(timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function app.cf_emails_today(timestamptz), app.email_hold_until(timestamptz, timestamptz) to service_role;

-- the emails held now (by the daily limit, or by the sender's "budget used" before Cloudflare could send) go out at once
update notification_outbox
   set send_after = now()
 where status = 'delayed' and send_after > now()
   and status_reason in ('daily email limit', 'the day''s email budget is used', 'the email provider''s daily limit');

-- ================================================================ 3. the public pages' reads never take the whole pool
-- November 6: scrapers' page renders held all 20 PostgREST connections (place_hub, the vehicle pages, the vehicle
-- sitemaps), and the Admin portal and sign-in could not get one. The heavy public reads now take one of
-- app.public_slots() slots (a transaction advisory lock) or are refused at once with 53400 ("busy"): the Worker then
-- serves the page's kept copy or its busy page, and the other connections stay free for staff, sign-in and bookings.
create or replace function app.public_slots() returns integer
language sql immutable as $$ select 8 $$;

create or replace function app.public_slot() returns void
language plpgsql security definer set search_path = public, app as $$
declare i integer;
begin
  -- the server itself (jobs, the deploy's checks) is never limited
  if coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') = 'service_role' then return; end if;
  for i in 1 .. app.public_slots() loop
    if pg_try_advisory_xact_lock(534000, i) then return; end if;
  end loop;
  raise exception 'The site is busy right now' using errcode = '53400', hint = 'public read slots in use';
end $$;
revoke all on function app.public_slot(), app.public_slots() from public, anon, authenticated;
grant execute on function app.public_slot(), app.public_slots() to service_role;

do $do$
declare
  f record;
  v_args text;
  v_call text;
  v_grants text[];
  g text;
begin
  for f in select p.oid, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('place_hub', 'vehicle_tier_page', 'vehicle_trim_page', 'vehicle_year_page', 'vehicle_model_page',
                                                         'vehicle_tier_sitemap', 'vehicle_sitemap')
              and pg_get_function_result(p.oid) = 'jsonb' loop
    v_args := pg_get_function_arguments(f.oid);
    select string_agg(quote_ident(a), ', ' order by o) into v_call from unnest((select proargnames from pg_proc where oid = f.oid)) with ordinality x(a, o);
    v_grants := array(select r from unnest(array['anon', 'authenticated', 'service_role']) r where has_function_privilege(r, f.oid, 'execute'));
    execute format('alter function public.%I(%s) rename to %I', f.proname, pg_get_function_identity_arguments(f.oid), f.proname || '_unslotted');
    execute format('alter function public.%I(%s) set schema app', f.proname || '_unslotted', pg_get_function_identity_arguments(f.oid));
    execute format('revoke all on function app.%I(%s) from public, anon, authenticated', f.proname || '_unslotted', pg_get_function_identity_arguments(f.oid));
    execute format('grant execute on function app.%I(%s) to service_role', f.proname || '_unslotted', pg_get_function_identity_arguments(f.oid));
    execute format($f$create function public.%I(%s) returns jsonb language plpgsql stable security definer set search_path = public, app as $b$
      begin perform app.public_slot(); return app.%I(%s); end $b$$f$, f.proname, v_args, f.proname || '_unslotted', coalesce(v_call, ''));
    execute format('revoke all on function public.%I(%s) from public', f.proname, pg_get_function_identity_arguments(f.oid));
    foreach g in array v_grants loop
      execute format('grant execute on function public.%I(%s) to %I', f.proname, pg_get_function_identity_arguments(f.oid), g);
    end loop;
  end loop;
end $do$;
