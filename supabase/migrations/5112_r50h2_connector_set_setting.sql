-- 5112 (r50 hotfix2): the connector's set_setting (admin:write, Admins only): one Program setting or Site setting changed
-- by its key, previewed then confirmed (preview_id) like every connector write. It runs the same database action as
-- Admin > Settings (app.door admin_save: the same columns allowed, the same checks, a Program setting as a dated row from
-- today), so it is refused exactly where the Settings page refuses. The preview runs it and rolls it back, so the value
-- the database would store is shown. api_calls keeps the before and the after. Secret-like keys are refused: API keys,
-- tokens, secrets, passwords, signing and webhook values, verify tokens and bank details (cc_pay_*, account, transit,
-- institution numbers, every cc_pay_ and bs_pay_ setting): those are changed in Admin > Settings only.
--   args: key (the column), value (any JSON: text, number, true or false, null), confirm, preview_id

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

create function app.setting_key_secret(p_key text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(p_key, '') ~* '(key|token|secret|password|passwd|signing|webhook|verify|private|credential|bank|account_no|transit|institution|iban|routing|^cc_pay_|^bs_pay_)'
$$;

-- the table a setting key belongs to: program_settings first, then site_settings; null when neither has it
create function app.setting_table(p_key text) returns text
language sql stable set search_path = public, app, pg_temp as $$
  select case
    when exists (select 1 from pg_attribute a where a.attrelid = 'public.program_settings'::regclass and a.attname = p_key and a.attnum > 0 and not a.attisdropped
                   and p_key not in ('id', 'effective_from', 'created_by', 'created_at')) then 'program_settings'
    when exists (select 1 from pg_attribute a where a.attrelid = 'public.site_settings'::regclass and a.attname = p_key and a.attnum > 0 and not a.attisdropped
                   and p_key not in ('id', 'singleton', 'created_at', 'updated_at', 'updated_by')) then 'site_settings'
  end
$$;

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre5112;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  v_key text;
  v_table text;
  v_before jsonb;
  v_after jsonb;
  v_row jsonb;
  pv api_previews;
  v_result jsonb;
begin
  if p_tool <> 'set_setting' then return app.api_call_pre5112(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:write', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  v_key := lower(btrim(coalesce(v_args ->> 'key', '')));
  begin
    if not app.user_is_admin(k.user_id) then raise exception 'Only an Admin changes settings' using errcode = '42501'; end if;
    if v_key = '' or not (v_args ? 'value') then raise exception 'key and value: the setting''s key (get_settings lists them) and its new value' using errcode = '22023'; end if;
    if app.setting_key_secret(v_key) then raise exception '% is a secret or bank detail: change it in Admin > Settings', v_key using errcode = '42501'; end if;
    v_table := app.setting_table(v_key);
    if v_table is null then raise exception 'Not a setting: %', v_key using errcode = '22023'; end if;
    v_before := case when v_table = 'program_settings' then to_jsonb(app.settings()) -> v_key else (select to_jsonb(s) -> v_key from site_settings s limit 1) end;
    if not v_confirm then
      -- the same action as the Settings page, rolled back: the value it would store, or its refusal
      begin
        v_row := app.door(k.user_id, 'aal2', 'admin_save', v_table, jsonb_build_object('key', null, 'values', jsonb_build_object(v_key, v_args -> 'value')));
        v_after := v_row -> v_key;
        raise exception using errcode = 'P0099', message = 'preview';
      exception when sqlstate 'P0099' then null;
      end;
      insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, jsonb_build_object(v_key, v_before), jsonb_build_object(v_key, v_after)) returning * into pv;
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes',
        'table', v_table, 'key', v_key, 'before', v_before, 'after', v_after,
        'will_do', format('Change %s (%s) from %s to %s%s.', v_key, case v_table when 'program_settings' then 'Program settings' else 'Site settings' end,
                          coalesce(v_before::text, 'empty'), coalesce(v_after::text, 'empty'), case when v_table = 'program_settings' then ', from today (a dated row; earlier rows are kept)' else '' end),
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      v_row := app.door(k.user_id, 'aal2', 'admin_save', v_table, jsonb_build_object('key', null, 'values', jsonb_build_object(v_key, v_args -> 'value')));
      v_after := v_row -> v_key;
      v_result := jsonb_build_object('done', true, 'tool', p_tool, 'table', v_table, 'key', v_key, 'before', v_before, 'after', v_after, 'admin_path', '/admin/settings');
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, left(coalesce(nullif(v_key, ''), p_tool), 200), v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, before, after, ok, client)
  values (k.id, k.user_id, case when v_confirm then p_tool else p_tool || ':preview' end, left(v_key, 200), v_args,
          jsonb_build_object(v_key, v_before), jsonb_build_object(v_key, v_after), true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;

select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre5112(text, text, jsonb, text)'::regprocedure);
revoke all on function app.api_call_pre5112(text, text, jsonb, text), app.setting_key_secret(text), app.setting_table(text) from public, anon, authenticated;
grant execute on function app.api_call_pre5112(text, text, jsonb, text), app.setting_key_secret(text), app.setting_table(text) to service_role;
