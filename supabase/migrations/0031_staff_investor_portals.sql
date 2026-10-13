-- 0031: the staff and investor portals (docs/blueprint/05-va.md, 06-field.md, 07-investor.md).
--
-- The web app reaches the database through functions in `public`, as the service role, with the
-- signed-in user's id. 0030 built that door for the Admin. This migration opens it to the other
-- people who sign in, each through the functions that already own the rules:
--
--   app.door(user, aal, call, name, p)  one entry for every staff and investor call: makes the user
--                                       the acting user for the transaction with the session's
--                                       assurance level (so app.is_admin(), app.va_has() and every
--                                       guard see the second factor), refuses a staff session
--                                       without it while require_staff_two_step is on, then runs
--                                       the call
--   app.va_list / va_read / va_do       an assistant's lists, screens and actions: an allow-list per
--                                       function (finance, fleet, cs, sales); an allowed admin
--                                       screen or action runs through 0030's door with the
--                                       assistant as the actor, so the earlier rules (send_offer,
--                                       the refund and deposit guards, create_field_job, ...) decide
--   app.field_read / field_do           the field staff member's own jobs: the job list, one job with
--                                       its checklist data, and the checklist's steps (acknowledge,
--                                       start, save, complete the handover or the return, block,
--                                       vehicle moves, late damage)
--   app.investor_read / investor_do     a signed-in investor's own records and the requests that
--                                       become an Admin task
--   app.my_roles(user)                  where a user goes after signing in
--
-- Plus: program_settings.staff_blocked_terms (words a staff message may not contain, 05-va.md
-- section 6), two task rules (approve_refund, investor_request), and a trigger that closes the
-- approve_refund task once an Admin decides the refund.

-- ================================================================ 0. settings and rules
alter table program_settings add column if not exists staff_blocked_terms text[] not null default '{}';
comment on column program_settings.staff_blocked_terms is 'Words or names a staff message to a customer may not contain (the coverage provider is never named). Case-insensitive.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('approve_refund',   'admin', 'Refund to approve',  'high',   'opening_minutes', 120, 7,    null, 'An assistant asked for a refund above their Single Limit or outside the cancellation table'),
  ('investor_request', 'admin', 'Investor request',   'normal', 'business_days',   2,   null, null, 'A request an investor made in the investor area: election change, bank account change, transfer')
on conflict (task_type) do nothing;

-- The approval task closes when the refund is decided.
create or replace function app.refund_approval_resolve() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if old.status = 'pending_approval' and new.status <> 'pending_approval' then
    update tasks set status = 'done', completed_at = now(), completed_by = coalesce(new.approved_by, completed_by),
                     completion_note = 'Refund ' || replace(new.status, '_', ' ')
     where related_table = 'refunds' and related_id = new.id and status in ('open', 'in_progress', 'waiting');
  end if;
  return new;
end $$;
drop trigger if exists refunds_approval_resolve on refunds;
create trigger refunds_approval_resolve after update of status on refunds
  for each row execute function app.refund_approval_resolve();

-- Why a staff message to a customer cannot be sent; null when it can.
create or replace function app.staff_message_problem(p_body text) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when nullif(btrim(coalesce(p_body, '')), '') is null then 'Write the message first'
    when length(p_body) > 4000 then 'Keep the message under 4,000 characters'
    else (select 'The message names something staff messages may not name: ' || t
            from unnest((app.settings()).staff_blocked_terms) t
           where nullif(btrim(t), '') is not null and position(lower(btrim(t)) in lower(p_body)) > 0 limit 1) end
$$;

-- ================================================================ 1. who is signing in
-- The places a user may go, for the routing after sign-in.
create or replace function app.my_roles(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object(
    'admin', app.user_is_admin(p_user),
    'va', (select sp.va_function::text from staff_profiles sp join user_roles r on r.user_id = sp.user_id and r.role = 'va'
             join users u on u.id = sp.user_id
            where sp.user_id = p_user and sp.staff_type = 'va' and sp.is_active and u.status = 'active' limit 1),
    'field', app.user_is_field(p_user),
    'owner', exists (select 1 from owners o where o.user_id = p_user),
    'renter', exists (select 1 from renters r where r.user_id = p_user),
    'investor', exists (select 1 from investors i where i.user_id = p_user and i.status in ('active', 'exited')),
    'staff', app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user),
    'two_step_required', coalesce((app.settings()).require_staff_two_step, false),
    'name', (select u.full_name from users u where u.id = p_user))
$$;

-- ================================================================ 2. the door
-- The acting user for the transaction, with the assurance level of their session (the server read
-- it from the session and passes it; only the service role reaches this function).
create or replace function app.door_begin(p_user uuid, p_aal text) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_staff boolean;
begin
  if p_user is null then raise exception 'Sign in first' using errcode = '42501'; end if;
  if p_aal is not null and p_aal not in ('aal1', 'aal2') then raise exception 'Unknown assurance level %', p_aal using errcode = '22023'; end if;
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('request.jwt.claim.aal', coalesce(p_aal, ''), true);
  perform set_config('request.jwt.claims',
    (coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
       || jsonb_build_object('sub', p_user, 'aal', p_aal))::text, true);
  v_staff := app.user_is_admin(p_user) or app.user_is_staff(p_user) or app.user_is_field(p_user);
  if v_staff and coalesce((app.settings()).require_staff_two_step, false) and p_aal is distinct from 'aal2' then
    raise exception 'Two-step sign-in is required' using errcode = '42501';
  end if;
end $$;

