-- 2811 (release 44, part B): an insurer-billed rental's Blind Spot agreement and its invoice show what the insurer pays.
--   1. The Blind Spot form's box 35 and box 14 were worked out from the booking's own rate (a monthly rate "/ 30 x 35 days",
--      a weekly rate "/ 7 x 17 days = $75.56 a day rounded"), so they did not match the insurer's invoice. The form's facts
--      (app.blindspot_extra) now carry the insurer's share exactly as its invoice computes it (app.booking_insurer_share:
--      the days covered, the insurer's daily rate, the rental and fees billed, the HST), and the form prints 35 x $80.00,
--      the VLF a day, the HST and the totals of the invoice to the cent (web/src/features/blindspot/layout.ts).
--   2. An insurer invoice never shows the CarmaCars name: the e-Transfer address on it is left out when it is a CarmaCars
--      address (Program settings bs_pay_etransfer_email; set a Blind Spot address there to print one); its fee lines and
--      company block are cleaned of the name on the PDF (web/src/features/documents/invoice-blocks.ts), which also adds
--      the Cheque section (payable to the legal entity, mailed to the company address, quoting the invoice and claim).
--   3. An issued invoice is final: its facts say final from the moment it is sent, so its PDF never says Draft.
--   4. Send by email goes to the adjuster's email on the booking (else the insurer's billing email), as the screen says,
--      instead of being refused when the insurer had no billing email.
-- No applied migration is edited: functions are wrapped (_pre2811).

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 1. the insurer's share on the form
alter function app.blindspot_extra(uuid) rename to blindspot_extra_pre2811;
create function app.blindspot_extra(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.blindspot_extra_pre2811(p_booking);
  b bookings;
  s record;
  r record;
begin
  if jsonb_typeof(v -> 'insurer') <> 'object' then return v; end if;
  select * into b from bookings where id = p_booking;
  select * into s from app.booking_insurer_share(p_booking);
  select * into r from app.booking_insurer_rate(b);
  return jsonb_set(v, '{insurer,share}', jsonb_build_object('bill_to', b.bill_to, 'covered_days', s.covered_days, 'daily_rate_cents', r.daily_rate_cents,
    'rental_share_cents', s.rental_share_cents, 'fees_share_cents', s.fees_share_cents, 'share_cents', s.share_cents, 'hst_cents', s.hst_cents));
end $$;
select pg_temp.copy_grants('app.blindspot_extra(uuid)'::regprocedure, 'app.blindspot_extra_pre2811(uuid)'::regprocedure);

-- ================================================================ 2 and 3. the invoice's facts
alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre2811;
create function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  f jsonb := app.pdf_facts_pre2811(p_kind, p_key, p_user);
begin
  if f is null or p_kind <> 'insurer_invoice' then return f; end if;
  if f ? 'pay' and jsonb_typeof(f -> 'pay') = 'object' and app.no_carmacars(f #>> '{pay,etransfer_email}') is null then
    f := jsonb_set(f, '{pay,etransfer_email}', 'null'::jsonb);
  end if;
  return f || jsonb_build_object('final', coalesce(f ->> 'status', 'draft') <> 'draft');
end $$;
select pg_temp.copy_grants('app.pdf_facts(text, text, uuid)'::regprocedure, 'app.pdf_facts_pre2811(text, text, uuid)'::regprocedure);

-- ================================================================ 4. issuing: Send by email reaches the adjuster
-- The admin list promised "the adjuster's email on the booking (else the insurer's billing address)", but the email went
-- to the billing address only and was refused when the insurer had none, so an invoice could not be issued by email.
-- Now: the adjuster's email on the booking when there is one, else the insurer's billing email; the draft is marked sent
-- as before (0032).
create or replace function app.send_insurer_invoice_email(p_by uuid, p_invoice uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  ii insurer_invoices;
  b bookings;
  v_email text;
  v_name text;
  v_n integer;
  v_event bigint;
begin
  if not app.user_runs_finance(p_by) then raise exception 'Finance or an Admin sends an insurer invoice' using errcode = '42501'; end if;
  select * into ii from insurer_invoices where id = p_invoice for update;
  if ii.id is null then raise exception 'Insurer invoice not found' using errcode = 'P0002'; end if;
  if ii.status in ('paid', 'written_off') then raise exception 'This invoice is %', replace(ii.status, '_', ' ') using errcode = '23514'; end if;
  select * into b from bookings where id = ii.booking_id;
  v_email := nullif(btrim(coalesce(b.insurer_adjuster_email, '')), '');
  v_name := case when v_email is not null then nullif(btrim(coalesce(b.insurer_adjuster_name, '')), '') end;
  if v_email is null then
    select nullif(btrim(x.billing_email), ''), coalesce(nullif(btrim(x.billing_contact_name), ''), x.name) into v_email, v_name from insurers x where x.id = ii.insurer_id;
  end if;
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'No email to send it to: add the adjuster''s email on the booking, or the insurer''s billing email in Settings, Insurers' using errcode = '23514';
  end if;
  if ii.status = 'draft' then
    update insurer_invoices set status = 'sent', sent_at = now(), sent_by = p_by where id = ii.id;
  end if;
  select count(*) into v_n from app_events where code = 'insurer_invoice' and entity = 'insurer_invoice' and entity_id = ii.id;
  v_event := app.emit_event('insurer_invoice', 'insurer_invoice', ii.id,
                            jsonb_build_object('insurer_id', ii.insurer_id, 'to_email', v_email, 'to_name', v_name),
                            'insurer_invoice:' || ii.id || ':send' || (v_n + 1));
  return jsonb_build_object('invoice_id', ii.id, 'status', (select status from insurer_invoices where id = ii.id), 'event_id', v_event,
                            'to', v_email, 'sends', v_n + 1);
end $$;

alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre2811;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'insurer_invoice' and nullif(btrim(coalesce(p_event.payload ->> 'to_email', '')), '') is not null then
    return query select 'insurer'::text, null::uuid, btrim(p_event.payload ->> 'to_email'), coalesce(nullif(p_event.payload ->> 'to_name', ''), 'there'),
                        null::uuid, null::uuid, true;
    return;
  end if;
  return query select * from app.notification_recipients_pre2811(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre2811(app_events, notification_catalogue)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['blindspot_extra_pre2811', 'pdf_facts_pre2811', 'notification_recipients_pre2811'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
