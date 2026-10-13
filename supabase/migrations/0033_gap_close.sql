-- 0033: closing the gaps of 0031 and 0032.
--
-- Builds on 0001 to 0032. No earlier migration is edited. Four functions are wrapped (renamed and
-- called from a new function with the same name and behaviour, plus the new branches):
--   app.door                  (0032) -> app.door_0032: new screens and actions for assistants, field
--                                       staff and Admins; the assistant's chosen function (_va)
--   app.notification_payload  (0032) -> app.ntf_payload_0032: renter_staff_message, staff_renter_replied
--   app.outbox_file_refs      (0032) -> app.outbox_file_refs_0032: owner_statement_ready's statement_url
-- and three are replaced with the same behaviour for a person with one function: app.va_has (0019),
-- app.user_va_has (0019) and app.my_roles (0031) now read the assistant's active function.
--
-- Sections: A the assistant's functions (cover functions and the switcher); B renter messages both ways
-- and their emails; C the monthly statement emails (PDF first, 7-day links); D Finance (Turo trips,
-- reconciliation), Fleet (daily checks, photo review and re-shoots, late returns), customer service
-- (find a renter), Sales (quotes); E the scorecard; F field staff (checklists for every job kind, the
-- incident report, referrals, profile); G the door; H privileges.

-- =====================================================================================
-- A. The assistant's functions
-- =====================================================================================
-- An assistant who covers another function's shifts (05-va.md section 1) keeps one staff_profiles row:
-- the main function in va_function, the others in cover_functions. The function they work in is chosen
-- in the portal and passed with every door call (_va); without one, the main function.
alter table staff_profiles add column if not exists cover_functions va_function[] not null default '{}';

create or replace function app.va_active_fn(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when nullif(current_setting('app.va_active', true), '') is not null
                   and current_setting('app.va_active', true) = any (array[sp.va_function::text] || sp.cover_functions::text[])
              then current_setting('app.va_active', true) else sp.va_function::text end
    from staff_profiles sp where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active
$$;

create or replace function app.va_has(variadic p_functions text[] default '{}') returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.has_role('va') and exists (
    select 1 from staff_profiles sp
     where sp.user_id = app.uid() and sp.staff_type = 'va' and sp.is_active
       and (cardinality(p_functions) = 0 or app.va_active_fn(sp.user_id) = any (p_functions)))
     and app.staff_two_step_ok()
$$;

create or replace function app.user_va_has(p_user uuid, variadic p_functions text[] default '{}') returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (
    select 1 from user_roles r join users u on u.id = r.user_id
      join staff_profiles sp on sp.user_id = r.user_id and sp.staff_type = 'va' and sp.is_active
     where r.user_id = p_user and r.role = 'va' and u.status = 'active'
       and (cardinality(p_functions) = 0 or app.va_active_fn(sp.user_id) = any (p_functions)))
$$;

create or replace function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'admin', app.user_is_admin(p_user),
    'va', (select app.va_active_fn(sp.user_id) from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va'
             join users u on u.id = sp.user_id
            where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active and u.status = 'active' limit 1),
    'va_functions', coalesce((select to_jsonb(array[sp.va_function::text] || array(select x::text from unnest(sp.cover_functions) x where x <> sp.va_function))
                                from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va' join users u on u.id = sp.user_id
                               where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active and u.status = 'active' limit 1), '[]'::jsonb),
    'field', app.user_is_field(p_user),
    'owner', exists (select 1 from owners o where o.user_id = p_user),
    'renter', exists (select 1 from renters r where r.user_id = p_user),
    'investor', exists (select 1 from investors i where i.user_id = p_user and i.status in ('active', 'exited')),
    'staff', app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user),
    'two_step_required', coalesce((app.settings()).require_staff_two_step, false),
    'name', (select u.full_name from users u where u.id = p_user))
$$;

-- An Admin sets the functions an assistant covers.
create or replace function app.set_cover_functions(p_admin uuid, p_user uuid, p_functions text[]) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  sp staff_profiles;
begin
  perform app.assert_admin(p_admin);
  select * into sp from staff_profiles where user_id = p_user and staff_type = 'va';
  if sp.user_id is null then raise exception 'Only an assistant covers another function' using errcode = '22023'; end if;
  update staff_profiles
     set cover_functions = array(select u.x::va_function from unnest(coalesce(p_functions, '{}')) with ordinality u(x, o)
                                  where nullif(btrim(u.x), '') is not null and u.x <> sp.va_function::text
                                  group by u.x order by min(u.o))
   where user_id = p_user;
  return jsonb_build_object('user_id', p_user, 'cover_functions', (select to_jsonb(cover_functions) from staff_profiles where user_id = p_user));
end $$;

-- =====================================================================================
-- B. Renter messages, both ways
-- =====================================================================================
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('renter_message',      'cs',    'Renter replied',              'high',   'opening_minutes', 15, 1,    null, 'A renter wrote in the booking''s messages; answer from the booking'),
  ('daily_check_problem', 'admin', 'Daily check: a problem',      'high',   'minutes',         60, 19,   null, 'A line of the opening or closing check was answered Problem'),
  ('field_report',        'fleet', 'Field report',                'urgent', 'minutes',         0,  9,    null, 'A field staff member reported something from a car'),
  ('field_job_problem',   'fleet', 'Field job: a problem',        'high',   'minutes',         60, null, null, 'A field checklist line was answered Problem'),
  ('record_registration', 'fleet', 'Record the new registration', 'normal', 'business_days',   1,  12,   null, 'A registry run brought back a new permit'),
  ('recovery_done',       'fleet', 'Car recovered',               'urgent', 'minutes',         0,  8,    null, 'A recovery job is done: check the car in and update the incident')
on conflict (task_type) do nothing;

-- The messages of one booking as its renter sees them: the portal thread (staff replies and the renter's),
-- never task notes or the internal T7 summary.
create or replace function app.booking_thread(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'direction', m.direction, 'subject', m.subject, 'body', m.body, 'at', m.occurred_at,
           'from', case when m.direction = 'inbound' then 'you' else coalesce(nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'CarmaCars') end)
           order by m.occurred_at), '[]'::jsonb)
    from messages m left join users u on u.id = m.sent_by
   where m.booking_id = p_booking and m.channel = 'portal' and m.related_table is distinct from 'tasks'
     and coalesce(m.template_code, '') <> 'T7'
$$;

