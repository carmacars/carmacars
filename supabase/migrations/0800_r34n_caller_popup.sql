-- 0800_r34n_caller_popup.sql
-- Release 34, part N (docs/changes/2026-11-08-r34-caller-popup.md). SCHEMA_MARKER 0802. The owner, November 8: "when
-- customers call, customer service should get a popup for whos on the phone on their portal so they can see everything
-- live and they should also be able to keep notes to update on each situation with each renter."
--   1. Who is calling. A call to the CarmaCars Quo number already reaches the database by webhook (0085,
--      app.server_phone_event) and its number is matched to a renter on the normalised E.164 number (app.phone_match).
--      The new read caller_live gives every Admin and every customer service staff member the incoming calls ringing or
--      in progress now (and those that ended in the last 3 minutes), each with who it is: for a renter, the active or next
--      booking, the balance owed, the deposit, open requests and the last notes; an unknown number with Create lead (0085's
--      phone_create_lead). The portals ask for it every 10 seconds while in use (web/src/lib/poll, once a minute when idle,
--      never in a hidden tab), as the Live chat inbox does: no new vendor.
--   2. Renter notes. renter_notes: timestamped, with the author's name and role, optionally the booking and the call it is
--      about. Admins and office staff (customer service, Sales, Fleet, Finance) who may see the renter (app.va_sees_renter,
--      or a call from the renter in the last hour) read and add them; staff never change or remove one; an Admin removes
--      one with a reason (kept, marked removed, never shown again). Every row change is in the audit log (app.audit_row).
--   3. Open from the pop-up. A staff member outside the renter's window opens the record from the pop-up of a call from
--      that renter: logged in data_access_log ("Incoming call", 24 hours), as Open with a reason does.
-- No applied migration is edited; the door is wrapped (door_pre0800).
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

-- ================================================================ 1. renter notes
create table if not exists renter_notes (
  id              uuid primary key default gen_random_uuid(),
  renter_id       uuid not null references renters (id) on delete cascade,
  body            text not null check (length(btrim(body)) between 1 and 4000),
  author_user_id  uuid references users (id) on delete set null,
  author_name     text not null,
  author_role     text not null check (author_role in ('admin', 'cs', 'sales', 'fleet', 'finance')),
  booking_id      uuid references bookings (id) on delete set null,
  call_id         uuid references phone_activity (id) on delete set null,
  created_at      timestamptz not null default now(),
  removed_at      timestamptz,
  removed_by      uuid references users (id) on delete set null,
  removed_reason  text,
  check (removed_at is null or removed_reason is not null)
);
create index if not exists renter_notes_renter_idx on renter_notes (renter_id, created_at desc);
comment on table renter_notes is 'Renter notes (0800): what staff noted about a renter, newest first. Added by Admins and office staff, never changed; an Admin removes one with a reason (kept, marked removed). Audited.';

-- a note is never edited; the only change is its removal, once
create or replace function app.renter_note_guard() returns trigger
language plpgsql as $$
begin
  if new.body is distinct from old.body or new.renter_id is distinct from old.renter_id or new.author_user_id is distinct from old.author_user_id and new.author_user_id is not null
     or new.author_name is distinct from old.author_name or new.author_role is distinct from old.author_role or new.created_at is distinct from old.created_at
     or new.booking_id is distinct from old.booking_id and new.booking_id is not null
     or new.call_id is distinct from old.call_id and new.call_id is not null then
    raise exception 'A note cannot be changed. Add a new note instead.' using errcode = '42501';
  end if;
  if old.removed_at is not null and (new.removed_at is distinct from old.removed_at or new.removed_reason is distinct from old.removed_reason) then
    raise exception 'This note was already removed' using errcode = '42501';
  end if;
  return new;
end $$;
drop trigger if exists renter_notes_guard on renter_notes;
create trigger renter_notes_guard before update on renter_notes for each row execute function app.renter_note_guard();
drop trigger if exists audit_renter_notes on renter_notes;
create trigger audit_renter_notes after insert or update or delete on renter_notes for each row execute function app.audit_row();

alter table renter_notes enable row level security;
drop policy if exists admin_all on renter_notes;
create policy admin_all on renter_notes for select to authenticated using (app.is_admin());
revoke all on renter_notes from anon, authenticated;

-- ================================================================ 2. who may
-- The pop-up: Admins and customer service.
create or replace function app.caller_popup_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (app.user_is_admin(p_user) or app.user_va_has(p_user, 'cs'))
$$;

-- A call from the renter's number in the last hour (the pop-up's own reason to show the renter).
create or replace function app.renter_called_recently(p_renter uuid, p_minutes integer default 60) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from phone_activity a join phone_threads t on t.id = a.thread_id
                  where a.kind = 'call' and a.direction = 'in' and a.started_at > now() - make_interval(mins => p_minutes)
                    and (t.renter_id = p_renter or a.renter_id = p_renter))
