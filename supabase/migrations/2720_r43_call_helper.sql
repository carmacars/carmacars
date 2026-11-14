-- 2720_r43_call_helper.sql
-- Release 43 (docs/changes/2026-11-12-r43-call-helper.md). The Call helper inside the caller pop-up (0800), for new hires:
-- a short greeting to read out, one button per situation with the steps to say and do, and a quick FAQ to search.
--   1. app.call_helper_items: the greetings (one per kind of caller), the situations (each line of the text is a step)
--      and the FAQ (question and answer). An Admin changes them in Settings > Call helper without a release; a row is
--      switched off, never lost; every change is in the audit log.
--   2. Tokens: {staff} (the first name of the person on the phone), {caller}, {booking} and {car} are filled in by the
--      pop-up from the call. The policy numbers are never typed into a script: {late_grace}, {deposit_tiers},
--      {km_per_day} and the others (app.call_helper_facts) are read from the Program settings, the fee defaults and the
--      deposit tiers each time the helper is read, so an answer changes the day the setting does.
--   3. Links: [Send an offer](/offers/new) is a page of the reader's own portal (/admin or /staff is put in front by the
--      pop-up); a full https:// address is allowed too. Nothing else.
--   4. Reads and actions through the door: call_helper (whoever has the caller pop-up: Admins, customer service and
--      Fleet), call_helper_admin, call_helper_save and call_helper_remove (an Admin).
-- No applied migration is edited: app.door is wrapped. Nothing in `public` changes, so the database types do not.
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

-- ================================================================ 1. the table
create table app.call_helper_items (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null check (kind in ('greeting', 'situation', 'faq')),
  code        text not null unique check (code ~ '^[a-z0-9_]{2,60}$'),
  title       text not null check (length(btrim(title)) between 2 and 120),
  body        text not null check (length(btrim(body)) between 2 and 4000),
  keywords    text not null default '' check (length(keywords) <= 400),
  sort_order  integer not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  updated_by  uuid references users (id) on delete set null
);
comment on table app.call_helper_items is 'The Call helper of the caller pop-up (2720): greetings (code greeting_<kind of caller>), situations (each line of body is a step) and FAQ (title is the question, body the answer). Edited by an Admin in Settings > Call helper.';
comment on column app.call_helper_items.body is 'Tokens in braces: {staff}, {caller}, {booking}, {car} from the call; the others from app.call_helper_facts (settings). Links: [words](/page of the portal) or [words](https://...).';
comment on column app.call_helper_items.keywords is 'More words the FAQ search finds this row by.';
create index call_helper_items_list on app.call_helper_items (kind, sort_order, title);
create trigger call_helper_items_updated before update on app.call_helper_items for each row execute function app.set_updated_at();
alter table app.call_helper_items enable row level security;
revoke all on app.call_helper_items from public, anon, authenticated;
grant all on app.call_helper_items to service_role;

-- ================================================================ 2. the facts (settings, never typed into a script)
create function app.call_helper_facts() returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  v_late fee_defaults;
  v_km fee_defaults;
  v_fuel fee_defaults;
  v_smoke fee_defaults;
  v_pet fee_defaults;
  v_tiers text;
  v_unset constant text := 'the amount set in Settings';
  pct text;
