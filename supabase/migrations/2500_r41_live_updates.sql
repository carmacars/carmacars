-- 2500_r41_live_updates.sql
-- Release 41 (the owner, Nov 12: "I need real time ... currently not everything is loading right away"). The portals'
-- key screens update within about two seconds of a change made elsewhere, without a reload
-- (web/src/features/live/realtime/hub.ts). The database keeps a version per "topic" and bumps it when a row behind it
-- changes; a screen watches the topics the server gave it (server_live_topics) by reading their versions
-- (live_poll, from the browser straight to the database API, never the Worker) and, when Supabase Realtime runs, by
-- listening on a public broadcast channel of the same name (realtime.send at commit; skipped while Realtime is not
-- installed). No data travels this way: a bump only tells the screen to read again through the usual checked reads.
--
-- Topics: 'staff:<area>' (bookings, requests, leads, messages, field), 'booking:<id>', 'renter:<user>', 'owner:<user>',
-- 'user:<user>' (the person's alerts and messages). The names handed out are keyed hashes of these (app.live_topic, a
-- random key kept in app.live_key), so a topic cannot be guessed and a version cannot be read without the name.
-- server_live_topics hands a name out only for what the person may read: staff areas to Admin and office staff (field
-- staff: the field area), a booking to staff or to its renter, drivers or owner, the person's own topics to them.
--
-- How a bump is made: an AFTER ... FOR EACH STATEMENT trigger (transition tables) on each watched table adds the
-- statement's topics to a transaction-local list (carmacars.live_pending) and marks the transaction once
-- (app.live_flush); a deferred constraint trigger on that mark bumps every topic at commit, in sorted order, so the row
-- lock is held for an instant and two transactions never wait on each other in a cycle. It never fails a commit.
-- No applied migration is edited.

