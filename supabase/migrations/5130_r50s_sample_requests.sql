-- 5130 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). The owner, Nov 27: "inquiries on sample cars
-- (e.g. DOST) do not appear in bookings or requests, so nobody can service them".
--
-- A request on a sample car (an example car, not a real one) is a lead of kind sample_car (0065): no booking may be made on
-- such a car, so it never reached Requests and offers. Now every open sample-car enquiry is a row of the request queue
-- (app.admin_requests, so Admin and staff read it the same way), marked as a sample car, with up to three real cars to
-- offer instead: published, not a sample, free for the dates asked, the same class first, then the same body type, then the
-- nearest year. The row stays while the enquiry is open (new, contacted or qualified, no outcome, not merged); recording an
-- outcome on the lead (won, lost, handled) takes it off the queue. Nothing about the enquiry itself changes.
-- SCHEMA_MARKER is not changed. No applied migration is edited: app.admin_requests is wrapped (_pre5130).
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

-- Up to three real cars to offer for a sample-car enquiry: published, real, free between p_from and p_to (or now and a day
-- later when the dates are not known), closest to the sample car first.
create function app.sample_real_cars(p_sample uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', app.vehicle_name(c.id), 'slug', c.slug, 'class', c.class, 'same_class', c.same_class) order by c.rank), '[]'::jsonb)
    from (select v.id, l.slug, v.class::text as class, v.class is not distinct from s.class as same_class,
                 row_number() over (order by (v.class is not distinct from s.class) desc, (v.body_type is not distinct from s.body_type) desc,
                                             abs(coalesce(v.year, 0) - coalesce(s.year, 0)), v.id) as rank
            from vehicles s
            join vehicles v on v.id <> s.id and not v.is_sample and v.status in ('available', 'on_rent', 'cleaning')
            join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
            left join owners o on o.id = v.owner_id
           where s.id = p_sample and not coalesce(o.is_test, false)
             and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.blocks_calendar
                               and b.status in ('requested', 'offered', 'pending_payment', 'confirmed', 'on_rent')
                               and b.pickup_at < coalesce(p_to, coalesce(p_from, now()) + interval '1 day')
                               and b.return_at > coalesce(p_from, now()))) c
   where c.rank <= 3
$$;

-- The open sample-car enquiries as rows of the request queue (the shape of the RequestsQueue rows, plus sample fields).
create function app.sample_request_rows() returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(x order by x ->> 'requested_at'), '[]'::jsonb) from (
    select jsonb_build_object('id', l.id, 'lead_id', l.id, 'sample', true, 'booking_number', coalesce(l.payload ->> 'reference', 'EQ'),
      'status', 'requested', 'state', 'sample', 'vehicle', coalesce(l.payload ->> 'car', app.vehicle_name(v.id), 'A sample car'),
      'vehicle_id', v.id, 'renter', coalesce(nullif(btrim(l.name), ''), l.email, l.phone), 'returning', false,
      'pickup_at', coalesce(app.sr_at(l.payload ->> 'pickup_at'), l.created_at), 'return_at', coalesce(app.sr_at(l.payload ->> 'return_at'), app.sr_at(l.payload ->> 'pickup_at'), l.created_at),
      'days', greatest(1, ceil(extract(epoch from coalesce(app.sr_at(l.payload ->> 'return_at'), app.sr_at(l.payload ->> 'pickup_at'), l.created_at)
                                                 - coalesce(app.sr_at(l.payload ->> 'pickup_at'), l.created_at)) / 86400.0))::integer,
      'total_cents', 0, 'requested_at', l.created_at, 'offer_expires_at', null,
      'waiting_minutes', floor(extract(epoch from now() - l.created_at) / 60)::integer,
      'flags', jsonb_build_array('Sample car'), 'drivers', '[]'::jsonb,
      'assigned', (select coalesce(u.full_name, u.email) from users u where u.id = l.assigned_to),
      'contact', jsonb_strip_nulls(jsonb_build_object('email', l.email, 'phone', l.phone)), 'note', left(l.message, 300),
      'suggestions', app.sample_real_cars(v.id, app.sr_at(l.payload ->> 'pickup_at'), app.sr_at(l.payload ->> 'return_at'))) as x
      from leads l
      left join vehicles v on v.id = app.sr_uuid(l.payload ->> 'vehicle_id')
     where l.kind = 'sample_car' and l.merged_into is null and l.status in ('new', 'contacted', 'qualified')
       and l.sales_outcome is null and l.handled_at is null) q
$$;

-- tolerant readers of the enquiry's form (a bad value is no date, never an error in the queue)
create function app.sr_at(p text) returns timestamptz
language plpgsql immutable set search_path = public, app, pg_temp as $$
begin
  return nullif(p, '')::timestamptz;
exception when others then return null;
end $$;
create function app.sr_uuid(p text) returns uuid
language plpgsql immutable set search_path = public, app, pg_temp as $$
begin
  return nullif(p, '')::uuid;
exception when others then return null;
end $$;

alter function app.admin_requests(uuid, jsonb) rename to admin_requests_pre5130;
create function app.admin_requests(p_admin uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select app.admin_requests_pre5130(p_admin, p) || app.sample_request_rows()
$$;
select pg_temp.copy_grants('app.admin_requests(uuid, jsonb)'::regprocedure, 'app.admin_requests_pre5130(uuid, jsonb)'::regprocedure);

revoke all on function app.sample_real_cars(uuid, timestamptz, timestamptz), app.sample_request_rows(), app.sr_at(text), app.sr_uuid(text) from public, anon, authenticated;
grant execute on function app.sample_real_cars(uuid, timestamptz, timestamptz), app.sample_request_rows(), app.sr_at(text), app.sr_uuid(text) to service_role;