-- 0030's acting Admin, now also reached by an assistant whose action the door allowed: the door
-- marks the transaction (app.door_va) after its own checks, and only for that user.
create or replace function app.admin_begin(p_admin uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if not coalesce(nullif(current_setting('app.door_va', true), '') = p_admin::text and app.user_is_staff(p_admin), false) then
    perform app.assert_admin(p_admin);
  end if;
  perform set_config('request.jwt.claim.sub', p_admin::text, true);
  perform set_config('request.jwt.claims',
    (coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb || jsonb_build_object('sub', p_admin))::text, true);
end $$;

-- The assistant's function, or an error.
create or replace function app.va_fn(p_user uuid) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v text := app.my_roles(p_user) ->> 'va';
begin
  if v is null then raise exception 'Only an assistant may do this' using errcode = '42501'; end if;
  return v;
end $$;

-- Runs an allowed admin screen or action as the assistant.
create or replace function app.va_delegate(p_user uuid) returns void
language plpgsql security definer set search_path = public, app as $$
begin
  perform set_config('app.door_va', p_user::text, true);
end $$;

-- ================================================================ 3. assistants: lists
create or replace function app.va_list(p_user uuid, p_rel text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_fn text := app.va_fn(p_user);
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_allowed text[] := case v_fn
    when 'finance' then array['tasks', 'bookings', 'payments', 'refunds', 'deposits', 'booking_statements', 'booking_line_items', 'toll_tickets', 'toll_work_queue',
                              'toll_work_queue_summary', 'toll_import_profiles', 'toll_import_batches', 'owner_invoices', 'owner_statements',
                              'payout_reconciliations', 'payout_reconciliation_items', 'quick_replies', 'staff_directory', 'field_jobs']
    when 'fleet' then array['tasks', 'bookings', 'field_jobs', 'vehicles', 'vehicle_calendar_blocks', 'listing_intakes', 'vehicle_listings', 'condition_reports',
                            'incidents', 'rate_cards', 'quick_replies', 'staff_directory', 'turo_trips']
    when 'cs' then array['tasks', 'bookings', 'booking_change_requests', 'booking_extensions', 'booking_info_requests', 'messages', 'leads', 'reviews',
                         'listing_intakes', 'vehicle_listings', 'vehicles', 'quick_replies', 'staff_directory', 'field_jobs', 'booking_offers']
    when 'sales' then array['tasks', 'bookings', 'booking_offers', 'leads', 'quick_replies', 'vehicles']
  end;
begin
  if not (p_rel = any (v_allowed)) then
    raise exception 'The % assistant does not list %', v_fn, p_rel using errcode = '42501';
  end if;
  -- the rows each function may see in a shared table
  if p_rel = 'tasks' then
    p_ := jsonb_set(p_, '{eq}', coalesce(p_ -> 'eq', '{}'::jsonb) || jsonb_build_object('queue', v_fn));
  elsif p_rel = 'bookings' and v_fn = 'sales' then
    p_ := jsonb_set(p_, '{eq}', coalesce(p_ -> 'eq', '{}'::jsonb) || jsonb_build_object('status', jsonb_build_array('requested', 'offered')));
  elsif p_rel = 'leads' and v_fn = 'cs' then
    p_ := jsonb_set(p_, '{eq}', coalesce(p_ -> 'eq', '{}'::jsonb) || jsonb_build_object('kind', jsonb_build_array('contact', 'insurer', 'other', 'owner_program')));
  elsif p_rel = 'quick_replies' then
    p_ := jsonb_set(p_, '{eq}', coalesce(p_ -> 'eq', '{}'::jsonb) || jsonb_build_object('is_active', true));
  end if;
  perform app.va_delegate(p_user);
  return app.admin_list(p_user, p_rel, p_);
end $$;

-- ================================================================ 4. assistants: screens
-- A booking as an assistant sees it: Fleet without money, Sales only while it is a request or an
-- offer, nobody with a processor's identifiers.
create or replace function app.va_booking(p_user uuid, p_fn text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb;
begin
  perform app.va_delegate(p_user);
  v := app.admin_read(p_user, 'booking', p);
  if v is null then return null; end if;
  if p_fn = 'sales' and not (v ->> 'status' in ('requested', 'offered')) then
    raise exception 'Sales works on requests and offers only' using errcode = '42501';
  end if;
  v := v || jsonb_build_object('payments', coalesce((select jsonb_agg(x - 'processor_payment_id' - 'processor_customer_id' - 'processor_payload' - 'processor_charge_id' - 'payment_method_id')
                                                      from jsonb_array_elements(v -> 'payments') x), '[]'::jsonb));
  if p_fn in ('fleet', 'sales') then
    v := v - 'payments' - 'refunds' - 'statements' - 'emails'
           || jsonb_build_object('deposit', case when v -> 'deposit' is null or v -> 'deposit' = 'null'::jsonb then null
                                                  else jsonb_build_object('status', v -> 'deposit' ->> 'status') end);
  end if;
  if p_fn = 'fleet' then
    v := v || jsonb_build_object('renter', jsonb_build_object('legal_name', split_part(btrim(coalesce(v -> 'renter' ->> 'legal_name', '')), ' ', 1)),
                                 'drivers', coalesce((select jsonb_agg(jsonb_build_object('full_name', d ->> 'full_name', 'role', d ->> 'role')) from jsonb_array_elements(v -> 'drivers') d), '[]'::jsonb));
  end if;
  return v || jsonb_build_object('va_function', p_fn);
end $$;

create or replace function app.va_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_fn text := app.va_fn(p_user);
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_today date := app.today();
  v_b uuid;
  v jsonb;
begin
  case p_what
  when 'queue' then
    return coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(t)) || jsonb_build_object(
               'bucket', case when t.status = 'waiting' then 'waiting' when t.assigned_to = p_user then 'mine' when t.assigned_to is null then 'unassigned' else 'others' end,
               'overdue', t.due_at is not null and t.due_at < now(), 'renter_first_name', (select split_part(btrim(r.legal_name), ' ', 1) from renters r where r.id = t.renter_id),
               'plate', (select x.plate from vehicles x where x.id = t.vehicle_id))
             order by case t.priority when 'urgent' then 1 when 'high' then 2 when 'normal' then 3 else 4 end, t.due_at nulls last, t.created_at)
      from tasks t where t.status in ('open', 'in_progress', 'waiting') and (t.queue = v_fn or t.assigned_to = p_user)), '[]'::jsonb);
  when 'task' then
    select app.admin_enrich(to_jsonb(t)) || jsonb_build_object('notes', coalesce((select jsonb_agg(jsonb_build_object('body', m.body, 'at', m.occurred_at,
               'by', (select u.full_name from users u where u.id = m.sent_by)) order by m.occurred_at)
             from messages m where m.related_table = 'tasks' and m.related_id = t.id), '[]'::jsonb),
             'rule', (select to_jsonb(r) from task_rules r where r.task_type = t.task_type))
      into v from tasks t where t.id = (p_ ->> 'id')::uuid and (t.queue = v_fn or t.assigned_to = p_user);
    return v;
  when 'digest' then
    return jsonb_build_object(
      'function', v_fn, 'today', v_today,
      'open', (select count(*) from tasks t where t.queue = v_fn and t.status in ('open', 'in_progress', 'waiting')),
      'overdue', (select count(*) from tasks t where t.queue = v_fn and t.status in ('open', 'in_progress') and t.due_at < now()),
      'due_today', (select count(*) from tasks t where t.queue = v_fn and t.status in ('open', 'in_progress', 'waiting') and app.local_date(t.due_at) = v_today),
      'escalated', (select count(*) from tasks t where t.queue = v_fn and t.status in ('open', 'in_progress', 'waiting') and t.escalated),
      'done_today', (select count(*) from tasks t where t.queue = v_fn and t.status = 'done' and app.local_date(t.completed_at) = v_today),
      'mine', (select count(*) from tasks t where t.assigned_to = p_user and t.status in ('open', 'in_progress', 'waiting')),
      'by_type', coalesce((select jsonb_object_agg(x.task_type, x.n) from (select t.task_type, count(*) n from tasks t
                             where t.queue = v_fn and t.status in ('open', 'in_progress', 'waiting') group by t.task_type) x), '{}'::jsonb),
      'pickups_today', (select count(*) from bookings b where b.status in ('confirmed', 'on_rent') and app.local_date(b.pickup_at) = v_today),
      'returns_today', (select count(*) from bookings b where b.status in ('on_rent', 'returned') and app.local_date(b.return_at) = v_today),
      'requests_waiting', case when v_fn in ('cs', 'sales') then (select count(*) from bookings b where b.status = 'requested') end,
      'payments_failed', case when v_fn = 'finance' then (select count(*) from payments x where x.status = 'failed' and x.created_at > now() - interval '30 days') end,
      'next', coalesce((select jsonb_agg(jsonb_build_object('title', t.title, 'due_at', t.due_at) order by t.due_at)
                          from (select * from tasks t where t.queue = v_fn and t.status in ('open', 'waiting') and t.due_at > now() order by t.due_at limit 5) t), '[]'::jsonb));
  when 'booking' then
    return app.va_booking(p_user, v_fn, p_);
  when 'requests' then
    if v_fn not in ('cs', 'sales') then raise exception 'Requests are worked by customer service and sales' using errcode = '42501'; end if;
    perform app.va_delegate(p_user);
    return app.admin_read(p_user, 'requests', p_);
  when 'booking_preview', 'quote_vehicles' then
    if v_fn not in ('cs', 'sales') then raise exception 'Not permitted' using errcode = '42501'; end if;
    perform app.va_guard_booking_edit(v_fn, p_);
    perform app.va_delegate(p_user);
    return app.admin_read(p_user, p_what, p_);
  when 'calendar' then
    perform app.va_delegate(p_user);
    v := app.admin_read(p_user, 'calendar', p_);
    if v_fn in ('cs', 'sales') then
      -- first names only, and no moves or Turo trips for customer service and sales
      v := jsonb_set(v, '{vehicles}', coalesce((select jsonb_agg(x - 'owner' || jsonb_build_object('entries', coalesce((select jsonb_agg(e || jsonb_build_object('renter', split_part(btrim(coalesce(e ->> 'renter', '')), ' ', 1)))
                 from jsonb_array_elements(x -> 'entries') e where coalesce(e ->> 'type', '') not in ('vehicle_move', 'turo_trip')), '[]'::jsonb)))
               from jsonb_array_elements(v -> 'vehicles') x), '[]'::jsonb));
    end if;
    return v;
  when 'calendar_preview' then
    if v_fn not in ('fleet', 'cs') then raise exception 'Not permitted' using errcode = '42501'; end if;
    perform app.va_delegate(p_user);
    return app.admin_read(p_user, p_what, p_);
  when 'listings', 'listing' then
    if v_fn not in ('cs', 'fleet') then raise exception 'Listings are reviewed by customer service and fleet' using errcode = '42501'; end if;
    perform app.va_delegate(p_user);
    return app.admin_read(p_user, p_what, p_);
  when 'tolls', 'toll', 'toll_profile', 'reconciliation' then
    if v_fn <> 'finance' then raise exception 'Tolls and reconciliation are Finance work' using errcode = '42501'; end if;
    perform app.va_delegate(p_user);
    return app.admin_read(p_user, p_what, p_);
  when 'vehicle' then
    if v_fn not in ('fleet', 'cs') then raise exception 'Not permitted' using errcode = '42501'; end if;
    perform app.va_delegate(p_user);
    v := app.admin_read(p_user, 'vehicle', p_);
    -- owner terms and money stay with the Admin
    return v - 'schedule' - 'fee_history' - 'owner_terms' - 'revenue_share';
  when 'finance_board' then
    if v_fn <> 'finance' then raise exception 'Not permitted' using errcode = '42501'; end if;
    return jsonb_build_object(
      'payments_failed', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'booking_number', b.booking_number, 'purpose', x.purpose, 'amount_cents', x.amount_cents,
                                     'created_at', x.created_at, 'decline_code', x.last_decline_code, 'card_last4', x.card_last4) order by x.created_at desc)
                                  from payments x left join bookings b on b.id = x.booking_id where x.status = 'failed' and x.created_at > now() - interval '30 days'), '[]'::jsonb),
      'deposits_due', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'booking_number', b.booking_number, 'amount_cents', d.amount_cents, 'status', d.status,
                                  'release_due_on', d.release_due_on, 'method', d.method) order by d.release_due_on nulls last)
                               from deposits d join bookings b on b.id = d.booking_id where d.status in ('held', 'captured') and d.release_due_on is not null and d.release_due_on <= v_today + 7), '[]'::jsonb),
      'deposits_to_take', coalesce((select jsonb_agg(jsonb_build_object('booking_number', b.booking_number, 'pickup_at', b.pickup_at, 'amount_cents', b.deposit_cents) order by b.pickup_at)
                                   from bookings b where b.status = 'confirmed' and b.deposit_cents > 0 and b.deposit_waived_at is null and b.pickup_at < now() + interval '2 days'
                                    and not exists (select 1 from deposits d where d.booking_id = b.id and d.status in ('held', 'captured'))), '[]'::jsonb),
      'refunds', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'booking_number', b.booking_number, 'reason', r.reason, 'amount_cents', r.amount_cents, 'status', r.status,
                              'due_by', r.due_by, 'created_at', r.created_at) order by r.created_at desc)
                           from refunds r join bookings b on b.id = r.booking_id where r.status in ('pending_approval', 'approved', 'processing', 'failed')), '[]'::jsonb),
      'cancellations', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'refund_cents', c.refund_cents, 'cancelled_at', c.created_at) order by c.created_at desc)
                                 from booking_cancellations c join bookings b on b.id = c.booking_id
                                where coalesce(c.refund_cents, 0) > 0 and not exists (select 1 from refunds r where r.booking_id = b.id and r.status <> 'rejected')), '[]'::jsonb),
      'owner_invoices', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'owner_name', o.legal_name, 'status', i.status,
                                     'balance_cents', i.balance_cents, 'billing_date', i.billing_date) order by i.billing_date)
                                  from owner_invoices i join owners o on o.id = i.owner_id where i.status in ('failed', 'retry_processing', 'in_arrears')), '[]'::jsonb),
      'statements', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'owner_name', o.legal_name, 'month', s.statement_month, 'status', s.status) order by s.statement_month desc)
                              from owner_statements s join owners o on o.id = s.owner_id where s.status = 'draft'), '[]'::jsonb));
  when 'fleet_board' then
    if v_fn <> 'fleet' then raise exception 'Not permitted' using errcode = '42501'; end if;
    return jsonb_build_object(
      'staff', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', u.full_name) order by u.full_name)
                           from users u where app.user_is_field(u.id)), '[]'::jsonb),
      'jobs', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(j)) order by j.scheduled_at) from field_jobs j
                         where j.status <> 'cancelled' and (j.status <> 'done' or j.completed_at > now() - interval '1 day')
                           and j.scheduled_at < now() + interval '3 days'), '[]'::jsonb),
      'unscheduled', coalesce((select jsonb_agg(jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'vehicle_id', b.vehicle_id,
                                  'vehicle_name', app.vehicle_name(b.vehicle_id), 'leg', x.leg, 'at', x.at, 'place', x.place) order by x.at)
                               from bookings b cross join lateral (values ('handover', b.pickup_at, b.pickup_place, b.status = 'confirmed'),
                                                                         ('return_check_in', b.return_at, b.return_place, b.status in ('confirmed', 'on_rent'))) x(leg, at, place, applies)
                              where x.applies and x.at between now() - interval '1 day' and now() + interval '7 days'
                                and not exists (select 1 from field_jobs j where j.booking_id = b.id and j.status <> 'cancelled'
                                                  and (case when x.leg = 'handover' then j.kind in ('handover', 'delivery') else j.kind in ('return_check_in', 'pickup_from_renter') end))), '[]'::jsonb),
      'expiry', coalesce((select jsonb_agg(app.admin_enrich(to_jsonb(t)) order by t.due_at) from tasks t
                           where t.status in ('open', 'in_progress', 'waiting') and t.task_type in ('turo_expiry', 'safety_certificate_window', 'plate_renewal', 'arrears_removal')), '[]'::jsonb),
      'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at, 'vehicle_id', d.vehicle_id,
                                'vehicle_name', app.vehicle_name(d.vehicle_id)) order by d.created_at desc)
                             from (select * from documents d where d.vehicle_id is not null and d.purged_at is null and d.booking_id is null
                                     and d.kind::text not in ('id_front', 'id_back', 'selfie') order by d.created_at desc limit 50) d), '[]'::jsonb));
  when 'verification' then
    -- identity documents of one booking, only while the assistant has the review task for it
    if v_fn <> 'cs' then raise exception 'Identity documents are reviewed by customer service' using errcode = '42501'; end if;
    select b.id into v_b from bookings b where b.id::text = p_ ->> 'booking' or b.booking_number = p_ ->> 'booking';
    if not exists (select 1 from tasks t where t.booking_id = v_b and t.status in ('open', 'in_progress', 'waiting')
                     and t.task_type in ('verify_renter', 'chase_verification') and t.queue = 'cs') then
      raise exception 'Identity documents open only for an open review task on this booking' using errcode = '42501';
    end if;
    insert into data_access_log (user_id, action, renter_id, reason, results)
    select p_user, 'open', b.renter_id, 'identity review, booking ' || b.booking_number, (select count(*) from verification_uploads u where u.booking_id = b.id and u.status = 'submitted')
      from bookings b where b.id = v_b;
    return (select jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'return_at', b.return_at, 'coverage_option', b.coverage_option,
              'readiness', app.booking_readiness(b.id),
              'drivers', coalesce((select jsonb_agg(jsonb_build_object('driver_id', d.driver_id, 'full_name', d.full_name, 'role', d.role, 'date_of_birth', d.date_of_birth,
                                     'licence_number', d.licence_number, 'licence_class', d.licence_class, 'licence_expiry', d.licence_expiry, 'verified_on', d.identity_verified_on)
                                     order by d.role desc, d.full_name) from booking_drivers d where d.booking_id = b.id), '[]'::jsonb),
              'uploads', coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'kind', u.kind, 'driver_id', u.driver_id, 'status', u.status, 'uploaded_at', u.uploaded_at,
                                     'bucket', doc.storage_bucket, 'path', doc.storage_path, 'mime_type', doc.mime_type) order by u.uploaded_at)
                                     from verification_uploads u join documents doc on doc.id = u.document_id
                                    where u.booking_id = b.id and u.status in ('submitted', 'approved', 'rejected') and doc.purged_at is null), '[]'::jsonb))
              from bookings b where b.id = v_b);
  when 'messages' then
    if v_fn <> 'cs' then raise exception 'Renter messages are customer service work' using errcode = '42501'; end if;
    return coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'direction', m.direction, 'channel', m.channel, 'subject', m.subject, 'body', m.body,
                         'occurred_at', m.occurred_at, 'booking_id', m.booking_id, 'booking_number', b.booking_number,
                         'renter_first_name', split_part(btrim(r.legal_name), ' ', 1), 'sent_by', (select u.full_name from users u where u.id = m.sent_by))
                       order by m.occurred_at desc)
                     from (select * from messages m where m.booking_id is not null and m.channel in ('email', 'portal', 'sms', 'whatsapp')
                              and (m.related_table is distinct from 'tasks') and coalesce(m.template_code, '') <> 'T7'
                              and (p_ ->> 'booking' is null or m.booking_id::text = p_ ->> 'booking')
                            order by m.occurred_at desc limit 100) m
                     join bookings b on b.id = m.booking_id left join renters r on r.id = m.renter_id), '[]'::jsonb);
  when 'owner_leads' then
    if v_fn not in ('sales', 'cs') then raise exception 'Not permitted' using errcode = '42501'; end if;
    return jsonb_build_object(
      'leads', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'name', l.name, 'email', l.email, 'phone', l.phone, 'message', l.message, 'status', l.status,
                            'created_at', l.created_at, 'assigned_to', l.assigned_to, 'assignee_name', (select u.full_name from users u where u.id = l.assigned_to),
                            'vehicle', l.payload ->> 'vehicle') order by l.created_at desc)
                         from leads l where l.kind = 'owner_program' and l.status in ('new', 'contacted', 'qualified')), '[]'::jsonb),
      'applications', coalesce((select jsonb_agg(jsonb_build_object('application_number', a.application_number, 'owner_name', o.legal_name, 'vehicle_count', a.vehicle_count,
                                   'created_at', a.created_at, 'source', a.source,
                                   'statuses', (select jsonb_agg(distinct vo.status) from vehicles v join vehicle_onboardings vo on vo.vehicle_id = v.id where v.owner_id = o.id)) order by a.created_at desc)
                               from owner_applications a join owners o on o.id = a.owner_id where a.created_at > now() - interval '90 days'), '[]'::jsonb));
  else
    raise exception 'Unknown screen %', p_what using errcode = '22023';
  end case;
