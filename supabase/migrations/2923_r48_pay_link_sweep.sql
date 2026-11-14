-- 2923 (release 48): the pay links already out that ask for more than is owed are cancelled once, and the connector can
-- cancel one pay link.
--   1. A one-time sweep (2921 stops new ones): every OPEN pay link for the rental, the fees or the balance whose booking
--      owes nothing, or less than the link asks, is cancelled the way the site cancels a link (Money, Cancel: the link's
--      status; the pay page then refuses it, and 2921's check before capture voids its Stripe authorization if it is ever
--      tried), with a line in the booking's history and one in the audit log. Deposit holds, saved-card links, later
--      charges and extensions are left alone. Example: a confirmed booking paid in full by card with an open staff balance
--      link for another amount.
--   2. cancel_pay_link {payment_intent} on the connector (admin:write, an Admin only, previewed then confirmed): cancels one
--      open pay link found by its PaymentIntent id; the web layer then cancels the PaymentIntent at Stripe (never
--      captured: no money moves). A link already paid is refused (that is a refund, never done here), as is one not open.
-- No applied migration is edited: app.api_call is wrapped (_pre2923).
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

-- ================================================================ 1. the sweep
-- the open links of the booking's money that ask for more than is owed (what the sweep and 2921's trigger cancel)
create function app.payreq_overpaying() returns table (id uuid, booking_id uuid, amount_cents bigint, owed_cents bigint)
language sql stable security definer set search_path = public, app as $$
  select q.id, q.booking_id, q.amount_cents, app.booking_amount_owed(q.booking_id)
    from payment_requests q
   where q.status = 'open' and q.kind = 'charge' and q.covers in ('rental', 'fees', 'balance')
     and q.amount_cents > app.booking_amount_owed(q.booking_id)
$$;
revoke all on function app.payreq_overpaying() from public, anon, authenticated;
grant execute on function app.payreq_overpaying() to service_role;

create function app.payreq_sweep_overpaying() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in select * from app.payreq_overpaying() loop
    update payment_requests set status = 'cancelled',
           last_error = 'Cancelled by release 48: ' || case when r.owed_cents <= 0 then 'nothing is owed on the booking' else 'only ' || app.fmt_money(r.owed_cents) || ' is owed, less than the link' end
     where id = r.id and status = 'open';
    perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
      format('Pay link for %s cancelled: %s (release 48)', app.fmt_money(r.amount_cents),
             case when r.owed_cents <= 0 then 'nothing is owed' else 'only ' || app.fmt_money(r.owed_cents) || ' is owed' end), null, 'system',
      jsonb_build_object('payment_request_id', r.id, 'owed_cents', r.owed_cents))
      from bookings b where b.id = r.booking_id;
    n := n + 1;
  end loop;
  insert into audit_log (actor_db_role, action, entity_table, entity_id, after)
  select current_user, 'pay_links_swept', 'payment_requests', null, jsonb_build_object('cancelled', n, 'migration', '2923')
   where n > 0;
  return n;
end $$;
revoke all on function app.payreq_sweep_overpaying() from public, anon, authenticated;
grant execute on function app.payreq_sweep_overpaying() to service_role;

-- once, now
select app.payreq_sweep_overpaying() as pay_links_cancelled;