begin
  select * into v_late from fee_defaults d where d.fee_type_code = 'late_return_fee' and d.vehicle_class is null and d.effective_from <= app.local_date(now())
     and (d.effective_to is null or d.effective_to > app.local_date(now())) order by d.effective_from desc limit 1;
  select * into v_km from fee_defaults d where d.fee_type_code = 'mileage_overage' and d.vehicle_class is null and d.effective_from <= app.local_date(now())
     and (d.effective_to is null or d.effective_to > app.local_date(now())) order by d.effective_from desc limit 1;
  select * into v_fuel from fee_defaults d where d.fee_type_code = 'fuel' and d.vehicle_class is null and d.effective_from <= app.local_date(now())
     and (d.effective_to is null or d.effective_to > app.local_date(now())) order by d.effective_from desc limit 1;
  select * into v_smoke from fee_defaults d where d.fee_type_code = 'smoking' and d.vehicle_class is null and d.effective_from <= app.local_date(now())
     and (d.effective_to is null or d.effective_to > app.local_date(now())) order by d.effective_from desc limit 1;
  select * into v_pet from fee_defaults d where d.fee_type_code = 'pet_cleaning' and d.vehicle_class is null and d.effective_from <= app.local_date(now())
     and (d.effective_to is null or d.effective_to > app.local_date(now())) order by d.effective_from desc limit 1;
  -- "$500, $1,000 or $2,500"
  select case when count(*) = 0 then null when count(*) = 1 then max(x.t)
              else string_agg(x.t, ', ' order by x.n) filter (where x.n < x.total) || ' or ' || max(x.t) filter (where x.n = x.total) end into v_tiers
    from (select app.money_text(t.amount_cents) as t, row_number() over (order by t.amount_cents) as n, count(*) over () as total
            from deposit_tiers t where t.is_active) x;
  return jsonb_build_object(
    'min_age', coalesce(s.min_renter_age::text, v_unset),
    'offer_hours', coalesce(s.offer_expiry_hours::text, v_unset),
    'km_per_day', coalesce(s.default_km_allowance_per_day::text, v_unset),
    'extra_km', coalesce(app.money_text(v_km.amount_cents), v_unset),
    'late_grace', coalesce(v_late.grace_minutes || ' minutes', v_unset),
    'late_fee_hour', coalesce(app.money_text(v_late.amount_cents), v_unset),
    'late_fee_cap', coalesce(trim(trailing '.' from trim(trailing '0' from (v_late.percent_bps / 100.0)::numeric(10, 2)::text)) || '%', v_unset),
    'deposit_tiers', coalesce(v_tiers, v_unset),
    'deposit_release_days', coalesce(s.deposit_release_business_days::text, v_unset),
    'debit_deposit_times', coalesce(trim(trailing '.' from trim(trailing '0' from s.debit_deposit_multiplier::numeric(10, 2)::text)), v_unset),
    'cancel_day_one', coalesce(trim(trailing '.' from trim(trailing '0' from (s.cancel_refund_within_24h_of_booking_bps / 100.0)::numeric(10, 2)::text)) || '%', v_unset),
    'cancel_48h', coalesce(trim(trailing '.' from trim(trailing '0' from (s.cancel_refund_48h_plus_bps / 100.0)::numeric(10, 2)::text)) || '%', v_unset),
    'cancel_24_48h', coalesce(trim(trailing '.' from trim(trailing '0' from (s.cancel_refund_24_to_48h_bps / 100.0)::numeric(10, 2)::text)) || '%', v_unset),
    'cancel_under_24h', coalesce(trim(trailing '.' from trim(trailing '0' from (s.cancel_refund_under_24h_bps / 100.0)::numeric(10, 2)::text)) || '%', v_unset),
    'fuel_markup', coalesce(trim(trailing '.' from trim(trailing '0' from (v_fuel.percent_bps / 100.0)::numeric(10, 2)::text)) || '%', v_unset),
    'smoking_fee', coalesce(app.money_text(v_smoke.amount_cents), v_unset),
    'pet_fee', coalesce(app.money_text(v_pet.amount_cents), v_unset));
end $$;

-- where each fact comes from, for the Admin's page
create function app.call_helper_fact_sources() returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'min_age', 'Program settings: youngest renter', 'offer_hours', 'Program settings: hours an offer stays open',
    'km_per_day', 'Program settings: kilometres included a day', 'extra_km', 'Fee defaults: Mileage overage',
    'late_grace', 'Fee defaults: Late return fee, grace minutes', 'late_fee_hour', 'Fee defaults: Late return fee, amount',
    'late_fee_cap', 'Fee defaults: Late return fee, percentage of the daily rate', 'deposit_tiers', 'Deposit tiers',
    'deposit_release_days', 'Program settings: business days to release a deposit', 'debit_deposit_times', 'Program settings: deposit with a debit or prepaid card',
    'cancel_day_one', 'Program settings: refund within 24 hours of booking', 'cancel_48h', 'Program settings: refund 48 hours or more before the start',
    'cancel_24_48h', 'Program settings: refund 24 to 48 hours before the start', 'cancel_under_24h', 'Program settings: refund under 24 hours before the start',
    'fuel_markup', 'Fee defaults: Fuel, percentage', 'smoking_fee', 'Fee defaults: Smoking', 'pet_fee', 'Fee defaults: Pet cleaning')
