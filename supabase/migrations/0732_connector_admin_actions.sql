-- 0732_connector_admin_actions.sql
-- Release 33, part G (docs/changes/2026-11-07-r33-hire-academy-connector.md, item 3): the Claude connector (/api/mcp,
-- 0562) runs the platform as an Admin does. Before: whoami and reading and lightly editing bookings, requests and owners.
-- Now also, through the very same database actions the Admin screens use (app.door as the key's Admin, aal2):
--   bookings  send, revise, withdraw or make an offer; change a booking or its fees; record a payment; request a refund;
--             cancel; record a pickup or a return
--   cars      rates, a fee for one car, publish now, take off the site
--   owners    terms of a car, issue, void or resend an invoice
--   staff     hire a candidate (one-step Hire, 0730), set a person's functions, end their access, verify pay details
--   reads     Program settings, cars, candidates, staff, a hire's onboarding
-- Every write is two calls. The first (no confirm) is a preview: the action runs inside a savepoint that is always rolled
-- back, so it passes every check the screen would, and the answer shows the record before and after and the fields that
-- would change; nothing is kept but the preview (api_previews, 10 minutes). The second call repeats the same arguments
-- with confirm: true and the preview_id, and does it. Both calls go through the key, scope, Admin and rate-limit checks of
-- 0562 and are logged in api_calls with the values before and after.
-- New scopes admin:read and admin:write. A key or connection made with every scope of 0562 (full access) gets the two new
-- ones too, so full access stays full access; keys with fewer scopes are unchanged. New keys and connections offer them.

-- ================================================================ 1. scopes
alter table api_keys drop constraint if exists api_keys_scopes_check;
alter table api_keys add constraint api_keys_scopes_check check (cardinality(scopes) >= 1 and scopes <@ array['bookings:read', 'bookings:write', 'owners:read', 'owners:write',
  'requests:read', 'requests:write', 'admin:read', 'admin:write']);
update api_keys set scopes = scopes || array['admin:read', 'admin:write']
 where revoked_at is null and scopes @> array['bookings:read', 'bookings:write', 'owners:read', 'owners:write', 'requests:read', 'requests:write'] and not ('admin:write' = any (scopes));

create or replace function app.api_scopes_known() returns text[]
language sql immutable as $$ select array['bookings:read', 'bookings:write', 'owners:read', 'owners:write', 'requests:read', 'requests:write', 'admin:read', 'admin:write'] $$;

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
  if not (p_scopes <@ app.api_scopes_known()) or cardinality(p_scopes) = 0 then raise exception 'Unknown scope' using errcode = '22023'; end if;
  insert into api_oauth_codes (code_hash, client_id, user_id, redirect_uri, code_challenge, scopes, expires_at)
  values (p_code_hash, c.id, p_user, p_redirect, p_challenge, p_scopes, now() + interval '5 minutes');
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 2. the previews
create table if not exists api_previews (
  id         uuid primary key default gen_random_uuid(),
  key_id     uuid not null references api_keys (id) on delete cascade,
  user_id    uuid not null references users (id) on delete cascade,
  tool       text not null,
  args       jsonb not null,
  before     jsonb,
  after      jsonb,
  created_at timestamptz not null default now(),
  used_at    timestamptz
);
create index if not exists api_previews_key_idx on api_previews (key_id, created_at desc);
comment on table api_previews is 'A connector write previewed (0732): the tool, its arguments, the record before and after the rolled-back run. The confirming call must name it, within 10 minutes, with the same arguments; it is used once.';
alter table api_previews enable row level security;
revoke all on api_previews from public, anon, authenticated;
grant select on api_previews to authenticated;
grant select, insert, update on api_previews to service_role;
drop policy if exists admin_all on api_previews;
create policy admin_all on api_previews for select to authenticated using (app.is_admin());

-- ================================================================ 3. the actions: each tool is one door action of the Admin screens
create or replace function app.api_action(p_tool text) returns jsonb
language sql immutable as $$
  select (case p_tool
    when 'send_offer'           then '{"call":"admin_do","name":"send_offer","target":"booking"}'
    when 'withdraw_offer'       then '{"call":"admin_do","name":"withdraw_offer","target":"booking"}'
    when 'create_offer'         then '{"call":"ops_do","name":"offer_create","target":"new_booking"}'
    when 'revise_offer'         then '{"call":"ops_do","name":"offer_revise","target":"booking"}'
    when 'change_booking'       then '{"call":"ops_do","name":"booking_staff_edit","target":"booking"}'
    when 'change_booking_fees'  then '{"call":"ops_do","name":"booking_fees_change","target":"booking"}'
    when 'record_payment'       then '{"call":"ops_do","name":"record_booking_payment","target":"booking"}'
    when 'request_refund'       then '{"call":"admin_do","name":"request_refund","target":"booking"}'
    when 'cancel_booking'       then '{"call":"admin_do","name":"cancel_booking","target":"booking"}'
    when 'record_handover'      then '{"call":"ops_do","name":"handover_record_now","target":"booking"}'
    when 'set_car_rates'        then '{"call":"ops_do","name":"rate_card_save","target":"vehicle"}'
    when 'set_car_fee'          then '{"call":"admin_do","name":"fee_override","target":"vehicle"}'
    when 'publish_car'          then '{"call":"ops_do","name":"listing_publish_now","target":"vehicle"}'
    when 'unlist_car'           then '{"call":"admin_do","name":"listing_unlist","target":"vehicle"}'
    when 'change_owner_terms'   then '{"call":"ops_do","name":"owner_terms_save","target":"vehicle"}'
    when 'issue_owner_invoice'  then '{"call":"ops_do","name":"owner_invoice_issue","target":"invoice"}'
    when 'void_owner_invoice'   then '{"call":"ops_do","name":"owner_invoice_void","target":"invoice"}'
    when 'resend_owner_invoice' then '{"call":"ops_do","name":"owner_invoice_resend","target":"invoice"}'
    when 'set_staff_functions'  then '{"call":"admin_do","name":"staff_functions","target":"staff"}'
    when 'end_staff_access'     then '{"call":"admin_do","name":"staff_end","target":"staff"}'
    when 'verify_staff_pay_details' then '{"call":"admin_do","name":"staff_payout_verify","target":"payout"}'
    when 'hire_applicant'       then '{"call":"web","name":"hire","target":"application"}'
  end)::jsonb
$$;

create or replace function app.api_admin_reads() returns text[]
language sql immutable as $$ select array['get_settings', 'list_cars', 'get_car', 'list_applicants', 'get_hire_status', 'list_staff'] $$;

create or replace function app.api_vehicle_row(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('vehicle_id', v.id, 'car', app.vehicle_name(v.id), 'plate', v.plate, 'vin', v.vin, 'status', v.status, 'bookings_enabled', v.bookings_enabled,
           'owner_id', v.owner_id, 'owner', (select o.legal_name from owners o where o.id = v.owner_id), 'class', v.class, 'retired_at', v.retired_at,
           'rates', (select jsonb_build_object('daily_cents', r.daily_rate_cents, 'weekend_cents', r.weekend_rate_cents, 'weekly_cents', r.weekly_rate_cents,
                                               'monthly_cents', r.monthly_rate_cents, 'km_per_day', r.km_allowance_per_day, 'deposit_cents', r.deposit_cents, 'from', r.effective_from)
                       from rate_cards r where r.vehicle_id = v.id and (r.effective_to is null or r.effective_to > now()) order by r.effective_from desc limit 1),
           'fee_overrides', coalesce((select jsonb_agg(jsonb_build_object('fee', f.fee_type_code, 'amount_cents', f.amount_cents, 'percent_bps', f.percent_bps, 'cap_cents', f.cap_cents, 'from', f.effective_from))
                                        from vehicle_fee_overrides f where f.vehicle_id = v.id and (f.effective_to is null or f.effective_to > app.today())), '[]'::jsonb),
           'admin_path', '/admin/vehicles/' || v.id)
    from vehicles v where v.id = p_id
$$;

create or replace function app.api_staff_row(p_id uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('user_id', u.id, 'name', u.full_name, 'email', u.email, 'status', u.status,
           'roles', (select coalesce(jsonb_agg(r.role order by r.role), '[]'::jsonb) from user_roles r where r.user_id = u.id),
           'functions', to_jsonb(sp.functions), 'sales_work_mode', sp.sales_work_mode, 'started_on', sp.started_on, 'active', sp.is_active,
           'pay_details', (select app.staff_payout_masked(x) || case when x.verified_at is null then ' (not verified)' else '' end from staff_payout_accounts x where x.user_id = u.id and x.is_current),
           'admin_path', '/admin/settings/staff')
    from users u left join staff_profiles sp on sp.user_id = u.id where u.id = p_id
$$;

-- the record a write acts on, as it is now (the before and after of a preview and of the confirmed call)
create or replace function app.api_target(p_kind text, a jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v_id uuid;
begin
  case p_kind
  when 'booking' then
    select id into v_id from bookings where id::text = a ->> 'booking' or booking_number = upper(btrim(coalesce(a ->> 'booking', a ->> 'booking_number', '')));
    return case when v_id is null then null else app.api_booking_row(v_id) end;
  when 'vehicle' then
    v_id := nullif(coalesce(a ->> 'vehicle', a ->> 'vehicle_id'), '')::uuid;
    return app.api_vehicle_row(v_id);
  when 'invoice' then
    return (select jsonb_build_object('invoice_id', i.id, 'invoice_number', i.invoice_number, 'owner', (select o.legal_name from owners o where o.id = i.owner_id), 'status', i.status,
                     'kind', i.kind, 'total_cents', i.total_cents, 'paid_cents', i.paid_cents, 'balance_cents', i.balance_cents, 'due_on', i.due_on, 'issued_at', i.issued_at,
                     'voided_at', i.voided_at, 'email_count', i.email_count) from owner_invoices i where i.id::text = a ->> 'id');
  when 'staff' then
    v_id := nullif(coalesce(a ->> 'user_id', a ->> 'user'), '')::uuid;
    return app.api_staff_row(v_id);
  when 'payout' then
    return (select jsonb_build_object('id', x.id, 'user_id', x.user_id, 'shown', app.staff_payout_masked(x), 'verified_at', x.verified_at) from staff_payout_accounts x where x.id::text = a ->> 'id');
  else return null;
  end case;
exception when invalid_text_representation then return null;
end $$;

-- the fields that differ between two records
create or replace function app.api_diff(b jsonb, x jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_object('before', b -> k, 'after', x -> k)), '{}'::jsonb)
    from (select jsonb_object_keys(coalesce(b, '{}'::jsonb) || coalesce(x, '{}'::jsonb)) k) s
   where (b -> k) is distinct from (x -> k) and k <> 'admin_path'
$$;

-- ================================================================ 4. the call
do $$ begin
  if to_regprocedure('app.api_call_pre0732(text,text,jsonb,text)') is null then
    alter function app.api_call(text, text, jsonb, text) rename to api_call_pre0732;
  end if;
end $$;

create or replace function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  k api_keys;
  act jsonb := app.api_action(p_tool);
  v_read boolean := p_tool = any (app.api_admin_reads());
  v_scope text;
  a jsonb := coalesce(p_args, '{}'::jsonb);
  v_door jsonb;
  v_confirm boolean;
  v_n integer;
  v_lim integer;
  v_q text;
  v_target text;
  v_before jsonb;
  v_after jsonb;
  v_out jsonb;
  v_err text;
  v_result jsonb;
  pv api_previews;
  v_bk text;
begin
  if act is null and not v_read then return app.api_call_pre0732(p_hash, p_tool, p_args, p_client); end if;
  v_scope := case when v_read then 'admin:read' else 'admin:write' end;
  -- the checks of 0562: the switch, the key, the Admin, the scope, the rate limit
  if not s.api_access_enabled then return jsonb_build_object('ok', false, 'status', 403, 'error', 'API access is turned off in Admin > Settings > Program.'); end if;
  if p_hash is null or p_hash !~ '^[0-9a-f]{64}$' then return jsonb_build_object('ok', false, 'status', 401, 'error', 'Missing or malformed key.'); end if;
  select * into k from api_keys where key_hash = p_hash;
  if k.id is null or k.revoked_at is not null or (k.expires_at is not null and k.expires_at <= now()) then
    return jsonb_build_object('ok', false, 'status', 401, 'error', 'This key is not valid (unknown, revoked or expired).');
  end if;
  if not app.user_is_admin(k.user_id) then return jsonb_build_object('ok', false, 'status', 403, 'error', 'Only an active Admin may use API access.'); end if;
  if jsonb_typeof(a) <> 'object' then a := '{}'::jsonb; end if;
  if not (v_scope = any (k.scopes)) then
    insert into api_calls (key_id, user_id, tool, args, ok, error, client) values (k.id, k.user_id, p_tool, a, false, 'scope ' || v_scope || ' not granted', left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', 403, 'error', format('This key does not have the %s scope. Make a new key with it in Admin > Settings > API access, or reconnect Claude.', v_scope));
  end if;
  select count(*) into v_n from api_calls c where c.key_id = k.id and c.created_at > now() - interval '1 minute';
  if v_n >= s.api_calls_per_minute then
    return jsonb_build_object('ok', false, 'status', 429, 'error', format('Too many calls: at most %s a minute. Wait a moment.', s.api_calls_per_minute));
  end if;
  update api_keys set last_used_at = now() where id = k.id;
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_door := a - 'confirm' - 'preview_id';
  v_lim := least(greatest(coalesce((a ->> 'limit')::integer, 20), 1), 50);
  v_q := nullif(btrim(coalesce(a ->> 'query', '')), '');

  begin
    if v_read then
      case p_tool
      when 'get_settings' then
        -- Settings as Admin > Settings reads them: one part by name, else the Program settings and the site settings with the
        -- names of the other parts (fees, deposit tiers, classes, coverage, promo codes, ...); the staff are list_staff
        v_out := app.door(k.user_id, 'aal2', 'admin_read', 'settings', '{}'::jsonb);
        v_result := case when nullif(a ->> 'section', '') is not null then jsonb_build_object(a ->> 'section', v_out -> (a ->> 'section'), 'sections', (select jsonb_agg(x order by x) from jsonb_object_keys(v_out) x))
                         else jsonb_build_object('program', v_out -> 'program', 'site', v_out -> 'site', 'sections', (select jsonb_agg(x order by x) from jsonb_object_keys(v_out) x)) end;
        v_out := null;
      when 'list_cars' then
        v_result := coalesce((select jsonb_agg(app.api_vehicle_row(v.id) order by v.created_at desc) from (
            select v.id, v.created_at from vehicles v
             where v.retired_at is null and not coalesce(v.is_sample, false)
               and ((a ->> 'status') is null or v.status::text = a ->> 'status')
               and (v_q is null or app.search_key(v.plate) = app.search_key(v_q) or lower(app.vehicle_name(v.id)) like app.search_like(v_q) or v.vin = upper(v_q))
             order by v.created_at desc limit v_lim) v), '[]'::jsonb);
      when 'get_car' then
        v_result := app.api_vehicle_row(nullif(a ->> 'vehicle_id', '')::uuid);
        if v_result is null then raise exception 'No car %', a ->> 'vehicle_id' using errcode = 'P0002'; end if;
        v_target := 'vehicle ' || (a ->> 'vehicle_id');
      when 'list_applicants' then
        v_result := coalesce((select jsonb_agg(jsonb_build_object('application_id', x.id, 'name', x.full_name, 'email', x.email, 'role', r.title, 'status', x.status, 'score', x.score,
                                  'applied_at', x.created_at, 'admin_path', '/admin/hiring/' || x.id) order by x.created_at desc)
            from (select * from job_applications j where j.purged_at is null
                    and ((a ->> 'status') is null or j.status = a ->> 'status')
                    and (v_q is null or lower(j.full_name) like app.search_like(v_q) or lower(coalesce(j.email, '')) like app.search_like(v_q))
                  order by j.created_at desc limit v_lim) x join hiring_roles r on r.id = x.role_id), '[]'::jsonb);
      when 'get_hire_status' then
        v_result := app.hire_status(k.user_id, jsonb_build_object('id', coalesce(a ->> 'application_id', a ->> 'id')));
        v_target := 'application ' || coalesce(a ->> 'application_id', a ->> 'id');
      when 'list_staff' then
        v_result := coalesce((select jsonb_agg(app.api_staff_row(u.id) order by u.full_name) from users u
                               where exists (select 1 from user_roles r where r.user_id = u.id and r.role in ('va', 'field', 'admin'))
                                 and (v_q is null or lower(coalesce(u.full_name, '')) like app.search_like(v_q) or lower(u.email) like app.search_like(v_q))), '[]'::jsonb);
      end case;

    elsif not v_confirm then
      -- the preview: the action runs and is rolled back; only the preview is kept
      if act ->> 'call' = 'web' then
        v_door := v_door || jsonb_build_object('id', coalesce(v_door ->> 'application_id', v_door ->> 'id'));
        v_out := app.hire_preview(k.user_id, v_door);
        if not coalesce((v_out ->> 'can_hire')::boolean, false) then
          raise exception 'This candidate cannot be hired (status %)', v_out #>> '{application,status}' using errcode = '23514';
        end if;
        v_target := 'application ' || (v_door ->> 'id');
        v_before := v_out -> 'application';
      else
        v_before := app.api_target(act ->> 'target', v_door);
        begin
          v_out := app.door(k.user_id, 'aal2', act ->> 'call', act ->> 'name', v_door);
          v_bk := coalesce(v_out ->> 'booking_number', v_out ->> 'booking_id');
          v_after := case when act ->> 'target' = 'new_booking' then app.api_target('booking', jsonb_build_object('booking', v_bk))
                          else app.api_target(act ->> 'target', v_door) end;
          raise exception 'cc_api_preview_rollback';
        exception when others then
          if sqlerrm <> 'cc_api_preview_rollback' then v_err := regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''); end if;
        end;
        if v_err is not null then raise exception 'It would be refused: %', v_err using errcode = '22023'; end if;
      end if;
      insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_door, v_before, v_after) returning * into pv;
      v_target := coalesce(v_target, 'preview ' || pv.id);
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes',
        'will_change', case when act ->> 'call' = 'web' then null else app.api_diff(v_before, v_after) end,
        'before', v_before, 'after', v_after, 'would_return', v_out,
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
      v_after := null;

    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if act ->> 'call' = 'web' then v_door := v_door || jsonb_build_object('id', coalesce(v_door ->> 'application_id', v_door ->> 'id')); end if;
      if pv.args is distinct from v_door then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      if act ->> 'call' = 'web' then
        -- the hire runs in the web layer (the sign-in is made there), as this Admin
        v_target := 'application ' || (v_door ->> 'id');
        v_result := jsonb_build_object('run', 'hire', 'actor', k.user_id, 'params', v_door);
      else
        v_before := app.api_target(act ->> 'target', v_door);
        perform set_config('app.via', 'via Claude connector', true);
        v_out := app.door(k.user_id, 'aal2', act ->> 'call', act ->> 'name', v_door);
        perform set_config('app.via', '', true);
        v_bk := coalesce(v_out ->> 'booking_number', v_out ->> 'booking_id');
        v_after := case when act ->> 'target' = 'new_booking' then app.api_target('booking', jsonb_build_object('booking', v_bk)) else app.api_target(act ->> 'target', v_door) end;
        v_target := coalesce(v_after ->> 'booking_number', v_door ->> 'booking', v_door ->> 'vehicle', v_door ->> 'vehicle_id', v_door ->> 'id', v_door ->> 'user_id', v_door ->> 'user');
        v_result := jsonb_build_object('done', true, 'tool', p_tool, 'changed', app.api_diff(v_before, v_after), 'after', v_after, 'result', v_out);
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client)
    values (k.id, k.user_id, p_tool, v_target, a, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;

  insert into api_calls (key_id, user_id, tool, target, args, before, after, ok, client)
  values (k.id, k.user_id, case when not v_read and not v_confirm then p_tool || ':preview' else p_tool end, left(v_target, 200), a, v_before, v_after, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;

-- the web layer reports how a connector hire went (it is logged like the call)
create or replace function app.api_hire_result(p_hash text, p_application uuid, p_ok boolean, p_error text, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare k api_keys;
begin
  select * into k from api_keys where key_hash = p_hash;
  if k.id is null then return jsonb_build_object('ok', false); end if;
  insert into api_calls (key_id, user_id, tool, target, args, after, ok, error, client)
  values (k.id, k.user_id, 'hire_applicant:run', 'application ' || p_application, jsonb_build_object('application_id', p_application),
          case when p_ok then app.hire_status(k.user_id, jsonb_build_object('id', p_application)) end, p_ok, left(p_error, 500), left(p_client, 64));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.server_api_hire_result(p_hash text, p_application uuid, p_ok boolean, p_error text, p_client text default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_hire_result(p_hash, p_application, p_ok, p_error, p_client) $$;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['api_call', 'api_call_pre0732', 'api_action', 'api_admin_reads', 'api_scopes_known', 'api_oauth_approve',
              'api_vehicle_row', 'api_staff_row', 'api_target', 'api_diff', 'api_hire_result']))
        or (n.nspname = 'public' and p.proname = 'server_api_hire_result')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