end $$;

-- An assistant has no per-booking price override (05-va.md sections 4.1 and 5): rates, a typed
-- rental charge, a staff discount, the Deposit, fee terms and the calendar switch stay with an
-- Admin. Customer service may price coverage sold on a request (0025); Sales may not.
create or replace function app.va_guard_booking_edit(p_fn text, p jsonb) returns void
language plpgsql stable security definer set search_path = public, app as $$
declare
  k text;
begin
  if jsonb_typeof(coalesce(p -> 'changes', '{}'::jsonb)) <> 'object' then raise exception 'The changes are a list of columns' using errcode = '22023'; end if;
  for k in select jsonb_object_keys(coalesce(p -> 'changes', '{}'::jsonb)) loop
    if k not in ('vehicle_id', 'pickup_at', 'return_at', 'booking_type', 'km_allowance_per_day', 'bill_to', 'insurer_id', 'insurer_claim_number',
                 'insurer_adjuster_name', 'insurer_adjuster_email', 'insurer_adjuster_phone', 'insurer_authorized_until', 'insurer_authorized_days', 'dates_provisional') then
      raise exception 'Only an Admin changes %: ask an Admin from the task', replace(k, '_', ' ') using errcode = '42501';
    end if;
  end loop;
  if p ? 'fee_terms' or p ? 'blocks_calendar' then
    raise exception 'Only an Admin changes fees or the calendar switch on a booking' using errcode = '42501';
  end if;
  if p ? 'coverage_cents' and p_fn <> 'cs' then
    raise exception 'Only customer service or an Admin prices coverage' using errcode = '42501';
  end if;
  if p ->> 'expires_at' is not null and (p ->> 'expires_at')::timestamptz > now() + interval '48 hours 5 minutes' then
    raise exception 'An assistant''s offer is open for 48 hours at most' using errcode = '23514';
  end if;
