-- 0441: Data health, the database checking its own records every night (docs/changes/2026-11-07-data-health.md).
--
-- The owner: "i shouldnt be spotting this myself, u should be telling me this and fixing it urself". Found by him in
-- production: bookings whose cars clearly went out still "confirmed" or "expired", a confirmed booking of October 25 to 27
-- never closed, a sales assistant's To do with duplicate tasks and "Offer expiring soon" for cars already out, real
-- owner leads never contacted, licence reviews waiting a week, cars added by VIN or permit with no seats.
--
-- 1. app.data_health(now): every check in one read, each with a plain line, a count and its records (the first 25), each
--    record with its link and, where it is safe, a one-tap fix. The checks:
--      pickup_not_recorded  confirmed, pickup time passed, no pickup recorded (Bookings > Now's "pickup not recorded",
--                           app.fleet_board of 0330): Mark picked up
--      never_closed         confirmed, return time passed, never closed (Bookings > Now's "ended, never closed", and the
--                           unrecorded ones whose return passed): Close (0330's booking_close_ended)
--      dead_with_money      expired or declined, yet paid or with a pickup or return report: link (an Admin's call)
--      on_rent_gaps         on rent with no signed agreement or no deposit: link
--      test_accounts        real work routed or credited to a test account (0440): Unassign, or link
--      inactive_assignee    open tasks or leads assigned to someone suspended, closed or no longer staff: Unassign
--      lead_followup        real owner leads whose follow-up stopped before a reply, or never planned; other leads still
--                           "new" after 2 days: Restart follow-up (owner leads), or link
--      licence_waiting      licence or selfie photos waiting more than 24 hours for a review: link
--      duplicate_tasks      two or more open tasks of one kind on one record: Close (keeps the one being worked)
--      resolved_tasks       open tasks whose subject is already settled (a request answered, an offer that became a
--                           booking, a car that came back, a lead closed): Close
--      car_gaps             published real cars missing seats, plate, real photos, a rate card or owner terms: link
--      owners_terms         program owners with cars and no terms entered: link
--      unmatched_payments   a renter's payment with no booking, a card processor charge matched to no payment: link
--      deposits_overdue     deposits still held 7 days after the return: link
--      offers_stale         offers that expired more than 48 hours ago still in a queue: Close (the task), or link
--      sample_requests      real requests on sample cars that nobody has turned into a real car yet: link
--      usage_trend          email or AI usage heading over its included allowance: link to Settings > Usage
-- 2. app.data_health_autofix(now): the clear-cut cases, fixed without asking: test accounts taken off real records
--    (0440's fences stop new ones), duplicate tasks closed, tasks whose subject is settled closed. Judgment calls (did an
--    expired booking actually run?) stay on the card. It runs with the hourly task hygiene (0078) and nightly.
-- 3. app.job_data_health(): nightly at 03:23 Toronto (08:23 UTC). The auto-fixes, then the checks, kept in
--    data_health_runs (the last 30), then one in-app notice a day to each Admin when something needs them (no email,
--    no text, no push).
-- 4. The door: ops_read data_health (Admins: the last run, with what the auto-fix did), ops_do data_health_fix (one record's
--    fix) and data_health_run (check now). The card on Admin > To do (DataHealthCard).
-- 5. Now: the auto-fix runs once (migration time).
-- No applied migration is edited.
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

-- ================================================================ the runs
create table if not exists data_health_runs (
  id          uuid primary key default gen_random_uuid(),
  ran_at      timestamptz not null default now(),
  issues      integer not null default 0,
  checks      jsonb not null default '[]'::jsonb,
  fixed       jsonb not null default '{}'::jsonb,
  ran_by      uuid references users (id) on delete set null
);
comment on table data_health_runs is 'Data health (0441): each run of the checks (nightly, or Check now), the last 30 kept. checks: every check with its count and first 25 records; fixed: what the auto-fix did before it.';
create index if not exists data_health_runs_at_idx on data_health_runs (ran_at desc);
alter table data_health_runs enable row level security;
create policy admin_all on data_health_runs for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on data_health_runs from anon, authenticated;
grant all on data_health_runs to service_role;

insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, subject, preheader, link_path, variables, has_email, in_catalogue,
                                    priority, user_can_mute, is_enabled, emitted_by, push_topic)
values ('staff_data_health', 'staff_admin', '{}', 'transactional', false, 'Data health: {{issues}} to look at',
        'The nightly check found records that need you. Open Admin > To do.', '/admin', '["issues"]'::jsonb, false, true, 3, false, true,
        'app.job_data_health (0441)', null)
on conflict (code) do nothing;

-- ================================================================ 1. the checks
-- one check: its line with the count, the first 25 records
create or replace function app.dh_check(p_key text, p_title text, p_line text, p_items jsonb, p_href text default null) returns jsonb
language sql immutable as $$
  select jsonb_build_object('key', p_key, 'title', p_title, 'line', p_line, 'href', p_href,
           'count', jsonb_array_length(coalesce(p_items, '[]'::jsonb)),
           'items', coalesce((select jsonb_agg(x order by n) from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) with ordinality e(x, n) where n <= 25), '[]'::jsonb))
$$;