-- The renter's read (as the signed-in user: app.is_my_booking checks auth.uid()).
create or replace function app.my_booking_messages(p_number text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_id uuid;
begin
  select b.id into v_id from bookings b where b.booking_number = p_number;
  if v_id is null or not coalesce(app.is_my_booking(v_id), false) then return '[]'::jsonb; end if;
  return app.booking_thread(v_id);
end $$;
create or replace function public.my_booking_messages(p_number text) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_booking_messages(p_number) $$;

-- A renter writes in the booking's messages. The reply joins the thread, raises one open task for
-- customer service on the booking (a second reply joins it) and tells customer service: in their
-- next digest, or at once when the pickup is within 48 hours or the car is out.
create or replace function app.renter_send_message(p_booking uuid, p_by uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id uuid;
  v_task uuid;
  v_body text := btrim(coalesce(p_body, ''));
begin
  perform app.assert_booking_renter(p_booking, p_by);
  select * into b from bookings where id = p_booking;
  if v_body = '' then raise exception 'Write the message first' using errcode = '22023'; end if;
  if length(v_body) > 4000 then raise exception 'Keep the message under 4,000 characters' using errcode = '22023'; end if;
  if (select count(*) from messages m where m.booking_id = b.id and m.direction = 'inbound' and m.channel = 'portal'
        and m.occurred_at > now() - interval '1 day') >= 30 then
    raise exception 'Too many messages today: call us instead' using errcode = '23514';
  end if;
  insert into messages (direction, channel, subject, body, user_id, renter_id, booking_id, vehicle_id, status)
  values ('inbound', 'portal', 'Reply about booking ' || b.booking_number, v_body, p_by, b.renter_id, b.id, b.vehicle_id, 'received')
  returning id into v_id;
  v_task := app.raise_task(p_type => 'renter_message', p_title => 'Booking ' || b.booking_number || ': the renter replied',
    p_detail => left(v_body, 300), p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id,
    p_related_table => 'messages', p_related_id => v_id, p_dedupe => 'renter_message:' || b.id, p_created_by => p_by);
  perform app.ntf_emit('staff_renter_replied', 'message', v_id, 'reply', jsonb_build_object('booking_id', b.id,
    '_immediate', b.status = 'on_rent' or (b.status in ('confirmed', 'pending_payment') and b.pickup_at < now() + interval '48 hours')));
  return jsonb_build_object('id', v_id, 'task_id', v_task);
end $$;
create or replace function public.renter_send_message(p_booking uuid, p_by uuid, p_body text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.renter_send_message(p_booking, p_by, p_body) $$;

-- A staff reply to the renter (customer service or Sales, through the door): kept on the booking,
-- emailed to the renter with the message and a link to reply in the portal (renter_staff_message), and
-- the open "renter replied" task closes. Replaces 0031's send_message, which only kept the reply.
create or replace function app.staff_send_message(p_user uuid, p_booking uuid, p_subject text, p_body text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_problem text;
  v_id uuid;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'A message belongs to a booking' using errcode = '22023'; end if;
  v_problem := app.staff_message_problem(p_body);
  if v_problem is not null then raise exception '%', v_problem using errcode = '23514'; end if;
  insert into messages (direction, channel, subject, body, to_address, user_id, renter_id, booking_id, vehicle_id, sent_by, status)
  select 'outbound', 'portal', coalesce(nullif(btrim(p_subject), ''), 'Your booking ' || b.booking_number), left(btrim(p_body), 4000),
         r.email, r.user_id, r.id, b.id, b.vehicle_id, p_user, 'delivered'
    from renters r where r.id = b.renter_id
  returning id into v_id;
  if v_id is null then raise exception 'This booking has no renter to write to' using errcode = '23514'; end if;
  perform app.ntf_emit('renter_staff_message', 'message', v_id, 'sent', jsonb_build_object('booking_id', b.id, 'renter_id', b.renter_id));
  perform app.resolve_tasks(array['renter_message'], b.id, p_user, 'Replied', false);
  return jsonb_build_object('id', v_id);
end $$;

-- The email values of the two message emails (the rest of the payload builder is 0023, 0024 and 0032's).
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_0032;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  m messages;
  b bookings;
begin
  if p_code not in ('renter_staff_message', 'staff_renter_replied') then
    return app.ntf_payload_0032(p_code, p_event, p_to);
  end if;
  select * into m from messages where id = p_event.entity_id;
  select * into b from bookings where id = m.booking_id;
  if p_code = 'renter_staff_message' then
    return app.ntf_contact() || jsonb_build_object(
      'first_name', coalesce(nullif(split_part(btrim(coalesce((select r.legal_name from renters r where r.id = b.renter_id), p_to ->> 'name', '')), ' ', 1), ''), 'there'),
      'booking_number', b.booking_number, 'vehicle_name', app.vehicle_name(b.vehicle_id),
      'staff_name', coalesce(nullif(split_part(btrim(coalesce((select u.full_name from users u where u.id = m.sent_by), '')), ' ', 1), ''), 'Our team'),
      'message_subject', coalesce(m.subject, 'Your booking ' || b.booking_number), 'message_body', m.body, 'booking_id', b.id);
  end if;
  return app.ntf_contact() || jsonb_build_object(
    'first_name', coalesce(nullif(split_part(btrim(coalesce(p_to ->> 'name', '')), ' ', 1), ''), 'there'),
    'renter_first_name', coalesce(nullif(split_part(btrim(coalesce((select r.legal_name from renters r where r.id = b.renter_id), '')), ' ', 1), ''), 'The renter'),
    'booking_number', b.booking_number, 'vehicle_name', app.vehicle_name(b.vehicle_id),
    'pickup_date', app.fmt_day(app.local_date(b.pickup_at)), 'booking_status', replace(b.status::text, '_', ' '),
    'message_excerpt', case when length(m.body) > 280 then left(m.body, 277) || '...' else m.body end, 'booking_id', b.id,
    '_digest_meta', 'Booking ' || b.booking_number);
end $$;

-- =====================================================================================
-- C. The monthly statement emails: the PDF first, then the email with a 7-day link
-- =====================================================================================
-- What is due (11-statements-and-reports.md section 1): an approved owner statement on its payout date
-- (the 10th), an investor's statement on its Payment Date (the 15th) once the return is paid or
-- reinvested; never older than 45 days, so a first run does not send a backlog.
create or replace function app.statement_mail_due(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x order by x ->> 'due'), '[]'::jsonb) from (
    select jsonb_build_object('kind', 'owner_statement', 'key', s.id::text, 'due', s.payout_date) x
      from owner_statements s
     where s.status in ('approved', 'paid') and s.sent_at is null
       and s.payout_date <= app.local_date(p_now) and s.payout_date > app.local_date(p_now) - 45
    union all
    select jsonb_build_object('kind', 'investor_statement', 'key', r.id::text, 'due', r.payment_date)
      from investment_returns r join investments i on i.id = r.investment_id join investors v on v.id = i.investor_id
     where r.status in ('paid', 'reinvested') and r.statement_sent_at is null and v.status in ('active', 'exited')
       and r.payment_date <= app.local_date(p_now) and r.payment_date > app.local_date(p_now) - 45
    limit 40) q
$$;

-- Sends one statement email, only once its PDF is stored (app.file_record of 0032). The owner email is
-- the event of app.issue_owner_statement (same dedupe key, so a statement an Admin already sent is not
-- sent twice); the investor email is 0023's trigger on statement_sent_at.
create or replace function app.statement_mail_release(p_kind text, p_key text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  g generated_documents;
  st owner_statements;
  n integer;
begin
  select * into g from generated_documents where kind = p_kind and entity_key = p_key;
  if g.document_id is null then raise exception 'Render and store the PDF first' using errcode = '23514'; end if;
  if p_kind = 'owner_statement' then
    update owner_statements set sent_at = now(), document_id = coalesce(document_id, g.document_id)
     where id = p_key::uuid and sent_at is null and status in ('approved', 'paid')
    returning * into st;
    if st.id is null then return jsonb_build_object('sent', false); end if;
    perform app.emit_event('owner_statement_ready', 'owner_statement', st.id,
      jsonb_build_object('owner_id', st.owner_id, 'statement_month', st.statement_month, 'payout_cents', st.payout_cents,
                         'payout_date', st.payout_date, 'version', st.version, 'document_id', st.document_id),
      'owner_statement_ready:' || st.id || ':v' || st.version);
    return jsonb_build_object('sent', true, 'kind', p_kind, 'key', p_key);
  elsif p_kind = 'investor_statement' then
    update investment_returns set statement_document_id = coalesce(statement_document_id, g.document_id), statement_sent_at = now()
     where id = p_key::uuid and statement_sent_at is null and status in ('paid', 'reinvested');
    get diagnostics n = row_count;
    return jsonb_build_object('sent', n = 1, 'kind', p_kind, 'key', p_key);
  end if;
  raise exception 'Unknown statement kind %', p_kind using errcode = '22023';
end $$;

-- The owner statement email now carries the 7-day link to its PDF (statement_url), as the investor one does.
alter function app.outbox_file_refs(uuid) rename to outbox_file_refs_0032;
create or replace function app.outbox_file_refs(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o notification_outbox;
begin
  select * into o from notification_outbox where id = p_outbox;
  if o.code = 'owner_statement_ready' and o.entity = 'owner_statement' then
    return jsonb_build_object('statement_url', jsonb_build_object('k', 'owner_statement', 'key', o.entity_id::text));
  end if;
  return app.outbox_file_refs_0032(p_outbox);
end $$;

-- =====================================================================================
-- D1. Finance: Turo trips (05-va.md section 2)
-- =====================================================================================
-- One trip: the Revenue Share in force for the car on the trip's end date (vehicle_fee_history), the
-- statement month of the end date (Toronto). An existing trip reference is updated while it is on no
-- statement yet.
create or replace function app.save_turo_trip(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_vehicle uuid;
  v_ref text := nullif(btrim(coalesce(p_ ->> 'turo_trip_ref', '')), '');
  v_start timestamptz := (p_ ->> 'starts_at')::timestamptz;
  v_end timestamptz := (p_ ->> 'ends_at')::timestamptz;
  v_gross bigint := (p_ ->> 'gross_cents')::bigint;
  v_fees bigint := coalesce((p_ ->> 'turo_fees_cents')::bigint, 0);
  v_bps integer;
  t turo_trips;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin records Turo trips' using errcode = '42501'; end if;
  select v.id into v_vehicle from vehicles v
   where v.id::text = p_ ->> 'vehicle' or upper(replace(v.plate, ' ', '')) = upper(replace(coalesce(p_ ->> 'plate', ''), ' ', '')) or v.vin = upper(btrim(coalesce(p_ ->> 'vin', '')))
   limit 1;
  if v_vehicle is null then raise exception 'Car not found (choose it, or give its plate or VIN)' using errcode = '22023'; end if;
  if v_ref is null then raise exception 'The trip reference is needed' using errcode = '22023'; end if;
  if v_start is null or v_end is null or v_end <= v_start then raise exception 'The trip ends after it starts' using errcode = '22023'; end if;
  if v_gross is null or v_gross < 0 or v_fees < 0 or v_fees > v_gross then raise exception 'Check the amounts: gross, then Turo''s fees' using errcode = '22023'; end if;
  v_bps := (app.vehicle_terms(v_vehicle, app.local_date(v_end))).revenue_share_bps;
  if v_bps is null then raise exception 'This car has no Revenue Share on file for that date' using errcode = '23514'; end if;
  select * into t from turo_trips where turo_trip_ref = v_ref;
  if t.id is not null and t.owner_statement_id is not null then
    raise exception 'Trip % is already on an owner statement', v_ref using errcode = '23514';
  end if;
  insert into turo_trips (vehicle_id, turo_trip_ref, starts_at, ends_at, gross_cents, turo_fees_cents, company_extras_cents, damage_payment_cents,
                          revenue_share_bps, revenue_share_cents, statement_month, received_at)
  values (v_vehicle, v_ref, v_start, v_end, v_gross, v_fees, coalesce((p_ ->> 'company_extras_cents')::bigint, 0), coalesce((p_ ->> 'damage_payment_cents')::bigint, 0),
          v_bps, public.calc_bps(v_gross - v_fees, v_bps), date_trunc('month', app.local_date(v_end))::date,
          coalesce((p_ ->> 'received_at')::timestamptz, case when coalesce((p_ ->> 'received')::boolean, true) then now() end))
  on conflict (turo_trip_ref) do update
     set vehicle_id = excluded.vehicle_id, starts_at = excluded.starts_at, ends_at = excluded.ends_at, gross_cents = excluded.gross_cents,
         turo_fees_cents = excluded.turo_fees_cents, company_extras_cents = excluded.company_extras_cents,
         damage_payment_cents = excluded.damage_payment_cents, revenue_share_bps = excluded.revenue_share_bps,
         revenue_share_cents = excluded.revenue_share_cents, statement_month = excluded.statement_month,
         received_at = coalesce(turo_trips.received_at, excluded.received_at)
  returning * into t;
  return jsonb_build_object('id', t.id, 'turo_trip_ref', t.turo_trip_ref, 'revenue_share_cents', t.revenue_share_cents,
                            'owner_payout_cents', t.owner_payout_cents, 'statement_month', t.statement_month);
end $$;

-- =====================================================================================
-- D2. Fleet: the daily checks (procedure 19), with the lines the system can answer pre-answered
-- =====================================================================================
create or replace function app.daily_check_form(p_date date, p_kind text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  dc daily_checks;
  v_items jsonb;
  v_quiet text;
  v_unacked text;
  v_unready text;
  v_overdue text;
  v_unsigned text;
  v_unpaid text;
begin
  if p_kind not in ('opening', 'closing') then raise exception 'Opening or closing' using errcode = '22023'; end if;
  select * into dc from daily_checks where check_date = p_date and kind = p_kind;
  if p_kind = 'opening' then
    select string_agg(v.plate, ', ' order by v.plate) into v_quiet
      from vehicles v join tracker_devices d on d.vehicle_id = v.id and d.status = 'installed'
     where v.status in ('available', 'on_rent') and not coalesce((app.tracker_reading(v.id) ->> 'reporting')::boolean, false);
    select string_agg(b.booking_number || case when j.id is null then ' (no job)' when j.assigned_to is null then ' (nobody)' else ' (not acknowledged)' end, ', ')
      into v_unacked
      from bookings b cross join lateral (values ('pickup', b.pickup_at, b.status = 'confirmed'), ('return', b.return_at, b.status in ('confirmed', 'on_rent'))) x(leg, at, applies)
      left join lateral (select * from field_jobs j where j.booking_id = b.id and j.status <> 'cancelled'
                            and (case when x.leg = 'pickup' then j.kind in ('handover', 'delivery') else j.kind in ('return_check_in', 'pickup_from_renter') end)
                          order by j.created_at desc limit 1) j on true
     where x.applies and app.local_date(x.at) = p_date and (j.id is null or j.assigned_to is null or j.acknowledged_at is null);
    select string_agg(b.booking_number, ', ') into v_unready
      from bookings b where b.status = 'confirmed' and app.local_date(b.pickup_at) = p_date + 1
       and not (coalesce((app.booking_readiness(b.id) ->> 'all_drivers_verified')::boolean, false) and coalesce((app.booking_readiness(b.id) ->> 'coverage_confirmed')::boolean, false));
    select string_agg(b.booking_number, ', ') into v_overdue from bookings b where b.status = 'on_rent' and b.return_at < now();
    select string_agg(coalesce(b.booking_number, 'payment'), ', ') into v_unpaid
      from payments x left join bookings b on b.id = x.booking_id where x.status = 'failed' and x.created_at < now() - interval '24 hours' and x.created_at > now() - interval '30 days'
       and not exists (select 1 from payments y where y.booking_id = x.booking_id and y.purpose = x.purpose and y.status = 'succeeded' and y.created_at > x.created_at);
    v_items := jsonb_build_array(
      jsonb_build_object('n', 1, 'label', 'Tracker: every car reporting; no overnight movement of an idle car; no tamper alert', 'system', v_quiet is null,
                         'detail', coalesce('Not reporting: ' || v_quiet, 'Every installed Tracker reported in the last 10 minutes.')),
      jsonb_build_object('n', 2, 'label', 'Today''s handovers and returns each have a field person who has acknowledged', 'system', v_unacked is null,
                         'detail', coalesce(v_unacked, 'Every job of today is assigned and acknowledged.')),
      jsonb_build_object('n', 3, 'label', 'Tomorrow''s pickups: verification and coverage complete (procedure 2), T5 sent', 'system', v_unready is null,
                         'detail', coalesce('Not ready: ' || v_unready, 'Every pickup of tomorrow is verified and covered.')),
      jsonb_build_object('n', 4, 'label', 'Overdue: late returns, charges unpaid over 24 hours, Deposits nearing 7 business days', 'system', v_overdue is null and v_unpaid is null,
                         'detail', concat_ws('. ', 'Late: ' || v_overdue, 'Unpaid: ' || v_unpaid, case when v_overdue is null and v_unpaid is null then 'Nothing overdue.' end)),
      jsonb_build_object('n', 5, 'label', 'Customer service: inbox, WhatsApp and voicemail cleared', 'system', null, 'detail', null));
  else
    select string_agg(b.booking_number, ', ') into v_unsigned
      from bookings b
     where (app.local_date(b.handed_over_at) = p_date and not exists (select 1 from condition_reports r where r.booking_id = b.id and r.kind = 'pickup' and r.completed_at is not null))
        or (app.local_date(b.checked_in_at) = p_date and (not exists (select 1 from condition_reports r where r.booking_id = b.id and r.kind = 'return' and r.completed_at is not null)
                                                         or not exists (select 1 from messages m where m.booking_id = b.id and m.template_code = 'T7')));
    v_items := jsonb_build_array(
      jsonb_build_object('n', 1, 'label', 'Every handover and return has a signed Part 4 and photo set filed, and T7 sent for every return', 'system', v_unsigned is null,
                         'detail', coalesce('Missing: ' || v_unsigned, 'Every report of today is signed; every return has its T7.')),
      jsonb_build_object('n', 2, 'label', 'Calendar statuses correct; tomorrow''s cars cleaned', 'system',
                         not exists (select 1 from bookings b join vehicles v on v.id = b.vehicle_id where b.status = 'confirmed' and app.local_date(b.pickup_at) = p_date + 1 and v.status = 'cleaning'),
                         'detail', (select 'Still in cleaning: ' || string_agg(v.plate, ', ') from bookings b join vehicles v on v.id = b.vehicle_id
                                     where b.status = 'confirmed' and app.local_date(b.pickup_at) = p_date + 1 and v.status = 'cleaning')),
      jsonb_build_object('n', 3, 'label', 'Finance: card processor payouts matched to the bookings', 'system',
                         not exists (select 1 from payout_reconciliations r where r.status not in ('matched', 'resolved')),
                         'detail', (select count(*) || ' payout(s) not matched' from payout_reconciliations r where r.status not in ('matched', 'resolved') having count(*) > 0)),
      jsonb_build_object('n', 4, 'label', 'Incidents updated; handover note sent to the on-call person', 'system', null, 'detail', null));
  end if;
  return jsonb_build_object('date', p_date, 'kind', p_kind, 'items', v_items,
    'saved', case when dc.id is null then null else jsonb_build_object('items', dc.items, 'issues', dc.issues, 'completed_at', dc.completed_at,
                                                                      'completed_by', (select full_name from users where id = dc.completed_by)) end,
    'due', app.local_midnight(p_date) + case when p_kind = 'opening' then interval '9 hours' else interval '18 hours' end);
end $$;

-- Saves the check: every line OK or Problem (a Problem needs a note); any Problem escalates to an Admin.
create or replace function app.save_daily_check(p_by uuid, p_date date, p_kind text, p_items jsonb, p_issues text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  f jsonb := app.daily_check_form(p_date, p_kind);
  it jsonb;
  a jsonb;
  v_problems text[] := '{}';
  v_id uuid;
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Fleet or an Admin records the daily checks' using errcode = '42501'; end if;
  if p_date > app.today() or p_date < app.today() - 2 then raise exception 'Record today''s check (or one of the last two days)' using errcode = '22023'; end if;
  for it in select * from jsonb_array_elements(f -> 'items') loop
    a := coalesce(p_items -> (it ->> 'n'), 'null'::jsonb);
    if coalesce(a ->> 'result', '') not in ('ok', 'problem') then
      raise exception 'Answer line % (OK or Problem)', it ->> 'n' using errcode = '22023';
    end if;
    if a ->> 'result' = 'problem' then
      if nullif(btrim(coalesce(a ->> 'note', '')), '') is null then raise exception 'Say what the problem is on line %', it ->> 'n' using errcode = '22023'; end if;
      v_problems := v_problems || format('%s. %s: %s', it ->> 'n', it ->> 'label', btrim(a ->> 'note'));
    end if;
  end loop;
  insert into daily_checks (check_date, kind, items, issues, completed_by, completed_at)
  values (p_date, p_kind, p_items, nullif(concat_ws(E'\n', nullif(array_to_string(v_problems, E'\n'), ''), nullif(btrim(coalesce(p_issues, '')), '')), ''), p_by, now())
  on conflict (check_date, kind) do update set items = excluded.items, issues = excluded.issues, completed_by = excluded.completed_by, completed_at = excluded.completed_at
  returning id into v_id;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by
   where task_type = case when p_kind = 'opening' then 'opening_checks' else 'closing_checks' end
     and status in ('open', 'in_progress', 'waiting') and (due_at is null or app.local_date(due_at) <= p_date);
  if cardinality(v_problems) > 0 then
    perform app.raise_task(p_type => 'daily_check_problem', p_title => format('%s check %s: %s problem(s)', initcap(p_kind), app.fmt_day(p_date), cardinality(v_problems)),
      p_detail => array_to_string(v_problems, E'\n'), p_related_table => 'daily_checks', p_related_id => v_id,
      p_dedupe => 'daily_check_problem:' || p_date || ':' || p_kind, p_created_by => p_by, p_escalation_reason => 'Procedure 19: escalate to admin');
  end if;
  return jsonb_build_object('id', v_id, 'problems', cardinality(v_problems));
end $$;

-- =====================================================================================
-- D3. Fleet: the photo review side by side, and the re-shoot (procedures 3 and 4)
-- =====================================================================================
alter table field_jobs add column if not exists checklist jsonb not null default '{}'::jsonb;
alter table field_jobs add column if not exists reshoot_report_id uuid references condition_reports (id);
alter table field_jobs add column if not exists reshoot_shots text[];

create or replace function app.photo_review(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v vehicles;
  v_out jsonb := '{}'::jsonb;
  r condition_reports;
  k text;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  select * into v from vehicles where id = b.vehicle_id;
  v_out := jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'vehicle', app.vehicle_name(v.id), 'plate', v.plate,
    'shots', coalesce((select jsonb_agg(jsonb_build_object('seq', s.seq, 'shot', s.shot, 'guide', s.guide) order by s.seq) from app.required_shots_for('pickup', v.class) s), '[]'::jsonb));
  foreach k in array array['pickup', 'return'] loop
    r := null;
    select * into r from condition_reports x where x.booking_id = b.id and x.kind = k order by x.created_at desc limit 1;
    v_out := v_out || jsonb_build_object(k, case when r.id is null then null else jsonb_build_object(
      'id', r.id, 'completed_at', r.completed_at, 'performed_by', r.performed_by, 'performed_by_name', (select full_name from users where id = r.performed_by),
      'odometer_km', r.odometer_km, 'fuel_pct', r.fuel_pct, 'keys_count', r.keys_count, 'reviewed_at', r.reviewed_at,
      'photos', coalesce((select jsonb_agg(jsonb_build_object('seq', ph.seq, 'shot', ph.shot, 'bucket', ph.storage_bucket, 'path', ph.storage_path, 'taken_at', ph.taken_at,
                             'damage_id', ph.damage_id) order by ph.seq, ph.taken_at) from condition_report_photos ph where ph.condition_report_id = r.id and ph.shot <> 'licence'), '[]'::jsonb),
      'damages', coalesce((select jsonb_agg(jsonb_build_object('label', d.label, 'location', d.location, 'description', d.description, 'is_new', d.is_new) order by d.label)
                             from condition_report_damages d where d.condition_report_id = r.id), '[]'::jsonb),
      'missing', coalesce((select jsonb_agg(s.shot order by s.seq) from app.required_shots_for(k, v.class) s
                            where not exists (select 1 from condition_report_photos ph where ph.condition_report_id = r.id and ph.shot = s.shot)), '[]'::jsonb),
      'reshoots', coalesce((select jsonb_agg(jsonb_build_object('id', j.id, 'status', j.status, 'shots', to_jsonb(j.reshoot_shots), 'scheduled_at', j.scheduled_at,
                              'assignee', (select full_name from users where id = j.assigned_to)) order by j.created_at)
                             from field_jobs j where j.reshoot_report_id = r.id and j.status <> 'cancelled'), '[]'::jsonb)) end);
  end loop;
  return v_out;
end $$;

-- "Ask for a re-shoot": a field job on the car for the shots named, given by default to whoever took the set.
create or replace function app.request_reshoot(p_by uuid, p_booking uuid, p_which text, p_shots text[], p_to uuid default null,
                                               p_at timestamptz default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  r condition_reports;
  v_shots text[];
  v_to uuid;
  v_job uuid;
begin
  if not app.user_runs_fleet(p_by) then raise exception 'Fleet or an Admin asks for a re-shoot' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  select * into r from condition_reports where booking_id = b.id and kind = p_which order by created_at desc limit 1;
  if r.id is null then raise exception 'There is no % report to re-shoot', p_which using errcode = '23514'; end if;
  select array_agg(s.shot order by s.seq) into v_shots
    from app.required_shots_for(p_which, (select class from vehicles where id = b.vehicle_id)) s where s.shot = any (coalesce(p_shots, '{}'));
  if coalesce(cardinality(v_shots), 0) = 0 then raise exception 'Choose the shots to take again' using errcode = '22023'; end if;
  v_to := coalesce(p_to, case when app.user_is_field(r.performed_by) then r.performed_by end);
  v_job := app.create_field_job('other', b.vehicle_id, coalesce(p_at, now() + interval '1 hour'), p_by, b.id, v_to,
                                coalesce(case when p_which = 'return' then b.return_place else b.pickup_place end, 'Where the car is'),
                                'Re-shoot for booking ' || b.booking_number || ' (' || p_which || '): ' || array_to_string(v_shots, ', ')
                                || coalesce('. ' || nullif(btrim(p_note), ''), ''));
  update field_jobs set reshoot_report_id = r.id, reshoot_shots = v_shots where id = v_job;
  return jsonb_build_object('job_id', v_job, 'shots', to_jsonb(v_shots), 'assigned_to', v_to);
end $$;

-- =====================================================================================
-- D4. Fleet: the late-return panel (procedure 8)
-- =====================================================================================
create or replace function app.late_panel(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_t13 timestamptz;
  v_t14 timestamptz;
  v_notice integer := coalesce((app.settings()).tracker_notice_minutes, 60);
  c tracker_commands;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return null; end if;
  select max(e.created_at) into v_t13 from app_events e where e.code = 'renter_late_return_first' and e.entity = 'booking' and e.entity_id = b.id;
  select max(e.created_at) into v_t14 from app_events e where e.code = 'renter_late_return_final' and e.entity = 'booking' and e.entity_id = b.id;
  select * into c from tracker_commands x where x.booking_id = b.id and x.command = 'disable' order by x.created_at desc limit 1;
  return jsonb_build_object(
    'booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'return_at', b.return_at, 'now', now(),
    'late', b.status = 'on_rent' and b.return_at < now(),
    'minutes_late', greatest(0, floor(extract(epoch from (now() - b.return_at)) / 60))::integer,
    'renter', (select jsonb_build_object('name', r.legal_name, 'mobile', r.mobile) from renters r where r.id = b.renter_id),
    't13_at', v_t13, 't14_at', v_t14, 'notice_minutes', v_notice,
    'steps', jsonb_build_array(
      jsonb_build_object('at', b.return_at, 'label', 'Call the renter, send T13, check the Tracker, offer an extension', 'done', v_t13 is not null),
      jsonb_build_object('at', b.return_at + interval '30 minutes', 'label', 'Late charges start', 'done', now() >= b.return_at + interval '30 minutes'),
      jsonb_build_object('at', b.return_at + interval '2 hours', 'label', 'Two calls, send T14, tell an Admin', 'done', v_t14 is not null),
      jsonb_build_object('at', coalesce(v_t14, b.return_at + interval '2 hours') + make_interval(mins => v_notice), 'label', 'Request disable (an Admin approves)', 'done', c.id is not null)),
    'calls', coalesce((select jsonb_agg(jsonb_build_object('at', m.occurred_at, 'note', m.body, 'by', (select full_name from users where id = m.sent_by)) order by m.occurred_at)
                         from messages m where m.booking_id = b.id and m.channel = 'phone' and m.related_table = 'late_return'), '[]'::jsonb),
    'tracker', app.tracker_reading(b.vehicle_id),
    'disable', case when c.id is null then null else jsonb_build_object('id', c.id, 'status', c.status, 'created_at', c.created_at) end,
    'incident', (select jsonb_build_object('id', i.id, 'number', i.incident_number, 'kind', i.kind, 'status', i.status) from incidents i
                  where i.booking_id = b.id and i.kind in ('late_return', 'non_return') order by i.created_at desc limit 1));
end $$;

-- The panel's buttons: log a call, send T13 or T14 now (the same event the late-returns job sends, so
-- never twice), request disable (the notice time is the T14's), open an incident.
create or replace function app.late_action(p_by uuid, p_booking uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
  v_id bigint;
  v_t14 timestamptz;
  v_uid uuid;
begin
  if not (app.user_runs_fleet(p_by) or app.user_va_has(p_by, 'cs')) then raise exception 'Fleet, customer service or an Admin works a late return' using errcode = '42501'; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  case p_action
  when 'call' then
    if nullif(btrim(coalesce(p ->> 'note', '')), '') is null then raise exception 'Note what happened on the call' using errcode = '22023'; end if;
    insert into messages (direction, channel, subject, body, renter_id, booking_id, vehicle_id, sent_by, status, related_table, related_id)
    values ('outbound', 'phone', 'Call about the late return', left(btrim(p ->> 'note'), 2000), b.renter_id, b.id, b.vehicle_id, p_by, 'sent', 'late_return', b.id)
    returning id into v_uid;
    return jsonb_build_object('id', v_uid);
  when 't13', 't14' then
    if b.status <> 'on_rent' or b.return_at > now() then raise exception 'The car is not late' using errcode = '23514'; end if;
    if p_action = 't14' and b.return_at > now() - interval '2 hours' then
      raise exception 'T14 is the final notice: it goes 2 hours after the return time' using errcode = '23514';
    end if;
    v_id := app.ntf_emit(case when p_action = 't13' then 'renter_late_return_first' else 'renter_late_return_final' end, 'booking', b.id,
                         'r' || extract(epoch from b.return_at)::bigint, jsonb_build_object('booking_id', b.id));
    return jsonb_build_object('event_id', v_id, 'already_sent', v_id is null);
  when 'disable' then
    select max(e.created_at) into v_t14 from app_events e where e.code = 'renter_late_return_final' and e.entity = 'booking' and e.entity_id = b.id;
    return jsonb_build_object('command_id', app.request_tracker_disable(b.vehicle_id, p_by, 'late_return',
      coalesce(nullif(btrim(p ->> 'reason'), ''), 'Not returned after the final notice'), b.id, null, v_t14, now()));
  when 'incident' then
    return jsonb_build_object('incident_id', app.open_incident('late_return', b.vehicle_id, p_by,
      jsonb_build_object('description', coalesce(nullif(btrim(p ->> 'note'), ''), 'Late return: booking ' || b.booking_number)), b.id, 'staff', now()));
  else
    raise exception 'Unknown action %', p_action using errcode = '22023';
  end case;
end $$;

-- =====================================================================================
-- D5. Customer service: find a renter (05-va.md section 4.4; 0012's search and logged opening)
-- =====================================================================================
create or replace function app.renter_view(p_renter uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.is_admin() or app.va_sees_renter(p_renter)) then
    raise exception 'Open this record with a reason first' using errcode = '42501';
  end if;
  return (select jsonb_build_object('id', r.id, 'legal_name', r.legal_name, 'email', r.email, 'mobile', r.mobile, 'identity_status', r.identity_status,
            'is_blocked', r.is_blocked, 'access_until', (select max(g.granted_until) from data_access_log g where g.renter_id = r.id and g.user_id = app.uid() and g.granted_until > now()),
            'bookings', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at,
                                   'return_at', b.return_at, 'vehicle', app.vehicle_name(b.vehicle_id)) order by b.pickup_at desc)
                                   from bookings b where b.renter_id = r.id), '[]'::jsonb))
            from renters r where r.id = p_renter);
end $$;

-- =====================================================================================
-- D6. Sales: a quote from a phone, email or WhatsApp lead (05-va.md section 5)
-- =====================================================================================
-- Creates the request as the web form would (renter and driver records, the request, its drivers and
-- fee terms, places, the price), with the source and the staff member who took it. No consent is
-- recorded for the lead: the renter accepts the terms when they sign the agreement.
create or replace function app.staff_quote_request(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_set program_settings := app.settings();
  v_email text := lower(btrim(coalesce(p_ ->> 'email', '')));
  v_name text := nullif(btrim(coalesce(p_ ->> 'full_name', '')), '');
  v_mobile text := nullif(btrim(coalesce(p_ ->> 'mobile', '')), '');
  v_dob date := nullif(p_ ->> 'date_of_birth', '')::date;
  v_class text := upper(coalesce(nullif(btrim(p_ ->> 'licence_class'), ''), 'G'));
  v_vehicle uuid := (p_ ->> 'vehicle_id')::uuid;
  v_pickup timestamptz := (p_ ->> 'pickup_at')::timestamptz;
  v_return timestamptz := (p_ ->> 'return_at')::timestamptz;
  v_source text := coalesce(nullif(p_ ->> 'source', ''), 'phone');
  v vehicles;
  u users;
  rn renters;
  dr drivers;
  v_age integer;
  v_booking uuid;
  b bookings;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'sales', 'cs')) then raise exception 'Sales, customer service or an Admin takes a quote' using errcode = '42501'; end if;
  if v_source not in ('phone', 'email', 'whatsapp') then raise exception 'Where did the lead come from: phone, email or WhatsApp' using errcode = '22023'; end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'The lead''s email address is needed' using errcode = '22023'; end if;
  if v_name is null or v_mobile is null or v_dob is null then raise exception 'The lead''s full name, mobile and date of birth are needed' using errcode = '22023'; end if;
  select * into v from vehicles where id = v_vehicle;
  if v.id is null then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_pickup is null or v_return is null or v_return <= v_pickup then raise exception 'The return must be after the pickup' using errcode = '22023'; end if;
  if v_pickup < now() + make_interval(mins => v_set.booking_min_notice_minutes) then
    raise exception 'The pickup must be at least % minutes from now', v_set.booking_min_notice_minutes using errcode = '22023';
  end if;
  v_age := app.age_on(v_dob, app.local_date(v_pickup));
  if v_age < v_set.min_renter_age then raise exception 'Every driver must be % or older at pickup', v_set.min_renter_age using errcode = '23514'; end if;
  if app.age_band(v_age) = '18_to_20' and not v.allows_18_to_20 then raise exception 'This car is for drivers % and over', v_set.standard_min_age using errcode = '23514'; end if;
  if not v_class = any (select upper(x) from unnest(v_set.accepted_licence_classes) x) then
    raise exception 'A class % licence is needed', array_to_string(v_set.accepted_licence_classes, ' or ') using errcode = '23514';
  end if;

  select * into u from users where lower(email) = v_email;
  if u.id is null then
    insert into users (email, phone, full_name) values (v_email, v_mobile, v_name) returning * into u;
  elsif u.status not in ('active', 'invited') then
    raise exception 'This person cannot book online: ask an Admin' using errcode = '23514';
  end if;
  insert into user_roles (user_id, role) values (u.id, 'renter') on conflict do nothing;
  select * into rn from renters where user_id = u.id;
  if rn.id is null then
    insert into renters (user_id, legal_name, date_of_birth, mobile, email) values (u.id, v_name, v_dob, v_mobile, u.email) returning * into rn;
  end if;
  select * into dr from drivers where renter_id = rn.id and is_account_holder;
  if dr.id is null then
    insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, mobile, email)
    values (rn.id, true, u.id, rn.legal_name, coalesce(rn.date_of_birth, v_dob), v_class, coalesce(rn.mobile, v_mobile), u.email) returning * into dr;
  end if;
  v_age := app.age_on(dr.date_of_birth, app.local_date(v_pickup));

  v_booking := app.request_booking(rn.id, v_vehicle, v_pickup, v_return, 'standard'::booking_type, nullif(btrim(coalesce(p_ ->> 'note', '')), ''), v_source, p_by,
                                   null, null, coalesce(nullif(p_ ->> 'pickup_method', ''), 'collected'), coalesce(nullif(p_ ->> 'return_method', ''), 'returned'),
                                   nullif(btrim(coalesce(p_ ->> 'pickup_place', '')), ''), nullif(btrim(coalesce(p_ ->> 'return_place', '')), ''));
  insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry, age_at_pickup, age_band)
  values (v_booking, dr.id, 'renter', dr.full_name, dr.date_of_birth, dr.licence_number, dr.licence_class, dr.licence_issuer, dr.licence_expiry, v_age, app.age_band(v_age));
  insert into booking_fee_terms (booking_id, fee_type_code, amount_cents, cap_cents, percent_bps, source)
  select v_booking, x.code, t.amount_cents, t.cap_cents, t.percent_bps, t.source
    from unnest(array['young_driver_18_20', 'young_driver_21_25', 'additional_driver', 'winter_tire', 'baby_seat', 'coverage_sold']) x(code)
    cross join lateral public.effective_fee(x.code, v_vehicle, app.today()) t
  on conflict (booking_id, fee_type_code) do nothing;
  update bookings set request_details = coalesce(request_details, '{}'::jsonb) || jsonb_build_object('submitted_at', now(), 'source', v_source, 'taken_by', p_by,
                        'coverage_option', (p_ ->> 'coverage_option')::integer, 'conflict_at_submit', not app.vehicle_is_available(v_vehicle, v_pickup, v_return, v_booking)),
                      coverage_option = coalesce((p_ ->> 'coverage_option')::integer, coverage_option)
   where id = v_booking;
  perform app.apply_booking_places(v_booking, jsonb_build_object('pickup_method', coalesce(nullif(p_ ->> 'pickup_method', ''), 'collected'),
    'return_method', coalesce(nullif(p_ ->> 'return_method', ''), 'returned'),
    'pickup_location', coalesce(p_ -> 'pickup_location', jsonb_build_object('kind', 'our_location')),
    'return_location', coalesce(p_ -> 'return_location', jsonb_build_object('kind', 'our_location'))));
  perform app.reprice_booking(v_booking);
  select * into b from bookings where id = v_booking;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'renter_id', rn.id,
                            'total_due_at_booking_cents', b.total_due_at_booking_cents);
end $$;

-- =====================================================================================
-- E. The weekly scorecard (VA hiring package section 7; 05-va.md section 6)
-- =====================================================================================
-- Each measure is the share of its cases that met the target in the week (Monday to Sunday, Toronto):
-- a task met its target when it was done by its due time; a task still open after its due time missed.
-- The daily checks measure counts the checks done by 9:00 and 18:00. Two weeks under 90% in a row means
-- a review.
create or replace function app.staff_scorecard(p_staff uuid, p_weeks integer default 6) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_fn text := app.va_active_fn(p_staff);
  v_measures jsonb;
  m jsonb;
  v_week date;
  v_from timestamptz;
  v_to timestamptz;
  v_met integer;
  v_total integer;
  v_rows jsonb;
  v_weeks jsonb := '[]'::jsonb;
  v_sum_met integer;
  v_sum_total integer;
  v_low integer := 0;
  v_review boolean := false;
  i integer;
begin
  select coalesce(jsonb_agg(jsonb_build_object('fn', x.fn, 'name', x.name, 'target', x.target, 'types', to_jsonb(x.types)) order by x.ord), '[]'::jsonb)
    into v_measures
    from (values
      (1, 'finance', 'Deposit balance released', '7 business days; aim for 2', array['release_deposit', 'settle_holdback', 'approve_deposit_release']),
      (2, 'finance', 'Refunds paid', '10 business days; aim for 2', array['refund_cancellation']),
      (3, 'finance', 'Tolls and tickets matched and charged', '3 business days, before the due date', array['match_toll', 'review_toll_match', 'review_damage_match']),
      (4, 'finance', 'Processor payouts matched to the bookings', 'Every day, nothing unmatched', array['reconcile', 'unmatched_payment']),
      (5, 'finance', 'Fleet report, payouts and owner billing', 'Same day', array['fleet_report', 'review_statements', 'debit_failed', 'arrears', 'collect_upfront']),
      (6, 'fleet', 'Opening checks by 9:00, closing by 18:00', 'Every day', array['_daily_checks']),
      (7, 'fleet', 'Car ready before pickup', '30 minutes', array['schedule_handover', 'schedule_detail']),
      (8, 'fleet', 'Handover and return photos reviewed', '1 hour', array['review_photos']),
      (9, 'fleet', 'Late returns and roadside handled', '15 minutes', array['late_return', 'breakdown', 'incident', 'field_report']),
      (10, 'cs', 'First reply in opening hours', '15 minutes', array['booking_request', 'enquiry', 'offer_change_requested', 'renter_message', 'reoffer_booking']),
      (11, 'cs', 'Verification and coverage proof complete', '24 hours before pickup', array['verify_renter', 'chase_verification']),
      (12, 'cs', 'Owner inquiries answered', '1 business day', array['owner_intake', 'check_owner_document', 'owner_lead']),
      (13, 'cs', 'Extensions confirmed and paid', 'Before the return time', array['review_extension']),
      (14, 'sales', 'Quote sent', '15 minutes', array['booking_request', 'owner_lead']),
      (15, 'sales', 'Tentative holds followed up', 'Before the expiry', array['chase_offer', 'offer_expired'])) x(ord, fn, name, target, types)
   where x.fn = v_fn;
  for i in reverse greatest(p_weeks, 1) - 1 .. 0 loop
    v_week := date_trunc('week', app.today())::date - (7 * i);
    v_from := app.local_midnight(v_week);
    v_to := app.local_midnight(v_week + 7);
    v_rows := '[]'::jsonb; v_sum_met := 0; v_sum_total := 0;
    for m in select * from jsonb_array_elements(v_measures) loop
      if m -> 'types' ? '_daily_checks' then
        select count(*) filter (where dc.completed_at <= app.local_midnight(dc.check_date) + case when dc.kind = 'opening' then interval '9 hours' else interval '18 hours' end),
               greatest(2 * (least(v_week + 7, app.today() + 1) - v_week), 0)
          into v_met, v_total
          from daily_checks dc where dc.check_date >= v_week and dc.check_date < v_week + 7 and dc.completed_by = p_staff;
      else
        select count(*) filter (where t.status = 'done' and (t.due_at is null or t.completed_at <= t.due_at)),
               count(*) filter (where t.status = 'done' or (t.due_at is not null and t.due_at < now()))
          into v_met, v_total
          from tasks t
         where t.task_type = any (array(select jsonb_array_elements_text(m -> 'types')))
           and (t.assigned_to = p_staff or t.completed_by = p_staff)
           and t.status <> 'cancelled'
           and coalesce(t.due_at, t.completed_at) >= v_from and coalesce(t.due_at, t.completed_at) < v_to;
      end if;
      v_rows := v_rows || jsonb_build_object('name', m ->> 'name', 'target', m ->> 'target', 'met', v_met, 'total', v_total,
                                             'score_pct', case when v_total > 0 then round(100.0 * v_met / v_total) end);
      v_sum_met := v_sum_met + v_met; v_sum_total := v_sum_total + v_total;
    end loop;
    v_weeks := v_weeks || jsonb_build_object('week_start', v_week, 'measures', v_rows,
                                             'score_pct', case when v_sum_total > 0 then round(100.0 * v_sum_met / v_sum_total) end);
    if v_sum_total > 0 and 100.0 * v_sum_met / v_sum_total < 90 then v_low := v_low + 1; if v_low >= 2 then v_review := true; end if;
    else v_low := 0; end if;
  end loop;
  return jsonb_build_object('staff_id', p_staff, 'name', (select full_name from users where id = p_staff), 'function', v_fn,
                            'weeks', v_weeks, 'review', v_review);
end $$;

-- =====================================================================================
-- F. Field staff: a checklist for every job kind (06-field.md section 7), the incident report
--    (section 9), referrals and profile (section 10)
-- =====================================================================================
-- The steps of a kind. type: tick (OK or Problem; a Problem needs a note), choice, text, number,
-- photos (taken in the page, stored privately; min = how many at least), serial, shots (the job's
-- condition report photo set, as the handover's), listing (the listing capture), rules (read and tick).
create or replace function app.field_checklist(p_kind text, p_reshoot boolean default false) returns jsonb
language sql immutable as $$
  select case
    when p_reshoot then jsonb_build_array(
      jsonb_build_object('key', 'reshoot', 'type', 'reshoot', 'label', 'Take the shots asked for again', 'help', 'Same position and framing as the guide for each shot.', 'required', true),
      jsonb_build_object('key', 'notes', 'type', 'text', 'label', 'Anything Fleet should know', 'required', false))
    when p_kind = 'detail' then jsonb_build_array(
      jsonb_build_object('key', 'grade', 'type', 'choice', 'label', 'How the car came in', 'required', true,
                         'options', jsonb_build_array(jsonb_build_array('standard', 'Standard clean'), jsonb_build_array('cleaning', 'Needs extra cleaning'),
                                                      jsonb_build_array('heavy', 'Heavy soiling or odour'), jsonb_build_array('pet', 'Pet hair'), jsonb_build_array('smoking', 'Smoking evidence'))),
      jsonb_build_object('key', 'before', 'type', 'photos', 'label', 'Photos before cleaning', 'help', 'Needed for anything beyond a standard clean.', 'required', false, 'min', 0),
      jsonb_build_object('key', 'belongings', 'type', 'text', 'label', 'Belongings found (bagged and labelled)', 'help', 'Leave empty if none.', 'required', false),
      jsonb_build_object('key', 'exterior', 'type', 'tick', 'label', 'Exterior washed and dried; wheels, glass and mirrors', 'required', true),
      jsonb_build_object('key', 'interior', 'type', 'tick', 'label', 'Interior vacuumed and wiped, glass clean, no odour', 'required', true),
      jsonb_build_object('key', 'checks', 'type', 'tick', 'label', 'Washer fluid, tire pressures, no warning lights', 'help', 'A warning light: Problem, with a photo. Fleet decides.', 'required', true, 'stop', true),
      jsonb_build_object('key', 'fuel', 'type', 'tick', 'label', 'Fuel full, or charge at 80% or more', 'required', true),
      jsonb_build_object('key', 'items', 'type', 'tick', 'label', 'In the car: permit, insurance slip, charging cable, spare and tools, extras for the next booking', 'required', true),
      jsonb_build_object('key', 'ready', 'type', 'shots', 'label', 'Ready photos', 'help', 'Front, rear, front seats and the instrument cluster.', 'required', true))
    when p_kind = 'photo_shoot' then jsonb_build_array(
      jsonb_build_object('key', 'conditions', 'type', 'rules', 'label', 'Daylight, plain background, landscape', 'required', true,
                         'text', 'Shoot in daylight against a plain background, phone held landscape. Remove plates from view where you can; the reviewer checks plates.'),
      jsonb_build_object('key', 'listing', 'type', 'listing', 'label', 'The listing photos', 'help', 'The shot list of the listing; then Submit for listing.', 'required', true),
      jsonb_build_object('key', 'notes', 'type', 'text', 'label', 'Notes for the reviewer', 'required', false))
    when p_kind = 'tracker_install' then jsonb_build_array(
      jsonb_build_object('key', 'serial', 'type', 'serial', 'label', 'Device serial number', 'help', 'Scan or type the serial on the device label.', 'required', true),
      jsonb_build_object('key', 'installed', 'type', 'tick', 'label', 'Installed out of sight, wiring secured', 'required', true),
      jsonb_build_object('key', 'tests', 'type', 'tick', 'label', 'Tested while parked: locate, lock, unlock, alarm and shut-off each confirmed', 'required', true),
      jsonb_build_object('key', 'photo', 'type', 'photos', 'label', 'Photo of the device in place', 'required', true, 'min', 1))
    when p_kind = 'tracker_removal' then jsonb_build_array(
      jsonb_build_object('key', 'removed', 'type', 'tick', 'label', 'Device removed, wiring restored', 'required', true),
      jsonb_build_object('key', 'odometer', 'type', 'number', 'label', 'Odometer (km)', 'required', true),
      jsonb_build_object('key', 'exit_photos', 'type', 'photos', 'label', 'Exit photos: front, rear, both sides, the cluster', 'required', true, 'min', 4))
    when p_kind = 'registry_run' then jsonb_build_array(
      jsonb_build_object('key', 'documents', 'type', 'tick', 'label', 'Documents carried: ownership permit, forms, owner''s authorization, insurance slip', 'required', true),
      jsonb_build_object('key', 'permit', 'type', 'photos', 'label', 'Photo of the new permit', 'required', true, 'min', 1),
      jsonb_build_object('key', 'notes', 'type', 'text', 'label', 'What was done at the office', 'required', false))
    when p_kind = 'recovery' then jsonb_build_array(
      jsonb_build_object('key', 'rules', 'type', 'rules', 'label', 'How a car is recovered', 'required', true,
                         'text', 'Peacefully, from a street, a driveway or an open lot. Never by force, never from a dwelling or a locked garage. If anyone objects, leave and call CarmaCars.'),
      jsonb_build_object('key', 'arrival', 'type', 'photos', 'label', 'Photos on arrival, before touching the car', 'required', true, 'min', 2),
      jsonb_build_object('key', 'where', 'type', 'text', 'label', 'Where the car was found', 'required', true),
      jsonb_build_object('key', 'secured', 'type', 'tick', 'label', 'Car secured and on its way back', 'required', true, 'stop', true))
    else jsonb_build_array(
      jsonb_build_object('key', 'done', 'type', 'tick', 'label', 'Done as instructed', 'required', true),
      jsonb_build_object('key', 'photos', 'type', 'photos', 'label', 'Photos', 'required', false, 'min', 0),
      jsonb_build_object('key', 'notes', 'type', 'text', 'label', 'Notes', 'required', false))
  end
$$;

-- The checklist part of a job: its steps, the answers so far, and what each step still needs.
create or replace function app.field_job_checklist(p_job field_jobs) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_steps jsonb := app.field_checklist(p_job.kind, p_job.reshoot_report_id is not null);
  s jsonb;
  a jsonb;
  v_missing text[] := '{}';
  v_intake listing_intakes;
  v_report condition_reports;
  v_have text[];
begin
  if p_job.kind = 'photo_shoot' then
    select * into v_intake from listing_intakes x where x.vehicle_id = p_job.vehicle_id and x.state <> 'cancelled' order by x.created_at desc limit 1;
  end if;
  if p_job.kind = 'detail' then
    select * into v_report from condition_reports r where r.field_job_id = p_job.id and r.kind = 'ready' order by r.created_at desc limit 1;
  end if;
  for s in select * from jsonb_array_elements(v_steps) loop
    a := p_job.checklist -> (s ->> 'key');
    if not coalesce((s ->> 'required')::boolean, false) and s ->> 'type' not in ('photos') then continue; end if;
    case s ->> 'type'
    when 'tick' then if coalesce(a ->> 'v', '') not in ('ok', 'problem') then v_missing := v_missing || (s ->> 'label'); end if;
    when 'rules' then if coalesce(a ->> 'v', '') <> 'ok' then v_missing := v_missing || (s ->> 'label'); end if;
    when 'choice', 'text', 'serial', 'number' then if nullif(btrim(coalesce(a ->> 'v', '')), '') is null then v_missing := v_missing || (s ->> 'label'); end if;
    when 'photos' then
      if coalesce(jsonb_array_length(case when jsonb_typeof(a -> 'photos') = 'array' then a -> 'photos' end), 0) < coalesce((s ->> 'min')::integer, 0)
         or (s ->> 'key' = 'before' and coalesce(p_job.checklist -> 'grade' ->> 'v', 'standard') <> 'standard'
             and coalesce(jsonb_array_length(case when jsonb_typeof(a -> 'photos') = 'array' then a -> 'photos' end), 0) = 0) then
        v_missing := v_missing || (s ->> 'label');
      end if;
    when 'shots' then
      select array_agg(ph.shot) into v_have from condition_report_photos ph where ph.condition_report_id = v_report.id;
      if v_report.id is null or exists (select 1 from app.required_shots_for('ready', (select class from vehicles where id = p_job.vehicle_id)) q
                                         where not q.shot = any (coalesce(v_have, '{}'))) then
        v_missing := v_missing || (s ->> 'label');
      end if;
    when 'listing' then
      if v_intake.id is null or v_intake.submitted_at is null or v_intake.submitted_at < p_job.created_at then v_missing := v_missing || (s ->> 'label'); end if;
    when 'reshoot' then
      if exists (select 1 from unnest(coalesce(p_job.reshoot_shots, '{}')) q(shot)
                  where not exists (select 1 from condition_report_photos ph where ph.condition_report_id = p_job.reshoot_report_id and ph.shot = q.shot
                                       and ph.taken_at >= p_job.created_at)) then
        v_missing := v_missing || (s ->> 'label');
      end if;
    else null;
    end case;
  end loop;
  return jsonb_build_object('steps', v_steps, 'answers', p_job.checklist, 'missing', to_jsonb(v_missing),
    'listing', case when v_intake.id is null then null else jsonb_build_object('intake_id', v_intake.id, 'state', v_intake.state, 'submitted_at', v_intake.submitted_at) end,
    'reshoot', case when p_job.reshoot_report_id is null then null else jsonb_build_object('report_id', p_job.reshoot_report_id,
      'kind', (select kind from condition_reports where id = p_job.reshoot_report_id),
      'shots', coalesce((select jsonb_agg(jsonb_build_object('seq', s2.seq, 'shot', s2.shot, 'guide', s2.guide,
                           'done', exists (select 1 from condition_report_photos ph where ph.condition_report_id = p_job.reshoot_report_id and ph.shot = s2.shot and ph.taken_at >= p_job.created_at)) order by s2.seq)
                         from app.required_shots_for((select kind from condition_reports where id = p_job.reshoot_report_id), (select class from vehicles where id = p_job.vehicle_id)) s2
                        where s2.shot = any (p_job.reshoot_shots)), '[]'::jsonb)) end);
end $$;

-- Completes a job of any kind but the handover and return (those finish with their reports).
create or replace function app.field_complete_job(p_user uuid, p_job uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
  c jsonb;
  s jsonb;
  a jsonb;
  v_problems text[] := '{}';
  v_doc uuid;
  v_key text;
  v_bucket text;
begin
  j := app.field_job_of(p_user, p_job);
  if j.id is null then raise exception 'That job is not one of yours' using errcode = '42501'; end if;
  if j.status <> 'in_progress' then raise exception 'Start the job first' using errcode = '23514'; end if;
  if j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter') then
    raise exception 'A % job is completed with its Condition Report', replace(j.kind, '_', ' ') using errcode = '23514';
  end if;
  c := app.field_job_checklist(j);
  if jsonb_array_length(c -> 'missing') > 0 then
    raise exception 'Still to do: %', (select string_agg(x, '; ') from jsonb_array_elements_text(c -> 'missing') x) using errcode = '23514';
  end if;
  for s in select * from jsonb_array_elements(c -> 'steps') loop
    a := j.checklist -> (s ->> 'key');
    if a ->> 'v' = 'problem' then v_problems := v_problems || format('%s: %s', s ->> 'label', coalesce(nullif(btrim(a ->> 'note'), ''), 'problem')); end if;
  end loop;

  -- what each kind records
  if j.kind = 'tracker_install' then
    v_key := btrim(j.checklist -> 'serial' ->> 'v');
    if exists (select 1 from tracker_devices d where d.serial_number = v_key and d.status = 'installed' and d.vehicle_id is distinct from j.vehicle_id) then
      raise exception 'Device % is recorded on another car: check the serial', v_key using errcode = '23514';
    end if;
    update tracker_devices set status = 'removed', removed_at = now(), removed_by = p_user
     where vehicle_id = j.vehicle_id and status = 'installed' and serial_number <> v_key;
    insert into tracker_devices (serial_number, vehicle_id, status, installed_at, installed_by, tested_at)
    values (v_key, j.vehicle_id, 'installed', now(), p_user, case when j.checklist -> 'tests' ->> 'v' = 'ok' then now() end)
    on conflict (serial_number) do update set vehicle_id = excluded.vehicle_id, status = 'installed', installed_at = now(), installed_by = p_user,
                                              tested_at = excluded.tested_at, removed_at = null, removed_by = null;
    -- the onboarding step (0029's app.record_tracker_installed, which is an Admin's; here the installer's record)
    update vehicles set tracker_install_pending = false, tracker_installed_on = coalesce(tracker_installed_on, app.today()) where id = j.vehicle_id;
  elsif j.kind = 'tracker_removal' then
    update tracker_devices set status = 'removed', removed_at = now(), removed_by = p_user where vehicle_id = j.vehicle_id and status = 'installed';
    update vehicle_exits set tracker_removed_at = coalesce(tracker_removed_at, now()), exit_odometer_km = coalesce(exit_odometer_km, (j.checklist -> 'odometer' ->> 'v')::integer)
     where id = (select x.id from vehicle_exits x where x.vehicle_id = j.vehicle_id and x.status not in ('withdrawn', 'completed') order by x.created_at desc limit 1);
  elsif j.kind = 'registry_run' then
    v_key := j.checklist -> 'permit' -> 'photos' ->> 0;
    v_bucket := 'condition-photos';
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, retention, uploaded_by, vehicle_id)
    values ('ownership_permit', 'Ownership permit (registry run ' || app.fmt_day(app.today()) || ')', v_bucket, v_key,
            case when v_key like '%.png' then 'image/png' else 'image/jpeg' end, 'records_7y', p_user, j.vehicle_id)
    returning id into v_doc;
    perform app.raise_task(p_type => 'record_registration', p_title => 'Record the registration: ' || app.vehicle_name(j.vehicle_id),
      p_detail => coalesce(nullif(btrim(j.checklist -> 'notes' ->> 'v'), ''), 'The new permit is on the vehicle''s documents.'),
      p_vehicle => j.vehicle_id, p_related_table => 'documents', p_related_id => v_doc, p_dedupe => 'record_registration:' || j.id, p_created_by => p_user);
  elsif j.kind = 'recovery' then
    perform app.raise_task(p_type => 'recovery_done', p_title => 'Recovered: ' || app.vehicle_name(j.vehicle_id),
      p_detail => 'Found: ' || coalesce(j.checklist -> 'where' ->> 'v', '') || '. Run the return checklist and update the incident.',
      p_booking => j.booking_id, p_vehicle => j.vehicle_id, p_related_table => 'field_jobs', p_related_id => j.id, p_dedupe => 'recovery_done:' || j.id, p_created_by => p_user);
  end if;

  perform app.complete_field_job(j.id, p_user, jsonb_strip_nulls(jsonb_build_object(
    'cleaning_grade', case when j.kind = 'detail' then j.checklist -> 'grade' ->> 'v' end,
    'belongings_found', nullif(btrim(coalesce(j.checklist -> 'belongings' ->> 'v', '')), ''),
    'fuel_or_charge_ok', case when j.kind = 'detail' then j.checklist -> 'fuel' ->> 'v' = 'ok' end,
    'odometer_km', case when j.kind = 'tracker_removal' then (j.checklist -> 'odometer' ->> 'v')::integer end)), now());
  if cardinality(v_problems) > 0 then
    perform app.raise_task(p_type => 'field_job_problem', p_title => initcap(replace(j.kind, '_', ' ')) || ': ' || app.vehicle_name(j.vehicle_id),
      p_detail => array_to_string(v_problems, E'\n'), p_booking => j.booking_id, p_vehicle => j.vehicle_id, p_related_table => 'field_jobs', p_related_id => j.id,
      p_dedupe => 'field_job_problem:' || j.id, p_created_by => p_user);
  end if;
  return jsonb_build_object('status', 'done', 'problems', cardinality(v_problems));
end $$;

-- One re-shot photo onto the report it belongs to (the earlier photo of that shot is replaced).
create or replace function app.field_reshoot_photo(p_user uuid, p_job uuid, p_shot text, p_bucket text, p_path text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  j field_jobs;
  v_seq integer;
begin
  j := app.field_job_of(p_user, p_job);
  if j.id is null then raise exception 'That job is not one of yours' using errcode = '42501'; end if;
  if j.reshoot_report_id is null or not p_shot = any (j.reshoot_shots) then raise exception 'That shot was not asked for' using errcode = '22023'; end if;
  if j.status <> 'in_progress' then raise exception 'Start the job first' using errcode = '23514'; end if;
  select s.seq into v_seq from app.required_shots_for((select kind from condition_reports where id = j.reshoot_report_id), (select class from vehicles where id = j.vehicle_id)) s
   where s.shot = p_shot;
  delete from condition_report_photos where condition_report_id = j.reshoot_report_id and shot = p_shot;
  insert into condition_report_photos (condition_report_id, seq, shot, storage_bucket, storage_path, taken_at, uploaded_by)
  values (j.reshoot_report_id, coalesce(v_seq, 900), p_shot, p_bucket, p_path, now(), p_user);
  return jsonb_build_object('shot', p_shot);
end $$;

-- The incident report from the field (06-field.md section 9).
create or replace function app.field_report(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_vehicle uuid := (p_ ->> 'vehicle')::uuid;
  v_what text := p_ ->> 'what';
  v_details text := btrim(coalesce(p_ ->> 'details', ''));
  v_hurt boolean := coalesce((p_ ->> 'anyone_hurt')::boolean, false);
  v_photos text[] := array(select jsonb_array_elements_text(case when jsonb_typeof(p_ -> 'photos') = 'array' then p_ -> 'photos' else '[]'::jsonb end));
  v_booking uuid;
  v_incident uuid;
  v_task uuid;
  v_kind text;
  k text;
begin
  if not exists (select 1 from field_jobs x where x.assigned_to = p_user and x.vehicle_id = v_vehicle and x.status <> 'cancelled'
                   and x.scheduled_at between now() - interval '2 days' and now() + interval '36 hours') then
    raise exception 'Report on a car of one of your jobs' using errcode = '42501';
  end if;
  if v_what not in ('new_damage', 'warning_light', 'collision', 'ticket_or_toll', 'lost_property', 'other') then
    raise exception 'Choose what happened' using errcode = '22023';
  end if;
  if length(v_details) < 10 then raise exception 'Describe what happened (10 characters or more)' using errcode = '22023'; end if;
  if v_what = 'new_damage' and cardinality(v_photos) = 0 then raise exception 'Add a photo of the damage' using errcode = '22023'; end if;
  if cardinality(v_photos) > 10 then raise exception 'Up to 10 photos' using errcode = '22023'; end if;
  select b.id into v_booking from bookings b where b.vehicle_id = v_vehicle and b.status = 'on_rent' order by b.pickup_at desc limit 1;
  v_kind := case v_what when 'new_damage' then 'damage_found_later' when 'collision' then 'accident' else null end;
  if v_kind is not null then
    v_incident := app.open_incident(v_kind, v_vehicle, p_user,
      jsonb_build_object('description', v_details, 'anyone_hurt', case when v_what = 'collision' then v_hurt end, 'staff_had_car', v_what = 'collision'),
      case when v_what = 'collision' then null else v_booking end, 'field', now());
    if v_what = 'collision' then update incidents set staff_user_id = p_user where id = v_incident; end if;
  end if;
  if v_incident is null then
    v_task := app.raise_task(p_type => case when v_what = 'lost_property' then 'lost_property' else 'field_report' end,
      p_title => initcap(replace(v_what, '_', ' ')) || ': ' || app.vehicle_name(v_vehicle),
      p_detail => v_details, p_vehicle => v_vehicle, p_booking => case when v_what = 'ticket_or_toll' then null else v_booking end,
      p_queue => case when v_what = 'ticket_or_toll' then 'finance' when v_what = 'lost_property' then 'cs' else 'fleet' end,
      p_priority => case when v_what = 'warning_light' then 'urgent' end, p_created_by => p_user);
  else
    -- the incident's own tasks (0020's trigger: urgent for Fleet, and a copy for an Admin at once)
    select t.id into v_task from tasks t where t.related_table = 'incidents' and t.related_id = v_incident and t.queue = 'fleet' order by t.created_at limit 1;
  end if;
  foreach k in array v_photos loop
    if k !~ '^(vehicles|bookings)/[0-9a-f-]{36}/[a-z_]+/[A-Za-z0-9_.-]+\.(jpg|png)$' then raise exception 'Unknown photo' using errcode = '22023'; end if;
    insert into documents (kind, title, storage_bucket, storage_path, mime_type, retention, uploaded_by, vehicle_id, incident_id)
    values ('incident_report', 'Field report photo', 'condition-photos', k, case when k like '%.png' then 'image/png' else 'image/jpeg' end,
            'records_7y', p_user, v_vehicle, v_incident);
  end loop;
  return jsonb_build_object('task_id', v_task, 'incident_id', v_incident);
end $$;

create or replace function app.field_referrals(p_user uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_code text;
begin
  select referral_code into v_code from staff_profiles where user_id = p_user and staff_type = 'field';
  if v_code is null then
    loop
      v_code := upper(substr(translate(md5(random()::text || clock_timestamp()::text || p_user::text), '01', ''), 1, 7));
      exit when length(v_code) = 7 and not exists (select 1 from staff_profiles where referral_code = v_code)
                and not exists (select 1 from owners where referral_code = v_code);
    end loop;
    update staff_profiles set referral_code = v_code where user_id = p_user and staff_type = 'field';
  end if;
  return jsonb_build_object('code', v_code, 'rate_bps', (app.settings()).kickback_bps,
    'kickbacks', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'month', date_trunc('month', coalesce(k.earned_on, k.created_at::date))::date,
                             'amount_cents', k.amount_cents, 'status', k.status, 'payroll_period', k.payroll_period) order by k.created_at desc)
                            from referral_kickbacks k join bookings b on b.id = k.booking_id where k.referrer_staff_id = p_user), '[]'::jsonb));
end $$;

create or replace function app.field_profile(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('name', u.full_name, 'email', u.email, 'phone', u.phone, 'field_function', sp.field_function, 'started_on', sp.started_on,
                            'referral_code', sp.referral_code)
    from users u join staff_profiles sp on sp.user_id = u.id where u.id = p_user
$$;

-- =====================================================================================
-- G. The door: the new screens and actions
-- =====================================================================================
create or replace function app.gap_va_read(p_user uuid, p_what text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_fn text := app.va_fn(p_user);
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_b uuid;
begin
  if p_ ? 'booking' then
    select b.id into v_b from bookings b where b.id::text = p_ ->> 'booking' or b.booking_number = p_ ->> 'booking';
  end if;
  case p_what
  when 'functions' then
    return jsonb_build_object('active', v_fn, 'functions', app.my_roles(p_user) -> 'va_functions');
  when 'scorecard' then
    return app.staff_scorecard(p_user, coalesce((p_ ->> 'weeks')::integer, 6));
  when 'turo_trips' then
    if v_fn <> 'finance' then raise exception 'Turo trips are Finance work' using errcode = '42501'; end if;
    return jsonb_build_object(
      'trips', coalesce((select jsonb_agg(jsonb_build_object('id', t.id, 'turo_trip_ref', t.turo_trip_ref, 'vehicle', app.vehicle_name(t.vehicle_id), 'plate', v.plate,
                            'starts_at', t.starts_at, 'ends_at', t.ends_at, 'gross_cents', t.gross_cents, 'turo_fees_cents', t.turo_fees_cents,
                            'revenue_share_bps', t.revenue_share_bps, 'revenue_share_cents', t.revenue_share_cents, 'owner_payout_cents', t.owner_payout_cents,
                            'company_extras_cents', t.company_extras_cents, 'damage_payment_cents', t.damage_payment_cents,
                            'statement_month', t.statement_month, 'on_statement', t.owner_statement_id is not null) order by t.ends_at desc)
                         from (select * from turo_trips order by ends_at desc limit 200) t join vehicles v on v.id = t.vehicle_id), '[]'::jsonb),
      'vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id) || coalesce(' · ' || v.plate, '')) order by v.make, v.model)
                             from vehicles v where v.status::text not in ('exited', 'total_loss', 'declined')), '[]'::jsonb));
  when 'daily_check' then
    if v_fn <> 'fleet' then raise exception 'The daily checks are Fleet work' using errcode = '42501'; end if;
    return app.daily_check_form(coalesce((p_ ->> 'date')::date, app.today()), coalesce(p_ ->> 'kind', 'opening'));
  when 'photo_review' then
    if v_fn <> 'fleet' then raise exception 'Photo review is Fleet work' using errcode = '42501'; end if;
    return app.photo_review(v_b) || jsonb_build_object('staff', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.full_name) order by u.full_name)
                                                                         from users u where app.user_is_field(u.id)), '[]'::jsonb));
  when 'late_panel' then
    if v_fn not in ('fleet', 'cs') then raise exception 'Late returns are Fleet work' using errcode = '42501'; end if;
    return app.late_panel(v_b);
  when 'find_renter' then
    if v_fn not in ('cs', 'finance', 'fleet') then raise exception 'Not permitted' using errcode = '42501'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('renter_id', x.renter_id, 'legal_name', x.legal_name, 'last_booking_number', x.last_booking_number,
                                                         'in_window', app.va_sees_renter(x.renter_id)))
                       from app.staff_find_renter(p_ ->> 'q') x), '[]'::jsonb);
  when 'renter' then
    if v_fn not in ('cs', 'finance', 'fleet') then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.renter_view((p_ ->> 'id')::uuid);
  when 'quote_form' then
    if v_fn not in ('sales', 'cs') then raise exception 'Not permitted' using errcode = '42501'; end if;
    return jsonb_build_object('vehicles', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'class', v.class) order by v.make, v.model)
                                                     from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'), '[]'::jsonb),
                              'min_notice_minutes', (app.settings()).booking_min_notice_minutes);
  else
    raise exception 'Unknown screen %', p_what using errcode = '22023';
  end case;