end $$;

-- ================================================================ 5. assistants: actions
create or replace function app.va_do(p_user uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_fn text := app.va_fn(p_user);
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_allowed text[] := case v_fn
    when 'cs' then array['booking_save', 'send_offer', 'withdraw_offer', 'resend_offer', 'approve_offer_by_phone', 'ask_info', 'decline_request', 'reopen_expired',
                         'approve_change', 'decline_change', 'approve_extension', 'decline_extension', 'cancel_booking',
                         'listing_review', 'listing_classes', 'review_publish', 'review_reply', 'review_request_decide']
    when 'sales' then array['booking_save', 'send_offer', 'withdraw_offer', 'resend_offer', 'ask_info', 'decline_request']
    when 'finance' then array['toll_log', 'toll_import', 'toll_profile_save', 'toll_confirm', 'toll_bulk_confirm', 'toll_charge', 'toll_dispute', 'toll_rematch',
                              'reconcile_match', 'settle_deposit', 'issue_booking_statement', 'refund_approve']
    when 'fleet' then array['field_job_create', 'block_create', 'block_update', 'block_end', 'listing_start', 'listing_review', 'listing_classes', 'vehicle_classes']
  end;
  b bookings;
  t tasks;
  v_id uuid;
  v_limit bigint;
  v_problem text;
  v_out jsonb;
begin
  if p_ ? 'booking' then
    select * into b from bookings where id::text = p_ ->> 'booking' or booking_number = p_ ->> 'booking';
    if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    if v_fn = 'sales' and b.status not in ('requested', 'offered') then
      raise exception 'Sales works on requests and offers only' using errcode = '42501';
    end if;
  end if;
  if p_ ? 'id' and p_action like 'task_%' then
    select * into t from tasks where id = (p_ ->> 'id')::uuid;
    if t.id is null or not (t.queue = v_fn or t.assigned_to = p_user) then
      raise exception 'That task is not in your queue' using errcode = '42501';
    end if;
  end if;

  case p_action
  -- ---------------------------------------------------------------- the task sheet (05-va.md section 1.2)
  when 'task_take' then perform app.assign_task(t.id, p_user, p_user); return jsonb_build_object('id', t.id);
  when 'task_done' then perform app.complete_task(t.id, p_user, nullif(btrim(p_ ->> 'note'), ''), false); return jsonb_build_object('id', t.id);
  when 'task_wait' then perform app.snooze_task(t.id, p_user, (p_ ->> 'until')::timestamptz, p_ ->> 'reason'); return jsonb_build_object('id', t.id);
  when 'task_escalate' then return jsonb_build_object('id', app.escalate_task(t.id, p_user, p_ ->> 'reason'));
  when 'task_handover' then
    perform app.assign_task(t.id, (p_ ->> 'to')::uuid, p_user); return jsonb_build_object('id', t.id);
  when 'task_note' then
    if nullif(btrim(coalesce(p_ ->> 'body', '')), '') is null then raise exception 'Write the note first' using errcode = '22023'; end if;
    insert into messages (direction, channel, body, related_table, related_id, sent_by, status, booking_id)
    values ('outbound', 'portal', left(btrim(p_ ->> 'body'), 4000), 'tasks', t.id, p_user, 'delivered', t.booking_id) returning id into v_id;
    return jsonb_build_object('id', v_id);

  -- ---------------------------------------------------------------- customer service
  when 'verify_upload' then
    if v_fn <> 'cs' then raise exception 'Identity documents are reviewed by customer service' using errcode = '42501'; end if;
    perform 1 from verification_uploads u join tasks k on k.booking_id = u.booking_id
     where u.id = (p_ ->> 'upload')::uuid and k.status in ('open', 'in_progress', 'waiting') and k.task_type in ('verify_renter', 'chase_verification');
    if not found then raise exception 'Identity documents are reviewed from an open review task' using errcode = '42501'; end if;
    perform app.review_verification_upload((p_ ->> 'upload')::uuid, p_user, (p_ ->> 'approve')::boolean, nullif(btrim(p_ ->> 'reason'), ''));
    return jsonb_build_object('ok', true);
  when 'send_message' then
    if v_fn not in ('cs', 'sales') then raise exception 'Renter messages are customer service work' using errcode = '42501'; end if;
    if b.id is null then raise exception 'A message belongs to a booking' using errcode = '22023'; end if;
    v_problem := app.staff_message_problem(p_ ->> 'body');
    if v_problem is not null then raise exception '%', v_problem using errcode = '23514'; end if;
    insert into messages (direction, channel, subject, body, to_address, user_id, renter_id, booking_id, vehicle_id, sent_by, status)
    select 'outbound', 'portal', coalesce(nullif(btrim(p_ ->> 'subject'), ''), 'Your booking ' || b.booking_number), left(btrim(p_ ->> 'body'), 4000),
           r.email, r.user_id, r.id, b.id, b.vehicle_id, p_user, 'delivered'
      from renters r where r.id = b.renter_id
    returning id into v_id;
    insert into notifications (user_id, code, title, body, url, entity, entity_id, dedupe_key)
    select r.user_id, 'renter_staff_message', 'A message about booking ' || b.booking_number, left(btrim(p_ ->> 'body'), 400),
           '/account/bookings/' || b.booking_number, 'booking', b.id, 'renter_staff_message:' || v_id
      from renters r where r.id = b.renter_id and r.user_id is not null
       and exists (select 1 from notification_catalogue c where c.code = 'renter_staff_message');
    return jsonb_build_object('id', v_id);
  when 'lead_update' then
    if v_fn not in ('cs', 'sales') then raise exception 'Not permitted' using errcode = '42501'; end if;
    update leads set status = coalesce(nullif(p_ ->> 'status', ''), status),
                     assigned_to = case when p_ ? 'take' then p_user else assigned_to end,
                     closed_reason = coalesce(nullif(btrim(p_ ->> 'closed_reason'), ''), closed_reason)
     where id = (p_ ->> 'id')::uuid
    returning id into v_id;
    if v_id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
    return jsonb_build_object('id', v_id);

  -- ---------------------------------------------------------------- finance: a refund is requested; above the limit it waits for an Admin
  when 'request_refund' then
    if v_fn <> 'finance' then raise exception 'Refunds are requested by Finance' using errcode = '42501'; end if;
    if b.id is null then raise exception 'A refund belongs to a booking' using errcode = '22023'; end if;
    if coalesce((p_ ->> 'amount_cents')::bigint, 0) <= 0 then raise exception 'Enter the amount to refund' using errcode = '22023'; end if;
    insert into refunds (booking_id, payment_id, reason, amount_cents, status, requested_by, note)
    values (b.id, coalesce((p_ ->> 'payment')::uuid, (select x.id from payments x where x.booking_id = b.id and x.status = 'succeeded' and x.kind in ('charge', 'capture') order by x.created_at desc limit 1)),
            coalesce(p_ ->> 'reason', 'other'), (p_ ->> 'amount_cents')::bigint, 'pending_approval', p_user, nullif(btrim(p_ ->> 'note'), ''))
    returning id into v_id;
    -- inside the procedures and the Single Limit the assistant may release it; anything else is an Admin's
    if app.may_release_payment(p_user, (p_ ->> 'amount_cents')::bigint,
         coalesce(p_ ->> 'reason', 'other') in ('cancellation', 'carmacars_cancelled', 'driver_not_verifiable')
         and exists (select 1 from booking_cancellations c where c.booking_id = b.id and c.refund_cents = (p_ ->> 'amount_cents')::bigint)) then
      return jsonb_build_object('id', v_id, 'needs_admin', false);
    end if;
    select sp.single_limit_cents into v_limit from staff_profiles sp where sp.user_id = p_user;
    perform app.raise_task(p_type => 'approve_refund',
      p_title => format('Booking %s: approve a refund of %s', b.booking_number, app.money_text((p_ ->> 'amount_cents')::bigint)),
      p_detail => format('Requested by %s (%s). Reason: %s. Their Single Limit is %s.', (select full_name from users where id = p_user),
                         'Finance', replace(coalesce(p_ ->> 'reason', 'other'), '_', ' ') || coalesce(', ' || nullif(btrim(p_ ->> 'note'), ''), ''), app.money_text(coalesce(v_limit, 0))),
      p_booking => b.id, p_renter => b.renter_id, p_related_table => 'refunds', p_related_id => v_id,
      p_dedupe => 'approve_refund:' || v_id, p_created_by => p_user, p_escalation_reason => 'Above the assistant''s limit');
    perform app.emit_event('staff_approval_needed', 'task', (select id from tasks where dedupe_key = 'approve_refund:' || v_id),
      jsonb_build_object('booking_number', b.booking_number, 'amount_cents', (p_ ->> 'amount_cents')::bigint, 'what', 'refund', 'requested_by', p_user),
      'staff_approval_needed:refund:' || v_id);
    return jsonb_build_object('id', v_id, 'needs_admin', true);

  -- ---------------------------------------------------------------- fleet: field jobs
  when 'field_job_assign' then
    if v_fn <> 'fleet' then raise exception 'Fleet assigns field jobs' using errcode = '42501'; end if;
    perform app.assign_field_job((p_ ->> 'id')::uuid, (p_ ->> 'to')::uuid, p_user); return jsonb_build_object('id', p_ ->> 'id');
  when 'field_job_reschedule' then
    if v_fn <> 'fleet' then raise exception 'Fleet reschedules field jobs' using errcode = '42501'; end if;
    perform app.reschedule_field_job((p_ ->> 'id')::uuid, p_user, (p_ ->> 'scheduled_at')::timestamptz, nullif(btrim(p_ ->> 'place'), ''));
    return jsonb_build_object('id', p_ ->> 'id');
  when 'field_job_cancel' then
    if v_fn <> 'fleet' then raise exception 'Fleet cancels field jobs' using errcode = '42501'; end if;
    perform app.cancel_field_job((p_ ->> 'id')::uuid, p_user, p_ ->> 'reason'); return jsonb_build_object('id', p_ ->> 'id');
  when 'submit_findings' then
    if v_fn <> 'fleet' then raise exception 'Fleet reviews the return photos' using errcode = '42501'; end if;
    return to_jsonb(app.submit_return_findings(b.id, p_user, coalesce(p_ -> 'findings', '{}'::jsonb)));
  else
    if not (p_action = any (v_allowed)) then
      raise exception 'The % assistant cannot %: send it for approval or escalate the task', v_fn, replace(p_action, '_', ' ') using errcode = '42501';
    end if;
    if p_action in ('booking_save', 'send_offer', 'resend_offer') then perform app.va_guard_booking_edit(v_fn, p_); end if;
    if p_action = 'cancel_booking' and coalesce(p_ ->> 'reason', 'renter_request') <> 'renter_request' then
      raise exception 'An assistant records a cancellation the renter asked for; any other cancellation is an Admin''s' using errcode = '42501';
    end if;
    perform app.va_delegate(p_user);
    return app.admin_do(p_user, p_action, p_);
  end case;
end $$;

-- ================================================================ 6. field staff
-- One job of the field staff member: assigned to them, not cancelled, inside the window of the
-- field_job_details view (from 36 hours before until 24 hours after it is done).
create or replace function app.field_job_of(p_user uuid, p_job uuid) returns field_jobs
language plpgsql stable security definer set search_path = public, app as $$
declare
  j field_jobs;
begin
  if not app.user_is_field(p_user) then raise exception 'Only field staff may do this' using errcode = '42501'; end if;
  select * into j from field_jobs x where x.id = p_job and x.assigned_to = p_user and x.status <> 'cancelled'
     and x.scheduled_at <= now() + interval '36 hours' and (x.completed_at is null or x.completed_at > now() - interval '24 hours');
  return j;
end $$;

create or replace function app.field_report_kind(p_kind text) returns text
language sql immutable as $$
  select case when p_kind in ('handover', 'delivery') then 'pickup' when p_kind in ('return_check_in', 'pickup_from_renter') then 'return'
              when p_kind = 'detail' then 'ready' end
$$;

-- The Tracker reports when a reading is fresh (the same rule as the disable guard: never older than
-- program_settings.tracker_reading_max_minutes, at most 10 minutes for the handover check).
create or replace function app.tracker_reading(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('installed', d.id is not null, 'reported_at', s.reported_at,
                            'reporting', s.reported_at is not null and s.reported_at > now() - interval '10 minutes')
    from (select 1) one
    left join tracker_devices d on d.vehicle_id = p_vehicle and d.status = 'installed'
    left join tracker_status s on s.tracker_device_id = d.id
$$;

create or replace function app.field_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  j field_jobs;
  b bookings;
  v vehicles;
  v_kind text;
  v_report condition_reports;
  v_pickup condition_reports;
  v_ready jsonb;
begin
  if not app.user_is_field(p_user) then raise exception 'Only field staff may do this' using errcode = '42501'; end if;
  case p_what
  when 'jobs' then
    return jsonb_build_object(
      'today', coalesce((select jsonb_agg(to_jsonb(x)) from app.staff_field_jobs(p_user, app.today()) x), '[]'::jsonb),
      'tomorrow', coalesce((select jsonb_agg(to_jsonb(x)) from app.staff_field_jobs(p_user, app.today() + 1) x), '[]'::jsonb),
      'moves', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'vehicle_id', m.vehicle_id, 'vehicle_name', app.vehicle_name(m.vehicle_id), 'purpose', m.purpose,
                            'started_at', m.started_at, 'from_place', m.from_place)) from vehicle_moves m where m.staff_user_id = p_user and m.ended_at is null), '[]'::jsonb),
      'vehicles', coalesce((select jsonb_agg(distinct jsonb_build_object('id', x.vehicle_id, 'name', app.vehicle_name(x.vehicle_id)))
                              from field_jobs x where x.assigned_to = p_user and x.status <> 'cancelled'
                               and x.scheduled_at between now() - interval '2 days' and now() + interval '36 hours'), '[]'::jsonb),
      'name', (select full_name from users where id = p_user));
  when 'job' then
    j := app.field_job_of(p_user, (p_ ->> 'id')::uuid);
    if j.id is null then return null; end if;
    select * into v from vehicles where id = j.vehicle_id;
    if j.booking_id is not null then select * into b from bookings where id = j.booking_id; end if;
    v_kind := app.field_report_kind(j.kind);
    if v_kind is not null then
      select * into v_report from condition_reports r where r.kind = v_kind and r.vehicle_id = j.vehicle_id and r.booking_id is not distinct from j.booking_id
       order by r.created_at desc limit 1;
    end if;
    if b.id is not null then
      select * into v_pickup from condition_reports r where r.kind = 'pickup' and r.booking_id = b.id order by r.created_at desc limit 1;
      v_ready := app.booking_readiness(b.id);
    end if;
    return jsonb_build_object(
      'job', to_jsonb(j), 'report_kind', v_kind,
      'vehicle', jsonb_build_object('id', v.id, 'name', v.year || ' ' || v.make || ' ' || v.model, 'plate', v.plate, 'colour', v.colour, 'class', v.class, 'odometer_km', v.odometer_km),
      'booking', case when b.id is null then null else jsonb_build_object(
          'id', b.id, 'booking_number', b.booking_number, 'status', b.status, 'pickup_at', b.pickup_at, 'return_at', b.return_at, 'unattended', b.unattended_handover,
          'km_allowance_total', b.km_allowance_total, 'odometer_out_km', b.odometer_out_km, 'fuel_out_pct', b.fuel_out_pct, 'booking_type', b.booking_type,
          'renter', (select jsonb_build_object('name', r.legal_name, 'mobile', r.mobile) from renters r where r.id = b.renter_id),
          'drivers', coalesce((select jsonb_agg(jsonb_build_object('name', d.full_name, 'role', d.role, 'licence_number', d.licence_number, 'licence_class', d.licence_class,
                                 'licence_expiry', d.licence_expiry, 'verified', d.identity_verified_on is not null, 'accepted', d.role = 'renter' or d.accepted_at is not null)
                                 order by d.role desc, d.full_name) from booking_drivers d where d.booking_id = b.id), '[]'::jsonb),
          'card', (select jsonb_build_object('brand', pm.card_brand, 'last4', pm.card_last4) from payment_methods pm where pm.id = b.card_on_file_id),
          'extras', coalesce((select jsonb_agg(distinct coalesce(l.description, replace(l.charge_type, '_', ' '))) from booking_line_items l
                                where l.booking_id = b.id and l.voided_at is null and (l.charge_type like '%tire%' or l.charge_type like '%seat%' or l.charge_type like 'extra%')), '[]'::jsonb)) end,
      -- the ready check of the handover, as plain lines (no amounts: the deposit is taken or not)
      'ready', case when v_ready is null then null else jsonb_build_object(
          'identity', (v_ready ->> 'all_drivers_verified')::boolean, 'coverage', (v_ready ->> 'coverage_confirmed')::boolean,
          'drivers_accepted', (v_ready ->> 'additional_drivers_accepted')::boolean, 'calendar', (v_ready ->> 'blocks_calendar')::boolean,
          'agreement', (v_ready ->> 'agreement_completed')::boolean,
          'deposit', case when (v_ready ->> 'deposit_waived')::boolean then 'waived' when (v_ready ->> 'deposit_taken')::boolean then 'taken'
                          when b.booking_type = 'owner' then 'none'
                          when exists (select 1 from deposits d where d.booking_id = b.id and d.status = 'failed') then 'declined' else 'not_taken' end) end,
      'tracker', app.tracker_reading(j.vehicle_id),
      'shots', case when v_kind is null then '[]'::jsonb else coalesce((select jsonb_agg(jsonb_build_object('seq', s.seq, 'shot', s.shot, 'guide', s.guide) order by s.seq)
                  from app.required_shots_for(v_kind, v.class) s), '[]'::jsonb) end,
      'report', case when v_report.id is null then null else to_jsonb(v_report) || jsonb_build_object(
          'photos', coalesce((select jsonb_agg(jsonb_build_object('seq', ph.seq, 'shot', ph.shot, 'storage_path', ph.storage_path) order by ph.seq)
                               from condition_report_photos ph where ph.condition_report_id = v_report.id), '[]'::jsonb),
          'damages', coalesce((select jsonb_agg(jsonb_build_object('label', dm.label, 'location', dm.location, 'description', dm.description, 'kind', dm.kind,
                                 'size_cm', dm.size_cm, 'position', dm.position, 'is_new', dm.is_new) order by dm.label)
                                from condition_report_damages dm where dm.condition_report_id = v_report.id), '[]'::jsonb),
          'problems', to_jsonb(app.condition_report_problems(v_report.id))) end,
      'pickup', case when v_pickup.id is null or v_kind <> 'return' then null else jsonb_build_object('odometer_km', v_pickup.odometer_km, 'fuel_pct', v_pickup.fuel_pct,
          'keys_count', v_pickup.keys_count,
          'damages', coalesce((select jsonb_agg(jsonb_build_object('label', dm.label, 'location', dm.location, 'description', dm.description, 'position', dm.position) order by dm.label)
                                from condition_report_damages dm where dm.condition_report_id = v_pickup.id), '[]'::jsonb)) end,
      'baseline_damages', case when v_kind = 'pickup' then coalesce((select jsonb_agg(jsonb_build_object('label', dm.label, 'location', dm.location, 'description', dm.description, 'position', dm.position) order by dm.label)
                               from condition_report_damages dm where dm.condition_report_id = (select r.id from condition_reports r where r.vehicle_id = j.vehicle_id
                                 and r.kind in ('return', 'baseline') and r.completed_at is not null order by r.completed_at desc limit 1)), '[]'::jsonb) end,
      'move', (select to_jsonb(m) from vehicle_moves m where m.vehicle_id = j.vehicle_id and m.ended_at is null limit 1),
      'now', now());
  else
    raise exception 'Unknown screen %', p_what using errcode = '22023';
  end case;
