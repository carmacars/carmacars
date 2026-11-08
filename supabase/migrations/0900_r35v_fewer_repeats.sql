-- 0900_r35v_fewer_repeats.sql
-- Release 35, part V (docs/changes/2026-11-08-r35-fewer-repeat-messages.md). SCHEMA_MARKER 0900.
--
-- The owner, November 8: "There seems to be a lot of repetitive messages and emails for renters." One clear message per
-- real event, no near duplicates:
--   1. The causes, fixed where they start:
--      a. a new agreement version right after paying: the card on file replaced by the card that paid and the deposit's
--         method set by the deposit link changed the agreement's payment details, which made a "corrected" version. How the
--         renter paid is not a change of terms: payment details no longer make a version (app.agreement_changes).
--      b. "Tomorrow: your car at ..." minutes after the confirmation that gives the date and time: the reminder is not sent
--         when the confirmation went out within the reminder gap before the reminder would be due (notify_reminder_confirm_gap_hours).
--      c. "Upload your licence and coverage proof" with the licence approved: the chase now goes only for what the renter
--         still has to send (nothing for what waits for our review), and the subject and copy name only that; the same
--         confirmation gap applies (app.renter_todo).
--      d. "One step left to book" while a staff pay link was out: not sent while a pay link staff sent is open or a payment is pending.
--      e. two staff pay link emails a minute apart, both "Payment for booking": each says what it is for (the deposit, the card).
--      f. owner_invoice_voided four to six times a day: one email per owner per day listing the invoices.
--      g. owner_vehicle_listed queued 44 times with no address for a partner's imported cars: never for a partner car,
--         never without an address to send to.
--   2. A guard in the email queue: the same email to the same person for the same booking (or record) is not sent twice
--      within notify_repeat_window_minutes (30), unless the email is marked always_send (receipts, signed copies, staff
--      messages, sign-in and signing codes). It is kept with status suppressed and the reason (Admin > Logs, Emails).
--   3. The same guard for texts (phone_outbox) and portal notices.
--   4. The owner's direction (November 8): emails and texts to the same person for the same booking queued within
--      notify_merge_window_minutes (2) are held and sent as one: one subject naming the booking ("Update on your booking
--      CC-10080: confirmed, receipt and agreement"), each email as its own section with its own buttons, attachments kept;
--      one text with a short line per item. A lone message goes after the window. Staff messages typed by a person,
--      sign-in and signing codes and urgent messages are never held.
--   5. Cloudflare Email Service: the site counted Cloudflare as sending only from the outbox's history of 'cf:' rows and a
--      success in the last day, so the day's cap fell to Resend's budget and Settings > Usage said "not set up" while
--      Cloudflare was sending. A recorded success now counts (app.cf_email_ever_sent), the state is 'ok' after a success
--      unless Cloudflare refused in the last 15 minutes or the binding is missing, and the cap is Cloudflare's budget plus
--      Resend's whenever Cloudflare works. The booking page's email box and Settings > Usage read the same email pace.
-- No applied migration is edited: functions are wrapped (_pre0900) or patched in place (pg_temp.patch_fn).
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

create function pg_temp.patch_fn(p_sig regprocedure, p_old text, p_new text) returns void
language plpgsql as $$
declare
  d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then
    raise exception '0900: the text to change was not found in %: %', p_sig, left(p_old, 160);
  end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings
alter table program_settings
  add column if not exists notify_repeat_window_minutes integer not null default 30 check (notify_repeat_window_minutes between 0 and 1440),
  add column if not exists notify_merge_window_minutes integer not null default 2 check (notify_merge_window_minutes between 0 and 30),
  add column if not exists notify_reminder_confirm_gap_hours integer not null default 12 check (notify_reminder_confirm_gap_hours between 0 and 72),
  add column if not exists owner_void_hold_minutes integer not null default 30 check (owner_void_hold_minutes between 0 and 720),
  add column if not exists owner_void_next_day_hour integer not null default 9 check (owner_void_next_day_hour between 6 and 20);
comment on column program_settings.notify_repeat_window_minutes is 'Emails and texts: the same message to the same person for the same booking is not sent twice within these minutes (0 turns the guard off). Receipts, signed copies, staff messages and codes always go (0900).';
comment on column program_settings.notify_merge_window_minutes is 'Emails and texts: messages to the same person for the same booking queued within these minutes go as one combined email and one text (0 sends each on its own). Staff messages, codes and urgent messages are never held (0900).';
comment on column program_settings.notify_reminder_confirm_gap_hours is 'The pickup reminder and the documents reminder are not sent when the booking confirmation, which already says it, went out within these hours before the reminder would be due (0900).';
comment on column program_settings.owner_void_hold_minutes is 'Cancelled owner invoices: the email waits these minutes so every invoice cancelled meanwhile is in one email (0900).';
comment on column program_settings.owner_void_next_day_hour is 'Cancelled owner invoices: once the day''s email went, later cancellations wait for this hour (Toronto) the next day, so an owner gets at most one a day (0900).';

-- ================================================================ 2. the catalogue: always sent, held to combine, the short label
alter table notification_catalogue
  add column if not exists always_send boolean not null default false,
  add column if not exists hold_to_merge boolean not null default true,
  add column if not exists merge_label text;
comment on column notification_catalogue.always_send is 'Sent even when the same email went to the same person for the same booking a moment ago: receipts, signed copies, staff messages, codes (0900).';
comment on column notification_catalogue.hold_to_merge is 'May be held a moment and combined with other messages to the same person for the same booking (0900). Off for staff messages, codes and urgent messages.';
comment on column notification_catalogue.merge_label is 'The item''s words in a combined email''s subject ("confirmed", "receipt"...) (0900).';

update notification_catalogue set always_send = true
 where always_email or code like 'account\_%' or code like '%signing\_code'
    or code in ('renter_staff_message', 'insurance_staff_message', 'renter_driver_link', 'renter_continue_request', 'renter_chat_transcript');
update notification_catalogue set hold_to_merge = false
 where audience not in ('renter', 'owner', 'investor') or category <> 'transactional' or is_digest
    or code like 'account\_%' or code like '%signing\_code'
    or code in ('renter_staff_message', 'insurance_staff_message', 'renter_continue_request', 'renter_chat_transcript', 'renter_driver_link', 'owner_cosigner_sign')
    or code in (select t.code from sms_templates t where t.urgent);
update notification_catalogue c set merge_label = x.label
  from (values ('renter_booking_confirmed', 'confirmed'), ('renter_payment_receipt', 'receipt'), ('renter_agreement_version', 'agreement'),
               ('renter_agreement_signed', 'signed agreement'), ('renter_agreement_ready', 'agreement to sign'), ('renter_identity_needed', 'documents needed'),
               ('renter_identity_approved', 'documents approved'), ('renter_identity_rejected', 'document to send again'), ('renter_coverage_needed', 'proof of coverage'),
               ('renter_booking_reminder', 'pickup reminder'), ('renter_pickup_details', 'pickup details'), ('renter_return_reminder', 'return reminder'),
               ('renter_return_details', 'return details'), ('renter_extra_charge', 'charge'), ('renter_refund_issued', 'refund'),
               ('renter_deposit_released', 'deposit released'), ('renter_final_statement', 'final statement'), ('renter_rental_started', 'rental started'),
               ('renter_return_complete', 'return complete'), ('renter_change_applied', 'change applied'), ('renter_extension_confirmed', 'extension confirmed'),
               ('renter_offer_ready', 'offer'), ('renter_recovery_pay', 'payment'), ('renter_payment_failed', 'payment failed'),
               ('owner_new_booking', 'new booking'), ('owner_booking_confirmed', 'booking confirmed'), ('owner_invoice_issued', 'invoice'),
               ('owner_invoice_voided', 'invoice cancelled'), ('owner_payment_recorded', 'receipt'), ('owner_statement_ready', 'statement'),
               ('owner_vehicle_listed', 'car listed'), ('owner_payout_sent', 'payout')) as x(code, label)
 where c.code = x.code;

-- ================================================================ 3. the queues: suppressed and merged rows
alter table notification_outbox
  add column if not exists merged_into uuid references notification_outbox (id) on delete set null,
  add column if not exists hold_until timestamptz;
alter table notification_outbox drop constraint if exists notification_outbox_status_check;
alter table notification_outbox add constraint notification_outbox_status_check
  check (status in ('queued', 'sending', 'sent', 'failed', 'suppressed', 'skipped', 'delayed', 'merged'));
create index if not exists notification_outbox_merged_idx on notification_outbox (merged_into) where merged_into is not null;
create index if not exists notification_outbox_repeat_idx on notification_outbox (code, lower(to_address), created_at desc);
comment on column notification_outbox.merged_into is 'Sent inside this other email, as one combined message (0900; status merged, sent_at when it went).';
comment on column notification_outbox.hold_until is 'Held until then so messages to the same person for the same booking go as one (0900).';

alter table phone_outbox
  add column if not exists merged_into uuid references phone_outbox (id) on delete set null,
  add column if not exists hold_until timestamptz;
alter table phone_outbox drop constraint if exists phone_outbox_status_check;
alter table phone_outbox add constraint phone_outbox_status_check
  check (status in ('queued', 'sending', 'sent', 'failed', 'skipped', 'suppressed', 'merged'));
create index if not exists phone_outbox_repeat_idx on phone_outbox (to_number, sms_kind, created_at desc);
comment on column phone_outbox.merged_into is 'Its line went inside this other text (0900; status merged).';
comment on column phone_outbox.hold_until is 'Held until then so texts to the same number for the same booking go as one (0900).';

-- ================================================================ 4. the repeat guard (emails)
create or replace function app.outbox_repeat_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  w integer := coalesce((app.settings()).notify_repeat_window_minutes, 30);
  c notification_catalogue;
  p notification_outbox;
  v_ref uuid := coalesce(new.booking_id, new.entity_id);
begin
  if w <= 0 or v_ref is null then return new; end if;
  if not (new.status = 'queued' or (new.status = 'skipped' and coalesce(new.status_reason, '') like 'Sent by text%')) then return new; end if;
  select * into c from notification_catalogue where code = new.code;
  if c.code is null or c.always_send or c.audience like 'staff\_%' then return new; end if;
  if nullif(btrim(coalesce(new.to_address, '')), '') is null and new.recipient_user_id is null then return new; end if;
  select * into p from notification_outbox o
   where o.code = new.code and coalesce(o.booking_id, o.entity_id) = v_ref and o.created_at > now() - make_interval(mins => w)
     and ((nullif(btrim(coalesce(new.to_address, '')), '') is not null and lower(o.to_address) = lower(new.to_address))
          or (new.recipient_user_id is not null and o.recipient_user_id = new.recipient_user_id))
     and (o.status in ('queued', 'sending', 'sent', 'delayed', 'merged') or (o.status = 'skipped' and coalesce(o.status_reason, '') like 'Sent by text%'))
   order by o.created_at desc limit 1;
  if p.id is null then return new; end if;
  new.status := 'suppressed';
  new.status_reason := format('Repeat held back: the same email went to this person for this booking at %s (Program settings: not twice within %s minutes)',
                              app.fmt_time(p.created_at), w);
  new.sms_planned := false;
  return new;
end $$;
drop trigger if exists notification_outbox_zdedupe on notification_outbox;
-- after notification_outbox_route (names run in order): the channel is known, and a suppressed row plans no text
create trigger notification_outbox_zdedupe before insert on notification_outbox for each row execute function app.outbox_repeat_guard();

-- ================================================================ 5. one email per owner per day for cancelled invoices
create or replace function app.owner_void_payload(p jsonb) returns jsonb
language plpgsql immutable as $$
declare
  n integer := coalesce(jsonb_array_length(case when jsonb_typeof(p -> 'invoices') = 'array' then p -> 'invoices' end), 0);
  one jsonb := case when n > 0 then p -> 'invoices' -> 0 else jsonb_build_object('invoice_number', p ->> 'invoice_number', 'vehicle_name', p ->> 'vehicle_name') end;
begin
  if n <= 1 then
    return p || jsonb_build_object('has_several', false,
      'voided_title', format('Invoice %s is cancelled', one ->> 'invoice_number'),
      'voided_preheader', coalesce(nullif(p ->> 'void_reason', ''), 'You do not need to pay it. Nothing will be debited.'),
      'voided_ref', 'Invoice ' || coalesce(one ->> 'invoice_number', ''),
      'voided_heading', format('You do not need to pay invoice %s', one ->> 'invoice_number'),
      'voided_lead', format('we cancelled this invoice for your %s.', coalesce(nullif(one ->> 'vehicle_name', ''), 'car')));
  end if;
  return p || jsonb_build_object('has_several', true,
    'voided_title', format('%s invoices are cancelled', n),
    'voided_preheader', 'You do not need to pay them. Nothing will be debited.',
    'voided_ref', format('%s invoices', n),
    'voided_heading', format('You do not need to pay these %s invoices', n),
    'voided_lead', 'we cancelled the invoices below. Each one says why.');
end $$;

-- ================================================================ 6. holding to combine (emails)
create or replace function app.outbox_merge_hold() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  w integer := coalesce(s.notify_merge_window_minutes, 2);
  c notification_catalogue;
  h notification_outbox;
  v_until timestamptz;
  v_p jsonb;
begin
  if new.status <> 'queued' or nullif(btrim(coalesce(new.to_address, '')), '') is null then return new; end if;
  select * into c from notification_catalogue where code = new.code;
  if c.code is null then return new; end if;
  -- cancelled owner invoices: folded into the owner's waiting email, else held (to the next morning once today's went)
  if new.code = 'owner_invoice_voided' and new.owner_id is not null then
    select * into h from notification_outbox o where o.code = 'owner_invoice_voided' and o.owner_id = new.owner_id
       and o.status in ('queued', 'delayed') and o.merged_into is null order by o.created_at limit 1 for update;
    if h.id is not null then
      v_p := app.owner_void_payload(h.payload || jsonb_build_object('invoices',
               coalesce(case when jsonb_typeof(h.payload -> 'invoices') = 'array' then h.payload -> 'invoices' end, '[]'::jsonb)
               || coalesce(case when jsonb_typeof(new.payload -> 'invoices') = 'array' then new.payload -> 'invoices' end, '[]'::jsonb)));
      update notification_outbox set payload = v_p, updated_at = now() where id = h.id;
      update phone_outbox t set body = left(coalesce((app.sms_text_for(h.code, v_p, h.audience, h.booking_id)) ->> 'body', t.body), 1600)
       where t.notification_id = h.id and t.status = 'queued';
      new.status := 'merged'; new.merged_into := h.id; new.sms_planned := false;
      new.payload := new.payload || jsonb_build_object('_folded', true);
      new.status_reason := 'Listed in the owner''s one email of cancelled invoices';
      return new;
    end if;
    v_until := case when exists (select 1 from notification_outbox o where o.code = 'owner_invoice_voided' and o.owner_id = new.owner_id
                                   and o.status in ('sent', 'sending') and o.sent_at >= app.local_midnight(app.local_date(now())))
                    then app.local_midnight(app.local_date(now()) + 1) + make_interval(hours => s.owner_void_next_day_hour)
                    else now() + make_interval(mins => s.owner_void_hold_minutes) end;
    new.send_after := greatest(new.send_after, v_until);
    new.hold_until := new.send_after;
    return new;
  end if;
  if w <= 0 or not c.hold_to_merge or c.audience not in ('renter', 'owner', 'investor') or new.category <> 'transactional'
     or coalesce((select t.urgent from sms_templates t where t.code = new.code), false) then
    return new;
  end if;
  select * into h from notification_outbox o
   where o.status = 'queued' and o.merged_into is null and o.hold_until > now() and o.created_at > now() - make_interval(mins => w)
     and lower(o.to_address) = lower(new.to_address) and o.booking_id is not distinct from new.booking_id and o.id <> new.id
   order by o.created_at limit 1 for update;
  if h.id is not null then
    new.status := 'merged'; new.merged_into := h.id;
    new.status_reason := format('Sent in one email with %s', h.code);
    return new;
  end if;
  new.send_after := greatest(new.send_after, now() + make_interval(mins => w));
  new.hold_until := new.send_after;
  return new;
