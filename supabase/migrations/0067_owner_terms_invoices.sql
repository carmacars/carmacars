-- 0067_owner_terms_invoices.sql
-- The owner's request of October 19, 2026 (docs/changes/2026-10-19-owner-terms-invoices.md):
--   1. Negotiated terms per owner (a default for their cars) and per car, with effective dates: Insurance Fee, Tracker
--      Fee, Revenue Share, Install Fee, the first and last month amount (2 x the Insurance Fee unless set to an exact
--      amount) and one-off fees. A car's own terms win, then the owner's, then the owner's other cars, then the standard
--      grid and Program settings. They feed the Vehicle Schedule; the signed schedule feeds monthly invoices, debits and
--      statements as before. A change after the schedule is signed is a new schedule version the owner signs.
--   2. Approve no longer issues invoices by itself: the Admin confirms the terms and the first invoices per car (send
--      now, save as a draft, or record as already paid by e-Transfer, cash, cheque, bank transfer or another way).
--   3. Owner invoices with lines Admin edits while they are drafts (description, quantity, unit amount to the cent, HST
--      per line, notes, due date), issued, voided with a reason and reissued corrected (an issued invoice is never
--      edited in place), credit notes for paid ones, resend, PDF.
--   4. Staff add a car for an owner (Admin, customer service and fleet): the same records as the owner's application,
--      marked "Entered by staff", one set-up email to the owner, who reviews and corrects before signing.
-- No earlier migration is edited. Functions changed are wrapped (renamed with the suffix _pre_ot) or replaced with the
-- same signature, as 0029 to 0063 did. Nothing here changes an invoice that exists.

-- ================================================================ 1. settings
do $$
declare
  c record;
begin
  for c in select conname from pg_constraint where conrelid = 'program_settings'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%owner_debit_kinds%' loop
    execute format('alter table program_settings drop constraint %I', c.conname);
  end loop;
end $$;
alter table program_settings add constraint program_settings_owner_debit_kinds_check
  check (owner_debit_kinds <@ array['monthly', 'upfront', 'tracker_install', 'adjustment', 'custom']);
alter table program_settings alter column owner_debit_kinds set default array['monthly', 'upfront', 'tracker_install', 'adjustment', 'custom'];
-- an invoice of exact amounts (a registration fee) is debited like any other issued invoice; drafts never are
update program_settings set owner_debit_kinds = owner_debit_kinds || array['custom'] where not ('custom' = any (owner_debit_kinds));
alter table program_settings add column if not exists owner_invoice_due_days integer not null default 7 check (owner_invoice_due_days between 0 and 90);
comment on column program_settings.owner_invoice_due_days is 'Days after it is issued that an owner invoice made by hand is due, unless the Admin sets the date (0067)';

-- ================================================================ 2. negotiated terms
create table owner_terms (
  id                  uuid primary key default gen_random_uuid(),
  owner_id            uuid not null references owners (id),
  vehicle_id          uuid references vehicles (id),              -- null: the owner's default for their cars
  insurance_fee_cents bigint check (insurance_fee_cents >= 0),     -- null: not negotiated, the next source applies
  tracker_fee_cents   bigint check (tracker_fee_cents >= 0),
  revenue_share_bps   integer check (revenue_share_bps between 0 and 10000),
  install_fee_cents   bigint check (install_fee_cents >= 0),
  first_last_cents    bigint check (first_last_cents >= 0),        -- null: 2 x the Insurance Fee
  one_off_fees        jsonb not null default '[]'::jsonb check (jsonb_typeof(one_off_fees) = 'array'),
  effective_from      date not null,
  effective_to        date,                                        -- exclusive; null = open
  note                text,
  created_by          uuid references users (id),
  created_at          timestamptz not null default now(),
  check (effective_to is null or effective_to > effective_from),
  exclude using gist (owner_id with =, (coalesce(vehicle_id, '00000000-0000-0000-0000-000000000000'::uuid)) with =,
                      daterange(effective_from, effective_to, '[)') with &&)
);
create index owner_terms_owner_idx on owner_terms (owner_id, vehicle_id, effective_from desc);
comment on table owner_terms is 'Negotiated terms (0067): per car, or per owner as the default for their cars, with effective dates. A car''s row wins over the owner''s, then the owner''s other cars, then the grid and Program settings.';
alter table owner_terms enable row level security;
create policy admin_all on owner_terms for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_owner_terms after insert or update or delete on owner_terms for each row execute function app.audit_row();

alter table vehicle_schedules
  add column if not exists first_last_cents bigint check (first_last_cents >= 0),
  add column if not exists one_off_fees jsonb not null default '[]'::jsonb;
comment on column vehicle_schedules.first_last_cents is 'The first and last month amount agreed (0067); null: 2 x the Insurance Fee';

alter table vehicle_term_changes
  add column if not exists install_fee_cents bigint,
  add column if not exists first_last_cents bigint,
  add column if not exists signed_method text check (signed_method in ('portal', 'paper')),
  add column if not exists owner_signed_name text,
  add column if not exists owner_signed_at timestamptz,
  add column if not exists owner_signed_ip text,
  add column if not exists signed_text_sha256 text,
  add column if not exists countersignature text,
  add column if not exists cancelled_reason text;

-- One-off fees: [{description, amount_cents, hst}]; anything else is refused.
create or replace function app.ot_one_off(p jsonb) returns jsonb
language plpgsql immutable as $$
declare
  e jsonb;
  v_out jsonb := '[]'::jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'array' then return '[]'::jsonb; end if;
  for e in select value from jsonb_array_elements(p) loop
    if nullif(btrim(coalesce(e ->> 'description', '')), '') is null then continue; end if;
    if coalesce(e ->> 'amount_cents', '') !~ '^\d{1,9}$' then
      raise exception 'One-off fee "%": enter the amount in dollars and cents', e ->> 'description' using errcode = '22023';
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('description', left(btrim(e ->> 'description'), 120), 'amount_cents', (e ->> 'amount_cents')::bigint,
                                                           'hst', coalesce((e ->> 'hst')::boolean, true)));
  end loop;
  return v_out;
end $$;

-- The terms of a car on a day, with where each value comes from. p_vehicle null: a car about to be added for p_owner.
create or replace function app.owner_terms_resolve(p_vehicle uuid, p_on date default null, p_owner uuid default null, p_mode management_mode default null)
returns jsonb language plpgsql stable security definer set search_path = public, app as $$
declare
  v vehicles;
  v_owner uuid;
  v_on date := coalesce(p_on, app.today());
  v_mode management_mode;
  std record;
  vt owner_terms;
  ot owner_terms;
  pv vehicle_schedules;
  r jsonb := '{}'::jsonb;
  src jsonb := '{}'::jsonb;
  f text;
  val jsonb;
begin
  if p_vehicle is not null then select * into v from vehicles where id = p_vehicle; end if;
  v_owner := coalesce(v.owner_id, p_owner);
  if v_owner is null then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  v_mode := coalesce(p_mode, (select ob.proposed_management_mode from vehicle_onboardings ob where ob.vehicle_id = p_vehicle), v.management_mode, 'managed');
  select * into std from app.standard_terms(v_owner, v_mode, v_on);
  if p_vehicle is not null then
    select * into vt from owner_terms x where x.vehicle_id = p_vehicle and x.effective_from <= v_on and (x.effective_to is null or x.effective_to > v_on);
  end if;
  select * into ot from owner_terms x where x.owner_id = v_owner and x.vehicle_id is null and x.effective_from <= v_on and (x.effective_to is null or x.effective_to > v_on);
  -- the owner's most recent other car with terms: "Add another car" starts from what they already have
  select s.* into pv from vehicle_schedules s join vehicles x on x.id = s.vehicle_id
   where x.owner_id = v_owner and s.superseded_by is null and x.id is distinct from p_vehicle and s.management_mode = v_mode
     and x.status not in ('declined', 'exited', 'total_loss')
   order by s.created_at desc limit 1;
  foreach f in array array['insurance_fee_cents', 'tracker_fee_cents', 'revenue_share_bps', 'install_fee_cents'] loop
    if vt.id is not null and to_jsonb(vt) -> f <> 'null'::jsonb then val := to_jsonb(vt) -> f; src := src || jsonb_build_object(f, 'car');
    elsif ot.id is not null and to_jsonb(ot) -> f <> 'null'::jsonb then val := to_jsonb(ot) -> f; src := src || jsonb_build_object(f, 'owner');
    elsif pv.id is not null then val := to_jsonb(pv) -> f; src := src || jsonb_build_object(f, 'other_car');
    else val := to_jsonb(std) -> f; src := src || jsonb_build_object(f, 'standard');
    end if;
    r := r || jsonb_build_object(f, val);
  end loop;
  -- the mode decides what can apply at all (Enrollment Agreement 6): no share on Self-Managed, no fees on Turo-Only
  if v_mode = 'self_managed' then r := r || '{"revenue_share_bps": 0}'; src := src || '{"revenue_share_bps": "mode"}'; end if;
  if v_mode = 'turo_only' then
    r := r || '{"insurance_fee_cents": 0, "tracker_fee_cents": 0, "install_fee_cents": 0}';
    src := src || '{"insurance_fee_cents": "mode", "tracker_fee_cents": "mode", "install_fee_cents": "mode"}';
  end if;
  if v_mode <> 'turo_only' and vt.first_last_cents is not null then
    r := r || jsonb_build_object('first_last_cents', vt.first_last_cents); src := src || '{"first_last_cents": "car"}';
  elsif v_mode <> 'turo_only' and ot.first_last_cents is not null then
    r := r || jsonb_build_object('first_last_cents', ot.first_last_cents); src := src || '{"first_last_cents": "owner"}';
  else
    r := r || jsonb_build_object('first_last_cents', 2 * (r ->> 'insurance_fee_cents')::bigint); src := src || '{"first_last_cents": "two_months"}';
  end if;
  r := r || jsonb_build_object('one_off_fees', case when jsonb_array_length(coalesce(vt.one_off_fees, '[]')) > 0 then vt.one_off_fees else coalesce(ot.one_off_fees, '[]'::jsonb) end);
  return r || jsonb_build_object('sources', src, 'management_mode', v_mode, 'on', v_on, 'owner_id', v_owner, 'vehicle_id', p_vehicle,
    'car_terms_id', vt.id, 'owner_terms_id', ot.id,
    'standard', jsonb_build_object('insurance_fee_cents', std.insurance_fee_cents, 'tracker_fee_cents', std.tracker_fee_cents,
                                   'revenue_share_bps', std.revenue_share_bps, 'install_fee_cents', std.install_fee_cents, 'vehicle_count', std.vehicle_count));
end $$;

-- Write one terms row: the open row of the same scope closes the day before, or is replaced when it starts the same day.
create or replace function app.ot_terms_row(p_by uuid, p_owner uuid, p_vehicle uuid, p jsonb, p_from date) returns owner_terms
language plpgsql security definer set search_path = public, app as $$
declare
  cur owner_terms;
  r owner_terms;
begin
  if exists (select 1 from owner_terms x where x.owner_id = p_owner and x.vehicle_id is not distinct from p_vehicle and x.effective_from > p_from) then
    raise exception 'Terms already start after %: change those instead', app.fmt_day(p_from) using errcode = '23514';
  end if;
  select * into cur from owner_terms x where x.owner_id = p_owner and x.vehicle_id is not distinct from p_vehicle
     and x.effective_from <= p_from and (x.effective_to is null or x.effective_to > p_from) for update;
  if cur.id is not null and cur.effective_from = p_from then
    delete from owner_terms where id = cur.id;
  elsif cur.id is not null then
    update owner_terms set effective_to = p_from where id = cur.id;
  end if;
  insert into owner_terms (owner_id, vehicle_id, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, first_last_cents,
                           one_off_fees, effective_from, note, created_by)
  values (p_owner, p_vehicle, nullif(p ->> 'insurance_fee_cents', '')::bigint, nullif(p ->> 'tracker_fee_cents', '')::bigint,
          nullif(p ->> 'revenue_share_bps', '')::integer, nullif(p ->> 'install_fee_cents', '')::bigint, nullif(p ->> 'first_last_cents', '')::bigint,
          app.ot_one_off(p -> 'one_off_fees'), p_from, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by)
  returning * into r;
  return r;
end $$;

-- The open signature requests of an owner's unsigned documents are withdrawn: the documents are made again from the
-- records the next time the owner opens them, so nobody signs numbers that changed.
create or replace function app.ot_withdraw_unsigned(p_owner uuid) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  n integer;
begin
  update signature_requests r set status = 'voided'
   where r.status in ('draft', 'sent', 'partially_signed')
     and (r.id in (select a.signature_request_id from owner_agreements a where a.owner_id = p_owner and a.status in ('draft', 'sent'))
          or r.id in (select s.signature_request_id from vehicle_schedules s join vehicles v on v.id = s.vehicle_id
                       where v.owner_id = p_owner and s.signed_at is null and s.superseded_by is null));
  get diagnostics n = row_count;
  return n;
end $$;

-- Save negotiated terms (Admin). p: {owner_id, vehicle_id?, effective_from?, insurance_fee_cents, tracker_fee_cents,
-- revenue_share_bps, install_fee_cents, first_last_cents, one_off_fees, note, confirm_resign?}.
--   the owner's default: kept with its date; used for cars whose terms are set from then on
--   a car whose Vehicle Schedule is not signed: kept, and written into the schedule at once (documents made again)
--   a car whose Vehicle Schedule is signed: not saved without confirm_resign (the warning); with it, an updated Vehicle
--   Schedule is created for the owner to sign (the owner is emailed); the new terms run from their date once signed.
create or replace function app.owner_terms_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_vehicle uuid := nullif(p ->> 'vehicle_id', '')::uuid;
  v_from date := coalesce(nullif(p ->> 'effective_from', '')::date, app.today());
  v vehicles;
  s vehicle_schedules;
  ob vehicle_onboardings;
  r owner_terms;
  res jsonb;
  v_change uuid;
  v_ins bigint; v_trk bigint; v_share integer; v_inst bigint; v_fl bigint;
begin
  perform app.assert_admin(p_by);
  if v_vehicle is not null then
    select * into v from vehicles where id = v_vehicle;
    if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
    v_owner := v.owner_id;
  end if;
  if v_owner is null or not exists (select 1 from owners where id = v_owner) then raise exception 'Owner not found' using errcode = 'P0002'; end if;
  if (p ->> 'revenue_share_bps') is not null and (p ->> 'revenue_share_bps')::integer not between 0 and 10000 then
    raise exception 'The Revenue Share is between 0%% and 100%%' using errcode = '22023';
  end if;

  if v_vehicle is null then
    r := app.ot_terms_row(p_by, v_owner, null, p, v_from);
    return jsonb_build_object('saved', 'owner', 'terms', to_jsonb(r),
      'note', 'The owner''s terms apply to cars whose terms are set from ' || app.fmt_day(v_from) || '. A car''s own terms are changed on the car.');
  end if;

  select * into s from vehicle_schedules where vehicle_id = v_vehicle and superseded_by is null;
  select * into ob from vehicle_onboardings where vehicle_id = v_vehicle;
  if s.id is null or s.signed_at is null then
    r := app.ot_terms_row(p_by, v_owner, v_vehicle, p, v_from);
    if s.id is not null then
      res := app.owner_terms_resolve(v_vehicle, v_from);
      if s.management_mode = 'self_managed' and (res ->> 'revenue_share_bps')::integer <> 0 then
        raise exception 'A Self-Managed car has no Revenue Share' using errcode = '23514';
      end if;
      update vehicle_schedules set insurance_fee_cents = (res ->> 'insurance_fee_cents')::bigint, tracker_fee_cents = (res ->> 'tracker_fee_cents')::bigint,
             revenue_share_bps = (res ->> 'revenue_share_bps')::integer, install_fee_cents = (res ->> 'install_fee_cents')::bigint,
             first_last_cents = case when (res #>> '{sources,first_last_cents}') = 'two_months' then null else (res ->> 'first_last_cents')::bigint end,
             one_off_fees = res -> 'one_off_fees'
       where id = s.id;
      update vehicle_onboardings set terms_off_grid = true, terms_approved_by = p_by, terms_approved_at = now(), pending_terms = null where id = ob.id;
      perform app.ot_withdraw_unsigned(v_owner);
    end if;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'owner_terms_save', 'vehicles', v_vehicle::text, jsonb_build_object('terms', to_jsonb(r), 'schedule', s.schedule_number));
    return jsonb_build_object('saved', 'car', 'terms', to_jsonb(r), 'schedule_number', s.schedule_number, 'needs_resign', false,
      'note', case when s.id is null then 'Kept for this car: used when its terms are set.' else 'Written into Vehicle Schedule ' || s.schedule_number || ', not signed yet. The owner signs these numbers.' end);
  end if;

  -- signed: a new version for the owner to sign
  if not coalesce((p ->> 'confirm_resign')::boolean, false) then
    return jsonb_build_object('saved', null, 'needs_resign', true, 'schedule_number', s.schedule_number, 'signed_at', s.signed_at,
      'message', format('Vehicle Schedule %s was signed on %s. New terms need an updated Vehicle Schedule signed by the owner; they apply from the date you give once it is signed.',
                        s.schedule_number, app.fmt_date(s.signed_at)));
  end if;
  if v_from < app.today() then raise exception 'An updated Vehicle Schedule takes effect today or later' using errcode = '22023'; end if;
  v_ins := coalesce(nullif(p ->> 'insurance_fee_cents', '')::bigint, s.insurance_fee_cents);
  v_trk := coalesce(nullif(p ->> 'tracker_fee_cents', '')::bigint, s.tracker_fee_cents);
  v_share := coalesce(nullif(p ->> 'revenue_share_bps', '')::integer, s.revenue_share_bps);
  v_inst := coalesce(nullif(p ->> 'install_fee_cents', '')::bigint, s.install_fee_cents);
  v_fl := coalesce(nullif(p ->> 'first_last_cents', '')::bigint, s.first_last_cents);
  if s.management_mode = 'self_managed' and v_share <> 0 then raise exception 'A Self-Managed car has no Revenue Share' using errcode = '23514'; end if;
  if s.management_mode = 'turo_only' and (v_ins, v_trk, v_inst) is distinct from (0::bigint, 0::bigint, 0::bigint) then
    raise exception 'A Turo-Only car has no Fees' using errcode = '23514';
  end if;
  if (v_ins, v_trk, v_share, v_inst, v_fl) is not distinct from (s.insurance_fee_cents, s.tracker_fee_cents, s.revenue_share_bps, s.install_fee_cents, s.first_last_cents) then
    raise exception 'These are the terms already signed' using errcode = '22023';
  end if;
  r := app.ot_terms_row(p_by, v_owner, v_vehicle, p, v_from);
  update vehicle_term_changes set status = 'cancelled', cancelled_reason = 'Replaced by a newer version'
   where vehicle_id = v_vehicle and status = 'awaiting_signature';
  insert into vehicle_term_changes (vehicle_id, kind, status, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, first_last_cents,
                                    previous, effective_from, reason, created_by)
  values (v_vehicle, 'new_schedule', 'awaiting_signature', v_ins, v_trk, v_share, v_inst, v_fl,
          jsonb_build_object('schedule_id', s.id, 'schedule_number', s.schedule_number, 'insurance_fee_cents', s.insurance_fee_cents,
                             'tracker_fee_cents', s.tracker_fee_cents, 'revenue_share_bps', s.revenue_share_bps, 'install_fee_cents', s.install_fee_cents,
                             'first_last_cents', s.first_last_cents),
          v_from, nullif(btrim(coalesce(p ->> 'note', '')), ''), p_by)
  returning id into v_change;
  perform app.ntf_emit('owner_schedule_resign', 'vehicle_term_change', v_change, 'sent', jsonb_build_object('owner_id', v_owner, 'vehicle_id', v_vehicle));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'schedule_resign_request', 'vehicle_term_changes', v_change::text, jsonb_build_object('vehicle_id', v_vehicle, 'effective_from', v_from));
  return jsonb_build_object('saved', 'car', 'needs_resign', true, 'change_id', v_change, 'terms', to_jsonb(r),
    'note', 'An updated Vehicle Schedule was sent to the owner to sign. The current terms apply until it is signed.');
end $$;