end $$;

create or replace function app.field_do(p_user uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
  j field_jobs;
  d jsonb;
  v_id uuid;
  v_kind text;
  v_out jsonb;
begin
  if not app.user_is_field(p_user) then raise exception 'Only field staff may do this' using errcode = '42501'; end if;
  if p_ ? 'job' then
    j := app.field_job_of(p_user, (p_ ->> 'job')::uuid);
    if j.id is null then raise exception 'That job is not one of yours' using errcode = '42501'; end if;
    v_kind := app.field_report_kind(j.kind);
  end if;
  -- the server's own readings, never the phone's: the Tracker check and the photo owner
  d := coalesce(p_ -> 'report', '{}'::jsonb) - 'tracker_reporting' - 'deposit_waiver' - 'deposit_payment_id';
  case p_action
  when 'acknowledge' then perform app.accept_field_job(j.id, p_user); return jsonb_build_object('status', 'acknowledged');
  when 'start' then perform app.start_field_job(j.id, p_user); return jsonb_build_object('status', 'in_progress');
  when 'save_report' then
    if v_kind is null then raise exception 'This job has no Condition Report' using errcode = '22023'; end if;
    v_id := app.save_condition_report(j.booking_id, v_kind, p_user, d, j.id, j.vehicle_id);
    return jsonb_build_object('report_id', v_id, 'problems', to_jsonb(app.condition_report_problems(v_id)));
  when 'complete_handover' then
    if v_kind <> 'pickup' then raise exception 'This job is not a handover' using errcode = '22023'; end if;
    d := d || jsonb_build_object('tracker_reporting', coalesce((app.tracker_reading(j.vehicle_id) ->> 'reporting')::boolean, false));
    v_id := app.complete_handover(j.booking_id, p_user, d, j.id);
    return jsonb_build_object('report_id', v_id, 'booking_status', (select status from bookings where id = j.booking_id));
  when 'complete_return' then
    if v_kind <> 'return' then raise exception 'This job is not a return' using errcode = '22023'; end if;
    v_out := app.complete_return(j.booking_id, p_user, d, j.id);
    return coalesce(v_out, '{}'::jsonb) || jsonb_build_object('booking_status', (select status from bookings where id = j.booking_id));
  when 'block_handover' then
    return jsonb_build_object('task_id', app.block_handover(j.booking_id, p_user, p_ ->> 'reason', j.id));
  when 'move_start' then
    if not exists (select 1 from field_jobs x where x.assigned_to = p_user and x.vehicle_id = (p_ ->> 'vehicle')::uuid and x.status <> 'cancelled'
                     and x.scheduled_at between now() - interval '2 days' and now() + interval '36 hours') then
      raise exception 'Move only a car of one of your jobs' using errcode = '42501';
    end if;
    v_id := app.start_vehicle_move((p_ ->> 'vehicle')::uuid, p_user, coalesce(nullif(btrim(p_ ->> 'purpose'), ''), 'other'), nullif(btrim(p_ ->> 'from_place'), ''),
                                   (p_ ->> 'odometer')::integer, j.id, j.booking_id, now(), p_user);
    return jsonb_build_object('move_id', v_id);
  when 'move_end' then
    if not exists (select 1 from vehicle_moves m where m.id = (p_ ->> 'move')::uuid and m.staff_user_id = p_user) then
      raise exception 'That move is not yours' using errcode = '42501';
    end if;
    perform app.end_vehicle_move((p_ ->> 'move')::uuid, nullif(btrim(p_ ->> 'to_place'), ''), (p_ ->> 'odometer')::integer, now());
    return jsonb_build_object('ended', true);
  when 'late_damage' then
    if j.booking_id is null then raise exception 'Late damage belongs to a booking' using errcode = '22023'; end if;
    return jsonb_build_object('damage_id', app.record_late_damage(j.booking_id, p_user, p_ -> 'damage', now(), null));
  else
    raise exception 'Unknown action %', p_action using errcode = '22023';
  end case;
end $$;

-- ================================================================ 7. investors
create or replace function app.investor_of(p_user uuid) returns investors
language plpgsql stable security definer set search_path = public, app as $$
declare
  i investors;
begin
  select * into i from investors where user_id = p_user and status in ('active', 'exited');
  if i.id is null then raise exception 'This area is for investors who have signed in' using errcode = '42501'; end if;
  return i;
end $$;

create or replace function app.investor_read(p_user uuid, p_what text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i investors := app.investor_of(p_user);
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  case p_what
  when 'home' then
    return jsonb_build_object(
      'investor', jsonb_build_object('id', i.id, 'legal_name', i.legal_name, 'status', i.status, 'email', i.email, 'phone', i.phone, 'address', i.address,
                                     'tax_information_complete', i.tax_information_complete),
      'bank_last4', (select a.account_last4 from investor_bank_accounts a where a.investor_id = i.id and a.is_current),
      'agreement', (select jsonb_build_object('agreement_number', a.agreement_number, 'status', a.status, 'id', a.id) from investment_agreements a
                     where a.investor_id = i.id order by a.created_at desc limit 1),
      'investments', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'principal_cents', x.principal_cents, 'reinvested_cents', x.reinvested_cents,
                                 'redeemed_cents', x.redeemed_cents, 'invested_amount_cents', x.invested_amount_cents, 'yearly_bps', x.yearly_bps,
                                 'investment_date', x.investment_date, 'lockup_end_date', x.lockup_end_date, 'status', x.status, 'is_initial', x.is_initial,
                                 'mode', app.investment_mode(x.agreement_id, app.today()),
                                 'next_payment_date', (app.month_start(greatest(app.today(), x.lockup_end_date)) + interval '1 month' + interval '14 days')::date)
                                 order by x.investment_date) from investments x where x.investor_id = i.id), '[]'::jsonb),
      'latest', (select jsonb_build_object('id', r.id, 'return_month', r.return_month, 'return_cents', r.return_cents, 'disposition', r.disposition, 'status', r.status)
                   from investment_returns r join investments x on x.id = r.investment_id where x.investor_id = i.id order by r.return_month desc limit 1),
      'redemptions', coalesce((select jsonb_agg(jsonb_build_object('kind', d.kind, 'notice_date', d.notice_date, 'redemption_date', d.redemption_date,
                                 'amount_cents', d.amount_cents, 'status', d.status) order by d.notice_date desc)
                               from investment_redemptions d join investments x on x.id = d.investment_id where x.investor_id = i.id and d.status in ('noticed', 'requested')), '[]'::jsonb),
      'held', coalesce((select jsonb_agg(jsonb_build_object('return_month', r.return_month, 'return_cents', r.return_cents, 'hold_reason', r.hold_reason) order by r.return_month)
                        from investment_returns r join investments x on x.id = r.investment_id where x.investor_id = i.id and r.status = 'held'), '[]'::jsonb),
      'transfers', coalesce((select jsonb_agg(jsonb_build_object('amount_cents', t.amount_cents, 'effective_date', t.effective_date, 'status', t.status)) from investment_transfers t join investments x on x.id = t.from_investment_id where x.investor_id = i.id), '[]'::jsonb),
      'requests', coalesce((select jsonb_agg(jsonb_build_object('title', k.title, 'status', k.status, 'created_at', k.created_at) order by k.created_at desc)
                            from tasks k where k.related_table = 'investors' and k.related_id = i.id and k.task_type = 'investor_request'), '[]'::jsonb),
      'election_effective_month', public.calc_election_effective_month(app.today()));
  when 'statements' then
    return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'return_month', r.return_month, 'opening_invested_cents', r.opening_invested_cents,
               'days_earning', r.days_earning, 'days_in_month', r.days_in_month, 'return_cents', r.return_cents, 'disposition', r.disposition,
               'payment_date', r.payment_date, 'status', r.status, 'has_pdf', r.statement_document_id is not null) order by r.return_month desc)
             from investment_returns r join investments x on x.id = r.investment_id where x.investor_id = i.id), '[]'::jsonb);
  when 'statement' then
    return (select jsonb_build_object('id', r.id, 'legal_name', i.legal_name,
              'agreement_number', (select a.agreement_number from investment_agreements a where a.id = x.agreement_id),
              'return_month', r.return_month, 'opening_invested_cents', r.opening_invested_cents, 'yearly_bps', r.yearly_bps,
              'days_earning', r.days_earning, 'days_in_month', r.days_in_month, 'return_cents', r.return_cents, 'withheld_tax_cents', r.withheld_tax_cents,
              'disposition', r.disposition, 'status', r.status, 'payment_date', r.payment_date, 'closing_invested_cents', r.closing_invested_cents,
              'paid_at', (select p.paid_at from payouts p where p.id = r.payout_id),
              'bank_last4', (select a.account_last4 from investor_bank_accounts a where a.investor_id = i.id and a.is_current),
              'company', (select jsonb_build_object('legal_name', s.legal_name_displayed, 'address', s.mailing_address) from site_settings s limit 1))
              from investment_returns r join investments x on x.id = r.investment_id
             where r.id = (p_ ->> 'id')::uuid and x.investor_id = i.id);
  when 'documents' then
    return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'created_at', d.created_at) order by d.created_at desc)
                     from documents d where d.investor_id = i.id and d.purged_at is null), '[]'::jsonb);
  else
    raise exception 'Unknown screen %', p_what using errcode = '22023';
  end case;