end $$;
drop trigger if exists notification_outbox_zmerge on notification_outbox;
create trigger notification_outbox_zmerge before insert on notification_outbox for each row execute function app.outbox_merge_hold();

-- The words "a, b and c".
create or replace function app.words_and(p text[]) returns text
language sql immutable as $$
  select case when coalesce(cardinality(p), 0) = 0 then '' when cardinality(p) = 1 then p[1]
              else array_to_string(p[1:cardinality(p) - 1], ', ') || ' and ' || p[cardinality(p)] end
$$;

-- What the sender combines for one claimed email: the email itself first, then each email merged into it (folded
-- invoice cancellations are already in its payload). subject is null for a lone email (it keeps its own).
create or replace function app.outbox_merge_parts(p_head uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  h notification_outbox;
  v_parts jsonb;
  v_labels text[];
  v_number text;
begin
  select * into h from notification_outbox where id = p_head;
  if h.id is null then return jsonb_build_object('subject', null, 'parts', '[]'::jsonb); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'subject', app.render_text(c.subject, o.payload), 'payload', o.payload,
                                               'template_html', c.template_html, 'template_text', c.template_text) order by (o.id = h.id) desc, o.created_at, o.id), '[]'::jsonb),
         array_agg(coalesce(c.merge_label, replace(regexp_replace(o.code, '^(renter|owner|investor)_', ''), '_', ' ')) order by (o.id = h.id) desc, o.created_at, o.id)
    into v_parts, v_labels
    from notification_outbox o join notification_catalogue c on c.code = o.code
   where o.id = h.id or (o.merged_into = h.id and o.status = 'merged' and o.sent_at is null and not coalesce((o.payload ->> '_folded')::boolean, false));
  if jsonb_array_length(v_parts) <= 1 then return jsonb_build_object('subject', null, 'parts', v_parts); end if;
  select array_agg(l order by k) into v_labels from (select l, min(k) k from unnest(v_labels) with ordinality u(l, k) group by l) d;
  select b.booking_number into v_number from bookings b where b.id = h.booking_id;
  return jsonb_build_object('subject', case when v_number is not null then format('Update on your booking %s: %s', v_number, app.words_and(v_labels))
                                            else 'Updates from CarmaCars: ' || app.words_and(v_labels) end,
                            'parts', v_parts);
