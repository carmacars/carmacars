-- 2898 (release 47, part B): an insurer rental whose end date is not known never escalates as a late return. An insurance
-- replacement runs until the repair is done; its return time on file is only a placeholder. Reaching it started the
-- late-return chain (the renter's return-due, first and final notices, Fleet's and the Admins' alerts, the To do's
-- "not back at the return time" and "120 minutes overdue: final notice, then disabling, repossession and police").
-- Such a booking (app.booking_insurer_open_end: billed to an insurer, or with the insurer's claim on file, and its dates
-- provisional, or its note saying the end date is not known) now:
--   - sends none of the overdue notices (app.ntf_emit) and opens neither late-return To do;
--   - opens one To do for the Admin instead, "Insurer rental reached its end date: extend or close" (once per end date),
--     and stays on rent; the To do closes by itself when the end date is moved later or the car is back.
-- Once: the open late-return To do's of such bookings are closed with a note and the new To do opened.
-- docs/changes/2026-11-14-r47b-crash-alerts-photo-standard.md.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. which bookings
create or replace function app.booking_insurer_open_end(b bookings) returns boolean
language sql stable set search_path = public, app as $$
  select b.id is not null
     and (coalesce(b.bill_to, 'renter') <> 'renter' or b.insurer_id is not null or nullif(btrim(coalesce(b.insurer_claim_number, '')), '') is not null)
     and (coalesce(b.dates_provisional, false)
          or concat_ws(' ', b.request_note, b.notes) ~* '((end|return|drop[- ]?off) date|end of (the )?rental)[^.]{0,20}(not (yet )?(known|set|confirmed)|unknown|tbd|tbc|to be (confirmed|determined)|open)|open[- ]?ended|no (fixed |set )?end date|until (the )?(repairs?|car|vehicle) (is |are )?(done|fixed|ready|repaired)')
$$;
comment on function app.booking_insurer_open_end(bookings) is 'r47 (2898): an insurer rental whose end date is not known (billed to an insurer or with its claim on file; dates provisional or the note says so): reaching the return time never starts the late-return chain.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('insurer_end_reached', 'admin', 'Insurer rental reached its end date: extend or close', 'high', 'none', null, null, null,
   'An insurer rental with no known end date reached the return time on file (2898). Ask the adjuster or the renter: move the end date (extend), or close the rental when the car is back. No late notice was sent; the booking stays on rent.')
on conflict (task_type) do nothing;

create or replace function app.insurer_end_reached_raise(p_booking uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or not app.booking_insurer_open_end(b) or b.return_at > now() then return null; end if;
  return app.raise_task(p_type => 'insurer_end_reached',
    p_title => format('Insurer rental %s reached its end date: extend or close', b.booking_number),
    p_detail => format('The end date on file was %s (Toronto) and it is not known for this insurer rental%s. Move the end date if the repair is not done, or close the rental when the car is back. No late notice was sent; the booking stays on rent.',
                       to_char(b.return_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'),
                       coalesce(', claim ' || nullif(btrim(b.insurer_claim_number), ''), '')),
    p_booking => b.id, p_vehicle => b.vehicle_id, p_renter => b.renter_id, p_due_at => now(),
    p_dedupe => 'insurer_end_reached:' || b.id || ':' || extract(epoch from b.return_at)::bigint);
end $$;

-- ================================================================ 2. no late-return To do and no overdue notice for them
create or replace function app.tasks_r47_route() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if (new.task_type = 'first_day_admin' and new.dedupe_key like 'first_day_admin:%')
     or (new.task_type = 'verify_staff_payout' and new.dedupe_key like 'verify_staff_payout:%') then
    return null; -- 2897: the digests answer them
  end if;
  if new.task_type in ('late_return', 'late_return_admin') and new.booking_id is not null
     and app.booking_insurer_open_end((select b from bookings b where b.id = new.booking_id)) then
    perform app.insurer_end_reached_raise(new.booking_id);
    return null;
  end if;
  return new;
end $$;

alter function app.ntf_emit(text, text, uuid, text, jsonb) rename to ntf_emit_pre2898;
create function app.ntf_emit(p_code text, p_entity text, p_id uuid, p_disc text, p_payload jsonb default '{}'::jsonb) returns bigint
language plpgsql security definer set search_path = public, app as $$
begin
  if p_entity = 'booking' and p_code = any (app.overdue_codes())
     and app.booking_insurer_open_end((select b from bookings b where b.id = p_id)) then
    perform app.insurer_end_reached_raise(p_id);
    return null;
  end if;
  return app.ntf_emit_pre2898(p_code, p_entity, p_id, p_disc, p_payload);
end $$;
select pg_temp.copy_grants('app.ntf_emit(text, text, uuid, text, jsonb)'::regprocedure, 'app.ntf_emit_pre2898(text, text, uuid, text, jsonb)'::regprocedure);

-- the To do closes by itself: the end date moved later, or the rental is over
create or replace function app.insurer_end_reached_settle() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.return_at > now() or new.status not in ('on_rent', 'confirmed') then
    update tasks set status = 'done', completed_at = now(),
           completion_note = case when new.status not in ('on_rent', 'confirmed') then 'The rental is ' || new.status::text || ' (2898)' else 'The end date was moved to ' || to_char(new.return_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') || ' (2898)' end
     where booking_id = new.id and task_type = 'insurer_end_reached' and status in ('open', 'in_progress', 'waiting');
  end if;
  return null;
end $$;
drop trigger if exists bookings_insurer_end_reached on bookings;
create trigger bookings_insurer_end_reached after update of return_at, status on bookings for each row
  when (old.return_at is distinct from new.return_at or old.status is distinct from new.status) execute function app.insurer_end_reached_settle();

revoke all on function app.booking_insurer_open_end(bookings), app.insurer_end_reached_raise(uuid), app.insurer_end_reached_settle(), app.ntf_emit_pre2898(text, text, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function app.booking_insurer_open_end(bookings), app.insurer_end_reached_raise(uuid), app.insurer_end_reached_settle(), app.ntf_emit_pre2898(text, text, uuid, text, jsonb) to service_role;

-- ================================================================ 3. once: the late-return To do's of such bookings
do $$
declare t record; n integer := 0;
begin
  for t in select distinct x.booking_id from tasks x join bookings b on b.id = x.booking_id
            where x.task_type in ('late_return', 'late_return_admin') and x.status in ('open', 'in_progress', 'waiting') and app.booking_insurer_open_end(b)
  loop
    update tasks set status = 'done', completed_at = now(),
           completion_note = 'Closed by release 47 (2898): an insurer rental with no known end date is not a late return. See the To do "Insurer rental reached its end date: extend or close".'
     where booking_id = t.booking_id and task_type in ('late_return', 'late_return_admin') and status in ('open', 'in_progress', 'waiting');
    perform app.insurer_end_reached_raise(t.booking_id);
    n := n + 1;
  end loop;
  raise notice '2898: % insurer rentals taken out of the late-return chain', n;
end $$;
