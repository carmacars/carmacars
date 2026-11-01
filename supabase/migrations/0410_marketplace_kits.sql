-- 0410: Facebook Marketplace kits, the posting schedule, the Marketplace log and "How did you hear about us?". SCHEMA_MARKER 0410.
-- docs/changes/2026-11-06-marketplace-kits.md; docs/runbooks/marketplace.md (the playbook Claude follows in the owner's Chrome).
-- The owner's decision (October 24, 2026): Meta's own Marketplace auto-replies, plus Claude posting the listings and answering
-- the Marketplace inbox through the owner's Chrome, from his personal profile (business Pages cannot post vehicles there).
--   1. Settings: marketplace_posts_per_day (4: a light rotation of 3 to 5 a day avoids spam flags), marketplace_renew_days (7:
--      renew a listing a week after it was posted or last renewed), marketplace_location (the town the listing shows when the
--      car's own home area is not set).
--   2. ad_postings.renewed_on: when the live Marketplace ad was last renewed. The kit itself is computed when the page opens from
--      the car's record (app.ads_facts of 0167), so it always carries today's prices; a live ad whose prices changed is marked
--      needs_update by 0167's rate-change check, and the schedule puts it first.
--   3. marketplace_log: what was posted, renewed, updated or taken down, and each inbox session (conversations, replies, numbers
--      collected), written from Admin > Marketing > Marketplace (by Claude in Chrome in the owner's session, or by a person).
--      A number collected from the inbox becomes a lead (kind contact, source fb_marketplace, the car's code as campaign) with a
--      call-back task for customer service within 15 minutes (task marketplace_callback).
--   4. bookings.heard_about: the renter's answer to "How did you hear about us?" on the booking request (optional). The report of
--      bookings by channel counts it after staff's source and a tracked visit, before a referral code (app.booking_channel).
--   5. The door: admin_read 'marketplace'; admin_do 'marketplace_log', 'marketplace_inbox', 'marketplace_settings';
--      public.server_booking_heard_about (the request form, service role).
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

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists marketplace_posts_per_day integer not null default 4 check (marketplace_posts_per_day between 1 and 10),
  add column if not exists marketplace_renew_days integer not null default 7 check (marketplace_renew_days between 2 and 60),
  add column if not exists marketplace_location text not null default 'Toronto, Ontario' check (length(btrim(marketplace_location)) between 2 and 80);
comment on column program_settings.marketplace_posts_per_day is 'Marketplace (0410): new posts and renewals a day on the schedule (3 to 5 avoids spam flags); price updates and take-downs do not count.';
comment on column program_settings.marketplace_renew_days is 'Marketplace (0410): renew a live listing this many days after it was posted or last renewed.';
comment on column program_settings.marketplace_location is 'Marketplace (0410): the listing''s location when the car has no home area.';

-- ================================================================ 2. the live ad's renewal
alter table ad_postings add column if not exists renewed_on date;
comment on column ad_postings.renewed_on is 'Marketplace (0410): the day the live ad was last renewed on Facebook Marketplace.';

-- ================================================================ 3. the Marketplace log
create table if not exists marketplace_log (
  id             uuid primary key default gen_random_uuid(),
  at             timestamptz not null default now(),
  on_date        date not null default app.today(),
  kind           text not null check (kind in ('posted', 'renewed', 'updated', 'removed', 'inbox')),
  vehicle_id     uuid references vehicles (id) on delete set null,
  posting_id     uuid references ad_postings (id) on delete set null,
  conversations  integer check (conversations is null or conversations between 0 and 5000),
  replies        integer check (replies is null or replies between 0 and 5000),
  numbers        integer check (numbers is null or numbers between 0 and 500),
  note           text check (note is null or length(note) <= 1000),
  logged_by      uuid references users (id) on delete set null,
  check (kind = 'inbox' or vehicle_id is not null),
  check (kind <> 'inbox' or conversations is not null)
);
create index if not exists marketplace_log_day_idx on marketplace_log (on_date desc, at desc);
create index if not exists marketplace_log_vehicle_idx on marketplace_log (vehicle_id, at desc);
comment on table marketplace_log is 'Marketplace (0410): what was posted, renewed, updated or taken down on Facebook Marketplace, and each inbox session, from Admin > Marketing > Marketplace.';

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('marketplace_callback', 'cs', 'Call back a Marketplace lead', 'high', 'minutes', 15, null, null,
   'Someone on Facebook Marketplace gave their number for a call about a car: call them, answer, and send them to request on carmacars.ca or send an offer (0410)')
on conflict (task_type) do nothing;

-- ================================================================ 4. "How did you hear about us?"
create or replace function app.heard_about_options() returns text[]
language sql immutable as $$ select array['fb_marketplace', 'instagram', 'tiktok', 'facebook', 'google', 'kijiji', 'word_of_mouth', 'repeat', 'other'] $$;

alter table bookings add column if not exists heard_about text check (heard_about is null or heard_about = any (app.heard_about_options()));
comment on column bookings.heard_about is 'Marketplace (0410): the renter''s answer to "How did you hear about us?" on the booking request.';

-- the labels of 0167, with TikTok (an answer to "How did you hear about us?")
create or replace function app.ad_channel_label(p text) returns text
language sql immutable as $$
  select case p
    when 'fb_marketplace' then 'Facebook Marketplace' when 'kijiji' then 'Kijiji' when 'craigslist' then 'Craigslist'
    when 'instagram' then 'Instagram' when 'facebook_page' then 'Facebook Page' when 'google_business' then 'Google Business Profile'
    when 'facebook' then 'Facebook (other)' when 'google' then 'Google search' when 'bing' then 'Bing' when 'tiktok' then 'TikTok'
    when 'other_site' then 'Another website' when 'direct' then 'Direct (typed or bookmarked)' when 'referral' then 'Referral code'
    when 'phone' then 'Phone call' when 'email' then 'Email' when 'whatsapp' then 'WhatsApp' when 'walk_in' then 'Walk-in'
    when 'repeat' then 'Returning renter' when 'word_of_mouth' then 'Word of mouth' when 'turo' then 'Turo'
    when 'other' then 'Other' else 'Not known' end
$$;

-- The channel a booking counts under (0167, with 0410's answer): staff's source, then the visit (first or last touch) unless
-- direct, then the renter's "How did you hear about us?", then a referral code, then how the request reached us (phone, email,
-- WhatsApp), then direct, else not known.
create or replace function app.booking_channel(b bookings, a booking_attribution, p_model text default 'last') returns text
language sql immutable as $$
  select coalesce(b.marketing_source,
    nullif(case when p_model = 'first' then a.first_channel else a.last_channel end, 'direct'),
    b.heard_about,
    case when b.referral_partner_id is not null or b.referrer_type is not null then 'referral' end,
    case when b.source in ('phone', 'email', 'whatsapp') then b.source end,
    case when p_model = 'first' then a.first_channel else a.last_channel end,
    'unknown')
$$;

-- The request form's answer, right after submit_booking_request (as server_request_notify_channel of 0096): only a request
-- made in the last hour, and only once.
create or replace function public.server_booking_heard_about(p_booking_number text, p_value text) returns boolean
language plpgsql security definer set search_path = public, app as $$
declare
  v text := nullif(btrim(coalesce(p_value, '')), '');
  n integer;
begin
  if v is null then return false; end if;
  if not v = any (app.heard_about_options()) then raise exception 'Choose how you heard about us from the list' using errcode = '22023'; end if;
  update bookings set heard_about = v
   where booking_number = p_booking_number and heard_about is null and created_at > now() - interval '1 hour';
  get diagnostics n = row_count;
  return n > 0;
end $$;
revoke all on function public.server_booking_heard_about(text, text) from public, anon, authenticated;
grant execute on function public.server_booking_heard_about(text, text) to service_role;

-- ================================================================ 5. the Admin page
-- The kit's facts (0167's ads_facts), the extra facts a Marketplace vehicle listing asks for, the live and past Marketplace
-- ads, today's log and the settings. The kit text and the schedule are written by web/src/features/marketplace/.
create or replace function app.marketplace_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings;
begin
  perform app.assert_admin(p_by);
  select * into s from program_settings limit 1;
  return app.ads_facts() || jsonb_build_object(
    'settings', jsonb_build_object('posts_per_day', s.marketplace_posts_per_day, 'renew_days', s.marketplace_renew_days, 'location', s.marketplace_location),
    'phone', (select coalesce(ss.phone_display, ss.phone) from site_settings ss limit 1),
    'extra', coalesce((select jsonb_object_agg(v.id::text, jsonb_build_object(
        'odometer_km', greatest(coalesce(v.odometer_km, 0), coalesce((select max(r.km) from vehicle_odometer_readings r where r.vehicle_id = v.id and r.voided_at is null), 0)),
        'home_area', nullif(btrim(coalesce(l.home_area, '')), ''), 'supply', v.supply_type, 'drivetrain', l.drivetrain, 'doors', l.doors))
      from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.retired_at is null and l.slug is not null), '{}'::jsonb),
    'postings', coalesce((select jsonb_agg(app.ad_posting_row(a) || jsonb_build_object('renewed_on', a.renewed_on) order by a.posted_on desc)
      from ad_postings a where a.channel = 'fb_marketplace' and (a.status = 'live' or a.removed_on > app.today() - 30)), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'at', m.at, 'on_date', m.on_date, 'kind', m.kind, 'vehicle_id', m.vehicle_id,
        'car', case when m.vehicle_id is not null then app.vehicle_name(m.vehicle_id) end, 'conversations', m.conversations, 'replies', m.replies,
        'numbers', m.numbers, 'note', m.note, 'by', (select full_name from users where id = m.logged_by)) order by m.at desc)
      from (select * from marketplace_log order by at desc limit 40) m), '[]'::jsonb),
    'done_today', (select count(*) from marketplace_log where on_date = app.today() and kind in ('posted', 'renewed')),
    'week', (select jsonb_build_object('posted', count(*) filter (where kind = 'posted'), 'renewed', count(*) filter (where kind = 'renewed'),
        'conversations', coalesce(sum(conversations), 0), 'replies', coalesce(sum(replies), 0), 'numbers', coalesce(sum(numbers), 0))
      from marketplace_log where on_date > app.today() - 7),
    'leads_30', (select count(*) from leads where source = 'fb_marketplace' and created_at > now() - interval '30 days'),
    'requests_30', (select count(*) from bookings b left join booking_attribution a on a.booking_id = b.id
      where b.booking_type <> 'owner' and coalesce(b.requested_at, b.created_at) > now() - interval '30 days' and app.booking_channel(b, a, 'last') = 'fb_marketplace'));