-- An updated Vehicle Schedule signed (in the portal or on paper): it supersedes the old one, its terms run from its
-- date (0022's record_schedule_change_signed, with the Install Fee and the first and last month amount carried).
create or replace function app.ot_schedule_change_apply(p_change uuid, p_by uuid, p_signed_at timestamptz, p_document uuid default null) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  s vehicle_schedules;
  v_new uuid := gen_random_uuid();
  v_hist uuid;
begin
  select * into c from vehicle_term_changes where id = p_change for update;
  if c.id is null or c.status <> 'awaiting_signature' then raise exception 'This change is not waiting for a signature' using errcode = '23514'; end if;
  select * into s from vehicle_schedules where vehicle_id = c.vehicle_id and superseded_by is null for update;
  if exists (select 1 from vehicle_fee_history h where h.vehicle_id = c.vehicle_id and h.effective_from > c.effective_from) then
    raise exception 'Terms already start after %', c.effective_from using errcode = '23514';
  end if;
  update vehicle_schedules set superseded_by = id where id = s.id;
  insert into vehicle_schedules (id, vehicle_id, owner_agreement_id, title_agreement_id, schedule_number, vehicle_number, is_additional,
      odometer_km, held_by, title_status, finance_party_name, finance_party_account, finance_permission, finance_permission_document_id,
      management_mode, onboarding_method, insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date,
      special_terms, owners_lien, ppsa_registration_number, onboarding_estimate_cents, document_id, signed_at, created_by, first_last_cents, one_off_fees)
  values (v_new, s.vehicle_id, s.owner_agreement_id, s.title_agreement_id, 'VS-' || nextval('vehicle_schedule_number_seq'), s.vehicle_number, s.is_additional,
      s.odometer_km, s.held_by, s.title_status, s.finance_party_name, s.finance_party_account, s.finance_permission, s.finance_permission_document_id,
      s.management_mode, s.onboarding_method, c.insurance_fee_cents, c.tracker_fee_cents, coalesce(c.install_fee_cents, s.install_fee_cents), c.revenue_share_bps,
      s.enrollment_date, s.special_terms, s.owners_lien, s.ppsa_registration_number, s.onboarding_estimate_cents, p_document, p_signed_at, p_by,
      coalesce(c.first_last_cents, s.first_last_cents), s.one_off_fees);
  update vehicle_schedules set superseded_by = v_new, superseded_at = now() where id = s.id;
  if exists (select 1 from vehicle_fee_history h where h.vehicle_id = c.vehicle_id) then
    delete from vehicle_fee_history where vehicle_id = c.vehicle_id and effective_from = c.effective_from;
    update vehicle_fee_history set effective_to = c.effective_from
     where vehicle_id = c.vehicle_id and (effective_to is null or effective_to > c.effective_from) and effective_from < c.effective_from;
    insert into vehicle_fee_history (vehicle_id, vehicle_schedule_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from, created_by)
    values (c.vehicle_id, v_new, 'signed_schedule', c.insurance_fee_cents, c.tracker_fee_cents, c.revenue_share_bps, c.effective_from, p_by)
    returning id into v_hist;
  end if;
  update vehicle_term_changes set status = 'applied', new_schedule_id = v_new, fee_history_id = v_hist, document_id = coalesce(p_document, document_id),
         applied_by = p_by, applied_at = now()
   where id = c.id;
  return v_new;
end $$;

-- The text the owner signs for an updated Vehicle Schedule (shown on screen; its SHA-256 is what the signature binds).
create or replace function app.schedule_change_text(p_change uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('change_id', c.id, 'status', c.status, 'vehicle_id', c.vehicle_id, 'vehicle_name', app.vehicle_name(c.vehicle_id),
    'plate', v.plate, 'vin', v.vin, 'owner_name', o.legal_name, 'effective_from', c.effective_from,
    'previous', c.previous,
    'new', jsonb_build_object('insurance_fee_cents', c.insurance_fee_cents, 'tracker_fee_cents', c.tracker_fee_cents, 'revenue_share_bps', c.revenue_share_bps,
                              'install_fee_cents', c.install_fee_cents, 'first_last_cents', c.first_last_cents),
    'text', concat_ws(E'\n',
      'Updated Vehicle Schedule to the Enrollment Agreement between ' || app.owner_payee_name() || ' and ' || o.legal_name || ' (the Owner).',
      'Vehicle: ' || app.vehicle_name(c.vehicle_id) || ', VIN ' || upper(v.vin) || coalesce(', plate ' || v.plate, '') || '.',
      'From ' || app.fmt_day(c.effective_from) || ' this entry replaces Vehicle Schedule ' || coalesce(c.previous ->> 'schedule_number', '') || ' for this Vehicle:',
      'Insurance Fee per month: ' || app.fmt_money(c.insurance_fee_cents) || '. Tracker Fee per month: ' || app.fmt_money(c.tracker_fee_cents) || '.',
      'Revenue Share: ' || trim(to_char(c.revenue_share_bps / 100.0, 'FM990.99')) || '%.',
      'Install Fee: ' || app.fmt_money(coalesce(c.install_fee_cents, (c.previous ->> 'install_fee_cents')::bigint)) || '.',
      case when c.first_last_cents is not null then 'First and last month amount: ' || app.fmt_money(c.first_last_cents) || '.' end,
      'HST is extra. Everything else in the Vehicle Schedule and the Enrollment Agreement stays the same.'),
    'signed_method', c.signed_method, 'signed_at', c.owner_signed_at, 'signed_name', c.owner_signed_name, 'countersignature', c.countersignature,
    'created_at', c.created_at)
    from vehicle_term_changes c join vehicles v on v.id = c.vehicle_id join owners o on o.id = v.owner_id
   where c.id = p_change
$$;

-- The owner signs an updated Vehicle Schedule in the owner portal: their typed legal name, the confirmation, and the
-- SHA-256 of the text on screen. CarmaCars countersigns under the standing authorization (0053).
create or replace function app.schedule_change_sign(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  t jsonb;
  v_sha text;
  v_new uuid;
  ps program_settings := app.settings();
begin
  select * into c from vehicle_term_changes where id = nullif(p ->> 'change_id', '')::uuid for update;
  if c.id is null or not app.user_owns_vehicle(p_by, c.vehicle_id) then raise exception 'Not found' using errcode = 'P0002'; end if;
  if c.status <> 'awaiting_signature' then raise exception 'This Vehicle Schedule is not waiting for your signature' using errcode = '23514'; end if;
  if not coalesce((p ->> 'agree')::boolean, false) then raise exception 'Tick the box to confirm you agree' using errcode = '22023'; end if;
  if length(btrim(coalesce(p ->> 'name', ''))) < 2 then raise exception 'Type your full legal name to sign' using errcode = '22023'; end if;
  t := app.schedule_change_text(c.id);
  v_sha := encode(sha256(convert_to(t ->> 'text', 'UTF8')), 'hex');
  if lower(coalesce(p ->> 'sha256', '')) <> v_sha then
    raise exception 'The schedule changed since you opened it. Open it again and sign.' using errcode = '23514';
  end if;
  v_new := app.ot_schedule_change_apply(c.id, p_by, now());
  update vehicle_term_changes set signed_method = 'portal', owner_signed_name = btrim(p ->> 'name'), owner_signed_at = now(),
         owner_signed_ip = nullif(p ->> 'ip', ''), signed_text_sha256 = v_sha,
         countersignature = format('Signed electronically for %s by %s, %s, under a standing authorization dated %s.', app.owner_payee_name(),
                                   coalesce(ps.signing_officer_name, 'its signing officer'), coalesce(ps.signing_officer_title, 'Director'),
                                   coalesce(app.fmt_day(ps.signing_officer_authorized_on), 'on file'))
   where id = c.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'schedule_change_signed', 'vehicle_term_changes', c.id::text, jsonb_build_object('schedule_id', v_new, 'sha256', v_sha, 'method', 'portal'));
  return jsonb_build_object('signed', true, 'schedule_id', v_new, 'schedule_number', (select schedule_number from vehicle_schedules where id = v_new));
end $$;

-- An Admin records an updated Vehicle Schedule signed on paper, or withdraws it.
create or replace function app.schedule_change_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c vehicle_term_changes;
  v_new uuid;
begin
  perform app.assert_admin(p_by);
  select * into c from vehicle_term_changes where id = nullif(p ->> 'change_id', '')::uuid for update;
  if c.id is null then raise exception 'Not found' using errcode = 'P0002'; end if;
  if c.status <> 'awaiting_signature' then raise exception 'This Vehicle Schedule is not waiting for a signature' using errcode = '23514'; end if;
  if p ->> 'do' = 'cancel' then
    if nullif(btrim(coalesce(p ->> 'reason', '')), '') is null then raise exception 'Give the reason' using errcode = '22023'; end if;
    update vehicle_term_changes set status = 'cancelled', cancelled_reason = btrim(p ->> 'reason') where id = c.id;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'schedule_change_cancel', 'vehicle_term_changes', c.id::text, p);
    return jsonb_build_object('cancelled', true);
  end if;
  v_new := app.ot_schedule_change_apply(c.id, p_by, app.local_midnight(coalesce(nullif(p ->> 'signed_on', '')::date, app.today())) + interval '12 hours');
  update vehicle_term_changes set signed_method = 'paper', owner_signed_at = app.local_midnight(coalesce(nullif(p ->> 'signed_on', '')::date, app.today())) + interval '12 hours'
   where id = c.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'schedule_change_signed', 'vehicle_term_changes', c.id::text, jsonb_build_object('method', 'paper', 'schedule_id', v_new));
  return jsonb_build_object('signed', true, 'schedule_id', v_new);
end $$;

-- The terms page of a car or an owner for the Admin: what applies now, every dated row, the signed schedule and any
-- updated schedule waiting for the owner.
create or replace function app.owner_terms_read(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'owner', (select jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(t) order by t.effective_from desc), '[]'::jsonb),
                                        'current', (select to_jsonb(x) from owner_terms x where x.owner_id = v_owner and x.vehicle_id is null
                                                       and x.effective_from <= app.today() and (x.effective_to is null or x.effective_to > app.today())))
                from owner_terms t where t.owner_id = v_owner and t.vehicle_id is null),
    'standard', (select to_jsonb(s) from app.standard_terms(v_owner, 'managed') s),
    'cars', (select coalesce(jsonb_agg(jsonb_build_object(
               'vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'mode', v.management_mode, 'billing_case', v.billing_case,
               'resolved', app.owner_terms_resolve(v.id),
               'rows', (select coalesce(jsonb_agg(to_jsonb(t) order by t.effective_from desc), '[]'::jsonb) from owner_terms t where t.vehicle_id = v.id),
               'schedule', (select jsonb_build_object('id', s.id, 'schedule_number', s.schedule_number, 'signed_at', s.signed_at, 'insurance_fee_cents', s.insurance_fee_cents,
                                   'tracker_fee_cents', s.tracker_fee_cents, 'revenue_share_bps', s.revenue_share_bps, 'install_fee_cents', s.install_fee_cents,
                                   'first_last_cents', coalesce(s.first_last_cents, 2 * s.insurance_fee_cents), 'first_last_set', s.first_last_cents is not null,
                                   'one_off_fees', s.one_off_fees)
                              from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null),
               'in_force', (select to_jsonb(h) from app.vehicle_terms(v.id, app.today()) h where h.effective_from is not null),
               'awaiting', (select app.schedule_change_text(c.id) from vehicle_term_changes c where c.vehicle_id = v.id and c.status = 'awaiting_signature'
                             order by c.created_at desc limit 1),
               'versions', (select coalesce(jsonb_agg(jsonb_build_object('schedule_number', s.schedule_number, 'signed_at', s.signed_at, 'insurance_fee_cents', s.insurance_fee_cents,
                                   'revenue_share_bps', s.revenue_share_bps, 'superseded_at', s.superseded_at) order by s.created_at), '[]'::jsonb)
                              from vehicle_schedules s where s.vehicle_id = v.id))
               order by v.created_at), '[]'::jsonb)
               from vehicles v where v.owner_id = v_owner and v.status not in ('declined')));
end $$;

-- ================================================================ 3. owner invoices: drafts, lines, void, reissue, credit notes
alter table owner_invoices drop constraint if exists owner_invoices_kind_check;
alter table owner_invoices add constraint owner_invoices_kind_check check (kind in ('upfront', 'monthly', 'adjustment', 'tracker_install', 'custom', 'credit_note'));
alter table owner_invoices
  add column if not exists title text,
  add column if not exists notes text,
  add column if not exists due_on date,
  add column if not exists void_reason text,
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid references users (id),
  add column if not exists replaces_invoice_id uuid references owner_invoices (id),
  add column if not exists credit_for_invoice_id uuid references owner_invoices (id),
  add column if not exists application_id uuid references owner_applications (id),
  add column if not exists issued_by uuid references users (id),
  add column if not exists email_count integer not null default 0,
  add column if not exists last_emailed_at timestamptz;
alter table owner_invoices add constraint owner_invoices_credit_note_check check (kind <> 'credit_note' or credit_for_invoice_id is not null);
comment on column owner_invoices.replaces_invoice_id is 'The voided invoice this one corrects (0067)';
comment on column owner_invoices.credit_for_invoice_id is 'A credit note: the paid invoice it credits (0067)';

alter table owner_invoice_lines drop constraint if exists owner_invoice_lines_kind_check;
alter table owner_invoice_lines add constraint owner_invoice_lines_kind_check check (kind in (
  'install_fee', 'first_month_insurance', 'last_month_insurance', 'insurance_fee', 'tracker_fee', 'late_fee', 'prepaid_credit', 'adjustment',
  'registration_fee', 'custom', 'credit'));
alter table owner_invoice_lines
  add column if not exists quantity numeric(10, 2) not null default 1 check (quantity > 0 and quantity <= 10000),
  add column if not exists unit_amount_cents bigint,
  add column if not exists note text,
  add column if not exists sort_order integer not null default 0;
alter table owner_invoice_lines add constraint owner_invoice_lines_credit_check check (kind <> 'credit' or amount_cents <= 0);

insert into status_transitions (entity, from_status, to_status, note) values
  ('owner_invoice', 'failed', 'void', 'voided with a reason before anything was paid; a corrected invoice replaces it (0067)')
on conflict do nothing;

-- An issued invoice is never edited in place: its lines change only while it is a draft (a Late Fee is added by the
-- debit rules as its own line, as before).
create or replace function app.owner_invoice_lines_draft_only() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_status text;
begin
  select status into v_status from owner_invoices where id = old.owner_invoice_id;
  if v_status is not null and v_status <> 'draft' then
    raise exception 'This invoice is %: its lines cannot change. Void it with a reason and issue a corrected one.', replace(v_status, '_', ' ') using errcode = '23514';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
create trigger owner_invoice_lines_draft_only before update or delete on owner_invoice_lines
  for each row execute function app.owner_invoice_lines_draft_only();

create or replace function app.oi_label(p_kind text) returns text
language sql immutable as $$
  select case p_kind when 'upfront' then 'First and last month' when 'monthly' then 'Monthly fees' when 'tracker_install' then 'Tracker install'
                     when 'custom' then 'Invoice' when 'credit_note' then 'Credit note' when 'adjustment' then 'Adjustment' else initcap(replace(p_kind, '_', ' ')) end
$$;

-- Write the lines of a draft. Each line: {kind?, description, quantity, unit_amount_cents, hst, note}. The amount is
-- quantity x unit, to the cent; HST at the Program settings rate on the lines that carry it.
create or replace function app.oi_write_lines(p_invoice uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  e jsonb;
  v_kind text;
  v_qty numeric;
  v_unit bigint;
  v_amt bigint;
  v_hst boolean;
  v_bps integer := (app.settings()).hst_bps;
  n integer := 0;
begin
  select * into i from owner_invoices where id = p_invoice;
  if jsonb_typeof(coalesce(p_lines, 'null')) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'Add at least one line' using errcode = '22023';
  end if;
  delete from owner_invoice_lines where owner_invoice_id = p_invoice and kind not in ('prepaid_credit', 'late_fee');
  for e in select value from jsonb_array_elements(p_lines) loop
    n := n + 1;
    v_kind := coalesce(nullif(e ->> 'kind', ''), case when i.kind = 'credit_note' then 'credit' else 'custom' end);
    if v_kind in ('prepaid_credit', 'late_fee') then continue; end if;
    if v_kind not in ('install_fee', 'first_month_insurance', 'last_month_insurance', 'insurance_fee', 'tracker_fee', 'adjustment', 'registration_fee', 'custom', 'credit') then
      raise exception 'Line %: unknown kind %', n, v_kind using errcode = '22023';
    end if;
    if nullif(btrim(coalesce(e ->> 'description', '')), '') is null then raise exception 'Line %: write the description', n using errcode = '22023'; end if;
    if coalesce(e ->> 'quantity', '1') !~ '^\d{1,5}(\.\d{1,2})?$' or coalesce(nullif(e ->> 'quantity', ''), '1')::numeric <= 0 then
      raise exception 'Line %: the quantity is a number above 0 (up to 2 decimals)', n using errcode = '22023';
    end if;
    if coalesce(e ->> 'unit_amount_cents', '') !~ '^-?\d{1,10}$' then raise exception 'Line %: enter the amount in dollars and cents', n using errcode = '22023'; end if;
    v_qty := coalesce(nullif(e ->> 'quantity', ''), '1')::numeric;
    v_unit := (e ->> 'unit_amount_cents')::bigint;
    if v_unit < 0 and v_kind not in ('custom', 'adjustment', 'credit') then raise exception 'Line %: only a custom line may be a discount', n using errcode = '22023'; end if;
    if v_kind = 'credit' and v_unit > 0 then v_unit := -v_unit; end if;
    v_amt := round(v_qty * v_unit)::bigint;
    v_hst := coalesce((e ->> 'hst')::boolean, true);
    insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents, quantity, unit_amount_cents, note, sort_order)
    values (p_invoice, v_kind, left(btrim(e ->> 'description'), 200), v_amt, v_hst, case when v_hst then public.calc_hst(v_amt, v_bps) else 0 end,
            v_qty, v_unit, nullif(left(btrim(coalesce(e ->> 'note', '')), 300), ''), n);
  end loop;
  if n = 0 then raise exception 'Add at least one line' using errcode = '22023'; end if;
end $$;

-- Create or change a draft (Admin). p: {id?, vehicle_id, kind (custom | upfront | tracker_install | adjustment), title,
-- notes, due_on, application_id, lines: [...]}.
create or replace function app.owner_invoice_draft_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  v vehicles;
  v_kind text := coalesce(nullif(p ->> 'kind', ''), 'custom');
  v_id uuid := nullif(p ->> 'id', '')::uuid;
begin
  perform app.assert_admin(p_by);
  if v_id is not null then
    select * into i from owner_invoices where id = v_id for update;
    if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
    if i.status <> 'draft' then
      raise exception 'Invoice % is %: an issued invoice is never edited. Void it with a reason and issue a corrected one.', i.invoice_number, replace(i.status, '_', ' ') using errcode = '23514';
    end if;
  else
    select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
    if v.id is null then raise exception 'Choose the car the invoice is for' using errcode = '22023'; end if;
    if v.supply_type <> 'program_owner' then raise exception 'Only a program owner''s car has owner invoices' using errcode = '23514'; end if;
    if v_kind not in ('custom', 'upfront', 'tracker_install', 'adjustment') then raise exception 'Unknown kind of invoice' using errcode = '22023'; end if;
    if v_kind = 'upfront' and exists (select 1 from owner_invoices x where x.vehicle_id = v.id and x.kind = 'upfront' and x.status <> 'void') then
      raise exception 'This car already has a first and last month invoice (%). Void it to replace it.',
        (select x.invoice_number from owner_invoices x where x.vehicle_id = v.id and x.kind = 'upfront' and x.status <> 'void' limit 1) using errcode = '23505';
    end if;
    if v_kind = 'tracker_install' and exists (select 1 from owner_invoices x where x.vehicle_id = v.id and x.kind = 'tracker_install' and x.status <> 'void') then
      raise exception 'This car already has a tracker install invoice. Void it to replace it.' using errcode = '23505';
    end if;
    insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, payment_method, status, created_by, application_id)
    values (v.owner_id, v.id, v_kind, app.today(), 'card', 'draft', p_by,
            coalesce(nullif(p ->> 'application_id', '')::uuid, (select ob.application_id from vehicle_onboardings ob where ob.vehicle_id = v.id)))
    returning * into i;
  end if;
  update owner_invoices set title = nullif(left(btrim(coalesce(p ->> 'title', '')), 120), ''), notes = nullif(left(btrim(coalesce(p ->> 'notes', '')), 1000), ''),
         due_on = nullif(p ->> 'due_on', '')::date
   where id = i.id;
  if p ? 'lines' then perform app.oi_write_lines(i.id, p -> 'lines'); end if;
  if not exists (select 1 from owner_invoice_lines where owner_invoice_id = i.id) then raise exception 'Add at least one line' using errcode = '22023'; end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, case when v_id is null then 'owner_invoice_draft_create' else 'owner_invoice_draft_edit' end, 'owner_invoices', i.id::text,
          jsonb_build_object('lines', (select jsonb_agg(jsonb_build_object('d', l.description, 'q', l.quantity, 'u', l.unit_amount_cents, 'hst', l.hst_applies) order by l.sort_order)
                                         from owner_invoice_lines l where l.owner_invoice_id = i.id), 'title', p ->> 'title', 'due_on', p ->> 'due_on'));
  return (select jsonb_build_object('id', x.id, 'invoice_number', x.invoice_number, 'status', x.status, 'total_cents', x.total_cents) from owner_invoices x where x.id = i.id);
end $$;

-- Issue a draft (Admin). quiet: no invoice email (an invoice recorded as already paid gets the receipt only).
create or replace function app.owner_invoice_issue(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
begin
  perform app.assert_admin(p_by);
  select * into i from owner_invoices where id = nullif(p ->> 'id', '')::uuid for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status <> 'draft' then return jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'status', i.status, 'repeat', true); end if;
  if not exists (select 1 from owner_invoice_lines where owner_invoice_id = i.id) then raise exception 'Add at least one line' using errcode = '22023'; end if;
  if i.kind <> 'credit_note' and i.total_cents <= 0 then raise exception 'The total must be above $0.00' using errcode = '22023'; end if;
  if coalesce((p ->> 'quiet')::boolean, false) then perform set_config('app.invoice_quiet', i.id::text, true); end if;
  update owner_invoices set billing_date = app.today(), issued_by = p_by,
         due_on = coalesce(due_on, case when kind in ('custom', 'upfront', 'tracker_install', 'adjustment') then app.today() + (app.settings()).owner_invoice_due_days end),
         status = 'issued'
   where id = i.id returning * into i;
  perform set_config('app.invoice_quiet', '', true);
  if i.kind = 'upfront' then
    update vehicle_onboardings set upfront_invoice_id = i.id where vehicle_id = i.vehicle_id and (upfront_invoice_id is null or upfront_invoice_id = i.replaces_invoice_id);
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_invoice_issue', 'owner_invoices', i.id::text, jsonb_build_object('total_cents', i.total_cents, 'quiet', coalesce((p ->> 'quiet')::boolean, false)));
  return jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'status', i.status, 'total_cents', i.total_cents);
end $$;

-- A draft copy of an invoice's lines (the corrected one after a void).
create or replace function app.oi_copy_draft(p_from uuid, p_by uuid) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  f owner_invoices;
  v_id uuid;
begin
  select * into f from owner_invoices where id = p_from;
  insert into owner_invoices (owner_id, vehicle_id, kind, period_month, days_billed, days_in_month, billing_date, payment_method, status, created_by,
                              title, notes, due_on, replaces_invoice_id, application_id)
  values (f.owner_id, f.vehicle_id, case when f.kind = 'credit_note' then 'custom' else f.kind end, f.period_month, f.days_billed, f.days_in_month, app.today(),
          f.payment_method, 'draft', p_by, f.title, f.notes, null, f.id, f.application_id)
  returning id into v_id;
  insert into owner_invoice_lines (owner_invoice_id, kind, description, amount_cents, hst_applies, hst_cents, vehicle_prepaid_id, quantity, unit_amount_cents, note, sort_order)
  select v_id, l.kind, l.description, l.amount_cents, l.hst_applies, l.hst_cents, l.vehicle_prepaid_id, l.quantity, coalesce(l.unit_amount_cents, l.amount_cents), l.note, l.sort_order
    from owner_invoice_lines l where l.owner_invoice_id = p_from and l.kind <> 'late_fee';
  -- a prepaid credit used again on the corrected invoice
  update vehicle_prepaids p set applied_cents = p.applied_cents - l.amount_cents
    from owner_invoice_lines l where l.owner_invoice_id = v_id and l.kind = 'prepaid_credit' and l.vehicle_prepaid_id = p.id;
  return v_id;
end $$;

-- Void (Admin, a reason): a draft, or an issued invoice nothing was paid on. The scheduled debit is cancelled; a
-- prepaid month it used is released; the owner is told (not for a draft). reissue: a corrected draft is made from it.
create or replace function app.owner_invoice_void(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_old text;
  v_new uuid;
begin
  perform app.assert_admin(p_by);
  if v_reason is null then raise exception 'Give the reason (the owner reads it)' using errcode = '22023'; end if;
  select * into i from owner_invoices where id = nullif(p ->> 'id', '')::uuid for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status = 'void' then return jsonb_build_object('id', i.id, 'status', 'void', 'repeat', true); end if;
  if i.status in ('processing', 'retry_processing') then
    raise exception 'A debit of invoice % is processing: wait for its result', i.invoice_number using errcode = '23514';
  end if;
  if i.paid_cents > 0 or i.deducted_cents > 0 or i.status not in ('draft', 'issued', 'failed') then
    raise exception 'Invoice % has money paid or deducted on it. Void the payment recorded by hand first, or issue a credit note.', i.invoice_number using errcode = '23514';
  end if;
  v_old := i.status;
  update owner_debit_attempts set status = 'canceled', skip_reason = 'invoice voided: ' || v_reason where owner_invoice_id = i.id and status = 'scheduled';
  update vehicle_prepaids p set applied_cents = p.applied_cents + l.amount_cents
    from owner_invoice_lines l where l.owner_invoice_id = i.id and l.kind = 'prepaid_credit' and l.vehicle_prepaid_id = p.id;
  update owner_invoices set status = 'void', void_reason = v_reason, voided_at = now(), voided_by = p_by, debit_on = null where id = i.id;
  update vehicle_onboardings set upfront_invoice_id = null where upfront_invoice_id = i.id;
  if v_old <> 'draft' then
    perform app.ntf_emit('owner_invoice_voided', 'owner_invoice', i.id, 'void', jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id));
  end if;
  if coalesce((p ->> 'reissue')::boolean, false) then v_new := app.oi_copy_draft(i.id, p_by); end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, 'owner_invoice_void', 'owner_invoices', i.id::text, jsonb_build_object('status', v_old), jsonb_build_object('reason', v_reason, 'replacement', v_new));
  return jsonb_build_object('id', i.id, 'status', 'void', 'replacement_id', v_new,
                            'replacement_number', (select invoice_number from owner_invoices where id = v_new));
end $$;