create or replace function app.dh_item(p_id uuid, p_text text, p_href text, p_fix text default null, p_fix_label text default null) returns jsonb
language sql immutable as $$
  select jsonb_build_object('id', p_id, 'text', p_text, 'href', p_href,
           'fix', case when p_fix is not null then jsonb_build_object('action', p_fix, 'label', p_fix_label) end)
$$;

-- the tasks settled by their subject (closed by the auto-fix): task id and why
create or replace function app.dh_resolved_tasks() returns table (task_id uuid, why text)
language sql stable security definer set search_path = public, app as $$
  select t.id, 'The request was answered (the booking is ' || replace(b.status::text, '_', ' ') || ')'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type in ('booking_request', 'request_open_to_sales') and b.status <> 'requested'
  union all
  select t.id, 'The offer is no longer out (the booking is ' || replace(b.status::text, '_', ' ') || ')'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type = 'chase_offer' and b.status not in ('offered', 'tentative', 'pending_payment')
  union all
  select t.id, 'The booking went ahead (it is ' || replace(b.status::text, '_', ' ') || ')'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting')
     and t.task_type in ('offer_expired', 'reoffer_booking', 'offer_change_requested', 'offer_change', 'calendar_offer_clash')
     and b.status in ('confirmed', 'on_rent', 'returned', 'closed', 'cancelled', 'declined', 'no_show')
  union all
  select t.id, 'The rental is over (the booking is ' || replace(b.status::text, '_', ' ') || ')'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting')
     and t.task_type in ('chase_verification', 'handover_essentials', 'offer_approved_paid', 'confirm_offline_booking', 'renew_deposit_hold')
     and b.status in ('returned', 'closed', 'cancelled', 'expired', 'declined', 'no_show')
  union all
  select t.id, 'The car came back'
    from tasks t join bookings b on b.id = t.booking_id
   where t.status in ('open', 'in_progress', 'waiting') and t.task_type in ('late_return', 'late_return_admin')
     and (b.checked_in_at is not null or b.status in ('returned', 'closed', 'cancelled'))
  union all
  select t.id, 'The lead is ' || l.status
    from tasks t join leads l on l.id = t.related_id
   where t.status in ('open', 'in_progress', 'waiting') and t.related_table = 'leads' and l.status in ('converted', 'closed', 'spam')
$$;

-- duplicate open tasks: every open task of one kind on one record but the one kept (the one being worked, else the oldest)
create or replace function app.dh_duplicate_tasks() returns table (task_id uuid, kept uuid)
language sql stable security definer set search_path = public, app as $$
  select id, first_value(id) over w from (
    select t.*, count(*) over (partition by t.task_type, t.booking_id, t.vehicle_id, t.owner_id, t.renter_id, t.related_table, t.related_id) n
      from tasks t
     where t.status in ('open', 'in_progress', 'waiting')
       and coalesce(t.booking_id, t.vehicle_id, t.owner_id, t.renter_id, t.related_id) is not null) d
  where n > 1
  window w as (partition by task_type, booking_id, vehicle_id, owner_id, renter_id, related_table, related_id
               order by (status = 'in_progress') desc, (assigned_to is not null) desc, created_at, id)
$$;
create or replace function app.dh_duplicate_tasks_extra() returns table (task_id uuid, kept uuid)
language sql stable security definer set search_path = public, app as $$
  select d.task_id, d.kept from app.dh_duplicate_tasks() d where d.task_id <> d.kept
$$;

