-- 0440: test accounts are fenced off from real work at the source (docs/changes/2026-11-07-data-health.md).
--
-- The owner, November 2026: "make sure there isnt more shit like that. i shouldnt be spotting this myself, u should be
-- telling me this and fixing it urself". Two real website owner leads were credited to the deploy verification's test
-- accounts ("Verify Invitation", "Verify Sales") and nobody contacted them; staff lists and task assignees showed
-- "Verify ..." accounts. The live verification (web/scripts/verify-live.mjs) signs in as verify-<name>@carmacars.ca
-- accounts and invites a throwaway delivered+verify-invite-<n>@resend.dev staff member; those accounts stay usable by
-- the checks, but nothing real may ever be routed to them.
--
-- 1. users.is_test (generated from the address): verify-<name>@carmacars.ca or any @resend.dev address (Resend's test
--    inboxes). app.is_test_email, app.is_test_user; app.staff_is_test (0078) now means the same, so the queues' "is the
--    function staffed" (va_function_staffed) and the assistants' lists also ignore the invitation's leftover account.
-- 2. owners.is_test is set for a test account's owner record (the existing exclusions then apply: statements, debits,
--    To do, referral codes).
-- 3. A record is a test record when its subject is: the booking's renter, the owner, the renter, the lead's or chat's
--    address, or the vehicle's owner is a test account (app.subject_is_test). A record with no subject is a test
--    record only when a test account made it.
-- 4. The fences: a trigger on every column that routes real work or credit to a person. A test account written there on
--    a real record is taken off (the record goes back to its queue) or, where the row is the credit itself, the row is not
--    written: tasks, leads, field jobs, live chats, live-map visitors (assigned_to); bookings (sales credit, referrer,
--    sales claim); owner applications (sourced by); interview scores (interviewer); request claims, staff commissions,
--    referral kickbacks and sales touches (not written); in-app notices, notification emails and texts, phone texts
--    and push alerts to a test account other than the verification Admin about a real record (not written; the
--    verification Admin's are suppressed already, 0036).
-- 5. The choosers skip test accounts: a new buyer, finance, detailing or body shop lead's least busy sales assistant
--    (submit_lead), the field job's least busy driver (field_auto_assignee), the phone's on-duty assistant
--    (phone_on_duty, phone_fn_held), the staff picker (staff_directory), the sales credit picker (sales_staff_options),
--    the sales team report (team_sales) and Settings > Sales (sales_modes_admin). Admin > Portals keeps them (the
--    verification opens each portal as them) and labels them "Test account".
-- 6. Live map and visitor history: a test account's visit is excluded (exclude_reason 'test'). A lead from a test
--    address is closed at once ("Test account") so it never reaches a queue or a follow-up.
-- No applied migration is edited.
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

-- ================================================================ 1. what a test account is
alter table users add column if not exists is_test boolean generated always as (
  coalesce(lower(btrim(email)) ~ '^verify-[a-z0-9-]+@carmacars\.ca$' or lower(btrim(email)) ~ '@resend\.dev$', false)) stored;
comment on column users.is_test is
  'A test account (0440): the live verification''s verify-<name>@carmacars.ca accounts and any @resend.dev address (Resend''s test inboxes). It signs in as usual, but no real record is ever routed or credited to it.';
create index if not exists users_is_test_idx on users (id) where is_test;

create or replace function app.is_test_email(p text) returns boolean
language sql immutable as $$
  select coalesce(lower(btrim(p)) ~ '^verify-[a-z0-9-]+@carmacars\.ca$' or lower(btrim(p)) ~ '@resend\.dev$', false)
$$;

create or replace function app.is_test_user(p uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p is not null and coalesce((select u.is_test from users u where u.id = p), false)
$$;

-- 0078's test: the verification's addresses only; now every test account (the invitation's leftover too). 0343 (Release 26,
-- live) widened it to the addresses of site_settings.admin_test_emails and the invitation's "+verify-" form: kept here.
create or replace function app.staff_is_test(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_test_user(p_user) or coalesce((select app.email_is_test(u.email) from users u where u.id = p_user), false)
$$;

-- ================================================================ 2. a test account's owner record
create or replace function app.owners_test_flag() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if not coalesce(new.is_test, false) and (app.is_test_email(new.email) or app.is_test_user(new.user_id)) then new.is_test := true; end if;
  return new;
end $$;
drop trigger if exists owners_test_flag on owners;
create trigger owners_test_flag before insert or update of email, user_id, is_test on owners for each row execute function app.owners_test_flag();
update owners set is_test = true where not coalesce(is_test, false) and (app.is_test_email(email) or app.is_test_user(user_id));

-- ================================================================ 3. test records
create or replace function app.renter_is_test(p_renter uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_renter is not null and exists (select 1 from renters r left join users u on u.id = r.user_id
                                           where r.id = p_renter and (app.is_test_email(r.email) or coalesce(u.is_test, false)))
$$;

create or replace function app.booking_is_test(p_booking uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_booking is not null and exists (
    select 1 from bookings b left join owners o on o.id = b.owner_id
     where b.id = p_booking and (app.renter_is_test(b.renter_id) or (b.renter_id is null and coalesce(o.is_test, false))))
$$;

create or replace function app.subject_is_test(p_booking uuid default null, p_owner uuid default null, p_renter uuid default null,
                                               p_email text default null, p_user uuid default null, p_vehicle uuid default null) returns boolean
language sql stable security definer set search_path = public, app as $$
  select app.is_test_email(p_email) or app.is_test_user(p_user) or app.renter_is_test(p_renter) or app.booking_is_test(p_booking)
      or (p_owner is not null and exists (select 1 from owners o where o.id = p_owner and coalesce(o.is_test, false)))
      or (p_vehicle is not null and exists (select 1 from vehicles v join owners o on o.id = v.owner_id where v.id = p_vehicle and coalesce(o.is_test, false)))
$$;

-- Is this row (as jsonb) a test record? Its subject columns, by table.
create or replace function app.row_is_test(p_table text, j jsonb) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_b uuid := nullif(j ->> 'booking_id', '')::uuid;
  v_o uuid := nullif(j ->> 'owner_id', '')::uuid;
  v_r uuid := nullif(j ->> 'renter_id', '')::uuid;
  v_v uuid := nullif(j ->> 'vehicle_id', '')::uuid;
  v_rel uuid := nullif(j ->> 'related_id', '')::uuid;
  v_by uuid := nullif(j ->> 'created_by', '')::uuid;
begin
  case p_table
  when 'bookings' then return app.booking_is_test(nullif(j ->> 'id', '')::uuid);
  when 'leads' then return app.subject_is_test(p_owner => v_o, p_email => j ->> 'email');
  when 'chat_conversations' then return app.subject_is_test(p_booking => v_b, p_renter => v_r, p_email => j ->> 'email', p_user => nullif(j ->> 'user_id', '')::uuid);
  when 'visitor_sessions' then return app.subject_is_test(p_renter => v_r, p_email => j ->> 'known_email', p_user => nullif(j ->> 'user_id', '')::uuid);
  when 'interview_scores' then
    return exists (select 1 from job_applications a where a.id = nullif(j ->> 'application_id', '')::uuid and app.is_test_email(a.email));
  when 'notifications' then
    return (j ->> 'entity') in ('booking', 'bookings') and app.booking_is_test(nullif(j ->> 'entity_id', '')::uuid);
  when 'push_outbox', 'phone_outbox' then
    return app.subject_is_test(p_booking => v_b, p_renter => v_r)
        or exists (select 1 from notifications n where n.id = nullif(j ->> 'notification_id', '')::uuid
                    and n.entity in ('booking', 'bookings') and app.booking_is_test(n.entity_id));
  else
    if app.subject_is_test(p_booking => v_b, p_owner => v_o, p_renter => v_r, p_vehicle => v_v) then return true; end if;
    if j ->> 'related_table' = 'leads' and exists (select 1 from leads l where l.id = v_rel and app.subject_is_test(p_owner => l.owner_id, p_email => l.email)) then return true; end if;
    if j ->> 'related_table' = 'bookings' and app.booking_is_test(v_rel) then return true; end if;
    -- no subject at all: a test record only when a test account made it
    return v_b is null and v_o is null and v_r is null and v_v is null and v_rel is null and app.is_test_user(v_by);
  end case;
end $$;

-- ================================================================ 4. the fences
-- tg_argv: the mode ('clear': the column is emptied, the record goes back to its queue; 'skip': the row is not written,
-- an update keeps the row as it was), then the columns. Only a value that changes to a test account is looked at, so
-- existing rows never block an unrelated update. The verification Admin is fenced only from credit, never from notices.
create or replace function app.fence_test_accounts() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_mode text := tg_argv[0];
  j jsonb := to_jsonb(new);
  o jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else '{}'::jsonb end;
  v_col text;
  v_who uuid;
  v_clear jsonb := '{}'::jsonb;
  i integer;
  v_test boolean;
begin
  for i in 1 .. tg_nargs - 1 loop
    v_col := tg_argv[i];
    v_who := nullif(j ->> v_col, '')::uuid;
    if v_who is null or (o ->> v_col) is not distinct from (j ->> v_col) or not app.is_test_user(v_who) then continue; end if;
    -- notices to the verification Admin are allowed (its email is suppressed, 0036)
    if v_mode = 'notice' and app.user_is_admin(v_who) then continue; end if;
    v_test := coalesce(v_test, app.row_is_test(tg_table_name, j));
    if v_test then return new; end if;
    if v_mode in ('skip', 'notice') then
      if tg_op = 'INSERT' then return null; end if;
      return old;
    end if;
    v_clear := v_clear || jsonb_build_object(v_col, null);
    -- the columns that go with a cleared person
    if tg_table_name = 'tasks' and v_col = 'assigned_to' and j ->> 'status' = 'in_progress' then v_clear := v_clear || '{"status": "open"}'; end if;
    if tg_table_name = 'visitor_sessions' then v_clear := v_clear || '{"assigned_at": null}'; end if;
    if tg_table_name = 'bookings' and v_col = 'sales_staff_id' then v_clear := v_clear || '{"sales_sourced": false}'; end if;
    if tg_table_name = 'bookings' and v_col = 'referrer_staff_id' then v_clear := v_clear || '{"referrer_type": null}'; end if;
    if tg_table_name = 'bookings' and v_col = 'sales_claim_by' then v_clear := v_clear || '{"sales_claim_at": null}'; end if;
  end loop;
  if v_clear = '{}'::jsonb then return new; end if;
  return jsonb_populate_record(new, v_clear);
end $$;

do $$
declare
  f record;
begin
  for f in select * from (values
      ('tasks', 'clear', array['assigned_to']), ('leads', 'clear', array['assigned_to']), ('field_jobs', 'clear', array['assigned_to']),
      ('chat_conversations', 'clear', array['assigned_to']), ('visitor_sessions', 'clear', array['assigned_to']),
      ('bookings', 'clear', array['sales_staff_id', 'referrer_staff_id', 'sales_claim_by']),
      ('owner_applications', 'clear', array['sourced_by']), ('interview_scores', 'clear', array['interviewer']),
      ('request_claims', 'skip', array['claimed_by']), ('staff_commissions', 'skip', array['staff_id']),
      ('referral_kickbacks', 'skip', array['referrer_staff_id']), ('sales_touches', 'skip', array['staff_id']),
      ('notification_outbox', 'notice', array['recipient_user_id']), ('notifications', 'notice', array['user_id']),
      ('push_outbox', 'notice', array['user_id']), ('phone_outbox', 'notice', array['user_id'])) x(tbl, mode, cols) loop
    execute format('drop trigger if exists a_fence_test_accounts on %I', f.tbl);
    execute format('drop trigger if exists z_fence_test_accounts on %I', f.tbl);
    -- named "a_..." so it runs before the table's other BEFORE triggers see the person; leads' is "z_...": 0343's
    -- leads_no_test_staff (Release 26, live) first gives a lead to the least busy real Sales person, then this one clears what is left
    execute format('create trigger %s before insert or update of %s on %I for each row execute function app.fence_test_accounts(%s)',
                   case when f.tbl = 'leads' then 'z_fence_test_accounts' else 'a_fence_test_accounts' end,
                   array_to_string(array(select quote_ident(c) from unnest(f.cols) c), ', '), f.tbl,
                   array_to_string(array(select quote_literal(a) from unnest(array[f.mode] || f.cols) a), ', '));
  end loop;
end $$;

-- ================================================================ 5. the choosers
-- a buyer, finance, detailing or body shop lead: the least busy real sales assistant (0097's text, the test account out)
create or replace function app.submit_lead(p jsonb, p_ip text default null) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_kind text := coalesce(p ->> 'kind', 'contact');
  v_id uuid := gen_random_uuid();
  v_email text := nullif(lower(btrim(p ->> 'email')), '');
  v_phone text := nullif(btrim(p ->> 'phone'), '');
  v_name text := nullif(btrim(p ->> 'name'), '');
  v_consent boolean := coalesce((p ->> 'consent_marketing')::boolean, false);
  v_set program_settings := app.settings();
  v_assignee uuid;
  v_task uuid;
  v_car text := nullif(btrim(p -> 'payload' ->> 'vehicle'), '');
  v_what text := nullif(btrim(p -> 'payload' ->> 'service'), '');
begin
  if v_kind not in ('buyer', 'finance', 'detailing', 'bodyshop') then return app.submit_lead_pre0097(p, p_ip); end if;
  if nullif(btrim(p_ip), '') is not null and not app.rate_limit('lead:ip:' || btrim(p_ip), v_set.lead_hourly_limit, interval '1 hour') then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  if v_email is null and v_phone is null then raise exception 'Give an email address or a phone number so we can reply' using errcode = '22023'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address, for example name@example.com' using errcode = '22023'; end if;
  if v_consent and nullif(p ->> 'consent_text', '') is null then raise exception 'Marketing consent needs the wording the person agreed to' using errcode = '22023'; end if;
  -- Sales: the least busy active sales assistant who is a real person (0440)
  select sp.user_id into v_assignee from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active' and not u.is_test
    join user_roles r on r.user_id = sp.user_id and r.role = 'va'
   where 'sales' = any (sp.functions) and sp.is_active
   order by (select count(*) from leads l where l.assigned_to = sp.user_id and l.status in ('new', 'contacted', 'qualified')), sp.created_at, sp.user_id limit 1;
  insert into leads (id, kind, name, email, phone, message, payload, source, source_url, referrer, consent_marketing, consent_text, consent_at, assigned_to)
  values (v_id, v_kind, v_name, v_email, v_phone, nullif(btrim(p ->> 'message'), ''), app.strip_transient(coalesce(p -> 'payload', '{}'::jsonb)),
          coalesce(nullif(p ->> 'source', ''), 'web'), p ->> 'source_url', p ->> 'referrer',
          v_consent, case when v_consent then p ->> 'consent_text' end, case when v_consent then now() end, v_assignee);
  v_task := app.raise_task(p_type => v_kind || '_lead',
    p_detail => case v_kind
      when 'detailing' then concat_ws(' ', coalesce(v_name, 'Someone'), 'asked for', coalesce(lower(v_what), 'detailing'), 'on', coalesce(v_car, 'a car') || '.',
                                      'Where: ' || nullif(btrim(p -> 'payload' ->> 'place'), '') || '.', 'When: ' || nullif(btrim(p -> 'payload' ->> 'timeline'), '') || '.')
      when 'bodyshop' then concat_ws(' ', coalesce(v_name, 'Someone'), 'asked for', coalesce(lower(v_what), 'body work'), 'on', coalesce(v_car, 'a car') || '.',
                                      'Where: ' || nullif(btrim(p -> 'payload' ->> 'place'), '') || '.', 'When: ' || nullif(btrim(p -> 'payload' ->> 'timeline'), '') || '.')
      else concat_ws(' ', coalesce(v_name, 'Someone'), case v_kind when 'finance' then 'asked about ' || coalesce(lower(v_what), 'financing') || ' for' else 'wants to buy' end,
                     coalesce(v_car, 'a car') || '.', 'Budget: ' || nullif(btrim(p -> 'payload' ->> 'budget'), '') || '.', 'Timeline: ' || nullif(btrim(p -> 'payload' ->> 'timeline'), '') || '.') end,
    p_related_table => 'leads', p_related_id => v_id, p_dedupe => 'lead:' || v_id);
  if v_assignee is not null then update tasks set assigned_to = v_assignee where id = v_task; end if;
  return jsonb_build_object('ok', true, 'lead_id', v_id);
end $$;

create or replace function app.field_auto_assignee(p_at timestamptz) returns uuid
language sql stable security definer set search_path = public, app as $$
  select case when (app.settings()).field_jobs_auto_assign = 'least_busy' then (
    select u.id from users u
      join staff_profiles sp on sp.user_id = u.id and 'field' = any (sp.functions) and sp.is_active and sp.field_function in ('driver', 'driver_detailer')
      join user_roles r on r.user_id = u.id and r.role = 'field'
     where u.status = 'active' and not u.is_test
     order by (select count(*) from field_jobs j where j.assigned_to = u.id and j.status <> 'cancelled' and app.local_date(j.scheduled_at) = app.local_date(p_at)),
              (select count(*) from field_jobs j where j.assigned_to = u.id and j.status <> 'cancelled' and j.scheduled_at between p_at - interval '3 days' and p_at + interval '4 days'),
              u.full_name, u.id
     limit 1) end
$$;

create or replace function app.phone_on_duty(p_fn text) returns uuid
language sql stable security definer set search_path = public, app as $$
  select p.user_id from chat_staff_prefs p
    join staff_profiles sp on sp.user_id = p.user_id and sp.staff_type = 'va' and sp.is_active
    join users u on u.id = p.user_id and u.status = 'active' and not u.is_test
   where p.last_seen_at > now() - make_interval(mins => (app.settings()).chat_shift_minutes)
     and (sp.va_function::text = p_fn or p_fn = any (array(select x::text from unnest(sp.cover_functions) x)))
   order by p.last_seen_at desc limit 1
$$;

create or replace function app.phone_fn_held(p_fn text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from staff_profiles sp join users u on u.id = sp.user_id and u.status = 'active' and not u.is_test
                   join user_roles r on r.user_id = sp.user_id and r.role = 'va'
                  where sp.staff_type = 'va' and sp.is_active
                    and (sp.va_function::text = p_fn or p_fn = any (array(select x::text from unnest(sp.cover_functions) x))))
$$;

-- the staff picker (reassigning a task): real people; a test account still sees itself and the others
create or replace view staff_directory as
  select u.id as user_id, u.full_name, sp.staff_type, sp.va_function, sp.field_function
    from users u join staff_profiles sp on sp.user_id = u.id
   where sp.is_active and u.status = 'active' and (app.is_staff() or app.is_field())
     and (not u.is_test or app.is_test_user(app.uid()));

create or replace function app.sales_staff_options(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'name', coalesce(u.full_name, u.email),
                     'function', coalesce(sp.va_function::text, case when 'field' = any (sp.functions) then 'field' end, 'admin')) order by coalesce(u.full_name, u.email))
                     from users u left join staff_profiles sp on sp.user_id = u.id
                    where app.user_is_sales_staff(u.id) and not u.is_test), '[]'::jsonb);
end $$;

-- a list of people (jsonb array) without the test accounts, by the element's id key
create or replace function app.without_test_people(p jsonb, p_key text) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce((select jsonb_agg(x order by n) from jsonb_array_elements(coalesce(p, '[]'::jsonb)) with ordinality e(x, n)
                    where not app.is_test_user(nullif(x ->> p_key, '')::uuid)), '[]'::jsonb)
$$;

alter function app.team_sales(uuid, jsonb) rename to team_sales_pre0440;
create function app.team_sales(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.team_sales_pre0440(p_by, p);
begin
  return jsonb_set(v, '{rows}', app.without_test_people(v -> 'rows', 'staff_id'));
end $$;
select pg_temp.copy_grants('app.team_sales(uuid, jsonb)'::regprocedure, 'app.team_sales_pre0440(uuid, jsonb)'::regprocedure);

alter function app.sales_modes_admin(uuid) rename to sales_modes_admin_pre0440;
create function app.sales_modes_admin(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.sales_modes_admin_pre0440(p_by);
begin
  return jsonb_set(v, '{people}', app.without_test_people(v -> 'people', 'id'));
end $$;
select pg_temp.copy_grants('app.sales_modes_admin(uuid)'::regprocedure, 'app.sales_modes_admin_pre0440(uuid)'::regprocedure);

-- Admin > Portals keeps the test accounts (the verification opens each portal as one) and says which they are
alter function app.admin_portal_people(uuid, text, integer) rename to admin_portal_people_pre0440;
create function app.admin_portal_people(p_admin uuid, p_q text default null, p_limit integer default 200) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_portal_people_pre0440(p_admin, p_q, p_limit);
begin
  return jsonb_set(v, '{people}', coalesce((select jsonb_agg(x || jsonb_build_object('test', app.is_test_user(nullif(x ->> 'id', '')::uuid)) order by n)
                                              from jsonb_array_elements(v -> 'people') with ordinality e(x, n)), '[]'::jsonb));
end $$;
select pg_temp.copy_grants('app.admin_portal_people(uuid, text, integer)'::regprocedure, 'app.admin_portal_people_pre0440(uuid, text, integer)'::regprocedure);

-- ================================================================ 6. visits and leads from test accounts
alter table visitor_sessions drop constraint if exists visitor_sessions_exclude_reason_check;
alter table visitor_sessions add constraint visitor_sessions_exclude_reason_check check (exclude_reason in ('bot', 'staff', 'test'));
create or replace function app.visitor_sessions_test() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.is_test_user(new.user_id) or app.is_test_email(new.known_email) or app.renter_is_test(new.renter_id) then new.exclude_reason := 'test'; end if;
  return new;
end $$;
drop trigger if exists z_visitor_sessions_test on visitor_sessions;
create trigger z_visitor_sessions_test before insert or update of user_id, known_email, renter_id, exclude_reason on visitor_sessions for each row execute function app.visitor_sessions_test();
update visitor_sessions set exclude_reason = 'test'
 where exclude_reason is distinct from 'test' and (app.is_test_user(user_id) or app.is_test_email(known_email) or app.renter_is_test(renter_id));

create or replace function app.leads_test_closed() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.is_test_email(new.email) and new.status not in ('closed', 'spam') then
    new.status := 'closed'; new.closed_reason := coalesce(new.closed_reason, 'Test account');
    new.followup_next_at := null;   -- the assignee stays (0343: a test lead keeps its test account, the verification's own data)
    if new.pipeline_stage is not null then new.pipeline_stage := 'lost'; end if;
    new.followup_stopped_at := coalesce(new.followup_stopped_at, now()); new.followup_stop_reason := coalesce(new.followup_stop_reason, 'Test account');
  end if;
  return new;
end $$;
drop trigger if exists leads_test_closed on leads;
create trigger leads_test_closed before insert on leads for each row execute function app.leads_test_closed();

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('is_test_email', 'is_test_user', 'owners_test_flag', 'renter_is_test', 'booking_is_test', 'subject_is_test',
              'row_is_test', 'fence_test_accounts', 'without_test_people', 'visitor_sessions_test', 'leads_test_closed',
              'team_sales_pre0440', 'sales_modes_admin_pre0440', 'admin_portal_people_pre0440') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- staff_directory reads app.is_test_user as the signed-in staff member
grant execute on function app.is_test_user(uuid) to authenticated;
