-- 0562_api_access.sql
-- Release 28 (docs/changes/2026-11-06-r28-platform.md, B3): Abbas and Mahad work with bookings, owners and requests from
-- Claude. Two ways in, one set of rules:
--   API keys      Admin > Settings > API access: a key per person, shown once, kept only as its SHA-256, with its scopes,
--                 revocable (Claude Code and scripts send it as "Authorization: Bearer cc_live_...")
--   Claude        the remote MCP connector at /api/mcp with OAuth 2.1 (Dynamic Client Registration, PKCE S256): the
--                 person signs in on carmacars.ca and approves; Claude holds a one-hour access token and a 30-day refresh
--                 token, both kept here only as hashes, and each connection is a row of api_keys (kind oauth), revocable
-- Only an active Admin may hold a key or connect (checked at every call, so removing the Admin role stops the key at once).
-- Every call runs through app.api_call: the key, its scope, the Admin role, the rate limit (Program settings
-- api_calls_per_minute, 60), then the tool as that person (app.door_begin: the audit log and every guard trigger see them),
-- and one row in api_calls with who, what, the row before and after, and the outcome. The tools change only the listed
-- fields; anything else (prices, payments, status) stays in the portal. No SQL text ever comes from outside.

alter table program_settings
  add column if not exists api_access_enabled boolean not null default true,
  add column if not exists api_calls_per_minute integer not null default 60 check (api_calls_per_minute between 1 and 600);
comment on column program_settings.api_access_enabled is 'API keys and the Claude connector (0562) answer at all. Off: every key and connection is refused until it is turned on again.';
comment on column program_settings.api_calls_per_minute is 'Calls one API key or Claude connection may make per minute (0562).';

create table if not exists api_oauth_clients (
  id            uuid primary key default gen_random_uuid(),
  client_id     text not null unique check (client_id ~ '^ccc_[A-Za-z0-9_-]{16,64}$'),
  client_name   text not null check (length(client_name) between 1 and 120),
  redirect_uris text[] not null check (cardinality(redirect_uris) between 1 and 5),
  created_at    timestamptz not null default now()
);
comment on table api_oauth_clients is 'OAuth clients registered by Dynamic Client Registration (0562): Claude registers itself; only Claude''s callback and loopback addresses are accepted.';

create table if not exists api_keys (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references users (id) on delete cascade,
  kind               text not null default 'key' check (kind in ('key', 'oauth')),
  name               text not null check (length(name) between 1 and 80),
  prefix             text not null check (length(prefix) between 6 and 24),
  key_hash           text not null unique check (key_hash ~ '^[0-9a-f]{64}$'),
  scopes             text[] not null check (cardinality(scopes) >= 1 and scopes <@ array['bookings:read', 'bookings:write', 'owners:read', 'owners:write', 'requests:read', 'requests:write']),
  oauth_client_id    uuid references api_oauth_clients (id) on delete cascade,
  refresh_hash       text unique check (refresh_hash ~ '^[0-9a-f]{64}$'),
  expires_at         timestamptz,
  refresh_expires_at timestamptz,
  created_by         uuid references users (id),
  created_at         timestamptz not null default now(),
  last_used_at       timestamptz,
  revoked_at         timestamptz,
  revoked_by         uuid references users (id),
  check (kind = 'key' or oauth_client_id is not null)
);
create index if not exists api_keys_user_idx on api_keys (user_id, created_at desc);
comment on table api_keys is 'API keys and Claude connections (0562): the SHA-256 of each secret only (never the secret), its scopes, who holds it, when it was last used, and when it was revoked.';
comment on column api_keys.prefix is 'The first characters of the secret, shown in Admin to tell keys apart (not enough to use it).';

create table if not exists api_oauth_codes (
  code_hash      text primary key check (code_hash ~ '^[0-9a-f]{64}$'),
  client_id      uuid not null references api_oauth_clients (id) on delete cascade,
  user_id        uuid not null references users (id) on delete cascade,
  redirect_uri   text not null,
  code_challenge text not null check (code_challenge ~ '^[A-Za-z0-9_-]{43}$'),
  scopes         text[] not null,
  expires_at     timestamptz not null,
  used_at        timestamptz,
  created_at     timestamptz not null default now()
);
comment on table api_oauth_codes is 'OAuth authorization codes (0562): kept as hashes, valid 5 minutes, used once.';