end $$;

create or replace function app.gap_va_do(p_user uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_fn text := app.va_fn(p_user);
  p_ jsonb := coalesce(p, '{}'::jsonb);
  b bookings;
  r jsonb;
  v_ok integer := 0;
  v_errors jsonb := '[]'::jsonb;
  i integer := 0;
begin
  if p_ ? 'booking' then
    select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking';
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    if v_fn = 'sales' and b.status not in ('requested', 'offered') then
      raise exception 'Sales works on requests and offers only' using errcode = '42501';
    end if;
  end if;
  case p_action
  when 'send_message' then
    if v_fn not in ('cs', 'sales') then raise exception 'Renter messages are customer service work' using errcode = '42501'; end if;
    if b.id is null then raise exception 'A message belongs to a booking' using errcode = '22023'; end if;
    return app.staff_send_message(p_user, b.id, p_ ->> 'subject', p_ ->> 'body');
  when 'turo_trip_save' then
    if v_fn <> 'finance' then raise exception 'Turo trips are Finance work' using errcode = '42501'; end if;
    return app.save_turo_trip(p_user, p_);
  when 'turo_trip_import' then
    if v_fn <> 'finance' then raise exception 'Turo trips are Finance work' using errcode = '42501'; end if;
    for r in select * from jsonb_array_elements(case when jsonb_typeof(p_ -> 'rows') = 'array' then p_ -> 'rows' else '[]'::jsonb end) loop
      i := i + 1;
      begin
        perform app.save_turo_trip(p_user, r);
        v_ok := v_ok + 1;
      exception when others then
        v_errors := v_errors || jsonb_build_object('row', i, 'ref', r ->> 'turo_trip_ref', 'message', sqlerrm);
      end;
    end loop;
    return jsonb_build_object('saved', v_ok, 'errors', v_errors);
  when 'reconcile_record' then
    if v_fn <> 'finance' then raise exception 'Reconciliation is Finance work' using errcode = '42501'; end if;
    perform app.va_delegate(p_user);
    return app.admin_do(p_user, 'reconcile_record', p_);
  when 'daily_check_save' then
    if v_fn <> 'fleet' then raise exception 'The daily checks are Fleet work' using errcode = '42501'; end if;
    return app.save_daily_check(p_user, coalesce((p_ ->> 'date')::date, app.today()), p_ ->> 'kind', coalesce(p_ -> 'items', '{}'::jsonb), p_ ->> 'issues');
  when 'request_reshoot' then
    if v_fn <> 'fleet' then raise exception 'Re-shoots are asked for by Fleet' using errcode = '42501'; end if;
    return app.request_reshoot(p_user, b.id, coalesce(p_ ->> 'which', 'return'),
      array(select jsonb_array_elements_text(case when jsonb_typeof(p_ -> 'shots') = 'array' then p_ -> 'shots' else '[]'::jsonb end)),
      nullif(p_ ->> 'to', '')::uuid, nullif(p_ ->> 'at', '')::timestamptz, p_ ->> 'note');
  when 'late_call', 'late_t13', 'late_t14', 'late_disable', 'late_incident' then
    if v_fn not in ('fleet', 'cs') or (v_fn = 'cs' and p_action in ('late_disable', 'late_incident')) then
      raise exception 'The % assistant cannot %', v_fn, replace(p_action, '_', ' ') using errcode = '42501';
    end if;
    return app.late_action(p_user, b.id, substr(p_action, 6), p_);
  when 'open_renter' then
    if v_fn not in ('cs', 'finance', 'fleet') then raise exception 'Not permitted' using errcode = '42501'; end if;
    perform app.staff_open_renter((p_ ->> 'renter')::uuid, p_ ->> 'reason');
    return app.renter_view((p_ ->> 'renter')::uuid);
  when 'quote_create' then
    if v_fn not in ('sales', 'cs') then raise exception 'Not permitted' using errcode = '42501'; end if;
    return app.staff_quote_request(p_user, p_);
  else
    raise exception 'Unknown action %', p_action using errcode = '22023';
  end case;
end $$;

create or replace function app.gap_field_read(p_user uuid, p_what text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  j field_jobs;
  v jsonb;
begin
  if not app.user_is_field(p_user) then raise exception 'Only field staff may do this' using errcode = '42501'; end if;
  case p_what
  when 'job' then
    v := app.field_read(p_user, 'job', p_);
    if v is null then return null; end if;
    j := app.field_job_of(p_user, (p_ ->> 'id')::uuid);
    return v || jsonb_build_object('checklist', case when j.kind in ('handover', 'delivery', 'return_check_in', 'pickup_from_renter') and j.reshoot_report_id is null then null
                                                     else app.field_job_checklist(j) end);
  when 'report_form' then
    return jsonb_build_object('vehicles', coalesce((select jsonb_agg(distinct jsonb_build_object('id', x.vehicle_id, 'name', app.vehicle_name(x.vehicle_id) || coalesce(' · ' || v2.plate, ''),
                                                     'job', (select y.id from field_jobs y where y.assigned_to = p_user and y.vehicle_id = x.vehicle_id and y.status <> 'cancelled'
                                                               and y.scheduled_at between now() - interval '2 days' and now() + interval '36 hours' order by y.scheduled_at desc limit 1)))
                                                     from field_jobs x join vehicles v2 on v2.id = x.vehicle_id where x.assigned_to = p_user and x.status <> 'cancelled'
                                                      and x.scheduled_at between now() - interval '2 days' and now() + interval '36 hours'), '[]'::jsonb));
  when 'referrals' then
    return app.field_referrals(p_user);
  when 'profile' then
    return app.field_profile(p_user);
  else
    raise exception 'Unknown screen %', p_what using errcode = '22023';
  end case;
end $$;

create or replace function app.gap_field_do(p_user uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  j field_jobs;
  v_phone text;
begin
  if not app.user_is_field(p_user) then raise exception 'Only field staff may do this' using errcode = '42501'; end if;
  case p_action
  when 'checklist_save' then
    j := app.field_job_of(p_user, (p_ ->> 'job')::uuid);
    if j.id is null then raise exception 'That job is not one of yours' using errcode = '42501'; end if;
    if j.status <> 'in_progress' then raise exception 'Start the job first' using errcode = '23514'; end if;
    if jsonb_typeof(p_ -> 'answers') <> 'object' then raise exception 'Nothing to save' using errcode = '22023'; end if;
    -- only the steps of this kind, each answer a small object
    update field_jobs set checklist = checklist || (select coalesce(jsonb_object_agg(k, a), '{}'::jsonb) from jsonb_each(p_ -> 'answers') e(k, a)
                                                     where k in (select s ->> 'key' from jsonb_array_elements(app.field_checklist(j.kind, j.reshoot_report_id is not null)) s)
                                                       and jsonb_typeof(a) = 'object' and length(a::text) < 8000)
     where id = j.id returning * into j;
    return app.field_job_checklist(j);
  when 'complete_job' then
    return app.field_complete_job(p_user, (p_ ->> 'job')::uuid);
  when 'reshoot_photo' then
    return app.field_reshoot_photo(p_user, (p_ ->> 'job')::uuid, p_ ->> 'shot', p_ ->> 'bucket', p_ ->> 'path');
  when 'report' then
    return app.field_report(p_user, p_);
  when 'profile_save' then
    v_phone := nullif(btrim(coalesce(p_ ->> 'phone', '')), '');
    if v_phone is not null and v_phone !~ '^\+?[0-9 ()-]{7,20}$' then raise exception 'Enter a phone number' using errcode = '22023'; end if;
    update users set phone = v_phone where id = p_user;
    return app.field_profile(p_user);
  else
    raise exception 'Unknown action %', p_action using errcode = '22023';
  end case;
end $$;

create or replace function app.gap_admin_read(p_user uuid, p_what text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_user);
  case p_what
  when 'scorecard' then
    if not exists (select 1 from staff_profiles where user_id = (p ->> 'staff')::uuid and staff_type = 'va') then
      raise exception 'A scorecard is kept for assistants' using errcode = '22023';
    end if;
    return app.staff_scorecard((p ->> 'staff')::uuid, coalesce((p ->> 'weeks')::integer, 6));
  else
    raise exception 'Unknown screen %', p_what using errcode = '22023';
  end case;
end $$;

create or replace function app.gap_admin_do(p_user uuid, p_action text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_user);
  case p_action
  when 'staff_cover' then
    return app.set_cover_functions(p_user, (p ->> 'user')::uuid, array(select jsonb_array_elements_text(case when jsonb_typeof(p -> 'functions') = 'array' then p -> 'functions' else '[]'::jsonb end)));
  when 'send_message' then
    return app.staff_send_message(p_user, (select id from bookings where id::text = p ->> 'booking' or booking_number = p ->> 'booking'), p ->> 'subject', p ->> 'body');
  else
    raise exception 'Unknown action %', p_action using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_0032;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  -- the function an assistant chose to work in (one of theirs; app.va_active_fn checks it)
  if p_ ? '_va' then
    perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true);
    p_ := p_ - '_va';
  end if;
  if (p_call = 'va_read' and p_name in ('functions', 'scorecard', 'turo_trips', 'daily_check', 'photo_review', 'late_panel', 'find_renter', 'renter', 'quote_form'))
     or (p_call = 'va_do' and p_name in ('send_message', 'turo_trip_save', 'turo_trip_import', 'reconcile_record', 'daily_check_save', 'request_reshoot',
                                         'late_call', 'late_t13', 'late_t14', 'late_disable', 'late_incident', 'open_renter', 'quote_create'))
     or (p_call = 'field_read' and p_name in ('job', 'report_form', 'referrals', 'profile'))
     or (p_call = 'field_do' and p_name in ('checklist_save', 'complete_job', 'reshoot_photo', 'report', 'profile_save'))
     or (p_call = 'admin_read' and p_name in ('scorecard'))
     or (p_call = 'admin_do' and p_name in ('staff_cover', 'send_message')) then
    perform app.door_begin(p_user, p_aal);
    case p_call
    when 'va_read' then return app.gap_va_read(p_user, p_name, p_);
    when 'va_do' then return app.gap_va_do(p_user, p_name, p_);
    when 'field_read' then return app.gap_field_read(p_user, p_name, p_);
    when 'field_do' then return app.gap_field_do(p_user, p_name, p_);
    when 'admin_read' then return app.gap_admin_read(p_user, p_name, p_);
    else return app.gap_admin_do(p_user, p_name, p_);
    end case;
  end if;
  return app.door_0032(p_user, p_aal, p_call, p_name, p_);
end $$;

-- =====================================================================================
-- H. Service-role wrappers, the email catalogue rows and privileges
-- =====================================================================================
create or replace function public.server_statement_mail_due() returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.statement_mail_due(now()) $$;
create or replace function public.server_statement_mail_release(p_kind text, p_key text) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.statement_mail_release(p_kind, p_key) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['va_active_fn', 'set_cover_functions', 'booking_thread', 'renter_send_message', 'staff_send_message',
              'notification_payload', 'ntf_payload_0032', 'statement_mail_due', 'statement_mail_release', 'outbox_file_refs', 'outbox_file_refs_0032',
              'save_turo_trip', 'daily_check_form', 'save_daily_check', 'photo_review', 'request_reshoot', 'late_panel', 'late_action', 'renter_view',
              'staff_quote_request', 'staff_scorecard', 'field_checklist', 'field_job_checklist', 'field_complete_job', 'field_reshoot_photo', 'field_report',
              'field_referrals', 'field_profile', 'gap_va_read', 'gap_va_do', 'gap_field_read', 'gap_field_do', 'gap_admin_read', 'gap_admin_do',
              'door', 'door_0032', 'my_roles']))
        or (n.nspname = 'public' and p.proname = any (array['renter_send_message', 'server_statement_mail_due', 'server_statement_mail_release']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- the renter's read runs as the signed-in user (row-level security and app.is_my_booking decide)
revoke all on function app.my_booking_messages(text), public.my_booking_messages(text) from public, anon;
grant execute on function app.my_booking_messages(text), public.my_booking_messages(text) to authenticated, service_role;
-- the helpers row-level security calls keep their 0019 grants (they were replaced in place)
grant execute on function app.va_has(text[]) to anon, authenticated;
grant execute on function app.va_active_fn(uuid) to authenticated, anon;

-- The two message emails, and owner_statement_ready with its PDF link (emails/src/emails/*.mjs; generated rows of
-- supabase/seed/0018_catalogue.sql; the deploy loads the template contents).
insert into notification_link_paths (key, path) values ('booking_messages', '/account/bookings/{{booking_number}}#messages')
on conflict (key) do update set path = excluded.path;
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('renter_staff_message', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'A message about your booking {{booking_number}}', '{{staff_name}} at CarmaCars wrote about your {{vehicle_name}} booking.', 'Immediate', 'A customer service or sales assistant (or an Admin) replies to the renter in the messages of a booking. The message is kept on the booking and shown in the renter''s account; this email carries it with a link to reply there. One email per message.', null, '/account/bookings/{{booking_number}}#messages', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"message_body","type":"string"},{"name":"message_subject","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"staff_name","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_staff_message.html', 'templates/renter_staff_message.txt'),
  ('owner_statement_ready', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Your {{statement_month}} statement: {{payout_amount}}', 'Owner Revenue {{owner_revenue_total}}. {{payout_summary}}', '10th of each month', 'An owner statement changes to issued: on the 10th of the month, after an admin approves the payout run, for the previous month. One statement and one email per owner, covering all their vehicles. (Message template T26, statement part.)', 'T26', '/owner/statements/{{statement_number}}', '[{"name":"balance_forward","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deductions_total","type":"string"},{"name":"first_name","type":"string"},{"name":"has_balance_forward","type":"boolean"},{"name":"has_payout_hst","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"kickbacks_deducted","type":"string"},{"name":"kickbacks_earned","type":"string"},{"name":"link_expiry","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"owner_revenue_total","type":"string"},{"name":"payout_amount","type":"string"},{"name":"payout_hst","type":"string"},{"name":"payout_label","type":"string"},{"name":"payout_summary","type":"string"},{"name":"rentals_total","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"revenue_share_total","type":"string"},{"name":"statement_month","type":"string"},{"name":"statement_number","type":"string"},{"name":"statement_url","type":"url"},{"name":"statement_vehicles","type":"list","fields":["name","owner_revenue","payable"]},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/owner_statement_ready.html', 'templates/owner_statement_ready.txt'),
  ('staff_renter_replied', 'staff_va_cs', '{}'::text[], 'transactional', true, 'next', 'CarmaCars <bookings@carmacars.ca>', 'contact@carmacars.ca', '{{renter_first_name}} replied about booking {{booking_number}}', '{{message_excerpt}}', 'Next digest. Immediate if the car is out or pickup is within 48 hours', 'A renter writes in the messages of their booking from their account. A "Renter replied" task opens in the customer service queue (one per booking while it is open). Queued for the next customer service digest; sent immediately instead when the car is out or the pickup is less than 48 hours away.', null, '/va/cs/bookings/{{booking_number}}', '[{"name":"booking_number","type":"string"},{"name":"booking_status","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"message_excerpt","type":"string"},{"name":"pickup_date","type":"string"},{"name":"renter_first_name","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/staff_renter_replied.html', 'templates/staff_renter_replied.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
update notification_catalogue set emitted_by = 'app.staff_send_message (0033)' where code = 'renter_staff_message';
update notification_catalogue set emitted_by = 'app.renter_send_message (0033)' where code = 'staff_renter_replied';
update notification_catalogue set emitted_by = 'app.issue_owner_statement (0021); app.statement_mail_release on the payout date (0033)' where code = 'owner_statement_ready';
update notification_catalogue set emitted_by = 'app.send_link_email (0029): owner invitations and form resume links; the sign-in service sends its own magic links'
 where code = 'account_sign_in_link';
update notification_catalogue set emitted_by = 'investment_returns_notify (0023), when app.statement_mail_release sets statement_sent_at on the Payment Date (0033)' where code = 'investor_statement_ready';
select app.notification_catalogue_refresh();

-- =====================================================================================
-- I. The live verification's test accounts (web/scripts/verify-live.mjs, the verify workflow)
-- =====================================================================================
-- One account per portal, made or repaired on every run: a renter, an owner, an investor, a customer service
-- assistant and a field staff member, never an Admin. Only addresses verify-<name>@carmacars.ca qualify; each
-- is on the email suppression list, so no email is ever sent to them, and has no money or records.
create or replace function app.verify_accounts(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb;
  v_user uuid;
  v_email text;
  v_role text;
  v_out jsonb := '[]'::jsonb;
begin
  for a in select * from jsonb_array_elements(case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) loop
    v_user := (a ->> 'user_id')::uuid;
    v_email := lower(btrim(a ->> 'email'));
    v_role := a ->> 'role';
    if v_email !~ '^verify-[a-z0-9-]+@carmacars\.ca$' then raise exception 'Not a verification address: %', v_email using errcode = '22023'; end if;
    if v_role not in ('renter', 'owner', 'investor', 'va_cs', 'field') then raise exception 'Not a verification role: %', v_role using errcode = '22023'; end if;
    if exists (select 1 from users u where u.email = v_email and u.id <> v_user) then raise exception 'The address % belongs to another account', v_email using errcode = '23505'; end if;
    -- never an Admin, whatever happened before
    delete from user_roles where user_id = v_user and role = 'admin';
    perform app.register_account(v_user, v_email, coalesce(a ->> 'name', 'Verify ' || initcap(replace(v_role, '_', ' '))), null);
    update users set status = 'active' where id = v_user and status <> 'active';
    if v_role <> 'renter' then delete from user_roles where user_id = v_user and role = 'renter'; end if;
    if v_role = 'owner' then
      insert into user_roles (user_id, role) values (v_user, 'owner') on conflict do nothing;
      if not exists (select 1 from owners where user_id = v_user) then
        insert into owners (user_id, owner_type, legal_name, status, email) values (v_user, 'individual', 'Verify Owner', 'active', v_email);
      end if;
    elsif v_role = 'investor' then
      if not exists (select 1 from investors where user_id = v_user) then
        insert into investors (user_id, legal_name, investor_type, status, email) values (v_user, 'Verify Investor', 'individual', 'active', v_email);
      end if;
      update investors set status = 'active' where user_id = v_user and status <> 'active';
    elsif v_role = 'va_cs' then
      insert into user_roles (user_id, role) values (v_user, 'va') on conflict do nothing;
      insert into staff_profiles (user_id, staff_type, va_function, is_active) values (v_user, 'va', 'cs', true)
      on conflict (user_id) do update set staff_type = 'va', va_function = 'cs', field_function = null, is_active = true, cover_functions = '{}', ended_on = null;
    elsif v_role = 'field' then
      insert into user_roles (user_id, role) values (v_user, 'field') on conflict do nothing;
      insert into staff_profiles (user_id, staff_type, field_function, is_active) values (v_user, 'field', 'driver', true)
      on conflict (user_id) do update set staff_type = 'field', field_function = coalesce(staff_profiles.field_function, 'driver'), va_function = null, is_active = true, ended_on = null;
    end if;
    insert into email_suppressions (email, scope, reason, detail)
    select v_email, 'all', 'manual', 'Deploy verification account: no email is sent'
     where not exists (select 1 from email_suppressions s where s.email = v_email and s.scope = 'all' and s.lifted_at is null);
    v_out := v_out || jsonb_build_object('email', v_email, 'role', v_role, 'roles', app.my_roles(v_user));
  end loop;
  return v_out;
end $$;
create or replace function public.server_verify_accounts(p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.verify_accounts(p) $$;
revoke all on function app.verify_accounts(jsonb), public.server_verify_accounts(jsonb) from public, anon, authenticated;
grant execute on function app.verify_accounts(jsonb), public.server_verify_accounts(jsonb) to service_role;

do $$ begin perform app.attach_audit(); end $$;