end $$;

-- the sender could not render a merged email: it goes on its own
create or replace function app.outbox_merge_detach(p_id uuid) returns void
language sql security definer set search_path = public, app as $$
  update notification_outbox set status = 'queued', merged_into = null, hold_until = null, send_after = now(), updated_at = now(),
         status_reason = 'On its own: it could not be combined'
   where id = p_id and status = 'merged' and sent_at is null
$$;

-- sent: the merged emails went with it (kept as merged, with the time and the provider's id; they count as one email)
alter function app.outbox_mark_sent(uuid, text, text, timestamptz) rename to outbox_mark_sent_pre0900;
create function app.outbox_mark_sent(p_id uuid, p_provider_id text, p_body_text text default null, p_now timestamptz default now()) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  h notification_outbox;
begin
  perform app.outbox_mark_sent_pre0900(p_id, p_provider_id, p_body_text, p_now);
  select * into h from notification_outbox where id = p_id;
  update notification_outbox set sent_at = p_now, provider_id = p_provider_id, message_id = h.message_id, updated_at = now(),
         status_reason = case when coalesce((payload ->> '_folded')::boolean, false) then status_reason else format('Sent in one email with %s', h.code) end
   where merged_into = p_id and status = 'merged' and sent_at is null;
end $$;
select pg_temp.copy_grants('app.outbox_mark_sent(uuid, text, text, timestamptz)'::regprocedure, 'app.outbox_mark_sent_pre0900(uuid, text, text, timestamptz)'::regprocedure);

-- failed for good: the merged emails fail with it (each can be sent again from Admin > Logs)
alter function app.outbox_mark_failed(uuid, text, boolean, timestamptz) rename to outbox_mark_failed_pre0900;
create function app.outbox_mark_failed(p_id uuid, p_error text, p_permanent boolean default false, p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.outbox_mark_failed_pre0900(p_id, p_error, p_permanent, p_now);
begin
  if v = 'failed' then
    update notification_outbox set status = 'failed', merged_into = null, last_error = left('Sent with another email that failed: ' || coalesce(p_error, ''), 1000), updated_at = now()
     where merged_into = p_id and status = 'merged' and sent_at is null;
  end if;
  return v;
end $$;
select pg_temp.copy_grants('app.outbox_mark_failed(uuid, text, boolean, timestamptz)'::regprocedure, 'app.outbox_mark_failed_pre0900(uuid, text, boolean, timestamptz)'::regprocedure);

-- an email whose combined email will not go (cancelled by an Admin, stale, stopped) does not go either: it was part of it
create or replace function app.outbox_merge_release(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  update notification_outbox m set status = 'skipped', updated_at = now(),
         status_reason = left('Not sent: the email it was combined with was not sent (' || coalesce(h.status_reason, h.status) || ')', 500)
    from notification_outbox h
   where m.merged_into = h.id and m.status = 'merged' and m.sent_at is null and h.status in ('skipped', 'suppressed');
  get diagnostics n = row_count;
  return n;
end $$;

alter function app.outbox_claim(integer, timestamptz) rename to outbox_claim_pre0900;
create function app.outbox_claim(p_limit integer default 20, p_now timestamptz default now())
returns table (id uuid, code text, category text, to_address text, to_name text, from_address text, reply_to text, subject text, payload jsonb,
               attempts integer, unsubscribe_url text, template_html text, template_text text)
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.outbox_merge_release(p_now);
  return query select * from app.outbox_claim_pre0900(p_limit, p_now);
end $$;
select pg_temp.copy_grants('app.outbox_claim(integer, timestamptz)'::regprocedure, 'app.outbox_claim_pre0900(integer, timestamptz)'::regprocedure);

-- ================================================================ 7. texts: the repeat guard and combining
create or replace function app.phone_ref(p phone_outbox) returns uuid
language sql stable security definer set search_path = public, app as $$
  select coalesce(p.booking_id, (select coalesce(o.booking_id, o.entity_id) from notification_outbox o where o.id = p.notification_id))
$$;

create or replace function app.phone_repeat_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  w integer := coalesce((app.settings()).notify_repeat_window_minutes, 30);
  v_ref uuid;
  p phone_outbox;
begin
  if w <= 0 or new.status <> 'queued' or new.kind <> 'notify' or new.sms_kind is null then return new; end if;
  if coalesce((select c.always_send from notification_catalogue c where c.code = new.sms_kind), true) then return new; end if;
  v_ref := app.phone_ref(new);
  if v_ref is null then return new; end if;
  select * into p from phone_outbox x
   where x.to_number = new.to_number and x.sms_kind = new.sms_kind and x.kind = 'notify' and x.created_at > now() - make_interval(mins => w)
     and x.status in ('queued', 'sending', 'sent', 'merged') and app.phone_ref(x) = v_ref
   order by x.created_at desc limit 1;
  if p.id is null then return new; end if;
  new.status := 'suppressed';
  new.status_reason := format('Repeat held back: the same text went to this number for this booking at %s (not twice within %s minutes)', app.fmt_time(p.created_at), w);
  return new;
end $$;
drop trigger if exists phone_outbox_repeat on phone_outbox;
create trigger phone_outbox_repeat before insert on phone_outbox for each row execute function app.phone_repeat_guard();

-- Two texts as one: "CarmaCars updates:" and a line per item; the opt-out line once at the end.
create or replace function app.sms_merge_body(p_a text, p_b text) returns text
language plpgsql immutable as $$
declare
  v_stop boolean := p_a like '% Reply STOP to opt out.' or p_b like '% Reply STOP to opt out.';
  a text := regexp_replace(p_a, '\s*Reply STOP to opt out\.$', '');
  b text := regexp_replace(p_b, '\s*Reply STOP to opt out\.$', '');
  v_lines text;
begin
  v_lines := case when a like E'CarmaCars updates:\n%' then substr(a, length(E'CarmaCars updates:\n') + 1)
                  else '- ' || regexp_replace(a, '^CarmaCars:\s*', '') end
             || E'\n- ' || regexp_replace(b, '^CarmaCars:\s*', '');
  return E'CarmaCars updates:\n' || v_lines || case when v_stop then E'\nReply STOP to opt out.' else '' end;
end $$;

create or replace function app.phone_merge_hold() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  w integer := coalesce((app.settings()).notify_merge_window_minutes, 2);
  h phone_outbox;
  v_body text;
begin
  if w <= 0 or new.status <> 'queued' or new.kind <> 'notify' then return new; end if;
  if coalesce((select t.urgent from sms_templates t where t.code = new.sms_kind), false)
     or not coalesce((select c.hold_to_merge from notification_catalogue c where c.code = new.sms_kind), false) then
    return new;
  end if;
  select * into h from phone_outbox x
   where x.kind = 'notify' and x.status = 'queued' and x.merged_into is null and x.hold_until > now() and x.to_number = new.to_number
     and x.booking_id is not distinct from new.booking_id and x.created_at > now() - make_interval(mins => w)
   order by x.created_at limit 1 for update;
  if h.id is not null then
    v_body := app.sms_merge_body(h.body, new.body);
    if length(v_body) <= 1600 then
      update phone_outbox set body = v_body, updated_at = now() where id = h.id;
      new.status := 'merged'; new.merged_into := h.id;
      new.status_reason := 'Sent in one text with the others for this booking';
      return new;
    end if;
  end if;
  new.send_after := greatest(new.send_after, now() + make_interval(mins => w));
  new.hold_until := new.send_after;
  return new;
end $$;
drop trigger if exists phone_outbox_zmerge on phone_outbox;
create trigger phone_outbox_zmerge before insert on phone_outbox for each row execute function app.phone_merge_hold();

-- ================================================================ 8. portal notices: the same guard
create or replace function app.notification_repeat_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  w integer := coalesce((app.settings()).notify_repeat_window_minutes, 30);
begin
  if w <= 0 or new.entity_id is null then return new; end if;
  if not exists (select 1 from notification_catalogue c where c.code = new.code and not c.always_send and c.audience in ('renter', 'owner', 'investor')) then return new; end if;
  if exists (select 1 from notifications n where n.user_id = new.user_id and n.code = new.code and n.entity_id = new.entity_id
                and n.created_at > now() - make_interval(mins => w)) then
    return null;
  end if;
  return new;
end $$;
drop trigger if exists notifications_repeat on notifications;
create trigger notifications_repeat before insert on notifications for each row execute function app.notification_repeat_guard();

-- ================================================================ 9. cause a: paying is not a change of terms
alter function app.agreement_changes(jsonb, jsonb) rename to agreement_changes_pre0900;
create function app.agreement_changes(p_old jsonb, p_new jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  -- how the renter paid (the card that paid becomes the card on file, the deposit link sets the deposit's method) is
  -- what the signed agreement said would happen, not a change of its terms: never a version of its own
  select coalesce(jsonb_agg(x order by o), '[]'::jsonb)
    from jsonb_array_elements(app.agreement_changes_pre0900(p_old, p_new)) with ordinality e(x, o)
   where x ->> 'key' not like 'payment.%'
$$;
select pg_temp.copy_grants('app.agreement_changes(jsonb, jsonb)'::regprocedure, 'app.agreement_changes_pre0900(jsonb, jsonb)'::regprocedure);

-- ================================================================ 10. causes b and c: reminders the confirmation already gave
-- The confirmation (which gives the date, the time and what is missing) went out within the gap before p_due.
create or replace function app.ntf_confirmation_covers(p_booking uuid, p_due timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from app_events e where e.code = 'renter_booking_confirmed' and e.entity = 'booking' and e.entity_id = p_booking
                    and e.created_at >= p_due - make_interval(hours => coalesce((app.settings()).notify_reminder_confirm_gap_hours, 12)))
$$;

-- What the renter still has to send: the drivers whose licence photos or selfie are not uploaded (or were rejected), and
-- the proof of coverage when none is confirmed or waiting for review. What waits for our review is not theirs to do.
create or replace function app.renter_todo(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
  v_names text[];
  v_cov boolean := false;
begin
  select * into b from bookings where id = p_booking;
  if b.id is null or b.booking_type = 'owner' then return jsonb_build_object('licence', '[]'::jsonb, 'coverage', false); end if;
  select array_agg(d.full_name order by d.role desc, d.full_name) into v_names from booking_drivers d
   where d.booking_id = b.id and d.identity_verified_on is null
     and exists (select 1 from jsonb_array_elements_text(coalesce(app.licence_status(b.id, d.driver_id) -> 'missing', '[]'::jsonb)) m
                  where m in ('licence front', 'licence back', 'selfie with the licence'));
  v_cov := b.coverage_confirmed_at is null and coalesce(b.coverage_option, 0) not in (3, 4)
           and not exists (select 1 from coverage_proofs c where c.booking_id = b.id and c.status in ('submitted', 'confirmed'));
  return jsonb_build_object('licence', to_jsonb(coalesce(v_names, '{}')), 'coverage', v_cov);
end $$;

create or replace function app.renter_todo_any(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select jsonb_array_length(t -> 'licence') > 0 or (t ->> 'coverage')::boolean from app.renter_todo(p_booking) t
$$;

select pg_temp.patch_fn('app.notify_reminders(timestamptz)'::regprocedure,
  E'and not (s.notify_pickup_soon and v_day and b.pickup_at <= p_now + make_interval(hours => s.notify_pickup_soon_hours)) loop\n    v_id := app.ntf_emit(''renter_booking_reminder''',
  E'and not (s.notify_pickup_soon and v_day and b.pickup_at <= p_now + make_interval(hours => s.notify_pickup_soon_hours))\n              and not app.ntf_confirmation_covers(b.id, b.pickup_at - make_interval(hours => s.notify_booking_reminder_hours)) loop\n    v_id := app.ntf_emit(''renter_booking_reminder''');
select pg_temp.patch_fn('app.notify_reminders(timestamptz)'::regprocedure,
  E'and app.ntf_missing_items(b.id) <> '''' loop\n    v_id := app.ntf_emit(''renter_identity_needed''',
  E'and app.renter_todo_any(b.id)\n              and not app.ntf_confirmation_covers(b.id, b.pickup_at - make_interval(hours => s.notify_identity_chase_hours)) loop\n    v_id := app.ntf_emit(''renter_identity_needed''');

-- the renter's emails say only what is missing (renter_identity_needed, renter_booking_confirmed and the others that list it)
alter function app.ntf_booking_pre0827(uuid) rename to ntf_booking_pre0900;
create function app.ntf_booking_pre0827(p_booking uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_booking_pre0900(p_booking);
  t jsonb;
  v_lic boolean;
  v_cov boolean;
  v_names text;
begin
  if x is null or p_booking is null then return x; end if;
  t := app.renter_todo(p_booking);
  v_lic := jsonb_array_length(t -> 'licence') > 0;
  v_cov := (t ->> 'coverage')::boolean;
  select app.words_and(array_agg(n)) into v_names from jsonb_array_elements_text(t -> 'licence') n;
  return x || jsonb_build_object(
    'needs_licence', v_lic, 'needs_coverage', v_cov, 'needs_verification', v_lic or v_cov,
    'needed_title', case when v_lic and v_cov then 'Upload your licence and coverage proof' when v_lic then 'Upload your licence photos'
                         when v_cov then 'Send your proof of coverage' else 'Your documents are in' end,
    'needed_line', case when v_lic and v_cov then format('We need the licence photos and a selfie of %s, plus proof of coverage,', v_names)
                        when v_lic then format('We need the licence photos and a selfie of %s', v_names)
                        when v_cov then 'We need your proof of coverage' else 'We have what we need' end,
    'needed_items', concat_ws(', ', case when v_lic then 'licence photos and selfie of ' || v_names end, case when v_cov then 'proof of coverage' end));
end $$;
select pg_temp.copy_grants('app.ntf_booking_pre0827(uuid)'::regprocedure, 'app.ntf_booking_pre0900(uuid)'::regprocedure);

-- ================================================================ 11. cause d: no recovery email while staff collect the payment
alter function app.recovery_staff_handling(uuid, uuid, timestamptz) rename to recovery_staff_handling_pre0900;
create function app.recovery_staff_handling(p_renter uuid, p_booking uuid, p_since timestamptz) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.recovery_staff_handling_pre0900(p_renter, p_booking, p_since)
      or (p_booking is not null and (
            exists (select 1 from payment_requests q where q.booking_id = p_booking and q.status = 'open' and q.expires_at > now()
                       and (q.created_by is not null or q.channel in ('text', 'email', 'link', 'device', 'reader')))
         or exists (select 1 from payments y where y.booking_id = p_booking and y.status in ('pending', 'requires_action', 'authorized')
                       and y.created_at > now() - interval '2 days')))
$$;
select pg_temp.copy_grants('app.recovery_staff_handling(uuid, uuid, timestamptz)'::regprocedure, 'app.recovery_staff_handling_pre0900(uuid, uuid, timestamptz)'::regprocedure);

-- ================================================================ 12. cause e: each pay link email says what it is for
select pg_temp.patch_fn('app.payreq_send(uuid, jsonb)'::regprocedure,
  E'perform app.staff_send_message(p_by, b.id, ''Payment for booking '' || b.booking_number,',
  E'perform app.staff_send_message(p_by, b.id, case q.kind when ''hold'' then ''Deposit hold for booking '' when ''setup'' then ''Save your card for booking '' else ''Payment for booking '' end || b.booking_number,');

-- ================================================================ 13. cause f: the cancelled invoices' list
alter function app.notification_payload_pre0827(text, app_events, jsonb) rename to notification_payload_pre0900;
create function app.notification_payload_pre0827(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.notification_payload_pre0900(p_code, p_event, p_to);
begin
  if p_code = 'owner_invoice_voided' then
    x := app.owner_void_payload(x || jsonb_build_object('invoices', jsonb_build_array(jsonb_build_object(
      'invoice_number', coalesce(x ->> 'invoice_number', ''), 'invoice_total', coalesce(x ->> 'invoice_total', ''), 'vehicle_name', coalesce(x ->> 'vehicle_name', ''),
      'void_reason', coalesce(x ->> 'void_reason', ''), 'replacement_number', coalesce(x ->> 'replacement_number', '')))));
  end if;
  return x;
end $$;
select pg_temp.copy_grants('app.notification_payload_pre0827(text, app_events, jsonb)'::regprocedure, 'app.notification_payload_pre0900(text, app_events, jsonb)'::regprocedure);

-- the texts follow the emails' words (an Admin's own wording is kept)
update sms_templates set body = 'CarmaCars: {{voided_title}}. Details: {{link}}'
 where code = 'owner_invoice_voided' and body = 'CarmaCars: invoice {{invoice_number}} is cancelled. Details: {{link}}';
update sms_templates set body = 'CarmaCars: booking {{booking_number}}: {{needed_title}} by {{verify_by}}: {{link}}'
 where code = 'renter_identity_needed' and body = 'CarmaCars: upload your licence and proof of coverage for booking {{booking_number}} by {{verify_by}}: {{link}}';

-- ================================================================ 14. cause g: no "your car is live" for a partner's car or to nobody
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0900;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_c.code = 'owner_vehicle_listed' then
    if exists (select 1 from vehicles v where v.id = p_event.entity_id and v.supply_type = 'partner') then return; end if;
    return query select * from app.notification_recipients_pre0900(p_event, p_c) r
                  where nullif(btrim(coalesce(r.email, '')), '') is not null or r.user_id is not null;
    return;
  end if;
  return query select * from app.notification_recipients_pre0900(p_event, p_c);
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure, 'app.notification_recipients_pre0900(app_events, notification_catalogue)'::regprocedure);

select pg_temp.patch_fn('app.publish_listing(uuid, uuid)'::regprocedure,
  E'if v.status <> ''onboarding'' and not exists (select 1 from app_events e where e.code = ''owner_vehicle_listed''',
  E'if v.status <> ''onboarding'' and v.supply_type <> ''partner'' and not exists (select 1 from app_events e where e.code = ''owner_vehicle_listed''');
select pg_temp.patch_fn('app.vehicle_status_listing_after()'::regprocedure,
  E'if l.status = ''published'' then\n      perform app.emit_event(''owner_vehicle_listed''',
  E'if l.status = ''published'' and new.supply_type <> ''partner'' then\n      perform app.emit_event(''owner_vehicle_listed''');

-- ================================================================ 15. Cloudflare Email Service: detected from its recorded sends
-- A success the sender recorded counts, not only the outbox rows still on file.
create or replace function app.cf_email_ever_sent() returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from email_provider_state e where e.cf_ok_at is not null)
      or exists (select 1 from notification_outbox o where o.status in ('sent', 'merged') and o.provider_id like 'cf:%')
$$;

-- ok after a success, unless Cloudflare refused in the last 15 minutes (it rests) or the Worker has no binding
select pg_temp.patch_fn('app.cf_email_setup(timestamptz)'::regprocedure,
  E'when e.cf_ok_at is not null and e.cf_ok_at > p_now - interval ''1 day'' and (e.cf_failed_at is null or e.cf_failed_at < e.cf_ok_at) then ''ok''',
  E'when e.cf_ok_at is not null and (e.cf_failed_at is null or e.cf_failed_at < e.cf_ok_at\n                                         or (e.cf_failed_at < p_now - interval ''15 minutes'' and coalesce(e.cf_error, '''') not ilike ''%binding%'')) then ''ok''');

-- the day's cap: Cloudflare's budget plus Resend's whenever Cloudflare is on and works
create or replace function app.email_day_cap(p_now timestamptz default now()) returns integer
language sql stable security definer set search_path = public, app as $$
  -- the setting as the Admin wrote it (app.settings lowers notify_daily_cap to Resend's own plan, which is Resend's alone)
  select greatest(0, least(s.notify_daily_cap,
           (case when coalesce(s.cf_email_enabled, false) and app.cf_email_ever_sent()
                      and coalesce((app.cf_email_setup(p_now)) ->> 'state', '') <> 'absent' then s.notify_cf_daily_budget else 0 end)
           + s.notify_resend_daily_budget))::integer
    from app.settings_base(app.local_date(p_now)) s
$$;

-- The pace read carries Cloudflare's state, so every page words the limit the same way.
alter function app.email_pace(timestamptz) rename to email_pace_pre0900;
create function app.email_pace(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.email_pace_pre0900(p_now) || jsonb_build_object('cf_state', coalesce(app.cf_email_setup(p_now) ->> 'state', 'absent'),
           'cf_counted', coalesce((app.cf_email_setup(p_now) ->> 'state') = 'ok', false) or (coalesce(s.cf_email_enabled, false) and app.cf_email_ever_sent()
                          and coalesce(app.cf_email_setup(p_now) ->> 'state', '') <> 'absent'))
    from app.settings_base(app.local_date(p_now)) s
$$;
select pg_temp.copy_grants('app.email_pace(timestamptz)'::regprocedure, 'app.email_pace_pre0900(timestamptz)'::regprocedure);

-- the booking page's email box: today's emails against the same cap, with why it is that number
alter function app.booking_conversation(uuid, jsonb) rename to booking_conversation_pre0900;
create function app.booking_conversation(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.booking_conversation_pre0900(p_by, p);
  pc jsonb;
begin
  if x is null or not (x ? 'usage') then return x; end if;
  pc := app.email_pace(now());
  return jsonb_set(x, '{usage}', (x -> 'usage') || jsonb_build_object('total', (pc ->> 'day_used')::integer, 'cap', (pc ->> 'day_cap')::integer,
    'cf_state', pc ->> 'cf_state', 'cf_counted', (pc ->> 'cf_counted')::boolean, 'cf_budget', (pc ->> 'cf_budget')::integer, 'resend_budget', (pc ->> 'resend_budget')::integer));
end $$;
select pg_temp.copy_grants('app.booking_conversation(uuid, jsonb)'::regprocedure, 'app.booking_conversation_pre0900(uuid, jsonb)'::regprocedure);

-- ================================================================ 16. the catalogue rows of the emails whose words changed
-- CATALOGUE 0900 START (generated by supabase/seed/0900_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_invoice_voided', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', '{{voided_title}}', '{{voided_preheader}}', 'Within 30 minutes, one email per owner per day', 'An Admin voids an issued owner invoice with a reason (nothing was paid on it). Its scheduled debit is cancelled. When a corrected invoice replaces it, that invoice has its own email once it is issued. One email per owner per day (migration 0900): the email waits a short while (Program settings, 30 minutes by default) and every invoice voided for the same owner meanwhile is listed in it; once the day''s email went, the next voids wait for the next morning''s email.', null, '/owner/invoices', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_replacement","type":"boolean"},{"name":"has_several","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"invoice_total","type":"string"},{"name":"invoices","type":"list","fields":["invoice_number","invoice_total","vehicle_name","void_reason","replacement_number"]},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"replacement_number","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"void_reason","type":"string"},{"name":"voided_heading","type":"string"},{"name":"voided_lead","type":"string"},{"name":"voided_preheader","type":"string"},{"name":"voided_ref","type":"string"},{"name":"voided_title","type":"string"}]'::jsonb, 'templates/owner_invoice_voided.html', 'templates/owner_invoice_voided.txt'),
  ('owner_vehicle_listed', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Your {{vehicle_name}} is live and open for bookings', 'Approved and listed on carmacars.ca. Check the rates and block any dates you need.', 'Immediate', 'Vehicle status changes from ready_to_list to available and its listing is published (staff approved the listing). Never for a partner''s car (a partner fleet such as 01 Motors, imported with its photos) and never queued without an owner address to send to (migration 0900).', null, '/owner/vehicles/{{vehicle_id}}/calendar', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"daily_rate","type":"string"},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"km_per_day","type":"string"},{"name":"monthly_rate","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payout_day","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"weekend_rate","type":"string"},{"name":"weekly_rate","type":"string"}]'::jsonb, 'templates/owner_vehicle_listed.html', 'templates/owner_vehicle_listed.txt'),
  ('renter_booking_confirmed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Confirmed: {{vehicle_name}}, {{pickup_date}}', 'Booking {{booking_number}}. {{amount_paid}} paid. Next: licence and coverage check.', 'Immediate', 'Booking status changes from pending_payment to confirmed (the offer was approved, the agreement signed, the booking total paid and the car still free for the dates).', null, '/account/bookings/{{booking_number}}/verify', '[{"name":"amount_paid","type":"string"},{"name":"booking_number","type":"string"},{"name":"calendar_url","type":"url"},{"name":"card_brand","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_non_refundable","type":"boolean"},{"name":"km_allowance","type":"string"},{"name":"line_items","type":"list","fields":["label","amount"]},{"name":"needed_line","type":"string"},{"name":"needs_verification","type":"boolean"},{"name":"non_refundable_percent","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"overage_rate","type":"string"},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"receipt_number","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_place","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_image_url","type":"url"},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_booking_confirmed.html', 'templates/renter_booking_confirmed.txt'),
  ('renter_booking_reminder', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'Tomorrow: your {{vehicle_name}} at {{pickup_time}}', 'Bring your original licence and the card ending {{card_last4}}.', '24 hours before pickup', 'Reminders job (every 5 minutes): booking status is confirmed and the pickup time is 24 hours away. Sent once per pickup time. Not sent when the pickup is already inside the 2 hours of renter_pickup_soon (migration 0430), nor when the booking confirmation, which gives the date and time, went out within the reminder gap before this reminder would be due (Program settings, 12 hours by default, migration 0900). (Message template T5.)', 'T5', '/account/bookings/{{booking_number}}/verify', '[{"name":"booking_number","type":"string"},{"name":"card_last4","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"deposit_amount","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"missing_items","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_place","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"verification_pending","type":"boolean"}]'::jsonb, 'templates/renter_booking_reminder.html', 'templates/renter_booking_reminder.txt'),
  ('renter_identity_needed', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', '{{needed_title}} for {{pickup_date}}', 'We need them by {{verify_by}}. No car is released without them.', '48 hours before pickup if still missing', 'Reminders job: 48 hours before pickup, a confirmed booking still needs something the renter sends (a driver''s licence photos or selfie not uploaded or rejected, or the proof of coverage not sent). Nothing is sent for what is already uploaded and waiting for our review, nor when the confirmation that already listed it went out within the reminder gap (Program settings, 12 hours by default, migration 0900). The subject and the copy name only what is missing.', null, '/account/bookings/{{booking_number}}/verify', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"coverage_for_sale","type":"boolean"},{"name":"first_name","type":"string"},{"name":"id_retention_days","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"min_renter_age","type":"string"},{"name":"needed_items","type":"string"},{"name":"needed_title","type":"string"},{"name":"needs_coverage","type":"boolean"},{"name":"needs_licence","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"verify_by","type":"string"}]'::jsonb, 'templates/renter_identity_needed.html', 'templates/renter_identity_needed.txt'),
  ('renter_recovery_pay', 'renter', '{}'::text[], 'transactional', false, null, 'CarmaCars <bookings@carmacars.ca>', 'bookings@carmacars.ca', 'One step left to book the {{vehicle_name}}', 'Your card is not charged until you finish. Need help? Reply to this email.', 'An hour after the pay page was left', 'Booking recovery job (every 15 minutes): the renter left the pay page of their approved booking (pending_payment) without paying, recovery_pay_minutes ago (Program settings, 60 by default). At most recovery_max_emails (2), the second after recovery_second_hours (24). Not sent outside the hours set for these emails, to a renter who unsubscribed or turned these reminders off, while a staff member is already handling the renter, while a pay link staff sent is still open, or while a payment is pending (migration 0900). Stops once they pay or the booking leaves pending_payment.', null, '/account/bookings/{{booking_number}}/pay', '[{"name":"booking_number","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"pickup_date","type":"string"},{"name":"pickup_time","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"return_date","type":"string"},{"name":"return_time","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"total_amount","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/renter_recovery_pay.html', 'templates/renter_recovery_pay.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0900 END

update notification_catalogue set emitted_by = 'app.notify_reminders (0023, 0900: only what is missing)' where code = 'renter_identity_needed';

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['outbox_repeat_guard', 'owner_void_payload', 'outbox_merge_hold', 'words_and',
              'outbox_merge_parts', 'outbox_merge_release', 'outbox_merge_detach', 'phone_ref', 'phone_repeat_guard', 'sms_merge_body', 'phone_merge_hold',
              'notification_repeat_guard', 'ntf_confirmation_covers', 'renter_todo', 'renter_todo_any',
              'outbox_mark_sent_pre0900', 'outbox_mark_failed_pre0900', 'outbox_claim_pre0900', 'agreement_changes_pre0900', 'ntf_booking_pre0900',
              'recovery_staff_handling_pre0900', 'notification_payload_pre0900', 'notification_recipients_pre0900', 'email_pace_pre0900',
              'booking_conversation_pre0900'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