-- A credit note for a paid invoice (Admin, a reason): its own numbered record, issued at once; the amount is refunded
-- or set against a later invoice by hand.
create or replace function app.owner_invoice_credit_note(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
  v_id uuid;
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
  v_amt bigint := nullif(p ->> 'amount_cents', '')::bigint;
  c owner_invoices;
begin
  perform app.assert_admin(p_by);
  if v_reason is null then raise exception 'Give the reason (the owner reads it)' using errcode = '22023'; end if;
  select * into i from owner_invoices where id = nullif(p ->> 'id', '')::uuid for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.kind = 'credit_note' or i.paid_cents + i.deducted_cents <= 0 then raise exception 'A credit note is for an invoice that was paid' using errcode = '23514'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter the amount to credit, before HST' using errcode = '22023'; end if;
  if v_amt > i.fees_cents + i.late_fee_cents then raise exception 'The credit cannot be more than the invoice' using errcode = '22023'; end if;
  insert into owner_invoices (owner_id, vehicle_id, kind, billing_date, payment_method, status, created_by, title, notes, credit_for_invoice_id, application_id)
  values (i.owner_id, i.vehicle_id, 'credit_note', app.today(), i.payment_method, 'draft', p_by, 'Credit note for ' || i.invoice_number, v_reason, i.id, i.application_id)
  returning id into v_id;
  perform app.oi_write_lines(v_id, jsonb_build_array(jsonb_build_object('kind', 'credit', 'description', 'Credit for invoice ' || i.invoice_number || ': ' || v_reason,
                                                                        'quantity', 1, 'unit_amount_cents', -v_amt, 'hst', coalesce((p ->> 'hst')::boolean, i.hst_cents <> 0))));
  update owner_invoices set status = 'issued', issued_by = p_by where id = v_id returning * into c;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_invoice_credit_note', 'owner_invoices', i.id::text, jsonb_build_object('credit_note', c.invoice_number, 'amount_cents', v_amt, 'reason', v_reason));
  return jsonb_build_object('id', c.id, 'invoice_number', c.invoice_number, 'total_cents', c.total_cents);
end $$;

-- Send the invoice email again (Admin).
create or replace function app.owner_invoice_resend(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  i owner_invoices;
begin
  perform app.assert_admin(p_by);
  select * into i from owner_invoices where id = nullif(p ->> 'id', '')::uuid for update;
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  if i.status in ('draft', 'void') then raise exception 'A % invoice is not sent', i.status using errcode = '23514'; end if;
  update owner_invoices set email_count = email_count + 1, last_emailed_at = now() where id = i.id returning * into i;
  perform app.ntf_emit(case i.kind when 'upfront' then 'owner_upfront_invoice' when 'monthly' then 'owner_fee_invoice' else 'owner_invoice_issued' end,
                       'owner_invoice', i.id, 'resend:' || i.email_count, jsonb_build_object('owner_id', i.owner_id, 'vehicle_id', i.vehicle_id, 'resend', true));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'owner_invoice_resend', 'owner_invoices', i.id::text, jsonb_build_object('n', i.email_count));
  return jsonb_build_object('id', i.id, 'sent', i.email_count);
end $$;

-- The invoice emails (0044's trigger function, same behaviour) plus: an invoice made by hand gets its own email when
-- issued; an invoice issued quietly (recorded as already paid) gets none.
create or replace function app.ntf_owner_invoices_after() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  pl jsonb := jsonb_build_object('owner_id', new.owner_id, 'vehicle_id', new.vehicle_id);
  v_att text := nullif(current_setting('app.debit_attempt_no', true), '');
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return null; end if;
  if new.status = 'issued' and coalesce(current_setting('app.invoice_quiet', true), '') = new.id::text then return null; end if;
  if new.status = 'issued' and new.kind = 'upfront' and (tg_op = 'INSERT' or old.status = 'draft') then
    perform app.ntf_emit('owner_upfront_invoice', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'issued' and new.kind = 'monthly' and (tg_op = 'INSERT' or old.status = 'draft') then
    perform app.ntf_emit('owner_fee_invoice', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'issued' and new.kind in ('custom', 'credit_note') and (tg_op = 'INSERT' or old.status = 'draft') then
    perform app.ntf_emit('owner_invoice_issued', 'owner_invoice', new.id, 'issued', pl);
  elsif new.status = 'paid' then
    if nullif(current_setting('app.manual_payment', true), '') is null then
      perform app.ntf_emit('owner_payment_received', 'owner_invoice', new.id, 'paid', pl);
    end if;
  elsif new.status = 'failed' then
    if tg_op = 'UPDATE' and old.status = 'paid' then return null; end if;
    if coalesce(current_setting('app.debit_no_retry', true), '') = new.id::text then return null; end if;
    perform app.ntf_emit('owner_payment_failed', 'owner_invoice', new.id, 'failed' || case when coalesce(v_att, '1') <> '1' then ':' || v_att else '' end, pl);
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', new.id, 'failed' || case when coalesce(v_att, '1') <> '1' then ':' || v_att else '' end, pl);
  elsif new.status = 'in_arrears' then
    if tg_op = 'UPDATE' and old.status = 'paid' then return null; end if;
    perform app.ntf_emit('owner_in_arrears', 'owner_invoice', new.id, 'in_arrears', pl);
    perform app.ntf_emit('staff_owner_invoice_failed', 'owner_invoice', new.id, 'in_arrears',
                         pl || jsonb_build_object('_immediate_roles', jsonb_build_array('staff_admin')));
  end if;
  return null;
end $$;

-- Lines as the owner and the Admin read them.
create or replace function app.oi_lines_json(p_invoice uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'kind', l.kind, 'description', coalesce(l.description, initcap(replace(l.kind, '_', ' '))),
            'quantity', l.quantity, 'unit_amount_cents', coalesce(l.unit_amount_cents, l.amount_cents), 'amount_cents', l.amount_cents,
            'hst', l.hst_applies, 'hst_cents', l.hst_cents, 'note', l.note)
            order by l.sort_order, array_position(array['install_fee', 'first_month_insurance', 'last_month_insurance', 'insurance_fee', 'tracker_fee',
                                                         'registration_fee', 'custom', 'adjustment', 'credit', 'prepaid_credit', 'late_fee'], l.kind), l.created_at, l.id), '[]'::jsonb)
    from owner_invoice_lines l where l.owner_invoice_id = p_invoice
$$;

-- One row of a list.
create or replace function app.oi_row(i owner_invoices) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'owner_id', i.owner_id, 'owner_name', (select o.legal_name from owners o where o.id = i.owner_id),
    'vehicle_id', i.vehicle_id, 'vehicle_name', app.vehicle_name(i.vehicle_id), 'kind', i.kind, 'kind_label', app.oi_label(i.kind), 'title', i.title,
    'period_month', i.period_month, 'status', i.status, 'total_cents', i.total_cents, 'balance_cents', i.balance_cents, 'paid_cents', i.paid_cents,
    'billing_date', i.billing_date, 'issued_at', i.issued_at, 'due_on', i.due_on, 'paid_at', i.paid_at, 'created_at', i.created_at,
    'void_reason', i.void_reason, 'replaces', (select x.invoice_number from owner_invoices x where x.id = i.replaces_invoice_id),
    'replaced_by', (select x.invoice_number from owner_invoices x where x.replaces_invoice_id = i.id order by x.created_at desc limit 1),
    'credit_for', (select x.invoice_number from owner_invoices x where x.id = i.credit_for_invoice_id),
    'partly_paid', i.status not in ('paid', 'void') and i.paid_cents > 0,
    'pending', exists (select 1 from payments p where p.owner_invoice_id = i.id and p.status = 'pending'),
    'application_number', (select a.application_number from owner_applications a
                             where a.id = coalesce(i.application_id, (select ob.application_id from vehicle_onboardings ob where ob.vehicle_id = i.vehicle_id))))
$$;

-- Every invoice of an owner, an application or everyone (drafts included; Admin).
create or replace function app.owner_invoices_admin(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_owner uuid := nullif(p ->> 'owner_id', '')::uuid;
  v_app uuid := nullif(p ->> 'application_id', '')::uuid;
  v_status text := nullif(p ->> 'status', '');
  v_q text := nullif(lower(btrim(coalesce(p ->> 'q', ''))), '');
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object(
    'rows', coalesce((select jsonb_agg(app.oi_row(i) order by i.created_at desc, i.invoice_number desc)
              from owner_invoices i
             where (v_owner is null or i.owner_id = v_owner)
               and (v_app is null or i.application_id = v_app
                    or i.vehicle_id in (select ob.vehicle_id from vehicle_onboardings ob where ob.application_id = v_app))
               and (v_status is null or i.status = v_status
                    or (v_status = 'open' and i.status in ('issued', 'failed', 'in_arrears', 'processing', 'retry_processing', 'partially_deducted'))
                    or (v_status = 'partly_paid' and i.status not in ('paid', 'void') and i.paid_cents > 0))
               and (v_q is null or lower(i.invoice_number) like '%' || v_q || '%'
                    or exists (select 1 from owners o where o.id = i.owner_id and lower(o.legal_name) like '%' || v_q || '%'))), '[]'::jsonb),
    'counts', (select jsonb_build_object('draft', count(*) filter (where i.status = 'draft'), 'open', count(*) filter (where i.status in ('issued', 'failed', 'in_arrears', 'processing', 'retry_processing', 'partially_deducted')),
                      'paid', count(*) filter (where i.status = 'paid'), 'void', count(*) filter (where i.status = 'void'))
                 from owner_invoices i where (v_owner is null or i.owner_id = v_owner)
                   and (v_app is null or i.application_id = v_app or i.vehicle_id in (select ob.vehicle_id from vehicle_onboardings ob where ob.application_id = v_app))),
    'cars', (select coalesce(jsonb_agg(jsonb_build_object('id', v.id, 'name', app.vehicle_name(v.id), 'owner_id', v.owner_id) order by v.created_at), '[]'::jsonb)
               from vehicles v where v.supply_type = 'program_owner' and v.status not in ('declined', 'exited')
                 and ((v_owner is not null and v.owner_id = v_owner) or (v_app is not null and v.id in (select ob.vehicle_id from vehicle_onboardings ob where ob.application_id = v_app)))));
end $$;

-- One invoice for the Admin: lines, payments, receipts, debits, emails, history, what can be done.
create or replace function app.owner_invoice_admin(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  i owner_invoices;
begin
  perform app.assert_admin(p_by);
  select * into i from owner_invoices where id::text = p ->> 'id' or invoice_number = upper(btrim(coalesce(p ->> 'id', '')));
  if i.id is null then raise exception 'Invoice not found' using errcode = 'P0002'; end if;
  return app.oi_row(i) || jsonb_build_object(
    'notes', i.notes, 'fees_cents', i.fees_cents, 'hst_cents', i.hst_cents, 'late_fee_cents', i.late_fee_cents, 'deducted_cents', i.deducted_cents,
    'voided_at', i.voided_at, 'voided_by', (select u.full_name from users u where u.id = i.voided_by), 'email_count', i.email_count, 'last_emailed_at', i.last_emailed_at,
    'owner_email', (select o.email from owners o where o.id = i.owner_id),
    'lines', app.oi_lines_json(i.id),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'method', x.method, 'method_label', app.payment_method_label(x.method), 'status', x.status,
                   'amount_cents', x.amount_cents, 'created_at', x.created_at, 'processed_at', x.processed_at, 'card_last4', x.card_last4,
                   'receipt', x.status = 'succeeded' and x.kind in ('charge', 'capture')) order by x.created_at), '[]'::jsonb)
                   from payments x where x.owner_invoice_id = i.id),
    'manual', app.manual_payments_json(i.id),
    'debits', (select coalesce(jsonb_agg(jsonb_build_object('attempt_no', a.attempt_no, 'debit_on', a.debit_on, 'amount_cents', a.amount_cents, 'status', a.status,
                 'skip_reason', a.skip_reason, 'failure_message', a.failure_message) order by a.attempt_no), '[]'::jsonb)
                 from owner_debit_attempts a where a.owner_invoice_id = i.id),
    'debit', app.owner_invoice_debit(i.id),
    'emails', (select coalesce(jsonb_agg(jsonb_build_object('code', e.code, 'at', e.created_at, 'processed', e.processed_at is not null) order by e.created_at), '[]'::jsonb)
                 from app_events e where e.entity_id = i.id and e.code like 'owner\_%'),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('action', l.action, 'at', l.at, 'by', (select u.full_name from users u where u.id = l.actor_user_id),
                  'after', l.after) order by l.at), '[]'::jsonb)
                  from audit_log l where l.entity_table = 'owner_invoices' and l.entity_id = i.id::text
                   and (l.action like 'owner_invoice%' or l.action in ('record_manual_payment', 'void_manual_payment'))),
    'credit_notes', (select coalesce(jsonb_agg(jsonb_build_object('invoice_number', x.invoice_number, 'id', x.id, 'total_cents', x.total_cents)), '[]'::jsonb)
                       from owner_invoices x where x.credit_for_invoice_id = i.id),
    'can', jsonb_build_object('edit', i.status = 'draft', 'issue', i.status = 'draft', 'void', i.status in ('draft', 'issued', 'failed') and i.paid_cents = 0 and i.deducted_cents = 0,
                              'credit', i.kind <> 'credit_note' and i.paid_cents + i.deducted_cents > 0,
                              'record_payment', i.status in ('issued', 'failed', 'in_arrears', 'partially_deducted') and i.balance_cents > 0
                                                and not exists (select 1 from payments x where x.owner_invoice_id = i.id and x.status = 'pending'),
                              'resend', i.status not in ('draft', 'void')));
end $$;

-- The owner portal: the exact lines (quantity, unit, HST), the title, notes, due date and a void's reason.
alter function app.owner_invoice_view(uuid) rename to owner_invoice_view_pre_ot;
create or replace function app.owner_invoice_view(p_invoice uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.owner_invoice_view_pre_ot(p_invoice) || jsonb_build_object(
    'lines', app.oi_lines_json(p_invoice), 'title', i.title, 'notes', i.notes, 'due_on', i.due_on, 'kind_label', app.oi_label(i.kind),
    'void_reason', i.void_reason, 'voided_at', i.voided_at,
    'replaced_by', (select x.invoice_number from owner_invoices x where x.replaces_invoice_id = i.id and x.status <> 'draft' order by x.created_at desc limit 1),
    'replaces', (select x.invoice_number from owner_invoices x where x.id = i.replaces_invoice_id),
    'credit_for', (select x.invoice_number from owner_invoices x where x.id = i.credit_for_invoice_id))
    from owner_invoices i where i.id = p_invoice
$$;
alter function app.owner_portal_invoices(uuid) rename to owner_portal_invoices_pre_ot;
create or replace function app.owner_portal_invoices(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(x || jsonb_build_object('title', i.title, 'due_on', i.due_on, 'kind_label', app.oi_label(i.kind), 'void_reason', i.void_reason)), '[]'::jsonb)
    from jsonb_array_elements(app.owner_portal_invoices_pre_ot(p_by)) x join owner_invoices i on i.id = (x ->> 'id')::uuid
$$;

-- The invoice PDF (Admins and Finance; the owner their own issued invoices). Rendered on each request, never stored:
-- an invoice can still be paid or voided.
alter function app.file_access(uuid, text, text) rename to file_access_pre_ot;
create or replace function app.file_access(p_user uuid, p_kind text, p_key text) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_kind = 'owner_invoice' then
    return p_user is not null and (app.user_runs_finance(p_user)
      or exists (select 1 from owner_invoices i join owners o on o.id = i.owner_id where i.id = app.file_key_id(p_key) and i.status <> 'draft' and o.user_id = p_user));
  end if;
  return app.file_access_pre_ot(p_user, p_kind, p_key);
end $$;
alter function app.pdf_facts(text, text, uuid) rename to pdf_facts_pre_ot;
create or replace function app.pdf_facts(p_kind text, p_key text, p_user uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  i owner_invoices;
  o owners;
begin
  if p_kind <> 'owner_invoice' then return app.pdf_facts_pre_ot(p_kind, p_key, p_user); end if;
  select * into i from owner_invoices where id = app.file_key_id(p_key);
  if i.id is null then return null; end if;
  select * into o from owners where id = i.owner_id;
  return jsonb_build_object('final', i.status <> 'draft', 'store', false, 'draft', i.status = 'draft',
    'title', case when i.kind = 'credit_note' then 'Credit note ' else 'Invoice ' end || i.invoice_number,
    'file_name', 'carmacars-' || lower(i.invoice_number) || '.pdf', 'invoice_number', i.invoice_number, 'kind_label', app.oi_label(i.kind), 'subject', i.title,
    'status', i.status, 'issued_at', coalesce(i.issued_at, i.created_at), 'due_on', i.due_on, 'period_month', i.period_month, 'notes', i.notes,
    'void_reason', i.void_reason, 'vehicle', app.vehicle_name(i.vehicle_id), 'plate', (select v.plate from vehicles v where v.id = i.vehicle_id),
    'owner', jsonb_build_object('legal_name', o.legal_name, 'address', concat_ws(', ', o.address_line1, o.address_line2, o.city, o.province, o.postal_code), 'hst_number', o.hst_number),
    'lines', app.oi_lines_json(i.id), 'fees_cents', i.fees_cents, 'hst_cents', i.hst_cents, 'late_fee_cents', i.late_fee_cents, 'total_cents', i.total_cents,
    'paid_cents', i.paid_cents, 'deducted_cents', i.deducted_cents, 'balance_cents', i.balance_cents,
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('method', app.payment_method_label(x.method), 'amount_cents', x.amount_cents,
                   'on', coalesce((select m.received_on::text from manual_payments m where m.payment_id = x.id), app.local_date(coalesce(x.processed_at, x.created_at))::text))
                   order by x.created_at), '[]'::jsonb) from payments x where x.owner_invoice_id = i.id and x.status = 'succeeded'),
    'credit_for', (select x.invoice_number from owner_invoices x where x.id = i.credit_for_invoice_id),
    'replaces', (select x.invoice_number from owner_invoices x where x.id = i.replaces_invoice_id),
    'payee', app.owner_payee_name(), 'company', app.doc_company());
end $$;

-- The first and last month invoice made by the older paths (owner page "Issue", signing) bills the amount agreed on the
-- Vehicle Schedule when it is not 2 x the Insurance Fee (0046's wrapper, same signature).
alter function app.issue_upfront_invoice(uuid, uuid) rename to issue_upfront_invoice_pre_ot;
create or replace function app.issue_upfront_invoice(p_vehicle uuid, p_by uuid default null)
returns uuid language plpgsql security definer set search_path = public, app as $$
declare
  v_id uuid := app.issue_upfront_invoice_pre_ot(p_vehicle, p_by);
  s vehicle_schedules;
  v_bps integer := (app.settings()).hst_bps;
begin
  select * into s from vehicle_schedules where vehicle_id = p_vehicle and superseded_by is null;
  if s.first_last_cents is not null and s.first_last_cents <> 2 * s.insurance_fee_cents then
    update owner_invoice_lines set amount_cents = s.first_last_cents / 2, unit_amount_cents = s.first_last_cents / 2, hst_cents = public.calc_hst(s.first_last_cents / 2, v_bps)
     where owner_invoice_id = v_id and kind = 'first_month_insurance';
    update owner_invoice_lines set amount_cents = s.first_last_cents - s.first_last_cents / 2, unit_amount_cents = s.first_last_cents - s.first_last_cents / 2,
           hst_cents = public.calc_hst(s.first_last_cents - s.first_last_cents / 2, v_bps)
     where owner_invoice_id = v_id and kind = 'last_month_insurance';
  end if;
  return v_id;
end $$;

-- ================================================================ 4. approve: terms and the first invoices, confirmed per car
alter table owner_applications
  add column if not exists entered_by uuid references users (id),
  add column if not exists entered_by_name text,
  add column if not exists sourced_by uuid references users (id),
  add column if not exists signing_method text check (signing_method in ('email', 'paper')),
  add column if not exists plan jsonb,
  add column if not exists setup_emailed_at timestamptz;
comment on column owner_applications.entered_by is 'Staff who entered the application for the owner (0067): "Entered by staff: <name>"';
comment on column owner_applications.sourced_by is 'Staff who said they sourced this owner (0067); null: entered for CarmaCars. Only then is the owner recorded as recruited by them';
comment on column owner_applications.plan is 'The terms and first invoices staff proposed per car (0067), the starting point of the Approve step';

-- One invoice of the Approve step for one car: made as a draft, then sent, kept as a draft, or recorded as paid.
-- inv: {type: first_last | registration | tracker_install | custom, amount_cents?, lines?, title?, due_on?, notes?,
--       action: send | draft | paid, payment: {method, received_on, reference, amount_cents, note}}
create or replace function app.oi_plan_invoice(p_by uuid, p_vehicle uuid, p_terms jsonb, inv jsonb, p_application uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_type text := coalesce(nullif(inv ->> 'type', ''), 'custom');
  v_action text := coalesce(nullif(inv ->> 'action', ''), 'draft');
  v_lines jsonb := inv -> 'lines';
  v_fl bigint;
  v_kind text;
  d jsonb;
  v_id uuid;
  r jsonb;
begin
  if v_action not in ('send', 'draft', 'paid') then raise exception 'Choose send now, save as a draft or already paid' using errcode = '22023'; end if;
  if v_type = 'first_last' then
    v_kind := 'upfront';
    v_fl := coalesce(nullif(inv ->> 'amount_cents', '')::bigint, (p_terms ->> 'first_last_cents')::bigint);
    if v_fl is null or v_fl <= 0 then raise exception 'Enter the first and last month amount' using errcode = '22023'; end if;
    if jsonb_typeof(coalesce(v_lines, 'null')) <> 'array' or jsonb_array_length(v_lines) = 0 then
      v_lines := jsonb_build_array(
        jsonb_build_object('kind', 'first_month_insurance', 'description', 'First month''s Insurance Fee', 'quantity', 1, 'unit_amount_cents', v_fl / 2, 'hst', true),
        jsonb_build_object('kind', 'last_month_insurance', 'description', 'Last month''s Insurance Fee', 'quantity', 1, 'unit_amount_cents', v_fl - v_fl / 2, 'hst', true));
    end if;
  elsif v_type = 'registration' then
    v_kind := 'custom';
    if nullif(inv ->> 'amount_cents', '') is null and v_lines is null then raise exception 'Enter the registration fee' using errcode = '22023'; end if;
    v_lines := coalesce(v_lines, jsonb_build_array(jsonb_build_object('kind', 'registration_fee', 'description', 'Registration fee', 'quantity', 1,
                                                                      'unit_amount_cents', (inv ->> 'amount_cents')::bigint, 'hst', coalesce((inv ->> 'hst')::boolean, true))));
    inv := inv || jsonb_build_object('title', coalesce(nullif(inv ->> 'title', ''), 'Registration fee'));
  elsif v_type = 'tracker_install' then
    if not coalesce((app.settings()).trackers_available, false) then
      raise exception 'Trackers are not available yet: the Tracker Install invoice is made when they arrive' using errcode = '23514';
    end if;
    v_kind := 'tracker_install';
    v_lines := coalesce(v_lines, jsonb_build_array(jsonb_build_object('kind', 'install_fee', 'description', 'Tracker Install Fee', 'quantity', 1,
                         'unit_amount_cents', coalesce(nullif(inv ->> 'amount_cents', '')::bigint, (p_terms ->> 'install_fee_cents')::bigint), 'hst', true)));
  elsif v_type = 'custom' then
    v_kind := 'custom';
  else
    raise exception 'Unknown invoice %', v_type using errcode = '22023';
  end if;
  d := app.owner_invoice_draft_save(p_by, jsonb_build_object('vehicle_id', p_vehicle, 'kind', v_kind, 'title', inv ->> 'title', 'notes', inv ->> 'notes',
                                                             'due_on', inv ->> 'due_on', 'application_id', p_application, 'lines', v_lines));
  v_id := (d ->> 'id')::uuid;
  if v_action = 'send' then
    perform app.owner_invoice_issue(p_by, jsonb_build_object('id', v_id));
  elsif v_action = 'paid' then
    perform app.owner_invoice_issue(p_by, jsonb_build_object('id', v_id, 'quiet', true));
    perform app.record_manual_payment(p_by, coalesce(inv -> 'payment', '{}'::jsonb) || jsonb_build_object('invoice', v_id::text));
  end if;
  select jsonb_build_object('id', i.id, 'invoice_number', i.invoice_number, 'type', v_type, 'action', v_action, 'status', i.status, 'total_cents', i.total_cents,
                            'balance_cents', i.balance_cents) into r from owner_invoices i where i.id = v_id;
  return r;
end $$;

-- What the Approve step shows for each car: the terms that apply with where each comes from, the grid, what staff
-- proposed, the invoices already made, and whether trackers are available.
create or replace function app.application_approve_plan(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a owner_applications;
begin
  perform app.assert_admin(p_by);
  select * into a from owner_applications where id = nullif(p ->> 'id', '')::uuid;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  return jsonb_build_object('id', a.id, 'application_number', a.application_number, 'status', a.status, 'plan', a.plan,
    'trackers_available', coalesce((app.settings()).trackers_available, false), 'today', app.today(),
    'entered_by_name', a.entered_by_name, 'signing_method', a.signing_method,
    'cars', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'onboarding_status', ob.status,
               'mode', coalesce(ob.proposed_management_mode, v.management_mode), 'method', ob.proposed_onboarding_method, 'shareholder', v.is_shareholder_owned,
               'options', (select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) from app.onboarding_options(ob.held_by, ob.title_status, coalesce(ob.proposed_management_mode, v.management_mode)) x),
               'terms', app.owner_terms_resolve(v.id),
               'pending_terms', ob.pending_terms,
               'invoices', (select coalesce(jsonb_agg(app.oi_row(i) order by i.created_at), '[]'::jsonb) from owner_invoices i where i.vehicle_id = v.id and i.status <> 'void'))
               order by v.created_at), '[]'::jsonb)
               from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
              where ob.application_id = a.id or (v.owner_id = a.owner_id and ob.status = 'intake' and ob.application_id is null)));
