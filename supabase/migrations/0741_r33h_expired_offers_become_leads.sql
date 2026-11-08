-- 0741: an offer expired for 7 days or more leaves Requests and offers and becomes a renter lead (release 33 part H,
-- docs/changes/2026-11-07-r33-finishing.md, item 4).
--
-- Requests and offers keeps an expired offer for 7 days (the Expired filter). After that the booking stays as it was (status expired, its history and
-- its numbers) but the person is not lost: the scheduled job (app.job_capture, every 15 minutes, as the unfinished request alerts) makes ONE renter lead
-- in `leads` for the booking: the renter's contact, the car and the dates they wanted (message, vehicle_text and the payload), source "expired_offer",
-- assigned by the existing lead rule (app.lead_real_assignee: the Sales person with the fewest open leads), and a follow-up To do for Sales
-- ("expired_offer_lead") assigned to the same person. Once per booking: the unique index below. Not made for a renter who is blocked, for a test
-- address, for an owner's booking or a placeholder, or when the renter booked a car afterwards (a confirmed, on-rent, returned or closed booking made
-- after the offer expired). A booking reopened by staff (status no longer expired) is not a lead.
-- The migration also runs it once for today's old expired offers, without the new-lead alert (the leads are not new news).
-- No applied migration is edited.

create unique index leads_expired_offer_once on leads ((payload ->> 'booking_id')) where source = 'expired_offer';

insert into task_rules (task_type, queue, title, priority, description)
values ('expired_offer_lead', 'sales', 'Expired offer: win the renter back', 'normal',
        'An offer expired without an answer a week ago, so the request left Requests and offers. The renter is now a lead with the car and the dates they wanted. Call or text them, offer the car again or another one, and mark the lead contacted or closed.')
on conflict (task_type) do nothing;

create function app.expired_offers_to_leads(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_lead uuid;
  v_task uuid;
  v_assignee uuid;
  v_car text;
  v_expired timestamptz;
  n integer := 0;
begin
  for r in
    select b.id, b.booking_number, b.vehicle_id, b.pickup_at, b.return_at, b.renter_id, b.updated_at,
           (select max(e.created_at) from booking_events e where e.booking_id = b.id and e.kind in ('offer_expired', 'request_expired')) as expired_at
      from bookings b
     where b.status = 'expired' and b.booking_type <> 'owner' and not b.is_placeholder
       and not exists (select 1 from leads l where l.source = 'expired_offer' and l.payload ->> 'booking_id' = b.id::text)
     order by b.id
  loop
    v_expired := coalesce(r.expired_at, r.updated_at);
    continue when v_expired > p_now - interval '7 days';
    declare
      rn renters;
    begin
      select * into rn from renters x where x.id = r.renter_id;
      continue when rn.id is null or rn.is_blocked or rn.merged_into is not null;
      continue when rn.email is null and rn.mobile is null;
      continue when app.email_is_test(rn.email);
      -- the renter booked anyway after the offer expired: nothing to win back
      continue when exists (select 1 from bookings x where x.renter_id = r.renter_id and x.id <> r.id
                              and x.status in ('confirmed', 'on_rent', 'returned', 'closed') and x.created_at > v_expired);
      v_car := coalesce(app.vehicle_name(r.vehicle_id), 'a car');
      v_assignee := app.lead_real_assignee();
      insert into leads (kind, name, email, phone, message, payload, source, vehicle_text, assigned_to, status)
      values ('contact', nullif(btrim(rn.legal_name), ''), nullif(lower(btrim(rn.email)), ''), nullif(btrim(rn.mobile), ''),
              format('Offer for the %s, %s to %s, expired on %s without an answer (booking %s).', v_car,
                     to_char(r.pickup_at at time zone 'America/Toronto', 'Mon FMDD, YYYY'), to_char(r.return_at at time zone 'America/Toronto', 'Mon FMDD, YYYY'),
                     to_char(v_expired at time zone 'America/Toronto', 'Mon FMDD, YYYY'), r.booking_number),
              jsonb_build_object('form', 'expired_offer', 'booking_id', r.id, 'booking_number', r.booking_number, 'renter_id', r.renter_id,
                                 'vehicle', v_car, 'pickup_at', r.pickup_at, 'return_at', r.return_at, 'expired_at', v_expired),
              'expired_offer', v_car, v_assignee, 'new')
      returning id into v_lead;
      v_task := app.raise_task(p_type => 'expired_offer_lead',
                               p_title => left(format('Win back %s: the offer for the %s expired', coalesce(nullif(btrim(rn.legal_name), ''), 'the renter'), v_car), 200),
                               p_detail => format('Wanted %s to %s. Booking %s. Call or text, then mark the lead contacted or closed.',
                                                  to_char(r.pickup_at at time zone 'America/Toronto', 'Mon FMDD'), to_char(r.return_at at time zone 'America/Toronto', 'Mon FMDD, YYYY'), r.booking_number),
                               p_renter => r.renter_id, p_related_table => 'leads', p_related_id => v_lead,
                               p_dedupe => 'expired_offer_lead:' || r.id);
      if v_task is not null and v_assignee is not null then
        update tasks set assigned_to = v_assignee where id = v_task;
      end if;
      n := n + 1;
    end;
  end loop;
  return n;
end $$;
revoke all on function app.expired_offers_to_leads(timestamptz) from public, anon, authenticated;
grant execute on function app.expired_offers_to_leads(timestamptz) to service_role;

-- the scheduled path: the job that already runs every 15 minutes for captured contacts
alter function app.job_capture(timestamptz) rename to job_capture_pre0741;
create function app.job_capture(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.job_capture_pre0741(p_now);
  n integer;
begin
  begin
    n := app.expired_offers_to_leads(p_now);
  exception when others then
    raise warning 'expired offers to leads failed: %', sqlerrm;
    n := 0;
  end;
  return v || case when n > 0 then format(', expired offers made leads %s', n) else '' end;
end $$;
do $$
declare g text;
begin
  execute 'revoke all on function app.job_capture(timestamptz) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.job_capture_pre0741(timestamptz)', 'execute') then execute format('grant execute on function app.job_capture(timestamptz) to %I', g); end if;
  end loop;
end $$;

-- one-time backfill: today's old expired offers (no "new lead" alert for these)
alter table leads disable trigger leads_z_alert;
select app.expired_offers_to_leads(now());
alter table leads enable trigger leads_z_alert;
