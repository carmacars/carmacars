-- 0135_owner_terms_per_car.sql
-- Owner terms per car, made easy (docs/changes/2026-10-24-owner-terms-per-car.md). The owner, October 24, 2026: "when a
-- car owner applies or they're registered, is there an easy way to set the percentage for host management fee and set
-- their monthly insurance amount per car?"
--
-- 1. Records: a lower amount is its own kind of change ('decrease', fee history source 'owner_benefit'); every change made
--    from the terms editor carries the edit it belongs to (edit_id) and its written notice.
-- 2. app.car_terms_change: one call per car, from the owner page's table, the vehicle page and the review that comes
--    before it (preview). Before the Vehicle Schedule is signed the numbers apply at once (0067's owner_terms_save, and
--    0022's set_vehicle_terms for the Management Mode and Onboarding Method while the terms are open). Once signed,
--    field by field against the terms in force:
--      lower (Insurance Fee, Tracker Fee, management fee): from today or a chosen date, no notice period (it only lowers
--        what the owner pays); the owner gets the written notice. A car not enrolled yet gets an updated Vehicle Schedule
--        at once instead (enrollment opens its terms from the schedule).
--      higher fees: written notice (Enrollment Agreement 4.8, Program settings fee_change_notice_days, 30), in force from
--        the date given.
--      higher management fee (Revenue Share): the same notice, and an updated Vehicle Schedule the owner signs (4.8: "a
--        Revenue Share changes only in writing signed by both parties"), through 0067's signing and countersigning; in
--        force from the date given once signed, or from the day it is signed when that is later.
--    The Install Fee, Management Mode and Onboarding Method are fixed by the signed schedule.
-- 3. app.car_terms_cancel: a change that has not started yet is cancelled (its dated terms removed); an updated schedule
--    waiting for a signature is withdrawn as before.
-- 4. Reads: app.car_terms_read (Admin: every car of an owner, or one car: the terms, from when, what is scheduled, every
--    period and every change) and app.owner_car_terms (the owner portal: the same for their cars, with the notices).
--    The owner portal's vehicles show the terms in force (fee history), not only the signed schedule's.
-- 5. The written notice as a document (/files/terms_notice/<change>) and its email (owner_fee_change_notice: the
--    management fee and lower amounts too).
-- 6. Billing by effective date: a month whose terms change part way is billed per day at each rate (the monthly owner
--    invoice used the rate of the billing day for the whole month). The Revenue Share of a rental stays the one in force
--    the day it is booked, stored on the booking (0011, 0016; a confirmed booking's split never changes).

-- ================================================================ 1. records
alter table vehicle_fee_history drop constraint if exists vehicle_fee_history_source_check;
alter table vehicle_fee_history add constraint vehicle_fee_history_source_check
  check (source in ('signed_schedule', 'fee_notice', 'shareholder', 'correction', 'owner_benefit'));
alter table vehicle_term_changes drop constraint if exists vehicle_term_changes_kind_check;
alter table vehicle_term_changes add constraint vehicle_term_changes_kind_check check (kind in ('fee_notice', 'new_schedule', 'decrease'));
alter table vehicle_term_changes add column if not exists edit_id uuid;
comment on column vehicle_term_changes.edit_id is 'The terms edit this change belongs to (0135): one edit can lower some amounts at once and raise others by notice';
alter table program_settings add column if not exists owner_lower_share_without_signature boolean not null default true;
comment on column program_settings.owner_lower_share_without_signature is 'Lower management % without owner signature (0135): on, a lower Revenue Share on a signed car applies from its date by CarmaCars'' written notice; off, the owner signs an updated Vehicle Schedule first (Enrollment Agreement 4.8)';
comment on column vehicle_fee_history.source is 'signed_schedule, fee_notice (30 days'' written notice), owner_benefit (a lower amount, in force from its date without a notice period, 0135), shareholder, correction';

-- ================================================================ 2. helpers
create or replace function app.ct_label(p_field text) returns text
language sql immutable as $$
  select case p_field when 'insurance_fee_cents' then 'Insurance Fee, monthly, before HST' when 'tracker_fee_cents' then 'Tracker Fee, monthly, before HST'
                      when 'revenue_share_bps' then 'Management fee (Revenue Share)' when 'install_fee_cents' then 'Install Fee, once' else p_field end
$$;
create or replace function app.ct_fmt(p_field text, p_value bigint) returns text
language sql immutable as $$
  select case when p_value is null then '' when p_field = 'revenue_share_bps' then trim(to_char(p_value / 100.0, 'FM990.99')) || '%' else app.fmt_money(p_value) end
$$;
create or replace function app.ct_int(p jsonb, k text) returns bigint
language plpgsql immutable as $$
begin
  if p is null or not (p ? k) or jsonb_typeof(p -> k) = 'null' or btrim(p ->> k) = '' then return null; end if;
  if (p ->> k) !~ '^\d{1,9}$' then raise exception '%: a whole number of cents (or basis points) of 0 or more', app.ct_label(k) using errcode = '22023'; end if;
  return (p ->> k)::bigint;
end $$;

-- CarmaCars' signature line on a notice or an updated schedule it issues (the standing authorization of 0053).
create or replace function app.ct_company_signature() returns text
language sql stable security definer set search_path = public, app as $$
  select format('Signed electronically for %s by %s, %s, under a standing authorization dated %s.', app.owner_payee_name(),
                coalesce(ps.signing_officer_name, 'its signing officer'), coalesce(ps.signing_officer_title, 'Director'),
                coalesce(app.fmt_day(ps.signing_officer_authorized_on), 'on file'))
    from app.settings() ps
$$;

-- The terms of a car as they stand: state (not_set: no Vehicle Schedule yet; pending: a schedule not signed yet; signed;
-- fixed: a shareholder, company or partner car), the values, since when, and whether billing has started (enrolled).
create or replace function app.ct_now(p_vehicle uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  s vehicle_schedules;
  h vehicle_fee_history;
  r jsonb;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return null; end if;
  if v.supply_type <> 'program_owner' or v.is_shareholder_owned then
    h := app.vehicle_terms(p_vehicle, app.today());
    return jsonb_build_object('state', 'fixed', 'enrolled', h.effective_from is not null, 'since', h.effective_from,
      'insurance_fee_cents', coalesce(h.insurance_fee_cents, 0), 'tracker_fee_cents', coalesce(h.tracker_fee_cents, 0),
      'revenue_share_bps', h.revenue_share_bps, 'install_fee_cents', 0);
  end if;
  select * into s from vehicle_schedules where vehicle_id = p_vehicle and superseded_by is null;
  select * into h from vehicle_fee_history where vehicle_id = p_vehicle and effective_from <= app.today() and (effective_to is null or effective_to > app.today());
  if s.id is not null and s.signed_at is not null then
    return jsonb_build_object('state', 'signed', 'enrolled', h.id is not null, 'since', h.effective_from,
      'insurance_fee_cents', coalesce(h.insurance_fee_cents, s.insurance_fee_cents), 'tracker_fee_cents', coalesce(h.tracker_fee_cents, s.tracker_fee_cents),
      'revenue_share_bps', coalesce(h.revenue_share_bps, s.revenue_share_bps), 'install_fee_cents', s.install_fee_cents,
      'schedule_id', s.id, 'schedule_number', s.schedule_number, 'signed_at', s.signed_at, 'management_mode', s.management_mode, 'onboarding_method', s.onboarding_method);
  end if;
  if s.id is not null then
    return jsonb_build_object('state', 'pending', 'enrolled', false, 'since', null,
      'insurance_fee_cents', s.insurance_fee_cents, 'tracker_fee_cents', s.tracker_fee_cents, 'revenue_share_bps', s.revenue_share_bps,
      'install_fee_cents', s.install_fee_cents, 'schedule_id', s.id, 'schedule_number', s.schedule_number, 'signed_at', null,
      'management_mode', s.management_mode, 'onboarding_method', s.onboarding_method);
  end if;
  r := app.owner_terms_resolve(p_vehicle);
  return jsonb_build_object('state', 'not_set', 'enrolled', false, 'since', null,
    'insurance_fee_cents', (r ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (r ->> 'tracker_fee_cents')::bigint,
    'revenue_share_bps', (r ->> 'revenue_share_bps')::integer, 'install_fee_cents', (r ->> 'install_fee_cents')::bigint,
    'sources', r -> 'sources', 'management_mode', r ->> 'management_mode',
    'onboarding_method', (select ob.proposed_onboarding_method from vehicle_onboardings ob where ob.vehicle_id = p_vehicle));
end $$;

-- ================================================================ 3. the written notice: email and document
-- One notice per part of an edit: the lower amounts (from their date) or the higher ones (from the notice date).
create or replace function app.ct_notice(p_change uuid, p_fields text[], p_decrease boolean, p_share boolean) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  v vehicles;
  f text;
  v_lines jsonb := '[]'::jsonb;
  v_new jsonb;
begin
  select * into c from vehicle_term_changes where id = p_change;
  select * into v from vehicles where id = c.vehicle_id;
  v_new := jsonb_build_object('insurance_fee_cents', c.insurance_fee_cents, 'tracker_fee_cents', c.tracker_fee_cents, 'revenue_share_bps', c.revenue_share_bps);
  foreach f in array p_fields loop
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', app.ct_label(f), 'before', app.ct_fmt(f, (c.previous ->> f)::bigint), 'after', app.ct_fmt(f, (v_new ->> f)::bigint)));
  end loop;
  perform app.emit_event('owner_fee_change_notice', 'vehicle_term_change', c.id,
    jsonb_build_object('owner_id', v.owner_id, 'vehicle_id', v.id, 'vehicle_name', app.vehicle_name(v.id), 'effective_from', c.effective_from,
      'old_insurance_fee_cents', (c.previous ->> 'insurance_fee_cents')::bigint, 'new_insurance_fee_cents', c.insurance_fee_cents,
      'old_tracker_fee_cents', (c.previous ->> 'tracker_fee_cents')::bigint, 'new_tracker_fee_cents', c.tracker_fee_cents,
      'reason', c.reason, 'changes', v_lines, 'is_decrease', p_decrease, 'is_share_change', p_share,
      'summary', (select string_agg((x ->> 'label') || ' ' || (x ->> 'before') || ' to ' || (x ->> 'after'), '; ') from jsonb_array_elements(v_lines) x)
                 || ', from ' || app.fmt_day(c.effective_from)),
    'owner_fee_change_notice:' || c.id || ':notice');
end $$;

-- The email's values for a notice of 0135 (the lines, lower amounts, the management fee); any older notice keeps its own.
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre0135;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre0135(p_code, p_event, p_to);
  p jsonb := coalesce(p_event.payload, '{}'::jsonb);
begin
  if p_code = 'owner_fee_change_notice' then
    x := coalesce(x, '{}'::jsonb) || jsonb_build_object('is_decrease', coalesce((p ->> 'is_decrease')::boolean, false));
    if jsonb_typeof(p -> 'changes') = 'array' then
      x := x || jsonb_build_object('fee_changes', p -> 'changes', 'fee_change_summary', coalesce(p ->> 'summary', x ->> 'fee_change_summary'),
                                   'is_share_change', coalesce((p ->> 'is_share_change')::boolean, false),
                                   'notice_days', greatest(0, (p ->> 'effective_from')::date - app.local_date(p_event.created_at))::text,
                                   'fee_change_reason', coalesce(nullif(p ->> 'reason', ''), case when coalesce((p ->> 'is_decrease')::boolean, false)
                                                                  then 'We lowered these amounts for this car.' else '' end));
    end if;
  end if;
  return x;
end $$;

-- The notice as a document: /files/terms_notice/<change id>. The owner downloads their own; Admins and Finance any.
alter function app.file_access(uuid, text, text) rename to file_access_pre0135;
create or replace function app.file_access(p_user uuid, p_kind text, p_key text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_kind = 'terms_notice' then
    return p_user is not null and (app.user_is_admin(p_user) or app.user_runs_finance(p_user)
      or exists (select 1 from vehicle_term_changes c join vehicles v on v.id = c.vehicle_id join owners o on o.id = v.owner_id
                  where c.id = app.file_key_id(p_key) and o.user_id = p_user));
  end if;
  return app.file_access_pre0135(p_user, p_kind, p_key);
end $$;

create or replace function app.ct_notice_text(c vehicle_term_changes) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_days integer := (app.settings(coalesce(c.notice_sent_on, app.local_date(c.created_at)))).fee_change_notice_days;
  v_out text[];
begin
  if c.kind = 'decrease' then
    v_out := array[
      'This is written notice that CarmaCars lowers the amounts below for this Vehicle, from ' || app.fmt_day(c.effective_from) || '.',
      'A lower amount needs no notice period: it only lowers what the Owner pays or what CarmaCars keeps. Everything else in the Enrollment Agreement and the Vehicle Schedule stays the same.',
      'Monthly invoices for days from that date use the lower amounts. The Revenue Share of a rental is the one in force on the day the rental is booked.'];
  elsif c.kind = 'fee_notice' then
    v_out := array[
      'This is written notice under section 4.8 of the Enrollment Agreement that the Fees below change for this Vehicle from ' || app.fmt_day(c.effective_from) || ', '
        || (c.effective_from - coalesce(c.notice_sent_on, app.local_date(c.created_at))) || ' days after this notice (the Notice Period is ' || v_days || ' days).',
      'The Owner may instead take the Vehicle out of the program by written notice of the Notice Period (section 12.1).',
      'Monthly invoices for days from that date use the new amounts.'];
  else
    v_out := array[
      'This is written notice that CarmaCars proposes the terms below for this Vehicle, from ' || app.fmt_day(c.effective_from) || '.',
      'A Revenue Share changes only in writing signed by both parties (section 4.8 of the Enrollment Agreement): the change applies only once the Owner signs the updated Vehicle Schedule, from the date above or the day it is signed, whichever is later. Until then the current terms stay in place.',
      'The Owner may instead take the Vehicle out of the program by written notice of the Notice Period (section 12.1).'];
  end if;
  return to_jsonb(v_out);
end $$;

alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre0135;
create or replace function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  v vehicles;
  o owners;
  f text;
  v_lines jsonb := '[]'::jsonb;
  v_new jsonb;
begin
  if p_kind <> 'terms_notice' then return app.pdf_facts_pre0135(p_kind, p_key, p_user); end if;
  select * into c from vehicle_term_changes where id = app.file_key_id(p_key);
  if c.id is null then return null; end if;
  select * into v from vehicles where id = c.vehicle_id;
  select * into o from owners where id = v.owner_id;
  v_new := jsonb_build_object('insurance_fee_cents', c.insurance_fee_cents, 'tracker_fee_cents', c.tracker_fee_cents, 'revenue_share_bps', c.revenue_share_bps,
                              'install_fee_cents', c.install_fee_cents);
  foreach f in array array['insurance_fee_cents', 'tracker_fee_cents', 'revenue_share_bps'] loop
    if (c.previous ->> f) is distinct from (v_new ->> f) then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object('label', app.ct_label(f), 'before', app.ct_fmt(f, (c.previous ->> f)::bigint), 'after', app.ct_fmt(f, (v_new ->> f)::bigint)));
    end if;
  end loop;
  return jsonb_build_object('final', true, 'store', false,
    'title', case c.kind when 'decrease' then 'Notice of lower terms' else 'Notice of a change to terms' end,
    'file_name', 'carmacars-terms-notice-' || to_char(coalesce(c.notice_sent_on, app.local_date(c.created_at)), 'YYYY-MM-DD') || '-' || left(c.id::text, 8) || '.pdf',
    'issued_at', c.created_at, 'notice_on', coalesce(c.notice_sent_on, app.local_date(c.created_at)), 'effective_from', c.effective_from,
    'kind', c.kind, 'status', c.status, 'cancelled_reason', c.cancelled_reason,
    'vehicle', app.vehicle_name(v.id), 'plate', v.plate, 'vin', upper(v.vin),
    'schedule_number', coalesce(c.previous ->> 'schedule_number', (select s.schedule_number from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null)),
    'owner', jsonb_build_object('legal_name', o.legal_name, 'address', concat_ws(', ', o.address_line1, o.address_line2, o.city, o.province, o.postal_code)),
    'lines', v_lines, 'reason', c.reason, 'paragraphs', app.ct_notice_text(c),
    'signature', coalesce(c.countersignature, app.ct_company_signature()),
    'owner_signed', case when c.owner_signed_at is not null then format('Signed by %s on %s (%s).', coalesce(c.owner_signed_name, o.legal_name), app.fmt_date(c.owner_signed_at),
                                                                         case c.signed_method when 'paper' then 'on paper' else 'in the owner portal' end) end,
    'payee', app.owner_payee_name(), 'company', app.doc_company());
end $$;

-- ================================================================ 4. an updated schedule of 0135 signed late applies from the day it is signed
-- A change of the terms editor proposed from a date already passed when the owner signs takes effect that day: a
-- Revenue Share is never back-dated. Dated terms of another change starting the same day (a notice of higher Fees, or
-- lower amounts) give way to the signed schedule, which carries the same Fees.
alter function app.ot_schedule_change_apply(uuid, uuid, timestamptz, uuid) rename to ot_schedule_change_apply_pre0135;
create or replace function app.ot_schedule_change_apply(p_change uuid, p_by uuid, p_signed_at timestamptz, p_document uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  v_on date;
begin
  select * into c from vehicle_term_changes where id = p_change for update;
  if c.id is not null and c.edit_id is not null and c.status = 'awaiting_signature' and c.kind = 'new_schedule' then
    v_on := greatest(c.effective_from, app.local_date(coalesce(p_signed_at, now())));
    if v_on <> c.effective_from then update vehicle_term_changes set effective_from = v_on where id = c.id; end if;
    update vehicle_term_changes x set fee_history_id = null, status = case when x.status = 'noticed' then 'applied' else x.status end,
           applied_at = coalesce(x.applied_at, now())
     where x.vehicle_id = c.vehicle_id and x.kind in ('fee_notice', 'decrease') and x.id <> c.id
       and x.fee_history_id in (select h.id from vehicle_fee_history h where h.vehicle_id = c.vehicle_id and h.effective_from = v_on);
  end if;
  return app.ot_schedule_change_apply_pre0135(p_change, p_by, p_signed_at, p_document);
end $$;

-- ================================================================ 5. change the terms of one car
-- p: {vehicle_id, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, management_mode,
--     onboarding_method, lower_from, raise_from, reason, preview}. A value left out keeps the current one.
-- preview: what would happen, nothing written. Returns {state, fields: [{field, label, before, after, direction}],
-- steps: [text], lower_from, raise_from, earliest_raise, blocked, done}.
create or replace function app.car_terms_change(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  s vehicle_schedules;
  ob vehicle_onboardings;
  cur vehicle_fee_history;
  st jsonb;
  b jsonb;
  n jsonb := '{}'::jsonb;
  f text;
  v_val bigint;
  v_today date := app.today();
  v_preview boolean := coalesce((p ->> 'preview')::boolean, false);
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_days integer := (app.settings()).fee_change_notice_days;
  v_lower date;
  v_raise date;
  v_down text[] := '{}';
  v_up text[] := '{}';
  v_fields jsonb := '[]'::jsonb;
  v_steps text[] := '{}';
  v_mode management_mode;
  v_method onboarding_method;
  v_cur_mode management_mode;
  v_cur_method onboarding_method;
  v_mode_changed boolean := false;
  v_enrolled boolean;
  v_edit uuid := gen_random_uuid();
  v_hist uuid;
  v_change uuid;
  v_ids uuid[] := '{}';
  v_vals jsonb;
  v_share_at bigint;
  v_fee_up boolean;
  v_share_up boolean;
  v_next date;
  v_t jsonb;
  ct owner_terms;
  v_res jsonb;
  v_lbl text;
  v_block text;
  v_sign_share boolean := false;
  v_sign_from date;
begin
  perform app.assert_admin(p_by);
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid for update;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v.supply_type <> 'program_owner' then raise exception 'A % car has no owner terms', lower(app.supply_label(v.supply_type)) using errcode = '23514'; end if;
  if v.is_shareholder_owned then raise exception 'A shareholder-owned car has fixed terms: 90/10 and no Fees' using errcode = '23514'; end if;
  if v.status in ('declined', 'exited', 'total_loss') then raise exception 'This car is no longer in the program' using errcode = '23514'; end if;
  select * into s from vehicle_schedules where vehicle_id = v.id and superseded_by is null;
  select * into ob from vehicle_onboardings where vehicle_id = v.id;
  st := app.ct_now(v.id);
  b := st;
  foreach f in array array['insurance_fee_cents', 'tracker_fee_cents', 'revenue_share_bps', 'install_fee_cents'] loop
    v_val := coalesce(app.ct_int(p, f), (b ->> f)::bigint);
    if f = 'revenue_share_bps' and v_val > 10000 then raise exception 'The management fee (Revenue Share) is between 0%% and 100%%' using errcode = '22023'; end if;
    n := n || jsonb_build_object(f, v_val);
  end loop;
  v_cur_mode := coalesce((st ->> 'management_mode')::management_mode, ob.proposed_management_mode, v.management_mode, 'managed');
  v_cur_method := coalesce(nullif(st ->> 'onboarding_method', '')::onboarding_method, ob.proposed_onboarding_method, v.onboarding_method);
  v_mode := coalesce(nullif(p ->> 'management_mode', '')::management_mode, v_cur_mode);
  v_method := coalesce(nullif(p ->> 'onboarding_method', '')::onboarding_method, case when v_mode = 'turo_only' then 'none'::onboarding_method end, v_cur_method);
  if v_mode <> 'turo_only' and v_method = 'none' then v_method := null; end if;
  v_mode_changed := v_mode is distinct from v_cur_mode or v_method is distinct from v_cur_method;
  -- the mode decides what can apply at all (Enrollment Agreement 6)
  if v_mode = 'self_managed' and (n ->> 'revenue_share_bps')::integer <> 0 then
    if app.ct_int(p, 'revenue_share_bps') is null and v_mode_changed then n := n || '{"revenue_share_bps": 0}';
    else raise exception 'A Self-Managed car has no management fee (Revenue Share): the owner is paid 100%% of Owner Revenue' using errcode = '23514'; end if;
  end if;
  if v_mode = 'turo_only' and ((n ->> 'insurance_fee_cents')::bigint, (n ->> 'tracker_fee_cents')::bigint, (n ->> 'install_fee_cents')::bigint) is distinct from (0::bigint, 0::bigint, 0::bigint) then
    if v_mode_changed and app.ct_int(p, 'insurance_fee_cents') is null then n := n || '{"insurance_fee_cents": 0, "tracker_fee_cents": 0, "install_fee_cents": 0}';
    else raise exception 'A Turo-Only car has no Fees and no Tracker' using errcode = '23514'; end if;
  end if;
  foreach f in array array['insurance_fee_cents', 'tracker_fee_cents', 'revenue_share_bps', 'install_fee_cents'] loop
    if (n ->> f)::bigint is distinct from (b ->> f)::bigint then
      v_fields := v_fields || jsonb_build_array(jsonb_build_object('field', f, 'label', app.ct_label(f), 'before', (b ->> f)::bigint, 'after', (n ->> f)::bigint,
        'before_text', app.ct_fmt(f, (b ->> f)::bigint), 'after_text', app.ct_fmt(f, (n ->> f)::bigint),
        'direction', case when (n ->> f)::bigint < (b ->> f)::bigint then 'lower' else 'higher' end));
      if f <> 'install_fee_cents' then
        if (n ->> f)::bigint < (b ->> f)::bigint then v_down := v_down || f; else v_up := v_up || f; end if;
      end if;
    end if;
  end loop;
  if v_mode_changed then
    v_fields := v_fields || jsonb_build_array(jsonb_build_object('field', 'management_mode', 'label', 'Management Mode and Onboarding Method',
      'before_text', initcap(replace(v_cur_mode::text, '_', '-')) || coalesce(', ' || replace(v_cur_method::text, '_', ' '), ''),
      'after_text', initcap(replace(v_mode::text, '_', '-')) || coalesce(', ' || replace(v_method::text, '_', ' '), ''), 'direction', 'other'));
  end if;
  if jsonb_array_length(v_fields) = 0 then
    if v_preview then return jsonb_build_object('state', st ->> 'state', 'fields', v_fields, 'steps', '[]'::jsonb, 'blocked', 'Nothing changed.', 'done', false); end if;
    raise exception 'These are the terms already in place' using errcode = '22023';
  end if;

  -- ---------------------------------------------------------------- before the Vehicle Schedule is signed: the numbers apply at once
  if st ->> 'state' in ('not_set', 'pending') then
    if v_mode_changed and s.id is not null and ob.status not in ('intake', 'terms_set') then
      raise exception 'The documents are out for signature: the Management Mode and Onboarding Method are fixed now. Change them by withdrawing the car''s documents first' using errcode = '23514';
    end if;
    if v_mode_changed and v_method is null then raise exception 'Choose the Onboarding Method' using errcode = '22023'; end if;
    v_steps := v_steps || case when s.id is null
      then 'Kept for this car and used when you approve it (the Approve step starts from these numbers).'
      else 'Written into Vehicle Schedule ' || s.schedule_number || ', which is not signed yet: the documents are made again, so the owner signs these numbers.' end;
    if v_preview then
      return jsonb_build_object('state', st ->> 'state', 'fields', v_fields, 'steps', to_jsonb(v_steps), 'blocked', null, 'done', false);
    end if;
    if v_mode_changed then
      if ob.held_by is not null and ob.title_status is not null then
        perform app.onboarding_plan(ob.held_by, ob.title_status, v_mode, v_method, coalesce(ob.owners_lien_elected, false));
      end if;
      if s.id is not null then
        perform app.set_vehicle_terms(v.id, p_by, jsonb_build_object('management_mode', v_mode, 'onboarding_method', v_method,
          'insurance_fee_cents', (n ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (n ->> 'tracker_fee_cents')::bigint,
          'revenue_share_bps', (n ->> 'revenue_share_bps')::integer, 'install_fee_cents', (n ->> 'install_fee_cents')::bigint,
          'owners_lien', coalesce(ob.owners_lien_elected, false), 'special_terms', s.special_terms));
      elsif ob.id is not null then
        update vehicle_onboardings set proposed_management_mode = v_mode, proposed_onboarding_method = v_method where id = ob.id;
      end if;
    end if;
    -- the car's negotiated row (0067): every number explicit; its first and last month amount and one-off fees kept
    select * into ct from owner_terms x where x.vehicle_id = v.id and x.effective_from <= v_today and (x.effective_to is null or x.effective_to > v_today);
    v_res := app.owner_terms_save(p_by, jsonb_build_object('vehicle_id', v.id, 'effective_from', greatest(v_today, coalesce((select max(x.effective_from) from owner_terms x where x.vehicle_id = v.id), v_today)),
      'insurance_fee_cents', (n ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (n ->> 'tracker_fee_cents')::bigint,
      'revenue_share_bps', (n ->> 'revenue_share_bps')::integer, 'install_fee_cents', (n ->> 'install_fee_cents')::bigint,
      'first_last_cents', ct.first_last_cents, 'one_off_fees', coalesce(ct.one_off_fees, '[]'::jsonb), 'note', coalesce(v_reason, ct.note)));
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'car_terms_change', 'vehicles', v.id::text, jsonb_build_object('state', st ->> 'state', 'fields', v_fields));
    return jsonb_build_object('state', st ->> 'state', 'fields', v_fields, 'steps', to_jsonb(v_steps), 'done', true, 'note', v_res ->> 'note');
  end if;

  -- ---------------------------------------------------------------- signed
  if v_mode_changed then
    raise exception 'The Management Mode and Onboarding Method are on the signed Vehicle Schedule %. A new mode is a new Vehicle Schedule: take the car out and enrol it again, or ask us to add this', s.schedule_number using errcode = '23514';
  end if;
  if (n ->> 'install_fee_cents')::bigint is distinct from (b ->> 'install_fee_cents')::bigint then
    raise exception 'The Install Fee is charged once, before enrollment, and is on the signed Vehicle Schedule. To bill another amount, change the invoice (the owner''s Invoices tab)' using errcode = '23514';
  end if;
  select c.effective_from into v_next from vehicle_term_changes c where c.vehicle_id = v.id and c.status = 'awaiting_signature' order by c.created_at desc limit 1;
  if v_next is not null then
    raise exception 'An updated Vehicle Schedule (from %) is waiting for the owner''s signature. Record it signed or withdraw it first', app.fmt_day(v_next) using errcode = '23514';
  end if;
  select min(h.effective_from) into v_next from vehicle_fee_history h where h.vehicle_id = v.id and h.effective_from > v_today;
  if v_next is not null then
    raise exception 'A change already starts on %. Cancel it first (History), then make the new one', app.fmt_day(v_next) using errcode = '23514';
  end if;
  v_enrolled := coalesce((st ->> 'enrolled')::boolean, false);
  cur := app.vehicle_terms(v.id, v_today);
  v_lower := coalesce(nullif(p ->> 'lower_from', '')::date, v_today);
  if cardinality(v_down) > 0 and v_lower < v_today then raise exception 'A lower amount takes effect today or later' using errcode = '22023'; end if;
  if not v_enrolled then v_lower := v_today; end if;
  if cardinality(v_up) > 0 then
    if v_enrolled then
      v_raise := coalesce(nullif(p ->> 'raise_from', '')::date, v_today + v_days);
      if v_raise < v_today + v_days then
        v_block := format('A higher amount needs %s days'' written notice: the earliest date is %s', v_days, app.fmt_day(v_today + v_days));
      elsif cardinality(v_down) > 0 and v_raise <= v_lower then
        v_block := 'The lower amounts start before the higher ones: choose an earlier date for them';
      end if;
    else
      v_raise := v_today;
    end if;
    -- the review shows what is missing; saving refuses it
    if v_block is not null and not v_preview then raise exception '%', v_block using errcode = '23514'; end if;
    if v_reason is null and not v_preview then raise exception 'Give the reason for the higher amounts: the owner reads it in the notice' using errcode = '22023'; end if;
  end if;
  v_fee_up := 'insurance_fee_cents' = any (v_up) or 'tracker_fee_cents' = any (v_up);
  v_share_up := 'revenue_share_bps' = any (v_up);
  -- Program settings "Lower management % without owner signature" off: a lower share waits for the owner's signature too
  if 'revenue_share_bps' = any (v_down) and not coalesce((app.settings()).owner_lower_share_without_signature, true) then
    v_sign_share := true;
    v_down := array_remove(v_down, 'revenue_share_bps');
  end if;
  if cardinality(v_down) > 0 then
    select string_agg(app.ct_label(x), ', ') into v_lbl from unnest(v_down) x;
    v_steps := v_steps || case when v_enrolled
      then format('Lower (%s): in force from %s. No notice period: it only lowers what the owner pays. The owner is emailed the written notice.', v_lbl, app.fmt_day(v_lower))
      else format('Lower (%s): the car is not enrolled yet, so an updated Vehicle Schedule is issued at once (no signature needed: it only lowers what the owner pays). The owner is emailed the written notice.', v_lbl) end;
  end if;
  if cardinality(v_up) > 0 then
    select string_agg(app.ct_label(x), ', ') into v_lbl from unnest(v_up) x;
    if not v_enrolled then
      v_steps := v_steps || format('Higher (%s): the car is not enrolled yet, so the owner signs an updated Vehicle Schedule (they are emailed the link); the new numbers apply once signed.', v_lbl);
    else
      if v_fee_up then
        v_steps := v_steps || format('Higher Fees: written notice today, in force from %s (%s days; the agreement needs %s). The owner may leave on notice instead.',
                                     app.fmt_day(v_raise), v_raise - v_today, v_days);
      end if;
      if v_share_up then
        v_steps := v_steps || format('Higher management fee (Revenue Share): the agreement needs the owner''s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from %s once signed, or from the day they sign if later.%s',
                                     app.fmt_day(v_raise), case when v_fee_up then ' The higher Fees apply from that date by the notice either way.' else '' end);
      end if;
    end if;
  end if;
  if v_sign_share then
    v_steps := v_steps || format('Lower management fee (Revenue Share): Program settings say the owner signs first. The owner is emailed an updated Vehicle Schedule to sign; it applies from %s once signed, or from the day they sign if later.',
                                 app.fmt_day(case when v_share_up then v_raise when v_enrolled then v_lower else v_today end));
  end if;
  if v_preview then
    return jsonb_build_object('state', 'signed', 'enrolled', v_enrolled, 'fields', v_fields, 'steps', to_jsonb(v_steps), 'blocked', v_block, 'done', false,
      'needs_reason', cardinality(v_up) > 0,
      'lower_from', case when cardinality(v_down) > 0 then v_lower end, 'raise_from', v_raise, 'earliest_raise', case when v_enrolled then v_today + v_days else v_today end);
  end if;

  -- the lower amounts
  if cardinality(v_down) > 0 then
    v_vals := b;
    foreach f in array v_down loop v_vals := v_vals || jsonb_build_object(f, (n ->> f)::bigint); end loop;
    if v_enrolled then
      if cur.effective_from = v_lower then
        update vehicle_fee_history set insurance_fee_cents = (v_vals ->> 'insurance_fee_cents')::bigint, tracker_fee_cents = (v_vals ->> 'tracker_fee_cents')::bigint,
               revenue_share_bps = (v_vals ->> 'revenue_share_bps')::integer, source = 'owner_benefit', notice_sent_on = v_today, created_by = p_by
         where id = cur.id;
        v_hist := cur.id;
      else
        update vehicle_fee_history set effective_to = v_lower where id = cur.id;
        insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from, notice_sent_on, created_by)
        values (v.id, s.id, 'owner_benefit', (v_vals ->> 'insurance_fee_cents')::bigint, (v_vals ->> 'tracker_fee_cents')::bigint, (v_vals ->> 'revenue_share_bps')::integer,
                v_lower, v_today, p_by)
        returning id into v_hist;
      end if;
      insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, previous, notice_sent_on, effective_from,
                                        reason, fee_history_id, created_by, applied_by, applied_at, countersignature, edit_id)
      values (v.id, 'decrease', 'applied', (v_vals ->> 'insurance_fee_cents')::bigint, (v_vals ->> 'tracker_fee_cents')::bigint, (v_vals ->> 'revenue_share_bps')::integer,
              jsonb_build_object('insurance_fee_cents', (b ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (b ->> 'tracker_fee_cents')::bigint,
                                 'revenue_share_bps', (b ->> 'revenue_share_bps')::bigint, 'schedule_number', s.schedule_number),
              v_today, v_lower, v_reason, v_hist, p_by, p_by, now(), app.ct_company_signature(), v_edit)
      returning id into v_change;
    else
      -- not enrolled: the schedule enrollment reads is updated at once (0067's versioning)
      insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, first_last_cents, previous,
                                        notice_sent_on, effective_from, reason, created_by, edit_id)
      values (v.id, 'decrease', 'awaiting_signature', (v_vals ->> 'insurance_fee_cents')::bigint, (v_vals ->> 'tracker_fee_cents')::bigint, (v_vals ->> 'revenue_share_bps')::integer,
              s.install_fee_cents, s.first_last_cents,
              jsonb_build_object('schedule_id', s.id, 'schedule_number', s.schedule_number, 'insurance_fee_cents', (b ->> 'insurance_fee_cents')::bigint,
                                 'tracker_fee_cents', (b ->> 'tracker_fee_cents')::bigint, 'revenue_share_bps', (b ->> 'revenue_share_bps')::bigint,
                                 'install_fee_cents', s.install_fee_cents, 'first_last_cents', s.first_last_cents),
              v_today, v_today, v_reason, p_by, v_edit)
      returning id into v_change;
      perform app.ot_schedule_change_apply(v_change, p_by, now());
      update vehicle_term_changes set countersignature = app.ct_company_signature() where id = v_change;
      select * into s from vehicle_schedules where vehicle_id = v.id and superseded_by is null;
    end if;
    v_ids := v_ids || v_change;
    perform app.ct_notice(v_change, v_down, true, false);
  end if;

  -- the higher amounts
  if cardinality(v_up) > 0 then
    v_share_at := case when 'revenue_share_bps' = any (v_down) then (n ->> 'revenue_share_bps')::bigint else (b ->> 'revenue_share_bps')::bigint end;
    v_vals := jsonb_build_object('insurance_fee_cents', (n ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (n ->> 'tracker_fee_cents')::bigint, 'revenue_share_bps', v_share_at);
    if v_enrolled and v_fee_up then
      update vehicle_fee_history set effective_to = v_raise where vehicle_id = v.id and effective_to is null and effective_from < v_raise;
      insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from, notice_sent_on, created_by)
      values (v.id, s.id, 'fee_notice', (v_vals ->> 'insurance_fee_cents')::bigint, (v_vals ->> 'tracker_fee_cents')::bigint, v_share_at::integer, v_raise, v_today, p_by)
      returning id into v_hist;
      insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, previous, notice_sent_on, effective_from,
                                        reason, fee_history_id, created_by, applied_by, applied_at, countersignature, edit_id)
      values (v.id, 'fee_notice', 'noticed', (v_vals ->> 'insurance_fee_cents')::bigint, (v_vals ->> 'tracker_fee_cents')::bigint, v_share_at::integer,
              jsonb_build_object('insurance_fee_cents', (b ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (b ->> 'tracker_fee_cents')::bigint,
                                 'revenue_share_bps', (b ->> 'revenue_share_bps')::bigint, 'schedule_number', s.schedule_number),
              v_today, v_raise, v_reason, v_hist, p_by, p_by, now(), app.ct_company_signature(), v_edit)
      returning id into v_change;
      v_ids := v_ids || v_change;
      if not v_share_up then
        perform app.ct_notice(v_change, (select array_agg(x) from unnest(v_up) x where x <> 'revenue_share_bps'), false, false);
      end if;
    end if;
  end if;
  if v_share_up or v_sign_share or (cardinality(v_up) > 0 and not v_enrolled) then
    v_sign_from := case when cardinality(v_up) > 0 then v_raise when v_enrolled then v_lower else v_today end;
    begin
      insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, first_last_cents,
                                        previous, notice_sent_on, effective_from, reason, created_by, edit_id)
      values (v.id, 'new_schedule', 'awaiting_signature', (n ->> 'insurance_fee_cents')::bigint, (n ->> 'tracker_fee_cents')::bigint, (n ->> 'revenue_share_bps')::integer,
              s.install_fee_cents, s.first_last_cents,
              jsonb_build_object('schedule_id', s.id, 'schedule_number', s.schedule_number,
                                 'insurance_fee_cents', (b ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (b ->> 'tracker_fee_cents')::bigint,
                                 'revenue_share_bps', (b ->> 'revenue_share_bps')::bigint, 'install_fee_cents', s.install_fee_cents, 'first_last_cents', s.first_last_cents),
              v_today, v_sign_from, v_reason, p_by, v_edit)
      returning id into v_change;
      v_ids := v_ids || v_change;
      perform app.ntf_emit('owner_schedule_resign', 'vehicle_term_change', v_change, 'sent', jsonb_build_object('owner_id', v.owner_id, 'vehicle_id', v.id));
      if v_enrolled and v_share_up then perform app.ct_notice(v_change, v_up, false, true); end if;
    end;
  end if;

  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'car_terms_change', 'vehicles', v.id::text, jsonb_build_object('state', 'signed', 'edit_id', v_edit, 'fields', v_fields, 'changes', to_jsonb(v_ids),
                                                                                'lower_from', v_lower, 'raise_from', v_raise));
  return jsonb_build_object('state', 'signed', 'enrolled', v_enrolled, 'fields', v_fields, 'steps', to_jsonb(v_steps), 'done', true, 'edit_id', v_edit, 'changes', to_jsonb(v_ids),
    'lower_from', case when cardinality(v_down) > 0 then v_lower end, 'raise_from', v_raise);
end $$;

-- ================================================================ 6. cancel a change that has not started
-- p: {change_id, reason}. A lower or higher amount whose date is still ahead: its dated terms are removed and the terms
-- before it run on. An updated schedule waiting for a signature: withdrawn (0067's schedule_change_admin).
create or replace function app.car_terms_cancel(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  h vehicle_fee_history;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  perform app.assert_admin(p_by);
  select * into c from vehicle_term_changes where id = nullif(p ->> 'change_id', '')::uuid for update;
  if c.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if v_reason is null then raise exception 'Give the reason' using errcode = '22023'; end if;
  if c.status = 'awaiting_signature' then
    return app.schedule_change_admin(p_by, jsonb_build_object('change_id', c.id, 'do', 'cancel', 'reason', v_reason));
  end if;
  if c.status = 'cancelled' then raise exception 'This change is already cancelled' using errcode = '23514'; end if;
  if c.kind not in ('fee_notice', 'decrease') or c.effective_from <= app.today() or c.fee_history_id is null then
    raise exception 'Only a change that has not started yet can be cancelled. To change the terms in force, make a new change' using errcode = '23514';
  end if;
  select * into h from vehicle_fee_history where id = c.fee_history_id for update;
  if exists (select 1 from vehicle_fee_history x where x.vehicle_id = c.vehicle_id and x.effective_from > h.effective_from) then
    raise exception 'A later change starts after this one: cancel that one first' using errcode = '23514';
  end if;
  update vehicle_term_changes set status = 'cancelled', cancelled_reason = v_reason, fee_history_id = null where id = c.id;
  delete from vehicle_fee_history where id = h.id;
  update vehicle_fee_history set effective_to = null where vehicle_id = c.vehicle_id and effective_to = h.effective_from;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'car_terms_cancel', 'vehicle_term_changes', c.id::text, jsonb_build_object('reason', v_reason, 'effective_from', c.effective_from));
  return jsonb_build_object('cancelled', true);
end $$;

-- ================================================================ 7. reads
-- One car: what applies now and from when, what is scheduled, every period and every change. p_admin: staff notes and
-- the editor's facts (mode options, what can be edited).
create or replace function app.ct_car(p_vehicle uuid, p_admin boolean) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  ob vehicle_onboardings;
  st jsonb;
  v_today date := app.today();
  v_periods jsonb;
  v_changes jsonb;
  v_awaiting jsonb;
  v_editable jsonb;
  v_options jsonb := null;
begin
  select * into v from vehicles where id = p_vehicle;
  if v.id is null then return null; end if;
  select * into ob from vehicle_onboardings where vehicle_id = v.id;
  st := app.ct_now(v.id);
  if st ->> 'state' in ('signed', 'fixed') then
    select coalesce(jsonb_agg(jsonb_build_object('from', h.effective_from, 'to', h.effective_to, 'insurance_fee_cents', h.insurance_fee_cents,
             'tracker_fee_cents', h.tracker_fee_cents, 'revenue_share_bps', h.revenue_share_bps, 'source', h.source,
             'current', h.effective_from <= v_today and (h.effective_to is null or h.effective_to > v_today), 'future', h.effective_from > v_today,
             'label', case h.source when 'signed_schedule' then 'Vehicle Schedule ' || coalesce((select x.schedule_number from vehicle_schedules x where x.id = h.vehicle_schedule_id), '')
                                    when 'fee_notice' then 'Written notice of ' || coalesce(app.fmt_day(h.notice_sent_on), '')
                                    when 'owner_benefit' then 'Lowered' || coalesce(', notice of ' || app.fmt_day(h.notice_sent_on), '')
                                    when 'shareholder' then 'Shareholder terms' else 'Correction' end)
             order by h.effective_from desc), '[]'::jsonb)
      into v_periods from vehicle_fee_history h where h.vehicle_id = v.id;
    if jsonb_array_length(v_periods) = 0 and st ->> 'state' = 'signed' then
      v_periods := jsonb_build_array(jsonb_build_object('from', null, 'to', null, 'insurance_fee_cents', (st ->> 'insurance_fee_cents')::bigint,
        'tracker_fee_cents', (st ->> 'tracker_fee_cents')::bigint, 'revenue_share_bps', (st ->> 'revenue_share_bps')::integer, 'source', 'signed_schedule',
        'current', true, 'future', false, 'label', 'Vehicle Schedule ' || (st ->> 'schedule_number') || ', from the Enrollment Date'));
    end if;
  else
    select coalesce(jsonb_agg(jsonb_build_object('from', t.effective_from, 'to', t.effective_to, 'insurance_fee_cents', t.insurance_fee_cents,
             'tracker_fee_cents', t.tracker_fee_cents, 'revenue_share_bps', t.revenue_share_bps, 'install_fee_cents', t.install_fee_cents, 'source', 'agreed',
             'current', t.effective_from <= v_today and (t.effective_to is null or t.effective_to > v_today), 'future', t.effective_from > v_today,
             'label', 'Agreed before signing' || case when p_admin and t.note is not null then ': ' || t.note else '' end)
             order by t.effective_from desc), '[]'::jsonb)
      into v_periods from owner_terms t where t.vehicle_id = v.id;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'status', c.status, 'created_at', c.created_at,
           'notice_on', coalesce(c.notice_sent_on, app.local_date(c.created_at)), 'effective_from', c.effective_from,
           'before', jsonb_build_object('insurance_fee_cents', (c.previous ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (c.previous ->> 'tracker_fee_cents')::bigint,
                                        'revenue_share_bps', (c.previous ->> 'revenue_share_bps')::bigint),
           'after', jsonb_build_object('insurance_fee_cents', c.insurance_fee_cents, 'tracker_fee_cents', c.tracker_fee_cents, 'revenue_share_bps', c.revenue_share_bps),
           'reason', c.reason, 'cancelled_reason', c.cancelled_reason, 'signed_method', c.signed_method, 'owner_signed_at', c.owner_signed_at,
           'notice', c.kind in ('fee_notice', 'decrease') or c.edit_id is not null,
           'label', case c.kind when 'decrease' then 'Lower amounts' when 'fee_notice' then 'Higher Fees by written notice' else 'Updated Vehicle Schedule for the owner to sign' end,
           'can_cancel', p_admin and (c.status = 'awaiting_signature' or (c.kind in ('fee_notice', 'decrease') and c.status in ('noticed', 'applied')
                                     and c.effective_from > v_today and c.fee_history_id is not null)))
           order by c.created_at desc), '[]'::jsonb)
    into v_changes from vehicle_term_changes c where c.vehicle_id = v.id;
  select jsonb_build_object('change_id', c.id, 'effective_from', c.effective_from, 'created_at', c.created_at,
           'insurance_fee_cents', c.insurance_fee_cents, 'tracker_fee_cents', c.tracker_fee_cents, 'revenue_share_bps', c.revenue_share_bps)
    into v_awaiting from vehicle_term_changes c where c.vehicle_id = v.id and c.status = 'awaiting_signature' order by c.created_at desc limit 1;
  v_editable := jsonb_build_object(
    'fees', st ->> 'state' <> 'fixed' and v.status not in ('declined', 'exited', 'total_loss'),
    'install', st ->> 'state' in ('not_set', 'pending'),
    'mode', st ->> 'state' = 'not_set' or (st ->> 'state' = 'pending' and ob.status in ('intake', 'terms_set')));
  if p_admin and (v_editable ->> 'mode')::boolean and ob.held_by is not null and ob.title_status is not null then
    v_options := jsonb_build_object(
      'managed', (select coalesce(jsonb_agg(jsonb_build_object('method', x ->> 'method', 'label', x ->> 'label', 'recommended', (x ->> 'recommended')::boolean)), '[]'::jsonb)
                    from jsonb_array_elements(app.onboarding_options_json(ob.held_by::text, ob.title_status::text, 'managed')) x),
      'self_managed', (select coalesce(jsonb_agg(jsonb_build_object('method', x ->> 'method', 'label', x ->> 'label', 'recommended', (x ->> 'recommended')::boolean)), '[]'::jsonb)
                    from jsonb_array_elements(app.onboarding_options_json(ob.held_by::text, ob.title_status::text, 'self_managed')) x),
      'turo_only', '[{"method": "none", "label": "None (Turo-Only)", "recommended": true}]'::jsonb);
  end if;
  return jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'plate', v.plate, 'status', v.status, 'onboarding_status', ob.status,
    'supply_type', v.supply_type, 'shareholder', v.is_shareholder_owned, 'state', st ->> 'state', 'enrolled', (st ->> 'enrolled')::boolean,
    'schedule_number', st ->> 'schedule_number', 'signed_at', st -> 'signed_at',
    'mode', coalesce(st ->> 'management_mode', ob.proposed_management_mode::text, v.management_mode::text),
    'method', coalesce(st ->> 'onboarding_method', ob.proposed_onboarding_method::text, v.onboarding_method::text),
    'current', jsonb_build_object('insurance_fee_cents', (st ->> 'insurance_fee_cents')::bigint, 'tracker_fee_cents', (st ->> 'tracker_fee_cents')::bigint,
                                  'revenue_share_bps', (st ->> 'revenue_share_bps')::integer, 'install_fee_cents', (st ->> 'install_fee_cents')::bigint),
    'since', st -> 'since', 'sources', case when p_admin then st -> 'sources' end,
    'scheduled', (select coalesce(jsonb_agg(x order by x ->> 'from'), '[]'::jsonb) from jsonb_array_elements(v_periods) x where (x ->> 'future')::boolean),
    'periods', v_periods, 'changes', v_changes, 'awaiting', v_awaiting,
    'editable', case when p_admin then v_editable end, 'options', v_options);
end $$;

-- Admin: every car of an owner (p.owner_id), or one car (p.vehicle_id).
create or replace function app.car_terms_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_days integer := (app.settings()).fee_change_notice_days;
begin
  perform app.assert_admin(p_by);
  if v_vehicle is not null then select owner_id into v_owner from vehicles where id = v_vehicle; end if;
  return jsonb_build_object('today', app.today(), 'notice_days', v_days, 'earliest_raise', app.today() + v_days, 'owner_id', v_owner,
    'cars', (select coalesce(jsonb_agg(app.ct_car(x.id, true) order by x.created_at, x.id), '[]'::jsonb)
               from vehicles x where (v_vehicle is not null and x.id = v_vehicle)
                                  or (v_vehicle is null and x.owner_id = v_owner and x.status not in ('declined'))));
end $$;

-- The owner portal: their cars' terms, from when, what is coming, every period and change, and the notices.
create or replace function app.owner_car_terms(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('today', app.today(), 'notice_days', (app.settings()).fee_change_notice_days,
    'cars', coalesce(jsonb_agg(app.ct_car(v.id, false) order by v.created_at, v.id), '[]'::jsonb))
    from vehicles v where v.owner_id = app.portal_owner_id(p_by) and v.status not in ('declined') and v.supply_type = 'program_owner'
$$;
create or replace function public.server_owner_car_terms(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_car_terms(p_by) $$;

-- The owner portal's cars show the terms in force today (a lower amount, a notice that started), not only the signed
-- schedule's numbers.
alter function app.owner_portal_vehicles(uuid) rename to owner_portal_vehicles_pre0135;
create or replace function app.owner_portal_vehicles(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(case when h.id is null then x else x || jsonb_build_object('insurance_fee_cents', h.insurance_fee_cents, 'tracker_fee_cents', h.tracker_fee_cents,
                                                                                     'revenue_share_bps', h.revenue_share_bps, 'terms_since', h.effective_from) end
                            order by o.n), '[]'::jsonb)
    from jsonb_array_elements(app.owner_portal_vehicles_pre0135(p_by)) with ordinality o(x, n)
    left join lateral (select f.* from vehicle_fee_history f where f.vehicle_id = (o.x ->> 'vehicle_id')::uuid
                         and f.effective_from <= app.today() and (f.effective_to is null or f.effective_to > app.today()) limit 1) h on true
$$;

-- ================================================================ 8. billing by effective date: a month whose terms change part way
-- The monthly owner invoice (0029, 0046) bills the whole month at the terms of its billing day. When the fee history has
-- more than one rate inside the days billed, the Insurance Fee and Tracker Fee lines are billed per day at each rate
-- (calc_prorated_fee per segment); a prepaid month applied to the invoice never exceeds the new Insurance Fee.
alter function app.generate_owner_invoice(uuid, date, uuid) rename to generate_owner_invoice_pre0135;
create or replace function app.generate_owner_invoice(p_vehicle uuid, p_month date, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.generate_owner_invoice_pre0135(p_vehicle, p_month, p_by);
  v vehicles;
  v_month date := app.month_start(p_month);
  v_last date;
  v_start date;
  v_end date;
  v_trk_start date;
  v_dim integer := app.days_in_month(p_month);
  v_hst integer := (app.settings(v_month)).hst_bps;
  v_ins bigint := 0;
  v_trk bigint := 0;
  v_parts text[] := '{}';
  v_tparts text[] := '{}';
  v_credit bigint;
  v_cut bigint;
  h record;
  l record;
  v_days integer;
begin
  if v_id is null then return null; end if;
  select * into v from vehicles where id = p_vehicle;
  v_last := (v_month + interval '1 month - 1 day')::date;
  v_start := greatest(v_month, v.enrollment_date);
  v_end := least(v_last, coalesce(app.vehicle_fee_end(p_vehicle), v_last));
  if (select count(*) from vehicle_fee_history f where f.vehicle_id = p_vehicle and f.effective_from <= v_end and (f.effective_to is null or f.effective_to > v_start)) < 2 then
    return v_id;
  end if;
  v_trk_start := case when v.tracker_installed_on is not null and v.tracker_installed_on > v_start then v.tracker_installed_on else v_start end;
  for h in select f.* from vehicle_fee_history f where f.vehicle_id = p_vehicle and f.effective_from <= v_end and (f.effective_to is null or f.effective_to > v_start)
            order by f.effective_from loop
    v_days := (least(v_end, coalesce(h.effective_to - 1, v_end)) - greatest(v_start, h.effective_from)) + 1;
    if v_days > 0 then
      v_ins := v_ins + public.calc_prorated_fee(h.insurance_fee_cents, v_days, v_dim);
      v_parts := v_parts || format('%s days at %s', v_days, app.fmt_money(h.insurance_fee_cents));
    end if;
    v_days := (least(v_end, coalesce(h.effective_to - 1, v_end)) - greatest(v_trk_start, h.effective_from)) + 1;
    if v_days > 0 then
      v_trk := v_trk + public.calc_prorated_fee(h.tracker_fee_cents, v_days, v_dim);
      v_tparts := v_tparts || format('%s days at %s', v_days, app.fmt_money(h.tracker_fee_cents));
    end if;
  end loop;
  update owner_invoice_lines set amount_cents = v_ins, hst_cents = public.calc_hst(v_ins, v_hst),
         description = format('Insurance Fee, %s (%s of %s days: %s)', to_char(v_month, 'FMMonth YYYY'), (v_end - v_start) + 1, v_dim, array_to_string(v_parts, ', '))
   where owner_invoice_id = v_id and kind = 'insurance_fee';
  update owner_invoice_lines set amount_cents = v_trk, hst_cents = public.calc_hst(v_trk, v_hst),
         description = format('Tracker Fee, %s (%s)', to_char(v_month, 'FMMonth YYYY'), array_to_string(v_tparts, ', '))
   where owner_invoice_id = v_id and kind = 'tracker_fee';
  -- a prepaid month applied never exceeds the Insurance Fee billed
  select coalesce(-sum(amount_cents), 0) into v_credit from owner_invoice_lines where owner_invoice_id = v_id and kind = 'prepaid_credit';
  if v_credit > v_ins then
    v_cut := v_credit - v_ins;
    for l in select * from owner_invoice_lines where owner_invoice_id = v_id and kind = 'prepaid_credit' order by amount_cents loop
      exit when v_cut <= 0;
      update owner_invoice_lines set amount_cents = amount_cents + least(v_cut, -amount_cents),
             hst_cents = -public.calc_hst(-(amount_cents + least(v_cut, -amount_cents)), v_hst)
       where id = l.id;
      update vehicle_prepaids set applied_cents = applied_cents - least(v_cut, -l.amount_cents) where id = l.vehicle_prepaid_id;
      v_cut := v_cut - least(v_cut, -l.amount_cents);
    end loop;
  end if;
  return v_id;
end $$;

-- ================================================================ 9. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0135;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'ops_read' and p_name = 'car_terms' then
    perform app.door_begin(p_user, p_aal);
    return app.car_terms_read(p_user, coalesce(p, '{}'::jsonb));
  end if;
  if p_call = 'ops_do' and p_name in ('car_terms_change', 'car_terms_cancel') then
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'car_terms_change' then app.car_terms_change(p_user, coalesce(p, '{}'::jsonb)) else app.car_terms_cancel(p_user, coalesce(p, '{}'::jsonb)) end;
  end if;
  return app.door_pre0135(p_user, p_aal, p_call, p_name, p);
end $$;

-- ================================================================ 9b. the car page's old "Fee change notice" (admin_do)
-- 0030's admin_act stored the jsonb that app.give_fee_change_notice returns in a uuid variable, so every Fee change notice
-- from Admin failed ("invalid input syntax for type uuid"). The action now goes through app.car_terms_change: the same
-- rules as the terms editor (a higher fee by written notice from the date given, a lower one from that date, or today
-- when the date has passed). p: {vehicle, insurance_fee_cents, tracker_fee_cents, effective_from, reason}.
alter function app.admin_do(uuid, text, jsonb) rename to admin_do_pre0135;
create or replace function app.admin_do(p_admin uuid, p_action text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_on date;
begin
  if p_action = 'fee_change_notice' then
    v_on := nullif(p ->> 'effective_from', '')::date;
    return app.car_terms_change(p_admin, jsonb_strip_nulls(jsonb_build_object('vehicle_id', coalesce(p ->> 'vehicle', p ->> 'vehicle_id'),
      'insurance_fee_cents', p -> 'insurance_fee_cents', 'tracker_fee_cents', p -> 'tracker_fee_cents',
      'raise_from', v_on, 'lower_from', case when v_on >= app.today() then v_on end, 'reason', p ->> 'reason')));
  end if;
  return app.admin_do_pre0135(p_admin, p_action, p);
end $$;

-- ================================================================ 10. the email: lower amounts and the management fee
-- CATALOGUE 0135 START (generated by supabase/seed/0135_gen.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_fee_change_notice', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Notice of a change to your terms for the {{vehicle_name}}, from {{effective_date}}', '{{fee_change_summary}}', 'Immediate: at least 30 days before the effective date of a higher amount; on the day a lower amount is set', 'An admin changes a vehicle''s terms after its Vehicle Schedule is signed: a higher Insurance Fee or Tracker Fee (a fee history row at least 30 days ahead), a higher Revenue Share (the same notice, and a new Vehicle Schedule opened for signature), or lower amounts (in force from today or a chosen date, no notice period). One email per change. is_share_change is true when a higher Revenue Share needs the owner''s signature; is_decrease is true for lower amounts.', null, '/owner/agreements', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"debit_day","type":"string"},{"name":"effective_date","type":"string"},{"name":"fee_change_reason","type":"string"},{"name":"fee_change_summary","type":"string"},{"name":"fee_changes","type":"list","fields":["label","before","after"]},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"is_decrease","type":"boolean"},{"name":"is_share_change","type":"boolean"},{"name":"notice_days","type":"string"},{"name":"notice_period_days","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_id","type":"string"},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_fee_change_notice.html', 'templates/owner_fee_change_notice.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0135 END
update notification_catalogue set emitted_by = 'app.give_fee_change_notice (0022), app.car_terms_change (0135)'
 where code = 'owner_fee_change_notice';

-- ================================================================ 11. the guides
-- GUIDES 0135 START (generated by supabase/seed/0135_gen.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('owner', 'fees-payments-and-payouts', 'chapter', 'bookings-and-your-own-use', 'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).
- Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.

An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Insufficient funds? | A $50.00 Late Fee once, and the same amount tried again within 30 days
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account > Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Account** > **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
2. Read the agreement and press **Continue to my bank details**.
3. Enter your bank details and press **Save the bank account**. Banking then shows the account and the next debit.

![](/guides/img/owner-07-banking-desktop-52316739.jpg "desktop; size: 1440 752; address: carmacars.ca/owner/banking; pins: 1 96.2 36.8")

## Pay an invoice now

1. Open Invoices, then the invoice. It lists what it covers and the balance.
2. Choose Card (paid at once) and press **Pay $...**.
3. Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press **Authorize debit of $...**.
4. Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.

![](/guides/img/owner-06-invoice-desktop-bba2c020.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/invoices/INV-1050; pins: 2 6.9 52.6, 3 38.2 52.6, 4 11.5 80.5")

> Tip: Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.

## Tell us where to pay you

1. Open **Account** > **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.
2. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
3. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 2 16.0 30.6, 1 66.0 40.9")
', 'Fees, payments and payouts', 'How fees are billed, the monthly debit, paying an invoice, statements and payouts.',
  'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).
- Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.
- Vehicles shows each car''s terms: the insurance fee and tracker fee a month and the Revenue Share, since when they apply, and any change coming. Open a car for its History: every period of terms and every notice we sent (Download the notice).
- Lower amounts apply from the date in our notice. A higher fee comes with 30 days'' written notice; a higher Revenue Share applies only if you sign an updated Vehicle Schedule. A month whose fee changes part way is billed per day at each amount.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.

An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Insufficient funds? | A $50.00 Late Fee once, and the same amount tried again within 30 days
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account > Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Account** > **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
2. Read the agreement and press **Continue to my bank details**.
3. Enter your bank details and press **Save the bank account**. Banking then shows the account and the next debit.

![](/guides/img/owner-07-banking-desktop-52316739.jpg "desktop; size: 1440 752; address: carmacars.ca/owner/banking; pins: 1 96.2 36.8")

## Pay an invoice now

1. Open Invoices, then the invoice. It lists what it covers and the balance.
2. Choose Card (paid at once) and press **Pay $...**.
3. Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press **Authorize debit of $...**.
4. Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.

![](/guides/img/owner-06-invoice-desktop-bba2c020.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/invoices/INV-1050; pins: 2 6.9 52.6, 3 38.2 52.6, 4 11.5 80.5")

> Tip: Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says "Paid by e-Transfer on" the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.

## Tell us where to pay you

1. Open **Account** > **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.
2. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
3. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 2 16.0 30.6, 1 66.0 40.9")
',
  '<p class="gd-p">Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.</p><section class="gd-task" id="fees-payments-and-payouts-how-your-fees-work" data-gd-task><h2 class="gd-h2">How your fees work</h2><ul class="gd-ul"><li>Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.</li><li>The tracker fee starts the day the car&#39;s tracker is installed. The tracker install fee has its own invoice.</li><li>Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).</li><li>Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.</li><li>Vehicles shows each car&#39;s terms: the insurance fee and tracker fee a month and the Revenue Share, since when they apply, and any change coming. Open a car for its History: every period of terms and every notice we sent (Download the notice).</li><li>Lower amounts apply from the date in our notice. A higher fee comes with 30 days&#39; written notice; a higher Revenue Share applies only if you sign an updated Vehicle Schedule. A month whose fee changes part way is billed per day at each amount.</li><li>One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.</li></ul><p class="gd-p">An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.</p></section><section class="gd-task" id="fees-payments-and-payouts-the-monthly-debit-step-by-step" data-gd-task><h2 class="gd-h2">The monthly debit, step by step</h2><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>10 days before: your invoices and one email with the total</em></li><li><b>2</b><span>The 15th</span><em>Each invoice is debited from your account</em></li><li><b>3</b><span>Cleared</span><em>The invoice shows Paid and you get a receipt</em></li><li><b>4</b><span>Insufficient funds?</span><em>A $50.00 Late Fee once, and the same amount tried again within 30 days</em></li></ol><ul class="gd-ul"><li>A debit is never more than its notice said. Each invoice shows &quot;will be debited on&quot; with the date.</li><li>If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.</li><li>Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Account &gt; Banking.</li><li>Returned again after the retry? The invoice is in arrears and we contact you.</li><li>You can always pay an invoice by card from its page before the debit day.</li><li>On your bank statement the debit shows our company&#39;s legal name, operating as CarmaCars.</li></ul></section><section class="gd-task" id="fees-payments-and-payouts-set-up-the-automatic-debit" data-gd-task><h2 class="gd-h2">Set up the automatic debit</h2><p class="gd-p">Do this once. Without it, we email you on each notice day to set it up.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Account</b> &gt; <b class="gd-ui">Banking</b>. Under Automatic debit of your fees, press <b class="gd-ui">Set up pre-authorized debit</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the agreement and press <b class="gd-ui">Continue to my bank details</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Enter your bank details and press <b class="gd-ui">Save the bank account</b>. Banking then shows the account and the next debit.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/752"><img src="/guides/img/owner-07-banking-desktop-52316739.jpg" alt="" loading="lazy" decoding="async" width="1440" height="752"><span class="gd-pin" style="left:96.2%;top:36.8%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-pay-an-invoice-now" data-gd-task><h2 class="gd-h2">Pay an invoice now</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Invoices, then the invoice. It lists what it covers and the balance.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose Card (paid at once) and press <b class="gd-ui">Pay $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press <b class="gd-ui">Authorize debit of $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/invoices/INV-1050</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-06-invoice-desktop-bba2c020.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:6.9%;top:52.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.2%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:11.5%;top:80.5%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says &quot;Paid by e-Transfer on&quot; the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.</div></aside></section><section class="gd-task" id="fees-payments-and-payouts-tell-us-where-to-pay-you" data-gd-task><h2 class="gd-h2">Tell us where to pay you</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Account</b> &gt; <b class="gd-ui">Banking</b>. Under Where we pay you, choose Bank transfer or e-Transfer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Submit payout details</b>. For your security we confirm new details by phone before we use them.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:990/642"><img src="/guides/img/owner-07-banking-desktop-87b2ffe3.jpg" alt="" loading="lazy" decoding="async" width="990" height="642"><span class="gd-pin" style="left:50.5%;top:25.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.9%;top:45.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:30.3%;top:89.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-statements-and-payouts" data-gd-task><h2 class="gd-h2">Statements and payouts</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download PDF</b> to keep a copy. We also email it to you with the PDF attached.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/792"><img src="/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg" alt="" loading="lazy" decoding="async" width="1440" height="792"><span class="gd-pin" style="left:16%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:66%;top:40.9%" aria-hidden="true">1</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'owners-and-onboarding', 'chapter', 'chauffeur-service', 'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**People** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**People** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**People** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
2. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
3. Statements and payouts for this owner.
4. Forms C and D, with a link to the review queue.
5. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms

The Terms tab of an owner''s page: what the owner pays and keeps, exact to the cent.

1. The owner''s terms are the default for their cars: fill in what you negotiated (leave a field empty to keep the standard grid), the date it applies from, and press **Save the terms**. They apply to cars whose terms are set from that date.
2. Each car has its own terms: open Change this car''s terms, type the exact amounts and press **Save the terms**. While the Vehicle Schedule is not signed, the schedule changes at once and the documents are made again.
3. When the Vehicle Schedule is already signed, saving shows a warning: the owner must sign an updated schedule. Press **Create the updated schedule and email the owner to sign**. The current terms stay until the owner signs; then the new ones apply from their date to invoices, debits and statements.
4. Signed on paper instead? **Record signed on paper** with the date. **Withdraw it** cancels the update, with a reason.

## Paid and signed

**People** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**People** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
', 'Owners and onboarding', 'Applications, the terms and first invoice, adding a car for an owner, an owner''s terms and invoices, paid and signed, and Forms C and D.',
  'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**People** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, **Use these terms for every car** copies the first car''s numbers to the others.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**People** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms, or their other car''s; change them for this car.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**People** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## Mark a car insured (Insurer confirmed)

A program owner''s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.

1. Each car waiting for the insurer is a line on To do: "Insurer has not confirmed : mark it insured". It says Now when a booking picks the car up soon.
2. When the insurer''s email arrives, press **Mark insured**. The date is today; change it to the date of the insurer''s email if it was earlier. Add its subject as the Reference if you like, and press **Insurer confirmed**.
3. One email for several cars? Press **Mark several insured** on the line " cars wait for the insurer". Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.
4. The same button is on the car: Overview (**Insurer confirmed**) and the Listing tab''s checklist, item "Not on the fleet insurance policy yet".

The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email "Written confirmation: your car is on the fleet policy". Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.

## Owners who paid another way, and the terms you agreed

Two lines on To do keep an owner''s money right without opening their page.

1. "Record the first and last month paid by ": their first and last month invoice was voided and nothing paid is recorded. Press **Record what they paid**, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car''s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.
2. "Enter the terms agreed with ": their cars still use the standard grid. Press **Enter the terms**: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.
3. Nothing to change? Press **Not needed** or **These are correct**: the line does not come back.

## A shareholder''s own car

On the owner''s page, each car has **Shareholder’s own car**.

1. A shareholder''s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.
2. Press **Shareholder’s own car**, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.
3. A first and last month or a tracker install invoice is refused for such a car, from any screen.

## Cancellation refunds

**Settings** > **Program**: the refund for each cancellation tier.

| When the renter cancels | Refund (default) |
| --- | --- |
| Within 24 hours of booking, 48 hours or more before the start | 95% |
| 48 hours or more before the start | 75% |
| 24 to 48 hours before the start | 50% |
| Under 24 hours, or after the start | 0% |

## An owner''s page

Open an owner from Owners. Three tabs: Overview, Terms and Invoices. **Add another car** and **New invoice** sit under the name.

1. Cars and terms, at the top: each car''s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with **Edit** and History (see An owner''s terms, car by car).
2. Upfront invoices: issue the first and last month amount agreed on each car''s terms, for each car whose terms are set.
3. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
4. Statements and payouts for this owner.
5. Forms C and D, with a link to the review queue.
6. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## An owner''s terms, car by car

The table Cars and terms, at the top of an owner''s page and its Terms tab: each car''s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.

1. Press **Edit** on a car''s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.
2. Press **Review**. It lists each value before and after, and what happens to each one. Nothing is saved yet.
3. Not signed yet (or not approved yet): **Save** applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.
4. Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings > Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.
5. Signed: a higher Insurance Fee or Tracker Fee needs 30 days'' written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.
6. Signed: a higher management fee (Revenue Share) needs the same notice and the owner''s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.
7. Press **Confirm**. The owner is emailed the written notice, which is also a PDF in their portal and in the car''s History.

History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.

The same editor is on the car''s page (Records tab, Owner terms). The owner''s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.

> Good to know: Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.

## Paid and signed

**People** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.
6. You rarely need to come here: an upfront or overdue owner invoice is a line on To do with **Record payment**, and an owner whose documents were sent two days ago or more and are not signed is a line with **Record paper signature**. Both pop-ups are the same forms, filled in.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**People** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
',
  '<p class="gd-p">Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.</p><section class="gd-task" id="owners-and-onboarding-applications" data-gd-task><h2 class="gd-h2">Applications</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Applications</b>. Every owner application, newest first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an application to decide.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/admin-33-applications-desktop-152f9e34.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:36.8%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:48.6%;top:53.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.8%;top:53.1%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-decide-on-an-application" data-gd-task><h2 class="gd-h2">Decide on an application</h2><p class="gd-p">One page holds everything: the owner, the car, the uploads, the four checks and the notes.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the driver&#39;s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The step &quot;Terms and first invoice&quot; opens for each car, filled in with the owner&#39;s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent; with several cars, <b class="gd-ui">Use these terms for every car</b> copies the first car&#39;s numbers to the others.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Approve</b> at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Missing something? Press <b class="gd-ui">Ask for something</b>, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press <b class="gd-ui">Send to the owner</b>. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Not a fit? Press <b class="gd-ui">Decline</b>, write the Reason the owner reads, and press <b class="gd-ui">Decline the application</b>. The owner is emailed for each car.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-34-application-desktop-98b64f92.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:72.9%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.9%;top:42.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.7%;top:42.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:72.9%;top:49.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says &quot;Entered by staff&quot; and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Notes on the page are for staff only: <b class="gd-ui">Add note</b> keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.</div></aside></section><section class="gd-task" id="owners-and-onboarding-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Add a car for an owner</b>, or <b class="gd-ui">Add another car</b> on an owner&#39;s page. The owner never has to fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN. The car is looked up at once and shown in one line (Edit if something is wrong); no VIN at hand, add it by its plate with the year, make and model from the lists. Tap the colour, check the class, then the odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner&#39;s terms, or their other car&#39;s; change them for this car.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and set it up</b>. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.</div></li></ol></div><p class="gd-p">Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, <b class="gd-ui">Send the set-up email again</b> sends the owner the email with a fresh link.</p></section><section class="gd-task" id="owners-and-onboarding-owners" data-gd-task><h2 class="gd-h2">Owners</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Owners</b>. Every owner, with their cars and where onboarding stands.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows their application, how many cars, and where onboarding stands.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">View as (owner portal)</b> shows their portal. <b class="gd-ui">Send password link</b> helps them sign in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invite an owner on file: fill in Name and Email under Invite an owner, then press <b class="gd-ui">Send invitation</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-12-owners-desktop-3a54d505.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:41%;top:42.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.4%;top:49.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:82.5%" aria-hidden="true">3</span></div></div></figure></div><p class="gd-p">The owner signs everything at once in their portal (Check and sign: the agreements, schedules and Forms A and B; the official registry forms are printed and signed in ink). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer&#39;s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.</p></section><section class="gd-task" id="owners-and-onboarding-mark-a-car-insured-insurer-confirmed" data-gd-task><h2 class="gd-h2">Mark a car insured (Insurer confirmed)</h2><p class="gd-p">A program owner&#39;s car is handed over to a renter only once the insurer confirms in writing that it is on the fleet policy. Requests, offers and payment never wait for it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each car waiting for the insurer is a line on To do: &quot;Insurer has not confirmed : mark it insured&quot;. It says Now when a booking picks the car up soon.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">When the insurer&#39;s email arrives, press <b class="gd-ui">Mark insured</b>. The date is today; change it to the date of the insurer&#39;s email if it was earlier. Add its subject as the Reference if you like, and press <b class="gd-ui">Insurer confirmed</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">One email for several cars? Press <b class="gd-ui">Mark several insured</b> on the line &quot; cars wait for the insurer&quot;. Every waiting car is ticked: untick any car the insurer did not name, check the date, and confirm them all at once.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The same button is on the car: Overview (<b class="gd-ui">Insurer confirmed</b>) and the Listing tab&#39;s checklist, item &quot;Not on the fleet insurance policy yet&quot;.</div></li></ol></div><p class="gd-p">The car is then on the fleet policy from that date: it can be handed over, its Enrollment Date is that date, its fee terms start, and the owner gets the email &quot;Written confirmation: your car is on the fleet policy&quot;. Its paperwork (agreements, registry visit, tracker) stays on its checklist until done. A car already listed and Available stays Available.</p></section><section class="gd-task" id="owners-and-onboarding-owners-who-paid-another-way-and-the-terms-you-agreed" data-gd-task><h2 class="gd-h2">Owners who paid another way, and the terms you agreed</h2><p class="gd-p">Two lines on To do keep an owner&#39;s money right without opening their page.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">&quot;Record the first and last month paid by &quot;: their first and last month invoice was voided and nothing paid is recorded. Press <b class="gd-ui">Record what they paid</b>, type the amount for each car (tax included), or one total for several cars, how and when it was paid and the reference. A draft first and last month invoice is kept or voided, your choice. Each car&#39;s invoice is then marked paid, the owner gets the receipt and the two prepaid months count. Never for a shareholder.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">&quot;Enter the terms agreed with &quot;: their cars still use the standard grid. Press <b class="gd-ui">Enter the terms</b>: the Management fee (Revenue Share), the Insurance Fee, the Tracker Fee, the Install Fee and the first and last month are filled in from the grid. Type what you agreed for the owner, and open a car to give it its own. A car whose schedule is signed gets an updated schedule for the owner to sign.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Nothing to change? Press <b class="gd-ui">Not needed</b> or <b class="gd-ui">These are correct</b>: the line does not come back.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-a-shareholder-s-own-car" data-gd-task><h2 class="gd-h2">A shareholder&#39;s own car</h2><p class="gd-p">On the owner&#39;s page, each car has <b class="gd-ui">Shareholder’s own car</b>.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">A shareholder&#39;s own car is split 90/10 (the share in Program settings) and pays no Insurance Fee, Tracker Fee, first and last month or tracker install.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Shareholder’s own car</b>, say why (it is kept in the audit log) and confirm. Press it again to undo. Bookings already made keep their split.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A first and last month or a tracker install invoice is refused for such a car, from any screen.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-cancellation-refunds" data-gd-task><h2 class="gd-h2">Cancellation refunds</h2><p class="gd-p"><b class="gd-ui">Settings</b> &gt; <b class="gd-ui">Program</b>: the refund for each cancellation tier.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">When the renter cancels</th><th scope="col">Refund (default)</th></tr></thead><tbody><tr><td>Within 24 hours of booking, 48 hours or more before the start</td><td>95%</td></tr><tr><td>48 hours or more before the start</td><td>75%</td></tr><tr><td>24 to 48 hours before the start</td><td>50%</td></tr><tr><td>Under 24 hours, or after the start</td><td>0%</td></tr></tbody></table></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-page" data-gd-task><h2 class="gd-h2">An owner&#39;s page</h2><p class="gd-p">Open an owner from Owners. Three tabs: Overview, Terms and Invoices. <b class="gd-ui">Add another car</b> and <b class="gd-ui">New invoice</b> sit under the name.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Cars and terms, at the top: each car&#39;s Insurance Fee, Tracker Fee, management fee (Revenue Share), Install Fee and mode, with <b class="gd-ui">Edit</b> and History (see An owner&#39;s terms, car by car).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Upfront invoices: issue the first and last month amount agreed on each car&#39;s terms, for each car whose terms are set.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Owner: address, sign-in, agreements, and what is still missing for the registry forms.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Statements and payouts for this owner.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Forms C and D, with a link to the review queue.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Further down: <b class="gd-ui">View as (owner portal)</b>, <b class="gd-ui">Send password link</b> and <b class="gd-ui">Send a sign-in link to the owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309</span></div><div class="gd-imgwrap" style="aspect-ratio:410/1030"><img src="/guides/img/admin-13-owner-desktop-819a9f8b.jpg" alt="" loading="lazy" decoding="async" width="410" height="1030"><span class="gd-pin" style="left:24.6%;top:4.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.1%;top:32.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.5%;top:73.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:21.2%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-terms-car-by-car" data-gd-task><h2 class="gd-h2">An owner&#39;s terms, car by car</h2><p class="gd-p">The table Cars and terms, at the top of an owner&#39;s page and its Terms tab: each car&#39;s Insurance Fee and Tracker Fee a month, management fee (Revenue Share), Install Fee and Management Mode, and since when they apply.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Edit</b> on a car&#39;s row. The row becomes fields: type the exact amounts (to the cent; the management fee in %). Before the Vehicle Schedule is signed you can also change the Install Fee, the Management Mode and the Onboarding Method.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Review</b>. It lists each value before and after, and what happens to each one. Nothing is saved yet.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Not signed yet (or not approved yet): <b class="gd-ui">Save</b> applies the numbers at once. An unsigned Vehicle Schedule is made again with them, so the owner signs these numbers; a car not approved yet keeps them for the Approve step.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed: a lower amount is in force from today, or the date you choose under Lower amounts from. No notice period is needed because it only lowers what the owner pays. A lower management fee does this while Settings &gt; Program, Lower management % without owner signature, is on (the default); off, the owner signs an updated Vehicle Schedule first.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Signed: a higher Insurance Fee or Tracker Fee needs 30 days&#39; written notice (Enrollment Agreement 4.8). Choose the date under Higher amounts from (30 days ahead at the earliest) and write the Reason: the owner reads it.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Signed: a higher management fee (Revenue Share) needs the same notice and the owner&#39;s signature. The owner is emailed the notice and an updated Vehicle Schedule to sign; it applies from the date once signed, or from the day they sign if that is later. Higher fees in the same change apply from the date by the notice either way.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Press <b class="gd-ui">Confirm</b>. The owner is emailed the written notice, which is also a PDF in their portal and in the car&#39;s History.</div></li></ol></div><p class="gd-p">History, under each car, lists every period of terms (from, to, the amounts, and why: the Vehicle Schedule, a written notice, lowered) and every change with its notice. A change that has not started yet has Cancel (give the reason): the terms before it run on. An updated schedule waiting for the owner has Record signed on paper (with the date) and Withdraw it. One change at a time: cancel or finish the one waiting before making the next.</p><p class="gd-p">The same editor is on the car&#39;s page (Records tab, Owner terms). The owner&#39;s default terms (for cars whose terms are set later) and the first and last month invoice stay on the Terms tab.</p><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Invoices follow the dates: a month whose Insurance Fee or Tracker Fee changes part way is billed per day at each rate. The Revenue Share of a rental is the one in force on the day it is booked.</div></aside></section><section class="gd-task" id="owners-and-onboarding-paid-and-signed" data-gd-task><h2 class="gd-h2">Paid and signed</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Paid and signed</b>. What each owner still has to pay or sign, and how each item was done.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <b class="gd-ui">Checklist and quick actions</b>. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b>. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Record paper signature</b>. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same checklist sits at the top of each owner&#39;s page.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">You rarely need to come here: an upfront or overdue owner invoice is a line on To do with <b class="gd-ui">Record payment</b>, and an owner whose documents were sent two days ago or more and are not signed is a line with <b class="gd-ui">Record paper signature</b>. Both pop-ups are the same forms, filled in.</div></li></ol></div><p class="gd-p">A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows &quot;Paid by e-Transfer on &quot; in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner&#39;s documents.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Recorded the wrong thing, or a cheque bounced? Press <b class="gd-ui">Void</b> beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.</div></aside></section><section class="gd-task" id="owners-and-onboarding-forms-c-and-d" data-gd-task><h2 class="gd-h2">Forms C and D</h2><p class="gd-p"><b class="gd-ui">People</b> &gt; <b class="gd-ui">Owner forms</b>. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the owner, the form, the witnesses and when it was uploaded.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the photo or scan. Check each marked spot is signed or initialled.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/470"><img src="/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg" alt="" loading="lazy" decoding="async" width="1440" height="470"><span class="gd-pin" style="left:29.2%;top:52.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:57.6%;top:52.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:52.3%" aria-hidden="true">3</span></div></div></figure></div></section>');
-- GUIDES 0135 END

-- ================================================================ privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array['ct_label', 'ct_fmt', 'ct_int', 'ct_company_signature', 'ct_now', 'ct_notice', 'ct_notice_text', 'ct_car',
              'notification_payload', 'ntf_payload_pre0135', 'file_access', 'file_access_pre0135', 'pdf_facts', 'pdf_facts_pre0135',
              'ot_schedule_change_apply', 'ot_schedule_change_apply_pre0135', 'car_terms_change', 'car_terms_cancel', 'car_terms_read', 'owner_car_terms',
              'owner_portal_vehicles', 'owner_portal_vehicles_pre0135', 'generate_owner_invoice', 'generate_owner_invoice_pre0135', 'door', 'door_pre0135']))
        or (n.nspname = 'public' and p.proname = 'server_owner_car_terms')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- admin_do keeps exactly the privileges it had (0079's pattern)
do $$
declare
  r record;
  v_new regprocedure;
  g text;
begin
  for r in select p.oid, oidvectortypes(p.proargtypes) as args from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = 'admin_do_pre0135' loop
    v_new := format('app.admin_do(%s)', r.args)::regprocedure;
    execute format('revoke all on function %s from public, anon, authenticated', v_new);
    foreach g in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(g, r.oid, 'execute') then execute format('grant execute on function %s to %I', v_new, g); end if;
    end loop;
  end loop;
end $$;