end $$;

-- Record a Marketplace post, renewal, update or take-down. p: {kind: posted | renewed | updated | removed, vehicle, url,
-- on_date, title, body, price_line, note}. Posted and updated go through 0167's ad_posting_save (one live ad per car), so a
-- later price change opens its update task as for every channel.
create or replace function app.marketplace_log_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := p ->> 'kind';
  v_vehicle uuid := nullif(p ->> 'vehicle', '')::uuid;
  v_on date := coalesce(nullif(p ->> 'on_date', '')::date, app.today());
  v_note text := nullif(btrim(coalesce(p ->> 'note', '')), '');
  a ad_postings;
  r jsonb;
begin
  perform app.assert_admin(p_by);
  if v_kind is null or v_kind not in ('posted', 'renewed', 'updated', 'removed') then raise exception 'Say what was done: posted, renewed, updated or taken down' using errcode = '22023'; end if;
  if v_vehicle is null or not exists (select 1 from vehicles where id = v_vehicle) then raise exception 'Choose the car' using errcode = '22023'; end if;
  if v_on > app.today() then raise exception 'The date cannot be in the future' using errcode = '22023'; end if;
  select * into a from ad_postings where vehicle_id = v_vehicle and channel = 'fb_marketplace' and status = 'live' for update;
  if v_kind in ('renewed', 'updated', 'removed') and a.id is null then
    raise exception 'This car has no live Marketplace ad here: record it as posted first' using errcode = '22023';
  end if;
  if v_kind = 'posted' and a.id is not null and a.url is not null and nullif(btrim(coalesce(p ->> 'url', '')), '') <> a.url then
    -- a new listing of a car that already had one (the old one was deleted on Facebook): the old ad ends here
    perform app.ad_posting_remove(p_by, jsonb_build_object('id', a.id, 'reason', 'Posted again as a new listing'));
    a := null;
  end if;
  if v_kind in ('posted', 'updated') then
    r := app.ad_posting_save(p_by, jsonb_build_object('vehicle', v_vehicle, 'channel', 'fb_marketplace', 'url', p ->> 'url', 'posted_on', v_on,
      'title', p ->> 'title', 'body', p ->> 'body', 'price_line', p ->> 'price_line', 'note', v_note));
    select * into a from ad_postings where id = (r ->> 'id')::uuid;
    if v_kind = 'posted' and a.renewed_on is null then update ad_postings set renewed_on = v_on where id = a.id returning * into a; end if;
  elsif v_kind = 'renewed' then
    update ad_postings set renewed_on = v_on, url = coalesce(nullif(btrim(coalesce(p ->> 'url', '')), ''), url) where id = a.id returning * into a;
  else
    r := app.ad_posting_remove(p_by, jsonb_build_object('id', a.id, 'reason', coalesce(v_note, 'Taken down from Marketplace')));
  end if;
  insert into marketplace_log (on_date, kind, vehicle_id, posting_id, note, logged_by) values (v_on, v_kind, v_vehicle, a.id, v_note, p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'marketplace_log', 'ad_postings', a.id::text, p - 'body');
  return jsonb_build_object('kind', v_kind, 'posting', app.ad_posting_row((select x from ad_postings x where x.id = a.id)) || jsonb_build_object('renewed_on', (select renewed_on from ad_postings where id = a.id)));
