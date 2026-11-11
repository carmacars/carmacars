-- 1873_r35gaps4_connector_claim_files.sql
-- The owner, November 11, 2026 (message 3892): the CarmaCars connector (app.api_call, web/src/features/api-access) can attach claim photos and
-- repair estimates to a claim. Two tools, both previewed then confirmed like every Admin write (api_previews: ten minutes, the same
-- arguments, used once), both checked for the role of the key's person:
--   attach_claim_photo     file_base64 (JPEG or PNG): a document on the claim's incident (kind other, title "Claim photo"), kept under legal hold.
--   attach_claim_estimate  amount_cents, shop_name, approved_shop, hst_cents, description, optional file_base64 (PDF, JPEG or PNG): an incident cost
--                          of kind repair_estimate (what Finance enters on the claim page), with the file as a repair_estimate document.
-- Who: an Admin, or Finance or Fleet staff (the claim page's own rule, incident_costs 0012). A closed or withdrawn claim takes nothing.
-- The bytes never reach the log or the preview: their fingerprint does. The web layer (api/mcp) stores them, then records them here.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

alter function app.api_call(text, text, jsonb, text) rename to api_call_pre1873;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_door jsonb;
  v_confirm boolean;
  pv api_previews;
  v_before jsonb;
  v_target text;
  c claims;
  v_result jsonb;
  v_cost uuid;
  v_est boolean := p_tool = 'attach_claim_estimate';
begin
  if p_tool not in ('attach_claim_photo', 'attach_claim_estimate') then return app.api_call_pre1873(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:write', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_door := a - 'confirm' - 'preview_id' - 'file_base64'
            || case when a ? 'file_base64' then jsonb_build_object('file_sha256', encode(sha256(convert_to(coalesce(a ->> 'file_base64', ''), 'UTF8')), 'hex'),
                                                                  'file_chars', length(coalesce(a ->> 'file_base64', ''))) else '{}'::jsonb end;
  begin
    -- the role of the person behind the key
    if not (app.is_admin() or app.va_has('finance', 'fleet')) then raise exception 'Only an Admin, Finance or Fleet can attach files to a claim' using errcode = '42501'; end if;
    select * into c from claims where claim_number = upper(btrim(coalesce(v_door ->> 'claim', ''))) or id::text = v_door ->> 'claim';
    if c.id is null then raise exception 'No claim %', coalesce(v_door ->> 'claim', '') using errcode = 'P0002'; end if;
    v_target := c.claim_number;
    if c.status in ('closed', 'withdrawn') then raise exception 'Claim % is % and takes no more files', c.claim_number, c.status using errcode = '23514'; end if;
    if v_est then
      if coalesce((v_door ->> 'amount_cents')::bigint, 0) <= 0 then raise exception 'amount_cents: the estimate in cents, above zero' using errcode = '22023'; end if;
      if length(btrim(coalesce(v_door ->> 'shop_name', ''))) < 2 then raise exception 'shop_name: the shop that made the estimate' using errcode = '22023'; end if;
      if jsonb_typeof(v_door -> 'approved_shop') is distinct from 'boolean' then raise exception 'approved_shop: true or false, whether it is an approved shop' using errcode = '22023'; end if;
      if coalesce((v_door ->> 'hst_cents')::bigint, 0) < 0 then raise exception 'hst_cents cannot be negative' using errcode = '22023'; end if;
    elsif coalesce((v_door ->> 'file_chars')::integer, 0) = 0 then
      raise exception 'file_base64: the photo (JPEG or PNG), base64' using errcode = '22023';
    end if;
    v_before := jsonb_build_object('claim', c.claim_number, 'status', c.status, 'incident_id', c.incident_id,
      'files', (select count(*) from documents d where d.incident_id = c.incident_id),
      'estimates', (select count(*) from incident_costs x where x.incident_id = c.incident_id and x.kind = 'repair_estimate' and not x.superseded),
      'damage_cost_cents', app.incident_damage_cost(c.incident_id));
    if not v_confirm then
      insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_door, v_before, null) returning * into pv;
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'before', v_before,
        'will_do', case when v_est then format('Add a repair estimate of %s from %s (%s shop) to claim %s%s.', app.fmt_money((v_door ->> 'amount_cents')::bigint), btrim(v_door ->> 'shop_name'),
                                               case when (v_door ->> 'approved_shop')::boolean then 'an approved' else 'a non-approved' end, c.claim_number,
                                               case when coalesce((v_door ->> 'file_chars')::integer, 0) > 0 then ', with the file' else '' end)
                        else format('Attach the photo to claim %s.', c.claim_number) end,
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_door then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      if v_est and coalesce((v_door ->> 'file_chars')::integer, 0) = 0 then
        -- no file: the cost is entered now
        insert into incident_costs (incident_id, kind, description, amount_cents, hst_cents, shop_name, approved_shop, created_by)
        values (c.incident_id, 'repair_estimate', left(nullif(btrim(coalesce(v_door ->> 'description', '')), ''), 500), (v_door ->> 'amount_cents')::bigint,
                coalesce((v_door ->> 'hst_cents')::bigint, 0), btrim(v_door ->> 'shop_name'), (v_door ->> 'approved_shop')::boolean, k.user_id)
        returning id into v_cost;
        v_result := jsonb_build_object('done', true, 'tool', p_tool, 'claim', c.claim_number, 'cost_id', v_cost, 'admin_path', '/admin/claims/' || c.claim_number);
      else
        -- the web layer stores the bytes it holds (checked against the fingerprint) and records them with app.api_claim_file_record
        v_result := jsonb_build_object('run', 'claim_file', 'actor', k.user_id, 'params', v_door || jsonb_build_object('claim_id', c.id, 'incident_id', c.incident_id));
      end if;
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, left(coalesce(v_target, p_tool), 200), v_door, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, before, ok, client)
  values (k.id, k.user_id, case when v_confirm then p_tool else p_tool || ':preview' end, left(v_target, 200), v_door, v_before, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre1873(text, text, jsonb, text)'::regprocedure);

-- the web layer stored the file: record it on the claim's incident (the key and the confirmed preview checked again, once)
create function app.api_claim_file_record(p_hash text, p_preview uuid, p_path text, p_mime text, p_sha text, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  k api_keys;
  pv api_previews;
  c claims;
  v_doc uuid;
  v_cost uuid;
  v_est boolean;
begin
  select * into k from api_keys where key_hash = p_hash and revoked_at is null;
  select * into pv from api_previews where id = p_preview;
  if k.id is null or pv.id is null or pv.key_id <> k.id or pv.tool not in ('attach_claim_photo', 'attach_claim_estimate') or pv.used_at is null or pv.used_at < now() - interval '5 minutes' then
    raise exception 'Not a confirmed claim file' using errcode = '42501';
  end if;
  if exists (select 1 from api_calls x where x.key_id = k.id and x.tool = pv.tool || ':stored' and x.target = p_preview::text) then raise exception 'Already stored' using errcode = '23505'; end if;
  perform app.door_begin(k.user_id, 'aal2');
  if not (app.is_admin() or app.va_has('finance', 'fleet')) then raise exception 'Only an Admin, Finance or Fleet can attach files to a claim' using errcode = '42501'; end if;
  select * into c from claims where claim_number = pv.before ->> 'claim';
  if c.id is null or c.status in ('closed', 'withdrawn') then raise exception 'The claim takes no more files' using errcode = '23514'; end if;
  if p_path !~ ('^claims/' || c.id || '/claude/[0-9a-f-]{36}\.(jpg|png|pdf)$') then raise exception 'Unexpected path' using errcode = '22023'; end if;
  if p_mime not in ('image/jpeg', 'image/png', 'application/pdf') or (pv.tool = 'attach_claim_photo' and p_mime = 'application/pdf') then raise exception 'Unexpected file type' using errcode = '22023'; end if;
  v_est := pv.tool = 'attach_claim_estimate';
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, legal_hold, uploaded_by, incident_id, booking_id)
  values (case when v_est then 'repair_estimate'::document_kind else 'other'::document_kind end,
          case when v_est then 'Repair estimate' else coalesce(nullif(left(btrim(coalesce(pv.args ->> 'caption', '')), 120), ''), 'Claim photo') end,
          'documents', p_path, p_mime, p_sha, true, k.user_id, c.incident_id, c.booking_id)
  returning id into v_doc;
  if v_est then
    insert into incident_costs (incident_id, kind, description, amount_cents, hst_cents, shop_name, approved_shop, document_id, created_by)
    values (c.incident_id, 'repair_estimate', left(nullif(btrim(coalesce(pv.args ->> 'description', '')), ''), 500), (pv.args ->> 'amount_cents')::bigint,
            coalesce((pv.args ->> 'hst_cents')::bigint, 0), btrim(pv.args ->> 'shop_name'), (pv.args ->> 'approved_shop')::boolean, k.user_id)
    returning id into v_cost;
  end if;
  insert into api_calls (key_id, user_id, tool, target, args, after, ok, client)
  values (k.id, k.user_id, pv.tool || ':stored', p_preview::text, pv.args, jsonb_build_object('document_id', v_doc, 'cost_id', v_cost, 'path', p_path), true, left(p_client, 64));
  return jsonb_build_object('done', true, 'tool', pv.tool, 'claim', c.claim_number, 'document_id', v_doc, 'cost_id', v_cost, 'admin_path', '/admin/claims/' || c.claim_number);
end $$;
create function public.server_api_claim_file_record(p_hash text, p_preview uuid, p_path text, p_mime text, p_sha text, p_client text default null) returns jsonb
language sql security definer set search_path = public, app as $$ select app.api_claim_file_record(p_hash, p_preview, p_path, p_mime, p_sha, p_client) $$;

revoke all on function app.api_call_pre1873(text, text, jsonb, text), app.api_claim_file_record(text, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function app.api_call_pre1873(text, text, jsonb, text), app.api_claim_file_record(text, uuid, text, text, text, text) to service_role;
revoke all on function public.server_api_claim_file_record(text, uuid, text, text, text, text) from public, anon, authenticated;
grant execute on function public.server_api_claim_file_record(text, uuid, text, text, text, text) to service_role;