$$;

-- Notes: Admins; office staff who may see the renter (their window, a logged opening, or a call from them in the last hour).
create or replace function app.renter_notes_ok(p_user uuid, p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and p_renter is not null and (
    app.user_is_admin(p_user)
    or (app.user_va_has(p_user, 'cs', 'sales', 'fleet', 'finance')
        and (app.va_sees_renter(p_renter) or (app.user_va_has(p_user, 'cs') and app.renter_called_recently(p_renter)))))
$$;

create or replace function app.renter_note_role(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when app.user_is_admin(p_user) then 'admin'
              else coalesce((select f from staff_profiles sp, unnest(sp.functions) f
                              where sp.user_id = p_user and sp.is_active and f in ('cs', 'sales', 'fleet', 'finance')
                              order by (f = nullif(current_setting('app.va_active', true), '')) desc, array_position(array['cs', 'sales', 'fleet', 'finance'], f) limit 1), 'cs') end
$$;

create or replace function app.renter_note_json(n renter_notes) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', n.id, 'body', n.body, 'at', n.created_at, 'author', n.author_name, 'role', n.author_role,
    'booking_number', (select b.booking_number from bookings b where b.id = n.booking_id), 'from_call', n.call_id is not null)
$$;

create or replace function app.renter_notes_list(p_renter uuid, p_limit integer default 50) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(app.renter_note_json(n) order by n.created_at desc, n.id), '[]'::jsonb)
    from (select * from renter_notes where renter_id = p_renter and removed_at is null order by created_at desc, id limit greatest(1, least(p_limit, 200))) n
$$;