create table if not exists api_calls (
  id         bigint generated always as identity primary key,
  key_id     uuid references api_keys (id) on delete set null,
  user_id    uuid references users (id) on delete set null,
  tool       text not null,
  target     text,
  args       jsonb not null default '{}'::jsonb,
  before     jsonb,
  after      jsonb,
  ok         boolean not null,
  error      text,
  client     text,
  created_at timestamptz not null default now()
);
create index if not exists api_calls_key_time_idx on api_calls (key_id, created_at desc);
create index if not exists api_calls_time_idx on api_calls (created_at desc);
comment on table api_calls is 'Every API and Claude connector call (0562): who (the key and its person), the tool, the record, the fields before and after a change, and whether it worked. Append-only.';

do $$
declare t text;
begin
  foreach t in array array['api_oauth_clients', 'api_keys', 'api_oauth_codes', 'api_calls'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from public, anon, authenticated', t);
    execute format('grant select on %I to authenticated', t);
    execute format('grant select, insert, update on %I to service_role', t);
    execute format('drop policy if exists admin_all on %I', t);
    execute format('create policy admin_all on %I for select to authenticated using (app.is_admin())', t);
  end loop;
end $$;
-- the keys and clients are audited like every table; the codes and the call log are logs of their own (03_flows lists them)
drop trigger if exists audit_api_keys on api_keys;
create trigger audit_api_keys after insert or update or delete on api_keys for each row execute function app.audit_row();
drop trigger if exists audit_api_oauth_clients on api_oauth_clients;
create trigger audit_api_oauth_clients after insert or update or delete on api_oauth_clients for each row execute function app.audit_row();
-- the call log cannot be edited or deleted, even by the server
create or replace function app.api_calls_append_only() returns trigger language plpgsql as $$
begin raise exception 'api_calls is append-only' using errcode = '42501'; end $$;
drop trigger if exists api_calls_append_only on api_calls;
create trigger api_calls_append_only before update or delete on api_calls for each row execute function app.api_calls_append_only();

-- ================================================================ the scopes and the tools
create or replace function app.api_tool_scope(p_tool text) returns text
language sql immutable as $$
  select case p_tool
    when 'list_bookings' then 'bookings:read' when 'get_booking' then 'bookings:read' when 'update_booking' then 'bookings:write'
    when 'list_requests' then 'requests:read' when 'update_request' then 'requests:write'
    when 'list_owners' then 'owners:read' when 'get_owner' then 'owners:read' when 'update_owner' then 'owners:write'
    when 'whoami' then 'any' end
$$;

-- the fields each write tool may change (everything else stays in the portal)
create or replace function app.api_fields(p_tool text) returns text[]
language sql immutable as $$
  select case p_tool
    when 'update_booking' then array['notes', 'pickup_place', 'return_place', 'insurer_claim_number', 'insurer_adjuster_name', 'insurer_adjuster_email',
                                     'insurer_adjuster_phone', 'marketing_source', 'marketing_source_note', 'do_not_email', 'heard_about']
    when 'update_request' then array['request_note', 'notes', 'pickup_at', 'return_at', 'pickup_place', 'return_place']
    when 'update_owner' then array['first_name', 'middle_name', 'last_name', 'legal_name', 'corporation_name', 'email', 'phone', 'hst_number',
                                   'address_line1', 'address_line2', 'city', 'province', 'postal_code', 'mailing_address_line1', 'mailing_address_line2',
                                   'mailing_city', 'mailing_province', 'mailing_postal_code', 'notify_channel', 'signing_officer_name', 'signing_officer_title']
    else '{}'::text[] end
$$;

create or replace function app.api_booking_row(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'car', app.vehicle_name(b.vehicle_id), 'plate', v.plate,
           'renter', r.legal_name, 'renter_email', r.email, 'renter_phone', r.mobile,
           'pickup_at', b.pickup_at, 'return_at', b.return_at, 'pickup_place', b.pickup_place, 'return_place', b.return_place,
           'total_due_cents', b.total_due_at_booking_cents, 'deposit_cents', b.deposit_cents, 'notes', b.notes, 'request_note', b.request_note,
           'insurer_claim_number', b.insurer_claim_number, 'insurer_adjuster_name', b.insurer_adjuster_name, 'insurer_adjuster_email', b.insurer_adjuster_email,
           'insurer_adjuster_phone', b.insurer_adjuster_phone, 'marketing_source', b.marketing_source, 'marketing_source_note', b.marketing_source_note,
           'do_not_email', b.do_not_email, 'heard_about', b.heard_about, 'requested_at', b.requested_at, 'confirmed_at', b.confirmed_at,
           'admin_path', '/admin/bookings/' || b.booking_number)
    from bookings b left join renters r on r.id = b.renter_id left join vehicles v on v.id = b.vehicle_id
   where b.id = p_id
$$;

create or replace function app.api_owner_row(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select to_jsonb(o) - 'balance_carried_forward_cents' - 'registrant_identification_number' - 'corporation_number'
         || jsonb_build_object('cars', coalesce((select jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'car', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status) order by v.created_at)
                                           from vehicles v where v.owner_id = o.id and v.retired_at is null), '[]'::jsonb),
                               'admin_path', '/admin/owners/' || o.id)
    from owners o where o.id = p_id