end $$;

-- An investor changes nothing directly (07-investor.md section 1): each request is an Admin task,
-- and an Admin records it through the existing functions and tables.
create or replace function app.investor_do(p_user uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i investors := app.investor_of(p_user);
  p_ jsonb := coalesce(p, '{}'::jsonb);
  v_title text;
  v_detail text;
  v_id uuid;
begin
  if i.status <> 'active' then raise exception 'Requests are made while the investment is active' using errcode = '23514'; end if;
  case p_action
  when 'election_change' then
    if p_ ->> 'mode' not in ('pay', 'reinvest') then raise exception 'Choose paid monthly or reinvested' using errcode = '22023'; end if;
    v_title := format('%s asks to have returns %s', i.legal_name, case p_ ->> 'mode' when 'pay' then 'paid monthly' else 'reinvested' end);
    v_detail := format('Received %s. Applies from the Return Month starting %s if recorded as received today.', app.today(),
                       public.calc_election_effective_month(app.today()));
  when 'bank_change' then
    v_title := format('%s asks to change the bank account for returns', i.legal_name);
    v_detail := 'Call the investor at the number on file to take the new account details. Nothing was collected online.';
  when 'transfer_request' then
    if not exists (select 1 from investments x where x.id = (p_ ->> 'investment')::uuid and x.investor_id = i.id) then
      raise exception 'Choose one of your investments' using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(p_ ->> 'to_name', '')), '') is null then raise exception 'Name the person the investment would go to' using errcode = '22023'; end if;
    v_title := format('%s asks to transfer an investment', i.legal_name);
    v_detail := format('To: %s. %s', left(btrim(p_ ->> 'to_name'), 200), coalesce(left(btrim(p_ ->> 'note'), 1000), ''));
  else
    raise exception 'Unknown request %', p_action using errcode = '22023';
  end case;
  v_id := app.raise_task(p_type => 'investor_request', p_title => v_title, p_detail => v_detail, p_related_table => 'investors', p_related_id => i.id,
                         p_dedupe => 'investor_request:' || i.id || ':' || p_action || ':' || app.today(), p_created_by => p_user);
  return jsonb_build_object('task_id', v_id);
