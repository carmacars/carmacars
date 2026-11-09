-- 0970_r35z_roles_alerts.sql
-- Release 35, part Z (docs/changes/2026-11-08-r35-fleet-calls-alerts.md). SCHEMA_MARKER 0971 (0971 carries the guides).
-- The owner, November 8:
--   1. Fleet collects payments (pay links, the saved card, deposit holds, cash or e-Transfer recorded for Finance to
--      check; never refunds or voids) and takes and makes calls and texts on its own Fleet lane: calls and texts about
--      pickups, returns, deliveries and cars on rent go to Fleet first, with the caller pop-up. Customer service keeps
--      offers, cancellations and extras.
--   2. Customer phone numbers are hidden from Sales only: every read a Sales rep makes comes back with the numbers masked
--      ("(647) •••-••00"); calls and texts go through the platform buttons, which find the number on the server. An Admin
--      may reveal a masked number (audited). Search by phone still matches on the server.
--   3. The outbound Call button through Twilio: the server rings the staff member's own cell, then bridges the customer
--      with the CarmaCars number as caller ID; each call is logged on the person's history with its length and outcome;
--      reps' outbound minutes (app.sales_call_minutes) on the Sales home.
--   4. One staff alert per booking moment: "CC-10077 not back: due 5:00 pm, renter reminded, return check-in not started"
--      once per booking and return time (Call and Open), copies of renter messages are no alert of their own, a late
--      return job is folded into it; the renter's overdue chase waits late_chase_grace_minutes (15) and stops when staff
--      mark "returning now", the return job starts, or the tracker shows the car at the return place.
--   5. Quiet hours: phone alerts held by a staff member's quiet hours go as one summary when they end.
--   6. Hiring: no "Offer accepted ... set their function and first day" after one-step Hire; one alert per hire instead
--      ("<name> hired as <role>, starts <date>, training not started", to their academy progress). One-step Hire from any
--      stage, a referred candidate included (into the role chosen in the Hire form; no booking link).
-- No applied migration is edited: functions are wrapped (_pre0970) or patched in place (pg_temp.patch_fn).
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
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0970: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 0. settings and columns
alter table program_settings
  add column if not exists late_chase_grace_minutes integer not null default 15 check (late_chase_grace_minutes between 0 and 120),
  add column if not exists late_chase_at_place_km numeric(5, 2) not null default 0.30 check (late_chase_at_place_km between 0.05 and 5),
  add column if not exists alert_quiet_summary boolean not null default true;
comment on column program_settings.late_chase_grace_minutes is 'Late returns (0970): the renter''s overdue reminders wait these minutes after the return time (15). They stop when staff mark "returning now", the return job starts, or the tracker shows the car at the return place.';
comment on column program_settings.late_chase_at_place_km is 'Late returns (0970): the car''s tracker within this distance of our location counts as at the return place (0.3 km).';
comment on column program_settings.alert_quiet_summary is 'Staff alerts (0970): the phone alerts held by a person''s quiet hours go as one summary when the quiet hours end.';

alter table bookings
  add column if not exists returning_now_at timestamptz,
  add column if not exists returning_now_by uuid references users (id) on delete set null,
  add column if not exists returning_now_return_at timestamptz;