-- ================================================================ 1. the key, the versions, the commit mark
create table app.live_key (
  only_one boolean primary key default true check (only_one),
  k bytea not null
);
insert into app.live_key (k)
select decode(replace(gen_random_uuid()::text || gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'hex');

create table app.live_versions (
  topic text primary key,
  ver bigint not null default 1,
  at timestamptz not null default now()
);
comment on table app.live_versions is 'Live updates (2500): the version of each topic (a keyed hash of its scope); bumped at commit by app.live_commit.';

create table app.live_flush (
  tx bigint primary key
);
comment on table app.live_flush is 'Live updates (2500): one row while a transaction has topics to bump; its deferred trigger bumps them at commit and removes it.';

alter table app.live_key enable row level security;
alter table app.live_versions enable row level security;
alter table app.live_flush enable row level security;
revoke all on app.live_key, app.live_versions, app.live_flush from public, anon, authenticated;

-- ================================================================ 2. names
create function app.live_topic(p_scope text) returns text
language sql stable security definer set search_path = public, app as $$
  select substr(encode(sha256((select k from app.live_key) || convert_to(p_scope, 'UTF8')), 'hex'), 1, 32)
$$;
revoke all on function app.live_topic(text) from public, anon, authenticated;

-- ================================================================ 3. collecting and bumping
-- adds scopes to the transaction's list (duplicates once; the list stops growing past 16 000 characters: the staff
-- areas still bump, a very large statement's single bookings do not)
create function app.live_add(p_scopes text[]) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v text := coalesce(current_setting('carmacars.live_pending', true), '');
  s text;
  added boolean := false;
begin
  foreach s in array coalesce(p_scopes, '{}') loop
    continue when s is null or s = '' or position(('|' || s || '|') in ('|' || v || '|')) > 0;
    continue when length(v) > 16000 and s not like 'staff:%';
    v := case when v = '' then s else v || '|' || s end;
    added := true;
  end loop;
  if not added then return; end if;
  perform set_config('carmacars.live_pending', v, true);
  insert into app.live_flush (tx) values (txid_current()) on conflict do nothing;
end $$;
revoke all on function app.live_add(text[]) from public, anon, authenticated;

-- the statement trigger: TG_ARGV = area ('-' for none), the booking column ('-'), the user column ('-')
create function app.live_rows() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_area text := tg_argv[0];
  v_booking text := tg_argv[1];
  v_user text := tg_argv[2];
  v_rel text := case when tg_op = 'DELETE' then 'live_old' else 'live_new' end;
  v_bookings uuid[];
  v_users uuid[];
  v_scopes text[] := '{}';
  n int;
begin
  begin
    execute format('select count(*) from %I', v_rel) into n;
    if n = 0 then return null; end if;
    if v_area <> '-' then v_scopes := v_scopes || ('staff:' || v_area); end if;
    if v_booking <> '-' then
      execute format('select array_agg(distinct x) from (select %I as x from %I where %I is not null limit 2000) q', v_booking, v_rel, v_booking) into v_bookings;
      if v_bookings is not null then
        v_scopes := v_scopes || array(select 'booking:' || b from unnest(v_bookings) b)
          || array(select distinct 'renter:' || r.user_id from bookings bk join renters r on r.id = bk.renter_id where bk.id = any (v_bookings) and r.user_id is not null)
          || array(select distinct 'owner:' || o.user_id from bookings bk join owners o on o.id = bk.owner_id where bk.id = any (v_bookings) and o.user_id is not null);
      end if;
    end if;
    if v_user <> '-' then
      execute format('select array_agg(distinct x) from (select %I as x from %I where %I is not null limit 2000) q', v_user, v_rel, v_user) into v_users;
      if v_users is not null then v_scopes := v_scopes || array(select 'user:' || u from unnest(v_users) u); end if;
    end if;
    perform app.live_add(v_scopes);
  exception when others then
    -- a live update is never worth a failed write
    null;
  end;
  return null;
end $$;
revoke all on function app.live_rows() from public, anon, authenticated;

-- at commit: bump every topic of the transaction, in sorted order, and broadcast it when Realtime is installed
create function app.live_commit() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v text := coalesce(current_setting('carmacars.live_pending', true), '');
  v_topics text[];
  t text;
  rt boolean;
begin
  begin
    perform set_config('carmacars.live_pending', '', true);
    delete from app.live_flush where tx = new.tx;
    if v = '' then return null; end if;
    select array_agg(x order by x) into v_topics from (select distinct app.live_topic(s) as x from unnest(string_to_array(v, '|')) s) q;
    insert into app.live_versions (topic, ver, at)
    select x, 1, now() from unnest(v_topics) x order by x
    on conflict (topic) do update set ver = app.live_versions.ver + 1, at = now();
    rt := to_regprocedure('realtime.send(jsonb, text, text, boolean)') is not null;
    if rt then
      foreach t in array v_topics[1:200] loop
        begin
          execute 'select realtime.send($1, $2, $3, false)' using '{}'::jsonb, 'bump', t;
        exception when others then null;
        end;
      end loop;
    end if;
  exception when others then
    null;
  end;
  return null;
end $$;
revoke all on function app.live_commit() from public, anon, authenticated;

create constraint trigger live_flush_commit after insert on app.live_flush
  deferrable initially deferred for each row execute function app.live_commit();

-- ================================================================ 4. the watched tables
create function app.live_watch(p_table regclass, p_area text, p_booking text, p_user text) returns void
language plpgsql set search_path = public, app as $$
declare
  n text := replace(p_table::text, '.', '_');
begin
  execute format('create trigger %I after insert on %s referencing new table as live_new for each statement execute function app.live_rows(%L, %L, %L)',
    'live_ins_' || n, p_table, p_area, p_booking, p_user);
  execute format('create trigger %I after update on %s referencing new table as live_new for each statement execute function app.live_rows(%L, %L, %L)',
    'live_upd_' || n, p_table, p_area, p_booking, p_user);
  execute format('create trigger %I after delete on %s referencing old table as live_old for each statement execute function app.live_rows(%L, %L, %L)',
    'live_del_' || n, p_table, p_area, p_booking, p_user);
end $$;
revoke all on function app.live_watch(regclass, text, text, text) from public, anon, authenticated;

do $$
declare w record;
begin
  for w in select * from (values
    -- bookings list, booking page, calendar, today board, renter's trips, owner dashboard
    ('bookings', 'bookings', 'id', '-'),
    ('booking_addons', 'bookings', 'booking_id', '-'),
    ('booking_events', 'bookings', 'booking_id', '-'),
    ('booking_extensions', 'bookings', 'booking_id', '-'),
    ('booking_line_items', 'bookings', 'booking_id', '-'),
    ('booking_drivers', 'bookings', 'booking_id', '-'),
    ('booking_vehicle_swaps', 'bookings', 'booking_id', '-'),
    ('payments', 'bookings', 'booking_id', '-'),
    ('payment_requests', 'bookings', 'booking_id', '-'),
    ('refunds', 'bookings', 'booking_id', '-'),
    ('deposits', 'bookings', 'booking_id', '-'),
    ('rental_agreements', 'bookings', 'booking_id', '-'),
    ('esign_sessions', 'bookings', 'booking_id', '-'),
    ('condition_reports', 'bookings', 'booking_id', '-'),
    ('identity_verifications', 'bookings', 'booking_id', '-'),
    ('vehicle_calendar_blocks', 'bookings', 'booking_id', '-'),
    -- requests and offers
    ('booking_offers', 'requests', 'booking_id', '-'),
    ('request_claims', 'requests', 'booking_id', '-'),
    ('booking_info_requests', 'requests', 'booking_id', '-'),
    ('booking_change_requests', 'requests', 'booking_id', '-'),
    -- leads (Sales)
    ('leads', 'leads', '-', '-'),
    ('lead_claims', 'leads', '-', '-'),
    ('lead_contacts', 'leads', '-', '-'),
    ('lead_holds', 'leads', '-', '-'),
    -- messages and the inbox
    ('messages', 'messages', 'booking_id', 'user_id'),
    ('chat_conversations', 'messages', '-', '-'),
    ('chat_messages', 'messages', '-', '-'),
    -- field jobs and shifts
    ('field_jobs', 'field', 'booking_id', 'assigned_to'),
    ('field_shifts', 'field', '-', 'staff_id'),
    ('field_shift_offers', 'field', '-', '-'),
    ('field_shift_slots', 'field', '-', '-'),
    ('field_shift_plans', 'field', '-', 'staff_id'),
    ('field_availability', 'field', '-', 'user_id'),
    -- alerts: the bell and the alerts feed of every portal
    ('notifications', '-', '-', 'user_id')
  ) v(tbl, area, booking_col, user_col)
  loop
    if to_regclass('public.' || w.tbl) is not null then
      perform app.live_watch(('public.' || w.tbl)::regclass, w.area, w.booking_col, w.user_col);
    end if;
  end loop;
end $$;

-- ================================================================ 5. the doors
-- the names a person may watch, for the portal frames and a booking's page (service role: the server asks for the
-- signed-in person). A scope the person may not read is left out.
create function app.server_live_topics(p_user uuid, p_scopes text[]) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s text;
  out jsonb := '{}'::jsonb;
  v_admin boolean;
  v_office boolean;
  v_field boolean;
  v_booking uuid;