$$;

create function app.call_helper_fill(p_text text, p_facts jsonb) returns text
language plpgsql immutable as $$
declare k text; v text;
begin
  for k, v in select * from jsonb_each_text(p_facts) loop
    p_text := replace(p_text, '{' || k || '}', v);
  end loop;
  return p_text;
end $$;

-- ================================================================ 3. what a text may hold
-- Every link is a page of the portal ([words](/bookings)) or an https address; every token is one the helper knows.
create function app.call_helper_problem(p_kind text, p_body text) returns text
language plpgsql stable security definer set search_path = public, app as $$
declare
  m text[];
  v_lines text[] := array(select btrim(l) from unnest(string_to_array(replace(coalesce(p_body, ''), E'\r', ''), E'\n')) l where btrim(l) <> '');
  v_known text[] := array['staff', 'caller', 'booking', 'car'] || array(select jsonb_object_keys(app.call_helper_fact_sources()));
begin
  if cardinality(v_lines) = 0 then return 'Write the text'; end if;
  if p_kind = 'situation' and cardinality(v_lines) > 8 then return 'Keep a situation to 8 steps at most, one step a line'; end if;
  if p_kind = 'situation' and exists (select 1 from unnest(v_lines) l where length(l) > 400) then return 'Keep each step under 400 characters'; end if;
  if p_kind = 'greeting' and length(btrim(p_body)) > 600 then return 'Keep a greeting under 600 characters: it is read out loud'; end if;
  for m in select regexp_matches(p_body, '\]\(([^)]*)\)', 'g') loop
    if m[1] !~ '^/[a-z0-9][a-z0-9/_?=&-]*$' and m[1] !~ '^https://[A-Za-z0-9.-]+(/[^\s()]*)?$' then
      return format('A link goes to a page of the portal, like (/bookings), or to an https address: %s', left(m[1], 80));
    end if;
  end loop;
  for m in select regexp_matches(p_body, '\{([^{}]*)\}', 'g') loop
    if not (m[1] = any (v_known)) then return format('{%s} is not a word the helper fills in', left(m[1], 40)); end if;
  end loop;
  return null;
end $$;

-- ================================================================ 4. reads
create function app.call_helper_staff_name(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(split_part(btrim(coalesce(u.full_name, '')), ' ', 1), ''), 'CarmaCars') from users u where u.id = p_user
$$;

-- the pop-up's read: what is on, in order, with the settings' numbers filled in
create function app.call_helper(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare f jsonb;
begin
  if not app.caller_popup_ok(p_by) then raise exception 'The call helper is for Admins, customer service and Fleet' using errcode = '42501'; end if;
  f := app.call_helper_facts();
  return jsonb_build_object(
    'staff', coalesce(app.call_helper_staff_name(p_by), 'CarmaCars'),
    'can_edit', app.user_is_admin(p_by),
    'greetings', coalesce((select jsonb_object_agg(substr(i.code, 10), app.call_helper_fill(i.body, f))
                             from app.call_helper_items i where i.kind = 'greeting' and i.is_active), '{}'::jsonb),
    'situations', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'title', i.title,
                               'steps', (select jsonb_agg(btrim(l) order by n) from unnest(string_to_array(replace(app.call_helper_fill(i.body, f), E'\r', ''), E'\n')) with ordinality x(l, n) where btrim(l) <> ''))
                             order by i.sort_order, i.title)
                             from app.call_helper_items i where i.kind = 'situation' and i.is_active), '[]'::jsonb),
    'faq', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'q', i.title, 'a', app.call_helper_fill(i.body, f), 'keywords', i.keywords) order by i.sort_order, i.title)
                       from app.call_helper_items i where i.kind = 'faq' and i.is_active), '[]'::jsonb));
end $$;

-- the Admin's page: every row as written, and the facts with their value now and where each comes from
create function app.call_helper_admin(p_admin uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare f jsonb;
begin
  perform app.assert_admin(p_admin);
  f := app.call_helper_facts();
  return jsonb_build_object(
    'items', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'kind', i.kind, 'code', i.code, 'title', i.title, 'body', i.body, 'keywords', i.keywords,
                          'sort_order', i.sort_order, 'is_active', i.is_active, 'updated_at', i.updated_at,
                          'updated_by', (select u.full_name from users u where u.id = i.updated_by), 'preview', app.call_helper_fill(i.body, f))
                          order by i.kind, i.sort_order, i.title) from app.call_helper_items i), '[]'::jsonb),
    'facts', (select jsonb_agg(jsonb_build_object('token', k.key, 'value', f ->> k.key, 'from', k.value) order by k.key) from jsonb_each_text(app.call_helper_fact_sources()) k));
