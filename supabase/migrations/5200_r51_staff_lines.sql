-- 5200 (R51 staff, REQ-132; docs/changes/2026-11-27-r51-staff.md): every staff member's own Twilio line behind a Quo
-- extension. The owner (Nov 27 17:29): "i need all staff to have a dedicated twilio line that corresponds with an extension
-- number that is on quo, so that all staff can get incoming calls to their portals and their apps via their extension
-- numbers that forward to their twilio phone numbers (nobody will ever know what those numbers are)".
--   1. staff_phone_lines: the extension (1 to 4 digits, unique), the last 4 digits of the number, its state and its monthly
--      cost. The number itself and Twilio's id are in staff_phone_line_secrets, which no browser role can read (the server
--      only): staff and renters never see it, and an Admin sees the last 4 digits.
--   2. An Admin sets the extension (admin_do staff_line_set) and buys the number from Admin > Settings > Staff: the button
--      shows Twilio's monthly price and asks to confirm, then the server buys it (web/src/server/staff-lines.ts) and records
--      it here (app.server_staff_line_bought, only for an Admin's confirmed purchase). Tests and jobs never buy a number.
--      Release gives the number back to Twilio (app.server_staff_line_released). "Added in Quo" records the owner's step.
--   3. A call to a staff line (Twilio's To) rings only that person's browser phone, in the portal or the app, while they are
--      online (app.server_voice_ring with to). The phone of a person with a line is ready for incoming calls whatever their
--      role (server_voice_presence). Not online or not answered: the line's message (Program setting phone_line_message),
--      the missed call on the caller's history as every call, and the alert staff_line_missed to that person.
--   4. The person sees their extension, never the number (ops_read my_line); they hear when the line is ready
--      (staff_line_ready).
-- No applied migration is edited: server_voice_ring and server_voice_presence are patched in place; the door is wrapped.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5200: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;
create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the lines
alter table program_settings
  add column if not exists phone_line_area_code text not null default '647' check (phone_line_area_code ~ '^[2-9][0-9]{2}$'),
  add column if not exists phone_line_message text not null default 'Sorry, they cannot take your call right now. Please call the main CarmaCars number. CarmaCars.'
    check (length(phone_line_message) between 1 and 300);
-- clear this transaction's copy of the settings row: it has the old columns (0827 caches it; deploy 46122920273 failed on 5170)
select set_config('app.settings_gen', gen_random_uuid()::text, true);
comment on column program_settings.phone_line_area_code is 'Staff lines (5200): the area code a new staff line is bought in (a Canadian local number at Twilio).';
comment on column program_settings.phone_line_message is 'Staff lines (5200): what a caller hears when the staff member is not online or does not answer.';

create table staff_phone_lines (
  user_id       uuid primary key references users (id) on delete cascade,
  extension     text not null unique check (extension ~ '^[0-9]{1,4}$'),
  last4         text check (last4 ~ '^[0-9]{4}$'),
  status        text not null default 'no_number' check (status in ('no_number', 'active', 'released')),
  monthly_cents integer check (monthly_cents >= 0),
  currency      text check (currency in ('USD', 'CAD')),
  bought_at     timestamptz,
  bought_by     uuid references users (id),
  released_at   timestamptz,
  released_by   uuid references users (id),
  quo_added_at  timestamptz,
  quo_added_by  uuid references users (id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check ((status = 'active') = (last4 is not null))
);
comment on table staff_phone_lines is 'Staff lines (5200, REQ-132): each staff member''s extension and own Twilio line. The number is in staff_phone_line_secrets (server only); this table holds its last 4 digits.';
create trigger staff_phone_lines_updated before update on staff_phone_lines for each row execute function app.set_updated_at();
create trigger audit_staff_phone_lines after insert or update or delete on staff_phone_lines for each row execute function app.audit_row();
alter table staff_phone_lines enable row level security;
create policy admin_all on staff_phone_lines for select to authenticated using (app.is_admin());
revoke all on staff_phone_lines from anon, authenticated;
grant select on staff_phone_lines to authenticated;
grant select, insert, update, delete on staff_phone_lines to service_role;

create table staff_phone_line_secrets (
  user_id       uuid primary key references staff_phone_lines (user_id) on delete cascade,
  twilio_number text not null unique check (twilio_number ~ '^\+[1-9][0-9]{7,14}$'),
  twilio_sid    text not null unique check (twilio_sid ~ '^PN[0-9a-fA-F]{32}$'),
  created_at    timestamptz not null default now()
);
comment on table staff_phone_line_secrets is 'Staff lines (5200): the Twilio number and its id. Never read by a browser role (no grant), never shown: the server rings and releases with it.';
alter table staff_phone_line_secrets enable row level security;
create policy admin_all on staff_phone_line_secrets for select to authenticated using (false);
revoke all on staff_phone_line_secrets from public, anon, authenticated;
grant select, insert, update, delete on staff_phone_line_secrets to service_role;

-- the line of this person is live
create function app.staff_has_line(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from staff_phone_lines l join staff_phone_line_secrets s on s.user_id = l.user_id where l.user_id = p_user and l.status = 'active')
$$;

-- "ends in 1234": all an Admin ever sees of a number
create function app.staff_line_words(l staff_phone_lines) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when l.status = 'active' then 'Ext ' || l.extension || ', number ending ' || l.last4
              when l.status = 'released' then 'Ext ' || l.extension || ', number released'
              else 'Ext ' || l.extension || ', no number yet' end
$$;

-- ================================================================ 2. Admin: the extension, the purchase, the release, Quo
create function app.staff_line_set(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_ext text := btrim(coalesce(p ->> 'extension', ''));
  l staff_phone_lines;
begin
  perform app.assert_admin(p_by);
  if not app.voice_staff_ok(v_user) then raise exception 'Choose an active staff member' using errcode = '22023'; end if;
  if v_ext = '' then
    -- the next free extension from 1 (Quo's phone menu takes one digit, 0 to 9, a menu)
    select min(x)::text into v_ext from generate_series(1, 9999) x where not exists (select 1 from staff_phone_lines e where e.extension = x::text);
  end if;
  if v_ext !~ '^[0-9]{1,4}$' then raise exception 'An extension is 1 to 4 digits' using errcode = '22023'; end if;
  if exists (select 1 from staff_phone_lines e where e.extension = v_ext and e.user_id <> v_user) then
    raise exception 'Extension % is someone else''s', v_ext using errcode = '23505';
  end if;
  insert into staff_phone_lines (user_id, extension) values (v_user, v_ext)
  on conflict (user_id) do update set extension = excluded.extension,
    -- a new extension is a new step in Quo
    quo_added_at = case when staff_phone_lines.extension = excluded.extension then staff_phone_lines.quo_added_at end,
    quo_added_by = case when staff_phone_lines.extension = excluded.extension then staff_phone_lines.quo_added_by end
  returning * into l;
  return jsonb_build_object('ok', true, 'extension', l.extension, 'line', app.staff_line_words(l));
end $$;

create function app.staff_line_quo_done(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l staff_phone_lines;
begin
  perform app.assert_admin(p_by);
  update staff_phone_lines set quo_added_at = case when coalesce((p ->> 'done')::boolean, true) then now() end,
                               quo_added_by = case when coalesce((p ->> 'done')::boolean, true) then p_by end
   where user_id = nullif(p ->> 'user_id', '')::uuid returning * into l;
  if l.user_id is null then raise exception 'Set the extension first' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'quo_added', l.quo_added_at is not null);
end $$;

-- the server, before it asks Twilio: an Admin, a staff member with an extension and no live number
create function app.server_staff_line_check(p_by uuid, p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare l staff_phone_lines;
begin
  perform app.assert_admin(p_by);
  if not app.voice_staff_ok(p_user) then raise exception 'Choose an active staff member' using errcode = '22023'; end if;
  select * into l from staff_phone_lines where user_id = p_user;
  if l.user_id is null then raise exception 'Set the extension first' using errcode = 'P0002'; end if;
  if l.status = 'active' then raise exception '% already has a line (ending %)', app.staff_display_name(p_user), l.last4 using errcode = '23505'; end if;
  return jsonb_build_object('ok', true, 'extension', l.extension, 'name', app.staff_display_name(p_user), 'area_code', (app.settings()).phone_line_area_code);
end $$;

-- the server bought the number (after the Admin confirmed the price): kept, the person told
create function app.server_staff_line_bought(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_by uuid := nullif(p ->> 'by', '')::uuid;
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_num text := app.phone_e164(p ->> 'number');
  l staff_phone_lines;
begin
  perform app.server_staff_line_check(v_by, v_user);
  if v_num is null or (p ->> 'sid') !~ '^PN[0-9a-fA-F]{32}$' then raise exception 'The number Twilio gave is not valid' using errcode = '22023'; end if;
  insert into staff_phone_line_secrets (user_id, twilio_number, twilio_sid) values (v_user, v_num, p ->> 'sid')
  on conflict (user_id) do update set twilio_number = excluded.twilio_number, twilio_sid = excluded.twilio_sid, created_at = now();
  update staff_phone_lines set status = 'active', last4 = right(v_num, 4), monthly_cents = nullif(p ->> 'monthly_cents', '')::integer,
         currency = coalesce(nullif(p ->> 'currency', ''), 'USD'), bought_at = now(), bought_by = v_by, released_at = null, released_by = null
   where user_id = v_user returning * into l;
  insert into audit_log (actor_user_id, actor_db_role, action, entity_table, entity_id, after)
  values (v_by, current_user, 'staff_line_bought', 'staff_phone_lines', v_user::text, jsonb_build_object('extension', l.extension, 'last4', l.last4, 'monthly_cents', l.monthly_cents, 'currency', l.currency));
  begin
    perform app.staff_alert('staff_line_ready', 'user', v_user, 'ready:' || l.extension,
      format('Your phone line is ready: extension %s', l.extension),
      format('Calls to extension %s ring your browser phone in the portal and the app while you are signed in. Keep a staff page open to take them.', l.extension),
      jsonb_build_object('assigned_to', v_user, 'path_staff', '/staff/profile', 'path_admin', '/admin/settings/staff'));
  exception when others then raise warning 'staff line alert not made: %', sqlerrm;
  end;
  return jsonb_build_object('ok', true, 'line', app.staff_line_words(l));
end $$;

-- the server, to release: the Twilio id (never the number)
create function app.server_staff_line_sid(p_by uuid, p_user uuid) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.assert_admin(p_by);
  return (select s.twilio_sid from staff_phone_line_secrets s where s.user_id = p_user);
end $$;

create function app.server_staff_line_released(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_by uuid := nullif(p ->> 'by', '')::uuid;
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  l staff_phone_lines;
begin
  perform app.assert_admin(v_by);
  delete from staff_phone_line_secrets where user_id = v_user;
  update staff_phone_lines set status = 'released', last4 = null, released_at = now(), released_by = v_by where user_id = v_user returning * into l;
  if l.user_id is null then raise exception 'No line for this person' using errcode = 'P0002'; end if;
  insert into audit_log (actor_user_id, actor_db_role, action, entity_table, entity_id, after)
  values (v_by, current_user, 'staff_line_released', 'staff_phone_lines', v_user::text, jsonb_build_object('extension', l.extension));
  return jsonb_build_object('ok', true, 'line', app.staff_line_words(l));
end $$;

-- Admin > Settings > Staff: every line, last 4 digits only
create function app.staff_lines_read(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_object_agg(l.user_id::text, jsonb_build_object('extension', l.extension, 'status', l.status, 'last4', l.last4, 'words', app.staff_line_words(l),
           'monthly_cents', l.monthly_cents, 'currency', l.currency, 'quo_added', l.quo_added_at is not null, 'bought_at', l.bought_at)) from staff_phone_lines l), '{}'::jsonb);
end $$;

-- the person: their extension, never the number
create function app.my_line_read(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select jsonb_build_object('extension', l.extension, 'active', app.staff_has_line(p_user)) from staff_phone_lines l where l.user_id = p_user),
                  jsonb_build_object('extension', null, 'active', false))
$$;

-- ================================================================ 3. calls to a line
-- the phone of a person with a line is ready for incoming calls (their line), whatever their role
select pg_temp.patch_fn('app.server_voice_presence(uuid,jsonb)'::regprocedure,
  $o$v_ring := app.voice_rings(p_user);$o$,
  $n$v_ring := app.voice_rings(p_user) or app.staff_has_line(p_user);$n$);

-- a call to a staff line rings only that person (to: the number called)
select pg_temp.patch_fn('app.server_voice_ring(jsonb)'::regprocedure,
  $o$begin
  if v_from is not null then select t.name into v_name from phone_threads t where t.number = v_from; end if;$o$,
  $n$  v_line uuid;
  v_ext text;
begin
  if v_from is not null then select t.name into v_name from phone_threads t where t.number = v_from; end if;
  -- 5200: a staff member's own line
  select ls.user_id, l.extension into v_line, v_ext from staff_phone_line_secrets ls join staff_phone_lines l on l.user_id = ls.user_id
   where ls.twilio_number = app.phone_e164(p ->> 'to') and l.status = 'active';
  if v_line is not null then
    select coalesce(jsonb_agg(jsonb_build_object('identity', 'staff_' || replace(vp.user_id::text, '-', ''),
             'who', coalesce(v_name, case when v_from is null then 'Unknown caller' when app.user_sales_only(vp.user_id) and not app.phone_unlocked_for(vp.user_id, v_from) then app.phone_mask_display(v_from) else app.phone_display(v_from) end)
                    || ' (your line, ext ' || v_ext || ')')), '[]'::jsonb)
      into v_ring
      from voice_presence vp
     where vp.user_id = v_line and vp.online and vp.seen_at > now() - interval '2 minutes' and app.voice_staff_ok(vp.user_id);
    return jsonb_build_object('enabled', s.phone_browser_calls, 'line', true, 'extension', v_ext, 'ring', v_ring, 'seconds', s.phone_inbound_ring_seconds,
      'forward_to', null, 'message', s.phone_line_message, 'caller_id', app.phone_our_number(), 'record', s.phone_twilio_record);
  end if;$n$);

-- a call to a line nobody took: that person hears of it (the call itself is on the caller's history as every call)
create function app.server_staff_line_missed(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_user uuid;
  v_ext text;
  v_from text := app.phone_e164(p ->> 'from');
  v_name text;
begin
  select s.user_id, l.extension into v_user, v_ext from staff_phone_line_secrets s join staff_phone_lines l on l.user_id = s.user_id
   where s.twilio_number = app.phone_e164(p ->> 'to') and l.status = 'active';
  if v_user is null then return jsonb_build_object('line', false); end if;
  if v_from is not null then select t.name into v_name from phone_threads t where t.number = v_from; end if;
  begin
    perform app.staff_alert('staff_line_missed', 'user', v_user, 'missed:' || coalesce(nullif(p ->> 'call_sid', ''), gen_random_uuid()::text),
      format('Missed call on your line (ext %s)', v_ext),
      'From ' || coalesce(v_name, case when v_from is null then 'an unknown caller' when app.user_sales_only(v_user) and not app.phone_unlocked_for(v_user, v_from) then app.phone_mask_display(v_from) else app.phone_display(v_from) end)
        || '. Call them back from the portal.',
      jsonb_build_object('assigned_to', v_user, 'path_staff', '/staff/alerts', 'path_admin', '/admin/settings/staff'));
  exception when others then raise warning 'staff line missed alert not made: %', sqlerrm;
  end;
  return jsonb_build_object('line', true, 'message', (app.settings()).phone_line_message);
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, hint, sort) values
  ('staff_line_ready', 'Your phone line is ready', 'Staff', '{assigned}', 'normal', 'messages', true, true, 'The staff member whose extension now has its own line.', 127),
  ('staff_line_missed', 'Missed call on your line', 'Staff', '{assigned}', 'urgent', 'messages', true, true, 'A call to a staff member''s own line that nobody took.', 128)
on conflict (rule) do nothing;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre5200;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
begin
  if (p_call = 'admin_read' and p_name = 'staff_lines') or (p_call = 'admin_do' and p_name in ('staff_line_set', 'staff_line_quo_done'))
     or (p_call in ('ops_read', 'field_read', 'va_read') and p_name = 'my_line') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'staff_lines' then app.staff_lines_read(p_user)
                       when 'staff_line_set' then app.staff_line_set(p_user, p_)
                       when 'staff_line_quo_done' then app.staff_line_quo_done(p_user, p_)
                       else app.my_line_read(p_user) end;
  end if;
  return app.door_pre5200(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre5200(uuid, text, text, text, jsonb)'::regprocedure);

-- the server's calls (the service role through the API)
create function public.server_staff_line_check(p_by uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.server_staff_line_check(p_by, p_user) $$;
create function public.server_staff_line_bought(p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_staff_line_bought(p) $$;
create function public.server_staff_line_sid(p_by uuid, p_user uuid) returns text
language sql stable security definer set search_path = public, app, pg_temp as $$ select app.server_staff_line_sid(p_by, p_user) $$;
create function public.server_staff_line_released(p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_staff_line_released(p) $$;
create function public.server_staff_line_missed(p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_staff_line_missed(p) $$;

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where (n.nspname = 'app' and p.proname = any (array['staff_has_line', 'staff_line_words', 'staff_line_set', 'staff_line_quo_done', 'server_staff_line_check',
                    'server_staff_line_bought', 'server_staff_line_sid', 'server_staff_line_released', 'staff_lines_read', 'my_line_read', 'server_staff_line_missed', 'door_pre5200']))
               or (n.nspname = 'public' and p.proname = any (array['server_staff_line_check', 'server_staff_line_bought', 'server_staff_line_sid', 'server_staff_line_released', 'server_staff_line_missed'])) loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
