-- 0213: the deposit hold link texted before every pickup (Release 21b, owner request). SCHEMA_MARKER 0213.
-- docs/changes/2026-11-01-deposit-link-text.md.
--   A confirmed booking whose deposit is a card hold, with no hold yet: the deposit job (the Worker's five-minute tick,
--   public.server_jobs_due "deposits") makes the same payment request as Money > Collect a card > The deposit hold (kind
--   hold, covers deposit, payment_requests.auto) and texts its /pay link to the renter's mobile from the CarmaCars number,
--   site_settings.deposit_link_hours (24) before pickup, or at once when the pickup is sooner. On by default
--   (site_settings.deposit_link_auto). One live request per booking and deposit amount: skipped when a hold is placed, the
--   deposit is waived or taken another way, or a live hold request (any channel) exists; an expired one, or one for an
--   older amount, is replaced. No mobile, or the text not sent: a task "Deposit link not sent" for the booking's staff and
--   the Admins. The Money tab says "Deposit link texted <time>" (and opened); the ready check shows it too. The hold is
--   still required before the keys, as before.
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

alter table site_settings add column if not exists deposit_link_auto boolean not null default true;
alter table site_settings add column if not exists deposit_link_hours integer not null default 24 check (deposit_link_hours between 1 and 168);
comment on column site_settings.deposit_link_auto is 'Deposit link by text (0213): before each pickup, the deposit hold link is texted to the renter when no hold is placed yet.';
comment on column site_settings.deposit_link_hours is 'Deposit link by text (0213): how many hours before pickup the link goes (at once when the pickup is sooner).';

alter table payment_requests add column if not exists auto boolean not null default false;
alter table payment_requests add column if not exists texted_at timestamptz;
alter table payment_requests add column if not exists text_id uuid references phone_outbox (id) on delete set null;
alter table payment_requests add column if not exists opened_at timestamptz;
comment on column payment_requests.auto is 'Made by the deposit link job (0213), not by a staff member.';
comment on column payment_requests.texted_at is 'When the link was texted to the renter (0213).';
comment on column payment_requests.opened_at is 'When the renter first opened the pay link (0213).';

-- the booking still needs its deposit hold placed by card
create or replace function app.deposit_link_needed(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select b.status = 'confirmed' and b.deposit_pay_method = 'card' and coalesce(b.deposit_cents, 0) > 0 and b.booking_type <> 'owner'
     and b.deposit_waived_at is null and b.pickup_at > now() and b.renter_id is not null
     and coalesce(b.billable_days, 0) <= coalesce((app.settings()).deposit_hold_max_days, 0)
     and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured', 'settled'))
     and not exists (select 1 from payments p where p.booking_id = b.id and p.purpose = 'deposit' and p.status = 'succeeded')
$$;

-- a live hold request for the booking's deposit (any channel, by staff or by the job)
create or replace function app.deposit_link_live(b bookings) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from payment_requests q where q.booking_id = b.id and q.kind = 'hold' and q.status = 'open' and q.expires_at > now()
                    and q.amount_cents = b.deposit_cents)
$$;

create or replace function app.deposit_links_due(p_limit integer default 20) returns setof bookings
language sql stable security definer set search_path = public, app as $$
  select b.* from bookings b, site_settings ss
   where ss.singleton and ss.deposit_link_auto and b.status = 'confirmed' and b.deposit_pay_method = 'card'
     and b.pickup_at > now() and b.pickup_at - make_interval(hours => ss.deposit_link_hours) <= now()
     and app.deposit_link_needed(b) and not app.deposit_link_live(b)
   order by b.pickup_at limit greatest(p_limit, 1)
$$;

create or replace function public.server_deposit_links_due() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number)), '[]'::jsonb) from app.deposit_links_due(20) b
$$;

-- the request, as Money > Collect a card > The deposit hold makes it (stale ones replaced)
create or replace function public.server_deposit_link_payreq(p_booking uuid, p_token_sha256 text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or not app.deposit_link_needed(b) then return jsonb_build_object('ok', false, 'reason', 'not needed'); end if;
  if app.deposit_link_live(b) then return jsonb_build_object('ok', false, 'reason', 'a live request exists'); end if;
  if p_token_sha256 is null or p_token_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'The link token is missing' using errcode = '22023'; end if;
  update payment_requests set status = 'cancelled', last_error = coalesce(last_error, 'Replaced by a new deposit link')
   where booking_id = b.id and kind = 'hold' and status = 'open';
  insert into payment_requests (booking_id, renter_id, kind, covers, amount_cents, token_sha256, channel, expires_at, created_by, auto)
  values (b.id, b.renter_id, 'hold', 'deposit', b.deposit_cents, p_token_sha256, 'text', greatest(b.pickup_at + interval '1 day', now() + interval '1 day'), null, true)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'booking_id', b.id, 'booking_number', b.booking_number, 'amount_cents', b.deposit_cents,
    'renter', (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', coalesce(r.email, u.email),
                 'customer_id', (select sc.processor_customer_id from payment_methods pm join payment_method_secrets sc on sc.payment_method_id = pm.id
                                  where pm.renter_id = r.id and sc.processor_customer_id is not null order by pm.created_at desc limit 1))
                 from renters r left join users u on u.id = r.user_id where r.id = b.renter_id));