end $$;

-- ================================================================ 5. actions (an Admin)
create function app.call_helper_save(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  r app.call_helper_items;
  b app.call_helper_items;
  v_kind text;
  v_title text;
  v_body text;
  v_problem text;
  v_code text;
begin
  perform app.assert_admin(p_admin);
  if v_id is not null then
    select * into r from app.call_helper_items where id = v_id for update;
    if r.id is null then raise exception 'That row is no longer there' using errcode = 'P0002'; end if;
    b := r;
    v_kind := r.kind;
  else
    v_kind := coalesce(p ->> 'kind', '');
    if v_kind not in ('situation', 'faq') then raise exception 'Add a situation or a question. The greetings are fixed: change their words instead' using errcode = '22023'; end if;
  end if;
  v_title := btrim(coalesce(p ->> 'title', r.title, ''));
  v_body := btrim(replace(coalesce(p ->> 'body', r.body, ''), E'\r', ''));
  if length(v_title) < 2 or length(v_title) > 120 then raise exception 'Give it a name of 2 to 120 characters' using errcode = '22023'; end if;
  if length(v_body) > 4000 then raise exception 'Keep the text under 4,000 characters' using errcode = '22023'; end if;
  v_problem := app.call_helper_problem(v_kind, v_body);
  if v_problem is not null then raise exception '%', v_problem using errcode = '22023'; end if;
  if length(coalesce(p ->> 'keywords', '')) > 400 then raise exception 'Keep the search words under 400 characters' using errcode = '22023'; end if;
  -- the greeting for a caller we do not know is the one every other falls back to
  if r.code = 'greeting_unknown' and p ? 'is_active' and not coalesce((p ->> 'is_active')::boolean, true) then
    raise exception 'The greeting for a caller we do not know stays on: the others fall back to it' using errcode = '23514';
  end if;
  if v_id is not null then
    update app.call_helper_items set title = v_title, body = v_body,
           keywords = case when p ? 'keywords' then btrim(coalesce(p ->> 'keywords', '')) else keywords end,
           sort_order = case when p ? 'sort_order' and p ->> 'sort_order' is not null then least(greatest((p ->> 'sort_order')::integer, 0), 9999) else sort_order end,
           is_active = case when p ? 'is_active' and p ->> 'is_active' is not null then (p ->> 'is_active')::boolean else is_active end,
           updated_by = p_admin
     where id = v_id returning * into r;
  else
    v_code := left(v_kind || '_' || btrim(regexp_replace(lower(v_title), '[^a-z0-9]+', '_', 'g'), '_'), 50);
    if exists (select 1 from app.call_helper_items where code = v_code) then v_code := left(v_code, 50) || '_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 6); end if;
    insert into app.call_helper_items (kind, code, title, body, keywords, sort_order, is_active, updated_by)
    values (v_kind, v_code, v_title, v_body, btrim(coalesce(p ->> 'keywords', '')),
            case when p ->> 'sort_order' is not null then least(greatest((p ->> 'sort_order')::integer, 0), 9999)
                 else (select coalesce(max(sort_order), 0) + 10 from app.call_helper_items where kind = v_kind) end,
            coalesce((p ->> 'is_active')::boolean, true), p_admin)
    returning * into r;
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_admin, case when v_id is null then 'call_helper_add' else 'call_helper_change' end, 'call_helper_items', r.id::text,
          case when v_id is null then null else jsonb_build_object('title', b.title, 'body', b.body, 'keywords', b.keywords, 'sort_order', b.sort_order, 'is_active', b.is_active) end,
          jsonb_build_object('kind', r.kind, 'code', r.code, 'title', r.title, 'body', r.body, 'keywords', r.keywords, 'sort_order', r.sort_order, 'is_active', r.is_active));
  return jsonb_build_object('ok', true, 'id', r.id, 'code', r.code);
end $$;

