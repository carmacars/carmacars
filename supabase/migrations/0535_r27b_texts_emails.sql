-- 0535 (hotfix r27b, 2026-11-06, docs/changes/2026-11-06-r27b-load-texts-emails.md)
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
    raise exception '0535: the text to change is not found exactly once in %: %', p_sig, left(p_old, 120);
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

-- Resend's limits are lifted while Cloudflare may send and has budget left today (0531: 200 a day). Before 0535 they
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

-- ================================================================ 4. remote applicants: the AI interview, never a call to book
-- The owner (November 6): every remote assistant applicant (customer service, fleet, finance, remote sales) still
-- "Invited" to book a call, or whose booked call time passed without the call (the Thursday November 5 calls), gets the
-- AI interview link once, with an apology for the scheduling problem on our side (applicant_ai_interview_sorry, through
-- the outbox: normal priority, paced, Cloudflare first). A past booked call is marked No show first, without an email.
-- From now on a remote applicant who passes screening gets only the AI interview (0380's hiring_emit, the setting on), and
-- the "invited but no interview day is open" warning leaves the remote roles out. In-person roles are unchanged.
-- CATALOGUE 0535 START (generated by supabase/seed/0535_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('applicant_ai_interview_sorry', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'CarmaCars: sorry about the interview times, here is your interview link', 'No need to book a call: do the short recorded interview any time before {{expires_on}}.', 'Once', 'Once, by migration 0535 (the owner, November 6, 2026): a candidate for a remote assistant role (customer service, fleet, finance or remote sales) who was invited to book a call, or whose booked call time passed without the call, is moved to the AI interview: an apology for the scheduling problem on our side and the personal link to the recorded interview. No booking needed.', null, null, '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"expires_on","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"interview_url","type":"url"},{"name":"minutes","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"question_count","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/applicant_ai_interview_sorry.html', 'templates/applicant_ai_interview_sorry.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0535 END
update notification_catalogue set emitted_by = 'app.hiring_remote_to_ai, run once by migration 0535' where code = 'applicant_ai_interview_sorry';

create table if not exists hiring_ai_moves (
  application_id uuid primary key references job_applications (id) on delete cascade,
  from_status    text not null,
  slot_at        timestamptz,
  moved_at       timestamptz not null default now(),
  outbox_event   bigint
);
comment on table hiring_ai_moves is 'Hiring (0535): remote applicants moved from a call to book (or a booked call that passed) to the AI interview, each once, with the apology email.';
alter table hiring_ai_moves enable row level security;
revoke all on hiring_ai_moves from anon, authenticated;
grant all on hiring_ai_moves to service_role;
drop policy if exists admin_read on hiring_ai_moves;
create policy admin_read on hiring_ai_moves for select to authenticated using (app.is_admin());
drop trigger if exists audit_hiring_ai_moves on hiring_ai_moves;
create trigger audit_hiring_ai_moves after insert or update or delete on hiring_ai_moves for each row execute function app.audit_row();

create or replace function app.hiring_remote_to_ai(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  iv ai_interviews;
  v_from text;
  v_slot timestamptz;
  v_ev bigint;
  n integer := 0;
  v_days integer := (app.settings()).hiring_ai_interview_days;
begin
  if not coalesce((app.settings()).hiring_ai_interviews, false) then return 0; end if;
  for a in select j.* from job_applications j join hiring_roles r on r.id = j.role_id
            where r.remote and r.staff_kind = 'va' and j.purged_at is null and nullif(btrim(coalesce(j.email, '')), '') is not null
              and (j.status = 'invited' or (j.status = 'booked' and exists (select 1 from interview_slots s where s.id = j.slot_id and s.starts_at < p_now)))
              and not exists (select 1 from ai_interviews i where i.application_id = j.id)
              and not exists (select 1 from hiring_ai_moves m where m.application_id = j.id)
            for update of j skip locked loop
    v_from := a.status;
    select s.starts_at into v_slot from interview_slots s where s.id = a.slot_id;
    if a.status = 'booked' then
      -- the call that passed: No show first (no email), the slot given back
      update job_applications set status = 'no_show', updated_at = p_now where id = a.id;
      insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
      values (null, 'hiring_no_show_auto', 'job_applications', a.id::text, jsonb_build_object('slot_at', v_slot, 'by', 'migration 0535'));
    end if;
    update job_applications set status = 'invited', invited_at = coalesce(invited_at, p_now), slot_id = null, waiting_for_day = false, no_slots_since = null,
           decided_at = null, decided_by = null, updated_at = p_now
     where id = a.id returning * into a;
    insert into ai_interviews (application_id, role_id, questions, expires_at)
    values (a.id, a.role_id, app.ai_interview_questions(a.role_id), p_now + make_interval(days => greatest(v_days, 7)))
    returning * into iv;
    v_ev := app.hiring_emit_pre0211('applicant_ai_interview_sorry', a, app.ai_interview_vars(a, iv), 'applicant_ai_interview_sorry:' || a.id);
    insert into hiring_ai_moves (application_id, from_status, slot_at, moved_at, outbox_event) values (a.id, v_from, v_slot, p_now, v_ev);
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (null, 'hiring_remote_to_ai', 'job_applications', a.id::text, jsonb_build_object('from', v_from, 'by', 'migration 0535'));
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function app.hiring_remote_to_ai(timestamptz) from public, anon, authenticated;
grant execute on function app.hiring_remote_to_ai(timestamptz) to service_role;

-- the warning "invited but no interview day is open": the remote assistant roles take the AI interview, never a day
create or replace function app.hiring_waiting_by_role() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', r.slug, 'title', r.title, 'short_title', r.short_title, 'count', x.n) order by r.sort_order, r.title), '[]'::jsonb)
    from hiring_roles r
    join lateral (select count(*)::int n from job_applications j where j.role_id = r.id and j.status = 'invited' and j.purged_at is null
                     and not exists (select 1 from ai_interviews i where i.application_id = j.id and i.state in ('sent', 'started', 'expired'))) x on x.n > 0
   where not app.hiring_open_slots(r.id)
     and not (r.remote and r.staff_kind = 'va' and coalesce((app.settings()).hiring_ai_interviews, false))
$$;

-- the owner's decision: AI interviews on, and the move now (once)
update program_settings set hiring_ai_interviews = true where not hiring_ai_interviews;
do $$ begin raise notice '0535: % remote applicants moved to the AI interview', app.hiring_remote_to_ai(); end $$;
