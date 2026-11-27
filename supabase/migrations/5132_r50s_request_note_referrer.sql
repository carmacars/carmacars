-- 5132 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). The owner, Nov 27: "renters can add a note on each
-- booking request, and enter who referred you (a staff member or partner, searchable) so that person is credited for the
-- referral or sale".
--
-- 1. Notes on a request: booking_request_notes. The renter adds a note to their own request while it is open (requested,
--    offered or accepted and not paid) from the request's page in their account (public.renter_request_note, the server's
--    call; 1 to 1,000 characters, at most 20 a request). Admin and the staff on the request are told at once (staff alert
--    request_note: Admins, the person answering it or credited with it, else customer service on duty). The notes show on
--    the request's row in Requests and offers and on the booking page (ops_read / admin_read request_notes).
-- 2. Who referred you: the request form searches the team and the referral partners by name
--    (public.server_referrer_search, the server's call, 3 letters at least, 8 answers at most): a staff member shows as
--    their first name and last initial, a partner as its business name. Nothing else about them leaves the database. The
--    choice travels with the request as referred_by ('s:' and the staff member's id, or 'p:' and the partner's code):
--      a partner        its code is the request's referral code (0164: the booking is the partner's referral)
--      a salesperson    the booking is credited to them as sourced (sales_source referral), when nobody is credited yet
--      field staff      their referral code is the request's (0016/0058: the referral fee)
--    The booking's history says who the renter named, and that person gets an alert (referral_named). A name typed and
--    not chosen stays as before (details.referrer_name, for staff to read). A renter who names themself (the same sign-in
--    or email) credits nobody. The credit pays as every commission and referral fee does: it waits for an Admin to
--    approve it (0058). The search matches what was typed as text (% and _ are not wildcards), in name order.
--    The notes are read by Admins, Sales and customer service only.
-- SCHEMA_MARKER is not changed. No applied migration is edited: app.submit_booking_request and app.door are wrapped (_pre5132).
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

-- ================================================================ 1. notes on a request
create table booking_request_notes (
  id          uuid primary key default gen_random_uuid(),
  booking_id  uuid not null references bookings (id) on delete cascade,
  author_id   uuid references users (id) on delete set null,
  body        text not null check (length(btrim(body)) between 1 and 1000),
  created_at  timestamptz not null default now()
);
comment on table booking_request_notes is 'A note the renter added to their own booking request (5132): shown to Admin and staff on the request.';
create index booking_request_notes_booking_idx on booking_request_notes (booking_id, created_at);
create index booking_request_notes_author_idx on booking_request_notes (author_id);
alter table booking_request_notes enable row level security;
create policy admin_all on booking_request_notes for all to authenticated using (app.is_admin()) with check (app.is_admin());
revoke all on booking_request_notes from public, anon, authenticated;
grant all on booking_request_notes to service_role;
create trigger audit_booking_request_notes after insert or update or delete on booking_request_notes for each row execute function app.audit_row();

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('request_note', 'A renter added a note to their request', 'Bookings', '{admin,assigned,unassigned_on_duty:cs}', 'normal', 'requests', true, false,
   '5132: the renter wrote a note on an open request; the person answering it (or credited with it) is told, else customer service on duty.', 50, 'staff_bookings'),
  ('referral_named', 'A renter named you as who referred them', 'Sales', '{assigned}', 'normal', 'leads', true, false,
   '5132: a renter chose you under "Who referred you?" on a request to book; the booking is credited to you.', 51, 'staff_system')
on conflict (rule) do nothing;

create function app.request_notes_json(p_booking uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'body', n.body, 'at', n.created_at) order by n.created_at), '[]'::jsonb)
    from booking_request_notes n where n.booking_id = p_booking
$$;