end $$;

-- Approve (replaces 0054's, same signature). p: {id, cars: [{vehicle_id, terms: {management_mode, onboarding_method,
-- insurance_fee_cents, tracker_fee_cents, revenue_share_bps, install_fee_cents, first_last_cents, one_off_fees,
-- special_terms}, invoices: [...]}], no_email}. Each car at intake gets its terms (the negotiated defaults where
-- nothing is given); only the invoices the Admin confirmed are made, each sent, kept as a draft or recorded as paid.
-- Without cars nothing is invoiced. An application staff entered for the owner gets the set-up email instead
-- (app.owner_setup_email, after the server made the sign-in link); the others get owner_application_approved.
create or replace function app.application_approve(p_admin uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
  r record;
  c jsonb;
  t jsonb;
  res jsonb;
  inv jsonb;
  v_terms jsonb := '[]'::jsonb;
  v_invoices jsonb := '[]'::jsonb;
  v_out jsonb;
  o owners;
begin
  perform app.assert_admin(p_admin);
  select * into a from owner_applications where id = (p ->> 'id')::uuid for update;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  if a.status = 'approved' then return jsonb_build_object('id', a.id, 'repeat', true); end if;
  if a.status = 'declined' then raise exception 'This application was declined' using errcode = '23514'; end if;
  update owners set status = 'active' where id = a.owner_id and status = 'lead';
  for r in select v.id, v.is_shareholder_owned from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
            where v.owner_id = a.owner_id and ob.status = 'intake' order by v.created_at loop
    c := (select x from jsonb_array_elements(coalesce(p -> 'cars', '[]'::jsonb)) x where x ->> 'vehicle_id' = r.id::text limit 1);
    res := app.owner_terms_resolve(r.id, null, null, nullif(c #>> '{terms,management_mode}', '')::management_mode);
    t := jsonb_strip_nulls(jsonb_build_object(
      'management_mode', c #>> '{terms,management_mode}', 'onboarding_method', c #>> '{terms,onboarding_method}', 'special_terms', c #>> '{terms,special_terms}',
      'insurance_fee_cents', coalesce(c #>> '{terms,insurance_fee_cents}', res ->> 'insurance_fee_cents'),
      'tracker_fee_cents', coalesce(c #>> '{terms,tracker_fee_cents}', res ->> 'tracker_fee_cents'),
      'revenue_share_bps', coalesce(c #>> '{terms,revenue_share_bps}', res ->> 'revenue_share_bps'),
      'install_fee_cents', coalesce(c #>> '{terms,install_fee_cents}', res ->> 'install_fee_cents')));
    v_out := app.admin_set_vehicle_terms(r.id, p_admin, t) - 'schedule';
    if not r.is_shareholder_owned then
      -- the first and last month amount and the one-off fees agreed, on the Vehicle Schedule and as the car's terms
      update vehicle_schedules set first_last_cents = case when nullif(c #>> '{terms,first_last_cents}', '') is not null
                                                           and (c #>> '{terms,first_last_cents}')::bigint <> 2 * insurance_fee_cents
                                                           then (c #>> '{terms,first_last_cents}')::bigint
                                                           when (res #>> '{sources,first_last_cents}') in ('car', 'owner') then (res ->> 'first_last_cents')::bigint end,
             one_off_fees = coalesce(app.ot_one_off(c #> '{terms,one_off_fees}'), '[]'::jsonb)
       where vehicle_id = r.id and superseded_by is null and signed_at is null;
      if c ? 'terms' then
        perform app.ot_terms_row(p_admin, a.owner_id, r.id, (c -> 'terms') || jsonb_build_object('note', 'Agreed at approval of ' || a.application_number), app.today());
      end if;
    end if;
    v_terms := v_terms || jsonb_build_array(v_out || jsonb_build_object('first_last_cents',
                 (select coalesce(s.first_last_cents, 2 * s.insurance_fee_cents) from vehicle_schedules s where s.vehicle_id = r.id and s.superseded_by is null)));
    for inv in select value from jsonb_array_elements(coalesce(c -> 'invoices', '[]'::jsonb)) loop
      v_invoices := v_invoices || jsonb_build_array(app.oi_plan_invoice(p_admin, r.id,
                      t || jsonb_build_object('first_last_cents', (select coalesce(s.first_last_cents, 2 * s.insurance_fee_cents) from vehicle_schedules s where s.vehicle_id = r.id and s.superseded_by is null)),
                      inv, a.id));
    end loop;
  end loop;
  update owner_applications set status = 'approved', decided_at = now(), decided_by = p_admin where id = a.id returning * into a;
  insert into owner_application_notes (application_id, body, kind, created_by)
  values (a.id, format('Approved: terms set for %s car(s); invoices: %s.', jsonb_array_length(v_terms),
                       coalesce((select string_agg(format('%s %s (%s)', x ->> 'invoice_number', app.fmt_money((x ->> 'total_cents')::bigint),
                                                          case x ->> 'action' when 'send' then 'sent' when 'paid' then 'recorded as paid' else 'draft' end), ', ')
                                   from jsonb_array_elements(v_invoices) x), 'none')), 'decision', p_admin);
  select * into o from owners where id = a.owner_id;
  if a.entered_by is null and not coalesce((p ->> 'no_email')::boolean, false) then
    perform app.ntf_emit('owner_application_approved', 'owner_application', a.id, 'approved', jsonb_build_object('owner_id', a.owner_id));
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_admin, 'application_approve', 'owner_applications', a.id::text, jsonb_build_object('terms', jsonb_array_length(v_terms), 'invoices', v_invoices));
  return jsonb_build_object('id', a.id, 'status', a.status, 'terms', v_terms, 'invoices', v_invoices,
    'setup', case when a.entered_by is not null then jsonb_build_object('needed', coalesce(a.signing_method, 'email') = 'email' and not coalesce((p ->> 'no_email')::boolean, false),
                     'owner_id', o.id, 'has_account', o.user_id is not null, 'email', o.email, 'name', o.legal_name, 'application_id', a.id) end);
end $$;

-- ================================================================ 5. staff add a car for an owner
-- p: {owner_id?, owner: {...new owner}, vehicle: {...as app.add_owner_vehicle}, sourced: boolean, signing: email | paper,
--     note, cars_plan: {terms, invoices} (the Approve step's values for this car)}.
-- Admin, customer service and fleet. The same records as the owner's own application, "Entered by staff: <name>"; the
-- owner's application emails are not sent (one set-up email goes when it is approved). An Admin's entry is approved at
-- once with the terms and invoices given; an assistant's waits in Applications for an Admin, with their proposal.
create or replace function app.staff_add_owner_car(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_admin boolean := app.user_is_admin(p_by);
  v_name text := (select coalesce(u.full_name, u.email) from users u where u.id = p_by);
  res jsonb;
  a owner_applications;
  v_vehicle uuid;
  v_onb uuid;
  v_signing text := coalesce(nullif(p ->> 'signing', ''), 'email');
  v_approve jsonb;
begin
  if not (v_admin or app.user_va_has(p_by, 'cs', 'fleet')) then
    raise exception 'Only an Admin, customer service or fleet adds a car for an owner' using errcode = '42501';
  end if;
  if v_signing not in ('email', 'paper') then raise exception 'Choose how the owner signs' using errcode = '22023'; end if;
  if jsonb_typeof(coalesce(p -> 'vehicle', 'null')) <> 'object' then raise exception 'Enter the car' using errcode = '22023'; end if;
  if nullif(p ->> 'owner_id', '') is null and nullif(btrim(coalesce(p #>> '{owner,email}', '')), '') is null and v_signing = 'email' then
    raise exception 'Enter the owner''s email address: the set-up email goes there' using errcode = '22023';
  end if;
  res := app.submit_owner_application(jsonb_strip_nulls(jsonb_build_object('owner_id', nullif(p ->> 'owner_id', ''), 'owner', coalesce(p -> 'owner', '{}'::jsonb),
           'vehicles', jsonb_build_array(p -> 'vehicle'), 'source', 'staff', 'note', concat_ws('. ', 'Entered by staff: ' || v_name, nullif(btrim(coalesce(p ->> 'note', '')), '')))), p_by);
  v_vehicle := (res #>> '{vehicles,0,vehicle_id}')::uuid;
  v_onb := (res #>> '{vehicles,0,onboarding_id}')::uuid;
  if coalesce((res #>> '{vehicles,0,declined}')::boolean, false) then
    raise exception 'A car with a rebuilt, salvage or irreparable brand is not eligible (Enrollment Agreement 3.1)' using errcode = '23514';
  end if;
  -- the owner hears from us once, when the car is set up; the sales notice is not needed for staff's own entry
  update app_events set processed_at = now(), process_note = 'entered by staff (0067): one set-up email instead'
   where entity_id = v_onb and code in ('owner_application_received', 'staff_owner_application_received') and processed_at is null;
  update vehicles set added_by = p_by where id = v_vehicle;
  update owner_applications set entered_by = p_by, entered_by_name = v_name, signing_method = v_signing,
         sourced_by = case when coalesce((p ->> 'sourced')::boolean, false) then p_by end,
         plan = case when p ? 'plan' then jsonb_build_object(v_vehicle::text, p -> 'plan') end
   where id = (res ->> 'application_id')::uuid returning * into a;
  if coalesce((p ->> 'sourced')::boolean, false) then
    update owners set recruited_by = coalesce(recruited_by, p_by) where id = a.owner_id;
  end if;
  insert into owner_application_notes (application_id, body, kind, created_by)
  values (a.id, format('Entered by staff: %s. %s. Owner signs %s.', v_name,
                       case when coalesce((p ->> 'sourced')::boolean, false) then 'Sourced by ' || v_name else 'Entered for CarmaCars' end,
                       case v_signing when 'paper' then 'on paper' else 'in the owner portal after the set-up email' end), 'note', p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'staff_add_owner_car', 'owner_applications', a.id::text, jsonb_build_object('vehicle_id', v_vehicle, 'owner_id', a.owner_id, 'sourced', a.sourced_by is not null, 'signing', v_signing));
  if v_admin and coalesce((p ->> 'approve')::boolean, true) then
    v_approve := app.application_approve(p_by, jsonb_build_object('id', a.id, 'cars', jsonb_build_array(coalesce(p -> 'plan', '{}'::jsonb) || jsonb_build_object('vehicle_id', v_vehicle))));
  else
    perform app.raise_task(p_type => 'owner_application_staff', p_queue => 'admin',
        p_title => format('Approve %s: entered by %s', a.application_number, v_name),
        p_detail => format('%s added %s for %s. Check the terms and first invoices, then approve.', v_name, app.vehicle_name(v_vehicle), (select legal_name from owners where id = a.owner_id)),
        p_owner => a.owner_id, p_vehicle => v_vehicle, p_related_table => 'owner_applications', p_related_id => a.id,
        p_dedupe => 'owner_application_staff:' || a.id);
  end if;
  return jsonb_build_object('application_id', a.id, 'application_number', a.application_number, 'owner_id', a.owner_id, 'vehicle_id', v_vehicle,
                            'approved', v_approve is not null, 'approve', v_approve, 'owner_missing', res -> 'owner_missing');
end $$;

-- A document staff upload for the owner's car (ownership, insurance, lender): filed as the owner's.
create or replace function app.staff_register_vehicle_document(p_by uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  v vehicles;
  v_id uuid;
  v_kind text := p ->> 'kind';
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into v from vehicles where id = nullif(p ->> 'vehicle_id', '')::uuid;
  if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
  if v_kind not in ('ownership_permit', 'finance_party_permission', 'owner_insurance_proof') then raise exception 'Unknown document %', v_kind using errcode = '22023'; end if;
  if coalesce(p ->> 'mime', '') not in ('image/jpeg', 'image/png', 'application/pdf') or coalesce(lower(p ->> 'sha256'), '') !~ '^[0-9a-f]{64}$'
     or coalesce(p ->> 'path', '') !~ '^owners/' then
    raise exception 'An upload needs its file, its type and its SHA-256' using errcode = '22023';
  end if;
  insert into documents (kind, title, storage_bucket, storage_path, mime_type, sha256, retention, uploaded_by, owner_id, vehicle_id)
  values (v_kind::document_kind, format('%s, %s', case v_kind when 'ownership_permit' then 'Ownership permit' when 'finance_party_permission' then 'Lender or lessor permission'
                                                 else 'Proof of insurance' end, app.vehicle_name(v.id)),
          'documents', p ->> 'path', p ->> 'mime', lower(p ->> 'sha256'), 'records_7y', p_by, v.owner_id, v.id)
  returning id into v_id;
  return v_id;
end $$;

-- The set-up email of a car staff entered (after approval; the server made the sign-in link when the owner has none).
-- Admin. Sent once per application unless "again".
create or replace function app.owner_setup_email(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a owner_applications;
  o owners;
begin
  perform app.assert_admin(p_by);
  select * into a from owner_applications where id = nullif(p ->> 'application_id', '')::uuid for update;
  if a.id is null then raise exception 'Application not found' using errcode = 'P0002'; end if;
  if a.status <> 'approved' then raise exception 'Approve the application first' using errcode = '23514'; end if;
  select * into o from owners where id = a.owner_id;
  if nullif(btrim(coalesce(o.email, '')), '') is null then raise exception 'The owner has no email address on file' using errcode = '23514'; end if;
  if a.setup_emailed_at is not null and not coalesce((p ->> 'again')::boolean, false) then
    return jsonb_build_object('sent', false, 'already', a.setup_emailed_at);
  end if;
  update owner_applications set setup_emailed_at = now() where id = a.id;
  perform app.ntf_emit('owner_car_set_up', 'owner_application', a.id, 'setup:' || to_char(now(), 'YYYYMMDDHH24MISS'),
                       jsonb_build_object('owner_id', a.owner_id, 'password_url', nullif(p ->> 'password_url', '')));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'owner_setup_email', 'owner_applications', a.id::text, jsonb_build_object('with_password_link', nullif(p ->> 'password_url', '') is not null));
  return jsonb_build_object('sent', true);
end $$;

-- The owner checks what staff entered and corrects it before signing: contact details, address, and the car's plate,
-- colour, odometer, insurer and lender. Only while nothing is signed; the documents are made again from the records,
-- and staff get a task to look at the change.
create or replace function app.owner_review_read(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('owner', jsonb_build_object('id', o.id, 'legal_name', o.legal_name, 'email', o.email, 'phone', o.phone, 'address_line1', o.address_line1,
            'address_line2', o.address_line2, 'city', o.city, 'province', o.province, 'postal_code', o.postal_code, 'owner_type', o.owner_type, 'corporation_name', o.corporation_name),
    'cars', (select coalesce(jsonb_agg(jsonb_build_object('vehicle_id', v.id, 'name', app.vehicle_name(v.id), 'vin', v.vin, 'plate', v.plate, 'colour', v.colour,
               'odometer_km', v.odometer_km, 'current_insurer', ob.current_insurer, 'finance_party_name', ob.finance_party_name, 'title_status', ob.title_status,
               'mode', v.management_mode, 'editable', not exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.signed_at is not null),
               'terms', (select jsonb_build_object('schedule_number', s.schedule_number, 'insurance_fee_cents', s.insurance_fee_cents, 'tracker_fee_cents', s.tracker_fee_cents,
                                   'revenue_share_bps', s.revenue_share_bps, 'install_fee_cents', s.install_fee_cents,
                                   'first_last_cents', coalesce(s.first_last_cents, 2 * s.insurance_fee_cents), 'one_off_fees', s.one_off_fees)
                           from vehicle_schedules s where s.vehicle_id = v.id and s.superseded_by is null),
               'entered_by_staff', exists (select 1 from owner_applications x where x.id = ob.application_id and x.entered_by is not null))
               order by v.created_at), '[]'::jsonb)
               from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id
              where v.owner_id = o.id and ob.status not in ('declined', 'withdrawn', 'enrolled')),
    'editable', not exists (select 1 from owner_agreements x where x.owner_id = o.id and x.kind = 'enrollment' and x.status = 'signed'))
    from owners o where o.id = app.portal_owner_id(p_by)
$$;

create or replace function app.owner_review_correct(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  o owners;
  c jsonb;
  v vehicles;
  v_changes jsonb := '[]'::jsonb;
  k text;
begin
  select * into o from owners where id = app.portal_owner_id(p_by) for update;
  if o.id is null then raise exception 'Not an owner' using errcode = '42501'; end if;
  if jsonb_typeof(coalesce(p -> 'owner', 'null')) = 'object' then
    if exists (select 1 from owner_agreements x where x.owner_id = o.id and x.kind = 'enrollment' and x.status = 'signed') then
      raise exception 'Your agreement is signed: contact us to change your details' using errcode = '23514';
    end if;
    foreach k in array array['phone', 'address_line1', 'address_line2', 'city', 'province', 'postal_code'] loop
      if p -> 'owner' ? k and coalesce(p #>> array['owner', k], '') is distinct from coalesce(to_jsonb(o) ->> k, '') then
        v_changes := v_changes || jsonb_build_array(jsonb_build_object('field', k, 'from', to_jsonb(o) ->> k, 'to', p #>> array['owner', k]));
      end if;
    end loop;
    update owners set phone = coalesce(nullif(btrim(p #>> '{owner,phone}'), ''), phone),
           address_line1 = coalesce(nullif(btrim(p #>> '{owner,address_line1}'), ''), address_line1),
           address_line2 = case when p -> 'owner' ? 'address_line2' then nullif(btrim(p #>> '{owner,address_line2}'), '') else address_line2 end,
           city = coalesce(nullif(btrim(p #>> '{owner,city}'), ''), city), province = coalesce(nullif(upper(btrim(p #>> '{owner,province}')), ''), province),
           postal_code = coalesce(nullif(upper(btrim(p #>> '{owner,postal_code}')), ''), postal_code)
     where id = o.id;
  end if;
  for c in select value from jsonb_array_elements(coalesce(p -> 'cars', '[]'::jsonb)) loop
    select * into v from vehicles where id = nullif(c ->> 'vehicle_id', '')::uuid and owner_id = o.id for update;
    if v.id is null then raise exception 'Car not found' using errcode = 'P0002'; end if;
    if exists (select 1 from vehicle_schedules s where s.vehicle_id = v.id and s.signed_at is not null) then
      raise exception 'The Vehicle Schedule of your % is signed: contact us to change it', app.vehicle_name(v.id) using errcode = '23514';
    end if;
    if c ? 'odometer_km' and coalesce(c ->> 'odometer_km', '') !~ '^\d{1,7}$' then raise exception 'Enter the odometer in km' using errcode = '22023'; end if;
    v_changes := v_changes || jsonb_build_array(jsonb_build_object('vehicle', app.vehicle_name(v.id), 'values', c - 'vehicle_id'));
    update vehicles set plate = coalesce(nullif(upper(regexp_replace(coalesce(c ->> 'plate', ''), '\s', '', 'g')), ''), plate),
           colour = coalesce(nullif(btrim(c ->> 'colour'), ''), colour), odometer_km = coalesce(nullif(c ->> 'odometer_km', '')::integer, odometer_km)
     where id = v.id;
    update vehicle_schedules set odometer_km = coalesce(nullif(c ->> 'odometer_km', '')::integer, odometer_km) where vehicle_id = v.id and superseded_by is null and signed_at is null;
    update vehicle_onboardings set current_insurer = coalesce(nullif(btrim(c ->> 'current_insurer'), ''), current_insurer),
           finance_party_name = case when title_status <> 'owned_outright' then coalesce(nullif(btrim(c ->> 'finance_party_name'), ''), finance_party_name) else finance_party_name end
     where vehicle_id = v.id;
  end loop;
  perform app.ot_withdraw_unsigned(o.id);
  perform app.raise_task(p_type => 'owner_corrected_details', p_queue => 'admin', p_title => format('%s corrected their details before signing', o.legal_name),
      p_detail => left(v_changes::text, 600), p_owner => o.id, p_related_table => 'owners', p_related_id => o.id,
      p_dedupe => 'owner_corrected_details:' || o.id || ':' || to_char(now(), 'YYYYMMDDHH24MI'));
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_by, 'owner_review_correct', 'owners', o.id::text, jsonb_build_object('changes', v_changes));
  return jsonb_build_object('saved', true, 'changes', jsonb_array_length(v_changes));
end $$;

-- The updated Vehicle Schedules waiting for the owner (owner portal home and the signing page).
create or replace function app.owner_schedule_changes(p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(app.schedule_change_text(c.id) order by c.created_at), '[]'::jsonb)
    from vehicle_term_changes c join vehicles v on v.id = c.vehicle_id
   where v.owner_id = app.portal_owner_id(p_by) and c.status = 'awaiting_signature'
$$;
create or replace function app.owner_schedule_change(p_by uuid, p_change uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.schedule_change_text(c.id) || jsonb_build_object('sha256', encode(sha256(convert_to(app.schedule_change_text(c.id) ->> 'text', 'UTF8')), 'hex'))
    from vehicle_term_changes c join vehicles v on v.id = c.vehicle_id
   where c.id = p_change and v.owner_id = app.portal_owner_id(p_by)
$$;

-- Owner search for "Add a car for this owner" (staff).
create or replace function app.owner_pick(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  q text := lower(btrim(coalesce(p ->> 'q', '')));
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x) from (
    select jsonb_build_object('id', o.id, 'legal_name', o.legal_name, 'email', o.email, 'phone', o.phone, 'owner_type', o.owner_type,
             'cars', (select count(*) from vehicles v where v.owner_id = o.id and v.status not in ('declined', 'exited'))) x
      from owners o
     where o.kind = 'program' and (q = '' or lower(o.legal_name) like '%' || q || '%' or lower(coalesce(o.email, '')) like '%' || q || '%'
                                   or regexp_replace(coalesce(o.phone, ''), '\D', '', 'g') like '%' || nullif(regexp_replace(q, '\D', '', 'g'), '') || '%')
     order by o.created_at desc limit 20) s), '[]'::jsonb);
end $$;

-- What "Add a car for this owner" starts from: the owner, and their negotiated terms (defaults from their other cars).
create or replace function app.owner_add_car_facts(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  o owners;
begin
  if not (app.user_is_admin(p_by) or app.user_va_has(p_by, 'cs', 'fleet')) then raise exception 'Not permitted' using errcode = '42501'; end if;
  select * into o from owners where id = nullif(p ->> 'owner_id', '')::uuid;
  return jsonb_build_object('admin', app.user_is_admin(p_by), 'trackers_available', coalesce((app.settings()).trackers_available, false), 'today', app.today(),
    'hst_bps', (app.settings()).hst_bps,
    'owner', case when o.id is not null then jsonb_build_object('id', o.id, 'legal_name', o.legal_name, 'email', o.email, 'phone', o.phone, 'owner_type', o.owner_type,
                     'has_account', o.user_id is not null, 'corporation_name', o.corporation_name) end,
    'terms', case when o.id is not null then app.owner_terms_resolve(null, null, o.id, coalesce(nullif(p ->> 'mode', '')::management_mode, 'managed')) end,
    'standard', (select jsonb_build_object('insurance_fee_cents', g.insurance_fee_cents, 'tracker_fee_cents', g.tracker_fee_cents, 'revenue_share_bps', g.revenue_share_bps,
                         'install_fee_cents', (app.settings()).install_fee_cents)
                   from owner_fee_grid g where g.min_vehicles <= 1 and g.effective_from <= app.today() order by g.effective_from desc, g.min_vehicles limit 1));
end $$;

-- ================================================================ 6. the emails' values
alter function app.notification_payload(text, app_events, jsonb) rename to ntf_payload_pre_ot;
create or replace function app.notification_payload(p_code text, p_event app_events, p_to jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  x jsonb := app.ntf_payload_pre_ot(p_code, p_event, p_to);
  inv owner_invoices;
  a owner_applications;
  o owners;
  t jsonb;
begin
  if p_code in ('owner_invoice_issued', 'owner_invoice_voided') then
    select * into inv from owner_invoices where id = p_event.entity_id;
    select * into o from owners where id = inv.owner_id;
    x := x || coalesce(app.ntf_vehicle(inv.vehicle_id), '{}'::jsonb) || jsonb_build_object(
      'first_name', coalesce(nullif(x ->> 'first_name', ''), o.first_name, split_part(o.legal_name, ' ', 1)),
      'invoice_number', inv.invoice_number, 'invoice_total', app.fmt_money(inv.total_cents),
      'invoice_title', coalesce(inv.title, app.oi_label(inv.kind)),
      'invoice_lines', coalesce((select jsonb_agg(jsonb_build_object('label', coalesce(l.description, initcap(replace(l.kind, '_', ' ')))
                                                    || case when l.quantity <> 1 then ' (' || trim(to_char(l.quantity, 'FM99990.##')) || ' x ' || app.fmt_money(l.unit_amount_cents) || ')' else '' end,
                                                    'amount', app.fmt_money(l.amount_cents)) order by l.sort_order, l.created_at)
                                   from owner_invoice_lines l where l.owner_invoice_id = inv.id), '[]'::jsonb)
                       || jsonb_build_array(jsonb_build_object('label', 'HST', 'amount', app.fmt_money(inv.hst_cents))),
      'due_date', coalesce(app.fmt_day(inv.due_on), 'On receipt'), 'has_notes', inv.notes is not null, 'invoice_notes', coalesce(inv.notes, ''),
      'is_credit', inv.kind = 'credit_note', 'void_reason', coalesce(inv.void_reason, ''),
      'replacement_number', coalesce((select r.invoice_number from owner_invoices r where r.replaces_invoice_id = inv.id order by r.created_at desc limit 1), ''),
      'has_replacement', exists (select 1 from owner_invoices r where r.replaces_invoice_id = inv.id),
      '_url', app.ntf_link('owner_invoice', jsonb_build_object('invoice_number', inv.invoice_number)));
  elsif p_code = 'owner_schedule_resign' then
    t := app.schedule_change_text(p_event.entity_id);
    select o2.* into o from owners o2 join vehicles v on v.owner_id = o2.id where v.id = (t ->> 'vehicle_id')::uuid;
    x := x || coalesce(app.ntf_vehicle((t ->> 'vehicle_id')::uuid), '{}'::jsonb) || jsonb_build_object(
      'first_name', coalesce(nullif(x ->> 'first_name', ''), o.first_name, split_part(o.legal_name, ' ', 1)),
      'effective_date', app.fmt_day((t ->> 'effective_from')::date),
      'change_id', p_event.entity_id::text,
      'terms_rows', jsonb_build_array(
        jsonb_build_object('label', 'Insurance Fee a month', 'before', app.fmt_money((t #>> '{previous,insurance_fee_cents}')::bigint), 'after', app.fmt_money((t #>> '{new,insurance_fee_cents}')::bigint)),
        jsonb_build_object('label', 'Tracker Fee a month', 'before', app.fmt_money((t #>> '{previous,tracker_fee_cents}')::bigint), 'after', app.fmt_money((t #>> '{new,tracker_fee_cents}')::bigint)),
        jsonb_build_object('label', 'Revenue Share', 'before', trim(to_char((t #>> '{previous,revenue_share_bps}')::numeric / 100, 'FM990.99')) || '%',
                           'after', trim(to_char((t #>> '{new,revenue_share_bps}')::numeric / 100, 'FM990.99')) || '%')),
      '_url', app.ntf_link('owner_schedule_sign', jsonb_build_object('change_id', p_event.entity_id)));
  elsif p_code = 'owner_car_set_up' then
    select * into a from owner_applications where id = p_event.entity_id;
    select * into o from owners where id = a.owner_id;
    x := x || jsonb_build_object(
      'first_name', coalesce(nullif(x ->> 'first_name', ''), o.first_name, split_part(o.legal_name, ' ', 1)),
      'vehicle_name', coalesce((select string_agg(app.vehicle_name(v.id), ', ' order by v.created_at) from vehicles v join vehicle_onboardings ob on ob.vehicle_id = v.id where ob.application_id = a.id),
                               (select string_agg(app.vehicle_name(v.id), ', ' order by v.created_at) from vehicles v where v.owner_id = a.owner_id and v.status not in ('declined', 'exited')), 'car'),
      'staff_name', coalesce(split_part(a.entered_by_name, ' ', 1), 'Our team'),
      'password_url', coalesce(p_event.payload ->> 'password_url', ''), 'has_password_url', nullif(p_event.payload ->> 'password_url', '') is not null,
      'owner_email', coalesce(o.email, ''),
      'invoice_count', (select count(*) from owner_invoices i join vehicle_onboardings ob on ob.vehicle_id = i.vehicle_id
                          where ob.application_id = a.id and i.status in ('issued', 'failed')),
      'paid_count', (select count(*) from owner_invoices i join vehicle_onboardings ob on ob.vehicle_id = i.vehicle_id
                          where ob.application_id = a.id and i.status = 'paid'),
      'review_url', app.ntf_link('owner_review'),
      '_url', app.ntf_link('owner_review'));
  end if;
  return x;
end $$;

insert into notification_link_paths (key, path) values ('owner_schedule_sign', '/owner/sign/schedule/{{change_id}}'), ('owner_review', '/owner/review'),
  ('owner_invoices', '/owner/invoices')
on conflict (key) do update set path = excluded.path;

-- ================================================================ 7. the doors
create or replace function app.ops_ot(p_user uuid, p_call text, p_name text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  case p_name
  when 'owner_terms' then return app.owner_terms_read(p_user, p);
  when 'owner_terms_save' then return app.owner_terms_save(p_user, p);
  when 'schedule_change_admin' then return app.schedule_change_admin(p_user, p);
  when 'owner_invoices_admin' then return app.owner_invoices_admin(p_user, p);
  when 'owner_invoice_admin' then return app.owner_invoice_admin(p_user, p);
  when 'owner_invoice_draft_save' then return app.owner_invoice_draft_save(p_user, p);
  when 'owner_invoice_issue' then return app.owner_invoice_issue(p_user, p);
  when 'owner_invoice_void' then return app.owner_invoice_void(p_user, p);
  when 'owner_invoice_credit_note' then return app.owner_invoice_credit_note(p_user, p);
  when 'owner_invoice_resend' then return app.owner_invoice_resend(p_user, p);
  when 'application_approve_plan' then return app.application_approve_plan(p_user, p);
  when 'staff_add_owner_car' then return app.staff_add_owner_car(p_user, p);
  when 'staff_vehicle_document' then return jsonb_build_object('id', app.staff_register_vehicle_document(p_user, p));
  when 'owner_setup_email' then return app.owner_setup_email(p_user, p);
  when 'owner_pick' then return app.owner_pick(p_user, p);
  when 'owner_add_car_facts' then return app.owner_add_car_facts(p_user, p);
  else raise exception 'Unknown action %', p_name using errcode = '22023';
  end case;
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre_ot;
create or replace function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb);
begin
  if (p_call in ('ops_read', 'admin_read') and p_name in ('owner_terms', 'owner_invoices_admin', 'owner_invoice_admin', 'application_approve_plan'))
     or (p_call in ('ops_do', 'admin_do') and p_name in ('owner_terms_save', 'schedule_change_admin', 'owner_invoice_draft_save', 'owner_invoice_issue',
                                                        'owner_invoice_void', 'owner_invoice_credit_note', 'owner_invoice_resend', 'owner_setup_email'))
     or (p_call in ('ops_read', 'admin_read', 'va_read') and p_name in ('owner_pick', 'owner_add_car_facts'))
     or (p_call in ('ops_do', 'admin_do', 'va_do') and p_name in ('staff_add_owner_car', 'staff_vehicle_document')) then
    if p_ ? '_va' then perform set_config('app.va_active', coalesce(p_ ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return app.ops_ot(p_user, p_call, p_name, p_ - '_va');
  end if;
  return app.door_pre_ot(p_user, p_aal, p_call, p_name, p);
end $$;

-- The owner portal's own calls (the server, as the service role).
create or replace function public.server_owner_review(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_review_read(p_by) $$;
create or replace function public.server_owner_review_correct(p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.owner_review_correct(p_by, p) $$;
create or replace function public.server_owner_schedule_changes(p_by uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_schedule_changes(p_by) $$;
create or replace function public.server_owner_schedule_change(p_by uuid, p_change uuid) returns jsonb
language sql stable security invoker set search_path = public, app as $$ select app.owner_schedule_change(p_by, p_change) $$;
create or replace function public.server_schedule_change_sign(p_by uuid, p jsonb) returns jsonb
language sql volatile security invoker set search_path = public, app as $$ select app.schedule_change_sign(p_by, p) $$;

-- ================================================================ 8. privileges
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where (n.nspname = 'app' and p.proname = any (array[
              'ot_one_off', 'owner_terms_resolve', 'ot_terms_row', 'ot_withdraw_unsigned', 'owner_terms_save', 'ot_schedule_change_apply', 'schedule_change_text',
              'schedule_change_sign', 'schedule_change_admin', 'owner_terms_read', 'owner_invoice_lines_draft_only', 'oi_label', 'oi_write_lines',
              'owner_invoice_draft_save', 'owner_invoice_issue', 'oi_copy_draft', 'owner_invoice_void', 'owner_invoice_credit_note', 'owner_invoice_resend',
              'ntf_owner_invoices_after', 'issue_upfront_invoice', 'oi_lines_json', 'oi_row', 'owner_invoices_admin', 'owner_invoice_admin', 'owner_invoice_view', 'owner_portal_invoices',
              'file_access', 'pdf_facts', 'oi_plan_invoice', 'application_approve_plan', 'application_approve', 'staff_add_owner_car',
              'staff_register_vehicle_document', 'owner_setup_email', 'owner_review_read', 'owner_review_correct', 'owner_schedule_changes', 'owner_schedule_change',
              'owner_pick', 'owner_add_car_facts', 'notification_payload', 'ops_ot', 'door']))
        or (n.nspname = 'public' and p.proname = any (array['server_owner_review', 'server_owner_review_correct', 'server_owner_schedule_changes',
              'server_owner_schedule_change', 'server_schedule_change_sign']))
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- the functions renamed keep their privileges (the wrappers above call them as their owner)
do $$
declare
  f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname like '%\_pre\_ot' loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ================================================================ 9. the guides for this release
-- From docs/guides/content (docs/guides/src, exported), published as 0059 does: an Admin's earlier text stays in the
-- history with Revert.
-- GUIDES OT START (generated by supabase/seed/owner_terms_gen_guides.mjs from docs/guides/content; do not edit by hand)
select app.guide_release_section('owner', 'fees-payments-and-payouts', 'chapter', 'bookings-and-your-own-use', 'Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.

## How your fees work

- Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.
- The tracker fee starts the day the car''s tracker is installed. The tracker install fee has its own invoice.
- Before a car goes live you pay the upfront invoice: the first and last month''s insurance fee.
- One invoice per car. Registry, inspection and appraisal costs are not billed by us; you pay them directly.

## The monthly debit, step by step

:::flow
Notice day | 10 days before: your invoices and one email with the total
The 15th | Each invoice is debited from your account
Cleared | The invoice shows Paid and you get a receipt
Insufficient funds? | A $50.00 Late Fee once, and the same amount tried again within 30 days
:::

- A debit is never more than its notice said. Each invoice shows "will be debited on" with the date.
- If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
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

1. Open **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
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
- Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Banking.
- Returned again after the retry? The invoice is in arrears and we contact you.
- You can always pay an invoice by card from its page before the debit day.
- On your bank statement the debit shows our company''s legal name, operating as CarmaCars.

## Set up the automatic debit

Do this once. Without it, we email you on each notice day to set it up.

1. Open **Banking**. Under Automatic debit of your fees, press **Set up pre-authorized debit**.
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

1. Open **Banking**. Under Where we pay you, choose Bank transfer or e-Transfer.
2. Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).
3. Press **Submit payout details**. For your security we confirm new details by phone before we use them.

![](/guides/img/owner-07-banking-desktop-87b2ffe3.jpg "desktop; size: 990 642; address: carmacars.ca/owner/banking; pins: 1 50.5 25.7, 2 90.9 45.5, 3 30.3 89.7")

## Statements and payouts

1. Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.
2. Press **Download PDF** to keep a copy. We also email it to you with the PDF attached.
3. Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.

![](/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg "desktop; size: 1440 792; address: carmacars.ca/owner/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 2 16.0 30.6, 1 66.0 40.9")
',
  '<p class="gd-p">Your fees are debited from your bank account on the 15th, after a notice. Your payout for the month before arrives on the 10th, with a statement.</p><section class="gd-task" id="fees-payments-and-payouts-how-your-fees-work" data-gd-task><h2 class="gd-h2">How your fees work</h2><ul class="gd-ul"><li>Each car has two monthly fees: an insurance fee and a tracker fee. They are due every month, rented or not.</li><li>The tracker fee starts the day the car&#39;s tracker is installed. The tracker install fee has its own invoice.</li><li>Before a car goes live you pay the first and last month amount we agreed with you (usually two months of the insurance fee, or the exact amount we agreed).</li><li>Your amounts are the ones we agreed for each car, to the cent. Any other fee we agreed, for example a registration fee, comes on its own invoice with each line, its quantity and whether HST applies.</li><li>One invoice per car. Registry, inspection and appraisal costs are not billed by us unless we agreed to pay them for you; then they are on an invoice of their own.</li></ul><p class="gd-p">An invoice we cancel shows Void with the reason, and the invoice that replaces it. Nothing is debited for a void invoice. Every invoice has Download PDF.</p></section><section class="gd-task" id="fees-payments-and-payouts-the-monthly-debit-step-by-step" data-gd-task><h2 class="gd-h2">The monthly debit, step by step</h2><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>10 days before: your invoices and one email with the total</em></li><li><b>2</b><span>The 15th</span><em>Each invoice is debited from your account</em></li><li><b>3</b><span>Cleared</span><em>The invoice shows Paid and you get a receipt</em></li><li><b>4</b><span>Insufficient funds?</span><em>A $50.00 Late Fee once, and the same amount tried again within 30 days</em></li></ol><ul class="gd-ul"><li>A debit is never more than its notice said. Each invoice shows &quot;will be debited on&quot; with the date.</li><li>If your bank returns a debit for insufficient funds, we add the $50.00 Late Fee to that invoice once and try the original amount again within 30 days, as section 4.4 of your Enrollment Agreement sets out. The Late Fee is collected with your next debit.</li><li>Returned for another reason (for example a closed account)? We do not try again and add no Late Fee. We pause your debit and email you: pay the invoice from its page, or set up a new account under Banking.</li><li>Returned again after the retry? The invoice is in arrears and we contact you.</li><li>You can always pay an invoice by card from its page before the debit day.</li><li>On your bank statement the debit shows our company&#39;s legal name, operating as CarmaCars.</li></ul></section><section class="gd-task" id="fees-payments-and-payouts-set-up-the-automatic-debit" data-gd-task><h2 class="gd-h2">Set up the automatic debit</h2><p class="gd-p">Do this once. Without it, we email you on each notice day to set it up.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Banking</b>. Under Automatic debit of your fees, press <b class="gd-ui">Set up pre-authorized debit</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the agreement and press <b class="gd-ui">Continue to my bank details</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Enter your bank details and press <b class="gd-ui">Save the bank account</b>. Banking then shows the account and the next debit.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/752"><img src="/guides/img/owner-07-banking-desktop-52316739.jpg" alt="" loading="lazy" decoding="async" width="1440" height="752"><span class="gd-pin" style="left:96.2%;top:36.8%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-pay-an-invoice-now" data-gd-task><h2 class="gd-h2">Pay an invoice now</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Invoices, then the invoice. It lists what it covers and the balance.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose Card (paid at once) and press <b class="gd-ui">Pay $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Or choose Pre-authorized debit (from a Canadian bank account, clears in 3 to 5 business days) and press <b class="gd-ui">Authorize debit of $...</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Prefer Interac e-Transfer? Send the amount to billing@carmacars.ca with the invoice number in the message.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/invoices/INV-1050</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-06-invoice-desktop-bba2c020.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:6.9%;top:52.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:38.2%;top:52.6%" aria-hidden="true">3</span><span class="gd-pin" style="left:11.5%;top:80.5%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Paid us by e-Transfer, cheque, cash or bank transfer? Once we record it, the invoice says &quot;Paid by e-Transfer on&quot; the date, you get a receipt by email, and the automatic debit does not take that amount. Paid part of it? The invoice shows Partly paid and only the rest is debited.</div></aside></section><section class="gd-task" id="fees-payments-and-payouts-tell-us-where-to-pay-you" data-gd-task><h2 class="gd-h2">Tell us where to pay you</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Banking</b>. Under Where we pay you, choose Bank transfer or e-Transfer.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Fill in Account holder, Institution number, Transit number and Account number (or your e-Transfer email).</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Submit payout details</b>. For your security we confirm new details by phone before we use them.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/banking</span></div><div class="gd-imgwrap" style="aspect-ratio:990/642"><img src="/guides/img/owner-07-banking-desktop-87b2ffe3.jpg" alt="" loading="lazy" decoding="async" width="990" height="642"><span class="gd-pin" style="left:50.5%;top:25.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.9%;top:45.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:30.3%;top:89.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="fees-payments-and-payouts-statements-and-payouts" data-gd-task><h2 class="gd-h2">Statements and payouts</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Statements: one a month, once approved by CarmaCars. Open one to see every booking, the revenue share, deductions and the payout.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download PDF</b> to keep a copy. We also email it to you with the PDF attached.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Payouts shows what was paid to you and when. Payouts are made on the 10th for the month before.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/792"><img src="/guides/img/owner-09-statement-desktop-fc5f9ea5.jpg" alt="" loading="lazy" decoding="async" width="1440" height="792"><span class="gd-pin" style="left:16%;top:30.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:66%;top:40.9%" aria-hidden="true">1</span></div></div></figure></div></section>');
select app.guide_release_section('owner', 'documents-and-forms', 'chapter', 'fees-payments-and-payouts', 'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.
4. Tap **All of these** for the statements the agreement asks you to initial (your initials are filled in), then press **Sign all**.
5. Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Initial each of the three acknowledgments, and type Your initials.
3. Sign: draw your signature in the box, or use your name.
4. Hand the device to your witness, another adult. They type their full name and tick the statement "I witnessed (your name) sign in my presence." Press **Sign Form C**.

![](/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg "desktop; size: 790 980; address: carmacars.ca/owner/documents/form-c/b39a2a4e-6dcb-459c-b7c0-393f78919d91; pins: 2 5.7 13.6, 3 32.9 55.1, 4 6.3 82.2")

## Forms C and D on paper, signed with witnesses

Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.

## Government forms filled for you

Each car''s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. To sign it on screen, draw your signature in the box, then press **Sign and save**. Forms ready to sign are also in the package on **Check and sign**, signed with the same one signature. The signed copy is kept with your documents.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/7624af13-b86c-4add-a2e7-b11651149086/official; pins: 2 22.2 29.5, 3 50.0 95.5")

> Watch out: If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.
', 'Documents and forms', 'Agreements, government forms, Forms C and D, and official forms filled for you.',
  'Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.

## Sign everything at once

Everything you sign on screen is in one place: Home shows how many are signed ("2 of 5 signed") and opens it with Check and sign.

1. Press **Check and sign** on Home (or open `carmacars.ca/owner/sign`). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).
2. Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press **Fix** next to it, change it, and come back.
3. Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.
4. Tap **All of these** for the statements the agreement asks you to initial (your initials are filled in), then press **Sign all**.
5. Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.

> Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.

> Good to know: Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.

> Tip: Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.

## We set up your car for you

When our team enters your car for you, you get one email: review the details and sign.

1. No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.
2. Open `carmacars.ca/owner/review` (Home has **Review or correct your details**). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.
3. Something wrong? Correct it and press **Save corrections**. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.
4. Everything right? Press **Everything is right: sign** and sign once.

## Sign an updated Vehicle Schedule

When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.

1. Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.
2. Read the text, tick that you agree, type your full legal name and press **Sign**.
3. Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date.

## Form C on screen, with your witness beside you

Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.

1. Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.
2. Initial each of the three acknowledgments, and type Your initials.
3. Sign: draw your signature in the box, or use your name.
4. Hand the device to your witness, another adult. They type their full name and tick the statement "I witnessed (your name) sign in my presence." Press **Sign Form C**.

![](/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg "desktop; size: 790 980; address: carmacars.ca/owner/documents/form-c/b39a2a4e-6dcb-459c-b7c0-393f78919d91; pins: 2 5.7 13.6, 3 32.9 55.1, 4 6.3 82.2")

## Forms C and D on paper, signed with witnesses

Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.

1. Open Documents. Under Forms to sign with witnesses, press **Print the form**. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.
2. Sign it in front of your witnesses. They sign and print their names in their spots.
3. Type each witness''s full name in the boxes.
4. On your phone, press **Take a photo of the signed page**: one photo of each page. A PDF scan works too (**Or choose a file**).

![](/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg "desktop; size: 1440 742; address: carmacars.ca/owner/documents; pins: 1 21.5 32.5, 3 69.4 50.7, 4 69.4 60.4")

> Tip: We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.

> Good to know: Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.

## Government forms filled for you

Each car''s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.

1. Open Documents and choose a form marked "Official form, filled for you".
2. Press **Download the filled form** and check each value.
3. To sign it on screen, draw your signature in the box, then press **Sign and save**. Forms ready to sign are also in the package on **Check and sign**, signed with the same one signature. The signed copy is kept with your documents.

![](/guides/img/owner-13-official-form-desktop-48614913.jpg "desktop; size: 1440 732; address: carmacars.ca/owner/documents/forms/7624af13-b86c-4add-a2e7-b11651149086/official; pins: 2 22.2 29.5, 3 50.0 95.5")

> Watch out: If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.
',
  '<p class="gd-p">Your signed agreements, uploads and government forms are under Documents. Some forms are filled for you; Forms C and D are signed with witnesses.</p><section class="gd-task" id="documents-and-forms-sign-everything-at-once" data-gd-task><h2 class="gd-h2">Sign everything at once</h2><p class="gd-p">Everything you sign on screen is in one place: Home shows how many are signed (&quot;2 of 5 signed&quot;) and opens it with Check and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Check and sign</b> on Home (or open <span class="gd-url">carmacars.ca/owner/sign</span>). The list at the top shows each document: signed, in this package, or done elsewhere (Forms C and D, the bank debit).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values: your name, address, each car with its VIN and plate, your fees and Revenue Share. Something wrong? Press <b class="gd-ui">Fix</b> next to it, change it, and come back.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open any document to read it word for word: the agreements, the schedules, Forms A and B, and the official registry forms that are ready.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Tap <b class="gd-ui">All of these</b> for the statements the agreement asks you to initial (your initials are filled in), then press <b class="gd-ui">Sign all</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Your name on file is your signature. One signature is applied to each document; CarmaCars countersigns at the same moment and every signed copy is in Documents.</div></li></ol></div><aside class="gd-box"><div>Two owners: A car with a second owner on its ownership? Each owner named in the Title Schedule signs. The other owner gets their own link by email and signs the same documents on their phone or computer. The agreements take effect when the last owner signs; CarmaCars countersigns then.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Form A (the trust declaration) is for cars under the Co-Registrant or Transfer method; Form B (the lease summary) for cars under a Lease method. No witness is needed: they are in the same package. You can also sign one on its own page from Documents.</div></aside><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Signed one of your documents on paper instead? Send us the scan. Once we record it, Documents shows it as Signed on paper and we do not ask again.</div></aside></section><section class="gd-task" id="documents-and-forms-we-set-up-your-car-for-you" data-gd-task><h2 class="gd-h2">We set up your car for you</h2><p class="gd-p">When our team enters your car for you, you get one email: review the details and sign.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">No sign-in yet? The email has a link to choose your password. It works once, for 24 hours; after that use Forgot password on the sign-in page.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <span class="gd-url">carmacars.ca/owner/review</span> (Home has <b class="gd-ui">Review or correct your details</b>). Check your phone and address, and each car: plate, colour, odometer, your insurer and your lender. The terms we agreed are shown too.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Something wrong? Correct it and press <b class="gd-ui">Save corrections</b>. Your documents are filled in again and we are told. A term you did not agree to: message us before you sign.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Everything right? Press <b class="gd-ui">Everything is right: sign</b> and sign once.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-sign-an-updated-vehicle-schedule" data-gd-task><h2 class="gd-h2">Sign an updated Vehicle Schedule</h2><p class="gd-p">When we agree new terms for a car you already signed for, you sign an updated Vehicle Schedule. Home shows it first.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open it from Home or the email. It shows what changes (now and updated) and the date it applies from.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Read the text, tick that you agree, type your full legal name and press <b class="gd-ui">Sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Your current terms stay until you sign. After that, your invoices and statements use the new ones from the date.</div></li></ol></div></section><section class="gd-task" id="documents-and-forms-form-c-on-screen-with-your-witness-beside-you" data-gd-task><h2 class="gd-h2">Form C on screen, with your witness beside you</h2><p class="gd-p">Form C is the lender or lessor permission for a financed or leased car. It needs one witness, and you can sign it on screen when your witness is with you.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press Sign Form C on screen instead.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Initial each of the three acknowledgments, and type Your initials.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Sign: draw your signature in the box, or use your name.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Hand the device to your witness, another adult. They type their full name and tick the statement &quot;I witnessed (your name) sign in my presence.&quot; Press <b class="gd-ui">Sign Form C</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/form-c/b39a2a4e-6dcb-459c-b7c0-393f78919d91</span></div><div class="gd-imgwrap" style="aspect-ratio:790/980"><img src="/guides/img/owner-16-form-c-screen-desktop-faa92983.jpg" alt="" loading="lazy" decoding="async" width="790" height="980"><span class="gd-pin" style="left:5.7%;top:13.6%" aria-hidden="true">2</span><span class="gd-pin" style="left:32.9%;top:55.1%" aria-hidden="true">3</span><span class="gd-pin" style="left:6.3%;top:82.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="documents-and-forms-forms-c-and-d-on-paper-signed-with-witnesses" data-gd-task><h2 class="gd-h2">Forms C and D on paper, signed with witnesses</h2><p class="gd-p">Form D is a limited power of attorney (two witnesses), signed on paper. Form C can be signed on paper too, with one witness.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents. Under Forms to sign with witnesses, press <b class="gd-ui">Print the form</b>. It is filled in, and every spot to sign or initial is marked SIGN HERE or INITIAL HERE.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Sign it in front of your witnesses. They sign and print their names in their spots.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Type each witness&#39;s full name in the boxes.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">On your phone, press <b class="gd-ui">Take a photo of the signed page</b>: one photo of each page. A PDF scan works too (<b class="gd-ui">Or choose a file</b>).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/742"><img src="/guides/img/owner-12-forms-c-d-desktop-21fbbe79.jpg" alt="" loading="lazy" decoding="async" width="1440" height="742"><span class="gd-pin" style="left:21.5%;top:32.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:69.4%;top:50.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:69.4%;top:60.4%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>We check the photo and approve it, or send it back with what to fix. You get an email either way, and the page shows the status.</div></aside><aside class="gd-box"><span class="gd-lbl">Good to know</span><div>Why paper for Form D? It is a power of attorney, which cannot be signed electronically in Ontario, and its two witnesses sign in person.</div></aside></section><section class="gd-task" id="documents-and-forms-government-forms-filled-for-you" data-gd-task><h2 class="gd-h2">Government forms filled for you</h2><p class="gd-p">Each car&#39;s registry forms are prepared from your records. Until we load the official PDF, you get a data sheet with the values.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open Documents and choose a form marked &quot;Official form, filled for you&quot;.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Download the filled form</b> and check each value.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To sign it on screen, draw your signature in the box, then press <b class="gd-ui">Sign and save</b>. Forms ready to sign are also in the package on <b class="gd-ui">Check and sign</b>, signed with the same one signature. The signed copy is kept with your documents.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/owner/documents/forms/7624af13-b86c-4add-a2e7-b11651149086/official</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/732"><img src="/guides/img/owner-13-official-form-desktop-48614913.jpg" alt="" loading="lazy" decoding="async" width="1440" height="732"><span class="gd-pin" style="left:22.2%;top:29.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:50%;top:95.5%" aria-hidden="true">3</span></div></div></figure></div><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>If the registry office asks for an ink signature, print the filled form and sign it there. You pay ServiceOntario, the inspection station and the appraiser directly.</div></aside></section>');
select app.guide_release_section('admin', 'getting-around-admin', 'chapter', 'start-here', 'Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.

## To do

Start every shift here. Each line counts what is waiting and has one button to deal with it.

1. The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance, cars using sample photos, staff commissions to approve and to pay, prices typed by hand to review, and staff who say they sourced a website request.
2. Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under "more with nothing waiting".
3. Below the list: today''s pickups (ready or not ready) and today''s returns (due or late).
4. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Tasks |
| Bookings | Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews |
| Cars | Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars |
| Owners and partners | Applications, Owners, Partners, Owner forms, Paid and signed |
| Money | Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses |
| People | Renters, Staff, Investors, Portals and view as |
| Settings | All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
', 'Getting around Admin', 'To do, the menu, search, keyboard shortcuts and your other portals.',
  'Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.

## To do

Start every shift here. Each line counts what is waiting and has one button to deal with it.

1. The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance, cars using sample photos, staff commissions to approve and to pay, prices typed by hand to review, and staff who say they sourced a website request.
2. Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under "more with nothing waiting".
3. Below the list: today''s pickups (ready or not ready) and today''s returns (due or late).
4. Press **Overview** for the money, fleet and queue figures, the alerts and the team''s sales for the month.

![](/guides/img/admin-01-today-desktop-ea48309c.jpg "desktop; size: 1440 900; address: carmacars.ca/admin; pins: 1 22.6 31.6, 2 90.3 31.7, 3 18.4 90.2, 4 94.4 22.2")

## The menu

The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.

| Group | Pages |
| --- | --- |
| Today | To do, Overview, Tasks |
| Bookings | Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews |
| Cars | Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars |
| Owners and partners | Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed |
| Money | Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses |
| People | Renters, Staff, Investors, Portals and view as |
| Settings | All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log |

![On a phone: press Menu (1), then a group (2), then the page (3).](/guides/img/admin-31-menu-phone-667dc2fd.jpg "phone; size: 390 715; pins: 1 10.3 28.7, 2 76.9 42.4, 3 76.9 48.3")

## Search

The search box sits at the top of the menu, on every page.

1. Type a booking number (CC-1042), a plate, a VIN, or a name or email address.
2. Press **Search** (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.

![](/guides/img/admin-32-search-desktop-ca548a70.jpg "desktop; size: 1440 420; address: carmacars.ca/admin/search?q=CC-10057; pins: 1 7.4 45.2, 2 95.0 46.9")

## Keyboard shortcuts

Press g, then a letter. Press / to jump to the search box.

| Keys | Opens | Keys | Opens |
| --- | --- | --- | --- |
| g t | To do | g v | Vehicles |
| g r | Requests | g l | Listings |
| g b | Bookings | g a | Applications |
| g c | Calendar | g o | Owners |
| g k | Tasks | g m | Payments and refunds |
| g s | All settings | / | Search |
',
  '<p class="gd-p">Admin opens on To do: what needs you now, most urgent first. The menu groups every screen into seven groups: Today, Bookings, Cars, Owners and partners, Money, People and Settings. Search finds any booking, car or person.</p><section class="gd-task" id="getting-around-admin-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Start every shift here. Each line counts what is waiting and has one button to deal with it.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The list is in order of urgency: owner applications, booking requests, changes renters asked for, failed payments, agreements to countersign, tolls, listings, plates not checked, insurance, cars using sample photos, staff commissions to approve and to pay, prices typed by hand to review, and staff who say they sourced a website request.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press the button on a line to go straight to that work. A line with nothing waiting moves to the bottom, under &quot;more with nothing waiting&quot;.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Below the list: today&#39;s pickups (ready or not ready) and today&#39;s returns (due or late).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Overview</b> for the money, fleet and queue figures, the alerts and the team&#39;s sales for the month.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/900"><img src="/guides/img/admin-01-today-desktop-ea48309c.jpg" alt="" loading="lazy" decoding="async" width="1440" height="900"><span class="gd-pin" style="left:22.6%;top:31.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:90.3%;top:31.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:18.4%;top:90.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:94.4%;top:22.2%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">The current group is open, with its pages; press another group to open it. On a phone the whole menu sits behind one Menu button that says where you are.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Group</th><th scope="col">Pages</th></tr></thead><tbody><tr><td>Today</td><td>To do, Overview, Tasks</td></tr><tr><td>Bookings</td><td>Requests, Bookings, Calendar, Add a rental, Damage, Incidents and claims, Reviews</td></tr><tr><td>Cars</td><td>Vehicles, Listings, Similar cars, Retire or delete, Rates for many cars</td></tr><tr><td>Owners and partners</td><td>Applications, Owners, Add a car for an owner, Partners, Owner forms, Paid and signed</td></tr><tr><td>Money</td><td>Owner invoices, Owner debits, Payments and refunds, Owner statements, Company statements, Payouts, Staff commissions, Tolls and tickets, Insurer invoices, Reconciliation, Expenses</td></tr><tr><td>People</td><td>Renters, Staff, Investors, Portals and view as</td></tr><tr><td>Settings</td><td>All settings, Site, Program, Forms, Guides, Emails, Email log, Sample photos, Audit log</td></tr></tbody></table></div><div class="gd-figblock"><figure class="gd-fig gd-fig--phone"><div class="gd-phone"><div class="gd-imgwrap" style="aspect-ratio:390/715"><img src="/guides/img/admin-31-menu-phone-667dc2fd.jpg" alt="On a phone: press Menu (1), then a group (2), then the page (3)." loading="lazy" decoding="async" width="390" height="715"><span class="gd-pin" style="left:10.3%;top:28.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:76.9%;top:42.4%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.9%;top:48.3%" aria-hidden="true">3</span></div></div><figcaption>On a phone: press Menu (1), then a group (2), then the page (3).</figcaption></figure></div></section><section class="gd-task" id="getting-around-admin-search" data-gd-task><h2 class="gd-h2">Search</h2><p class="gd-p">The search box sits at the top of the menu, on every page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Type a booking number (CC-1042), a plate, a VIN, or a name or email address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Search</b> (or Enter). Results come in groups: bookings, cars, owners, partners and renters. Open one to go to its page.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/search?q=CC-10057</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/420"><img src="/guides/img/admin-32-search-desktop-ca548a70.jpg" alt="" loading="lazy" decoding="async" width="1440" height="420"><span class="gd-pin" style="left:7.4%;top:45.2%" aria-hidden="true">1</span><span class="gd-pin" style="left:95%;top:46.9%" aria-hidden="true">2</span></div></div></figure></div></section><section class="gd-task" id="getting-around-admin-keyboard-shortcuts" data-gd-task><h2 class="gd-h2">Keyboard shortcuts</h2><p class="gd-p">Press g, then a letter. Press / to jump to the search box.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Keys</th><th scope="col">Opens</th><th scope="col">Keys</th><th scope="col">Opens</th></tr></thead><tbody><tr><td>g t</td><td>To do</td><td>g v</td><td>Vehicles</td></tr><tr><td>g r</td><td>Requests</td><td>g l</td><td>Listings</td></tr><tr><td>g b</td><td>Bookings</td><td>g a</td><td>Applications</td></tr><tr><td>g c</td><td>Calendar</td><td>g o</td><td>Owners</td></tr><tr><td>g k</td><td>Tasks</td><td>g m</td><td>Payments and refunds</td></tr><tr><td>g s</td><td>All settings</td><td>/</td><td>Search</td></tr></tbody></table></div></section>');
select app.guide_release_section('admin', 'owners-and-onboarding', 'chapter', 'partners-company-cars-and-rentals-added-by-hand', 'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**Owners and partners** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The owner becomes active, the car gets its terms from the standard grid, the first and last month''s invoices are issued, and the owner gets an email to sign and pay in the owner portal.
3. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
4. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Owners

**Owners and partners** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

## An owner''s page

Open an owner from Owners. The details are in the right-hand column.

1. Upfront invoices: issue the first and last month''s insurance fee for each car whose terms are set.
2. Owner: address, sign-in, agreements, and what is still missing for the registry forms.
3. Statements and payouts for this owner.
4. Forms C and D, with a link to the review queue.
5. Further down: **View as (owner portal)**, **Send password link** and **Send a sign-in link to the owner portal**.

![](/guides/img/admin-13-owner-desktop-819a9f8b.jpg "desktop; size: 410 1030; address: carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309; pins: 1 24.6 4.4, 2 16.1 32.9, 3 31.5 73.2, 4 21.2 98.1")

## Paid and signed

**Owners and partners** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**Owners and partners** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
', 'Owners and onboarding', 'Applications, the terms and first invoice, adding a car for an owner, an owner''s terms and invoices, paid and signed, and Forms C and D.',
  'Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.

## Applications

**Owners and partners** > **Applications**. Every owner application, newest first.

1. The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.
2. Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.
3. Open an application to decide.

![](/guides/img/admin-33-applications-desktop-152f9e34.jpg "desktop; size: 1440 640; address: carmacars.ca/admin/applications; pins: 1 36.8 39.7, 2 48.6 53.1, 3 19.8 53.1")

## Decide on an application

One page holds everything: the owner, the car, the uploads, the four checks and the notes.

1. Check the driver''s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.
2. Press **Approve**. The step "Terms and first invoice" opens for each car, filled in with the owner''s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, Revenue Share, Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent.
3. Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.
4. Press **Approve** at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.
5. Missing something? Press **Ask for something**, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press **Send to the owner**. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.
6. Not a fit? Press **Decline**, write the Reason the owner reads, and press **Decline the application**. The owner is emailed for each car.

![](/guides/img/admin-34-application-desktop-98b64f92.jpg "desktop; size: 1440 812; address: carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca; pins: 1 72.9 67.1, 2 73.9 42.9, 3 84.7 42.9, 4 72.9 49.6")

The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says "Entered by staff" and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.

> Tip: Notes on the page are for staff only: **Add note** keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.

## Add a car for an owner

**Owners and partners** > **Add a car for an owner**, or **Add another car** on an owner''s page. The owner never has to fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN and press Decode, then the plate, colour, odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender''s information if you have them.
3. Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner''s terms.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.
5. Press **Add the car and set it up**. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.

Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, **Send the set-up email again** sends the owner the email with a fresh link.

## Owners

**Owners and partners** > **Owners**. Every owner, with their cars and where onboarding stands.

1. Each owner shows their application, how many cars, and where onboarding stands.
2. **View as (owner portal)** shows their portal. **Send password link** helps them sign in.
3. Invite an owner on file: fill in Name and Email under Invite an owner, then press **Send invitation**.

![](/guides/img/admin-12-owners-desktop-3a54d505.jpg "desktop; size: 1440 560; address: carmacars.ca/admin/owners; pins: 1 41.0 42.9, 2 37.4 49.3, 3 77.4 82.5")

The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer''s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.

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

**Owners and partners** > **Paid and signed**. What each owner still has to pay or sign, and how each item was done.

1. Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.
2. Open **Checklist and quick actions**. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.
3. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment**. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.
4. Signed on paper? Press **Record paper signature**. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.
5. The same checklist sits at the top of each owner''s page.

A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows "Paid by e-Transfer on " in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner''s documents.

> Watch out: Recorded the wrong thing, or a cheque bounced? Press **Void** beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.

## Forms C and D

**Owners and partners** > **Owner forms**. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.

1. Each row shows the owner, the form, the witnesses and when it was uploaded.
2. Press Open to read the photo or scan. Check each marked spot is signed or initialled.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg "desktop; size: 1440 470; address: carmacars.ca/admin/owner-forms; pins: 1 29.2 52.3, 2 57.6 52.3, 3 76.7 52.3")
',
  '<p class="gd-p">Owners apply on the site with List your car. Every application waits for you in one place, Applications: approve it, ask the owner for something, or decline it. Approved owners sign and pay in their portal.</p><section class="gd-task" id="owners-and-onboarding-applications" data-gd-task><h2 class="gd-h2">Applications</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Applications</b>. Every owner application, newest first.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The chips filter by status: New, Waiting on owner, Approved, Declined, or All. New applications also show on To do.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each row shows the application number, the owner, the car, how many of the four checks are done, and when they applied.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Open an application to decide.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/admin-33-applications-desktop-152f9e34.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:36.8%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:48.6%;top:53.1%" aria-hidden="true">2</span><span class="gd-pin" style="left:19.8%;top:53.1%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-decide-on-an-application" data-gd-task><h2 class="gd-h2">Decide on an application</h2><p class="gd-p">One page holds everything: the owner, the car, the uploads, the four checks and the notes.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Check the driver&#39;s licence, the ownership, the insurance and the lender or lessor. Mark each one Checked, fine, Problem or Not needed.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b>. The step &quot;Terms and first invoice&quot; opens for each car, filled in with the owner&#39;s negotiated terms (or the standard grid): Insurance Fee, Tracker Fee, Revenue Share, Install Fee and the first and last month amount (2 x the Insurance Fee unless you type an exact amount). Change any of them to the cent.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Choose the invoices: First and last month, Registration fee (any exact amount), Tracker install (only once trackers are available) and Another invoice. For each one choose Send now, Save as draft or Already paid. Already paid asks how (e-Transfer, cash, cheque, bank transfer or other), the date and the reference: it is recorded like Record payment and the owner gets the receipt, not an invoice.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Approve</b> at the bottom of the step. Nothing is set or sent before that. The owner becomes active, the documents open for one signature in their portal, only the invoices you chose are made, and the owner gets one email.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Missing something? Press <b class="gd-ui">Ask for something</b>, tick what you need (for example the ownership permit or the insurance slip), add a message if you like, and press <b class="gd-ui">Send to the owner</b>. The owner gets an email and a task in their portal; the application shows Waiting on owner until they answer.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Not a fit? Press <b class="gd-ui">Decline</b>, write the Reason the owner reads, and press <b class="gd-ui">Decline the application</b>. The owner is emailed for each car.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/applications/166e487a-11a1-4433-b1ca-8c2bc14bf5ca</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/812"><img src="/guides/img/admin-34-application-desktop-98b64f92.jpg" alt="" loading="lazy" decoding="async" width="1440" height="812"><span class="gd-pin" style="left:72.9%;top:67.1%" aria-hidden="true">1</span><span class="gd-pin" style="left:73.9%;top:42.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:84.7%;top:42.9%" aria-hidden="true">3</span><span class="gd-pin" style="left:72.9%;top:49.6%" aria-hidden="true">4</span></div></div></figure></div><p class="gd-p">The application has an Invoices tab: every invoice of its cars, drafts and voids included. An application staff entered for the owner says &quot;Entered by staff&quot; and who; approving it sends the owner the set-up email (review the details and sign) instead of the approval email.</p><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Notes on the page are for staff only: <b class="gd-ui">Add note</b> keeps a line on the record. When the owner answers a request, their answer is in the notes and the application is New again.</div></aside></section><section class="gd-task" id="owners-and-onboarding-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Add a car for an owner</b>, or <b class="gd-ui">Add another car</b> on an owner&#39;s page. The owner never has to fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN and press Decode, then the plate, colour, odometer, insurer and whether it is owned, financed or leased. Photos are optional: the listing shows sample photos until real ones are added. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: the same fields as Approve. For another car of the same owner they start from that owner&#39;s terms.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner (only then are you recorded as the one who brought the owner). How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and set it up</b>. The owner gets one email: review the details, correct anything, and sign. An owner with no sign-in gets the link to choose a password in that same email.</div></li></ol></div><p class="gd-p">Customer service and fleet assistants add cars the same way from their portal; theirs wait in Applications for you, with the terms and invoices they proposed already filled in. On an approved application staff entered, <b class="gd-ui">Send the set-up email again</b> sends the owner the email with a fresh link.</p></section><section class="gd-task" id="owners-and-onboarding-owners" data-gd-task><h2 class="gd-h2">Owners</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Owners</b>. Every owner, with their cars and where onboarding stands.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows their application, how many cars, and where onboarding stands.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">View as (owner portal)</b> shows their portal. <b class="gd-ui">Send password link</b> helps them sign in.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Invite an owner on file: fill in Name and Email under Invite an owner, then press <b class="gd-ui">Send invitation</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/560"><img src="/guides/img/admin-12-owners-desktop-3a54d505.jpg" alt="" loading="lazy" decoding="async" width="1440" height="560"><span class="gd-pin" style="left:41%;top:42.9%" aria-hidden="true">1</span><span class="gd-pin" style="left:37.4%;top:49.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.4%;top:82.5%" aria-hidden="true">3</span></div></div></figure></div><p class="gd-p">The owner signs everything at once in their portal (Check and sign: the agreements, schedules, Forms A and B and the official forms that are ready). The confirmations to tick, then one signature: CarmaCars countersigns at the same moment, under the signing officer&#39;s standing authorization. A car with a second owner on the ownership waits for that owner too: they get their own link by email and sign the same documents.</p></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-page" data-gd-task><h2 class="gd-h2">An owner&#39;s page</h2><p class="gd-p">Open an owner from Owners. Three tabs: Overview, Terms and Invoices. <b class="gd-ui">Add another car</b> and <b class="gd-ui">New invoice</b> sit under the name.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Upfront invoices: issue the first and last month amount agreed on each car&#39;s terms, for each car whose terms are set.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Owner: address, sign-in, agreements, and what is still missing for the registry forms.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Statements and payouts for this owner.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Forms C and D, with a link to the review queue.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Further down: <b class="gd-ui">View as (owner portal)</b>, <b class="gd-ui">Send password link</b> and <b class="gd-ui">Send a sign-in link to the owner portal</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owners/9e367055-7780-4451-822a-d79d5b59a309</span></div><div class="gd-imgwrap" style="aspect-ratio:410/1030"><img src="/guides/img/admin-13-owner-desktop-819a9f8b.jpg" alt="" loading="lazy" decoding="async" width="410" height="1030"><span class="gd-pin" style="left:24.6%;top:4.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:16.1%;top:32.9%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.5%;top:73.2%" aria-hidden="true">3</span><span class="gd-pin" style="left:21.2%;top:98.1%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="owners-and-onboarding-an-owner-s-terms" data-gd-task><h2 class="gd-h2">An owner&#39;s terms</h2><p class="gd-p">The Terms tab of an owner&#39;s page: what the owner pays and keeps, exact to the cent.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner&#39;s terms are the default for their cars: fill in what you negotiated (leave a field empty to keep the standard grid), the date it applies from, and press <b class="gd-ui">Save the terms</b>. They apply to cars whose terms are set from that date.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Each car has its own terms: open Change this car&#39;s terms, type the exact amounts and press <b class="gd-ui">Save the terms</b>. While the Vehicle Schedule is not signed, the schedule changes at once and the documents are made again.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">When the Vehicle Schedule is already signed, saving shows a warning: the owner must sign an updated schedule. Press <b class="gd-ui">Create the updated schedule and email the owner to sign</b>. The current terms stay until the owner signs; then the new ones apply from their date to invoices, debits and statements.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper instead? <b class="gd-ui">Record signed on paper</b> with the date. <b class="gd-ui">Withdraw it</b> cancels the update, with a reason.</div></li></ol></div></section><section class="gd-task" id="owners-and-onboarding-paid-and-signed" data-gd-task><h2 class="gd-h2">Paid and signed</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Paid and signed</b>. What each owner still has to pay or sign, and how each item was done.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each owner shows how many items are open and how many are done. Owners with nothing left are hidden; press Show every owner to see them.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open <b class="gd-ui">Checklist and quick actions</b>. Each line says Signed in the portal, Signed on paper, Paid by e-Transfer, Not signed, and so on.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid by e-Transfer, cheque, cash or bank transfer? Press <b class="gd-ui">Record payment</b>. Choose Paid by, the Date received and the Reference (the cheque number for a cheque). Leave Amount empty for the full balance, or type less for a partial payment. Add a photo of the cheque or a screenshot if you have one.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Signed on paper? Press <b class="gd-ui">Record paper signature</b>. Choose the Document, check Signed by and Date signed, add the witnesses where the form needs them, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">The same checklist sits at the top of each owner&#39;s page.</div></li></ol></div><p class="gd-p">A recorded payment marks the invoice paid (or partly paid), stops the automatic debit for that amount, sends the owner a receipt, and shows &quot;Paid by e-Transfer on &quot; in their portal. A paper signature counts as signed everywhere: the checklist, onboarding and the owner portal. The scan is kept privately with the owner&#39;s documents.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Recorded the wrong thing, or a cheque bounced? Press <b class="gd-ui">Void</b> beside it and give the reason. The invoice owes that amount again and the owner is told; a voided signature makes the item open again. Only an Admin can void.</div></aside></section><section class="gd-task" id="owners-and-onboarding-forms-c-and-d" data-gd-task><h2 class="gd-h2">Forms C and D</h2><p class="gd-p"><b class="gd-ui">Owners and partners</b> &gt; <b class="gd-ui">Owner forms</b>. Form C is signed on screen in the owner portal, with the witness on the same screen. Form D (and Form C on paper, if the owner prefers) is printed, signed in front of witnesses, and sent as a photo of each page.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Each row shows the owner, the form, the witnesses and when it was uploaded.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the photo or scan. Check each marked spot is signed or initialled.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/470"><img src="/guides/img/admin-22-owner-forms-desktop-c20ad300.jpg" alt="" loading="lazy" decoding="async" width="1440" height="470"><span class="gd-pin" style="left:29.2%;top:52.3%" aria-hidden="true">1</span><span class="gd-pin" style="left:57.6%;top:52.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:52.3%" aria-hidden="true">3</span></div></div></figure></div></section>');
select app.guide_release_section('admin', 'owner-money', 'chapter', 'owners-and-onboarding', 'Owner fee invoices are issued on the notice day and debited on the 15th. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**

1. **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month. An invoice is never issued twice.
2. **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.
3. Filter by Open, Paid, Failed or In arrears. Failed invoices show the reason.
4. Paid by e-Transfer, cheque, cash or bank transfer? Press **Record payment** under the invoice. Leave Amount empty for the full balance.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4, 4 51.6 84.3")

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, less refunds |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
', 'Owner money', 'Owner invoices (drafts, void and reissue, credit notes), the automatic debit, statements, payouts and the company statement.',
  'Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.

## Owner invoices

**Money** > **Owner invoices**. Every owner invoice, drafts and voids included. The same list is on each owner''s and each application''s Invoices tab.

1. Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.
2. **New invoice** makes an invoice of any amount for an owner''s car, for example a registration fee of $123.45.
3. The monthly run and tracker invoices: **Run the monthly invoices** issues the invoices for the 15th by hand, for a missed month (never twice); **Issue all tracker invoices** bills the Tracker Install for each car waiting for its tracker.

![](/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg "desktop; size: 1440 1060; address: carmacars.ca/admin/invoices; pins: 1 83.3 22.4, 2 41.7 35.7, 3 29.0 43.4")

## Make, edit and issue an invoice

A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.

1. Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. **Add a line** for more.
2. **Save as draft** to come back to it, or **Save and issue** to send it now. On a draft''s page, **Issue and email** sends it.
3. Paid another way? Press **Record payment** on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.
4. **Resend email** sends the invoice again. **PDF** opens it as a PDF.

## Correct an issued invoice

An issued invoice is never edited. You void it and issue a corrected one.

1. Press **Void**, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press **Void the invoice**. Its scheduled debit is cancelled and the owner is told.
2. The corrected invoice opens as a draft with the same lines. Fix the amounts and press **Save and issue**.
3. Already paid? Void the payment first, or press **Credit note** for the amount to give back: it gets its own number and the owner sees it.

Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.

## The automatic debit

The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.

:::flow
Notice day | Invoices issued, one notice per owner, 10 days before
Debit day | The 15th from 6:00: one debit per invoice
Cleared | The invoice is paid
Returned, insufficient funds | The $50.00 Late Fee is added once; the same amount is tried again within 30 days
Returned for another reason | No retry and no Late Fee: the debit pauses and you get a task
:::

1. The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.
2. How it runs explains the policy in words, read from Program settings.
3. Scheduled and processing lists each debit. **Pause** holds one (a reason is needed).
4. Owners lists each mandate. Use **Pause**, **Resume** or **Send a notice now**.

![](/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg "desktop; size: 1440 920; address: carmacars.ca/admin/debits; pins: 1 21.8 21.7, 2 21.5 35.5, 3 91.5 75.4, 4 84.7 94.7")

5. Results: each debit, cleared or returned, with the bank''s reason.
6. Run log: each notice and debit run, with its counts.
7. Notices sent: who was told what, for which debit day.

![](/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg "desktop; size: 1230 520; address: carmacars.ca/admin/debits; pins: 5 11.0 14.4, 6 10.2 52.3, 7 15.4 89.8")

Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner''s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.

> Watch out: Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner''s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.

## Owner statements

**Money** > **Owner statements**

1. Press **Build all for a month** (or **Build one**).
2. Open each draft. Check it, **Rebuild** after a correction, **Preview PDF**, then **Approve**.
3. Press **Issue to the owner**. **Reissue** sends a corrected copy; **CSV** exports it.

![](/guides/img/admin-16-statements-desktop-43a313ea.jpg "desktop; size: 1440 400; address: carmacars.ca/admin/statements; pins: 1 79.9 27.3")

![An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.](/guides/img/admin-17-statement-desktop-106ee57f.jpg "desktop; size: 1440 520; address: carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1; pins: 3 86.0 22.7")

## Staff commissions

**Money** > **Staff commissions**. Nothing is paid automatically.

:::flow
Not earned yet | The rental is ahead, or not paid in full
Pending approval | Completed and paid in full; a Sales month once it has ended
Approved | You approved it; the staff member is told
Paid | You recorded the payment; the staff member is told
Reversed | Cancelled, refunded or charged back; after payment it comes off the next payment
:::

1. By person shows each staff member''s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.
2. Press **Approve** on a person (everything that may be approved now) or on one commission.
3. Press **Record a payment**: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.
4. **Prices to review** lists prices typed by hand; **Sourcing claims** lists staff who say they sourced a website request; **Payments made** lists each payment.

|  | Commission |
| --- | --- |
| Sales | By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month''s rentals |
| Customer service, finance, fleet, field staff | 10% (also the field referral fee) |
| Base | The rental charge before tax, after discounts, less refunds |
| On the owner statement | An owner''s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner''s car: from CarmaCars'' commission. A CarmaCars-owned car: a CarmaCars expense |

> Tip: A commission that changes after an owner statement was built (a refund, or the month''s Sales tier) goes on the owner''s next statement as an adjustment line.

## Company statements

CarmaCars'' own monthly statement, in twelve sections.

1. Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.
2. Switch between Total, Per owner and Per vehicle.
3. Download **PDF**, **PDF by owner** or **PDF by vehicle**, or press **Email me the PDFs**.
4. **Finalize** freezes the month. **Rebuild** works until then.

![](/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg "desktop; size: 1440 760; address: carmacars.ca/admin/reports; pins: 1 20.8 28.0, 2 19.4 59.3, 3 77.1 15.5, 4 46.9 15.5")
',
  '<p class="gd-p">Owner fee invoices are issued on the notice day and debited on the 15th. Invoices of any amount are made by hand, as drafts first. Statements are built, approved and issued each month, and payouts follow.</p><section class="gd-task" id="owner-money-owner-invoices" data-gd-task><h2 class="gd-h2">Owner invoices</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner invoices</b>. Every owner invoice, drafts and voids included. The same list is on each owner&#39;s and each application&#39;s Invoices tab.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Filter by Drafts, Open, Partly paid, Paid, Failed, In arrears or Void, or search by invoice number or owner. Open an invoice to see everything about it.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">New invoice</b> makes an invoice of any amount for an owner&#39;s car, for example a registration fee of $123.45.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">The monthly run and tracker invoices: <b class="gd-ui">Run the monthly invoices</b> issues the invoices for the 15th by hand, for a missed month (never twice); <b class="gd-ui">Issue all tracker invoices</b> bills the Tracker Install for each car waiting for its tracker.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/invoices</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1060"><img src="/guides/img/admin-14-owner-invoices-desktop-dc4ed1f1.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1060"><span class="gd-pin" style="left:83.3%;top:22.4%" aria-hidden="true">1</span><span class="gd-pin" style="left:41.7%;top:35.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:29%;top:43.4%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="owner-money-make-edit-and-issue-an-invoice" data-gd-task><h2 class="gd-h2">Make, edit and issue an invoice</h2><p class="gd-p">A new invoice is a draft: the owner sees nothing and it is never debited until you issue it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the car, a title (for example Registration fee) and, if you like, the due date (empty: 7 days after it is issued). Each line: the description, the quantity, the unit amount to the cent, HST on or off, and a note. <b class="gd-ui">Add a line</b> for more.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Save as draft</b> to come back to it, or <b class="gd-ui">Save and issue</b> to send it now. On a draft&#39;s page, <b class="gd-ui">Issue and email</b> sends it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Paid another way? Press <b class="gd-ui">Record payment</b> on the invoice. The page lists the payments with their receipts, the automatic debits, the emails sent and the history.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Resend email</b> sends the invoice again. <b class="gd-ui">PDF</b> opens it as a PDF.</div></li></ol></div></section><section class="gd-task" id="owner-money-correct-an-issued-invoice" data-gd-task><h2 class="gd-h2">Correct an issued invoice</h2><p class="gd-p">An issued invoice is never edited. You void it and issue a corrected one.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Void</b>, write the reason (the owner reads it), keep Make a corrected invoice from it ticked, and press <b class="gd-ui">Void the invoice</b>. Its scheduled debit is cancelled and the owner is told.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The corrected invoice opens as a draft with the same lines. Fix the amounts and press <b class="gd-ui">Save and issue</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Already paid? Void the payment first, or press <b class="gd-ui">Credit note</b> for the amount to give back: it gets its own number and the owner sees it.</div></li></ol></div><p class="gd-p">Invoices issued before October 20, 2026 at the old default (for example $904.00, or $1,017.00 when the Insurance Fee was $450.00) are not changed by themselves. Where an owner agreed another amount, void them and reissue at the agreed amount.</p></section><section class="gd-task" id="owner-money-the-automatic-debit" data-gd-task><h2 class="gd-h2">The automatic debit</h2><p class="gd-p">The debit runs by itself. Your job is to watch for returned debits and owners without a mandate.</p><ol class="gd-flow"><li><b>1</b><span>Notice day</span><em>Invoices issued, one notice per owner, 10 days before</em></li><li><b>2</b><span>Debit day</span><em>The 15th from 6:00: one debit per invoice</em></li><li><b>3</b><span>Cleared</span><em>The invoice is paid</em></li><li><b>4</b><span>Returned, insufficient funds</span><em>The $50.00 Late Fee is added once; the same amount is tried again within 30 days</em></li><li><b>5</b><span>Returned for another reason</span><em>No retry and no Late Fee: the debit pauses and you get a task</em></li></ol><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The tiles show the next debit day and notice day, scheduled, processing, cleared and returned debits.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">How it runs explains the policy in words, read from Program settings.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Scheduled and processing lists each debit. <b class="gd-ui">Pause</b> holds one (a reason is needed).</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Owners lists each mandate. Use <b class="gd-ui">Pause</b>, <b class="gd-ui">Resume</b> or <b class="gd-ui">Send a notice now</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/920"><img src="/guides/img/admin-15-owner-debits-desktop-f65f061a.jpg" alt="" loading="lazy" decoding="async" width="1440" height="920"><span class="gd-pin" style="left:21.8%;top:21.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:21.5%;top:35.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:91.5%;top:75.4%" aria-hidden="true">3</span><span class="gd-pin" style="left:84.7%;top:94.7%" aria-hidden="true">4</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="5"><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Results: each debit, cleared or returned, with the bank&#39;s reason.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Run log: each notice and debit run, with its counts.</div></li><li><span class="gd-n" aria-hidden="true">7</span><div class="gd-t">Notices sent: who was told what, for which debit day.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/debits</span></div><div class="gd-imgwrap" style="aspect-ratio:1230/520"><img src="/guides/img/admin-15-owner-debits-desktop-8d4682bc.jpg" alt="" loading="lazy" decoding="async" width="1230" height="520"><span class="gd-pin" style="left:11%;top:14.4%" aria-hidden="true">5</span><span class="gd-pin" style="left:10.2%;top:52.3%" aria-hidden="true">6</span><span class="gd-pin" style="left:15.4%;top:89.8%" aria-hidden="true">7</span></div></div></figure></div><p class="gd-p">Insufficient funds: the $50.00 Late Fee is added to that invoice once and collected with the owner&#39;s next debit, and the original amount is tried again within 30 days, as section 4.4 of the Enrollment Agreement sets out. The retry is never more than the original amount. Returned again: the invoice is in arrears and you get a task.</p><aside class="gd-box gd-box--warn"><span class="gd-lbl">Watch out</span><div>Returned for any other reason (account closed, payment stopped, no authorization): there is no retry and no Late Fee. The owner&#39;s debit pauses, the owner gets an email asking them to fix the account or pay another way, and you get a task. A debit is never more than its notice said. An owner with no mandate gets an email on the notice day and you get a task; nothing is debited for them.</div></aside></section><section class="gd-task" id="owner-money-owner-statements" data-gd-task><h2 class="gd-h2">Owner statements</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Owner statements</b></p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Press <b class="gd-ui">Build all for a month</b> (or <b class="gd-ui">Build one</b>).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Open each draft. Check it, <b class="gd-ui">Rebuild</b> after a correction, <b class="gd-ui">Preview PDF</b>, then <b class="gd-ui">Approve</b>.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Issue to the owner</b>. <b class="gd-ui">Reissue</b> sends a corrected copy; <b class="gd-ui">CSV</b> exports it.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/400"><img src="/guides/img/admin-16-statements-desktop-43a313ea.jpg" alt="" loading="lazy" decoding="async" width="1440" height="400"><span class="gd-pin" style="left:79.9%;top:27.3%" aria-hidden="true">1</span></div></div></figure></div><div class="gd-figblock"><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/statements/f27936a8-9bfb-4280-81ae-c67ec47febe1</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/520"><img src="/guides/img/admin-17-statement-desktop-106ee57f.jpg" alt="An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts." loading="lazy" decoding="async" width="1440" height="520"><span class="gd-pin" style="left:86%;top:22.7%" aria-hidden="true">3</span></div></div><figcaption>An approved statement: the owner gets it by email with the PDF on the 10th, and payouts follow under Payouts.</figcaption></figure></div></section><section class="gd-task" id="owner-money-staff-commissions" data-gd-task><h2 class="gd-h2">Staff commissions</h2><p class="gd-p"><b class="gd-ui">Money</b> &gt; <b class="gd-ui">Staff commissions</b>. Nothing is paid automatically.</p><ol class="gd-flow"><li><b>1</b><span>Not earned yet</span><em>The rental is ahead, or not paid in full</em></li><li><b>2</b><span>Pending approval</span><em>Completed and paid in full; a Sales month once it has ended</em></li><li><b>3</b><span>Approved</span><em>You approved it; the staff member is told</em></li><li><b>4</b><span>Paid</span><em>You recorded the payment; the staff member is told</em></li><li><b>5</b><span>Reversed</span><em>Cancelled, refunded or charged back; after payment it comes off the next payment</em></li></ol><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">By person shows each staff member&#39;s month (Sales: rental days of 100 and the tier), what is not earned yet, pending approval, approved and paid.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press <b class="gd-ui">Approve</b> on a person (everything that may be approved now) or on one commission.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Record a payment</b>: choose how it was paid (e-Transfer, bank transfer, Wise, cash, the monthly pay statement or another way), the reference and the date.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Prices to review</b> lists prices typed by hand; <b class="gd-ui">Sourcing claims</b> lists staff who say they sourced a website request; <b class="gd-ui">Payments made</b> lists each payment.</div></li></ol></div><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col"></th><th scope="col">Commission</th></tr></thead><tbody><tr><td>Sales</td><td>By rental days of the month: under 50 days 10%, from 50 days 15%, from 100 days 20%, on all that month&#39;s rentals</td></tr><tr><td>Customer service, finance, fleet, field staff</td><td>10% (also the field referral fee)</td></tr><tr><td>Base</td><td>The rental charge before tax, after discounts, less refunds</td></tr><tr><td>On the owner statement</td><td>An owner&#39;s car: deducted with the kickbacks before Owner Revenue, its own line on the statement. A partner&#39;s car: from CarmaCars&#39; commission. A CarmaCars-owned car: a CarmaCars expense</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>A commission that changes after an owner statement was built (a refund, or the month&#39;s Sales tier) goes on the owner&#39;s next statement as an adjustment line.</div></aside></section><section class="gd-task" id="owner-money-company-statements" data-gd-task><h2 class="gd-h2">Company statements</h2><p class="gd-p">CarmaCars&#39; own monthly statement, in twelve sections.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Choose the month. The tiles show revenue, fees, refunds, expenses and the company net.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Switch between Total, Per owner and Per vehicle.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Download <b class="gd-ui">PDF</b>, <b class="gd-ui">PDF by owner</b> or <b class="gd-ui">PDF by vehicle</b>, or press <b class="gd-ui">Email me the PDFs</b>.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t"><b class="gd-ui">Finalize</b> freezes the month. <b class="gd-ui">Rebuild</b> works until then.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/admin/reports</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/760"><img src="/guides/img/admin-18-company-statements-desktop-8e2738ed.jpg" alt="" loading="lazy" decoding="async" width="1440" height="760"><span class="gd-pin" style="left:20.8%;top:28%" aria-hidden="true">1</span><span class="gd-pin" style="left:19.4%;top:59.3%" aria-hidden="true">2</span><span class="gd-pin" style="left:77.1%;top:15.5%" aria-hidden="true">3</span><span class="gd-pin" style="left:46.9%;top:15.5%" aria-hidden="true">4</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'your-workday', 'chapter', 'start-here', 'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors and Live chat). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar), Renters (Find a renter), Rentals (Add a rental, New quote) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
', 'Your workday', 'The menu, To do, task actions, Today, switching functions and your scorecard.',
  'Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.

## The menu

My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors and Live chat). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.

| Function | Groups and pages |
| --- | --- |
| Customer service | Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms) |
| Sales | Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads) |
| Finance | Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote) |
| Fleet | Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote) |

## To do

Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.

1. The top line shows your function and how many tasks are open.
2. Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.
3. Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.
4. Press **Take it** to make it yours. **Sheet** opens the step-by-step procedure.

![](/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg "desktop; size: 1440 640; address: carmacars.ca/va; pins: 1 13.9 5.0, 2 36.1 17.5, 3 31.9 43.8, 4 91.7 52.3")

## Work a task

Open the task. The buttons along the top move it on.

| Button | What it does |
| --- | --- |
| **Open the working screen** | Jumps to the booking, car or owner the task is about. |
| **Done** | You finished it. It leaves the queue. |
| **Waiting** | You are waiting on someone (a renter, an owner). It stays yours. |
| **Escalate** | It needs an Admin. Add why. |
| **Hand over** | Give it to someone else on the team. |
| **Add a note** | Leave a note for whoever looks next. |

> Tip: Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.

## Today

1. Today lists pickups and returns, and what is due, for your function.
2. Press a booking number to open it. **To do** takes you back to your tasks.

![](/guides/img/va-cs-02-today-desktop-dfd277b7.jpg "desktop; size: 1440 700; address: carmacars.ca/va/today; pins: 1 20.8 14.3")

## Documents to sign

Your staff agreement, when CarmaCars sends it.

1. The queue shows "You have a document to sign". Press **Read and sign**.
2. Check the key values at the top (your role, hours, rate and start date), then press **Read the PDF** and read it.
3. Press **Sign**. Your full legal name is your signature (or press **Draw instead**). Several documents? One signature covers all of them. The signed copy stays on the same page.

## Several functions? Switch with Working as

If you cover more than one function, **Working as** above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.

## Your scorecard

1. Open **My work** > **My scorecard**.
2. By week shows each measure, its target and your result for each week.
3. A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.
4. The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.

![](/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg "desktop; size: 1440 360; address: carmacars.ca/va/scorecard; pins: 1 4.2 39.7, 2 62.5 58.3")
',
  '<p class="gd-p">Every function works the same way: start on To do, take the oldest task, finish it, and check Today for pickups and returns. The menu keeps your own work first, then the screens of your function in a few groups.</p><section class="gd-task" id="your-workday-the-menu" data-gd-task><h2 class="gd-h2">The menu</h2><p class="gd-p">My work comes first: To do, Today, My scorecard and My sales (customer service and Sales also have Live visitors and Live chat). Then the groups of your function. The current group is open; press another to open it. On a phone the whole menu sits behind one Menu button.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Function</th><th scope="col">Groups and pages</th></tr></thead><tbody><tr><td>Customer service</td><td>Bookings (Requests, New quote, Add a rental, Calendar), Renters (Messages, Find a renter), Cars (Listings, Similar cars), Owners (Owners and enquiries, Add a car for an owner, Owner forms)</td></tr><tr><td>Sales</td><td>Bookings (Requests and offers, New quote, Add a rental, Calendar), Owners (Owner leads)</td></tr><tr><td>Finance</td><td>Money (Payments, deposits and refunds, Tolls and tickets, Reconciliation, Turo trips), Renters and bookings (Find a renter, Calendar), Rentals (Add a rental, New quote)</td></tr><tr><td>Fleet</td><td>Field work (Field jobs, Daily checks, Photo reviews), Cars (Listings, Similar cars, Calendar, Calendar sync, Add a car for an owner), Renters (Find a renter), Rentals (Add a rental, New quote)</td></tr></tbody></table></div></section><section class="gd-task" id="your-workday-to-do" data-gd-task><h2 class="gd-h2">To do</h2><p class="gd-p">Tasks come to your function on their own: new requests, renter replies, failed payments, toll notices and more.</p><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The top line shows your function and how many tasks are open.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Filter: All, Mine, Unassigned or Waiting; Any time, Overdue, Due today or Escalated; and by type.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Each row has a priority, the task, its record, when it is due and how long it has waited. The oldest due is first.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Take it</b> to make it yours. <b class="gd-ui">Sheet</b> opens the step-by-step procedure.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-01-queue-desktop-c36a8e2d.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:13.9%;top:5%" aria-hidden="true">1</span><span class="gd-pin" style="left:36.1%;top:17.5%" aria-hidden="true">2</span><span class="gd-pin" style="left:31.9%;top:43.8%" aria-hidden="true">3</span><span class="gd-pin" style="left:91.7%;top:52.3%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="your-workday-work-a-task" data-gd-task><h2 class="gd-h2">Work a task</h2><p class="gd-p">Open the task. The buttons along the top move it on.</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">What it does</th></tr></thead><tbody><tr><td><b class="gd-ui">Open the working screen</b></td><td>Jumps to the booking, car or owner the task is about.</td></tr><tr><td><b class="gd-ui">Done</b></td><td>You finished it. It leaves the queue.</td></tr><tr><td><b class="gd-ui">Waiting</b></td><td>You are waiting on someone (a renter, an owner). It stays yours.</td></tr><tr><td><b class="gd-ui">Escalate</b></td><td>It needs an Admin. Add why.</td></tr><tr><td><b class="gd-ui">Hand over</b></td><td>Give it to someone else on the team.</td></tr><tr><td><b class="gd-ui">Add a note</b></td><td>Leave a note for whoever looks next.</td></tr></tbody></table></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Work oldest due first. A task meets its target when it is done by its due time; that is what your scorecard counts.</div></aside></section><section class="gd-task" id="your-workday-today" data-gd-task><h2 class="gd-h2">Today</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Today lists pickups and returns, and what is due, for your function.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press a booking number to open it. <b class="gd-ui">To do</b> takes you back to your tasks.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/today</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/700"><img src="/guides/img/va-cs-02-today-desktop-dfd277b7.jpg" alt="" loading="lazy" decoding="async" width="1440" height="700"><span class="gd-pin" style="left:20.8%;top:14.3%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="your-workday-documents-to-sign" data-gd-task><h2 class="gd-h2">Documents to sign</h2><p class="gd-p">Your staff agreement, when CarmaCars sends it.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The queue shows &quot;You have a document to sign&quot;. Press <b class="gd-ui">Read and sign</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Check the key values at the top (your role, hours, rate and start date), then press <b class="gd-ui">Read the PDF</b> and read it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Sign</b>. Your full legal name is your signature (or press <b class="gd-ui">Draw instead</b>). Several documents? One signature covers all of them. The signed copy stays on the same page.</div></li></ol></div></section><section class="gd-task" id="your-workday-several-functions-switch-with-working-as" data-gd-task><h2 class="gd-h2">Several functions? Switch with Working as</h2><p class="gd-p">If you cover more than one function, <b class="gd-ui">Working as</b> above the menu lists them: Customer service, Finance, Fleet and Sales. Choose one; the menu, To do and Today change to that function.</p></section><section class="gd-task" id="your-workday-your-scorecard" data-gd-task><h2 class="gd-h2">Your scorecard</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">My work</b> &gt; <b class="gd-ui">My scorecard</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">By week shows each measure, its target and your result for each week.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">A task meets its target when done by its due time. Daily checks count when done by 9:00 and 18:00.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">The first reply target is 5 minutes: a new booking request, an enquiry, a change the renter asked for or a renter message is due 5 minutes after it comes in. An Admin sets it in Program settings, and the target column shows the one in force.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/scorecard</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/360"><img src="/guides/img/va-sales-05-scorecard-desktop-78ec1b03.jpg" alt="" loading="lazy" decoding="async" width="1440" height="360"><span class="gd-pin" style="left:4.2%;top:39.7%" aria-hidden="true">1</span><span class="gd-pin" style="left:62.5%;top:58.3%" aria-hidden="true">2</span></div></div></figure></div></section>');
select app.guide_release_section('va', 'customer-service', 'chapter', 'your-workday', 'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact.
2. Find a real car of the same kind and price that is free for those dates, and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
', 'Customer service', 'Requests and offers, new quotes, renter messages, find a renter, owner forms, late returns.',
  'You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter''s first person.

Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.

## Answer a request

1. Open **Requests**. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.
2. Waiting shows how long the renter has waited. Open the booking number.

![](/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg "desktop; size: 1440 640; address: carmacars.ca/va/requests; pins: 1 27.1 17.5, 2 52.8 32.8")

3. On the Review tab, check the request: the car is free, the renter, the places.
4. Press **Adjust the booking** to change the car, dates, places, price or extras, then **Save changes**.
5. Add a message and press **Send the offer**. Within your limit you can also use **Approve (within my limit)** or **Approve and send the pay link**.
6. Can''t do it? **Decline** with Reason and any alternative. Need to know more? **Ask the renter**.

![](/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg "desktop; size: 1440 1000; address: carmacars.ca/va/bookings/CC-10056?tab=review; pins: 3 69.4 24.0, 4 95.8 98.0")

> Tip: Reply within 5 minutes: send the offer, or ask the renter what you need. That is the "First reply in opening hours" measure on your scorecard. Requests waiting longer show in red.

## An enquiry on an example car

Some cars on the site are marked "Example car": samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.

1. The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact.
2. Find a real car of the same kind and price that is free for those dates, and make a **New quote** for it.
3. Call or email the person with the car and the price, then mark the task done.

> Tip: Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.

## New quote for a caller

1. Open **New quote**. Choose the Car, the Pickup and Return (at least 2 hours from now).
2. Choose how the lead came in, then the caller''s Full legal name, Email, Mobile and Date of birth.
3. Set the Licence class and Damage cover, and note places, extras and what they asked.
4. Press **Create the request**. It opens like any request; send the offer from there.

![](/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg "desktop; size: 1220 1260; address: carmacars.ca/va/quotes/new; pins: 1 72.1 15.6, 2 72.1 41.7, 3 72.1 72.7, 4 63.9 85.5")

## Renter messages and Find a renter

1. **Renter messages** lists the latest messages with their booking. Open the booking to reply, then press **Send**.
2. **Find a renter**: search by name, email, phone or booking number.
3. To open a renter''s private details, press **Open with a reason**. The reason is kept in the access log.

![](/guides/img/va-cs-06-messages-desktop-3441fa91.jpg "desktop; size: 1440 260; address: carmacars.ca/va/messages; pins: 1 32.6 48.5")

## Add a car for an owner

Open **Owners** > **Add a car for an owner** (fleet: under Cars). You enter everything for the owner; they never fill in the application.

1. The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.
2. The car: type the VIN and press Decode, then the details. Upload the ownership permit, the insurance slip and the lender''s information if you have them. Photos are optional.
3. Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.
4. Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.
5. Press **Add the car and send to an Admin**. The application waits in the Admin''s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.

## Owner forms (Forms C and D)

1. Open **Owner forms**. Each row is a scan an owner uploaded, with the witnesses and the status.
2. Press Open to read the scan. Check every page is there and signed, with each witness''s signature and name.
3. Press **Approve**, or **Send back** with What to fix (the owner reads this).

![](/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg "desktop; size: 1440 300; address: carmacars.ca/va/owner-forms; pins: 2 68.6 36.7, 3 76.7 36.7")

## A rental agreement signed on paper

1. Open the booking. Under Signed on paper, press **Record paper signature**.
2. Choose the Rental agreement, or the booking change the renter signed.
3. Check Signed by and Date signed, and upload the scan of every signed page.
4. Press **Record signature**. It counts as signed, and the renter is not asked to sign again.

## A change to a confirmed booking

On a booking''s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press **Preview the price**, then **Send to the renter**. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.

## A late return

A booking past its return time shows the late return panel. Work it in order:

| Button | When |
| --- | --- |
| **Log a call** | Record each call to the renter and what they said. |
| **Send T13** | The first late notice email. |
| **Send T14 (final notice)** | The final notice. |
| **Request disable** | Ask an Admin to approve disabling the car. |
| **Open an incident** | When the car is not coming back as planned. |
',
  '<p class="gd-p">You answer requests with offers, quote callers, reply to renters, look renters up, and review owner forms. You are often the renter&#39;s first person.</p><p class="gd-p">Your rail: Queue, Today, Requests, New quote, Renter messages, Find a renter, Calendar, Listings, Similar cars, Owners and enquiries, Owner forms and Scorecard.</p><section class="gd-task" id="customer-service-answer-a-request" data-gd-task><h2 class="gd-h2">Answer a request</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Requests</b>. Filter by New, Waiting on the renter, Pushed back, Offer out or Offer expired.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Waiting shows how long the renter has waited. Open the booking number.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/requests</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/640"><img src="/guides/img/va-cs-03-requests-desktop-b3c66d25.jpg" alt="" loading="lazy" decoding="async" width="1440" height="640"><span class="gd-pin" style="left:27.1%;top:17.5%" aria-hidden="true">1</span><span class="gd-pin" style="left:52.8%;top:32.8%" aria-hidden="true">2</span></div></div></figure></div><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol" start="3"><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">On the Review tab, check the request: the car is free, the renter, the places.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Adjust the booking</b> to change the car, dates, places, price or extras, then <b class="gd-ui">Save changes</b>.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Add a message and press <b class="gd-ui">Send the offer</b>. Within your limit you can also use <b class="gd-ui">Approve (within my limit)</b> or <b class="gd-ui">Approve and send the pay link</b>.</div></li><li><span class="gd-n" aria-hidden="true">6</span><div class="gd-t">Can&#39;t do it? <b class="gd-ui">Decline</b> with Reason and any alternative. Need to know more? <b class="gd-ui">Ask the renter</b>.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/bookings/CC-10056?tab=review</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/1000"><img src="/guides/img/va-cs-04-booking-review-desktop-52c68a73.jpg" alt="" loading="lazy" decoding="async" width="1440" height="1000"><span class="gd-pin" style="left:69.4%;top:24%" aria-hidden="true">3</span><span class="gd-pin" style="left:95.8%;top:98%" aria-hidden="true">4</span></div></div></figure></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within 5 minutes: send the offer, or ask the renter what you need. That is the &quot;First reply in opening hours&quot; measure on your scorecard. Requests waiting longer show in red.</div></aside></section><section class="gd-task" id="customer-service-an-enquiry-on-an-example-car" data-gd-task><h2 class="gd-h2">An enquiry on an example car</h2><p class="gd-p">Some cars on the site are marked &quot;Example car&quot;: samples that show the kind of cars we rent. A request on one is an enquiry, never a booking.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The task Suggest a similar real car comes to To do with the enquiry number (EQ-1001 and up), the car asked for, the dates and the contact.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Find a real car of the same kind and price that is free for those dates, and make a <b class="gd-ui">New quote</b> for it.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Call or email the person with the car and the price, then mark the task done.</div></li></ol></div><aside class="gd-box"><span class="gd-lbl">Tip</span><div>Reply within the first reply target, as for any request. Never offer the example car itself: it does not exist.</div></aside></section><section class="gd-task" id="customer-service-new-quote-for-a-caller" data-gd-task><h2 class="gd-h2">New quote for a caller</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">New quote</b>. Choose the Car, the Pickup and Return (at least 2 hours from now).</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose how the lead came in, then the caller&#39;s Full legal name, Email, Mobile and Date of birth.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Set the Licence class and Damage cover, and note places, extras and what they asked.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Create the request</b>. It opens like any request; send the offer from there.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/quotes/new</span></div><div class="gd-imgwrap" style="aspect-ratio:1220/1260"><img src="/guides/img/va-cs-05-new-quote-desktop-4e386b1c.jpg" alt="" loading="lazy" decoding="async" width="1220" height="1260"><span class="gd-pin" style="left:72.1%;top:15.6%" aria-hidden="true">1</span><span class="gd-pin" style="left:72.1%;top:41.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:72.1%;top:72.7%" aria-hidden="true">3</span><span class="gd-pin" style="left:63.9%;top:85.5%" aria-hidden="true">4</span></div></div></figure></div></section><section class="gd-task" id="customer-service-renter-messages-and-find-a-renter" data-gd-task><h2 class="gd-h2">Renter messages and Find a renter</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t"><b class="gd-ui">Renter messages</b> lists the latest messages with their booking. Open the booking to reply, then press <b class="gd-ui">Send</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t"><b class="gd-ui">Find a renter</b>: search by name, email, phone or booking number.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">To open a renter&#39;s private details, press <b class="gd-ui">Open with a reason</b>. The reason is kept in the access log.</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/messages</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/260"><img src="/guides/img/va-cs-06-messages-desktop-3441fa91.jpg" alt="" loading="lazy" decoding="async" width="1440" height="260"><span class="gd-pin" style="left:32.6%;top:48.5%" aria-hidden="true">1</span></div></div></figure></div></section><section class="gd-task" id="customer-service-add-a-car-for-an-owner" data-gd-task><h2 class="gd-h2">Add a car for an owner</h2><p class="gd-p">Open <b class="gd-ui">Owners</b> &gt; <b class="gd-ui">Add a car for an owner</b> (fleet: under Cars). You enter everything for the owner; they never fill in the application.</p><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">The owner: find them by name, email or phone, or choose New owner and enter the name, email, phone and address.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">The car: type the VIN and press Decode, then the details. Upload the ownership permit, the insurance slip and the lender&#39;s information if you have them. Photos are optional.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Terms and first invoice: what was agreed with the owner, to the cent. An Admin checks them before anything is sent.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Who sourced the owner: Entered for CarmaCars, or I sourced this owner. How the owner signs: by email, or on paper.</div></li><li><span class="gd-n" aria-hidden="true">5</span><div class="gd-t">Press <b class="gd-ui">Add the car and send to an Admin</b>. The application waits in the Admin&#39;s Applications, marked Entered by staff with your name. When the Admin approves, the owner gets one email to review and sign.</div></li></ol></div></section><section class="gd-task" id="customer-service-owner-forms-forms-c-and-d" data-gd-task><h2 class="gd-h2">Owner forms (Forms C and D)</h2><div class="gd-stepblock gd-stepblock--below"><div class="gd-stepcol"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open <b class="gd-ui">Owner forms</b>. Each row is a scan an owner uploaded, with the witnesses and the status.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Press Open to read the scan. Check every page is there and signed, with each witness&#39;s signature and name.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Press <b class="gd-ui">Approve</b>, or <b class="gd-ui">Send back</b> with What to fix (the owner reads this).</div></li></ol></div><figure class="gd-fig gd-fig--desk"><div class="gd-browser"><div class="gd-bar" aria-hidden="true"><i></i><i></i><i></i><span class="gd-addr">carmacars.ca/va/owner-forms</span></div><div class="gd-imgwrap" style="aspect-ratio:1440/300"><img src="/guides/img/va-cs-08-owner-forms-desktop-eceaee0b.jpg" alt="" loading="lazy" decoding="async" width="1440" height="300"><span class="gd-pin" style="left:68.6%;top:36.7%" aria-hidden="true">2</span><span class="gd-pin" style="left:76.7%;top:36.7%" aria-hidden="true">3</span></div></div></figure></div></section><section class="gd-task" id="customer-service-a-rental-agreement-signed-on-paper" data-gd-task><h2 class="gd-h2">A rental agreement signed on paper</h2><div class="gd-stepblock"><ol class="gd-ol"><li><span class="gd-n" aria-hidden="true">1</span><div class="gd-t">Open the booking. Under Signed on paper, press <b class="gd-ui">Record paper signature</b>.</div></li><li><span class="gd-n" aria-hidden="true">2</span><div class="gd-t">Choose the Rental agreement, or the booking change the renter signed.</div></li><li><span class="gd-n" aria-hidden="true">3</span><div class="gd-t">Check Signed by and Date signed, and upload the scan of every signed page.</div></li><li><span class="gd-n" aria-hidden="true">4</span><div class="gd-t">Press <b class="gd-ui">Record signature</b>. It counts as signed, and the renter is not asked to sign again.</div></li></ol></div></section><section class="gd-task" id="customer-service-a-change-to-a-confirmed-booking" data-gd-task><h2 class="gd-h2">A change to a confirmed booking</h2><p class="gd-p">On a booking&#39;s Changes tab you can propose new dates, times or another car, as an Admin does: set the change, write the reason, press <b class="gd-ui">Preview the price</b>, then <b class="gd-ui">Send to the renter</b>. The renter has 48 hours to accept and sign the amendment. You also send a new signing link to an additional driver from the booking screen.</p></section><section class="gd-task" id="customer-service-a-late-return" data-gd-task><h2 class="gd-h2">A late return</h2><p class="gd-p">A booking past its return time shows the late return panel. Work it in order:</p><div class="gd-tablewrap"><table class="gd-table"><thead><tr><th scope="col">Button</th><th scope="col">When</th></tr></thead><tbody><tr><td><b class="gd-ui">Log a call</b></td><td>Record each call to the renter and what they said.</td></tr><tr><td><b class="gd-ui">Send T13</b></td><td>The first late notice email.</td></tr><tr><td><b class="gd-ui">Send T14 (final notice)</b></td><td>The final notice.</td></tr><tr><td><b class="gd-ui">Request disable</b></td><td>Ask an Admin to approve disabling the car.</td></tr><tr><td><b class="gd-ui">Open an incident</b></td><td>When the car is not coming back as planned.</td></tr></tbody></table></div></section>');
-- GUIDES OT END

-- ================================================================ 10. the email catalogue
-- CATALOGUE OT START (generated by supabase/seed/owner_terms_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('owner_car_set_up', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'We set up your {{vehicle_name}}: review the details and sign', 'Your agreements are filled in. Check them, correct anything, and sign once.', 'Immediate, after approval', 'Staff added a car for the owner (Admin, customer service or fleet: Add a car for this owner) and an Admin approved it with its terms and first invoices. The owner''s one email: review the details and sign. Not sent when the owner signs on paper. For an owner with no sign-in yet it carries the link to choose a password.', null, '/owner/review', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_password_url","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"owner_email","type":"string"},{"name":"password_url","type":"url"},{"name":"reply_time","type":"string","global":true},{"name":"staff_name","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_car_set_up.html', 'templates/owner_car_set_up.txt'),
  ('owner_invoice_issued', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', '{{invoice_title}} {{invoice_number}} for the {{vehicle_name}}: {{invoice_total}}', 'Due {{due_date}}. Pay from the invoice page by card, debit or e-Transfer.', 'Immediate', 'An Admin issues an owner invoice made by hand (a registration fee or any other amount agreed with the owner, Admin > Money > Owner invoices, the owner page or the application), or a credit note, or presses Resend on one. Not sent for an invoice recorded as already paid (the receipt goes instead).', null, '/owner/invoices/{{invoice_number}}', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"due_date","type":"string"},{"name":"first_name","type":"string"},{"name":"has_notes","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_lines","type":"list","fields":["label","amount"]},{"name":"invoice_notes","type":"string"},{"name":"invoice_number","type":"string"},{"name":"invoice_title","type":"string"},{"name":"invoice_total","type":"string"},{"name":"is_credit","type":"boolean"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_invoice_issued.html', 'templates/owner_invoice_issued.txt'),
  ('owner_invoice_voided', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <billing@carmacars.ca>', 'billing@carmacars.ca', 'Invoice {{invoice_number}} is cancelled', '{{void_reason}}', 'Immediate', 'An Admin voids an issued owner invoice with a reason (nothing was paid on it). Its scheduled debit is cancelled. When a corrected invoice replaces it, that invoice has its own email once it is issued.', null, '/owner/invoices', '[{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"has_replacement","type":"boolean"},{"name":"instagram_url","type":"url","global":true},{"name":"invoice_number","type":"string"},{"name":"invoice_total","type":"string"},{"name":"opening_hours","type":"string","global":true},{"name":"payee_name","type":"string"},{"name":"replacement_number","type":"string"},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"},{"name":"void_reason","type":"string"}]'::jsonb, 'templates/owner_invoice_voided.html', 'templates/owner_invoice_voided.txt'),
  ('owner_schedule_resign', 'owner', '{}'::text[], 'transactional', false, null, 'CarmaCars <owners@carmacars.ca>', 'owners@carmacars.ca', 'Please sign the updated Vehicle Schedule for the {{vehicle_name}}', 'New terms from {{effective_date}}, once you sign.', 'Immediate', 'An Admin changes the terms of a car whose Vehicle Schedule is signed and confirms that the owner must sign an updated one (Admin > the owner > Terms). The new terms apply from their date only once the owner signs; until then the signed terms stay in place.', null, '/owner/sign/schedule/{{change_id}}', '[{"name":"change_id","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"effective_date","type":"string"},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"support_phone","type":"string","global":true},{"name":"terms_rows","type":"list","fields":["label","before","after"]},{"name":"tiktok_url","type":"url","global":true},{"name":"vehicle_name","type":"string"}]'::jsonb, 'templates/owner_schedule_resign.html', 'templates/owner_schedule_resign.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE OT END
update notification_catalogue set emitted_by = 'owner_invoices_notify (0067), app.owner_invoice_resend (0067)' where code = 'owner_invoice_issued';
update notification_catalogue set emitted_by = 'app.owner_invoice_void (0067)' where code = 'owner_invoice_voided';
update notification_catalogue set emitted_by = 'app.owner_terms_save (0067)' where code = 'owner_schedule_resign';
update notification_catalogue set emitted_by = 'app.owner_setup_email (0067)' where code = 'owner_car_set_up';
update notification_catalogue set trigger_text = 'An Admin approves an owner application the owner sent themselves (Admin > Owners and partners > Applications > Approve): the owner is active, each car has the terms the Admin confirmed, the agreements open for one signature in the owner portal, and only the invoices the Admin chose are sent (their own emails go too). An application staff entered for the owner gets owner_car_set_up instead.'
 where code = 'owner_application_approved';