end $$;

-- ================================================================ 8. the API
-- One entry point: the server passes the signed-in user, their session's assurance level, which
-- reader or action, its name and its arguments.
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.door_begin(p_user, p_aal);
  case p_call
  when 'roles' then return app.my_roles(p_user);
  when 'admin_list' then return app.admin_list(p_user, p_name, p);
  when 'admin_read' then return app.admin_read(p_user, p_name, p);
  when 'admin_save' then return app.admin_save(p_user, p_name, p);
  when 'admin_do' then return app.admin_do(p_user, p_name, p);
  when 'va_list' then return app.va_list(p_user, p_name, p);
  when 'va_read' then return app.va_read(p_user, p_name, p);
  when 'va_do' then return app.va_do(p_user, p_name, p);
  when 'field_read' then return app.field_read(p_user, p_name, p);
  when 'field_do' then return app.field_do(p_user, p_name, p);
  when 'investor_read' then return app.investor_read(p_user, p_name, p);
  when 'investor_do' then return app.investor_do(p_user, p_name, p);
  else raise exception 'Unknown call %', p_call using errcode = '22023';
  end case;
end $$;

create or replace function public.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.door(p_user, p_aal, p_call, p_name, p) $$;
create or replace function public.my_roles(p_user uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.my_roles(p_user) $$;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['refund_approval_resolve', 'staff_message_problem', 'my_roles', 'door_begin', 'admin_begin', 'va_fn',
              'va_delegate', 'va_list', 'va_booking', 'va_read', 'va_guard_booking_edit', 'va_do', 'field_job_of', 'field_report_kind', 'tracker_reading',
              'field_read', 'field_do', 'investor_of', 'investor_read', 'investor_do', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['door', 'my_roles']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
