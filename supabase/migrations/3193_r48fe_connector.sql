-- 3193 (release 48, part FE): the connector's tools for the return charges and the evidence of every fee.
--   add_return_charge      (admin:write) app.return_charge_add: non_return, improper_return, theft_recovery, tire, roadside
--   attach_fee_evidence    (admin:write) app.fee_evidence_attach: a receipt or invoice (a document of the booking), photo ids, a note
--   override_fee_evidence  (admin:write) app.fee_evidence_override: an Admin charges a fee without its evidence, with the reason
--   fee_evidence           (admin:read)  each fee line of a booking with what its evidence needs, has and lacks
-- The writes are two steps like every connector write: the preview names what will happen and changes nothing.
-- No applied migration is edited: app.api_call is wrapped (_pre3193).
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

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre3193;
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
  li booking_line_items;
  v_result jsonb;
  v_before jsonb;
  v_will text;
  v_target text := left(coalesce(nullif(a ->> 'booking', ''), nullif(a ->> 'line', ''), p_tool), 200);
begin
  if p_tool not in ('add_return_charge', 'attach_fee_evidence', 'override_fee_evidence', 'fee_evidence') then
    return app.api_call_pre3193(p_hash, p_tool, p_args, p_client);
  end if;
  chk := app.api_key_check(p_hash, case when p_tool = 'fee_evidence' then 'admin:read' else 'admin:write' end, p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if p_tool = 'fee_evidence' then
      select * into b from bookings where booking_number = upper(btrim(coalesce(v_args ->> 'booking', ''))) or id::text = v_args ->> 'booking';
      if b.id is null then raise exception 'Booking % not found', coalesce(v_args ->> 'booking', '(none)') using errcode = 'P0002'; end if;
      v_result := jsonb_build_object('booking_number', b.booking_number, 'lines', app.booking_fee_evidence(k.user_id, b.id));
      insert into api_calls (key_id, user_id, tool, target, args, ok, client) values (k.id, k.user_id, p_tool, b.booking_number, v_args, true, left(p_client, 64));
      return jsonb_build_object('ok', true, 'result', v_result);
    end if;
    if p_tool = 'add_return_charge' then
      select * into b from bookings where booking_number = upper(btrim(coalesce(v_args ->> 'booking', ''))) or id::text = v_args ->> 'booking';
      if b.id is null then raise exception 'Booking % not found', coalesce(v_args ->> 'booking', '(none)') using errcode = 'P0002'; end if;
      v_target := b.booking_number;
      v_before := jsonb_build_object('booking_number', b.booking_number, 'status', b.status, 'kind', v_args ->> 'kind');
      v_will := format('Add the %s charge to %s (%s plus HST where it applies, with %s cost line(s) at cost). Its evidence is checked by itself; what is missing becomes a To do and the charge waits for it.',
        replace(coalesce(v_args ->> 'kind', '?'), '_', ' '), b.booking_number,
        app.fmt_money(case v_args ->> 'kind' when 'non_return' then (app.settings()).non_return_fee_cents when 'improper_return' then (app.settings()).improper_return_fee_cents
                                             when 'theft_recovery' then (app.settings()).theft_recovery_fee_cents else (app.settings()).roadside_admin_fee_cents end),
        jsonb_array_length(coalesce(v_args -> 'costs', '[]'::jsonb)));
    else
      select * into li from booking_line_items where id = nullif(v_args ->> 'line', '')::uuid;
      if li.id is null then raise exception 'Fee line not found (line: the line_item_id that fee_evidence lists)' using errcode = 'P0002'; end if;
      select * into b from bookings where id = li.booking_id;
      v_target := b.booking_number;
      v_before := jsonb_build_object('booking_number', b.booking_number, 'line', li.description, 'evidence_status', li.evidence_status, 'missing', to_jsonb(li.evidence_missing));
      v_will := case p_tool when 'attach_fee_evidence' then format('Attach %s to "%s" on %s; the evidence is checked again.', coalesce(v_args ->> 'kind', 'evidence'), li.description, b.booking_number)
                            else format('Charge "%s" on %s without its missing evidence (%s), with the reason: %s', li.description, b.booking_number, array_to_string(li.evidence_missing, ', '), v_args ->> 'reason') end;
    end if;
    if not v_confirm then
      insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, v_before, v_before) returning * into pv;
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'now', v_before, 'will_do', v_will,
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      v_result := case p_tool
        when 'add_return_charge' then app.return_charge_add(k.user_id, v_args || jsonb_build_object('note', coalesce(v_args ->> 'note', '') ))
        when 'attach_fee_evidence' then app.fee_evidence_attach(k.user_id, v_args)
        else app.fee_evidence_override(k.user_id, v_args) end;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre3193(text, text, jsonb, text)'::regprocedure);
revoke all on function app.api_call_pre3193(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function app.api_call_pre3193(text, text, jsonb, text) to service_role;