-- p_by: the signed-in renter (the server checks the session). Returns the request's notes.
create function public.renter_request_note(p_booking uuid, p_by uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
  v_to uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if b.id is null or p_by is null or not exists (select 1 from renters r where r.id = b.renter_id and r.user_id = p_by) then
    raise exception 'Request not found' using errcode = 'P0002';
  end if;
  if b.status::text not in ('requested', 'offered', 'pending_payment') then
    raise exception 'This request is no longer open: write to us in Messages instead' using errcode = '23514';
  end if;
  if length(v_body) < 1 or length(v_body) > 1000 then raise exception 'Write a note of up to 1,000 characters' using errcode = '22023'; end if;
  if (select count(*) from booking_request_notes n where n.booking_id = b.id) >= 20 then
    raise exception 'This request has 20 notes already: write to us in Messages instead' using errcode = '23514';
  end if;
  insert into booking_request_notes (booking_id, author_id, body) values (b.id, p_by, v_body) returning id into v_id;
  v_to := coalesce((select c.claimed_by from request_claims c where c.booking_id = b.id and c.expires_at > now()), b.sales_staff_id);
  begin
    perform app.staff_alert('request_note', 'booking', b.id, 'note:' || v_id,
      left(format('Note from the renter on %s', b.booking_number), 140), left(v_body, 240),
      jsonb_strip_nulls(jsonb_build_object('assigned_to', v_to, 'booking_id', b.id, 'path_admin', '/admin/bookings/' || b.booking_number,
                                           'path_staff', '/staff/bookings/' || b.booking_number)));
  exception when others then raise warning 'request note alert not sent for %: %', b.booking_number, sqlerrm;
  end;
  return app.request_notes_json(b.id);
end $$;

create function public.renter_request_notes(p_booking uuid, p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if p_by is null or not exists (select 1 from bookings b join renters r on r.id = b.renter_id where b.id = p_booking and r.user_id = p_by) then
    raise exception 'Request not found' using errcode = 'P0002';
  end if;
  return app.request_notes_json(p_booking);
end $$;

-- The request queue shows each request's notes.
alter function app.admin_requests(uuid, jsonb) rename to admin_requests_pre5132;
create function app.admin_requests(p_admin uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(case when coalesce((x ->> 'sample')::boolean, false) then x
                                 else x || jsonb_build_object('renter_notes', app.request_notes_json((x ->> 'id')::uuid)) end order by n), '[]'::jsonb)
    from jsonb_array_elements(app.admin_requests_pre5132(p_admin, p)) with ordinality t(x, n)
$$;
select pg_temp.copy_grants('app.admin_requests(uuid, jsonb)'::regprocedure, 'app.admin_requests_pre5132(uuid, jsonb)'::regprocedure);

-- ================================================================ 2. who referred you
-- p_q: what the renter typed. Active team members who can be credited (Sales, field staff) and active referral partners.
create function public.server_referrer_search(p_q text) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  -- what was typed is matched as text: % and _ are not wildcards
  with q as (select replace(replace(replace(lower(btrim(coalesce(p_q, ''))), '\', '\\'), '%', '\%'), '_', '\_') as t, lower(btrim(coalesce(p_q, ''))) as raw)
  select coalesce(jsonb_agg(x order by x ->> 'label'), '[]'::jsonb) from (
    select x from (
      select jsonb_build_object('key', 's:' || u.id, 'kind', 'staff',
               'label', case when btrim(u.full_name) ~ '\s' then split_part(btrim(u.full_name), ' ', 1) || ' ' || upper(left(regexp_replace(btrim(u.full_name), '^.*\s', ''), 1)) || '.'
                             else btrim(u.full_name) end,
               'note', 'CarmaCars team') as x
        from users u, q
       where length(q.raw) >= 3 and u.status = 'active' and not u.is_test and nullif(btrim(u.full_name), '') is not null
         and (app.user_va_has_sales(u.id) or app.is_field_person(u.id))
         and (lower(u.full_name) like q.t || '%' or lower(u.full_name) like '% ' || q.t || '%')
      union all
      select jsonb_build_object('key', 'p:' || rp.referral_code, 'kind', 'partner', 'label', rp.business_name, 'note', 'Partner')
        from referral_partners rp, q
       where length(q.raw) >= 3 and rp.status = 'active'
         and (lower(rp.business_name) like q.t || '%' or lower(rp.business_name) like '% ' || q.t || '%' or upper(rp.referral_code) = upper(q.raw))
    ) s order by x ->> 'label' limit 8) y
$$;

-- The person the renter named credits the booking: a salesperson the sale (when nobody is credited yet), field staff the
-- referral (their code). Never fails the request.
create function app.request_referrer_credit(p_booking uuid, p_staff uuid) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  b bookings;
  u users;
  v_code text;
  v_how text;
begin
  select * into b from bookings where id = p_booking for update;
  select * into u from users where id = p_staff;
  if b.id is null or u.id is null or u.status <> 'active' or u.is_test or app.credit_blocked(u.id) then return null; end if;
  -- no self-referral: the renter is the staff member (their sign-in, or the same email)
  if exists (select 1 from renters r where r.id = b.renter_id and (r.user_id = u.id or (r.email is not null and lower(r.email) = lower(u.email)))) then
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      'The renter named themself as who referred them: nobody is credited', null, 'system', jsonb_build_object('referrer', u.id, 'credited', 'none', 'why', 'self'));
    return null;
  end if;
  if app.user_va_has_sales(u.id) and b.sales_staff_id is null then
    update bookings set sales_staff_id = u.id, sales_source = 'referral', sales_sourced = true, sales_attributed_at = now()
     where id = b.id;
    v_how := 'sale';
  elsif app.is_field_person(u.id) and b.referrer_type is null and b.referral_partner_id is null then
    select sp.referral_code into v_code from staff_profiles sp where sp.user_id = u.id and sp.staff_type = 'field';
    if v_code is null then return null; end if;
    update bookings set referred_by_code = v_code where id = b.id;
    v_how := 'referral';
  else
    return null;
  end if;
  perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
    format('The renter named %s as who referred them: the %s is credited to them', coalesce(u.full_name, 'a team member'), v_how),
    null, 'system', jsonb_build_object('referrer', u.id, 'credited', v_how));
  begin
    perform app.staff_alert('referral_named', 'booking', b.id, 'named:' || u.id,
      left(format('A renter named you as who referred them: %s', b.booking_number), 140),
      left(format('%s, %s to %s. The %s is credited to you.', app.vehicle_name(b.vehicle_id), app.fmt_at(b.pickup_at), app.fmt_at(b.return_at), v_how), 240),
      jsonb_build_object('assigned_to', u.id, 'booking_id', b.id, 'path_staff', '/staff/bookings/' || b.booking_number, 'path_admin', '/admin/bookings/' || b.booking_number));
  exception when others then raise warning 'referral alert not sent for %: %', b.booking_number, sqlerrm;
  end;
  return v_how;
exception when others then
  raise warning 'referrer not credited on %: %', p_booking, sqlerrm;
  return null;
end $$;

alter function app.submit_booking_request(jsonb, inet, text, uuid) rename to submit_booking_request_pre5132;
create function app.submit_booking_request(p_request jsonb, p_ip inet default null, p_user_agent text default null, p_user uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_req jsonb := p_request;
  v_key text := nullif(btrim(coalesce(p_request ->> 'referred_by', '')), '');
  v_staff uuid;
  v_out jsonb;
begin
  if v_key ~ '^p:[A-Z0-9]{4,12}$' and nullif(btrim(coalesce(p_request ->> 'referred_by_code', '')), '') is null then
    v_req := v_req || jsonb_build_object('referred_by_code', substr(v_key, 3));
  elsif v_key ~ '^s:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_staff := substr(v_key, 3)::uuid;
  end if;
  v_out := app.submit_booking_request_pre5132(v_req - 'referred_by', p_ip, p_user_agent, p_user);
  if v_staff is not null and coalesce((v_out ->> 'ok')::boolean, false) and coalesce((v_out ->> 'created')::boolean, true)
     and nullif(v_out ->> 'booking_id', '') is not null then
    perform app.request_referrer_credit((v_out ->> 'booking_id')::uuid, v_staff);
  end if;
  return v_out;
end $$;
select pg_temp.copy_grants('app.submit_booking_request(jsonb, inet, text, uuid)'::regprocedure, 'app.submit_booking_request_pre5132(jsonb, inet, text, uuid)'::regprocedure);

-- ================================================================ 3. the door: the notes on the booking page
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5132;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_b uuid;
begin
  if p_call in ('ops_read', 'va_read', 'admin_read') and p_name = 'request_notes' then
    perform app.door_begin(p_user, p_aal);
    if not (app.user_is_admin(p_user) or app.user_va_has(p_user, 'sales', 'cs')) then raise exception 'Not permitted' using errcode = '42501'; end if;
    select b.id into v_b from bookings b where b.id::text = p ->> 'booking' or b.booking_number = p ->> 'booking';
    if v_b is null then raise exception 'Booking not found' using errcode = 'P0002'; end if;
    return app.request_notes_json(v_b);
  end if;
  return app.door_pre5132(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5132(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.request_notes_json(uuid), public.renter_request_note(uuid, uuid, text), public.renter_request_notes(uuid, uuid),
  public.server_referrer_search(text), app.request_referrer_credit(uuid, uuid) from public, anon, authenticated;
grant execute on function app.request_notes_json(uuid), public.renter_request_note(uuid, uuid, text), public.renter_request_notes(uuid, uuid),
  public.server_referrer_search(text), app.request_referrer_credit(uuid, uuid) to service_role;