end $$;

-- An inbox session: how many conversations were answered, and every phone number collected (each a lead with a call-back
-- task). p: {conversations, replies, note, leads: [{name, phone, vehicle, message}]}
create or replace function app.marketplace_inbox_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_conv integer := nullif(p ->> 'conversations', '')::integer;
  v_rep integer := coalesce(nullif(p ->> 'replies', '')::integer, v_conv);
  x jsonb;
  v_phone text;
  v_vehicle uuid;
  v_code text;
  v_car text;
  v_lead uuid;
  v_new integer := 0;
  v_ids uuid[] := '{}';
begin
  perform app.assert_admin(p_by);
  if v_conv is null or v_conv < 0 then raise exception 'Say how many conversations were answered (0 or more)' using errcode = '22023'; end if;
  -- the numbers typed one per line ("Sam, 416 555 0142, CC-7F3A"): the phone number, the car code if any, the rest is the name
  if btrim(coalesce(p ->> 'numbers_text', '')) <> '' then
    p := jsonb_set(p, '{leads}', coalesce(p -> 'leads', '[]'::jsonb) || coalesce((
      select jsonb_agg(jsonb_build_object('phone', coalesce(ph, line), 'name', nullif(btrim(regexp_replace(replace(replace(line, coalesce(ph, ''), ''), coalesce(cc, ''), ''), '^[\s,;:|-]+|[\s,;:|-]+$', '', 'g')), ''),
               'vehicle', (select v.id from vehicles v where cc is not null and regexp_replace(upper(v.car_code), '[^A-Z0-9]', '', 'g') = regexp_replace(upper(cc), '[^A-Z0-9]', '', 'g') limit 1))
             order by n)
        from (select btrim(l) as line, n, substring(l from '(\+?1?[\s.-]?\(?[2-9][0-9]{2}\)?[\s.-]?[0-9]{3}[\s.-]?[0-9]{4})') as ph, substring(l from '(?i)(\mCC-?[A-Z0-9]{3,8}\M)') as cc
                from regexp_split_to_table(p ->> 'numbers_text', '\r?\n') with ordinality t(l, n) where btrim(l) <> '') x), '[]'::jsonb));
  end if;
  if jsonb_typeof(coalesce(p -> 'leads', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p -> 'leads', '[]'::jsonb)) > 100 then
    raise exception 'The numbers collected must be a list of at most 100' using errcode = '22023';
  end if;
  for x in select * from jsonb_array_elements(coalesce(p -> 'leads', '[]'::jsonb)) loop
    v_phone := app.phone_e164(x ->> 'phone');
    if v_phone is null then raise exception 'Not a phone number: %', coalesce(x ->> 'phone', '(empty)') using errcode = '22023'; end if;
    v_vehicle := nullif(x ->> 'vehicle', '')::uuid;
    if v_vehicle is not null and not exists (select 1 from vehicles where id = v_vehicle) then v_vehicle := null; end if;
    v_code := (select car_code from vehicles where id = v_vehicle);
    v_car := case when v_vehicle is not null then app.vehicle_name(v_vehicle) end;
    -- the same number from Marketplace in the last 30 days is the same lead
    select id into v_lead from leads where source = 'fb_marketplace' and phone = v_phone and created_at > now() - interval '30 days' order by created_at desc limit 1;
    if v_lead is null then
      insert into leads (kind, name, phone, message, payload, source, utm_source, utm_medium, utm_campaign)
      values ('contact', nullif(btrim(coalesce(x ->> 'name', '')), ''), v_phone,
              left(concat_ws(' ', 'Facebook Marketplace:', case when v_car is not null then 'asked about the ' || v_car || coalesce(' (' || v_code || ')', '') || '.' end,
                             nullif(btrim(coalesce(x ->> 'message', '')), ''), 'Gave their number for a call.'), 2000),
              jsonb_build_object('vehicle_id', v_vehicle, 'car', v_car, 'car_code', v_code, 'via', 'marketplace_inbox'),
              'fb_marketplace', 'fb_marketplace', 'marketplace', coalesce(v_code, 'inbox'))
      returning id into v_lead;
      v_new := v_new + 1;
      perform app.raise_task(p_type => 'marketplace_callback', p_title => 'Call back ' || coalesce(nullif(btrim(coalesce(x ->> 'name', '')), ''), 'a Marketplace lead')
                             || coalesce(' about the ' || v_car, ''),
                             p_detail => concat_ws(' ', 'Number:', v_phone || '.', case when v_car is not null then 'Car: ' || v_car || coalesce(' (' || v_code || ')', '') || '.' end,
                               nullif(btrim(coalesce(x ->> 'message', '')), ''), 'They asked on Facebook Marketplace and gave their number for a call. Answer, then send them to request on carmacars.ca or send an offer.'),
                             p_vehicle => v_vehicle, p_related_table => 'leads', p_related_id => v_lead, p_dedupe => 'mpcall:' || v_lead);
    end if;
    v_ids := v_ids || v_lead;
  end loop;
  insert into marketplace_log (kind, conversations, replies, numbers, note, logged_by)
  values ('inbox', v_conv, v_rep, coalesce(array_length(v_ids, 1), 0), nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by);
  return jsonb_build_object('conversations', v_conv, 'numbers', coalesce(array_length(v_ids, 1), 0), 'new_leads', v_new, 'leads', to_jsonb(v_ids));