create function app.call_helper_remove(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare r app.call_helper_items;
begin
  perform app.assert_admin(p_admin);
  select * into r from app.call_helper_items where id = nullif(p ->> 'id', '')::uuid for update;
  if r.id is null then return jsonb_build_object('ok', true, 'already', true); end if;
  if r.kind = 'greeting' then raise exception 'A greeting is not removed: change its words, or switch it off' using errcode = '23514'; end if;
  delete from app.call_helper_items where id = r.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before)
  values (p_admin, 'call_helper_remove', 'call_helper_items', r.id::text, jsonb_build_object('kind', r.kind, 'code', r.code, 'title', r.title, 'body', r.body));
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 6. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2720;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call in ('admin_read', 'va_read', 'ops_read') and p_name = 'call_helper')
     or (p_call = 'admin_read' and p_name = 'call_helper_admin')
     or (p_call = 'admin_do' and p_name in ('call_helper_save', 'call_helper_remove')) then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    return case p_name
      when 'call_helper' then app.call_helper(p_user, p)
      when 'call_helper_admin' then app.call_helper_admin(p_user, p)
      when 'call_helper_save' then app.call_helper_save(p_user, p)
      else app.call_helper_remove(p_user, p) end;
  end if;
  return app.door_pre2720(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2720(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 7. the first scripts (from the staff guides; an Admin edits them)
insert into app.call_helper_items (kind, code, title, body, sort_order) values
('greeting', 'greeting_unknown', 'A caller we do not know',
 'Thank you for calling CarmaCars, this is {staff}, how can I help?', 10),
('greeting', 'greeting_renter_booking', 'A renter with a booking',
 'Thank you for calling CarmaCars, this is {staff}. Hi {caller}, are you calling about your booking {booking}? How can I help?', 20),
('greeting', 'greeting_renter', 'A renter with no booking now',
 'Thank you for calling CarmaCars, this is {staff}. Hi {caller}, good to hear from you again. How can I help?', 30),
('greeting', 'greeting_lead', 'A lead',
 'Thank you for calling CarmaCars, this is {staff}. Am I speaking with {caller}? How can I help?', 40),
('greeting', 'greeting_owner', 'A car owner',
 'Thank you for calling CarmaCars, this is {staff}. Hi {caller}, how can I help with your car today?', 50),
('greeting', 'greeting_staff', 'A staff member',
 'Hi {caller}, this is {staff}. How can I help?', 60);

insert into app.call_helper_items (kind, code, title, body, sort_order) values
('situation', 'situation_new_booking', 'New booking or price question',
 'Ask: which dates, which car or kind of car, pickup or delivery, and how old the driver is. Every driver must be {min_age} or older.
Open [Send an offer](/offers/new), find or add the customer, choose the car and the dates. Never quote from memory: this screen works out the rate, the fees, the deposit and the tax.
Say the total, the deposit and what is included: {km_per_day} km a day, then {extra_km} for each extra km unless the car''s rate says otherwise.
Send the offer by email, text or both while they are on the line. It stays open {offer_hours} hours unless you set another time.
Say: "You will get a link to review, sign and pay. Your booking is confirmed once it is paid."
Write a note about this call below.', 10),
('situation', 'situation_change_booking', 'Change or extend a booking',
 'Open their booking: it is linked at the top of this panel, or find it in [Bookings](/bookings).
To extend: while they have the car, the renter presses Extend in their own booking. It is approved at once when the car is free.
Another change (dates, times, another car): on the booking''s Changes tab set the change, write the reason, press Preview the price, then Send to the renter.
Say: "I have sent you the change. Please accept and sign it within 48 hours."
Write a note about this call below.', 20),
('situation', 'situation_late_return', 'Running late or late return',
 'Stay calm and friendly. Ask when they will be back and where the car is now.
Offer Extend first: they press Extend in their booking, it counts from the original return time, and paying it stops the late notices.
If they do not extend, say: after {late_grace} late there is a late return fee of {late_fee_hour} for each started hour, up to {late_fee_cap} of the daily rate for every 24 hours, plus the rental charge for each extra day.
Open the booking in [Bookings](/bookings). On its late return panel press Log a call and write what they said.
If the car is not coming back as planned, or they will not say when, tell an Admin now.', 30),
('situation', 'situation_pickup_delivery', 'Pick-up and delivery',
 'Open their booking in [Bookings](/bookings) and read them the pickup time and place.
Before the handover the booking needs four things: the licence checked, the agreement signed online, the rental paid and the deposit taken. The booking shows what is missing.
Delivery is priced by the distance to their address. The offer works it out: do not promise a delivery price before the offer shows it.
A new time or place: the booking''s Changes tab, write the reason, Preview the price, Send to the renter.
A pickup or a return within a day belongs to Fleet: write a note below so Fleet sees it.', 40),
('situation', 'situation_deposit_payments', 'Deposit and payments',
 'Look at Balance and Deposit at the top of this panel, then open the booking''s Money tab for what is paid and what is owed.
The deposit is a hold on the card, not a charge. It is {deposit_tiers} depending on the car, and the booking shows the amount.
With a debit or prepaid card the deposit is {debit_deposit_times} times the car''s deposit.
After the return it is released within {deposit_release_days} business days when nothing is owed. Tolls, fuel and damage are checked first.
A refund or a charge they do not agree with: do not promise anything. Write a note below and pass it to Finance or an Admin.', 50),
('situation', 'situation_insurance', 'Insurance and protection',
 'There are three ways to be covered: the CarmaCars Protection Plan, their own auto policy with OPCF 27, or a credit card that covers this car.
Credit card: check [Card coverage](/card-coverage) and send them carmacars.ca/credit-card-rental-coverage. Never tell a renter they are covered: their card''s issuer decides that.
OPCF 27: they upload the pink slip and the endorsement page. It is approved only with both.
To change it on a booking: the Protection card at the top of the booking, Change protection, pick the option and write the reason.
If the rule says no, ask an Admin. Only an Admin can override it, with a reason.', 60),
('situation', 'situation_accident_damage', 'Accident or damage',
 'First ask: "Is everyone safe?" If anyone is hurt or in danger, tell them to call 911 now.
Ask where they are, what happened, and whether the car can be driven. Ask them to take photos.
Open their booking in [Bookings](/bookings) and press Open an incident. Write down everything they said.
Tell Fleet and an Admin at once.
Do not say who pays. The rental agreement and the protection on the booking decide that.', 70),
('situation', 'situation_complaint', 'Complaint',
 'Let them finish. Then say: "I am sorry about that. Let me make sure I have it right."
Say the problem back to them in your own words, and open their booking or their page from this panel.
Fix what you can now.
Do not promise a refund or a credit. Say: "I will pass this to my manager today and we will call you back."
Write a full note below: what happened and what they want. Then tell an Admin.', 80),
('situation', 'situation_owner_listing', 'Owner wants to list a car',
 'Say: "Great, tell me about your car." Ask the year, the make and model, the kilometres and where the car is.
Send them carmacars.ca/list-your-car to apply, or enter the car for them in [Add a car for an owner](/owners/add-car).
Do not promise earnings or terms. An Admin checks each car and sends the terms to sign.
If this caller is not on file, press Create lead on this panel.', 90),
('situation', 'situation_job_applicant', 'Job applicant',
 'Thank them for their interest and ask which job they are calling about.
Every application is made online: send them to carmacars.ca/careers. We do not take applications on the phone.
Already applied? Say each application is read and answered by email. Do not promise an interview or a date.
An Admin follows up in [Hiring](/hiring).', 100);

insert into app.call_helper_items (kind, code, title, body, keywords, sort_order) values
('faq', 'faq_age', 'How old do I have to be to rent?',
 'Every driver must be {min_age} or older at pickup. A young driver fee applies to drivers aged 18 to 25, and the offer adds it. Drivers aged 18 to 20 can rent only the cars that allow it.', 'age young driver minimum 18 21 25', 10),
('faq', 'faq_need', 'What do I need to rent a car?',
 'A valid driver''s licence, checked before pickup. The rental agreement is signed online. The rental is paid and the deposit is taken before the handover.', 'documents licence license requirements bring id', 20),
('faq', 'faq_deposit', 'How much is the deposit?',
 'The deposit is a hold on the card, not a charge: {deposit_tiers} depending on the car. With a debit or prepaid card it is {debit_deposit_times} times the car''s deposit. The offer shows the amount.', 'security hold debit prepaid card', 30),
('faq', 'faq_deposit_back', 'When do I get my deposit back?',
 'Within {deposit_release_days} business days after the return, when nothing is owed. Tolls, fuel and damage are checked first. A hold can take a few more days to leave the card, which depends on the bank.', 'release refund hold returned', 40),
('faq', 'faq_km', 'How many kilometres are included?',
 '{km_per_day} km a day unless the car''s rate says otherwise. Each extra km is {extra_km}; luxury and exotic cars can have their own rate. The offer shows both.', 'mileage km distance unlimited overage', 50),
('faq', 'faq_late', 'What happens if I return the car late?',
 'Nothing up to {late_grace} late. After that the late return fee is {late_fee_hour} for each started hour, up to {late_fee_cap} of the daily rate for every 24 hours, plus the rental charge for each extra day. Extending the booking first avoids it.', 'late return fee grace overdue', 60),
('faq', 'faq_extend', 'Can I keep the car longer?',
 'Yes, while the car is free. The renter presses Extend in their booking. It is approved at once when the car is free, and it counts from the original return time.', 'extend extension longer more days', 70),
('faq', 'faq_cancel', 'What is the cancellation policy?',
 'Cancelled 48 hours or more before the start: {cancel_48h} of what was paid is refunded ({cancel_day_one} when it is also within 24 hours of booking). 24 to 48 hours before: {cancel_24_48h}. Under 24 hours before, or after the start: {cancel_under_24h}. A booking with the non-refundable discount is not refunded. The policy is at carmacars.ca/cancellation-policy.', 'cancel refund cancellation non-refundable', 80),
('faq', 'faq_delivery', 'Do you deliver the car?',
 'Yes. Delivery is priced by the distance to the address, and airports have their own charge. The offer works out the price: do not promise one before the offer shows it.', 'delivery deliver airport drop off pick up collection', 90),
('faq', 'faq_debit', 'Can I pay with a debit card?',
 'Yes. With a debit or prepaid card the deposit is {debit_deposit_times} times the car''s deposit. Credit card coverage needs a credit card that covers the car.', 'debit prepaid visa debit payment', 100),
('faq', 'faq_driver', 'Can someone else drive the car?',
 'Only a driver who is on the booking. Add the additional driver on the booking and send them the signing link. An additional driver fee applies, and the offer shows it.', 'additional second driver spouse friend', 110),
('faq', 'faq_insurance', 'Do I need my own insurance?',
 'Every rental needs one of three: the CarmaCars Protection Plan, the renter''s own auto policy with OPCF 27, or a credit card that covers this car. Never tell a renter they are covered by a card: the issuer decides.', 'insurance protection plan opcf 27 coverage credit card', 120),
('faq', 'faq_fuel', 'What about fuel?',
 'Return the car with the same fuel as at pickup. Missing fuel is charged at the pump price plus {fuel_markup}, and a service fee can apply. An electric car is charged for the missing charge the same way.', 'gas fuel refuel tank electric charge', 130),
('faq', 'faq_smoking_pets', 'Can I smoke or bring a pet?',
 'No smoking in any car: the smoking fee is {smoking_fee}. Pets are the renter''s responsibility: pet cleaning is {pet_fee} when the car comes back with hair or odour.', 'smoke smoking vape pet dog cat cleaning', 140),
('faq', 'faq_tolls', 'How do tolls and tickets work?',
 'Tolls, tickets and fines during the rental are the renter''s. We bill the amount plus an administration fee after the notice arrives, which can be weeks after the return.', 'toll 407 ticket fine parking', 150),
('faq', 'faq_rideshare', 'Can I use the car for rideshare or delivery work?',
 'Yes, with the rideshare documents the renter completes on their booking. Tell them to open their booking and follow the steps there.', 'uber lyft rideshare delivery doordash work', 160);

-- every seeded text passes the same check a change by an Admin does
do $$
declare r record; v text;
begin
  for r in select code, kind, body from app.call_helper_items loop
    v := app.call_helper_problem(r.kind, r.body);
    if v is not null then raise exception 'call helper seed %: %', r.code, v; end if;
  end loop;
end $$;

-- ================================================================ 8. privileges: the server only
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['call_helper_facts', 'call_helper_fact_sources', 'call_helper_fill', 'call_helper_problem', 'call_helper_staff_name',
             'call_helper', 'call_helper_admin', 'call_helper_save', 'call_helper_remove', 'door_pre2720'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