-- ================================================================ 2. cancel_pay_link on the connector
alter function app.api_call(text, text, jsonb, text) rename to api_call_pre2923;
create function app.api_call(p_hash text, p_tool text, p_args jsonb, p_client text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a jsonb := case when jsonb_typeof(p_args) = 'object' then p_args else '{}'::jsonb end;
  chk jsonb;
  k api_keys;
  v_args jsonb;
  v_confirm boolean;
  pv api_previews;
  q payment_requests;
  b bookings;
  v_link jsonb;
  v_result jsonb;
  v_target text := left(coalesce(nullif(a ->> 'payment_intent', ''), p_tool), 200);
begin
  if p_tool <> 'cancel_pay_link' then return app.api_call_pre2923(p_hash, p_tool, p_args, p_client); end if;
  chk := app.api_key_check(p_hash, 'admin:write', p_tool, a, p_client);
  if not (chk ->> 'ok')::boolean then return chk; end if;
  k := jsonb_populate_record(null::api_keys, chk -> 'key');
  perform app.door_begin(k.user_id, 'aal2');
  v_confirm := coalesce((a ->> 'confirm')::boolean, false);
  v_args := a - 'confirm' - 'preview_id';
  begin
    if not app.user_is_admin(k.user_id) then raise exception 'Only an Admin cancels a pay link here' using errcode = '42501'; end if;
    if coalesce(v_args ->> 'payment_intent', '') !~ '^pi_[A-Za-z0-9_-]{6,}$' then
      raise exception 'payment_intent: the PaymentIntent id (pi_...) of the pay link (stripe_booking lists them)' using errcode = '22023';
    end if;
    select * into q from payment_requests where processor_intent_id = v_args ->> 'payment_intent' order by created_at desc limit 1;
    if q.id is null then raise exception 'No pay link has the PaymentIntent %', v_args ->> 'payment_intent' using errcode = 'P0002'; end if;
    select * into b from bookings where id = q.booking_id;
    v_target := b.booking_number;
    if q.status = 'paid' then
      raise exception 'The pay link % on % is paid: nothing to cancel. Giving money back is a refund, prepared as an Admin To do', v_args ->> 'payment_intent', b.booking_number using errcode = '23514';
    end if;
    if q.status <> 'open' then
      raise exception 'The pay link % on % is already %', v_args ->> 'payment_intent', b.booking_number, q.status using errcode = '23514';
    end if;
    v_link := jsonb_build_object('id', q.id, 'booking_number', b.booking_number, 'kind', q.kind, 'covers', q.covers, 'amount_cents', q.amount_cents,
      'amount', app.fmt_money(q.amount_cents), 'status', q.status, 'channel', q.channel, 'created_at', q.created_at, 'expires_at', q.expires_at,
      'owed_cents', case when q.kind = 'charge' and q.covers in ('rental', 'fees', 'balance') then app.booking_amount_owed(b.id) end);
    if not v_confirm then
      insert into api_previews (key_id, user_id, tool, args, before, after) values (k.id, k.user_id, p_tool, v_args, v_link, v_link || '{"status": "cancelled"}'::jsonb) returning * into pv;
      v_result := jsonb_build_object('preview', true, 'preview_id', pv.id, 'tool', p_tool, 'expires_at', pv.created_at + interval '10 minutes', 'link', v_link,
        'will_do', format('Cancel the open pay link for %s (%s) on booking %s, and its PaymentIntent %s at Stripe. No money moves: it was never paid.',
                          app.fmt_money(q.amount_cents), q.covers, b.booking_number, v_args ->> 'payment_intent'),
        'next', 'Nothing was changed. To do it, call this tool again with exactly the same arguments plus "confirm": true and "preview_id": "' || pv.id || '".');
    else
      select * into pv from api_previews where id = nullif(a ->> 'preview_id', '')::uuid for update;
      if pv.id is null or pv.key_id <> k.id or pv.tool <> p_tool then raise exception 'Preview first: call without confirm, then confirm with its preview_id' using errcode = '22023'; end if;
      if pv.used_at is not null then raise exception 'This preview was already used: preview again' using errcode = '22023'; end if;
      if pv.created_at < now() - interval '10 minutes' then raise exception 'This preview is more than 10 minutes old: preview again' using errcode = '22023'; end if;
      if pv.args is distinct from v_args then raise exception 'The arguments differ from the preview: preview again with these' using errcode = '22023'; end if;
      update api_previews set used_at = now() where id = pv.id;
      update payment_requests set status = 'cancelled', last_error = 'Cancelled by an Admin through the connector' where id = q.id and status = 'open';
      perform app.log_booking_event(b.id, 'adjusted', b.status::text, b.status::text, null,
        format('Pay link for %s cancelled by an Admin (connector)', app.fmt_money(q.amount_cents)), k.user_id, 'staff',
        jsonb_build_object('payment_request_id', q.id, 'payment_intent', v_args ->> 'payment_intent'));
      v_result := jsonb_build_object('done', true, 'run', 'pay_link_cancel', 'payment_intent', v_args ->> 'payment_intent', 'booking_number', b.booking_number,
        'cancelled', v_link || '{"status": "cancelled"}'::jsonb, 'charged', false);
    end if;
  exception when others then
    insert into api_calls (key_id, user_id, tool, target, args, ok, error, client) values (k.id, k.user_id, p_tool, v_target, v_args, false, left(sqlerrm, 500), left(p_client, 64));
    return jsonb_build_object('ok', false, 'status', case sqlstate when 'P0002' then 404 when '42501' then 403 else 400 end, 'error', regexp_replace(sqlerrm, '^.*?ERROR:\s*', ''));
  end;
  insert into api_calls (key_id, user_id, tool, target, args, ok, client)
  values (k.id, k.user_id, case when not v_confirm then p_tool || ':preview' else p_tool end, v_target, v_args, true, left(p_client, 64));
  return jsonb_build_object('ok', true, 'result', v_result);
end $$;
select pg_temp.copy_grants('app.api_call(text, text, jsonb, text)'::regprocedure, 'app.api_call_pre2923(text, text, jsonb, text)'::regprocedure);
revoke all on function app.api_call_pre2923(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function app.api_call_pre2923(text, text, jsonb, text) to service_role;