begin
  if p_user is null or not exists (select 1 from users u where u.id = p_user and u.status = 'active') then return out; end if;
  select bool_or(r.role = 'admin'), bool_or(r.role = 'va'), bool_or(r.role = 'field')
    into v_admin, v_office, v_field from user_roles r where r.user_id = p_user;
  v_admin := coalesce(v_admin, false); v_office := coalesce(v_office, false); v_field := coalesce(v_field, false);
  foreach s in array coalesce(p_scopes, '{}')
  loop
    continue when s is null or out ? s;
    if s in ('user:' || p_user, 'renter:' || p_user, 'owner:' || p_user) then
      out := out || jsonb_build_object(s, app.live_topic(s));
    elsif s in ('staff:bookings', 'staff:requests', 'staff:leads', 'staff:messages') then
      if v_admin or v_office then out := out || jsonb_build_object(s, app.live_topic(s)); end if;
    elsif s = 'staff:field' then
      if v_admin or v_office or v_field then out := out || jsonb_build_object(s, app.live_topic(s)); end if;
    elsif s like 'booking:%' then
      select b.id into v_booking from bookings b where b.booking_number = substr(s, 9);
      if v_booking is not null and (v_admin or v_office or app.is_booking_party(v_booking, p_user)
          or exists (select 1 from bookings b join owners o on o.id = b.owner_id where b.id = v_booking and o.user_id = p_user)
          or exists (select 1 from field_jobs j where j.booking_id = v_booking and j.assigned_to = p_user)) then
        out := out || jsonb_build_object(s, app.live_topic('booking:' || v_booking));
      end if;
    end if;
  end loop;
  return out;
end $$;
create function public.server_live_topics(p_user uuid, p_scopes text[]) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.server_live_topics(p_user, p_scopes) $$;
revoke all on function app.server_live_topics(uuid, text[]), public.server_live_topics(uuid, text[]) from public, anon, authenticated;
grant execute on function app.server_live_topics(uuid, text[]), public.server_live_topics(uuid, text[]) to service_role;

-- the versions of the named topics (the browser, anonymous: the names are the secret). At most 24 names; anything
-- that is not a name is ignored; a topic with no change yet is left out.
create function public.live_poll(p_topics text[]) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_object_agg(v.topic, v.ver::text), '{}'::jsonb)
    from app.live_versions v
   where v.topic = any (array(select t from unnest(coalesce(p_topics, '{}')) with ordinality u(t, i) where i <= 24 and t ~ '^[0-9a-f]{32}$'))
$$;
revoke all on function public.live_poll(text[]) from public;
grant execute on function public.live_poll(text[]) to anon, authenticated, service_role;
comment on function public.live_poll(text[]) is 'Live updates (2500): the versions of up to 24 topics, by their names (server_live_topics). Read every 2 s by an open portal screen while Realtime is not joined.';

-- ================================================================ 6. Realtime's own schema
-- the self-hosted Realtime container (infra/vps, compose profile "realtime") keeps its tenants in _realtime, which the
-- upstream image makes only on a fresh database (an init script): made here so enabling the container is one step.
-- Nothing of the app lives there (infra/vps/scripts/filter-data.py skips it).
do $$
begin
  create schema if not exists _realtime;
  begin
    if exists (select 1 from pg_roles where rolname = 'supabase_admin') then execute 'alter schema _realtime owner to supabase_admin'; end if;
  exception when others then null;
  end;
  revoke all on schema _realtime from public;
end $$;
