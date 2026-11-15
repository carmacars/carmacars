-- 3013 (release 48): the connector lets a main driver keep a licence from outside Ontario on one booking, as the Admin's
-- "Let it go" does on the booking page (docs/changes/2026-11-14-r48-connector-licence-let-go.md).
--
-- licence_let_go {booking, reason}: an Admin only, previewed then confirmed like every write. The preview says who keeps
-- which licence and why; the confirm runs app.primary_swap_decide (action override) as the key's Admin: the first main
-- driver is back as the main driver for this booking only, pickup is no longer blocked by it, and the booking history
-- says "Main driver kept with a licence from outside Ontario: <reason>". Every call is logged (api_calls).
-- No applied migration is edited: app.api_call is wrapped (_pre3013).
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

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3013;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  b bookings;
  w booking_primary_swaps;
  v_reason text;
  v_swap jsonb;
  v_result jsonb;
  v_target text := left(coalesce(nullif(a ->> 'booking', ''), p_tool), 200);
begin
  if p_tool <> 'licence_let_go' then return app.api_call_pre3013(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:write', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if not app.user_is_admin(k.user_id) then raise exception 'Only an Admin lets a licence from outside Ontario go' using errcode = '42501'; end if;
    select * into b from bookings where booking_number = upper(btrim(coalesce(v_args ->> 'booking', ''))) or id::text = v_args ->> 'booking';
    if b.id is null then raise exception 'Booking % not found', coalesce(v_args ->> 'booking', '(none)') using errcode = 'P0002'; end if;
    v_target := b.booking_number;
    v_reason := nullif(btrim(coalesce(v_args ->> 'reason', '')), '');
    if v_reason is null or length(v_reason) < 5 then
      raise exception 'reason: say why this main driver may keep the licence (5 characters or more)' using errcode = '22023';
    end if;
    select * into w from booking_primary_swaps where booking_id = b.id and state = 'needed';
    if w.id is null then
      raise exception 'Booking % has no main driver waiting on an Ontario licence: nothing to let go', b.booking_number using errcode = '23514';
    end if;
    v_swap := jsonb_build_object('booking_number', b.booking_number, 'state', w.state, 'issuer', coalesce(w.issuer, 'outside Ontario'),
      'main_driver', (select d.full_name from drivers d where d.id = w.from_driver_id),
      'moved_in_as_main', (select d.full_name from drivers d where d.id = w.to_driver_id));
    if not v_confirm then
      insert into api_previews (key_id, user_id, tool, args, before, after)
      values (k.id, k.user_id, p_tool, v_args, v_swap, v_swap || jsonb_build_object('state', 'overridden', 'reason', v_reason)) returning * into pv;
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'swap', v_swap,
        'will_do', format('Let %s keep the licence from %s as the main driver on booking %s only (the Admin''s Let it go), with the reason: %s. Pickup is no longer blocked by it.',
                          coalesce(v_swap ->> 'main_driver', 'the main driver'), v_swap ->> 'issuer', b.booking_number, v_reason),
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      perform app.primary_swap_decide(k.user_id, jsonb_build_object('booking', b.id, 'action', 'override', 'reason', v_reason || ' (connector)'));
      v_result := jsonb_build_object('done', true, 'booking_number', b.booking_number, 'state', 'overridden', 'swap', v_swap, 'reason', v_reason);
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3013(text, text, jsonb, text)'::regprocedure);
revoke all on function app.api_call_pre3013(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function app.api_call_pre3013(text, text, jsonb, text) to service_role;
