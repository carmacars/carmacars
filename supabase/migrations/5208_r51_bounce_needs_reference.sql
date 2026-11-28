-- 5208 (R51 review fix 1): a bounce for an insurer email changes something only when it carries a matching X-Outbox-Ref
-- or the exact Message-ID we sent (notification_outbox.provider_id). Without one it is logged (email_bounces, no outbox row)
-- and nothing else changes: no version marked, no claim history line, no To do, no email sent again.
-- 5204 is not edited: the function is replaced here.
create or replace function app.server_email_bounce(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_to text := lower(btrim(coalesce(p ->> 'to', '')));
  v_ref uuid := case when (p ->> 'ref') ~* '^[0-9a-f-]{36}$' then (p ->> 'ref')::uuid end;
  o notification_outbox;
  e app_events;
  ii insurer_invoices;
  ver insurer_invoice_versions;
  b bookings;
  ins insurers;
  v_bounce uuid;
  v_reason text := left(nullif(btrim(coalesce(p ->> 'reason', '')), ''), 300);
  v_code text := left(nullif(btrim(coalesce(p ->> 'status', '')), ''), 20);
  v_mid text := nullif(btrim(coalesce(p ->> 'message_id', ''), ' <>'), '');
  v_fallback text;
  v_words text;
begin
  if v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('matched', false, 'why', 'no failed address'); end if;
  -- an insurer email is acted on only when the bounce names it: our X-Outbox-Ref, or the exact Message-ID we sent (its provider id)
  if v_ref is not null then select * into o from notification_outbox where id = v_ref and lower(to_address) = v_to; end if;
  if o.id is null and v_mid is not null then
    select * into o from notification_outbox where provider_id = v_mid and lower(to_address) = v_to order by created_at desc limit 1;
  end if;
  if o.id is null then
    -- no reference: the latest email sent to that address in 14 days, for other audiences only
    select * into o from notification_outbox where lower(to_address) = v_to and status = 'sent' and sent_at > now() - interval '14 days' order by sent_at desc limit 1;
    if o.id is null then return jsonb_build_object('matched', false, 'why', 'not one of our emails'); end if;
    if o.audience = 'insurer' then
      -- logged, nothing else changes: anyone can send a bounce-shaped email naming an insurer address
      insert into email_bounces (outbox_id, to_address, status_code, reason, source)
      values (null, v_to, v_code, v_reason, case when p ->> 'source' = 'provider' then 'provider' else 'ndr' end);
      return jsonb_build_object('matched', false, 'why', 'insurer email: no matching reference, logged only');
    end if;
  end if;
  insert into email_bounces (outbox_id, to_address, status_code, reason, source)
  values (o.id, v_to, v_code, v_reason, case when p ->> 'source' = 'provider' then 'provider' else 'ndr' end)
  on conflict (outbox_id, lower(to_address)) where outbox_id is not null do nothing
  returning id into v_bounce;
  if v_bounce is null then return jsonb_build_object('matched', true, 'repeat', true); end if;
  if o.audience <> 'insurer' then return jsonb_build_object('matched', true, 'insurer', false); end if;

  -- an insurer email: the version, the booking, the fallback and the To do
  select * into e from app_events where id = o.event_id;
  if o.entity = 'insurer_invoice' then select * into ii from insurer_invoices where id = o.entity_id; end if;
  if ii.id is not null then
    select * into ver from insurer_invoice_versions where invoice_id = ii.id and version = coalesce((e.payload ->> 'version')::int, ii.version);
    select * into b from bookings where id = ii.booking_id;
    select * into ins from insurers where id = ii.insurer_id;
  else
    select * into b from bookings where id = o.booking_id;
    select * into ins from insurers where id = b.insurer_id;
  end if;
  v_words := coalesce(v_code || ' ', '') || coalesce(v_reason, 'refused by the receiving mail server');
  if ver.id is not null then
    update insurer_invoice_versions set bounced_at = now(), bounce_reason = v_words where id = ver.id;
  end if;
  -- once a version: the same invoice or estimate again, to the insurer's general claims email when it is another address
  if ver.id is not null and ver.fallback_to is null and o.code in ('insurer_invoice', 'insurer_estimate')
     and nullif(lower(btrim(coalesce(ins.claims_email, ''))), '') is not null and lower(btrim(ins.claims_email)) <> v_to then
    v_fallback := lower(btrim(ins.claims_email));
    perform app.emit_event(o.code, 'insurer_invoice', ii.id,
      jsonb_build_object('insurer_id', ii.insurer_id, 'to_email', v_fallback, 'to_name', ins.name, 'version', ver.version, 'fallback_of', o.id),
      'insurer_invoice:' || ii.id || ':v' || ver.version || ':fallback');
    update insurer_invoice_versions set fallback_to = v_fallback where id = ver.id;
  end if;
  if b.id is not null then
    perform app.insurer_log(null, b.id, format('Email to %s bounced: %s.%s', v_to, v_words, case when v_fallback is not null then ' Sent again to the claims email ' || v_fallback || '.' else '' end),
      jsonb_build_object('bounce', v_bounce, 'outbox', o.id));
  end if;
  perform app.raise_task(p_type => 'insurer_email_bounced',
    p_title => format('Insurer email bounced: %s%s', coalesce(ins.name, v_to), coalesce(', booking ' || b.booking_number, '')),
    p_detail => format(E'%s to %s was refused: %s.\nAdjuster: %s.\nInsurer claims contact: %s.\n%s\nAllowlist request, ready to send from the Blind Spot email (never from rent@carmacars.ca):\n\n%s',
      case o.code when 'insurer_invoice' then 'The invoice' when 'insurer_estimate' then 'The estimate' when 'insurer_payment_received' then 'The payment receipt' else 'The email' end,
      v_to, v_words,
      coalesce(nullif(concat_ws(', ', nullif(b.insurer_adjuster_name, ''), nullif(b.insurer_adjuster_email, ''), nullif(b.insurer_adjuster_phone, '')), ''), 'not on the booking'),
      coalesce(nullif(concat_ws(', ', nullif(ins.claims_email, ''), nullif(ins.claims_phone, '')), ''), 'none on file (Settings, Insurers)'),
      case when v_fallback is not null then 'It was sent again to ' || v_fallback || '.' else 'Not sent again: no other claims email on file.' end,
      app.insurer_allowlist_request(v_to, coalesce(app.insurer_sender(), 'our sender address'), v_code, v_reason)),
    p_booking => b.id, p_related_table => case when ii.id is not null then 'insurer_invoices' end, p_related_id => ii.id,
    p_priority => 'urgent', p_dedupe => 'insurer_bounce:' || o.id, p_queue => 'admin');
  -- (the To do says to send the request from the Blind Spot email, never from rent@carmacars.ca: REQ-137)
  return jsonb_build_object('matched', true, 'insurer', true, 'bounce', v_bounce, 'fallback_to', v_fallback);
end $$;
