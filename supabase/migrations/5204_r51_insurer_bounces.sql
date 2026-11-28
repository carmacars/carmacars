-- 5204 (R51 staff, REQ-136; docs/changes/2026-11-27-r51-staff.md): emails to insurers that their mail server refuses.
-- The owner (Nov 27 18:22): "emails coming from blindspotcarrental @ carmacars are not getting passed insurance's firewall.
-- can u fix that and make sure it doesnt happen again". Evidence (rent@'s Gmail, Nov 25): the insurer's Exchange answered
-- 550 5.7.129 RestrictedToRecipientsPermission ("the sender isn't on the recipient's list of senders to accept mail from")
-- with SPF, DKIM and DMARC passing for carmacars.ca: the adjuster's mailbox accepts only listed senders. Our provider took
-- the email, so only the bounce email (an NDR) says it failed.
--   1. email_bounces: each bounce read from an NDR or a delivery status report (web/src/app/api/inbound/bounce, from the
--      mailbox's Apps Script, scripts/turo-gmail.gs), matched to the email we sent: by the X-Outbox-Ref header the sender
--      adds (send-outbox), else by the address that failed among our emails to it in the last 14 days. A bounce never
--      suppresses the address (a refusal by an accept list ends once the insurer lists the sender).
--   2. An insurer email (invoice, estimate, payment receipt) that bounced: the version is marked bounced with the reason,
--      the booking's claim history says so, and the Admins get one urgent To do with the reason, the adjuster, the
--      insurer's general claims contact when on file, and an allowlist request ready to send (Blind Spot branding).
--   3. insurers.claims_email and claims_phone (the general claims contact): a bounced invoice or estimate goes again, at
--      once and once, to the claims email when it is another address.
--   4. Admin and Finance see each version's delivery: queued, sent, delivered (sent and no bounce in 24 hours: the
--      provider gives no delivery receipt here), bounced (with the reason) or failed.
--   5. REQ-137 (the owner, Nov 27 18:43: "DO NOT SEND IT FROM RENT@CARMACARS.CA"): no insurer email has rent@carmacars.ca as its
--      From or reply-to, in the catalogue, the reply-to rules or a queued email; the database refuses it (and the build check
--      web/src/features/insurance/insurer-sender.test.ts reads the catalogue and the templates).
-- No applied migration is edited: insurer_rental_json is wrapped (_pre5204); admin_save_pre0780 is patched in place.
set local check_function_bodies = off;

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '5204: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
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

