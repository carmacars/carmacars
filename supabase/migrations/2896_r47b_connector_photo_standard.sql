-- 2896 (release 47, part B): the CarmaCars connector reads the listing photo standard (r45, 2840 to 2842), so Claude
-- answers "are the photos done?" without opening Admin. One read-only tool, photo_standard {vehicle?} (admin:read), logged
-- in api_calls like every call:
--   per car: photos (current, not rejected), public (on the site now), at the standard (made by Gemini at app.photo_spec()),
--   flagged (kept off the site, each with the check's why and reasons, tries and when), queued, AI angles (generated
--   views on the site, and the standard angles still missing), the first photo's shot type, and the public cover: a real
--   photo, a sample photo, or none (not listed);
--   fleet totals, and Gemini today: image calls used, the daily limit, the reserve kept for new uploads, what is left, and
--   the photos waiting for it.
-- A vehicle filter takes the car's id, fleet number or plate; without one, every car the standard applies to (not a sample
-- car, not retired, with a current photo or a live listing), newest listed first.
-- Also Stripe, read live by the web layer with the server's key (features/api-access/stripe-inspect.ts): the database
-- checks the key and the scope, logs the call and gives what the site recorded; the web reads Stripe (GET only):
--   stripe_booking {booking} (admin:read): every PaymentIntent, charge and SetupIntent the booking references or that
--     Stripe finds by its metadata, beside the site's payments, holds and pay links, with a one-line verdict;
--   stripe_account {} (admin:read): the balance, payouts and the next payout, and the account's open requirements;
--   stripe_record_paid {booking, payment_intent} (admin:write, previewed then confirmed): a PaymentIntent Stripe shows
--     succeeded for this booking and the site never recorded is recorded exactly as the webhook would (settleIntent);
--     nothing is charged or captured (the web refuses any intent that is not succeeded).
-- docs/changes/2026-11-14-r47b-crash-alerts-photo-standard.md. SCHEMA_MARKER 2896.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. one car
create or replace function app.photo_standard_car(p_vehicle uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with pub as (select coalesce(app.public_listing_photos(p_vehicle), '[]'::jsonb) j),
       row_ as (select app.public_listing_row_live(p_vehicle) r)
  select jsonb_build_object(
    'vehicle_id', v.id, 'car', app.vehicle_name(v.id), 'fleet_number', v.fleet_number, 'plate', v.plate,
    'listing', (select l.status from vehicle_listings l where l.vehicle_id = v.id order by l.created_at desc limit 1),
    'photos', (select count(*) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected'),
    'public', (select jsonb_array_length(j) from pub),
    'standard_applies', (select count(*) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected' and app.photo_r45_applies(ph)),
    'at_standard', (select count(*) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected' and app.photo_r45_applies(ph) and ph.r45 ->> 'spec' = app.photo_spec() and ph.r45 ->> 'state' = 'done'),
    'queued', (select count(*) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected' and app.photo_r45_applies(ph) and ph.r45 ->> 'state' = 'queued'),
    'flagged', (select count(*) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected' and app.photo_r45_applies(ph) and ph.r45 ->> 'state' = 'flagged'),
    'flagged_photos', coalesce((select jsonb_agg(jsonb_build_object('photo_id', ph.id, 'shot', ph.shot_type, 'ai_generated', ph.ai_generated,
                                   'why', ph.r45 -> 'why', 'reasons', coalesce(ph.r45 -> 'reasons', '[]'::jsonb), 'tries', ph.r45 -> 'tries', 'at', ph.r45 -> 'at')
                                   order by app.photo_rank(ph.shot_type), ph.id)
                                  from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected' and app.photo_r45_applies(ph) and ph.r45 ->> 'state' = 'flagged'), '[]'::jsonb),
    'ai_angles', (select count(*) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected' and ph.ai_generated and ph.r45 ->> 'state' = 'done'),
    'ai_angle_shots', coalesce((select jsonb_agg(ph.shot_type order by app.photo_rank(ph.shot_type)) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected' and ph.ai_generated and ph.r45 ->> 'state' = 'done'), '[]'::jsonb),
    'missing_angles', coalesce((select jsonb_agg(m) from app.photo_r45_missing(v.id) m), '[]'::jsonb),
    'first_photo_shot', (select j -> 0 ->> 'shot' from pub),
    'first_photo_ai', (select coalesce((j -> 0 ->> 'generated')::boolean, false) from pub),
    'cover', (select case when r is null then 'none'
                          when coalesce((r ->> 'sample_photos')::boolean, false) then 'sample'
                          when nullif(r #>> '{cover,path}', '') is null then 'none'
                          else 'real' end from row_),
    'done', app.photo_r45_car_done(v.id),
    'last_run', (select max((ph.r45 ->> 'at')::timestamptz) from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected'),
    'admin_path', '/admin/vehicles/' || v.id)
  from vehicles v where v.id = p_vehicle
$$;
comment on function app.photo_standard_car(uuid) is 'r47 (2896): one car against the listing photo standard (r45) for the connector''s photo_standard: counts, flagged photos with why and reasons, AI angles, the first photo and the cover (real, sample, none).';

-- ================================================================ 2. the read: one car or the fleet, and Gemini today
-- p: vehicle (id, fleet number or plate) | limit (cars, 200 by default)
create or replace function app.photo_standard_read(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  ps program_settings := app.settings();
  q text := nullif(btrim(coalesce(p ->> 'vehicle', '')), '');
  v_lim integer := least(greatest(coalesce(nullif(p ->> 'limit', '')::integer, 200), 1), 500);
  v_one uuid;
  v_cars jsonb;
  v_used integer;
begin
  if not app.photo_r45_may(p_by) then raise exception 'An Admin or fleet sees the photo standard' using errcode = '42501'; end if;
  if q is not null then
    select v.id into v_one from vehicles v
     where v.id::text = lower(q) or upper(btrim(v.fleet_number)) = upper(q)
        or upper(regexp_replace(coalesce(v.plate, ''), '[^A-Za-z0-9]', '', 'g')) = upper(regexp_replace(q, '[^A-Za-z0-9]', '', 'g'))
     order by (v.id::text = lower(q)) desc, v.retired_at nulls first limit 1;
    if v_one is null then raise exception 'No car matches "%": give its vehicle id, fleet number or plate', left(q, 60) using errcode = 'P0002'; end if;
    v_cars := jsonb_build_array(app.photo_standard_car(v_one));
  else
    select coalesce(jsonb_agg(app.photo_standard_car(c.id) order by c.listed_at desc, c.id), '[]'::jsonb) into v_cars
      from (select v.id, coalesce((select max(i.created_at) from listing_intakes i where i.vehicle_id = v.id), v.created_at) listed_at
              from vehicles v
             where not coalesce(v.is_sample, false) and v.retired_at is null
               and (exists (select 1 from vehicle_photos ph where ph.vehicle_id = v.id and ph.replaced_at is null and ph.status <> 'rejected')
                    or exists (select 1 from vehicle_listings l where l.vehicle_id = v.id and l.status in ('published', 'paused')))
             order by 2 desc, v.id limit v_lim) c;
  end if;
  v_used := (select count(*)::integer from provider_calls c where c.purpose = 'listing_showroom' and c.created_at >= app.local_midnight(app.local_date(now())));
  return jsonb_build_object(
    'spec', app.photo_spec(),
    'auto', coalesce(ps.listing_photo_r45_auto, true) and coalesce(ps.listing_showroom_ai, false),
    'gemini', jsonb_build_object('used_today', v_used, 'daily_limit', ps.listing_showroom_ai_daily, 'reserve', ps.listing_photo_r45_reserve,
                                 'left_today', app.photo_gemini_left(0), 'waiting', app.photo_r45_outstanding(), 'day', app.local_date(now())),
    'totals', (select jsonb_build_object('cars', count(*), 'cars_done', count(*) filter (where (c ->> 'done')::boolean),
                 'photos', coalesce(sum((c ->> 'photos')::integer), 0), 'public', coalesce(sum((c ->> 'public')::integer), 0),
                 'at_standard', coalesce(sum((c ->> 'at_standard')::integer), 0), 'flagged', coalesce(sum((c ->> 'flagged')::integer), 0),
                 'queued', coalesce(sum((c ->> 'queued')::integer), 0), 'ai_angles', coalesce(sum((c ->> 'ai_angles')::integer), 0),
                 'missing_angles', coalesce(sum(jsonb_array_length(c -> 'missing_angles')), 0),
                 'cover_real', count(*) filter (where c ->> 'cover' = 'real'), 'cover_sample', count(*) filter (where c ->> 'cover' = 'sample'),
                 'cover_none', count(*) filter (where c ->> 'cover' = 'none'),
                 'first_photo_inside', count(*) filter (where c ->> 'first_photo_shot' is not null and not app.photo_is_exterior(c ->> 'first_photo_shot')))
               from jsonb_array_elements(v_cars) c),
    'cars', v_cars);
end $$;
comment on function app.photo_standard_read(uuid, jsonb) is 'r47 (2896): the listing photo standard for the connector (photo_standard): per car and fleet totals, and Gemini''s use today. An Admin or fleet.';

-- ================================================================ 3. what the site recorded for a booking's money (stripe_booking)
create or replace function app.stripe_booking_recorded(p_booking text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare b bookings;
begin
  select * into b from bookings where booking_number = upper(btrim(coalesce(p_booking, ''))) or id::text = lower(btrim(coalesce(p_booking, ''))) limit 1;
  if b.id is null then raise exception 'No booking %', left(coalesce(p_booking, ''), 40) using errcode = 'P0002'; end if;
  return jsonb_build_object('booking_id', b.id, 'booking_number', b.booking_number, 'status', b.status::text,
    'renter_due_at_booking_cents', b.renter_due_at_booking_cents, 'deposit_cents', b.deposit_cents,
    'payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'purpose', p.purpose, 'kind', p.kind, 'status', p.status, 'amount_cents', p.amount_cents,
                          'card', nullif(concat_ws(' ', p.card_brand, p.card_last4), ''), 'dispute_status', p.dispute_status, 'last_decline_code', p.last_decline_code,
                          'created_at', p.created_at, 'intent', d.processor_payment_id, 'charge', d.processor_charge_id, 'refund', d.processor_refund_id) order by p.created_at)
                          from payments p left join payment_processor_details d on d.payment_id = p.id where p.booking_id = b.id), '[]'::jsonb),
    'holds', coalesce((select jsonb_agg(jsonb_build_object('status', x.status, 'method', x.method, 'amount_cents', x.amount_cents, 'captured_cents', x.captured_cents,
                          'released_cents', x.released_cents, 'hold_expires_at', x.hold_expires_at, 'intent',
                          (select d.processor_payment_id from payment_processor_details d where d.payment_id = x.hold_payment_id)))
                          from deposits x where x.booking_id = b.id), '[]'::jsonb),
    'pay_links', coalesce((select jsonb_agg(jsonb_build_object('kind', q.kind, 'covers', q.covers, 'amount_cents', q.amount_cents, 'status', q.status,
                          'intent', q.processor_intent_id, 'expires_at', q.expires_at, 'last_error', q.last_error) order by q.created_at)
                          from payment_requests q where q.booking_id = b.id and (q.status = 'open' or q.processor_intent_id is not null)), '[]'::jsonb),
    'intents', coalesce((select jsonb_agg(distinct x.i) from (
                          select d.processor_payment_id i from payments p join payment_processor_details d on d.payment_id = p.id where p.booking_id = b.id and d.processor = 'stripe'
                          union select o.processor_payment_id from payment_intents_opened o where o.booking_id = b.id and o.processor = 'stripe'
                          union select q.processor_intent_id from payment_requests q where q.booking_id = b.id) x where x.i ~ '^(pi|seti)_[A-Za-z0-9]{6,}$'), '[]'::jsonb));
end $$;
comment on function app.stripe_booking_recorded(text) is 'r47 (2896): what the site recorded of a booking''s money (payments, holds, pay links, the Stripe ids it knows), for the connector''s stripe_booking.';

-- ================================================================ 4. the connector
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre2896;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  v_write boolean := p_tool = 'stripe_record_paid';
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  v_rec jsonb;
  v_result jsonb;
  v_target text := left(coalesce(nullif(a ->> 'vehicle', ''), nullif(a ->> 'booking', ''), p_tool), 200);
begin
  if p_tool not in ('photo_standard', 'stripe_booking', 'stripe_account', 'stripe_record_paid') then return app.api_call_pre2896(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, case when v_write then 'admin:write' else 'admin:read' end, p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if p_tool = 'photo_standard' then
      v_result := app.photo_standard_read(k.user_id, jsonb_build_object('vehicle', a ->> 'vehicle', 'limit', a ->> 'limit'));
    elsif p_tool = 'stripe_account' then
      v_result := jsonb_build_object('run', 'stripe_account');
    elsif p_tool = 'stripe_booking' then
      v_result := jsonb_build_object('run', 'stripe_booking', 'recorded', app.stripe_booking_recorded(v_args ->> 'booking'));
    else
      v_rec := app.stripe_booking_recorded(v_args ->> 'booking');
      v_target := v_rec ->> 'booking_number';
      if coalesce(v_args ->> 'payment_intent', '') !~ '^pi_[A-Za-z0-9]{6,}$' then raise exception 'payment_intent: the PaymentIntent id (pi_...) that stripe_booking found paid but not recorded' using errcode = '22023'; end if;
      if exists (select 1 from jsonb_array_elements(v_rec -> 'payments') p where p ->> 'intent' = v_args ->> 'payment_intent' and p ->> 'status' = 'succeeded') then
        raise exception 'Payment % is already recorded as paid on %', v_args ->> 'payment_intent', v_target using errcode = '23514';
      end if;
      if not v_confirm then
        insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, v_rec -> 'payments', null) returning * into pv;
        v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'run', 'stripe_record_preview',
          'booking_id', v_rec ->> 'booking_id', 'booking_number', v_target, 'payment_intent', v_args ->> 'payment_intent',
          'will_do', format('Record the Stripe payment %s on booking %s exactly as Stripe''s webhook would. Nothing is charged or captured: it is recorded only if Stripe shows it succeeded for this booking.', v_args ->> 'payment_intent', v_target),
          'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
      else
        select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
        if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
        if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
        if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
        if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
        update api_previews set used_at = now() where id = pv.id;
        v_result := jsonb_build_object('run', 'stripe_record_paid', 'actor', k.user_id,
          'params', jsonb_build_object('id', v_rec ->> 'booking_id', 'booking_number', v_target, 'payment_intent', v_args ->> 'payment_intent'));
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when v_write and not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre2896(text, text, jsonb, text)'::regprocedure);

revoke all on function app.photo_standard_car(uuid), app.photo_standard_read(uuid, jsonb), app.stripe_booking_recorded(text), app.api_call_pre2896(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function app.photo_standard_car(uuid), app.photo_standard_read(uuid, jsonb), app.stripe_booking_recorded(text), app.api_call_pre2896(text, text, jsonb, text) to service_role;
