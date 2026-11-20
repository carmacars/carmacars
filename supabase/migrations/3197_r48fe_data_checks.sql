-- 3197 (release 48, part FE; docs/changes/2026-11-20-r48-fees-evidence-hiring.md): data checks on a person's own record.
--
-- The owner (Nov 20): "make it smarter and more general than the agreement fix". On sign-in and on every portal page the
-- site checks the person's own record and shows a pop-up naming exactly what looks wrong, with the input to fix it.
-- A registry (data_checks): one row and one function per check (app.dc_<key>(user) returns null, or {message, fix,
-- fingerprint}); a new check is one function and one row. Severity:
--   blocking  the pop-up cannot be closed (the agreement needs it, an expired licence of a driver at work)
--   warning   "Remind me later" closes it for 24 hours; a check that allows it also takes "It's correct" with the reason,
--             kept until the value changes (its fingerprint)
-- The checks: staff agreement needs (licence number, home address: blocking), a home address outside Ontario or Canada for
-- in-person staff (Jamal: Pawtucket, RI), the staff licence number and expiry (expired: blocking; within 30 days: warning),
-- pay details missing for a paid role, a phone number that is not valid (staff, owners, renters), the WhatsApp member tag
-- not confirmed, a renter's licence expired or expiring within 30 days, a renter's licence name that differs from the
-- profile. (Staff licences carry no name on record, so the name check is the renters'.)
-- Admin: every open issue per person (app.data_issues: staff, owners, renters with a booking in the last 90 days) on
-- Settings > Staff, Owners and Renters, with Send reminder (app.data_check_remind: a staff alert to a staff member; for an
-- owner or renter the pop-up comes back at once, even a dismissed warning).
set local check_function_bodies = off;

alter table staff_profiles add column if not exists licence_expiry date;
comment on column staff_profiles.licence_expiry is 'Expiry date of the staff member''s driver''s licence (3197), entered with the number; checked 30 days ahead.';

create table if not exists data_checks (
  key           text primary key check (key ~ '^[a-z][a-z0-9_]{2,40}$'),
  audience      text not null check (audience in ('staff', 'owner', 'renter')),
  severity      text not null check (severity in ('blocking', 'warning')),
  fn            text not null check (fn ~ '^app\.dc_[a-z0-9_]+$'),
  label         text not null,
  allow_confirm boolean not null default false,
  enabled       boolean not null default true,
  sort          integer not null default 100
);
comment on table data_checks is 'The data check registry (3197): one row per check of a person''s own record; fn returns null or {message, fix, fingerprint}. A check''s own result may raise its severity (an expired licence is blocking).';
alter table data_checks enable row level security;
revoke all on data_checks from anon, authenticated;
grant select on data_checks to authenticated;
grant all on data_checks to service_role;
create policy admin_all on data_checks for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_data_checks after insert or update or delete on data_checks for each row execute function app.audit_row();

create table if not exists data_check_answers (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references users (id) on delete cascade,
  check_key   text not null references data_checks (key) on delete cascade,
  action      text not null check (action in ('dismiss', 'confirm', 'remind')),
  fingerprint text,
  reason      text check (char_length(reason) <= 500),
  by_user     uuid references users (id) on delete set null,
  at          timestamptz not null default now()
);
create index if not exists data_check_answers_user on data_check_answers (user_id, check_key, at desc);
comment on table data_check_answers is 'What a person (or an Admin) did with a data check (3197): dismiss (a warning, 24 hours), confirm ("It''s correct", with the reason, while the value is unchanged), remind (an Admin sent a reminder: earlier dismissals no longer count).';
alter table data_check_answers enable row level security;
revoke all on data_check_answers from anon, authenticated;
grant all on data_check_answers to service_role;
create policy admin_all on data_check_answers for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_data_check_answers after insert or update or delete on data_check_answers for each row execute function app.audit_row();

-- ================================================================ the checks (one function each)
create function app.dc_phone_ok(p text) returns boolean
language sql immutable as $$
  select length(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g')) between 10 and 15 and coalesce(p, '') !~ '[A-Za-z]'
$$;

-- the agreement waits for what only the person gives
create function app.dc_staff_agreement(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.staff_agreement_needs(p_user);
begin
  if jsonb_array_length(coalesce(v -> 'mine', '[]'::jsonb)) = 0 then return null; end if;
  return jsonb_build_object('message', 'Your staff agreement needs: ' || (select string_agg(m ->> 'label', ', ') from jsonb_array_elements(v -> 'mine') m) || '. Add it here and your agreement is made and sent to sign at once.',
    'fix', jsonb_build_object('kind', 'agreement', 'fields', (select jsonb_agg(m ->> 'key') from jsonb_array_elements(v -> 'mine') m)), 'fingerprint', (v -> 'mine')::text);
end $$;

-- in person in Toronto with a home address outside Ontario (or Canada)
create function app.dc_staff_address(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare sp staff_profiles; v_where text; v_canada boolean;
begin
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null or not app.staff_in_person(p_user) or nullif(btrim(coalesce(sp.home_address, '')), '') is null
     or app.address_in_ontario(sp.home_address, sp.home_postal_code) then return null; end if;
  v_canada := upper(regexp_replace(coalesce(sp.home_postal_code, ''), '\s', '', 'g')) ~ '^[A-Z][0-9][A-Z][0-9][A-Z][0-9]$';
  v_where := btrim(regexp_replace(sp.home_address, '^[0-9][^,]*,\s*', ''));
  return jsonb_build_object('message', format('Your home address is in %s%s. You work in person in Toronto: is this right?', coalesce(nullif(v_where, ''), sp.home_address),
                                             case when v_canada then '' else ', outside Canada' end),
    'fix', jsonb_build_object('kind', 'address', 'address', sp.home_address, 'postal', sp.home_postal_code), 'fingerprint', sp.home_address || '|' || coalesce(sp.home_postal_code, ''));
end $$;

-- the driver's licence of staff who drive (the in-person agreement): number and expiry
create function app.dc_staff_licence(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare sp staff_profiles;
begin
  select * into sp from staff_profiles where user_id = p_user;
  if sp.user_id is null or app.staff_agreement_kind(sp) <> 'in_person' then return null; end if;
  if sp.licence_number is null and not app.staff_agreement_signed(p_user) then return null; end if; -- the agreement check asks for it
  if sp.licence_number is null or sp.licence_expiry is null then
    return jsonb_build_object('message', 'Add your driver''s licence ' || case when sp.licence_number is null then 'number and expiry date' else 'expiry date' end || ': you drive our cars.',
      'fix', jsonb_build_object('kind', 'licence'), 'fingerprint', 'missing');
  end if;
  if sp.licence_expiry < app.today() then
    return jsonb_build_object('severity', 'blocking', 'message', format('Your driver''s licence expired on %s. You cannot drive for us until you add the renewed licence.', to_char(sp.licence_expiry, 'FMMonth FMDD, YYYY')),
      'fix', jsonb_build_object('kind', 'licence'), 'fingerprint', sp.licence_expiry::text);
  end if;
  if sp.licence_expiry < app.today() + 30 then
    return jsonb_build_object('message', format('Your driver''s licence expires on %s: renew it and add the new expiry date.', to_char(sp.licence_expiry, 'FMMonth FMDD, YYYY')),
      'fix', jsonb_build_object('kind', 'licence'), 'fingerprint', sp.licence_expiry::text);
  end if;
  return null;
end $$;

-- a paid role (an hourly rate, a salary, field work) with no pay details
create function app.dc_staff_pay(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('message', 'Add your pay details (bank account, GCash, PayPal, Wise, e-Transfer or OnlineJobs.ph) so we can pay you.',
           'fix', jsonb_build_object('kind', 'link', 'href', '/staff/profile#pay', 'label', 'Add my pay details'), 'fingerprint', 'missing')
    from staff_profiles sp where sp.user_id = p_user
     and (coalesce(sp.hourly_rate_cents, 0) > 0 or coalesce(sp.monthly_salary_cents, 0) > 0 or 'field' = any (sp.functions))
     and not exists (select 1 from staff_payout_accounts a where a.user_id = p_user and a.is_current)
$$;

create function app.dc_staff_phone(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('message', case when nullif(btrim(coalesce(u.phone, '')), '') is null then 'Add your mobile number: the team calls and texts you on it.'
                                            else format('Your phone number %s does not look right: write it with the area code (10 digits) or the country code.', u.phone) end,
           'fix', jsonb_build_object('kind', 'phone', 'value', u.phone), 'fingerprint', coalesce(u.phone, ''))
    from users u where u.id = p_user and not app.dc_phone_ok(u.phone)
$$;

create function app.dc_staff_whatsapp_tag(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('message', format('Set your member tag "%s" in each WhatsApp group you are in, then confirm it here.', app.staff_member_tag(p_user)),
           'fix', jsonb_build_object('kind', 'whatsapp_tag', 'tag', app.staff_member_tag(p_user)), 'fingerprint', 'unset')
    from staff_profiles sp where sp.user_id = p_user and cardinality(sp.whatsapp_joined) > 0 and sp.whatsapp_tag_set_at is null
$$;

create function app.dc_owner_phone(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('message', case when nullif(btrim(coalesce(o.phone, '')), '') is null then 'Add your phone number: we call you about your cars on it.'
                                            else format('Your phone number %s does not look right: write it with the area code (10 digits).', o.phone) end,
           'fix', jsonb_build_object('kind', 'phone', 'value', o.phone), 'fingerprint', coalesce(o.phone, ''))
    from owners o where o.user_id = p_user and not app.dc_phone_ok(o.phone) order by o.created_at limit 1
$$;

create function app.dc_renter_phone(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('message', case when nullif(btrim(coalesce(r.mobile, '')), '') is null then 'Add your mobile number: we text you about your trips on it.'
                                            else format('Your mobile number %s does not look right: write it with the area code (10 digits).', r.mobile) end,
           'fix', jsonb_build_object('kind', 'phone', 'value', r.mobile), 'fingerprint', coalesce(r.mobile, ''))
    from renters r where r.user_id = p_user and not coalesce(r.is_owner_account, false) and not app.dc_phone_ok(r.mobile) order by r.created_at limit 1
$$;

create function app.dc_renter_licence(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('message', case when d.licence_expiry < app.today() then format('Your driver''s licence expired on %s: add your renewed licence before your next trip.', to_char(d.licence_expiry, 'FMMonth FMDD, YYYY'))
                                            else format('Your driver''s licence expires on %s: add the renewed one before it does.', to_char(d.licence_expiry, 'FMMonth FMDD, YYYY')) end,
           'fix', jsonb_build_object('kind', 'link', 'href', '/account/profile#licence', 'label', 'Add my renewed licence'), 'fingerprint', d.licence_expiry::text)
    from renters r join drivers d on d.renter_id = r.id and d.is_account_holder
   where r.user_id = p_user and d.licence_expiry is not null and d.licence_expiry < app.today() + 30
   order by d.licence_expiry limit 1
$$;

create function app.dc_name_key(p text) returns text
language sql immutable as $$ select array_to_string(array(select x from unnest(regexp_split_to_array(lower(regexp_replace(coalesce(p, ''), '[^A-Za-z ]', '', 'g')), '\s+')) x where x <> '' order by x), ' ') $$;

create function app.dc_renter_name(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('message', format('The name on your licence (%s) is not the name on your profile (%s). They must match on the rental agreement: fix the one that is wrong.', d.full_name, r.legal_name),
           'fix', jsonb_build_object('kind', 'link', 'href', '/account/profile', 'label', 'Open my profile'), 'fingerprint', d.full_name || '|' || r.legal_name)
    from renters r join drivers d on d.renter_id = r.id and d.is_account_holder
   where r.user_id = p_user and not coalesce(r.is_owner_account, false) and nullif(btrim(d.full_name), '') is not null and nullif(btrim(r.legal_name), '') is not null
     and app.dc_name_key(d.full_name) <> app.dc_name_key(r.legal_name)
     -- a middle name on one side only is the same person
     and not (string_to_array(app.dc_name_key(d.full_name), ' ') @> string_to_array(app.dc_name_key(r.legal_name), ' ')
              or string_to_array(app.dc_name_key(r.legal_name), ' ') @> string_to_array(app.dc_name_key(d.full_name), ' '))
   limit 1
$$;

insert into data_checks (key, audience, severity, fn, label, allow_confirm, sort) values
  ('staff_agreement', 'staff', 'blocking', 'app.dc_staff_agreement', 'The staff agreement needs something only you give', false, 10),
  ('staff_licence', 'staff', 'warning', 'app.dc_staff_licence', 'Driver''s licence number and expiry', false, 20),
  ('staff_address', 'staff', 'warning', 'app.dc_staff_address', 'Home address outside Ontario for in-person work', true, 30),
  ('staff_pay', 'staff', 'warning', 'app.dc_staff_pay', 'Pay details for a paid role', false, 40),
  ('staff_phone', 'staff', 'warning', 'app.dc_staff_phone', 'A valid mobile number', false, 50),
  ('staff_whatsapp_tag', 'staff', 'warning', 'app.dc_staff_whatsapp_tag', 'WhatsApp member tag confirmed', false, 60),
  ('owner_phone', 'owner', 'warning', 'app.dc_owner_phone', 'A valid phone number', false, 10),
  ('renter_licence', 'renter', 'warning', 'app.dc_renter_licence', 'Licence not expired or expiring within 30 days', false, 10),
  ('renter_name', 'renter', 'warning', 'app.dc_renter_name', 'Licence name matches the profile', true, 20),
  ('renter_phone', 'renter', 'warning', 'app.dc_renter_phone', 'A valid mobile number', false, 30)
on conflict (key) do update set audience = excluded.audience, severity = excluded.severity, fn = excluded.fn, label = excluded.label, allow_confirm = excluded.allow_confirm, sort = excluded.sort;

-- ================================================================ the engine
create function app.data_audiences(p_user uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select array_remove(array[
    case when app.staff_is_member(p_user) then 'staff' end,
    case when exists (select 1 from owners o where o.user_id = p_user) then 'owner' end,
    case when exists (select 1 from renters r where r.user_id = p_user and not coalesce(r.is_owner_account, false)) then 'renter' end], null)
$$;

-- the open issues of a person: [{key, severity, label, message, fix, allow_confirm}]
create function app.data_checks_for(p_user uuid, p_audience text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  c data_checks;
  v jsonb;
  v_out jsonb := '[]'::jsonb;
  v_aud text[] := app.data_audiences(p_user);
  v_fp text;
  v_sev text;
  v_remind timestamptz;
begin
  if p_user is null then return v_out; end if;
  for c in select * from data_checks where enabled and audience = any (v_aud) and (p_audience is null or audience = p_audience) order by audience, sort loop
    begin
      execute format('select %s($1)', c.fn) into v using p_user;
    exception when others then
      v := null;
    end;
    if v is null then continue; end if;
    v_fp := md5(coalesce(v ->> 'fingerprint', v ->> 'message'));
    v_sev := coalesce(v ->> 'severity', c.severity);
    select max(a.at) into v_remind from data_check_answers a where a.user_id = p_user and a.check_key = c.key and a.action = 'remind';
    if c.allow_confirm and exists (select 1 from data_check_answers a where a.user_id = p_user and a.check_key = c.key and a.action = 'confirm' and a.fingerprint = v_fp
                                     and (v_remind is null or a.at > v_remind)) then continue; end if;
    if v_sev = 'warning' and exists (select 1 from data_check_answers a where a.user_id = p_user and a.check_key = c.key and a.action = 'dismiss'
                                       and a.at > now() - interval '24 hours' and (v_remind is null or a.at > v_remind)) then continue; end if;
    v_out := v_out || jsonb_build_object('key', c.key, 'audience', c.audience, 'severity', v_sev, 'label', c.label, 'message', v ->> 'message',
                                         'fix', coalesce(v -> 'fix', '{}'::jsonb), 'allow_confirm', c.allow_confirm);
  end loop;
  return v_out;
end $$;

-- p: {key, action: dismiss | confirm, reason}
create function app.data_check_answer(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  c data_checks;
  v jsonb;
  v_action text := coalesce(p ->> 'action', '');
  v_reason text := nullif(btrim(coalesce(p ->> 'reason', '')), '');
begin
  select * into c from data_checks where key = p ->> 'key';
  if c.key is null then raise exception 'Unknown check' using errcode = '22023'; end if;
  execute format('select %s($1)', c.fn) into v using p_user;
  if v is null then return jsonb_build_object('ok', true, 'open', app.data_checks_for(p_user)); end if;
  if v_action = 'dismiss' then
    if coalesce(v ->> 'severity', c.severity) = 'blocking' then raise exception 'This one must be fixed first' using errcode = '23514'; end if;
  elsif v_action = 'confirm' then
    if not c.allow_confirm then raise exception 'Fix it instead' using errcode = '22023'; end if;
    if v_reason is null or char_length(v_reason) < 5 then raise exception 'Say why it is correct' using errcode = '22023'; end if;
    if c.key = 'staff_address' then update staff_profiles set home_address_outside_ok_at = now() where user_id = p_user; end if;
  else
    raise exception 'dismiss or confirm' using errcode = '22023';
  end if;
  insert into data_check_answers (user_id, check_key, action, fingerprint, reason, by_user)
  values (p_user, c.key, v_action, md5(coalesce(v ->> 'fingerprint', v ->> 'message')), v_reason, p_user);
  return jsonb_build_object('ok', true, 'open', app.data_checks_for(p_user));
end $$;

-- the fixes the pop-up saves that no other screen has: the phone, the staff licence, the WhatsApp tag
create function app.data_fix_save(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := p ->> 'kind';
  v_phone text := btrim(coalesce(p ->> 'phone', ''));
  v_exp date := nullif(p ->> 'licence_expiry', '')::date;
begin
  if v_kind = 'phone' then
    if not app.dc_phone_ok(v_phone) then raise exception 'Write the number with the area code, 10 digits (or the country code and the number)' using errcode = '22023'; end if;
    case coalesce(p ->> 'audience', 'staff')
      when 'owner' then update owners set phone = v_phone where user_id = p_user;
      when 'renter' then update renters set mobile = v_phone where user_id = p_user and not coalesce(is_owner_account, false);
      else update users set phone = v_phone, phone_verified_at = case when phone is distinct from v_phone then null else phone_verified_at end where id = p_user;
    end case;
  elsif v_kind = 'licence' then
    if nullif(btrim(coalesce(p ->> 'licence_number', '')), '') is not null then perform app.staff_licence_number_save(p_user, p); end if;
    if v_exp is null then raise exception 'Add the expiry date on your licence' using errcode = '22023'; end if;
    if v_exp < app.today() then raise exception 'That date has passed: add the renewed licence''s expiry date' using errcode = '22023'; end if;
    update staff_profiles set licence_expiry = v_exp where user_id = p_user;
  elsif v_kind in ('agreement', 'address') then
    -- the agreement's own inputs (3196): the licence number, the home address (outside Ontario confirmed for in-person staff)
    if nullif(btrim(coalesce(p ->> 'licence_number', '')), '') is not null then perform app.staff_licence_number_save(p_user, p); end if;
    if nullif(btrim(coalesce(p ->> 'home_address', '')), '') is not null then perform app.staff_home_address_save(p_user, p); end if;
    if (p ->> 'licence_expiry') is not null and v_exp >= app.today() then update staff_profiles set licence_expiry = v_exp where user_id = p_user; end if;
  elsif v_kind = 'whatsapp_tag' then
    if not coalesce((p ->> 'tag_set')::boolean, false) then raise exception 'Tick that you set your member tag' using errcode = '22023'; end if;
    update staff_profiles set whatsapp_tag_set_at = coalesce(whatsapp_tag_set_at, now()) where user_id = p_user;
  else
    raise exception 'Unknown fix' using errcode = '22023';
  end if;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after) values (p_user, 'data_fix_save', 'users', p_user::text, jsonb_build_object('kind', v_kind));
  return jsonb_build_object('ok', true, 'open', app.data_checks_for(p_user));
end $$;

-- Admin: every open issue per person of an audience
create function app.data_issues(p_by uuid, p_audience text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(x order by x ->> 'name') from (
    select jsonb_build_object('user_id', u.id, 'name', coalesce(nullif(btrim(u.full_name), ''), u.email), 'email', u.email,
             'issues', app.data_checks_for(u.id, p_audience),
             'reminded_at', (select max(a.at) from data_check_answers a where a.user_id = u.id and a.action = 'remind')) x
      from users u
     where u.id = any (case p_audience
         when 'staff' then (select array_agg(sp.user_id) from staff_profiles sp where sp.is_active)
         when 'owner' then (select array_agg(o.user_id) from owners o where o.user_id is not null and o.status = 'active')
         else (select array_agg(distinct r.user_id) from renters r join bookings b on b.renter_id = r.id
                where r.user_id is not null and b.booking_type::text <> 'owner' and b.created_at > now() - interval '90 days') end)) y
   where jsonb_array_length(x -> 'issues') > 0), '[]'::jsonb);
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort)
values ('data_check_reminder', 'Your record: something to fix', 'Team', '{assigned}', 'normal', 'alerts', true, true, false,
        'An Admin pressed Send reminder on a data issue (3197): to the person.', 119)
on conflict (rule) do nothing;

-- p: {user}
create function app.data_check_remind(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user', '')::uuid;
  v jsonb;
begin
  perform app.assert_admin(p_by);
  -- every check of the person: a warning they dismissed comes back too
  insert into data_check_answers (user_id, check_key, action, by_user)
  select v_user, c.key, 'remind', p_by from data_checks c where c.enabled and c.audience = any (app.data_audiences(v_user));
  v := app.data_checks_for(v_user);
  if jsonb_array_length(v) = 0 then raise exception 'Nothing to fix on this record' using errcode = '23514'; end if;
  if app.staff_is_member(v_user) then
    perform app.staff_alert('data_check_reminder', 'user', v_user, to_char(now(), 'YYYYMMDDHH24MI'), 'Please fix your record',
      left((select string_agg(x ->> 'message', ' ') from jsonb_array_elements(v) x), 230), jsonb_build_object('assigned_to', v_user, 'path_staff', '/staff'));
  end if;
  return jsonb_build_object('ok', true, 'issues', jsonb_array_length(v));
end $$;

create function public.server_data_checks(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$ select app.data_checks_for(p_user) $$;
create function public.server_data_check_answer(p_user uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.data_check_answer(p_user, p) $$;
create function public.server_data_fix_save(p_user uuid, p jsonb) returns jsonb
language sql security definer set search_path = public, app as $$ select app.data_fix_save(p_user, p) $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3197;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'data_issues' then
    perform app.door_begin(p_user, p_aal);
    return app.data_issues(p_user, coalesce(p ->> 'audience', 'staff'));
  end if;
  if p_call = 'admin_do' and p_name = 'data_check_remind' then
    perform app.door_begin(p_user, p_aal);
    return app.data_check_remind(p_user, p);
  end if;
  return app.door_pre3197(p_user, p_aal, p_call, p_name, p);
end $$;
do $$ declare g text; begin
  execute 'revoke all on function app.door(uuid, text, text, text, jsonb) from public, anon, authenticated';
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, 'app.door_pre3197(uuid, text, text, text, jsonb)'::regprocedure, 'execute') then execute format('grant execute on function app.door(uuid, text, text, text, jsonb) to %I', g); end if;
  end loop;
end $$;

revoke all on function app.dc_phone_ok(text), app.dc_staff_agreement(uuid), app.dc_staff_address(uuid), app.dc_staff_licence(uuid), app.dc_staff_pay(uuid), app.dc_staff_phone(uuid),
  app.dc_staff_whatsapp_tag(uuid), app.dc_owner_phone(uuid), app.dc_renter_phone(uuid), app.dc_renter_licence(uuid), app.dc_name_key(text), app.dc_renter_name(uuid),
  app.data_audiences(uuid), app.data_checks_for(uuid, text), app.data_check_answer(uuid, jsonb), app.data_fix_save(uuid, jsonb), app.data_issues(uuid, text), app.data_check_remind(uuid, jsonb),
  public.server_data_checks(uuid), public.server_data_check_answer(uuid, jsonb), public.server_data_fix_save(uuid, jsonb), app.door_pre3197(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.dc_phone_ok(text), app.dc_staff_agreement(uuid), app.dc_staff_address(uuid), app.dc_staff_licence(uuid), app.dc_staff_pay(uuid), app.dc_staff_phone(uuid),
  app.dc_staff_whatsapp_tag(uuid), app.dc_owner_phone(uuid), app.dc_renter_phone(uuid), app.dc_renter_licence(uuid), app.dc_name_key(text), app.dc_renter_name(uuid),
  app.data_audiences(uuid), app.data_checks_for(uuid, text), app.data_check_answer(uuid, jsonb), app.data_fix_save(uuid, jsonb), app.data_issues(uuid, text), app.data_check_remind(uuid, jsonb),
  public.server_data_checks(uuid), public.server_data_check_answer(uuid, jsonb), public.server_data_fix_save(uuid, jsonb), app.door_pre3197(uuid, text, text, text, jsonb) to service_role;