-- ================================================================ 1. bounces
alter table insurers
  add column if not exists claims_email text check (claims_email is null or claims_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  add column if not exists claims_phone text;
comment on column insurers.claims_email is 'Insurer emails (5204): the general claims email. A bounced invoice or estimate goes again to it, once, when it is another address.';
-- Settings, Insurers saves them (the columns an Admin may write)
select pg_temp.patch_fn('app.admin_save_pre0780(uuid,text,jsonb)'::regprocedure,
  $o$when 'insurers' then array['name', 'billing_contact_name', 'billing_email', 'billing_phone', 'billing_address', 'notes', 'is_active']$o$,
  $n$when 'insurers' then array['name', 'billing_contact_name', 'billing_email', 'billing_phone', 'claims_email', 'claims_phone', 'billing_address', 'notes', 'is_active']$n$);
comment on column insurers.claims_phone is 'Insurer emails (5204): the general claims phone, shown on the To do of a bounced email.';

alter table insurer_invoice_versions
  add column if not exists bounced_at timestamptz,
  add column if not exists bounce_reason text,
  add column if not exists fallback_to text;
-- a version stays as sent; only how its email went (the bounce, the claims email it went to again) is added to it
create or replace function app.insurer_invoice_versions_frozen() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and (to_jsonb(new) - array['bounced_at', 'bounce_reason', 'fallback_to']) = (to_jsonb(old) - array['bounced_at', 'bounce_reason', 'fallback_to']) then return new; end if;
  raise exception 'A version sent to an insurer is never changed' using errcode = '23514';
end $$;
comment on column insurer_invoice_versions.bounced_at is 'Insurer emails (5204): the email of this version bounced (an NDR or a delivery report), with bounce_reason.';
comment on column insurer_invoice_versions.fallback_to is 'Insurer emails (5204): the claims email this version was sent to again after the bounce.';

create table email_bounces (
  id          uuid primary key default gen_random_uuid(),
  outbox_id   uuid references notification_outbox (id) on delete set null,
  to_address  text not null,
  status_code text,
  reason      text,
  source      text not null default 'ndr' check (source in ('ndr', 'provider')),
  received_at timestamptz not null default now(),
  created_at  timestamptz not null default now()
);
create unique index email_bounces_once on email_bounces (outbox_id, lower(to_address)) where outbox_id is not null;
create index email_bounces_outbox_idx on email_bounces (outbox_id);
comment on table email_bounces is 'Insurer emails (5204): bounces read from NDRs and delivery reports, matched to the email we sent. Never suppresses the address.';
alter table email_bounces enable row level security;
create policy admin_all on email_bounces for select to authenticated using (app.is_admin());
revoke all on email_bounces from anon, authenticated;
grant select on email_bounces to authenticated;
grant select, insert, update, delete on email_bounces to service_role;
create trigger audit_email_bounces after insert or update or delete on email_bounces for each row execute function app.audit_row();

-- the sender of insurer emails (the catalogue's from address)
create function app.insurer_sender() returns text
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(substring(c.from_address from '<([^>]+)>'), c.from_address) from notification_catalogue c where c.code = 'insurer_invoice'
$$;

-- the allowlist request, ready to send by the Admin (Blind Spot branding, the sender address as it is)
create function app.insurer_allowlist_request(p_to text, p_sender text, p_code text, p_reason text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select format('Hello,%sOur emails to %s are refused by your mail server (%s). Please add %s to the senders this mailbox accepts, or ask your IT team to allow it. We send the rental invoices and estimates for the claims we handle for you from that address.%sThank you,%sBlind Spot Car Rental',
                E'\n\n', p_to, coalesce(nullif(btrim(concat_ws(' ', p_code, p_reason)), ''), 'not accepted'), p_sender, E'\n\n', E'\n')
$$;

-- p: {ref (the X-Outbox-Ref of the email that bounced), to (the address that failed), status ('5.7.129'), reason, source}
create function app.server_email_bounce(p jsonb) returns jsonb
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
  v_fallback text;
  v_words text;
begin
  if v_to !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then return jsonb_build_object('matched', false, 'why', 'no failed address'); end if;
  -- only an email we sent to that address: by our reference, else the latest sent to it in 14 days
  if v_ref is not null then select * into o from notification_outbox where id = v_ref and lower(to_address) = v_to; end if;
  if o.id is null then
    select * into o from notification_outbox where lower(to_address) = v_to and status = 'sent' and sent_at > now() - interval '14 days' order by sent_at desc limit 1;
  end if;
  if o.id is null then return jsonb_build_object('matched', false, 'why', 'not one of our emails'); end if;
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
create function public.server_email_bounce(p jsonb) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$ select app.server_email_bounce(p) $$;

-- ================================================================ 4. delivery of each version
create function app.insurer_delivery(p_invoice uuid, p_version integer) returns jsonb
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('to', o.to_address, 'at', coalesce(o.sent_at, o.created_at), 'fallback', (e.payload ? 'fallback_of'),
           'status', case when bo.id is not null then 'bounced' when o.status = 'sent' and o.sent_at < now() - interval '24 hours' then 'delivered'
                          when o.status = 'sent' then 'sent' when o.status in ('failed', 'suppressed', 'skipped') then 'failed' else 'queued' end,
           'reason', coalesce(nullif(concat_ws(' ', bo.status_code, bo.reason), ''), case when o.status in ('failed', 'suppressed', 'skipped') then o.last_error end))
           order by o.created_at), '[]'::jsonb)
    from app_events e join notification_outbox o on o.event_id = e.id
    left join lateral (select * from email_bounces x where x.outbox_id = o.id order by x.received_at desc limit 1) bo on true
   where e.entity_id = p_invoice and e.code in ('insurer_invoice', 'insurer_estimate') and (e.payload ->> 'version')::int = p_version
$$;

alter function app.insurer_rental_json(uuid, jsonb) rename to insurer_rental_json_pre5204;
create function app.insurer_rental_json(p_user uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v jsonb := app.insurer_rental_json_pre5204(p_user, p);
begin
  if jsonb_typeof(v -> 'versions') <> 'array' or v -> 'invoice' ->> 'id' is null then return v; end if;
  return v || jsonb_build_object('versions', (select coalesce(jsonb_agg(x || jsonb_build_object('delivery', app.insurer_delivery((v -> 'invoice' ->> 'id')::uuid, (x ->> 'version')::int),
                                       'bounced_at', iv.bounced_at, 'bounce_reason', iv.bounce_reason, 'fallback_to', iv.fallback_to) order by n), '[]'::jsonb)
                                     from jsonb_array_elements(v -> 'versions') with ordinality t(x, n) left join insurer_invoice_versions iv on iv.id = (x ->> 'id')::uuid))
    || jsonb_build_object('claim', (v -> 'claim') || (select jsonb_build_object('insurer_claims_email', i.claims_email, 'insurer_claims_phone', i.claims_phone)
                                                       from insurers i where i.id = (v -> 'claim' ->> 'insurer_id')::uuid));
end $$;
select pg_temp.copy_grants('app.insurer_rental_json(uuid, jsonb)'::regprocedure, 'app.insurer_rental_json_pre5204(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. never from rent@ (REQ-137)
create function app.insurer_not_from_rent() returns trigger
language plpgsql set search_path = public, app, pg_temp as $$
declare v jsonb := to_jsonb(new);
begin
  if (coalesce(v ->> 'audience', '') = 'insurer' or coalesce(v ->> 'code', '') in ('insurer_invoice', 'insurer_estimate', 'insurer_payment_received'))
     and concat_ws(' ', v ->> 'from_address', v ->> 'reply_to') ~* 'rent@carmacars\.ca' then
    raise exception 'Insurer emails never go from rent@carmacars.ca: use blindspotcarrental@carmacars.ca (REQ-137)' using errcode = '23514';
  end if;
  return new;
end $$;
create trigger notification_catalogue_insurer_sender before insert or update on notification_catalogue for each row execute function app.insurer_not_from_rent();
create trigger email_reply_to_insurer_sender before insert or update on email_reply_to for each row execute function app.insurer_not_from_rent();
create trigger notification_outbox_insurer_sender before insert or update of reply_to on notification_outbox for each row execute function app.insurer_not_from_rent();
-- what is there now passes (a database that already broke the rule stops here)
do $$
begin
  if exists (select 1 from notification_catalogue where (audience = 'insurer' or code in ('insurer_invoice', 'insurer_estimate', 'insurer_payment_received'))
              and concat_ws(' ', from_address, reply_to) ~* 'rent@carmacars\.ca')
     or exists (select 1 from email_reply_to where audience = 'insurer' and reply_to ~* 'rent@carmacars\.ca') then
    raise exception '5204: an insurer email is set to go from rent@carmacars.ca';
  end if;
end $$;

revoke all on function app.insurer_sender(), app.insurer_allowlist_request(text, text, text, text), app.server_email_bounce(jsonb), public.server_email_bounce(jsonb),
  app.insurer_delivery(uuid, integer), app.insurer_rental_json_pre5204(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.insurer_sender(), app.insurer_allowlist_request(text, text, text, text), app.server_email_bounce(jsonb), public.server_email_bounce(jsonb),
  app.insurer_delivery(uuid, integer), app.insurer_rental_json_pre5204(uuid, jsonb) to service_role;