end $$;

create or replace function app.marketplace_settings_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings;
begin
  perform app.assert_admin(p_by);
  update program_settings set
    marketplace_posts_per_day = coalesce(nullif(p ->> 'posts_per_day', '')::integer, marketplace_posts_per_day),
    marketplace_renew_days = coalesce(nullif(p ->> 'renew_days', '')::integer, marketplace_renew_days),
    marketplace_location = coalesce(nullif(btrim(coalesce(p ->> 'location', '')), ''), marketplace_location)
  where true returning * into s;
  insert into audit_log (actor_user_id, action, entity_table, after) values (p_by, 'marketplace_settings', 'program_settings', p);
  return jsonb_build_object('posts_per_day', s.marketplace_posts_per_day, 'renew_days', s.marketplace_renew_days, 'location', s.marketplace_location);
end $$;

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0410;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'marketplace' then
    perform app.door_begin(p_user, p_aal);
    return app.marketplace_read(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'admin_do' and p_name = 'marketplace_log' then
    perform app.door_begin(p_user, p_aal);
    return app.marketplace_log_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'admin_do' and p_name = 'marketplace_inbox' then
    perform app.door_begin(p_user, p_aal);
    return app.marketplace_inbox_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  if p_call = 'admin_do' and p_name = 'marketplace_settings' then
    perform app.door_begin(p_user, p_aal);
    return app.marketplace_settings_save(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre0410(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0410(uuid, text, text, text, jsonb)'::regprocedure);

alter table marketplace_log enable row level security;
revoke all on marketplace_log from anon, authenticated;
grant all on marketplace_log to service_role;
drop policy if exists admin_all on marketplace_log;
create policy admin_all on marketplace_log for all to authenticated using (app.is_admin()) with check (app.is_admin());
drop trigger if exists audit_marketplace_log on marketplace_log;
create trigger audit_marketplace_log after insert or update or delete on marketplace_log for each row execute function app.audit_row();

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('marketplace_read', 'marketplace_log_save', 'marketplace_inbox_save', 'marketplace_settings_save', 'door_pre0410') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
