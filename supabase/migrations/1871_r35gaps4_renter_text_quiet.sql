-- 1871_r35gaps4_renter_text_quiet.sql
-- The owner, November 9, 2026 (message 3804): hold the texts to renters from 1 am to 5 am Toronto time and send them after 5 am.
-- The window is the Program setting of the text alerts (sms_quiet_from_hour, sms_quiet_until_hour), now 1 and 5 by default (it was 21 and 8);
-- it replaces the 23-7 site-check quiet hours of 0085 (phone_sms_quiet_hours, which the booking text no longer reads) for renter texts.
-- Urgent texts are exempt: a pickup or a return today, an overdue return, and sign-in or signing codes (app.sms_renter_urgent).
-- Staff keep their own quiet hours (staff_alert_prefs; with no row, 21:00 to 8:00 as 0466 promised), so app.alert_quiet_end no longer
-- borrows the renter window for them.

alter table program_settings alter column sms_quiet_from_hour set default 1;
alter table program_settings alter column sms_quiet_until_hour set default 5;
update program_settings set sms_quiet_hours = true, sms_quiet_from_hour = 1, sms_quiet_until_hour = 5;
comment on column program_settings.sms_quiet_hours is 'Text alerts: hold texts to renters, owners and investors that are not urgent during the quiet hours below and send them when they end. Urgent: a pickup or return today, an overdue return, sign-in and signing codes, and the templates marked urgent.';
comment on column program_settings.sms_quiet_from_hour is 'Text alerts: quiet hours start (Toronto hour, 1 is 1 am).';
comment on column program_settings.sms_quiet_until_hour is 'Text alerts: quiet hours end (Toronto hour, 5 is 5 am).';
comment on column program_settings.phone_sms_quiet_hours is 'Superseded (1871): booking texts follow the text alerts quiet hours (sms_quiet_hours, sms_quiet_from_hour, sms_quiet_until_hour, 1 am to 5 am), not the site check''s.';

-- The staff default when a person has no preferences row: 21:00 to 8:00 (it used to come from the text quiet hours).
create or replace function app.alert_quiet_end(p_user uuid, p_at timestamptz) returns timestamptz
language plpgsql stable security definer set search_path = public, app as $$
declare
  pr staff_alert_prefs;
  v_local timestamp := p_at at time zone 'America/Toronto';
  v_min integer := extract(hour from v_local)::integer * 60 + extract(minute from v_local)::integer;
  v_inside boolean;
begin
  select * into pr from staff_alert_prefs where user_id = p_user;
  if pr.user_id is null then pr.quiet_on := true; pr.quiet_from := 1260; pr.quiet_until := 480; end if;
  if not pr.quiet_on or pr.quiet_from = pr.quiet_until then return p_at; end if;
  v_inside := case when pr.quiet_from < pr.quiet_until then v_min >= pr.quiet_from and v_min < pr.quiet_until
                   else v_min >= pr.quiet_from or v_min < pr.quiet_until end;
  if not v_inside then return p_at; end if;
  return ((date_trunc('day', v_local) + case when v_min >= pr.quiet_until then interval '1 day' else interval '0' end)
          + make_interval(mins => pr.quiet_until)) at time zone 'America/Toronto';
end $$;

-- Does a text to a renter go through the quiet hours? p_template_urgent is the template's own flag.
create or replace function app.sms_renter_urgent(p_code text, p_booking uuid, p_template_urgent boolean default false, p_now timestamptz default now())
returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  b bookings;
begin
  if coalesce(p_template_urgent, false) then return true; end if;
  if p_code in ('renter_signing_code', 'document_signing_code', 'account_sign_in_link') or p_code like '%sign_in%' or p_code like '%signing_code%' or p_code like '%login_code%' then
    return true;
  end if;
  if p_booking is null then return false; end if;
  select * into b from bookings where id = p_booking;
  if b.id is null or b.status in ('cancelled', 'declined', 'expired', 'closed') then return false; end if;
  return app.local_date(b.pickup_at) = app.local_date(p_now)
      or app.local_date(b.return_at) = app.local_date(p_now)
      or (b.status = 'on_rent' and b.return_at < p_now);
end $$;
revoke all on function app.sms_renter_urgent(text, uuid, boolean, timestamptz) from public, anon, authenticated;
grant execute on function app.sms_renter_urgent(text, uuid, boolean, timestamptz) to service_role;
