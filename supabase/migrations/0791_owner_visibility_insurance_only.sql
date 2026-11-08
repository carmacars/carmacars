-- 0791: only an insurance replacement is hidden from the car's owner.
-- Every other booking (billed to the renter) is shown to the owner now, and every new one is shown from the start.
-- A placeholder hold keeps its own rule (the owner sees its dates only). An insurance replacement (bill_to insurer or split) keeps the Program setting and any choice staff made.

alter table program_settings add column if not exists owner_hide_insurance_only boolean not null default true;
comment on column program_settings.owner_hide_insurance_only is 'On (0791): only an insurance replacement (billed to an insurer) can be hidden from the car''s owner; every booking billed to the renter is shown.';

-- 1. new bookings: the Program setting's hiding applies to insurance replacements only
create or replace function app.bookings_owner_visibility_default() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.owner_visibility is null then
    new.owner_visibility := case when coalesce(new.bill_to, 'renter') = 'renter' and (app.settings()).owner_hide_insurance_only then 'shown'
                                 else app.owner_visibility_default(new.booking_type) end;
  end if;
  return new;
end $$;

-- 2. staff may hide only an insurance replacement from now on
alter function app.booking_owner_visibility_apply(bookings, text, text, uuid, text) rename to booking_owner_visibility_apply_pre0791;
create or replace function app.booking_owner_visibility_apply(b bookings, p_to text, p_reason text, p_by uuid, p_how text default 'staff') returns void
language plpgsql security definer set search_path = public, app as $$
begin
  if p_to is distinct from 'shown' and coalesce(b.bill_to, 'renter') = 'renter' and (app.settings()).owner_hide_insurance_only then
    raise exception 'Only an insurance replacement can be hidden from the owner. This booking is billed to the renter, so the owner sees it.' using errcode = '23514';
  end if;
  perform app.booking_owner_visibility_apply_pre0791(b, p_to, p_reason, p_by, p_how);
end $$;

-- 3. every booking billed to the renter that is hidden now is shown, with its history line
do $$
declare b bookings;
begin
  for b in select * from bookings where coalesce(owner_visibility, 'shown') <> 'shown' and coalesce(bill_to, 'renter') = 'renter'
                      and not coalesce(is_placeholder, false) loop
    perform app.booking_owner_visibility_apply_pre0791(b, 'shown', 'Only insurance replacements are hidden from owners (0791)', null, 'staff');
  end loop;
end $$;

-- 4. privileges
revoke all on function app.booking_owner_visibility_apply(bookings, text, text, uuid, text) from public, anon, authenticated;
grant execute on function app.booking_owner_visibility_apply(bookings, text, text, uuid, text) to service_role;
revoke all on function app.booking_owner_visibility_apply_pre0791(bookings, text, text, uuid, text) from public, anon, authenticated;
grant execute on function app.booking_owner_visibility_apply_pre0791(bookings, text, text, uuid, text) to service_role;

-- 4b. the hire's commission text printed "10.0000000000000000%" (0730): percentages read 10%, 12.5%
create or replace function app.pct_text(p numeric) returns text language sql immutable set search_path = public, app as $f$
  select rtrim(rtrim(to_char(p, 'FM9999990.00'), '0'), '.')
$f$;
create or replace function app.hire_standard_pay(p_path text, p_role uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  s program_settings := app.settings();
  r hiring_roles;
  d jsonb := coalesce(s.staff_agreement_defaults, '{}'::jsonb);
  v_rate text;
  v_cents bigint;
begin
  select * into r from hiring_roles where id = p_role;
  if p_path in ('sales_in_person', 'sales_remote') then
    return jsonb_build_object('basis', 'commission', 'cents', null, 'currency', null,
      'text', case p_path
        when 'sales_remote' then format('Commission only, remote tiers: %s%%, %s%% and %s%% of the rental charge by rental days in the month; a month under the minimum drops %s tier (never under %s%%)',
          app.pct_text(s.sales_remote_tier_low_bps / 100.0), app.pct_text(s.sales_remote_tier_mid_bps / 100.0), app.pct_text(s.sales_remote_tier_high_bps / 100.0), s.sales_remote_drop_tiers, app.pct_text(s.sales_remote_floor_bps / 100.0))
        else format('Commission only, in-person tiers: %s%%, %s%% and %s%% of the rental charge by rental days in the month',
          app.pct_text(coalesce(s.sales_tier_low_bps, 1000) / 100.0), app.pct_text(coalesce(s.sales_tier_mid_bps, 1500) / 100.0), app.pct_text(coalesce(s.sales_tier_high_bps, 2000) / 100.0)) end);
  end if;
  if p_path = 'field' then
    if r.id is not null and r.staff_kind = 'field' and r.pay_unit = 'HOUR' and r.pay_min_cents is not null then v_cents := r.pay_min_cents;
    else v_rate := d #>> '{field,wage}'; v_cents := case when v_rate ~ '^\d+(\.\d{1,2})?$' then round(v_rate::numeric * 100) end; end if;
    return jsonb_build_object('basis', 'hourly', 'cents', coalesce(v_cents, 1800), 'currency', coalesce(r.pay_currency, d #>> '{field,currency}', 'CAD'),
      'text', format('%s %s an hour', coalesce(r.pay_currency, d #>> '{field,currency}', 'CAD'), to_char(coalesce(v_cents, 1800) / 100.0, 'FM999990.00')));
  end if;
  if r.id is not null and app.hire_default_path(r) = p_path and r.pay_unit = 'MONTH' and r.pay_min_cents is not null then
    v_cents := r.pay_min_cents;
  else
    v_rate := d #>> array['va', 'by_function', p_path, 'rate'];
    v_cents := case when v_rate ~ '^\d+(\.\d{1,2})?$' then round(v_rate::numeric * 100) end;
  end if;
  return jsonb_build_object('basis', 'monthly', 'cents', coalesce(v_cents, 0), 'currency', coalesce(case when app.hire_default_path(r) = p_path then r.pay_currency end, d #>> '{va,currency}', 'USD'),
    'text', format('%s %s a month', coalesce(case when app.hire_default_path(r) = p_path then r.pay_currency end, d #>> '{va,currency}', 'USD'), to_char(coalesce(v_cents, 0) / 100.0, 'FM999990.00')));
end $$;
revoke all on function app.pct_text(numeric) from public, anon, authenticated;
grant execute on function app.pct_text(numeric) to service_role;

-- 5. a Drive import had a cap of 600 photos (0760): the rest of a big folder was skipped. Raised so a whole fleet folder goes in one run.
create or replace function app.drive_import_limits() returns jsonb language sql immutable as $$
  select jsonb_build_object('max_files', 5000, 'max_folders', 2000, 'max_depth', 4, 'max_total_bytes', 42949672960, 'max_file_bytes', 15728640, 'pause_ms', 400, 'tries', 3)
$$;