-- a person who no longer works: not active, or neither an Admin nor active staff
create or replace function app.dh_gone(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and not app.is_test_user(p_user) and not exists (
    select 1 from users u where u.id = p_user and u.status = 'active'
       and (app.user_is_admin(u.id) or exists (select 1 from staff_profiles sp where sp.user_id = u.id and sp.is_active)))
$$;

create or replace function app.dh_task_text(t tasks) returns text
language sql stable security definer set search_path = public, app as $$
  select concat_ws(': ', t.title, (select b.booking_number from bookings b where b.id = t.booking_id))
$$;

create or replace function app.data_health(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  fb jsonb := app.fleet_board(p_now);
  v jsonb := '[]'::jsonb;
  x jsonb;
begin
  -- confirmed, pickup passed, nothing recorded (Bookings > Now's own list)
  select coalesce(jsonb_agg(app.dh_item((c ->> 'booking_id')::uuid,
           format('%s, %s: pickup was %s', c ->> 'number', c #>> '{car,name}', app.fmt_time((c ->> 'booked_pickup_at')::timestamptz)),
           '/admin/bookings/' || (c ->> 'number'), 'mark_picked_up', 'Mark picked up') order by c ->> 'booked_pickup_at'), '[]'::jsonb) into x
    from jsonb_array_elements(fb -> 'out') c
   where (c ->> 'unrecorded')::boolean and (c ->> 'return_at')::timestamptz > p_now;
  v := v || app.dh_check('pickup_not_recorded', 'Pickup not recorded', 'Confirmed bookings whose pickup time passed with no pickup recorded', x, '/admin/bookings');

  -- confirmed, return passed, never closed
  select coalesce(jsonb_agg(app.dh_item((c ->> 'booking_id')::uuid,
           format('%s, %s: due back %s', c ->> 'number', c #>> '{car,name}', app.fmt_time((c ->> 'return_at')::timestamptz)),
           '/admin/bookings/' || (c ->> 'number'), 'close_booking', 'Close') order by c ->> 'return_at'), '[]'::jsonb) into x
    from (select c from jsonb_array_elements(fb -> 'stale') c
          union all
          select c from jsonb_array_elements(fb -> 'out') c where (c ->> 'unrecorded')::boolean and (c ->> 'return_at')::timestamptz <= p_now) s;
  v := v || app.dh_check('never_closed', 'Never closed', 'Confirmed bookings whose return time passed and were never closed', x, '/admin/bookings');

  -- expired or declined, yet money came in or the car was handed over
  select coalesce(jsonb_agg(app.dh_item(b.id,
           format('%s is %s but %s', b.booking_number, b.status,
                  concat_ws(' and ', case when p.paid then 'was paid' end, case when r.reported then 'has a pickup or return report' end)),
           '/admin/bookings/' || b.booking_number) order by b.pickup_at desc), '[]'::jsonb) into x
    from bookings b
    cross join lateral (select exists (select 1 from payments p where p.booking_id = b.id and p.status = 'succeeded' and p.kind in ('charge', 'capture')) paid) p
    cross join lateral (select exists (select 1 from condition_reports c where c.booking_id = b.id and c.completed_at is not null) reported) r
   where b.status in ('expired', 'declined') and not coalesce(b.is_placeholder, false) and (p.paid or r.reported)
     and not app.booking_is_test(b.id);
  v := v || app.dh_check('dead_with_money', 'Expired but ran', 'Bookings marked expired or declined that were paid or have a pickup or return report', x, '/admin/bookings?view=all');

  -- on rent without a signed agreement or a deposit
  select coalesce(jsonb_agg(app.dh_item(b.id,
           format('%s, %s: %s', b.booking_number, app.vehicle_name(b.vehicle_id),
                  concat_ws(' and ', case when not s.signed then 'no signed agreement' end, case when not (h.e ->> 'deposit')::boolean then 'no deposit' end)),
           '/admin/bookings/' || b.booking_number) order by b.pickup_at), '[]'::jsonb) into x
    from bookings b
    cross join lateral (select app.handover_essentials(b.id) e) h
    cross join lateral (select (h.e ->> 'agreement')::boolean
                               or exists (select 1 from rental_agreements a where a.booking_id = b.id and a.status in ('signed', 'completed')) signed) s
   where b.status = 'on_rent' and b.booking_type <> 'owner' and not coalesce(b.is_placeholder, false)
     and (not s.signed or not (h.e ->> 'deposit')::boolean) and not app.booking_is_test(b.id);
  v := v || app.dh_check('on_rent_gaps', 'On rent, papers missing', 'Cars on rent with no signed agreement or no deposit', x, '/admin/bookings');

  -- real work routed or credited to a test account
  select coalesce(jsonb_agg(i order by i ->> 'text'), '[]'::jsonb) into x from (
    select app.dh_item(t.id, format('Task "%s" is assigned to %s', app.dh_task_text(t), u.full_name), '/admin/tasks', 'unassign_task', 'Unassign') i
      from tasks t join users u on u.id = t.assigned_to and u.is_test
     where t.status in ('open', 'in_progress', 'waiting') and not app.row_is_test('tasks', to_jsonb(t))
    union all
    select app.dh_item(l.id, format('Lead %s is assigned to %s', coalesce(l.name, l.email, l.phone), u.full_name), '/admin/leads', 'unassign_lead', 'Unassign')
      from leads l join users u on u.id = l.assigned_to and u.is_test
     where l.status in ('new', 'contacted', 'qualified') and not app.row_is_test('leads', to_jsonb(l))
    union all
    select app.dh_item(j.id, format('Field job %s on %s is assigned to %s', replace(j.kind, '_', ' '), app.fmt_time(j.scheduled_at), u.full_name), '/admin/calendar', 'unassign_field_job', 'Unassign')
      from field_jobs j join users u on u.id = j.assigned_to and u.is_test
     where j.status not in ('done', 'cancelled') and not app.booking_is_test(j.booking_id)
    union all
    select app.dh_item(b.id, format('Booking %s credits %s', b.booking_number, u.full_name), '/admin/bookings/' || b.booking_number)
      from bookings b join users u on u.is_test and u.id in (b.sales_staff_id, b.referrer_staff_id, b.sales_claim_by)
     where not app.booking_is_test(b.id)
    union all
    select app.dh_item(c.id, format('A %s commission on %s goes to %s', replace(c.kind, '_', ' '), b.booking_number, u.full_name), '/admin/bookings/' || b.booking_number)
      from staff_commissions c join users u on u.id = c.staff_id and u.is_test join bookings b on b.id = c.booking_id
     where c.reversed_at is null and not app.booking_is_test(b.id)
    union all
    select app.dh_item(a.id, format('Owner application %s is sourced by %s', a.application_number, u.full_name), '/admin/applications')
      from owner_applications a join users u on u.id = a.sourced_by and u.is_test
     where not app.subject_is_test(p_owner => a.owner_id)
    union all
    select app.dh_item(v2.id, format('%s is on the site but belongs to a test owner', app.vehicle_name(v2.id)), '/admin/vehicles/' || v2.id)
      from vehicles v2 join owners o on o.id = v2.owner_id and coalesce(o.is_test, false)
      join vehicle_listings l on l.vehicle_id = v2.id and l.status = 'published'
     where not v2.is_sample) q;
  v := v || app.dh_check('test_accounts', 'Test accounts in real work', 'Real work routed or credited to a test account', x);

  -- assigned to someone who no longer works here
  select coalesce(jsonb_agg(i order by i ->> 'text'), '[]'::jsonb) into x from (
    select app.dh_item(t.id, format('Task "%s" is assigned to %s (%s)', app.dh_task_text(t), coalesce(u.full_name, 'a deleted account'), coalesce(u.status, 'deleted')),
                       '/admin/tasks', 'unassign_task', 'Unassign') i
      from tasks t left join users u on u.id = t.assigned_to
     where t.status in ('open', 'in_progress', 'waiting') and t.assigned_to is not null and app.dh_gone(t.assigned_to)
    union all
    select app.dh_item(l.id, format('Lead %s is assigned to %s (%s)', coalesce(l.name, l.email, l.phone), coalesce(u.full_name, 'a deleted account'), coalesce(u.status, 'deleted')),
                       '/admin/leads', 'unassign_lead', 'Unassign')
      from leads l left join users u on u.id = l.assigned_to
     where l.status in ('new', 'contacted', 'qualified') and l.assigned_to is not null and app.dh_gone(l.assigned_to)) q;
  v := v || app.dh_check('inactive_assignee', 'Assigned to someone gone', 'Open tasks or leads assigned to someone who no longer works here', x);

  -- real leads nobody is following up
  select coalesce(jsonb_agg(i order by i ->> 'text'), '[]'::jsonb) into x from (
    select app.dh_item(l.id,
             format('%s (%s owner lead): %s', coalesce(l.name, l.email, l.phone), app.fmt_day(app.local_date(l.created_at)),
                    case when l.followup_stopped_at is not null then 'follow-up stopped (' || coalesce(l.followup_stop_reason, 'no reason') || ')' else 'no follow-up planned' end),
             '/admin/leads', case when l.email is not null then 'restart_followup' end, 'Restart follow-up') i
      from leads l
     where l.kind in ('owner_program', 'owner_recruit') and l.status in ('new', 'contacted', 'qualified')
       and coalesce(l.pipeline_stage, 'new') in ('new', 'contacted') and l.replied_at is null and l.do_not_contact_at is null
       and not app.is_test_email(l.email) and l.created_at < p_now - interval '1 hour'
       and (l.followup_stopped_at is not null or l.followup_next_at is null)
       and not exists (select 1 from owners o where o.id = l.owner_id and o.status = 'active')
    union all
    select app.dh_item(l.id, format('%s (%s, %s): still new, nobody has replied', coalesce(l.name, l.email, l.phone), replace(l.kind, '_', ' '), app.fmt_day(app.local_date(l.created_at))),
                       '/admin/leads')
      from leads l
     where l.kind not in ('owner_program', 'owner_recruit', 'turo_guest', 'launch_notice', 'sample_car') and l.status = 'new'
       and l.created_at < p_now - interval '2 days' and l.created_at > p_now - interval '60 days' and not app.is_test_email(l.email)) q;
  v := v || app.dh_check('lead_followup', 'Leads not followed up', 'Real leads with their follow-up stopped or never started', x, '/admin/leads');

  -- licence photos waiting for a review
  select coalesce(jsonb_agg(app.dh_item(b.id, format('%s: licence photos waiting since %s', b.booking_number, app.fmt_time(w.since)),
                                         '/admin/bookings/' || b.booking_number) order by w.since), '[]'::jsonb) into x
    from (select u.booking_id, min(u.uploaded_at) since from verification_uploads u
           where u.status = 'submitted' and u.kind in ('licence_front', 'licence_back', 'selfie') and u.uploaded_at < p_now - interval '24 hours'
           group by u.booking_id) w
    join bookings b on b.id = w.booking_id
   where b.status in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent') and not app.booking_is_test(b.id);
  v := v || app.dh_check('licence_waiting', 'Licence reviews waiting', 'Licence reviews waiting more than 24 hours', x, '/admin/bookings');

  -- duplicate open tasks
  select coalesce(jsonb_agg(app.dh_item(t.id, format('"%s" is open twice', app.dh_task_text(t)), '/admin/tasks', 'close_task', 'Close') order by t.created_at), '[]'::jsonb) into x
    from app.dh_duplicate_tasks_extra() d join tasks t on t.id = d.task_id;
  v := v || app.dh_check('duplicate_tasks', 'Duplicate tasks', 'Tasks open more than once for the same thing', x, '/admin/tasks');

  -- open tasks whose subject is settled
  select coalesce(jsonb_agg(app.dh_item(t.id, format('"%s": %s', app.dh_task_text(t), r.why), '/admin/tasks', 'close_task', 'Close') order by t.created_at), '[]'::jsonb) into x
    from (select distinct on (task_id) * from app.dh_resolved_tasks()) r join tasks t on t.id = r.task_id;
  v := v || app.dh_check('resolved_tasks', 'Tasks already done', 'Open tasks whose subject is already settled', x, '/admin/tasks');

  -- published real cars with gaps
  select coalesce(jsonb_agg(app.dh_item(c.id, format('%s: no %s', app.vehicle_name(c.id), array_to_string(c.gaps, ', ')), '/admin/vehicles/' || c.id) order by app.vehicle_name(c.id)), '[]'::jsonb) into x
    from (select v2.id, array_remove(array[
                   case when coalesce(l.seats, 0) <= 0 then 'seats' end,
                   case when nullif(btrim(coalesce(v2.plate, '')), '') is null and v2.supply_type <> 'partner' then 'plate' end,
                   case when not exists (select 1 from vehicle_photos ph where ph.vehicle_id = v2.id and ph.status = 'approved' and ph.is_public and ph.replaced_at is null)
                        then 'real photos' end,
                   case when not exists (select 1 from rate_cards rc where rc.vehicle_id = v2.id and rc.effective_from <= p_now
                                          and (rc.effective_to is null or rc.effective_to > p_now) and rc.daily_rate_cents > 0) then 'rate card' end,
                   case when app.vehicle_needs_terms(v2.id) then 'owner terms' end], null) gaps
            from vehicles v2 join vehicle_listings l on l.vehicle_id = v2.id and l.status = 'published'
           where not v2.is_sample and v2.retired_at is null) c
   where cardinality(c.gaps) > 0;
  v := v || app.dh_check('car_gaps', 'Cars on the site with gaps', 'Published cars missing seats, plate, real photos, a rate card or owner terms', x, '/admin/vehicles');

  -- owners with cars and no terms (as Admin > To do asks)
  select coalesce(jsonb_agg(app.dh_item(o.id, format('%s: no terms entered', o.legal_name), '/admin/owners/' || o.id) order by o.legal_name), '[]'::jsonb) into x
    from owners o
   where o.kind = 'program' and o.status = 'active' and not coalesce(o.is_test, false) and not coalesce(o.is_shareholder, false)
     and exists (select 1 from vehicles v2 where v2.owner_id = o.id and not v2.is_sample and v2.retired_at is null and v2.management_mode <> 'turo_only'
                  and v2.status not in ('exited', 'total_loss', 'declined'))
     and not exists (select 1 from owner_terms t where t.owner_id = o.id)
     and not exists (select 1 from todo_dismissals d where d.key = 'terms:' || o.id);
  v := v || app.dh_check('owners_terms', 'Owners without terms', 'Owners with cars and no terms entered', x, '/admin/owners');

  -- money with nothing to tie it to: a renter's payment with no booking, a processor charge never matched to a payment
  select coalesce(jsonb_agg(i order by i ->> 'text'), '[]'::jsonb) into x from (
    select app.dh_item(p.id, format('%s %s on %s has no booking', app.money_text(p.amount_cents), replace(p.purpose, '_', ' '), app.fmt_day(app.local_date(p.created_at))),
                       '/admin/payments') i
      from payments p
     where p.status = 'succeeded' and p.kind in ('charge', 'capture') and p.booking_id is null
       and p.purpose in ('booking_total', 'deposit', 'extension', 'post_rental', 'addon', 'damage', 'deductible')
    union all
    select app.dh_item(it.id, format('%s from the card processor on %s matches no payment', app.money_text(it.amount_cents), app.fmt_day(app.local_date(it.occurred_at))),
                       '/admin/reconciliation')
      from payout_reconciliation_items it where it.status = 'unmatched' and it.kind = 'charge') q;
  v := v || app.dh_check('unmatched_payments', 'Payments not matched', 'Payments received that are not tied to a booking', x, '/admin/payments');

  -- deposits held long after the return
  select coalesce(jsonb_agg(app.dh_item(b.id, format('%s: %s still held, back %s', b.booking_number, app.money_text(d.amount_cents - d.applied_cents - d.released_cents),
                                                     app.fmt_day(app.local_date(coalesce(b.checked_in_at, b.return_at)))),
                                         '/admin/bookings/' || b.booking_number) order by b.return_at), '[]'::jsonb) into x
    from deposits d join bookings b on b.id = d.booking_id
   where d.status = 'held' and d.amount_cents - d.applied_cents - d.released_cents > 0
     and coalesce(b.checked_in_at, b.return_at) < p_now - interval '7 days' and b.status in ('returned', 'closed', 'cancelled', 'expired', 'declined', 'no_show')
     and (d.held_back_until is null or d.held_back_until < app.local_date(p_now));
  v := v || app.dh_check('deposits_overdue', 'Deposits held too long', 'Deposits still held 7 days after the car came back', x, '/admin/bookings');

  -- offers that ran out long ago and are still in a queue
  select coalesce(jsonb_agg(i order by i ->> 'text'), '[]'::jsonb) into x from (
    select app.dh_item(t.id, format('"%s": the offer ran out %s', app.dh_task_text(t), app.fmt_time(b.offer_expires_at)), '/admin/tasks', 'close_task', 'Close') i
      from tasks t join bookings b on b.id = t.booking_id
     where t.status in ('open', 'in_progress', 'waiting') and t.task_type in ('chase_offer', 'offer_expired', 'reoffer_booking')
       and b.status in ('offered', 'expired') and b.offer_expires_at < p_now - interval '48 hours'
    union all
    select app.dh_item(b.id, format('%s: still "offer out", it ran out %s', b.booking_number, app.fmt_time(b.offer_expires_at)), '/admin/bookings/' || b.booking_number)
      from bookings b where b.status = 'offered' and b.offer_expires_at < p_now - interval '48 hours') q;
  v := v || app.dh_check('offers_stale', 'Old offers in queues', 'Offers that expired more than 48 hours ago still in a queue', x, '/admin/requests');

  -- real requests on sample cars
  select coalesce(jsonb_agg(i order by i ->> 'text'), '[]'::jsonb) into x from (
    select app.dh_item(l.id, format('%s asked for the sample %s on %s: no real car offered yet', coalesce(l.name, l.email, l.phone),
                                    coalesce(l.payload ->> 'vehicle_name', l.payload ->> 'car', 'car'), app.fmt_day(app.local_date(l.created_at))), '/admin/leads') i
      from leads l
     where l.kind = 'sample_car' and l.status = 'new' and l.created_at < p_now - interval '2 hours' and l.created_at > p_now - interval '30 days'
       and not app.is_test_email(l.email)
    union all
    select app.dh_item(b.id, format('%s is a real booking on the sample %s', b.booking_number, app.vehicle_name(b.vehicle_id)), '/admin/bookings/' || b.booking_number)
      from bookings b join vehicles v2 on v2.id = b.vehicle_id and v2.is_sample
     where b.status in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent') and not app.booking_is_test(b.id)) q;
  v := v || app.dh_check('sample_requests', 'Sample car requests', 'Real people who asked for a sample car and were not offered a real one', x, '/admin/leads');

  -- email and AI usage heading over the allowance
  select coalesce(jsonb_agg(app.dh_item(null, format('%s: on course for %s of %s %s', s.label, round(t.projected)::bigint, s.included::bigint, s.unit), '/admin/settings/usage')
                            order by s.sort), '[]'::jsonb) into x
    from usage_services s
    cross join lateral (select case
             when s.period = 'month' then coalesce(s.used, 0)
                  / greatest(extract(epoch from p_now - app.local_midnight(date_trunc('month', app.local_date(p_now))::date)) / 86400.0, 1)
                  * extract(day from (date_trunc('month', app.local_date(p_now)) + interval '1 month - 1 day'))
             when s.period = 'day' then (select avg(d.used) from (select r.day, max(r.used) used from usage_readings r
                                                                   where r.service = s.service and r.day >= app.local_date(p_now) - 7 and r.day < app.local_date(p_now)
                                                                   group by r.day) d)
           end::numeric as projected) t
   where s.enabled and not s.unlimited and s.included > 0 and s.period in ('day', 'month')
     and (s.service in ('workers_ai', 'resend_day', 'resend_month', 'cf_email', 'claude') or s.label ilike '%email%')
     and t.projected > s.included;
  v := v || app.dh_check('usage_trend', 'Usage over allowance', 'Email or AI usage on course to go over its included allowance', x, '/admin/settings/usage');

  return jsonb_build_object('ran_at', p_now, 'issues', (select coalesce(sum((c ->> 'count')::integer), 0) from jsonb_array_elements(v) c), 'checks', v);
end $$;

-- ================================================================ 2. the clear-cut fixes
create or replace function app.data_health_autofix(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n_tasks integer; n_leads integer; n_jobs integer; n_chats integer; n_visits integer; n_book integer; n_claims integer; n_apps integer;
  n_dup integer; n_res integer;
begin
  -- test accounts off real records (back to their queue)
  update tasks t set assigned_to = null, status = case when t.status = 'in_progress' then 'open' else t.status end
   where t.assigned_to in (select id from users where is_test) and t.status in ('open', 'in_progress', 'waiting') and not app.row_is_test('tasks', to_jsonb(t));
  get diagnostics n_tasks = row_count;
  update leads l set assigned_to = null
   where l.assigned_to in (select id from users where is_test) and not app.row_is_test('leads', to_jsonb(l));
  get diagnostics n_leads = row_count;
  update field_jobs j set assigned_to = null, status = case when j.status = 'acknowledged' then 'scheduled' else j.status end, acknowledged_at = null
   where j.assigned_to in (select id from users where is_test) and j.status in ('scheduled', 'acknowledged') and not app.booking_is_test(j.booking_id);
  get diagnostics n_jobs = row_count;
  update chat_conversations c set assigned_to = null
   where c.assigned_to in (select id from users where is_test) and c.status <> 'closed' and not app.row_is_test('chat_conversations', to_jsonb(c));
  get diagnostics n_chats = row_count;
  update visitor_sessions s set assigned_to = null, assigned_at = null
   where s.assigned_to in (select id from users where is_test) and not app.row_is_test('visitor_sessions', to_jsonb(s));
  get diagnostics n_visits = row_count;
  update bookings b
     set sales_staff_id = case when app.is_test_user(b.sales_staff_id) then null else b.sales_staff_id end,
         sales_sourced = case when app.is_test_user(b.sales_staff_id) then false else b.sales_sourced end,
         referrer_staff_id = case when app.is_test_user(b.referrer_staff_id) then null else b.referrer_staff_id end,
         referrer_type = case when app.is_test_user(b.referrer_staff_id) then null else b.referrer_type end,
         sales_claim_by = case when app.is_test_user(b.sales_claim_by) then null else b.sales_claim_by end,
         sales_claim_at = case when app.is_test_user(b.sales_claim_by) then null else b.sales_claim_at end
   where (app.is_test_user(b.sales_staff_id) or app.is_test_user(b.referrer_staff_id) or app.is_test_user(b.sales_claim_by))
     and b.status in ('requested', 'offered', 'tentative', 'pending_payment', 'confirmed', 'on_rent') and not app.booking_is_test(b.id);
  get diagnostics n_book = row_count;
  delete from request_claims c where c.claimed_by in (select id from users where is_test) and not app.booking_is_test(c.booking_id);
  get diagnostics n_claims = row_count;
  update owner_applications a set sourced_by = null
   where a.sourced_by in (select id from users where is_test) and not app.subject_is_test(p_owner => a.owner_id);
  get diagnostics n_apps = row_count;
  -- duplicate open tasks (the one being worked, else the oldest, stays)
  update tasks t set status = 'cancelled', completed_at = p_now, wake_at = null,
         completion_note = coalesce(t.completion_note, 'Duplicate: closed by Data health')
    from app.dh_duplicate_tasks_extra() d where d.task_id = t.id;
  get diagnostics n_dup = row_count;
  -- tasks whose subject is settled
  update tasks t set status = 'cancelled', completed_at = p_now, wake_at = null, completion_note = coalesce(t.completion_note, r.why || ': closed by Data health')
    from (select distinct on (task_id) * from app.dh_resolved_tasks()) r where r.task_id = t.id;
  get diagnostics n_res = row_count;
  return jsonb_strip_nulls(jsonb_build_object(
    'test_tasks', nullif(n_tasks, 0), 'test_leads', nullif(n_leads, 0), 'test_field_jobs', nullif(n_jobs, 0), 'test_chats', nullif(n_chats, 0),
    'test_visitors', nullif(n_visits, 0), 'test_bookings', nullif(n_book, 0), 'test_claims', nullif(n_claims, 0), 'test_applications', nullif(n_apps, 0),
    'duplicate_tasks', nullif(n_dup, 0), 'resolved_tasks', nullif(n_res, 0)));
end $$;

-- the hourly task hygiene (0078) also does the clear-cut fixes, so they never pile up between nights
alter function app.job_task_hygiene(timestamptz) rename to job_task_hygiene_pre0441;
create function app.job_task_hygiene(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.job_task_hygiene_pre0441(p_now) || jsonb_build_object('data_health', app.data_health_autofix(p_now));
end $$;
select pg_temp.copy_grants('app.job_task_hygiene(timestamptz)'::regprocedure, 'app.job_task_hygiene_pre0441(timestamptz)'::regprocedure);

-- ================================================================ 3. the nightly run
create or replace function app.data_health_store(p_now timestamptz, p_fixed jsonb, p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.data_health(p_now);
  v_id uuid;
begin
  insert into data_health_runs (ran_at, issues, checks, fixed, ran_by)
  values (p_now, (r ->> 'issues')::integer, r -> 'checks', coalesce(p_fixed, '{}'::jsonb), p_by) returning id into v_id;
  delete from data_health_runs where id in (select id from data_health_runs order by ran_at desc offset 30);
  return r || jsonb_build_object('id', v_id, 'fixed', coalesce(p_fixed, '{}'::jsonb));
end $$;

create or replace function app.job_data_health(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_fixed jsonb := app.data_health_autofix(p_now);
  r jsonb := app.data_health_store(p_now, v_fixed, null);
  v_issues integer := (r ->> 'issues')::integer;
  v_day text := to_char(app.local_date(p_now), 'YYYY-MM-DD');
  v_sent integer := 0;
begin
  -- one in-app notice a day to each Admin (not the verification's), only when something needs them; never an email
  if v_issues > 0 then
    insert into notifications (user_id, code, title, body, url, entity, dedupe_key)
    select u.id, 'staff_data_health', format('Data health: %s to look at', v_issues),
           (select string_agg(format('%s %s', c ->> 'count', lower(c ->> 'title')), ', ' order by (c ->> 'count')::integer desc)
              from jsonb_array_elements(r -> 'checks') c where (c ->> 'count')::integer > 0) || '.',
           '/admin#data-health', 'data_health', 'data_health:' || v_day || '|' || u.id
      from users u join user_roles ur on ur.user_id = u.id and ur.role = 'admin'
     where u.status = 'active' and not u.is_test
    on conflict (dedupe_key) do nothing;
    get diagnostics v_sent = row_count;
  end if;
  return jsonb_build_object('issues', v_issues, 'fixed', v_fixed, 'notices', v_sent);
end $$;

do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-data-health', '23 8 * * *', $q$select app.job_data_health()$q$);
  end if;
end $$;

-- ================================================================ 4. the door
create or replace function app.data_health_read(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  r data_health_runs;
begin
  perform app.assert_admin(p_by);
  select * into r from data_health_runs order by ran_at desc limit 1;
  if r.id is null then return jsonb_build_object('ran_at', null, 'issues', 0, 'checks', '[]'::jsonb, 'fixed', '{}'::jsonb); end if;
  return jsonb_build_object('id', r.id, 'ran_at', r.ran_at, 'issues', r.issues, 'checks', r.checks, 'fixed', r.fixed,
    -- what the auto-fix did over the last 7 days (the hourly hygiene's own runs are in job_runs)
    'fixed_week', coalesce((select jsonb_object_agg(k, s) from (select k, sum(v::integer) s from data_health_runs h, jsonb_each_text(h.fixed) f(k, v)
                                                                where h.ran_at > now() - interval '7 days' group by k) q), '{}'::jsonb));
end $$;

create or replace function app.data_health_fix(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_action text := p ->> 'action';
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  b bookings;
  n integer := 0;
begin
  perform app.assert_admin(p_by);
  if v_id is null then raise exception 'Choose the record to fix' using errcode = '22023'; end if;
  case v_action
  when 'close_task' then
    update tasks set status = 'cancelled', completed_at = now(), completed_by = p_by, wake_at = null,
           completion_note = coalesce(completion_note, 'Closed from Data health')
     where id = v_id and status in ('open', 'in_progress', 'waiting');
    get diagnostics n = row_count;
  when 'unassign_task' then
    update tasks set assigned_to = null, status = case when status = 'in_progress' then 'open' else status end
     where id = v_id and status in ('open', 'in_progress', 'waiting') and assigned_to is not null;
    get diagnostics n = row_count;
  when 'unassign_lead' then
    update leads set assigned_to = null where id = v_id and assigned_to is not null;
    get diagnostics n = row_count;
  when 'unassign_field_job' then
    update field_jobs set assigned_to = null, status = case when status = 'acknowledged' then 'scheduled' else status end, acknowledged_at = null
     where id = v_id and status in ('scheduled', 'acknowledged');
    get diagnostics n = row_count;
  when 'restart_followup' then
    update leads set followup_stopped_at = null, followup_stop_reason = null, followup_next_at = now()
     where id = v_id and kind in ('owner_program', 'owner_recruit') and email is not null and replied_at is null and do_not_contact_at is null
       and status in ('new', 'contacted', 'qualified');
    get diagnostics n = row_count;
  when 'mark_picked_up' then
    select * into b from bookings where id = v_id;
    if b.id is null or b.status::text <> 'confirmed' or b.handed_over_at is not null or b.pickup_at > now() then
      raise exception 'This booking is not waiting for its pickup to be recorded' using errcode = '23514';
    end if;
    perform app.handover_record_now(p_by, jsonb_build_object('booking', b.id, 'kind', 'pickup', 'at', b.pickup_at, 'reason', 'Pickup not recorded: recorded from Data health'));
    n := 1;
  when 'close_booking' then
    perform app.booking_close_ended(p_by, jsonb_build_object('booking', v_id, 'reason', 'Never closed: recorded from Data health'));
    n := 1;
  else
    raise exception 'Unknown fix %', v_action using errcode = '22023';
  end case;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'data_health_fix', 'data_health_runs', v_id::text, p);
  -- the card shows the result straight away: the record leaves the last run
  update data_health_runs h set checks = (
           select coalesce(jsonb_agg(case when exists (select 1 from jsonb_array_elements(c -> 'items') i where i ->> 'id' = v_id::text)
                                          then c || jsonb_build_object('count', greatest((c ->> 'count')::integer - 1, 0),
                                                                       'items', coalesce((select jsonb_agg(i) from jsonb_array_elements(c -> 'items') i where i ->> 'id' is distinct from v_id::text), '[]'::jsonb))
                                          else c end order by o), '[]'::jsonb)
             from jsonb_array_elements(h.checks) with ordinality e(c, o))
   where h.id = (select id from data_health_runs order by ran_at desc limit 1);
  update data_health_runs h set issues = (select coalesce(sum((c ->> 'count')::integer), 0) from jsonb_array_elements(h.checks) c)
   where h.id = (select id from data_health_runs order by ran_at desc limit 1);
  return jsonb_build_object('ok', true, 'changed', n);
end $$;

create or replace function app.data_health_run(p_by uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return app.data_health_store(now(), app.data_health_autofix(now()), p_by) - 'checks';
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0441;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'admin_read') and p_name = 'data_health' then
    perform app.door_begin(p_user, p_aal);
    return app.data_health_read(p_user);
  end if;
  if p_call in ('ops_do', 'admin_do') and p_name = 'data_health_fix' then
    perform app.door_begin(p_user, p_aal);
    return app.data_health_fix(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call in ('ops_do', 'admin_do') and p_name = 'data_health_run' then
    perform app.door_begin(p_user, p_aal);
    return app.data_health_run(p_user);
  end if;
  return app.door_pre0441(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0441(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('dh_check', 'dh_item', 'dh_resolved_tasks', 'dh_duplicate_tasks', 'dh_duplicate_tasks_extra', 'dh_gone',
              'dh_task_text', 'data_health', 'data_health_autofix', 'job_task_hygiene_pre0441', 'data_health_store', 'job_data_health', 'data_health_read',
              'data_health_fix', 'data_health_run', 'door_pre0441') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 5. now: the clear-cut fixes, once, and a first run
do $$
declare v jsonb;
begin
  v := app.data_health_autofix(now());
  raise notice 'data health auto-fix at migration time: %', v;
  perform app.data_health_store(now(), v, null);
end $$;