-- ================================================================ 3. the renter on the pop-up
-- The booking a call is about: on rent (or confirmed with its pickup passed), else the next one coming.
create or replace function app.caller_booking(p_renter uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select b.id from bookings b
   where b.renter_id = p_renter and not coalesce(b.is_placeholder, false)
     and (b.status::text = 'on_rent' or (b.status::text in ('confirmed', 'pending_payment', 'offered', 'requested') and b.return_at > now()))
   order by case when b.status::text = 'on_rent' or (b.status::text = 'confirmed' and b.pickup_at <= now()) then 0 else 1 end, b.pickup_at
   limit 1
$$;

-- What the renter owes now: the rental payments due or open on their confirmed, out and returned bookings, and charges
-- after a rental (tolls, damage, fuel) not paid. A booking whose plan cannot be read is left out, never the whole card.
create or replace function app.caller_balance(p_renter uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b record;
  s jsonb;
  v_open bigint := 0;
  v_after bigint := 0;
  v_overdue boolean := false;
begin
  for b in select x.id, x.status::text as status from bookings x
            where x.renter_id = p_renter and not coalesce(x.is_placeholder, false) and x.status::text in ('confirmed', 'on_rent', 'returned', 'closed') loop
    begin
      if b.status in ('confirmed', 'on_rent', 'returned') then
        s := app.booking_pay_schedule(b.id, now());
        if (s ->> 'state') not in ('none') then
          v_open := v_open + coalesce((s ->> 'open_cents')::bigint, 0);
          v_overdue := v_overdue or s ->> 'state' = 'overdue';
        end if;
      end if;
      if b.status in ('returned', 'closed') then v_after := v_after + coalesce(app.booking_balance_open(b.id), 0); end if;
    exception when others then null;
    end;
  end loop;
  return jsonb_build_object('owed_cents', v_open + v_after, 'rental_cents', v_open, 'charges_cents', v_after, 'overdue', v_overdue);
end $$;

-- The deposit of the booking: held (and how), waived, not taken yet, released, or none needed.
create or replace function app.caller_deposit(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when b.id is null then null else jsonb_build_object(
    'required_cents', coalesce(b.deposit_cents, 0),
    'held_cents', coalesce(d.amount_cents - d.applied_cents - d.released_cents, 0),
    'how', d.method,
    'state', case when d.status in ('held', 'captured') then 'held'
                  when b.deposit_waived_at is not null then 'waived'
                  when d.status in ('settled', 'carried_forward') then 'released'
                  when d.status = 'failed' then 'failed'
                  when coalesce(b.deposit_cents, 0) = 0 then 'none'
                  else 'not_taken' end) end
    from (select 1) one
    left join bookings b on b.id = p_booking
    left join lateral (select * from deposits x where x.booking_id = b.id order by x.created_at desc limit 1) d on true
$$;

-- What the renter is waiting on: booking requests and offers, change requests, questions staff asked, open tasks.
create or replace function app.caller_requests(p_renter uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x.j order by x.at desc), '[]'::jsonb) from (
    select * from (
      select jsonb_build_object('kind', 'booking', 'label', case when b.status::text = 'offered' then 'Offer sent, waiting for the renter' else 'Booking request' end,
               'booking_number', b.booking_number, 'at', b.created_at) as j, b.created_at as at
        from bookings b where b.renter_id = p_renter and b.status::text in ('requested', 'offered') and b.return_at > now()
      union all
      select jsonb_build_object('kind', 'change', 'label', case c.status when 'requested' then 'Change asked' when 'proposed' then 'Change proposed, waiting for the renter' else 'Change approved, waiting for payment' end,
               'booking_number', b.booking_number, 'at', c.created_at), c.created_at
        from booking_change_requests c join bookings b on b.id = c.booking_id where b.renter_id = p_renter and c.status in ('requested', 'proposed', 'approved')
      union all
      select jsonb_build_object('kind', 'question', 'label', 'Question to the renter, not answered', 'booking_number', b.booking_number, 'at', q.asked_at), q.asked_at
        from booking_info_requests q join bookings b on b.id = q.booking_id where b.renter_id = p_renter and q.status = 'open'
      union all
      select jsonb_build_object('kind', 'task', 'label', t.title, 'booking_number', (select b.booking_number from bookings b where b.id = t.booking_id), 'at', t.created_at), t.created_at
        from tasks t where t.renter_id = p_renter and t.status in ('open', 'in_progress', 'waiting')
    ) y order by y.at desc limit 6) x
$$;

create or replace function app.caller_renter(p_renter uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', r.id, 'name', r.legal_name, 'identity_status', r.identity_status, 'is_blocked', r.is_blocked,
    'booking', (select jsonb_build_object('number', b.booking_number, 'status', b.status, 'car', app.vehicle_name(b.vehicle_id),
                  'pickup_at', b.pickup_at, 'return_at', b.return_at,
                  'active', b.status::text = 'on_rent' or (b.status::text = 'confirmed' and b.pickup_at <= now()))
                  from bookings b where b.id = x.bid),
    'balance', app.caller_balance(r.id),
    'deposit', app.caller_deposit(x.bid),
    'requests', app.caller_requests(r.id),
    'notes', app.renter_notes_list(r.id, 3),
    'notes_count', (select count(*) from renter_notes n where n.renter_id = r.id and n.removed_at is null))
    from renters r cross join lateral (select app.caller_booking(r.id) as bid) x
   where r.id = p_renter
$$;

create index if not exists phone_activity_live_calls_idx on phone_activity (started_at desc) where kind = 'call' and direction = 'in';

-- The calls on the pop-up: ringing or in progress now (a call Quo never closed drops after 30 minutes), and those that
-- ended or were missed in the last 3 minutes, so the person who answered can still write the note. Newest first, at most 3.
create or replace function app.caller_live(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.caller_popup_ok(p_by) then raise exception 'The caller pop-up is for Admins and customer service' using errcode = '42501'; end if;
  if not (app.settings()).phone_enabled then return jsonb_build_object('at', now(), 'calls', '[]'::jsonb); end if;
  return jsonb_build_object('at', now(), 'calls', coalesce((
    select jsonb_agg(c.j order by c.started_at desc) from (
      select a.started_at, jsonb_build_object(
               'id', a.id, 'thread_id', t.id, 'number', t.number, 'display', app.phone_display(t.number), 'at', a.started_at,
               'answered_at', a.answered_at, 'ended_at', a.ended_at, 'missed', a.missed,
               'live', a.ended_at is null and not a.missed,
               'kind', t.match_kind, 'who', coalesce(t.name, app.phone_display(t.number)), 'lead_id', t.lead_id, 'owner_id', t.owner_id,
               'renter', case when t.renter_id is not null then app.caller_renter(t.renter_id) end) as j
        from phone_activity a join phone_threads t on t.id = a.thread_id
       where a.kind = 'call' and a.direction = 'in' and a.started_at > now() - interval '30 minutes'
         and ((a.ended_at is null and not a.missed) or coalesce(a.ended_at, a.updated_at) > now() - interval '3 minutes')
       order by a.started_at desc limit 3) c), '[]'::jsonb));
end $$;

-- ================================================================ 4. reads and actions
create or replace function app.renter_notes_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_renter uuid := nullif(coalesce(p ->> 'renter_id', p ->> 'renter', ''), '')::uuid;
begin
  if not app.renter_notes_ok(p_by, v_renter) then raise exception 'Open this renter''s record first' using errcode = '42501'; end if;
  return jsonb_build_object('renter_id', v_renter, 'notes', app.renter_notes_list(v_renter, 200), 'can_remove', app.user_is_admin(p_by));
end $$;

create or replace function app.renter_note_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_renter uuid := nullif(coalesce(p ->> 'renter_id', p ->> 'renter', ''), '')::uuid;
  v_body text := btrim(coalesce(p ->> 'body', ''));
  v_call uuid := nullif(p ->> 'call_id', '')::uuid;
  v_booking uuid;
  n renter_notes;
begin
  if not app.renter_notes_ok(p_by, v_renter) then raise exception 'Open this renter''s record first' using errcode = '42501'; end if;
  if v_body = '' then raise exception 'Write the note' using errcode = '22023'; end if;
  if length(v_body) > 4000 then raise exception 'Keep a note under 4,000 characters' using errcode = '22023'; end if;
  -- the call must be one of the renter's
  if v_call is not null and not exists (select 1 from phone_activity a join phone_threads t on t.id = a.thread_id
                                         where a.id = v_call and (t.renter_id = v_renter or a.renter_id = v_renter)) then v_call := null; end if;
  select b.id into v_booking from bookings b where b.renter_id = v_renter
     and (b.booking_number = upper(btrim(coalesce(p ->> 'booking_number', ''))) or b.id::text = coalesce(p ->> 'booking_id', '')) limit 1;
  if v_booking is null and v_call is not null then v_booking := app.caller_booking(v_renter); end if;
  insert into renter_notes (renter_id, body, author_user_id, author_name, author_role, booking_id, call_id)
  values (v_renter, v_body, p_by, coalesce((select nullif(btrim(u.full_name), '') from users u where u.id = p_by), 'Staff'), app.renter_note_role(p_by), v_booking, v_call)
  returning * into n;
  return jsonb_build_object('ok', true, 'note', app.renter_note_json(n));
end $$;

create or replace function app.renter_note_remove(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  n renter_notes;
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin can remove a note' using errcode = '42501'; end if;
  if length(v_reason) < 3 then raise exception 'Give the reason for removing this note' using errcode = '22023'; end if;
  select * into n from renter_notes where id = nullif(p ->> 'id', '')::uuid for update;
  if n.id is null then raise exception 'That note is no longer kept' using errcode = 'P0002'; end if;
  if n.removed_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  update renter_notes set removed_at = now(), removed_by = p_by, removed_reason = left(v_reason, 500) where id = n.id;
  return jsonb_build_object('ok', true);
end $$;

-- Open the renter from the pop-up of their call: a logged opening for 24 hours ("Incoming call"), as Open with a reason.
create or replace function app.caller_open(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_renter uuid;
  v_call uuid := nullif(p ->> 'call_id', '')::uuid;
begin
  if not app.caller_popup_ok(p_by) then raise exception 'The caller pop-up is for Admins and customer service' using errcode = '42501'; end if;
  select coalesce(t.renter_id, a.renter_id) into v_renter from phone_activity a join phone_threads t on t.id = a.thread_id
   where a.id = v_call and a.kind = 'call' and a.direction = 'in' and a.started_at > now() - interval '60 minutes';
  if v_renter is null then raise exception 'That call is not one from a renter in the last hour' using errcode = '42501'; end if;
  if app.user_is_admin(p_by) then return jsonb_build_object('ok', true, 'renter_id', v_renter); end if;
  if not app.va_sees_renter(v_renter) then
    insert into data_access_log (user_id, action, renter_id, reason, granted_until)
    values (p_by, 'open', v_renter, 'Incoming call from the renter''s number (caller pop-up)', now() + interval '24 hours');
  end if;
  return jsonb_build_object('ok', true, 'renter_id', v_renter);
end $$;

-- ================================================================ 5. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0800;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('admin_read', 'va_read', 'ops_read') and p_name in ('caller_live', 'renter_notes'))
     or (p_call in ('admin_do', 'va_do', 'ops_do') and p_name in ('renter_note_add', 'renter_note_remove', 'caller_open')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'caller_live' then app.caller_live(p_user, p)
      when 'renter_notes' then app.renter_notes_read(p_user, p)
      when 'renter_note_add' then app.renter_note_add(p_user, p)
      when 'renter_note_remove' then app.renter_note_remove(p_user, p)
      else app.caller_open(p_user, p) end;
  end if;
  return app.door_pre0800(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0800(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 6. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['caller_popup_ok', 'renter_called_recently', 'renter_notes_ok', 'renter_note_role', 'renter_note_json',
             'renter_notes_list', 'caller_booking', 'caller_balance', 'caller_deposit', 'caller_requests', 'caller_renter', 'caller_live', 'renter_notes_read',
             'renter_note_add', 'renter_note_remove', 'caller_open', 'door_pre0800'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