comment on column bookings.returning_now_at is 'Late return (0970): staff marked "returning now" (the renter is on the way back); the overdue reminders stop for this return time.';
do $$
declare c record;
begin
  select conname, pg_get_constraintdef(oid) d into c from pg_constraint
   where conrelid = 'booking_events'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%kind = ANY%';
  if c.conname is not null and c.d not like '%returning_now%' then
    execute format('alter table booking_events drop constraint %I', c.conname);
    execute format('alter table booking_events add constraint %I %s', c.conname, replace(c.d, '''verification''::text]', '''verification''::text, ''returning_now''::text]'));
  end if;
end $$;
comment on column bookings.returning_now_return_at is 'The return time the "returning now" mark was for: an extension that moves the return clears it in effect.';

alter table push_outbox add column if not exists quiet_hold boolean not null default false;
comment on column push_outbox.quiet_hold is 'Held by the person''s quiet hours (0970): when they end, several held alerts go as one summary.';

-- ================================================================ 1. Fleet: collect payments, the Fleet lane, the pop-up
create or replace function app.user_collects_money(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_runs_finance(p_by) or app.user_va_has(p_by, 'fleet')
$$;

-- the card on the renter's phone, a pay link, the reader: Fleet too
create or replace function app.card_collect_allowed(p_by uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'sales', 'finance', 'fleet') or app.user_is_field(p_by)
$$;

-- a payment received another way: Fleet records it within its single limit; Finance checks it (a To do, below)
alter function app.booking_payment_allowed(uuid, bigint) rename to booking_payment_allowed_pre0970;
create function app.booking_payment_allowed(p_by uuid, p_amount bigint) returns text
language sql stable security definer set search_path = public, app as $$
  select case
    when app.user_va_has(p_by, 'fleet') and not app.user_is_admin(p_by) and not app.user_va_has(p_by, 'finance') then
      case when p_amount > coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0)
           then format('%s is above your single limit of %s: an Admin records it', app.fmt_money(p_amount),
                       app.fmt_money(coalesce((select sp.single_limit_cents from staff_profiles sp where sp.user_id = p_by), 0))) end
    else app.booking_payment_allowed_pre0970(p_by, p_amount) end
$$;
select pg_temp.copy_grants('app.booking_payment_allowed(uuid, bigint)'::regprocedure, 'app.booking_payment_allowed_pre0970(uuid, bigint)'::regprocedure);

-- the saved card and the deposit hold on it: Finance, Fleet or an Admin (captures, releases, refunds and voids stay Finance)
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.prokind = 'f'
       and p.proname ~ '^(card_charge_(begin|finish)|deposit_hold_saved_[a-z]+)(_pre[0-9]+)?$'
       and pg_get_functiondef(p.oid) like '%app.user_runs_finance(p_by)%'
  loop
    execute replace(replace(pg_get_functiondef(f.sig), 'app.user_runs_finance(p_by)', 'app.user_collects_money(p_by)'),
                    'Finance or an Admin charges a saved card', 'Finance, Fleet or an Admin charges a saved card');
  end loop;
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.prokind = 'f' and pg_get_functiondef(p.oid) like '%''charge'', app.user_runs_finance(p_by)%'
  loop
    execute replace(pg_get_functiondef(f.sig), '''charge'', app.user_runs_finance(p_by)', '''charge'', app.user_collects_money(p_by)');
  end loop;
end $$;

-- a payment received another way on a booking: Fleet within its single limit; the list of them on the booking too
select pg_temp.patch_fn('app.record_manual_payment(uuid, jsonb)'::regprocedure,
  'v_refuse := app.manual_payment_allowed(p_by, v_amount);
    if v_refuse is not null then raise exception ''%'', v_refuse using errcode = ''42501''; end if;
    v_purpose',
  'v_refuse := case when app.user_va_has(p_by, ''fleet'') and not app.user_is_admin(p_by) and not app.user_va_has(p_by, ''finance'')
                     then app.booking_payment_allowed(p_by, v_amount) else app.manual_payment_allowed(p_by, v_amount) end;  -- 0970
    if v_refuse is not null then raise exception ''%'', v_refuse using errcode = ''42501''; end if;
    v_purpose');
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.prokind = 'f'
              and pg_get_functiondef(p.oid) like '%when ''manual_payments'' then
    if not app.user_runs_finance(p_user) then%' loop
    execute replace(pg_get_functiondef(f.sig), 'when ''manual_payments'' then
    if not app.user_runs_finance(p_user) then', 'when ''manual_payments'' then
    if not app.user_collects_money(p_user) then');
  end loop;
end $$;

-- cash or e-Transfer recorded by Fleet: a To do for Finance to check it
create or replace function app.fleet_payment_check() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare v_number text;
begin
  begin
    if new.target <> 'booking' or app.user_is_admin(new.recorded_by) or app.user_va_has(new.recorded_by, 'finance') or not app.user_va_has(new.recorded_by, 'fleet') then
      return null;
    end if;
    select b.booking_number into v_number from bookings b where b.id = new.booking_id;
    perform app.raise_task(p_type => 'fleet_payment_check', p_title => format('Check the payment Fleet recorded: %s by %s on %s', app.fmt_money(new.amount_cents),
                             replace(new.method, '_', '-'), coalesce(v_number, 'a booking')),
      p_detail => 'Fleet recorded a payment received another way. Match it with the bank or the cash count, or void it with the reason.',
      p_booking => new.booking_id, p_renter => new.renter_id, p_due_at => now() + interval '1 day', p_dedupe => 'fleet_payment_check:' || new.id, p_queue => 'finance');
  exception when others then
    raise warning 'fleet payment check not raised for %: %', new.id, sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists manual_payments_z_fleet_check on manual_payments;
create trigger manual_payments_z_fleet_check after insert on manual_payments for each row execute function app.fleet_payment_check();

-- the Fleet lane: a renter with a car on rent, a pickup, return, delivery or collection within a day
create or replace function app.phone_lane(p_renter uuid, p_booking uuid default null) returns text
language sql stable security definer set search_path = public, app as $$
  select case when exists (
    select 1 from bookings b
     where (b.renter_id = p_renter or b.id = p_booking) and b.booking_type <> 'owner'
       and (b.status = 'on_rent'
            or (b.status = 'confirmed' and b.pickup_at between now() - interval '12 hours' and now() + interval '24 hours')
            or (b.status in ('confirmed', 'returned') and b.return_at between now() - interval '12 hours' and now() + interval '24 hours')
            or exists (select 1 from field_jobs j where j.booking_id = b.id and j.status in ('scheduled', 'acknowledged', 'in_progress')
                          and j.scheduled_at between now() - interval '12 hours' and now() + interval '24 hours')))
  then 'fleet' else 'cs' end
$$;
comment on function app.phone_lane(uuid, uuid) is 'Phone (0970): fleet when the call or text is about a pickup, a return, a delivery or a car on rent (within a day); cs otherwise.';

create or replace function app.fleet_on_duty() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from users u join chat_staff_prefs cp on cp.user_id = u.id
                  where u.status = 'active' and cp.last_seen_at > now() - make_interval(mins => (app.settings()).chat_shift_minutes)
                    and app.user_va_has(u.id, 'fleet') and not app.staff_is_test(u.id))
$$;

create or replace function app.caller_popup_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs', 'fleet'))
$$;

-- the phone pages: Admins, customer service, Sales and Fleet
create or replace function app.assert_phone_staff(p_user uuid) returns void
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not (app.live_staff_ok(p_user) or app.user_va_has(p_user, 'fleet')) then
    raise exception 'Texts and calls are for Admins, customer service, Sales and Fleet' using errcode = '42501';
  end if;
end $$;
select pg_temp.patch_fn('app.phone_inbox(uuid, jsonb)'::regprocedure, 'perform app.assert_live_staff(p_by);', 'perform app.assert_phone_staff(p_by);');
select pg_temp.patch_fn('app.phone_thread(uuid, jsonb)'::regprocedure, 'perform app.assert_live_staff(p_by);', 'perform app.assert_phone_staff(p_by);');
select pg_temp.patch_fn('app.phone_timeline(uuid, jsonb)'::regprocedure, 'perform app.assert_live_staff(p_by);', 'perform app.assert_phone_staff(p_by);');
select pg_temp.patch_fn('app.phone_renter_search(uuid, jsonb)'::regprocedure, 'perform app.assert_live_staff(p_by);', 'perform app.assert_phone_staff(p_by);');
select pg_temp.patch_fn('app.phone_staff_do(uuid, text, jsonb)'::regprocedure, 'perform app.assert_live_staff(p_by);', 'perform app.assert_phone_staff(p_by);');

-- each conversation says its lane; Fleet's inbox opens on its lane, customer service's on its own
select pg_temp.patch_fn('app.phone_thread_row(phone_threads)'::regprocedure,
  '''opt_out_source'', t.opt_out_source, ''visitor_id'', t.visitor_id,',
  '''opt_out_source'', t.opt_out_source, ''visitor_id'', t.visitor_id, ''lane'', app.phone_lane(t.renter_id, t.booking_id),');
select pg_temp.patch_fn('app.phone_inbox(uuid, jsonb)'::regprocedure,
  'perform app.assert_phone_staff(p_by);',
  'perform app.assert_phone_staff(p_by);
  -- 0970: Fleet opens on its own lane (it may choose all)
  if nullif(p ->> ''view'', '''') is null and not app.user_is_admin(p_by) and app.va_active_fn(p_by) = ''fleet'' then v_view := ''fleet''; end if;');
select pg_temp.patch_fn('app.phone_inbox(uuid, jsonb)'::regprocedure,
  'and (v_view = ''all'' or (v_view = ''unknown'' and t.match_kind = ''unknown'') or (v_view = ''unread'' and t.unread > 0))',
  'and (v_view = ''all'' or (v_view = ''unknown'' and t.match_kind = ''unknown'') or (v_view = ''unread'' and t.unread > 0)
                or (v_view in (''fleet'', ''cs'') and app.phone_lane(t.renter_id, t.booking_id) = v_view))');

-- a missed call about a pickup, a return, a delivery or a car on rent: Fleet's call-back To do first
select pg_temp.patch_fn('app.phone_missed(uuid)'::regprocedure,
  'if ps.phone_missed_call_task and t.match_kind <> ''staff'' then',
  'if ps.phone_missed_call_task and t.match_kind <> ''staff'' then
    if v_queue <> ''admin'' and app.phone_lane(t.renter_id, t.booking_id) = ''fleet'' and app.phone_fn_held(''fleet'') then v_queue := ''fleet''; end if;  -- 0970');

-- The pop-up by lane: Admins see every call; Fleet the calls of its lane; customer service the rest, and a Fleet call
-- when no Fleet staff member is on duty or nobody answered it within 20 seconds.
create or replace function app.caller_live(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  v_cs boolean := app.user_va_has(p_by, 'cs');
  v_fleet boolean := app.user_va_has(p_by, 'fleet');
  v_duty boolean;
begin
  if not app.caller_popup_ok(p_by) then raise exception 'The caller pop-up is for Admins, customer service and Fleet' using errcode = '42501'; end if;
  if not (app.settings()).phone_enabled then return jsonb_build_object('at', now(), 'calls', '[]'::jsonb); end if;
  v_duty := app.fleet_on_duty();
  return jsonb_build_object('at', now(), 'calls', coalesce((
    select jsonb_agg(c.j order by c.started_at desc) from (
      select a.started_at, jsonb_build_object(
               'id', a.id, 'thread_id', t.id, 'number', t.number, 'display', app.phone_display(t.number), 'at', a.started_at,
               'answered_at', a.answered_at, 'ended_at', a.ended_at, 'missed', a.missed,
               'live', a.ended_at is null and not a.missed, 'lane', l.lane,
               'kind', t.match_kind, 'who', coalesce(t.name, app.phone_display(t.number)), 'lead_id', t.lead_id, 'owner_id', t.owner_id,
               'renter', case when t.renter_id is not null then app.caller_renter(t.renter_id) end) as j
        from phone_activity a join phone_threads t on t.id = a.thread_id
        cross join lateral (select app.phone_lane(coalesce(t.renter_id, a.renter_id), coalesce(a.booking_id, t.booking_id)) as lane) l
       where a.kind = 'call' and a.direction = 'in' and a.started_at > now() - interval '30 minutes'
         and ((a.ended_at is null and not a.missed) or coalesce(a.ended_at, a.updated_at) > now() - interval '3 minutes')
         and (v_admin or (l.lane = 'fleet' and (v_fleet or (v_cs and (not v_duty or (a.answered_at is null and a.started_at < now() - interval '20 seconds')))))
                      or (l.lane = 'cs' and v_cs))
       order by a.started_at desc limit 3) c), '[]'::jsonb));
end $$;
select pg_temp.patch_fn('app.caller_open(uuid, jsonb)'::regprocedure, 'The caller pop-up is for Admins and customer service', 'The caller pop-up is for Admins, customer service and Fleet');

-- ================================================================ 2. Sales: masked numbers
create table if not exists phone_masks (
  user_id  uuid not null references users (id) on delete cascade,
  number   text not null,
  display  text not null,
  seen_at  timestamptz not null default now(),
  primary key (user_id, number)
);
create index if not exists phone_masks_display_idx on phone_masks (user_id, display);
comment on table phone_masks is 'Sales masked numbers (0970): which masked number a Sales rep was shown, so the platform Call and Text buttons find the number on the server. Never read by a browser.';
alter table phone_masks enable row level security;
create policy admin_all on phone_masks for select to authenticated using (app.is_admin());
revoke all on phone_masks from anon, authenticated;
grant all on phone_masks to service_role;

create or replace function app.phone_mask_display(p text) returns text
language sql immutable as $$
  select case when n ~ '^\+1[0-9]{10}$' then '(' || substr(n, 3, 3) || ') ' || chr(8226) || chr(8226) || chr(8226) || '-' || chr(8226) || chr(8226) || right(n, 2)
              when n is not null then left(n, 3) || ' ' || repeat(chr(8226), 6) || right(n, 2) end
    from (select app.phone_e164(p) as n) x
$$;

-- Sales sees masked numbers (not an Admin, and working as Sales at this moment)
create or replace function app.viewer_masks_phones(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and not app.user_is_admin(p_user) and app.user_va_has(p_user, 'sales') and coalesce(app.va_active_fn(p_user), '') = 'sales'
$$;

create or replace function app.mask_phone_text(p_user uuid, s text, p_keep text) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  m text[];
  v_n text;
  v_d text;
  v_out text := s;
begin
  if s is null or s !~ '[0-9]{3}' then return s; end if;
  for m in select regexp_matches(s, '(^|[^0-9A-Za-z_-])((\+?1[ .-]?)?\(?[2-9][0-9]{2}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}|\+[2-9][0-9]{7,14})(?=[^0-9A-Za-z_-]|$)', 'g') loop
    v_n := app.phone_e164(m[2]);
    continue when v_n is null or v_n is not distinct from p_keep;
    v_d := app.phone_mask_display(v_n);
    -- "(647) 555-0199": the opening bracket was taken as the boundary before the number
    v_out := replace(v_out, case when m[1] = '(' then '(' || m[2] else m[2] end, v_d);
    insert into phone_masks as x (user_id, number, display) values (p_user, v_n, v_d)
    on conflict (user_id, number) do update set seen_at = now() where x.seen_at < now() - interval '1 hour';
  end loop;
  return v_out;
end $$;

create or replace function app.mask_phones_in(p_user uuid, j jsonb, p_keep text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb;
begin
  case jsonb_typeof(j)
    when 'object' then
      select coalesce(jsonb_object_agg(e.key, app.mask_phones_in(p_user, e.value, p_keep)), '{}'::jsonb) into v from jsonb_each(j) e;
      return v;
    when 'array' then
      select coalesce(jsonb_agg(app.mask_phones_in(p_user, e.x, p_keep) order by e.i), '[]'::jsonb) into v from jsonb_array_elements(j) with ordinality e(x, i);
      return v;
    when 'string' then
      if (j #>> '{}') !~ '[0-9]{3}' then return j; end if;
      return to_jsonb(app.mask_phone_text(p_user, j #>> '{}', p_keep));
    else return j;
  end case;
end $$;

-- the number behind a masked one the person was shown (the server's Call and Text, never the browser)
create or replace function app.phone_unmask_for(p_user uuid, p jsonb, p_any_user boolean default false) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_masked text := btrim(coalesce(p ->> 'masked', ''));
  v_name text := nullif(btrim(coalesce(p ->> 'name', '')), '');
  v_booking text := upper(nullif(btrim(coalesce(p ->> 'booking', p ->> 'booking_number', '')), ''));
  v_list text[];
  v_pick text;
begin
  select array_agg(distinct m.number) into v_list from phone_masks m
   where m.display = v_masked and m.seen_at > now() - interval '30 days' and (p_any_user or m.user_id = p_user);
  if coalesce(cardinality(v_list), 0) = 0 then raise exception 'Open the record again and press Call or Text there' using errcode = 'P0002'; end if;
  if cardinality(v_list) = 1 then return v_list[1]; end if;
  -- several people share the masked digits: the booking's renter, then the name
  select n into v_pick from unnest(v_list) n
   where (v_booking is not null and n = (select app.phone_e164(r.mobile) from bookings b join renters r on r.id = b.renter_id where b.booking_number = v_booking))
      or (v_name is not null and exists (select 1 from phone_threads t where t.number = n and lower(t.name) = lower(v_name)))
      or (v_name is not null and exists (select 1 from renters r where app.phone_e164(r.mobile) = n and lower(r.legal_name) = lower(v_name)))
      or (v_name is not null and exists (select 1 from leads l where app.phone_e164(l.phone) = n and lower(l.name) = lower(v_name)))
   limit 1;
  if v_pick is null then raise exception 'Open the record again and press Call or Text there' using errcode = 'P0002'; end if;
  return v_pick;
end $$;

create or replace function app.server_phone_unmask(p_user uuid, p jsonb) returns text
language sql stable security definer set search_path = public, app as $$ select app.phone_unmask_for(p_user, p, false) $$;

-- an Admin reveals a masked number (viewing as Sales, or from a Sales rep's screen): audited
create or replace function app.phone_reveal(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_n text;
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin reveals a hidden number' using errcode = '42501'; end if;
  v_n := app.phone_unmask_for(p_by, p, true);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'phone_reveal', 'phone_masks', left(v_n, 5) || '...' || right(v_n, 2),
          jsonb_build_object('masked', p ->> 'masked', 'booking', p ->> 'booking', 'reason', left(coalesce(p ->> 'reason', ''), 300)));
  return jsonb_build_object('ok', true, 'number', v_n, 'display', app.phone_display(v_n));
end $$;

-- a masked number is never saved over the real one (a form Sales saves carries what it was shown)
create or replace function app.keep_unmasked_phone() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  c text;
  v jsonb := to_jsonb(new);
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  fix jsonb := '{}'::jsonb;
begin
  foreach c in array tg_argv loop
    if coalesce(v ->> c, '') like '%' || chr(8226) || '%' then fix := fix || jsonb_build_object(c, o -> c); end if;
  end loop;
  if fix = '{}'::jsonb then return new; end if;
  return jsonb_populate_record(new, fix);
end $$;
do $$
declare t record;
begin
  for t in select * from (values ('renters', 'mobile'), ('leads', 'phone'), ('owners', 'phone'), ('drivers', 'mobile'), ('contact_captures', 'phone'),
                                 ('chat_conversations', 'phone'), ('chauffeur_requests', 'phone'), ('game_claims', 'phone'), ('job_applications', 'phone'),
                                 ('bookings', 'insurer_adjuster_phone'), ('insurer_adjusters', 'phone'), ('partners', 'phone'), ('referral_partners', 'phone')) x(tbl, col) loop
    if to_regclass('public.' || t.tbl) is not null then
      execute format('drop trigger if exists %I on %I', t.tbl || '_zkeep_phone', t.tbl);
      execute format('create trigger %I before insert or update of %I on %I for each row execute function app.keep_unmasked_phone(%L)', t.tbl || '_zkeep_phone', t.col, t.tbl, t.col);
    end if;
  end loop;
end $$;

-- Sales only (no Admin, customer service or Fleet function): their in-app alerts and phone alerts carry masked numbers
-- and no Call button with the number in it
create or replace function app.user_sales_only(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and app.user_va_has(p_user, 'sales') and not app.user_is_admin(p_user) and not app.user_va_has(p_user, 'cs', 'fleet')
$$;
create or replace function app.notification_mask_sales() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.user_id is not null and app.user_sales_only(new.user_id) then
    new.title := app.mask_phone_text(new.user_id, new.title, app.phone_our_number());
    new.body := app.mask_phone_text(new.user_id, new.body, app.phone_our_number());
  end if;
  return new;
end $$;
drop trigger if exists notifications_zmask_sales on notifications;
create trigger notifications_zmask_sales before insert on notifications for each row execute function app.notification_mask_sales();
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure,
  '-- focus mode: only urgent alerts reach the phone',
  'if v_staff and app.user_sales_only(new.user_id) then v_payload := v_payload - ''call''; end if;  -- 0970: no number for Sales
    -- focus mode: only urgent alerts reach the phone');

-- ================================================================ 3. outbound calls (Twilio)
create table if not exists outbound_calls (
  id               uuid primary key default gen_random_uuid(),
  staff_user_id    uuid not null references users (id) on delete cascade,
  to_number        text not null check (to_number ~ '^\+[1-9][0-9]{7,14}$'),
  staff_number     text not null,
  thread_id        uuid references phone_threads (id) on delete set null,
  renter_id        uuid references renters (id) on delete set null,
  owner_id         uuid references owners (id) on delete set null,
  lead_id          uuid references leads (id) on delete set null,
  booking_id       uuid references bookings (id) on delete set null,
  provider         text not null default 'twilio' check (provider in ('twilio')),
  call_sid         text unique,
  status           text not null default 'starting' check (status in ('starting', 'ringing_staff', 'connecting', 'completed', 'no_answer', 'busy', 'failed', 'canceled', 'staff_missed')),
  outcome          text,
  staff_seconds    integer check (staff_seconds >= 0),
  duration_seconds integer check (duration_seconds >= 0),
  activity_id      uuid,
  error            text,
  started_at       timestamptz not null default now(),
  answered_at      timestamptz,
  ended_at         timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists outbound_calls_staff_idx on outbound_calls (staff_user_id, started_at desc);
create trigger outbound_calls_updated before update on outbound_calls for each row execute function app.set_updated_at();
comment on table outbound_calls is 'Outbound calls from the site''s Call button (0970): Twilio rings the staff member''s own cell, then bridges the customer with the CarmaCars number as caller ID. Logged on the person''s history (phone_activity) with its length and outcome.';
alter table outbound_calls enable row level security;
create policy admin_all on outbound_calls for select to authenticated using (app.is_admin());
create trigger audit_outbound_calls after insert or update or delete on outbound_calls for each row execute function app.audit_row();
revoke all on outbound_calls from anon, authenticated;
grant select on outbound_calls to authenticated;
grant all on outbound_calls to service_role;

-- a call starts: the staff member and their cell, the customer and who they are
create or replace function app.server_twilio_call_start(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_to text := app.phone_e164(p ->> 'number');
  v_staff text;
  t phone_threads;
  v_booking uuid;
  c outbound_calls;
begin
  if v_user is null or not exists (select 1 from users u join user_roles r on r.user_id = u.id where u.id = v_user and u.status = 'active' and r.role::text in ('admin', 'va', 'field')) then
    raise exception 'Sign in as staff first' using errcode = '42501';
  end if;
  if v_to is null then raise exception 'That is not a number we can call' using errcode = '22023'; end if;
  select app.phone_e164(u.phone) into v_staff from users u where u.id = v_user;
  if v_staff is null then raise exception 'Add your own cell number to your profile first: the call rings it, then connects the customer' using errcode = '23514'; end if;
  if v_staff = v_to then raise exception 'That is your own number' using errcode = '22023'; end if;
  t := app.phone_thread_for(v_to);
  select b.id into v_booking from bookings b where b.booking_number = upper(btrim(coalesce(p ->> 'booking_number', '')));
  insert into outbound_calls (staff_user_id, to_number, staff_number, thread_id, renter_id, owner_id, lead_id, booking_id)
  values (v_user, v_to, v_staff, t.id, t.renter_id, t.owner_id, t.lead_id, coalesce(v_booking, t.booking_id))
  returning * into c;
  return jsonb_build_object('id', c.id, 'staff_number', v_staff, 'caller_id', app.phone_our_number(), 'who', coalesce(t.name, app.phone_mask_display(v_to)));
end $$;

-- what the voice webhook needs when the staff member answers: the customer's number and the caller ID
create or replace function app.server_twilio_call_get(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', c.id, 'to', c.to_number, 'caller_id', app.phone_our_number(), 'status', c.status)
    from outbound_calls c where c.id = p_id and c.created_at > now() - interval '2 hours'
$$;

-- Twilio's callbacks: the staff leg (CallStatus of the parent call) and the customer leg (the Dial's action)
create or replace function app.server_twilio_call_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c outbound_calls;
  v_kind text := coalesce(p ->> 'kind', '');
  v_status text := lower(coalesce(p ->> 'status', ''));
  v_secs integer := nullif(p ->> 'duration', '')::integer;
  v_new text;
  v_outcome text;
  a phone_activity;
begin
  select * into c from outbound_calls where id = nullif(p ->> 'id', '')::uuid for update;
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'unknown call'); end if;
  if nullif(p ->> 'call_sid', '') is not null and c.call_sid is null then update outbound_calls set call_sid = p ->> 'call_sid' where id = c.id; end if;
  if c.activity_id is not null then return jsonb_build_object('ok', true, 'done', true); end if;
  if v_kind = 'started' then
    update outbound_calls set status = 'ringing_staff', call_sid = coalesce(call_sid, nullif(p ->> 'call_sid', '')) where id = c.id;
    return jsonb_build_object('ok', true);
  elsif v_kind = 'failed_to_start' then
    v_new := 'failed'; v_outcome := 'not started: ' || left(coalesce(p ->> 'error', 'the phone service refused'), 200);
  elsif v_kind = 'staff_answered' then
    update outbound_calls set status = 'connecting', answered_at = coalesce(answered_at, now()) where id = c.id;
    return jsonb_build_object('ok', true);
  elsif v_kind = 'dial' then
    v_new := case v_status when 'completed' then 'completed' when 'answered' then 'completed' when 'busy' then 'busy' when 'no-answer' then 'no_answer'
                           when 'canceled' then 'canceled' else 'failed' end;
    v_outcome := case v_new when 'completed' then 'connected' when 'busy' then 'busy' when 'no_answer' then 'no answer' when 'canceled' then 'hung up before they answered' else 'did not connect' end;
  elsif v_kind = 'staff' then
    -- the staff leg ended: when the customer leg already reported, nothing more; else the staff member never answered
    if v_status not in ('completed', 'busy', 'no-answer', 'failed', 'canceled') then return jsonb_build_object('ok', true); end if;
    update outbound_calls set staff_seconds = v_secs where id = c.id;
    if c.status in ('completed', 'busy', 'no_answer', 'canceled', 'failed') then return jsonb_build_object('ok', true); end if;
    v_new := case when c.status = 'connecting' then 'failed' else 'staff_missed' end;
    v_outcome := case when c.status = 'connecting' then 'did not connect' else 'your phone was not answered' end;
    v_secs := 0;
  else
    return jsonb_build_object('ok', false, 'error', 'unknown event');
  end if;
  update outbound_calls set status = v_new, outcome = v_outcome, duration_seconds = coalesce(v_secs, 0), ended_at = now(), error = nullif(p ->> 'error', '')
   where id = c.id returning * into c;
  -- on the person's history: the conversation, the renter, the lead, the booking
  if c.thread_id is not null then
    insert into phone_activity (thread_id, kind, direction, status, body, started_at, answered_at, ended_at, duration_seconds, missed, renter_id, owner_id, lead_id, booking_id, sent_by)
    values (c.thread_id, 'call', 'out', v_outcome, 'Call from the site: ' || v_outcome || case when c.duration_seconds > 0 then format(', %s min %s s', c.duration_seconds / 60, c.duration_seconds % 60) else '' end,
            c.started_at, c.answered_at, c.ended_at, c.duration_seconds, false, c.renter_id, c.owner_id, c.lead_id, c.booking_id, c.staff_user_id)
    returning * into a;
    update outbound_calls set activity_id = a.id where id = c.id;
    update phone_threads set last_at = greatest(coalesce(last_at, '-infinity'::timestamptz), a.started_at), last_direction = 'out',
           last_preview = left('Call: ' || v_outcome, 120) where id = c.thread_id;
  end if;
  return jsonb_build_object('ok', true, 'status', c.status, 'outcome', v_outcome);
end $$;

-- a rep's outbound minutes (connected calls) in a period
create or replace function app.sales_call_minutes(p_user uuid, p_from timestamptz, p_to timestamptz) returns numeric
language sql stable security definer set search_path = public, app as $$
  select round(coalesce(sum(c.duration_seconds), 0) / 60.0, 1) from outbound_calls c
   where c.staff_user_id = p_user and c.status = 'completed' and c.started_at >= p_from and c.started_at < p_to
$$;

create or replace function app.my_call_minutes(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_user uuid := coalesce(case when app.user_is_admin(p_by) then nullif(p ->> 'user_id', '')::uuid end, p_by);
  v_day timestamptz := app.local_midnight(app.local_date(now()));
begin
  return jsonb_build_object('today', app.sales_call_minutes(v_user, v_day, now() + interval '1 minute'),
    'week', app.sales_call_minutes(v_user, v_day - make_interval(days => extract(isodow from now() at time zone 'America/Toronto')::integer - 1), now() + interval '1 minute'),
    'month', app.sales_call_minutes(v_user, app.local_midnight(date_trunc('month', app.local_date(now()))::date), now() + interval '1 minute'),
    'calls_month', (select count(*) from outbound_calls c where c.staff_user_id = v_user and c.started_at >= app.local_midnight(date_trunc('month', app.local_date(now()))::date)),
    'team', case when app.user_is_admin(p_by) then coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'name', u.full_name,
                     'month', app.sales_call_minutes(u.id, app.local_midnight(date_trunc('month', app.local_date(now()))::date), now() + interval '1 minute')) order by u.full_name)
                     from users u where exists (select 1 from outbound_calls c where c.staff_user_id = u.id and c.started_at > now() - interval '40 days')), '[]'::jsonb) end);
end $$;

-- ================================================================ 4. one staff alert per booking moment
-- who: the Admins, the person on the return job, every Fleet staff member
create or replace function app.staff_alert_users(p_rule text, p jsonb) returns table (user_id uuid, audience text)
language plpgsql stable security definer set search_path = public, app as $$
declare
  r staff_alert_rules;
  v_assigned uuid := nullif(p ->> 'assigned_to', '')::uuid;
  v_shift integer := (app.settings()).chat_shift_minutes;
begin
  select * into r from staff_alert_rules x where x.rule = p_rule;
  if r.rule is null then return; end if;
  return query
    select distinct on (c.uid) c.uid, c.aud
      from (
        select u.id uid, 'staff_admin'::text aud, 0 ord
          from users u where 'admin' = any (r.who) and u.status = 'active' and exists (select 1 from user_roles x where x.user_id = u.id and x.role::text = 'admin')
        union all
        select u.id, case when sp.staff_type = 'field' then 'staff_field' else 'staff_va_' || sp.va_function::text end, 1
          from users u join staff_profiles sp on sp.user_id = u.id and sp.is_active
         where 'assigned' = any (r.who) and u.id = v_assigned and u.status = 'active'
        union all
        select u.id, 'staff_va_' || sp.va_function::text, 2
          from users u join staff_profiles sp on sp.user_id = u.id and sp.staff_type = 'va' and sp.is_active
          join chat_staff_prefs cp on cp.user_id = u.id and cp.last_seen_at > now() - make_interval(mins => v_shift)
         where u.status = 'active'
           and exists (select 1 from unnest(r.who) w
                        where (w like 'on_duty:%' or (w like 'unassigned_on_duty:%' and v_assigned is null))
                          and split_part(w, ':', 2) in (sp.va_function::text, (select x::text from unnest(sp.cover_functions) x where x::text = split_part(w, ':', 2))))
        union all
        -- 0970: fn:<function>, everyone who holds the function
        select u.id, 'staff_va_' || split_part(w, ':', 2), 3
          from users u join staff_profiles sp on sp.user_id = u.id and sp.staff_type = 'va' and sp.is_active
          cross join unnest(r.who) w
         where u.status = 'active' and w like 'fn:%' and app.user_va_has(u.id, split_part(w, ':', 2))
      ) c
     where not app.staff_is_test(c.uid)
     order by c.uid, c.ord;
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('booking_not_back', 'Car not back (one alert per booking and return time)', 'Bookings', '{admin,assigned,fn:fleet}', 'urgent', 'alerts', true, false,
   'One alert per booking and return time: whether the renter was reminded and the return check-in state are in it, with Call and Open (0970).', 57)
on conflict (rule) do update set label = excluded.label, who = excluded.who, tier = excluded.tier, wired = true, hint = excluded.hint;
update staff_alert_rules set hint = 'Copies of renter messages about a booking show in the booking''s activity and as a line in the booking''s alert, not as an alert of their own (0970).'
 where rule like 'sent:renter\_%';
update staff_alert_rules set hint = 'Scheduled 15 minutes ago and not started. A late return job of a car that is not back is in the "not back" alert instead (0970).' where rule = 'job_late';

-- the buttons: Call and Open on the "not back" alert
select pg_temp.patch_fn('app.alert_actions(text, jsonb, text, boolean)'::regprocedure,
  '  if p_urgent then a := a || jsonb_build_object(''action'', ''snooze'', ''title'', ''Snooze 30 min''); end if;',
  '  if v_rule = ''booking_not_back'' then a := a || jsonb_build_object(''action'', ''open'', ''title'', ''Open'', ''url'', v_url); end if;
  if p_urgent then a := a || jsonb_build_object(''action'', ''snooze'', ''title'', ''Snooze 30 min''); end if;');

-- copies of renter messages about a booking: no alert of their own
select pg_temp.patch_fn('app.sa_outbox_mirror()'::regprocedure,
  'if not exists (select 1 from staff_alert_rules where rule = ''sent:'' || new.code)',
  'if new.audience = ''renter'' and new.booking_id is not null then return null; end if;  -- 0970
    if not exists (select 1 from staff_alert_rules where rule = ''sent:'' || new.code)');

-- a late return job of a car that is not back: the "not back" alert says it
create or replace function app.job_late_folded(p_kind text, p_booking uuid, p_now timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_kind in ('return_check_in', 'pickup_from_renter') and p_booking is not null and coalesce((app.settings()).notify_not_back, true)
     and exists (select 1 from bookings b where b.id = p_booking and b.status in ('on_rent', 'confirmed') and b.return_at <= p_now and app.booking_is_out(b, p_now))
$$;
select pg_temp.patch_fn('app.job_staff_alerts(timestamptz)'::regprocedure,
  'and j.scheduled_at < p_now - interval ''15 minutes'' and j.scheduled_at > p_now - interval ''1 day'' loop',
  'and j.scheduled_at < p_now - interval ''15 minutes'' and j.scheduled_at > p_now - interval ''1 day''
                and not app.job_late_folded(j.kind, j.booking_id, p_now) loop');

-- "CC-10077 not back: due 5:00 pm, renter reminded, return check-in not started": once per booking and return time
create or replace function app.not_back_alerts(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings(app.local_date(p_now));
  r record;
  u record;
  j record;
  v_n integer := 0;
  v_id bigint;
  v_epoch bigint;
  v_base text := rtrim(coalesce(s.notify_base_url, 'https://carmacars.ca'), '/');
  v_title text;
  v_who text;
  v_reminded boolean;
begin
  if not s.notify_not_back then return 0; end if;
  for r in select b.id, b.booking_number, b.return_at, app.vehicle_name(b.vehicle_id) as car, rn.legal_name, rn.mobile, rn.email
             from bookings b left join renters rn on rn.id = b.renter_id
            where b.status in ('on_rent', 'confirmed') and b.booking_type <> 'owner' and app.booking_is_out(b, p_now)
              and b.return_at <= p_now - make_interval(mins => s.notify_not_back_minutes) and b.return_at > p_now - interval '24 hours' loop
    continue when app.email_is_test(r.email);
    v_epoch := extract(epoch from r.return_at)::bigint;
    select x.id, x.kind, x.status, x.assigned_to into j from field_jobs x
     where x.booking_id = r.id and x.kind in ('return_check_in', 'pickup_from_renter') and x.status <> 'cancelled'
     order by x.scheduled_at desc limit 1;
    v_reminded := exists (select 1 from app_events e where e.entity = 'booking' and e.entity_id = r.id
                            and e.code in ('renter_return_due', 'renter_late_return_first', 'renter_late_return_final') and e.created_at >= r.return_at - interval '10 minutes');
    v_title := format('%s not back: due %s', r.booking_number, app.fmt_time(r.return_at))
      || case when v_reminded then ', renter reminded' else ', renter not reminded yet' end
      || case when j.id is null then ', no return check-in scheduled' when j.status in ('scheduled', 'acknowledged') then ', return check-in not started' else ', return check-in started' end;
    v_who := concat_ws(', ', nullif(btrim(coalesce(r.legal_name, '')), ''), case when nullif(btrim(coalesce(r.mobile, '')), '') is not null then 'call ' || r.mobile end);
    v_id := app.staff_alert('booking_not_back', 'booking', r.id, 'stage:' || v_epoch, v_title,
      concat_ws('. ', r.car, nullif(v_who, '')),
      jsonb_build_object('booking_id', r.id, 'path_admin', '/admin/bookings/' || r.booking_number, 'path_staff', '/staff/bookings/' || r.booking_number,
                         'assigned_to', j.assigned_to, 'job_kind', j.kind, 'call', nullif(regexp_replace(coalesce(r.mobile, ''), '[^0-9+]', '', 'g'), '')));
    continue when v_id is null;
    v_n := v_n + 1;
    -- by text too: the Admins, and the person on the return job with its link
    for u in select x.id from users x where x.status = 'active' and app.user_is_admin(x.id) and not app.staff_is_test(x.id) loop
      perform app.staff_text(u.id, format('CarmaCars: %s. %s. Booking: %s', v_title, coalesce(nullif(v_who, ''), 'No renter phone on file'), v_base || '/admin/bookings/' || r.booking_number),
                             r.id, 'not_back', 'not_back:' || r.id || ':' || v_epoch || ':' || u.id);
    end loop;
    if j.assigned_to is not null and not app.user_is_admin(j.assigned_to) then
      perform app.staff_text(j.assigned_to, format('CarmaCars: %s. %s. Job: %s', v_title, coalesce(nullif(v_who, ''), 'No renter phone on file'), app.ntf_link('field_job', jsonb_build_object('job_id', j.id))),
                             r.id, 'not_back', 'not_back:' || r.id || ':' || v_epoch || ':' || j.assigned_to);
    end if;
  end loop;
  return v_n;
end $$;

-- the old two notices (one per channel and class) give way to the one alert
select pg_temp.patch_fn('app.notify_booking_staff_pre0540(timestamptz)'::regprocedure,
  'if s.notify_not_back then', 'if s.notify_not_back and false then  -- 0970: app.not_back_alerts');
alter function app.notify_booking_staff(timestamptz) rename to notify_booking_staff_pre0970;
create function app.notify_booking_staff(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
begin
  return app.notify_booking_staff_pre0970(p_now) + app.not_back_alerts(p_now);
end $$;
select pg_temp.copy_grants('app.notify_booking_staff(timestamptz)'::regprocedure, 'app.notify_booking_staff_pre0970(timestamptz)'::regprocedure);

-- the renter's overdue chase: a grace, and it stops once the car is on its way or there
create or replace function app.renter_chase_paused(p_booking uuid, p_now timestamptz default now()) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  b bookings;
  v_lat numeric; v_lng numeric; v_at timestamptz;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null then return false; end if;
  if p_now < b.return_at + make_interval(mins => s.late_chase_grace_minutes) then return true; end if;
  if b.returning_now_at is not null and b.returning_now_return_at is not distinct from b.return_at then return true; end if;
  if exists (select 1 from field_jobs j where j.booking_id = b.id and j.kind in ('return_check_in', 'pickup_from_renter') and j.status in ('in_progress', 'done')) then return true; end if;
  if coalesce(b.return_location_kind, 'our_location') = 'our_location' and s.company_latitude is not null and s.company_longitude is not null then
    select ts.latitude, ts.longitude, ts.reported_at into v_lat, v_lng, v_at
      from tracker_devices td join tracker_status ts on ts.tracker_device_id = td.id
     where td.vehicle_id = b.vehicle_id and td.removed_at is null order by ts.reported_at desc limit 1;
    if v_at > p_now - interval '20 minutes' and v_lat is not null
       and app.distance_km(s.company_latitude, s.company_longitude, v_lat, v_lng) <= s.late_chase_at_place_km then return true; end if;
  end if;
  return false;
end $$;

select pg_temp.patch_fn('app.ntf_emit(text, text, uuid, text, jsonb)'::regprocedure,
  'begin
  if p_entity = ''booking'' and p_code = any (app.overdue_codes())',
  'begin
  -- 0970: the reminders job''s overdue chase waits the grace and stops once the car is on its way or there
  if p_entity = ''booking'' and p_code in (''renter_return_due'', ''renter_late_return_first'', ''renter_late_return_final'')
     and coalesce(current_setting(''app.chase_now'', true), '''') <> ''''
     and app.renter_chase_paused(p_id, current_setting(''app.chase_now'', true)::timestamptz) then
    return null;
  end if;
  if p_entity = ''booking'' and p_code = any (app.overdue_codes())');
-- Fleet's stage alerts before the "not back" alert are in it
select pg_temp.patch_fn('app.notify_reminders(timestamptz)'::regprocedure,
  'if p_now >= r.return_at + make_interval(mins => v_m) and v_m < s.late_admin_minutes then',
  'if p_now >= r.return_at + make_interval(mins => v_m) and v_m < s.late_admin_minutes and (v_m >= s.notify_not_back_minutes or not s.notify_not_back) then');
alter function app.notify_reminders(timestamptz) rename to notify_reminders_pre0970;
create function app.notify_reminders(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare v integer;
begin
  perform set_config('app.chase_now', p_now::text, true);
  v := app.notify_reminders_pre0970(p_now);
  perform set_config('app.chase_now', '', true);
  return v;
end $$;
select pg_temp.copy_grants('app.notify_reminders(timestamptz)'::regprocedure, 'app.notify_reminders_pre0970(timestamptz)'::regprocedure);

-- "Returning now" on the late panel
create or replace function app.late_returning_now(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet') or app.user_is_field(p_by)) then
    raise exception 'Admins, customer service, Fleet and field staff mark a car returning' using errcode = '42501';
  end if;
  select * into b from bookings where id::text = coalesce(p ->> 'booking', '') or booking_number = upper(btrim(coalesce(p ->> 'booking', ''))) for update;
  if b.id is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
  if b.status not in ('on_rent', 'confirmed') then raise exception 'The car of % is not out', b.booking_number using errcode = '23514'; end if;
  update bookings set returning_now_at = now(), returning_now_by = p_by, returning_now_return_at = b.return_at where id = b.id;
  insert into booking_events (booking_id, kind, note, actor_type, actor_user_id)
  values (b.id, 'returning_now', 'Returning now: the renter is on the way back (the overdue reminders stop)', 'staff', p_by);
  return jsonb_build_object('ok', true, 'message', 'Marked returning now: the renter gets no more overdue reminders for this return time.');
end $$;

-- ================================================================ 5. quiet hours: one summary when they end
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure,
  'insert into push_outbox (subscription_id, user_id, notification_id, code, title, body, url, urgent, send_after, actions)',
  'insert into push_outbox (subscription_id, user_id, notification_id, code, title, body, url, urgent, send_after, actions, quiet_hold)');
select pg_temp.patch_fn('app.push_from_notice()'::regprocedure,
  'case when v_staff then app.alert_actions(new.code, v_payload, app.push_path(new.url), v_urgent) end',
  'case when v_staff then app.alert_actions(new.code, v_payload, app.push_path(new.url), v_urgent) end, (v_staff and not v_urgent and v_after > now() + interval ''1 minute'')');

-- the words of the summary: grouped by the alert's group, newest first in each
create or replace function app.push_quiet_summary(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  g record;
  v_n integer := 0;
  v_body text;
  v_admin boolean;
begin
  if not coalesce((app.settings()).alert_quiet_summary, true) then return 0; end if;
  for g in select o.subscription_id, o.user_id, count(*) n, array_agg(o.id) ids
             from push_outbox o where o.status = 'queued' and o.quiet_hold and o.send_after <= p_now
            group by o.subscription_id, o.user_id having count(*) >= 2 loop
    select string_agg(x.line, E'\n' order by x.newest desc) into v_body from (
      select coalesce(r.grp, 'Other') || ' (' || count(*) || '): ' || string_agg(o.title, '; ' order by o.created_at desc) as line, max(o.created_at) newest
        from push_outbox o left join notifications n on n.id = o.notification_id left join app_events e on e.id = n.event_id
        left join staff_alert_rules r on r.rule = e.payload ->> 'rule'
       where o.id = any (g.ids) group by coalesce(r.grp, 'Other')) x;
    v_admin := app.user_is_admin(g.user_id);
    insert into push_outbox (subscription_id, user_id, notification_id, code, title, body, url, urgent, send_after)
    values (g.subscription_id, g.user_id, null, 'staff_quiet_summary', format('While your alerts were quiet: %s alerts', g.n), left(v_body, 240),
            case when v_admin then '/admin/alerts' else '/staff/alerts' end, false, p_now);
    update push_outbox set status = 'skipped', last_error = 'in the quiet hours summary', locked_at = null where id = any (g.ids);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

alter function app.server_push_due(integer, text[]) rename to server_push_due_pre0970;
create function app.server_push_due(p_limit integer default 50, p_kinds text[] default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  -- what was read meanwhile is skipped first (the old function does it again; no harm), then the summaries are made
  update push_outbox o set status = 'skipped', last_error = 'read before it was sent'
    from notifications n where n.id = o.notification_id and o.status = 'queued' and n.read_at is not null;
  perform app.push_quiet_summary(now());
  return app.server_push_due_pre0970(p_limit, p_kinds);
end $$;
select pg_temp.copy_grants('app.server_push_due(integer, text[])'::regprocedure, 'app.server_push_due_pre0970(integer, text[])'::regprocedure);

-- ================================================================ 6. hiring: one alert per hire, Hire from any stage
create or replace function app.sa_applicant_hired() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.email_is_test(new.email) then return null; end if;
    -- one-step Hire already set the function and the first day: its own alert follows (staff_onboarding)
    if exists (select 1 from staff_profiles sp where sp.user_id = new.hired_user_id and sp.started_on is not null) then return null; end if;
    perform app.staff_alert('applicant_hired', 'hiring_alert', new.id, 'hired', 'Offer accepted: ' || coalesce(new.full_name, 'an applicant'),
      'Their staff account is ready. Set their function and first day.', jsonb_build_object('path_admin', '/admin/hiring/' || new.id));
  exception when others then
    raise warning 'hired alert not made: %', sqlerrm;
  end;
  return null;
end $$;

create or replace function app.sa_hire_onboarded() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare a job_applications;
begin
  begin
    select * into a from job_applications where id = new.application_id;
    if a.id is null or app.email_is_test(a.email) then return null; end if;
    perform app.staff_alert('applicant_hired', 'hiring_alert', a.id, 'onboarded',
      format('%s hired as %s, starts %s, training not started', coalesce(a.full_name, 'The hire'), coalesce(app.hire_path_of(new.path) ->> 'label', new.path),
             to_char(new.start_on, 'FMDy Mon FMDD')),
      'Open their academy progress to follow the training.', jsonb_build_object('path_admin', '/admin/academy/staff/' || new.user_id));
  exception when others then
    raise warning 'onboarded alert not made: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists staff_onboarding_z_staff_alert on staff_onboarding;
create trigger staff_onboarding_z_staff_alert after insert on staff_onboarding for each row execute function app.sa_hire_onboarded();
update staff_alert_rules set label = 'Hired (one alert per hire: role, start date, training)', hint = 'After one-step Hire: "<name> hired as <role>, starts <date>, training not started", to their academy progress (0970).'
 where rule = 'applicant_hired';

-- Hire from any stage (a referred candidate too), into the role chosen in the Hire form
select pg_temp.patch_fn('app.hiring_hire(uuid, jsonb)'::regprocedure,
  'if a.status not in (''interviewed'', ''booked'', ''invited'', ''below_bar'') then',
  'if a.status = ''hired'' then');
select pg_temp.patch_fn('app.hiring_hire(uuid, jsonb)'::regprocedure,
  'ur.role::text = r.staff_kind)',
  'ur.role::text = coalesce(nullif(current_setting(''app.hire_kind'', true), ''''), r.staff_kind))');
select pg_temp.patch_fn('app.hire_onboard(uuid, jsonb)'::regprocedure,
  'perform set_config(''app.hiring_decide'', ''on'', true);',
  'perform set_config(''app.hiring_decide'', ''on'', true);
  perform set_config(''app.hire_kind'', m ->> ''staff_kind'', true);');
select pg_temp.patch_fn('app.hire_onboard(uuid, jsonb)'::regprocedure,
  'perform set_config(''app.hiring_decide'', '''', true);',
  'perform set_config(''app.hiring_decide'', '''', true);
  perform set_config(''app.hire_kind'', '''', true);');
select pg_temp.patch_fn('app.hire_preview(uuid, jsonb)'::regprocedure,
  '''can_hire'', a.purged_at is null and a.email is not null and a.status in (''interviewed'', ''booked'', ''invited'', ''below_bar''),',
  '''can_hire'', a.purged_at is null and a.email is not null and a.status <> ''hired'',');

-- ================================================================ 7. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0970;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb;
begin
  if (p_call in ('admin_do', 'va_do', 'ops_do', 'field_do') and p_name in ('late_returning_now', 'phone_reveal'))
     or (p_call in ('admin_read', 'va_read', 'ops_read') and p_name = 'my_call_minutes') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'late_returning_now' then app.late_returning_now(p_user, p)
      when 'phone_reveal' then app.phone_reveal(p_user, p)
      else app.my_call_minutes(p_user, p) end;
  end if;
  v := app.door_pre0970(p_user, p_aal, p_call, p_name, p);
  -- Sales sees customer numbers masked (0970)
  if p_call in ('va_read', 'va_list', 'ops_read') and app.viewer_masks_phones(p_user) then
    return app.mask_phones_in(p_user, v, app.phone_our_number());
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0970(uuid, text, text, text, jsonb)'::regprocedure);

-- the server's calls (the Worker, as service_role)
create or replace function public.server_phone_unmask(p_user uuid, p jsonb) returns text
language sql stable security definer set search_path = public, app as $$ select app.server_phone_unmask(p_user, p) $$;
create or replace function public.server_twilio_call_start(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_twilio_call_start(p) $$;
create or replace function public.server_twilio_call_get(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.server_twilio_call_get(p_id) $$;
create or replace function public.server_twilio_call_event(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_twilio_call_event(p) $$;
revoke all on function public.server_phone_unmask(uuid, jsonb), public.server_twilio_call_start(jsonb), public.server_twilio_call_get(uuid),
                       public.server_twilio_call_event(jsonb) from public, anon, authenticated;
grant execute on function public.server_phone_unmask(uuid, jsonb), public.server_twilio_call_start(jsonb), public.server_twilio_call_get(uuid),
                          public.server_twilio_call_event(jsonb) to service_role;

-- ================================================================ 8. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['user_collects_money', 'booking_payment_allowed_pre0970', 'fleet_payment_check', 'phone_lane', 'fleet_on_duty',
             'assert_phone_staff', 'phone_mask_display', 'user_sales_only', 'notification_mask_sales', 'keep_unmasked_phone', 'viewer_masks_phones', 'mask_phone_text', 'mask_phones_in', 'phone_unmask_for', 'server_phone_unmask', 'phone_reveal',
             'server_twilio_call_start', 'server_twilio_call_get', 'server_twilio_call_event', 'sales_call_minutes', 'my_call_minutes', 'job_late_folded', 'not_back_alerts',
             'notify_booking_staff_pre0970', 'renter_chase_paused', 'notify_reminders_pre0970', 'late_returning_now', 'push_quiet_summary', 'server_push_due_pre0970',
             'sa_hire_onboarded', 'door_pre0970'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