$$;

-- ================================================================ one call
create or replace function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  k api_keys;
  v_scope text := app.api_tool_scope(p_tool);
  a jsonb := coalesce(p_args, '{}'::jsonb);
  ch jsonb := coalesce(p_args -> 'changes', '{}'::jsonb);
  v_n integer;
  v_id uuid;
  v_target text;
  v_before jsonb;
  v_after jsonb;
  v_result jsonb;
  v_lim integer;
  v_q text;
  v_bad text[];
  f text;
  sets text := '';
begin
  if not s.api_access_enabled then return jsonb_build_object('ok', false, 'status', 403, 'error', 'API access is turned off in Admin > Settings > Program.'); end if;
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'status', 401, 'error', 'Missing or malformed key.'); end if;
  select * into k from api_keys where key_hash = p_hash;
  if k.id is null or k.revoked_at is not null or (k.expires_at is not null and k.expires_at <= now()) then
    return jsonb_build_object('ok', false, 'status', 401, 'error', 'This key is not valid (unknown, revoked or expired).');
  end if;
  if not app.user_is_admin(k.user_id) then
    return jsonb_build_object('ok', false, 'status', 403, 'error', 'Only an active Admin may use API access.');
  end if;
  if v_scope is null then
    insert into api_calls (key_id, user_id, tool, args, ok, error, client) values (k.id, k.user_id, left(coalesce(p_tool, ''), 60), '{}'::jsonb, false, 'unknown tool', left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', 400, 'error', format('Unknown tool %s.', p_tool));
  end if;
  if v_scope <> 'any' and not (v_scope = any (k.scopes)) then
    insert into api_calls (key_id, user_id, tool, args, ok, error, client) values (k.id, k.user_id, p_tool, a, false, 'scope ' || v_scope || ' not granted', left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', 403, 'error', format('This key does not have the %s scope.', v_scope));
  end if;
  select count(*) into v_n from api_calls c where c.key_id = k.id and c.created_at > now() - interval '1 minute';
  if v_n >= s.api_calls_per_minute then
    return jsonb_build_object('ok', false, 'status', 429, 'error', format('Too many calls: at most %s a minute. Wait a moment.', s.api_calls_per_minute));
  end if;
  update api_keys set last_used_at = now() where id = k.id;

  -- the call runs as the key's person: the audit log and every guard see them (an Admin; the key is their second factor)
  perform app.door_begin(k.user_id, 'aal2');
  v_lim := least(greatest(coalesce((a ->> 'limit')::integer, 20), 1), 50);
  v_q := nullif(btrim(coalesce(a ->> 'query', '')), '');

  begin
    case p_tool
    when 'whoami' then
      v_result := jsonb_build_object('user', (select jsonb_build_object('email', u.email) from users u where u.id = k.user_id), 'key', k.name, 'scopes', k.scopes,
                                     'tools_change_only', jsonb_build_object('update_booking', app.api_fields('update_booking'), 'update_request', app.api_fields('update_request'), 'update_owner', app.api_fields('update_owner')));

    when 'list_bookings', 'list_requests' then
      v_result := coalesce((select jsonb_agg(app.api_booking_row(b.id) order by b.pickup_at desc) from (
          select b.id, b.pickup_at from bookings b
            left join renters r on r.id = b.renter_id left join vehicles v on v.id = b.vehicle_id
           where not coalesce(b.is_placeholder, false)
             and (case when p_tool = 'list_requests' then b.status::text in ('requested', 'offered', 'tentative')
                       else (a ->> 'status') is null or b.status::text = a ->> 'status' end)
             and ((a ->> 'from') is null or b.return_at >= (a ->> 'from')::timestamptz)
             and ((a ->> 'to') is null or b.pickup_at <= (a ->> 'to')::timestamptz)
             and (v_q is null or app.search_key(b.booking_number) like '%' || app.search_key(v_q) || '%' or lower(coalesce(r.legal_name, '')) like app.search_like(v_q)
                  or lower(coalesce(r.email, '')) like app.search_like(v_q) or app.search_key(v.plate) = app.search_key(v_q))
           order by b.pickup_at desc limit v_lim) b), '[]'::jsonb);

    when 'get_booking' then
      select id into v_id from bookings where booking_number = upper(btrim(coalesce(a ->> 'booking_number', '')));
      if v_id is null then raise exception 'No booking %', a ->> 'booking_number' using errcode = 'P0002'; end if;
      v_target := 'booking ' || (a ->> 'booking_number');
      v_result := app.api_booking_row(v_id);

    when 'update_booking', 'update_request' then
      select id into v_id from bookings where booking_number = upper(btrim(coalesce(a ->> 'booking_number', '')));
      if v_id is null then raise exception 'No booking %', a ->> 'booking_number' using errcode = 'P0002'; end if;
      v_target := 'booking ' || upper(btrim(a ->> 'booking_number'));
      if p_tool = 'update_request' and not exists (select 1 from bookings where id = v_id and status::text = 'requested') then
        raise exception 'Only a request not yet offered can be changed here (its dates and places); change an offer or a booking in the portal' using errcode = '22023';
      end if;
      if jsonb_typeof(ch) <> 'object' or ch = '{}'::jsonb then raise exception 'Nothing to change: give "changes" with the fields to set' using errcode = '22023'; end if;
      select array_agg(x) into v_bad from jsonb_object_keys(ch) x where not (x = any (app.api_fields(p_tool)));
      if v_bad is not null then raise exception 'These fields cannot be changed here: %. Allowed: %', array_to_string(v_bad, ', '), array_to_string(app.api_fields(p_tool), ', ') using errcode = '22023'; end if;
      select jsonb_object_agg(x, to_jsonb(b) -> x) into v_before from bookings b, jsonb_object_keys(ch) x where b.id = v_id;
      for f in select jsonb_object_keys(ch) loop
        sets := sets || case when sets = '' then '' else ', ' end ||
          format('%I = (jsonb_populate_record(null::bookings, jsonb_build_object(%L, $1 -> %L))).%I', f, f, f, f);
      end loop;
      execute format('update bookings set %s where id = $2', sets) using ch, v_id;
      select jsonb_object_agg(x, to_jsonb(b) -> x) into v_after from bookings b, jsonb_object_keys(ch) x where b.id = v_id;
      v_result := app.api_booking_row(v_id);

    when 'list_owners' then
      v_result := coalesce((select jsonb_agg(jsonb_build_object('owner_id', o.id, 'name', o.legal_name, 'email', o.email, 'phone', o.phone, 'status', o.status,
                                 'cars', (select count(*) from vehicles v where v.owner_id = o.id and v.retired_at is null)) order by o.legal_name)
          from (select * from owners o where o.kind = 'program'
                  and (v_q is null or lower(o.legal_name) like app.search_like(v_q) or lower(coalesce(o.email, '')) like app.search_like(v_q)
                       or (length(app.search_digits(v_q)) >= 4 and app.search_digits(o.phone) like '%' || app.search_digits(v_q) || '%'))
                 order by o.legal_name limit v_lim) o), '[]'::jsonb);

    when 'get_owner' then
      v_id := nullif(a ->> 'owner_id', '')::uuid;
      if v_id is null or not exists (select 1 from owners where id = v_id) then raise exception 'No owner %', a ->> 'owner_id' using errcode = 'P0002'; end if;
      v_target := 'owner ' || v_id;
      v_result := app.api_owner_row(v_id);

    when 'update_owner' then
      v_id := nullif(a ->> 'owner_id', '')::uuid;
      if v_id is null or not exists (select 1 from owners where id = v_id) then raise exception 'No owner %', a ->> 'owner_id' using errcode = 'P0002'; end if;
      v_target := 'owner ' || v_id;
      if jsonb_typeof(ch) <> 'object' or ch = '{}'::jsonb then raise exception 'Nothing to change: give "changes" with the fields to set' using errcode = '22023'; end if;
      select array_agg(x) into v_bad from jsonb_object_keys(ch) x where not (x = any (app.api_fields(p_tool)));
      if v_bad is not null then raise exception 'These fields cannot be changed here: %. Allowed: %', array_to_string(v_bad, ', '), array_to_string(app.api_fields(p_tool), ', ') using errcode = '22023'; end if;
      select jsonb_object_agg(x, to_jsonb(o) -> x) into v_before from owners o, jsonb_object_keys(ch) x where o.id = v_id;
      for f in select jsonb_object_keys(ch) loop
        sets := sets || case when sets = '' then '' else ', ' end ||
          format('%I = (jsonb_populate_record(null::owners, jsonb_build_object(%L, $1 -> %L))).%I', f, f, f, f);
      end loop;
      execute format('update owners set %s where id = $2', sets) using ch, v_id;
      select jsonb_object_agg(x, to_jsonb(o) -> x) into v_after from owners o, jsonb_object_keys(ch) x where o.id = v_id;
      v_result := app.api_owner_row(v_id);
    end case;
  exception when others then
    -- the change (if any) is undone with this block; the call is still recorded
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client)
    values (k.id, k.user_id, p_tool, v_target, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', sqlerrm);
  end;

  -- whoami is the connector's check of the key before each message: not a call of its own
  if p_tool <> 'whoami' then
    insert into api_calls (key_id, user_id, tool, target, args, before, after, ok, client)
    values (k.id, k.user_id, p_tool, v_target, a, v_before, v_after, true, left(p_client, 64));
  end if;
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;

-- ================================================================ keys (Admin)
create or replace function app.api_key_create(p_admin uuid, p_user uuid, p_name text, p_scopes text[], p_hash text, p_prefix text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  perform app.assert_admin(p_admin);
  perform app.door_begin(p_admin, 'aal2');
  if not app.user_is_admin(p_user) then raise exception 'API access is for Admins only: give this person the Admin role first' using errcode = '42501'; end if;
  if (select count(*) from api_keys where user_id = p_user and kind = 'key' and revoked_at is null) >= 5 then
    raise exception 'This person already has 5 working keys: revoke one first' using errcode = '22023';
  end if;
  insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, created_by)
  values (p_user, 'key', btrim(p_name), p_prefix, p_hash, (select array_agg(distinct x order by x) from unnest(p_scopes) x), p_admin)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function app.api_key_revoke(p_admin uuid, p_id uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  perform app.door_begin(p_admin, 'aal2');
  update api_keys set revoked_at = now(), revoked_by = p_admin, refresh_hash = null where id = p_id and revoked_at is null;
  if not found then raise exception 'No working key with this id' using errcode = 'P0002'; end if;
  return jsonb_build_object('id', p_id, 'revoked', true);
end $$;

create or replace function app.api_access_view(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_admin);
  return jsonb_build_object(
    'enabled', (app.settings()).api_access_enabled, 'per_minute', (app.settings()).api_calls_per_minute,
    'admins', coalesce((select jsonb_agg(jsonb_build_object('user_id', u.id, 'email', u.email) order by u.email)
                          from users u where app.user_is_admin(u.id)), '[]'::jsonb),
    'keys', coalesce((select jsonb_agg(jsonb_build_object('id', k.id, 'kind', k.kind, 'name', k.name, 'prefix', k.prefix, 'scopes', k.scopes,
                        'email', u.email, 'client', c.client_name, 'created_at', k.created_at, 'last_used_at', k.last_used_at,
                        'expires_at', coalesce(k.refresh_expires_at, k.expires_at), 'revoked_at', k.revoked_at) order by k.revoked_at nulls first, k.created_at desc)
                        from api_keys k join users u on u.id = k.user_id left join api_oauth_clients c on c.id = k.oauth_client_id), '[]'::jsonb),
    'calls', coalesce((select jsonb_agg(x order by (x ->> 'id')::bigint desc) from (
                        select jsonb_build_object('id', c.id, 'at', c.created_at, 'email', u.email, 'key', k.name, 'tool', c.tool, 'target', c.target, 'ok', c.ok,
                                                  'error', c.error, 'before', c.before, 'after', c.after) x
                          from api_calls c left join users u on u.id = c.user_id left join api_keys k on k.id = c.key_id
                         order by c.id desc limit 100) s), '[]'::jsonb));
end $$;

-- ================================================================ OAuth (the Claude connector)
create or replace function app.api_oauth_register(p_client_id text, p_name text, p_redirects text[]) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare u text;
begin
  if not (app.settings()).api_access_enabled then raise exception 'API access is turned off' using errcode = '42501'; end if;
  foreach u in array coalesce(p_redirects, '{}') loop
    if not (u ~ '^https://(claude\.ai|claude\.com)/api/mcp/auth_callback$' or u ~ '^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/[A-Za-z0-9/_-]*$') then
      raise exception 'Redirect address not allowed: %', u using errcode = '22023';
    end if;
  end loop;
  if (select count(*) from api_oauth_clients where created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Too many registrations: try again later' using errcode = '54000';
  end if;
  insert into api_oauth_clients (client_id, client_name, redirect_uris) values (p_client_id, left(coalesce(nullif(btrim(p_name), ''), 'Claude'), 120), p_redirects);
  return jsonb_build_object('client_id', p_client_id);
end $$;

create or replace function app.api_oauth_client(p_client_id text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('client_id', c.client_id, 'client_name', c.client_name, 'redirect_uris', c.redirect_uris) from api_oauth_clients c where c.client_id = p_client_id
$$;

-- the person approved on the consent page: a code for the client (its hash; valid 5 minutes)
create or replace function app.api_oauth_approve(p_user uuid, p_client_id text, p_redirect text, p_challenge text, p_scopes text[], p_code_hash text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare c api_oauth_clients;
begin
  if not (app.settings()).api_access_enabled then raise exception 'API access is turned off in Admin > Settings > Program' using errcode = '42501'; end if;
  if not app.user_is_admin(p_user) then raise exception 'Connecting Claude is for Admins only' using errcode = '42501'; end if;
  select * into c from api_oauth_clients where client_id = p_client_id;
  if c.id is null then raise exception 'Unknown client' using errcode = 'P0002'; end if;
  if not (p_redirect = any (c.redirect_uris)) and not (p_redirect ~ '^http://(localhost|127\.0\.0\.1)(:[0-9]{1,5})?/' and exists (
      select 1 from unnest(c.redirect_uris) r where regexp_replace(r, ':[0-9]{1,5}/', '/') = regexp_replace(p_redirect, ':[0-9]{1,5}/', '/'))) then
    raise exception 'Redirect address not registered for this client' using errcode = '22023';
  end if;
  if not (p_scopes <@ array['bookings:read', 'bookings:write', 'owners:read', 'owners:write', 'requests:read', 'requests:write']) or cardinality(p_scopes) = 0 then
    raise exception 'Unknown scope' using errcode = '22023';
  end if;
  insert into api_oauth_codes (code_hash, client_id, user_id, redirect_uri, code_challenge, scopes, expires_at)
  values (p_code_hash, c.id, p_user, p_redirect, p_challenge, p_scopes, now() + interval '5 minutes');
  return jsonb_build_object('ok', true);
end $$;

-- the token endpoint: a code (with its PKCE challenge recomputed by the server from the verifier) or a refresh token
-- becomes an access token (1 hour) and a new refresh token (30 days); the old refresh token stops working
create or replace function app.api_oauth_token(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c api_oauth_clients;
  code api_oauth_codes;
  k api_keys;
  v_id uuid;
begin
  if not (app.settings()).api_access_enabled then return jsonb_build_object('error', 'access_denied', 'error_description', 'API access is turned off'); end if;
  select * into c from api_oauth_clients where client_id = p ->> 'client_id';
  if c.id is null then return jsonb_build_object('error', 'invalid_client'); end if;
  if p ->> 'grant_type' = 'authorization_code' then
    select * into code from api_oauth_codes where code_hash = p ->> 'code_hash' for update;
    if code.code_hash is null or code.used_at is not null or code.expires_at <= now() or code.client_id <> c.id then
      return jsonb_build_object('error', 'invalid_grant', 'error_description', 'The code is unknown, used or expired');
    end if;
    update api_oauth_codes set used_at = now() where code_hash = code.code_hash;
    if code.redirect_uri <> coalesce(p ->> 'redirect_uri', '') then return jsonb_build_object('error', 'invalid_grant', 'error_description', 'redirect_uri differs'); end if;
    if code.code_challenge <> coalesce(p ->> 'challenge', '') then return jsonb_build_object('error', 'invalid_grant', 'error_description', 'PKCE verification failed'); end if;
    if not app.user_is_admin(code.user_id) then return jsonb_build_object('error', 'access_denied'); end if;
    perform app.door_begin(code.user_id, 'aal2');
    insert into api_keys (user_id, kind, name, prefix, key_hash, scopes, oauth_client_id, refresh_hash, expires_at, refresh_expires_at, created_by)
    values (code.user_id, 'oauth', left('Claude connection: ' || c.client_name, 80), p ->> 'prefix', p ->> 'access_hash', code.scopes, c.id, p ->> 'refresh_hash',
            now() + interval '1 hour', now() + interval '30 days', code.user_id)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'scopes', code.scopes, 'expires_in', 3600);
  elsif p ->> 'grant_type' = 'refresh_token' then
    select * into k from api_keys where refresh_hash = p ->> 'old_refresh_hash' for update;
    if k.id is null or k.revoked_at is not null or k.refresh_expires_at <= now() or k.oauth_client_id <> c.id then
      return jsonb_build_object('error', 'invalid_grant', 'error_description', 'The refresh token is unknown, revoked or expired');
    end if;
    if not app.user_is_admin(k.user_id) then return jsonb_build_object('error', 'access_denied'); end if;
    perform app.door_begin(k.user_id, 'aal2');
    update api_keys set key_hash = p ->> 'access_hash', prefix = p ->> 'prefix', refresh_hash = p ->> 'refresh_hash',
           expires_at = now() + interval '1 hour', refresh_expires_at = now() + interval '30 days' where id = k.id;
    return jsonb_build_object('ok', true, 'scopes', k.scopes, 'expires_in', 3600);
  end if;
  return jsonb_build_object('error', 'unsupported_grant_type');
end $$;

-- ================================================================ the server's doors (service role only)
create or replace function public.server_api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_call(p_hash, p_tool, p_args, p_client) $$;
create or replace function public.server_api_key_create(p_admin uuid, p_user uuid, p_name text, p_scopes text[], p_hash text, p_prefix text) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_key_create(p_admin, p_user, p_name, p_scopes, p_hash, p_prefix) $$;
create or replace function public.server_api_key_revoke(p_admin uuid, p_id uuid) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_key_revoke(p_admin, p_id) $$;
create or replace function public.server_api_access_view(p_admin uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.api_access_view(p_admin) $$;
create or replace function public.server_api_oauth_register(p_client_id text, p_name text, p_redirects text[]) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_oauth_register(p_client_id, p_name, p_redirects) $$;
create or replace function public.server_api_oauth_client(p_client_id text) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.api_oauth_client(p_client_id) $$;
create or replace function public.server_api_oauth_approve(p_user uuid, p_client_id text, p_redirect text, p_challenge text, p_scopes text[], p_code_hash text) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_oauth_approve(p_user, p_client_id, p_redirect, p_challenge, p_scopes, p_code_hash) $$;
create or replace function public.server_api_oauth_token(p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_oauth_token(p) $$;

do $$
declare f text;
begin
  foreach f in array array['app.api_call(text, text, jsonb, text)', 'app.api_key_create(uuid, uuid, text, text[], text, text)', 'app.api_key_revoke(uuid, uuid)',
                           'app.api_access_view(uuid)', 'app.api_oauth_register(text, text, text[])', 'app.api_oauth_client(text)',
                           'app.api_oauth_approve(uuid, text, text, text, text[], text)', 'app.api_oauth_token(jsonb)',
                           'app.api_booking_row(uuid)', 'app.api_owner_row(uuid)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['public.server_api_call(text, text, jsonb, text)', 'public.server_api_key_create(uuid, uuid, text, text[], text, text)',
                           'public.server_api_key_revoke(uuid, uuid)', 'public.server_api_access_view(uuid)', 'public.server_api_oauth_register(text, text, text[])',
                           'public.server_api_oauth_client(text)', 'public.server_api_oauth_approve(uuid, text, text, text, text[], text)', 'public.server_api_oauth_token(jsonb)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- the server may run every function of the app schema (suites 06, 08 and 09)
do $g$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and not has_function_privilege('service_role', p.oid, 'execute') loop
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $g$;