end $$;

-- the in-app notice of a deposit link not sent (no email: it may be the daily limit)
insert into notification_catalogue (code, audience, also_sent_to, category, subject, preheader, has_email, priority, emitted_by, link_path)
values ('staff_deposit_link_not_sent', 'staff_admin', array['staff_va_cs'], 'transactional', 'Deposit link not sent: {{booking_number}}',
        'Send it or call the renter before pickup.', false, 3, 'app.deposit_link_problem (0213)', null)
on conflict (code) do nothing;

-- "Deposit link not sent": a task for the booking's staff, and the Admins told
create or replace function app.deposit_link_problem(q payment_requests, p_why text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_staff uuid;
  v_user uuid;
  s program_settings := app.settings();
begin
  select * into b from bookings where id = q.booking_id;
  perform app.raise_task(p_type => 'staff_task', p_title => 'Deposit link not sent: ' || b.booking_number,
    p_detail => format('The deposit hold link (%s) could not be texted to the renter: %s. Send it from the booking''s Money tab (Collect a card, The deposit hold) or call the renter before pickup on %s.',
                       app.fmt_money(q.amount_cents), p_why, app.fmt_date(b.pickup_at)),
    p_booking => b.id, p_renter => b.renter_id, p_related_table => 'payment_requests', p_related_id => q.id,
    p_due_at => greatest(now(), b.pickup_at - interval '2 hours'), p_priority => 'high', p_dedupe => 'deposit_link_not_sent:' || q.id, p_queue => 'cs');
  v_staff := coalesce(b.sales_claim_by, case when app.user_is_staff(b.created_by) then b.created_by end);
  for v_user in select u.id from users u join user_roles ur on ur.user_id = u.id and ur.role = 'admin' where u.status = 'active'
                union select v_staff where v_staff is not null loop
    insert into notifications (user_id, code, title, body, url, dedupe_key)
    values (v_user, 'staff_deposit_link_not_sent', 'Deposit link not sent: ' || b.booking_number,
            format('The deposit hold link could not be texted (%s). Send it or call the renter before pickup.', p_why),
            rtrim(s.notify_base_url, '/') || '/admin/bookings/' || b.booking_number, 'deposit_link_not_sent:' || q.id || '|' || v_user)
    on conflict (dedupe_key) do nothing;
  end loop;
end $$;

-- the text, from the CarmaCars number
create or replace function public.server_deposit_link_send(p_id uuid, p_link text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  q payment_requests;
  b bookings;
  rn renters;
  o phone_outbox;
  v_to text;
begin
  select * into q from payment_requests where id = p_id for update;
  if q.id is null or q.status <> 'open' or not q.auto then raise exception 'That deposit link is not open' using errcode = '23514'; end if;
  if p_link is null or p_link !~ '^https?://[^ ]+/pay/[A-Za-z0-9_-]{20,}$'
     or encode(sha256(convert_to(regexp_replace(p_link, '^.*/pay/', ''), 'UTF8')), 'hex') <> q.token_sha256 then
    raise exception 'That link is not this request''s' using errcode = '22023';
  end if;
  if q.texted_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  select * into b from bookings where id = q.booking_id;
  select * into rn from renters where id = b.renter_id;
  v_to := app.phone_e164(rn.mobile);
  if v_to is null then
    perform app.deposit_link_problem(q, 'no mobile number on file');
    update payment_requests set last_error = 'No mobile number on file' where id = q.id;
    return jsonb_build_object('ok', false, 'reason', 'no mobile');
  end if;
  o := app.phone_outbox_put(v_to, format('CarmaCars: booking %s, pickup %s at %s. Please place the deposit hold of %s before pickup (it is released after the rental): %s',
                                         b.booking_number, app.fmt_date(b.pickup_at), app.fmt_time(b.pickup_at), app.fmt_money(q.amount_cents), p_link),
                            'booking', b.id, rn.id, 'deposit_link', null, 'deposit_link:' || q.id, now());
  update phone_outbox set urgent = true where id = o.id;
  if o.status = 'skipped' then
    perform app.deposit_link_problem(q, coalesce(o.status_reason, 'the text was not sent'));
    update payment_requests set last_error = left(coalesce(o.status_reason, 'The text was not sent'), 300), text_id = o.id where id = q.id;
    return jsonb_build_object('ok', false, 'reason', o.status_reason);
  end if;
  update payment_requests set texted_at = now(), text_id = o.id where id = q.id;
  return jsonb_build_object('ok', true, 'to', app.phone_display(o.to_number));
end $$;

-- a deposit link text that fails at Quo: the same task
create or replace function app.deposit_link_text_failed() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare q payment_requests;
begin
  if new.sms_kind = 'deposit_link' and new.status in ('failed', 'skipped') and old.status not in ('failed', 'skipped') then
    select * into q from payment_requests where text_id = new.id;
    if q.id is not null and q.status = 'open' then
      perform app.deposit_link_problem(q, coalesce(new.status_reason, new.last_error, 'the text failed'));
    end if;
  end if;
  return new;
end $$;
create trigger phone_outbox_deposit_link_failed after update of status on phone_outbox for each row execute function app.deposit_link_text_failed();

-- the pay page records the first opening
create or replace function public.server_payreq_opened(p_token_sha256 text) returns void
language sql security definer set search_path = public, app as $$
  update payment_requests set opened_at = now() where token_sha256 = p_token_sha256 and opened_at is null
$$;

-- the deposit job also runs when a deposit link is due
alter function app.server_jobs_due() rename to server_jobs_due_pre0213;
create function app.server_jobs_due() returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j jsonb := app.server_jobs_due_pre0213();
begin
  if coalesce((j ->> 'deposits')::boolean, false) then return j; end if;
  return j || jsonb_build_object('deposits', exists (select 1 from app.deposit_links_due(1)));
end $$;
select pg_temp.copy_grants('app.server_jobs_due()'::regprocedure, 'app.server_jobs_due_pre0213()'::regprocedure);

-- the latest deposit link of a booking: texted, opened
create or replace function app.deposit_link_state(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', q.id, 'status', case when q.status = 'open' and q.expires_at <= now() then 'expired' else q.status end,
           'texted_at', q.texted_at, 'opened_at', q.opened_at, 'error', q.last_error, 'auto', q.auto, 'channel', q.channel)
    from payment_requests q where q.booking_id = p_booking and q.kind = 'hold' and q.channel in ('text', 'email', 'link')
   order by q.created_at desc limit 1
$$;

alter function app.booking_money(uuid, jsonb) rename to booking_money_pre0213;
create function app.booking_money(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.booking_money_pre0213(p_by, p);
begin
  if v is null or nullif(v ->> 'booking_id', '') is null then return v; end if;
  return v || jsonb_build_object('deposit_link', app.deposit_link_state((v ->> 'booking_id')::uuid),
    -- Collect a card offers the text first when the renter has a mobile number
    'renter_has_mobile', exists (select 1 from bookings b join renters r on r.id = b.renter_id where b.id = (v ->> 'booking_id')::uuid and app.phone_e164(r.mobile) is not null));
end $$;
select pg_temp.copy_grants('app.booking_money(uuid, jsonb)'::regprocedure, 'app.booking_money_pre0213(uuid, jsonb)'::regprocedure);

alter function app.field_read(uuid, text, jsonb) rename to field_read_pre0213;
create function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  x jsonb := app.field_read_pre0213(p_user, p_what, p);
begin
  if p_what = 'job' and x is not null and jsonb_typeof(x -> 'ready') = 'object' and (x #>> '{booking,id}') is not null then
    x := jsonb_set(x, '{ready,deposit_link}', coalesce(app.deposit_link_state((x #>> '{booking,id}')::uuid), 'null'::jsonb));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.field_read(uuid, text, jsonb)'::regprocedure, 'app.field_read_pre0213(uuid, text, jsonb)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname in ('deposit_link_needed', 'deposit_link_live', 'deposit_links_due', 'deposit_link_problem', 'deposit_link_text_failed',
                                                       'deposit_link_state', 'server_jobs_due_pre0213', 'booking_money_pre0213', 'field_read_pre0213'))
               or (n.nspname = 'public' and p.proname in ('server_deposit_links_due', 'server_deposit_link_payreq', 'server_deposit_link_send', 'server_payreq_opened')) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
