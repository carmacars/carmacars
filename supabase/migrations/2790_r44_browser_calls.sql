-- 2790 (release 44, part A): calls in the browser, the hiring defaults, and Sales reading only their own leads.
--  1. Calls in the browser (Twilio's Voice SDK). Calls from the site never worked: the Twilio account, the caller ID and
--     the secrets were never set, and the only way the Call button had (0970: ring the staff member's own cell first, then
--     the customer) cannot work for staff abroad, whose own numbers are international (2460 accepts Canadian and US
--     mobiles only). Now staff place and take calls in the browser of the staff and Admin portals, with the CarmaCars
--     number as caller ID:
--       - outbound_calls.via says how a call was placed (phone, the 0970 way; browser, this release);
--       - app.server_twilio_browser_call_start keeps a call placed in the browser (no own number needed), and
--         app.server_twilio_browser_call_get gives the client webhook the customer's number only for the staff member who
--         started that call;
--       - voice_presence: who has a staff page open with the phone ready (a beat every minute); a call to the business
--         number (a Twilio number) rings the browsers of those online whose role rings (Program setting
--         phone_inbound_ring, customer service and Sales by default), app.server_voice_ring, each shown the caller as
--         they may see them (a name, or the number masked for Sales, 0970);
--       - nobody online or nobody answered: a short message and the missed-call handling of every call (0085), or a
--         forward to the number an Admin sets. Never to a staff member's own number: phone_call_own_mobile (the 0970 way)
--         is off by default.
--  2. Hiring: the AI interview decides by itself again (hiring_ai_auto_decide on; the r43 rules hold: only a Sales pass is
--     hired by the AI, every other role books an interview). The welcome note of a hire no longer gives a start date
--     (read as "you work tomorrow"): training and claiming shifts only, then a hello in the team chat and the member tag
--     "Name - Position" in each WhatsApp group. A first-day To do says the same.
--  3. A person who works in Sales only reads, directly from their session, only their own leads (assigned to them, brought
--     in or added by them, claimed by them now, or with their sale outcome). Through the door every lead's number stays
--     masked for them (0970) as before.
-- No applied migration is edited: app.hire_onboard_pre1067 is patched in place. SCHEMA_MARKER 2790.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '2790: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. calls in the browser
alter table program_settings
  add column if not exists phone_browser_calls boolean not null default true,
  add column if not exists phone_inbound_ring text not null default 'cs, sales'
    check (phone_inbound_ring ~ '^\s*$|^\s*(admin|cs|sales|fleet|finance)(\s*,\s*(admin|cs|sales|fleet|finance))*\s*$'),
  add column if not exists phone_inbound_ring_seconds integer not null default 25 check (phone_inbound_ring_seconds between 10 and 60),
  add column if not exists phone_inbound_forward_number text not null default '' check (phone_inbound_forward_number = '' or phone_inbound_forward_number ~ '^\+[1-9][0-9]{7,14}$'),
  add column if not exists phone_inbound_message text not null default 'Sorry, we could not take your call. We will call you back shortly. CarmaCars.'
    check (length(phone_inbound_message) between 1 and 300),
  add column if not exists phone_call_own_mobile boolean not null default false;
comment on column program_settings.phone_browser_calls is 'Calls (2790): staff place and take calls in the browser of the staff and Admin portals with the CarmaCars number as caller ID (Twilio Voice SDK). On by default.';
comment on column program_settings.phone_inbound_ring is 'Calls (2790): whose browser rings for a call to the business number (a Twilio number): a comma list of admin, cs, sales, fleet, finance. Only people with a staff page open ring. Empty: nobody (the no-answer way at once).';
comment on column program_settings.phone_inbound_ring_seconds is 'Calls (2790): how long the browsers ring before the no-answer way (seconds, 10 to 60).';
comment on column program_settings.phone_inbound_forward_number is 'Calls (2790): nobody answered in the browser: forward the call to this number (E.164, for example +12895550123). Empty (the default): the short message, and the missed call is handled as every missed call. Never a staff member''s own number by default.';
comment on column program_settings.phone_inbound_message is 'Calls (2790): what a caller hears when nobody answered in the browser and no forward number is set.';
comment on column program_settings.phone_call_own_mobile is 'Calls (0970, 2790): the old way of the Call button: ring the staff member''s own mobile first, then the customer. Off by default (staff abroad have international numbers): calls are made in the browser.';

alter table outbound_calls add column if not exists via text not null default 'phone' check (via in ('phone', 'browser'));
comment on column outbound_calls.via is 'How the call was placed (2790): phone (0970: the staff member''s own cell rang first) or browser (the Voice SDK in the staff portal).';

create table if not exists voice_presence (
  user_id    uuid primary key references users (id) on delete cascade,
  online     boolean not null default true,
  seen_at    timestamptz not null default now()
);
comment on table voice_presence is 'Calls in the browser (2790): who has a staff page open with the phone ready; the page beats every minute. A call to the business number rings those seen in the last 2 minutes whose role rings (phone_inbound_ring).';
alter table voice_presence enable row level security;
create policy admin_all on voice_presence for select to authenticated using (app.is_admin());
revoke all on voice_presence from anon, authenticated;
grant select on voice_presence to authenticated;
grant select, insert, update, delete on voice_presence to service_role;

-- staff who may use the phone at all (the Call buttons are every staff member's, 0500)
create or replace function app.voice_staff_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and exists (select 1 from users u join user_roles r on r.user_id = u.id
                                         where u.id = p_user and u.status = 'active' and r.role::text in ('admin', 'va', 'field'))
$$;

-- whether a call to the business number rings this person (their role is in phone_inbound_ring)
create or replace function app.voice_rings(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  with want as (select array(select btrim(x) from unnest(string_to_array((app.settings()).phone_inbound_ring, ',')) x where btrim(x) <> '') as f)
  select coalesce((app.settings()).phone_browser_calls, true)
     and ((('admin' = any (w.f)) and app.user_is_admin(p_user))
          or app.user_va_has(p_user, variadic coalesce(nullif(array(select y from unnest(w.f) y where y <> 'admin'), '{}'), array['none'])))
    from want w
$$;

create or replace function app.server_voice_settings() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('calls', s.phone_browser_calls, 'inbound', btrim(s.phone_inbound_ring) <> '', 'own_mobile', s.phone_call_own_mobile,
           'seconds', s.phone_inbound_ring_seconds, 'forward_to', nullif(s.phone_inbound_forward_number, ''), 'message', s.phone_inbound_message,
           'caller_id', app.phone_our_number())
    from (select (app.settings()).*) s
$$;

-- the page's phone is ready (a token was given) or still open (the beat), or it closed
create or replace function app.server_voice_presence(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_online boolean := coalesce((p ->> 'online')::boolean, true);
  v_ring boolean;
begin
  if not app.voice_staff_ok(p_user) then raise exception 'Sign in as staff first' using errcode = '42501'; end if;
  v_ring := app.voice_rings(p_user);
  if v_ring or not v_online then
    insert into voice_presence (user_id, online, seen_at) values (p_user, v_online, now())
    on conflict (user_id) do update set online = excluded.online, seen_at = excluded.seen_at;
  end if;
  return jsonb_build_object('ok', true, 'calls', (app.settings()).phone_browser_calls, 'ring', v_ring,
    'message', case when not (app.settings()).phone_browser_calls then 'Calls in the browser are off (Program settings).' end);
end $$;

-- a call placed in the browser: the person, the customer and who they are (no own number needed)
create or replace function app.server_twilio_browser_call_start(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_to text := app.phone_e164(p ->> 'number');
  t phone_threads;
  v_booking uuid;
  c outbound_calls;
begin
  if not app.voice_staff_ok(v_user) then raise exception 'Sign in as staff first' using errcode = '42501'; end if;
  if not (app.settings()).phone_browser_calls then raise exception 'Calls in the browser are off (Program settings)' using errcode = '23514'; end if;
  if v_to is null then raise exception 'That is not a number we can call' using errcode = '22023'; end if;
  if v_to = app.phone_our_number() then raise exception 'That is the CarmaCars number itself' using errcode = '22023'; end if;
  t := app.phone_thread_for(v_to);
  select b.id into v_booking from bookings b where b.booking_number = upper(btrim(coalesce(p ->> 'booking_number', '')));
  insert into outbound_calls (staff_user_id, to_number, staff_number, thread_id, renter_id, owner_id, lead_id, booking_id, via)
  values (v_user, v_to, 'browser', t.id, t.renter_id, t.owner_id, t.lead_id, coalesce(v_booking, t.booking_id), 'browser')
  returning * into c;
  return jsonb_build_object('id', c.id, 'who', coalesce(t.name, case when app.user_sales_only(v_user) then app.phone_mask_display(v_to) else app.phone_display(v_to) end));
end $$;

-- what the client webhook needs: the customer's number, only for the staff member who started this browser call, recently
create or replace function app.server_twilio_browser_call_get(p_id uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', c.id, 'to', c.to_number, 'caller_id', app.phone_our_number(), 'record', (app.settings()).phone_twilio_record)
    from outbound_calls c
   where c.id = p_id and c.staff_user_id = p_user and c.via = 'browser' and c.status = 'starting' and c.created_at > now() - interval '10 minutes'
$$;

-- a call to the business number: whose browsers ring (online in the last 2 minutes, role rings), each shown the caller
-- as they may see them; and what happens when nobody answers
create or replace function app.server_voice_ring(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_from text := app.phone_e164(p ->> 'from');
  v_name text;
  v_ring jsonb;
begin
  if v_from is not null then select t.name into v_name from phone_threads t where t.number = v_from; end if;
  select coalesce(jsonb_agg(jsonb_build_object('identity', 'staff_' || replace(v.user_id::text, '-', ''),
           'who', coalesce(v_name, case when v_from is null then 'Unknown caller' when app.user_sales_only(v.user_id) then app.phone_mask_display(v_from) else app.phone_display(v_from) end))
           order by v.seen_at desc), '[]'::jsonb)
    into v_ring
    from (select vp.user_id, vp.seen_at from voice_presence vp
           where vp.online and vp.seen_at > now() - interval '2 minutes' and app.voice_staff_ok(vp.user_id) and app.voice_rings(vp.user_id)
           order by vp.seen_at desc limit 10) v;
  return jsonb_build_object('enabled', s.phone_browser_calls and btrim(s.phone_inbound_ring) <> '', 'ring', v_ring, 'seconds', s.phone_inbound_ring_seconds,
    'forward_to', nullif(s.phone_inbound_forward_number, ''), 'message', s.phone_inbound_message, 'caller_id', app.phone_our_number());
end $$;

create or replace function public.server_voice_settings() returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.server_voice_settings() $$;
create or replace function public.server_voice_presence(p_user uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_voice_presence(p_user, p) $$;
create or replace function public.server_twilio_browser_call_start(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_twilio_browser_call_start(p) $$;
create or replace function public.server_twilio_browser_call_get(p_id uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.server_twilio_browser_call_get(p_id, p_user) $$;
create or replace function public.server_voice_ring(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.server_voice_ring(p) $$;

-- ================================================================ 2. hiring
-- the owner: the AI decides by itself (Sales passes are hired; every other role books an interview, 2680)
update program_settings set hiring_ai_auto_decide = true where not hiring_ai_auto_decide;

-- the welcome note: no start date (it read as "you work tomorrow"); training, claiming shifts, the team chat and the tag
select pg_temp.patch_fn('app.hire_onboard_pre1067(uuid, jsonb)'::regprocedure,
  $o$format('Your start date is %s. Next: 1. Choose your password from the invitation email. 2. Sign your staff agreement in your portal. 3. Enter your pay details: %s 4. Start the academy: each section opens once the one before it is passed.',
                        to_char(v_start, 'FMDay, FMMonth FMDD'), app.hiring_url($o$,
  $n$format('You are not working a shift yet. Next: 1. Choose your password from the invitation email. 2. Sign your staff agreement in your portal. 3. Enter your pay details: %s 4. Do your training: the academy, each section opens once the one before it is passed. 5. Claim your shifts online in the portal. 6. Say hello in the team chat (the CarmaCars Team WhatsApp group, the link is in your portal) and set your member tag in each WhatsApp group as "Name - Position", for example "Maria - Sales".',
                        app.hiring_url($n$);
select pg_temp.patch_fn('app.hire_onboard_pre1067(uuid, jsonb)'::regprocedure,
  $o$(5, 'guide', 'First day: read your guide', 'Guide in your portal: the pages of your role, step by step.')) x(n, k, t, dt)$o$,
  $n$(5, 'guide', 'First day: read your guide', 'Guide in your portal: the pages of your role, step by step.'),
          (6, 'team', 'First day: say hello in the team chat', 'Post a hello in the CarmaCars Team WhatsApp group (the link is in your portal) and set your member tag in each WhatsApp group as "Name - Position", for example "Maria - Sales".')) x(n, k, t, dt)$n$);

-- ================================================================ 3. Sales reads only their own leads
create or replace function app.lead_is_mine(p_lead uuid, p_sourced_by uuid, p_assigned_to uuid, p_payload jsonb, p_outcome_by uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and (p_assigned_to = p_user or p_sourced_by = p_user or p_outcome_by = p_user or (p_payload ->> 'added_by') = p_user::text
         or exists (select 1 from lead_claims c where c.lead_id = p_lead and c.claimed_by = p_user and c.expires_at > now()))
$$;
comment on function app.lead_is_mine(uuid, uuid, uuid, jsonb, uuid, uuid) is '2790: the lead is this person''s: assigned to them, brought in or added by them, with their sale outcome, or claimed by them now (0950).';

drop policy if exists sales_own_only on leads;
create policy sales_own_only on leads as restrictive for select to authenticated
  using (not app.direct_read_masked() or app.lead_is_mine(id, sourced_by, assigned_to, payload, sales_outcome_by, app.uid()));
drop policy if exists sales_own_only_update on leads;
create policy sales_own_only_update on leads as restrictive for update to authenticated
  using (not app.direct_read_masked() or app.lead_is_mine(id, sourced_by, assigned_to, payload, sales_outcome_by, app.uid()))
  with check (not app.direct_read_masked() or app.lead_is_mine(id, sourced_by, assigned_to, payload, sales_outcome_by, app.uid()));

-- ================================================================ grants
revoke all on function app.voice_staff_ok(uuid), app.voice_rings(uuid), app.server_voice_settings(), app.server_voice_presence(uuid, jsonb),
                       app.server_twilio_browser_call_start(jsonb), app.server_twilio_browser_call_get(uuid, uuid), app.server_voice_ring(jsonb),
                       public.server_voice_settings(), public.server_voice_presence(uuid, jsonb), public.server_twilio_browser_call_start(jsonb),
                       public.server_twilio_browser_call_get(uuid, uuid), public.server_voice_ring(jsonb) from public, anon, authenticated;
grant execute on function app.voice_staff_ok(uuid), app.voice_rings(uuid), app.server_voice_settings(), app.server_voice_presence(uuid, jsonb),
                          app.server_twilio_browser_call_start(jsonb), app.server_twilio_browser_call_get(uuid, uuid), app.server_voice_ring(jsonb),
                          public.server_voice_settings(), public.server_voice_presence(uuid, jsonb), public.server_twilio_browser_call_start(jsonb),
                          public.server_twilio_browser_call_get(uuid, uuid), public.server_voice_ring(jsonb) to service_role;
-- the lead policy runs as the signed-in session
revoke all on function app.lead_is_mine(uuid, uuid, uuid, jsonb, uuid, uuid) from public, anon;
grant execute on function app.lead_is_mine(uuid, uuid, uuid, jsonb, uuid, uuid) to authenticated, service_role;
