-- 0802_r34n_academy_gate.sql
-- Release 34, part N (docs/changes/2026-11-08-r34-academy-gate.md). SCHEMA_MARKER 0802. The owner, November 8: "academy should
-- be mandatory and it should be well built and updated and describes every part of the business necessary and describes all
-- workflows that they should know. they must pass the academy to continue".
--   1. The gate (0207, on since 0731) stays: a staff member (office functions and field work) who has not passed every
--      section of their paths opens only the academy, the guide, their profile and the new Welcome page (their onboarding
--      checklist). Passing is unchanged: every section of the path, each with its quiz passed at academy_pass_bps (80%),
--      retakes allowed. New: an Admin waives the gate for one person with a reason (academy_waivers, audited), and takes the
--      waiver back.
--   2. Welcome (staff_welcome): the first-login flow of a new hire: welcome, profile and phone, the academy, then their
--      first tasks (the first-day To do's of one-step Hire, ticked off there).
--   3. Content: four sections for the work of releases 33 and 34 (pickups and returns, money, listing photos, the caller
--      panel and renter notes), each with a quiz, appended to the paths of the roles that use them; written from the guide
--      chapters they name (academy_sections.guide_refs). Staff who had passed everything keep a week before the new sections
--      hold them (lock_from), as 0731 did; nothing is reset.
--   4. Kept up to date: when a guide chapter is published again (guide_sections.published_version changes), every section
--      that names it is flagged for review (review_due_at, review_note) on Admin > Academy until an Admin marks it reviewed.
-- No applied migration is edited; the door is wrapped (door_pre0802).
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

-- ================================================================ 1. the guide chapters of each section, and the review flag
alter table academy_sections
  add column if not exists guide_refs text[] not null default '{}',
  add column if not exists review_due_at timestamptz,
  add column if not exists review_note text,
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references users (id);
comment on column academy_sections.guide_refs is 'The guide chapters (portal/slug) the section was written from (0802): when one is published again, the section is flagged for review.';
comment on column academy_sections.review_due_at is 'Set when a guide chapter of guide_refs was published again (0802); cleared when an Admin marks the section reviewed.';

create or replace function app.academy_flag_guides() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.published_version is distinct from old.published_version then
    update academy_sections
       set review_due_at = coalesce(review_due_at, now()),
           review_note = left(coalesce(review_note || '; ', '') || format('The guide chapter %s/%s (%s) was updated on %s', new.portal, new.slug, coalesce(new.published_title, new.title),
                                   to_char(now() at time zone 'America/Toronto', 'Mon DD, YYYY')), 600)
     where (new.portal || '/' || new.slug) = any (guide_refs);
  end if;
  return new;
end $$;
drop trigger if exists guide_sections_flag_academy on guide_sections;
create trigger guide_sections_flag_academy after update on guide_sections for each row execute function app.academy_flag_guides();

-- ================================================================ 2. waivers
create table if not exists academy_waivers (
  user_id     uuid primary key references users (id) on delete cascade,
  waived_by   uuid not null references users (id),
  reason      text not null check (length(btrim(reason)) between 3 and 300),
  waived_at   timestamptz not null default now(),
  revoked_at  timestamptz,
  revoked_by  uuid references users (id)
);
comment on table academy_waivers is 'The academy gate waived by an Admin for one person (0802), with the reason; revoked_at set when taken back. Audited.';
alter table academy_waivers enable row level security;
drop policy if exists admin_all on academy_waivers;
create policy admin_all on academy_waivers for select to authenticated using (app.is_admin());
revoke all on academy_waivers from anon, authenticated;
drop trigger if exists audit_academy_waivers on academy_waivers;
create trigger audit_academy_waivers after insert or update or delete on academy_waivers for each row execute function app.audit_row();

create or replace function app.academy_waived(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from academy_waivers w where w.user_id = p_user and w.revoked_at is null)
$$;

-- the hold (0731), unless an Admin waived it for the person
create or replace function app.academy_locked(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((app.settings()).academy_gate, false) and not app.user_is_admin(p_user)
     and exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('va', 'field'))
     and not app.academy_done(p_user)
     and not app.academy_waived(p_user)
     and coalesce((select min(e.lock_from) from academy_enrollments e where e.user_id = p_user and e.gate), now()) <= now()
$$;

create or replace function app.academy_home(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('paths', coalesce((select jsonb_agg(app.academy_path_progress(p_user, c) order by ap.sort) from unnest(app.academy_paths_of(p_user)) c join academy_paths ap on ap.code = c), '[]'::jsonb),
    'gate', coalesce((app.settings()).academy_gate, false), 'locked', app.academy_locked(p_user), 'pass_bps', (app.settings()).academy_pass_bps,
    'lock_from', (select min(e.lock_from) from academy_enrollments e where e.user_id = p_user and e.gate),
    'waived', app.academy_waived(p_user))
$$;

-- the gate of one person, for Admin (the academy progress page and the hiring card)
create or replace function app.academy_gate_state(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('user_id', p_user, 'locked', app.academy_locked(p_user), 'done', app.academy_done(p_user),
    'passed', (select count(*) from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(p_user)) and ps.path_code <> 'admin' and app.academy_passed(p_user, ps.section_id)),
    'sections', (select count(*) from academy_path_sections ps where ps.path_code = any (app.academy_paths_of(p_user)) and ps.path_code <> 'admin'),
    'lock_from', (select min(e.lock_from) from academy_enrollments e where e.user_id = p_user and e.gate),
    'waiver', (select jsonb_build_object('reason', w.reason, 'at', w.waived_at, 'by', (select u.full_name from users u where u.id = w.waived_by))
                 from academy_waivers w where w.user_id = p_user and w.revoked_at is null))
$$;

create or replace function app.academy_waive(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid := nullif(p ->> 'user_id', '')::uuid;
  v_on boolean := coalesce((p ->> 'on')::boolean, true);
  v_reason text := btrim(coalesce(p ->> 'reason', ''));
begin
  if not app.user_is_admin(p_by) then raise exception 'Only an Admin can waive the academy' using errcode = '42501'; end if;
  if v_user is null or not exists (select 1 from user_roles r where r.user_id = v_user and r.role in ('va', 'field')) then
    raise exception 'That person is not on the staff' using errcode = '22023';
  end if;
  if v_on then
    if length(v_reason) < 3 then raise exception 'Give the reason for waiving the academy' using errcode = '22023'; end if;
    insert into academy_waivers (user_id, waived_by, reason) values (v_user, p_by, left(v_reason, 300))
    on conflict (user_id) do update set waived_by = excluded.waived_by, reason = excluded.reason, waived_at = now(), revoked_at = null, revoked_by = null;
  else
    update academy_waivers set revoked_at = now(), revoked_by = p_by where user_id = v_user and revoked_at is null;
  end if;
  return app.academy_gate_state(v_user);
end $$;

-- the sections flagged for review, for Admin > Academy
create or replace function app.academy_reviews(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.user_is_admin(p_by) then raise exception 'Admins only' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'slug', s.slug, 'title', s.title, 'guides', s.guide_refs, 'due_at', s.review_due_at, 'note', s.review_note) order by s.review_due_at)
                     from academy_sections s where s.review_due_at is not null), '[]'::jsonb);
end $$;

create or replace function app.academy_review_done(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  if not app.user_is_admin(p_by) then raise exception 'Admins only' using errcode = '42501'; end if;
  update academy_sections set review_due_at = null, review_note = null, reviewed_at = now(), reviewed_by = p_by
   where id::text = p ->> 'id' or slug = p ->> 'id' returning id into v_id;
  if v_id is null then raise exception 'No such section' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- ================================================================ 3. Welcome: the first-login flow
create or replace function app.staff_welcome(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  u users;
  sp staff_profiles;
  v_field boolean;
  v_g jsonb;
  v_tasks jsonb;
  v_profile boolean;
begin
  if not exists (select 1 from user_roles r where r.user_id = p_user and r.role in ('va', 'field')) then raise exception 'Staff only' using errcode = '42501'; end if;
  select * into u from users where id = p_user;
  select * into sp from staff_profiles where user_id = p_user;
  v_field := not exists (select 1 from user_roles r where r.user_id = p_user and r.role = 'va');
  v_g := app.academy_gate_state(p_user);
  v_profile := nullif(btrim(coalesce(sp.home_address, '')), '') is not null and nullif(btrim(coalesce(u.phone, '')), '') is not null;
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'title', t.title, 'detail', t.detail, 'done', t.status in ('done', 'cancelled')) order by t.created_at, t.title), '[]'::jsonb)
    into v_tasks from tasks t where t.task_type = 'first_day' and t.assigned_to = p_user;
  return jsonb_build_object('name', coalesce(nullif(btrim(u.full_name), ''), 'there'), 'portal', case when v_field then 'field' else 'va' end,
    'locked', (v_g ->> 'locked')::boolean,
    'steps', jsonb_build_array(
      jsonb_build_object('key', 'welcome', 'done', true),
      jsonb_build_object('key', 'profile', 'done', v_profile, 'phone', u.phone is not null, 'phone_verified', u.phone_verified_at is not null, 'address', nullif(btrim(coalesce(sp.home_address, '')), '') is not null),
      jsonb_build_object('key', 'academy', 'done', (v_g ->> 'done')::boolean or v_g -> 'waiver' <> 'null'::jsonb, 'passed', v_g -> 'passed', 'sections', v_g -> 'sections', 'waived', v_g -> 'waiver' <> 'null'::jsonb),
      jsonb_build_object('key', 'tasks', 'done', not exists (select 1 from jsonb_array_elements(v_tasks) x where not (x ->> 'done')::boolean), 'tasks', v_tasks)));
end $$;

-- a first-day To do ticked off on Welcome (its own only)
create or replace function app.staff_welcome_task(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  update tasks set status = 'done', completed_at = now(), completed_by = p_user
   where id = nullif(p ->> 'id', '')::uuid and task_type = 'first_day' and assigned_to = p_user and status not in ('done', 'cancelled')
   returning id into v_id;
  if v_id is null and not exists (select 1 from tasks where id = nullif(p ->> 'id', '')::uuid and task_type = 'first_day' and assigned_to = p_user) then
    raise exception 'That is not one of your first-day tasks' using errcode = '42501';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ================================================================ 4. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0802;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if (p_call = 'admin_read' and p_name in ('academy_gate_state', 'academy_reviews'))
     or (p_call = 'admin_do' and p_name in ('academy_waive', 'academy_review_done'))
     or (p_call = 'ops_read' and p_name = 'staff_welcome') or (p_call = 'ops_do' and p_name = 'staff_welcome_task') then
    perform app.door_begin(p_user, p_aal);
    p := coalesce(p, '{}'::jsonb) - '_va';
    if p_call like 'admin%' and not app.user_is_admin(p_user) then raise exception 'Admins only' using errcode = '42501'; end if;
    return case p_name
      when 'academy_gate_state' then app.academy_gate_state(nullif(p ->> 'user_id', '')::uuid)
      when 'academy_reviews' then app.academy_reviews(p_user, p)
      when 'academy_waive' then app.academy_waive(p_user, p)
      when 'academy_review_done' then app.academy_review_done(p_user, p)
      when 'staff_welcome' then app.staff_welcome(p_user)
      else app.staff_welcome_task(p_user, p) end;
  end if;
  return app.door_pre0802(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0802(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 5. the content of releases 33 and 34
-- staff who had passed everything keep a week before the new sections hold them (0731's rule); nothing is reset
create temp table r34n_done on commit drop as
  select sp.user_id from staff_profiles sp where sp.is_active and app.academy_done(sp.user_id);

-- ACADEMY 0802 START (generated by supabase/seed/0802_gen_academy.mjs from supabase/seed/academy/r34.mjs; do not edit by hand)
insert into academy_sections (slug, title, blurb, guide_refs) values ('new-r33-bookings', 'New in releases 33 and 34: pickups, returns and offers', 'Check-in is the pickup and check-out the return, the Sign and pay page, Book it now, and an Admin override when a check stops a trip.', array['admin/requests-offers-and-bookings', 'va/customer-service', 'va/sales', 'va/fleet', 'field/a-handover', 'field/a-return']::text[]) on conflict (slug) do update set title = excluded.title, blurb = excluded.blurb, guide_refs = excluded.guide_refs, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r33-bookings'), 1, 'The words: check-in and check-out', '[{"caption":"Check-in is the pickup","say":"Check-in is the pickup: the start of the booking, when the renter takes the car. Check-out is the return: the drop-off at the end.","visual":{"kind":"list","heading":"The two words","items":["Check-in: the pickup, the start","Check-out: the return, the end"]}},{"caption":"The mid-trip message","say":"The message we send during a trip is called the Mid-trip check, so nobody reads it as the pickup.","visual":{"kind":"title","heading":"Mid-trip check","text":"Not a check-in"}},{"caption":"Say it the same way","say":"Use the same words with renters and with the team. A renter who says they want to check in is asking about the pickup.","visual":{"kind":"chat","lines":[{"who":"renter","text":"When can I check in?"},{"who":"you","text":"Your pickup is Friday at 10 am. You can do the check-in from 24 hours before, on your booking."}]}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r33-bookings'), 2, 'Sign and pay on one page', '[{"caption":"One page","say":"A renter signs and pays on one page, Sign and pay. It says what is left in one sentence with the amount, then the signature, then the card form right below.","visual":{"kind":"steps","heading":"Sign and pay","items":["What is left, with the amount","Sign the agreement","Pay below, on the same page"]}},{"caption":"Old links still work","say":"The old sign and pay links open the same page. Send the renter the Sign and pay link from the booking.","visual":{"kind":"rule","heading":"One link","text":"Send the Sign and pay link from the booking.","tone":"ok"}},{"caption":"Book it now","say":"When you send an offer and the renter already agreed, tick Book it now. An Admin''s offer is booked at once; a staff offer waits for an Admin''s one-tap approval. The booking then waits for payment and holds the car.","visual":{"kind":"list","heading":"Book it now","items":["Tick it when the renter agreed","Admin: booked at once","Staff: an Admin approves in one tap","The renter gets one Sign and pay link"]}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r33-bookings'), 3, 'When a check stops the pickup or the return', '[{"caption":"What stops it now","say":"On the booking, What stops the pickup now lists each check in plain words: the deposit, the signature, the licence, the coverage, payment due, and others.","visual":{"kind":"title","heading":"What stops the pickup now","text":"Each check in plain words"}},{"caption":"Ask an Admin to override","say":"When the trip must go ahead, press Ask an Admin to override, give the actual time, km and fuel if you know them, and why. An Admin approves in one tap and it is recorded with your time.","visual":{"kind":"steps","heading":"An override","items":["Ask an Admin to override","The time, km and fuel, and why","An Admin approves in one tap","Recorded in the booking history"]}},{"caption":"A past trip","say":"A trip that happened and was never recorded: Ask to record a past trip with both times. Once approved, the booking is Returned and the deposit can be settled.","visual":{"kind":"rule","heading":"One override, one booking","text":"It passes only the checks it lists, once.","tone":"warn"}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-bookings'), 1, 'A renter says they want to check in. What are they asking about?', '["The return","The pickup, the start of the booking","The mid-trip check","Their deposit"]'::jsonb, 1, 'Check-in is the pickup; check-out is the return.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-bookings'), 2, 'Where does a renter sign and pay?', '["Two pages: sign, then a pay page","One Sign and pay page: sign, then the card form right below","By email only","At the pickup only"]'::jsonb, 1, 'Sign and pay is one page; the old links open it too.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-bookings'), 3, 'You send an offer with Book it now as a staff member. What happens?', '["It is booked at once","An Admin approves it in one tap, then it is booked and waits for payment","The renter must approve twice","Nothing until the renter pays"]'::jsonb, 1, 'A staff Book it now waits for an Admin''s one-tap approval.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-bookings'), 4, 'The deposit check stops a pickup that must go ahead. What do you do?', '["Record it anyway","Ask an Admin to override, with the time and the reason","Cancel the booking","Waive the deposit yourself"]'::jsonb, 1, 'Only an Admin overrides, one booking and one time, with a reason.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-bookings'), 5, 'A trip happened and was never recorded. What is the step?', '["Make a new booking","Ask to record a past trip with both times","Delete the booking","Nothing"]'::jsonb, 1, 'Record a past trip: once approved, the booking is Returned.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_path_sections (path_code, section_id, sort) select 'cs', (select id from academy_sections where slug = 'new-r33-bookings'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'cs' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'sales_in_person', (select id from academy_sections where slug = 'new-r33-bookings'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'sales_in_person' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'sales_remote', (select id from academy_sections where slug = 'new-r33-bookings'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'sales_remote' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'fleet', (select id from academy_sections where slug = 'new-r33-bookings'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'fleet' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'field', (select id from academy_sections where slug = 'new-r33-bookings'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'field' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'admin', (select id from academy_sections where slug = 'new-r33-bookings'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'admin' on conflict (path_code, section_id) do nothing;
insert into academy_sections (slug, title, blurb, guide_refs) values ('new-r33-money', 'New in release 33: charging the renter and owner invoices', 'Charge the renter after a return with a reason, an expired card hold, the debit deposit fee, and an owner invoice paid outside the platform.', array['admin/requests-offers-and-bookings', 'admin/owner-money', 'va/finance']::text[]) on conflict (slug) do update set title = excluded.title, blurb = excluded.blurb, guide_refs = excluded.guide_refs, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r33-money'), 1, 'Charge the renter', '[{"caption":"One action after the return","say":"After the return, the Money tab has one action: Charge the renter. Choose the reason, the amount and an optional note.","visual":{"kind":"steps","heading":"Charge the renter","items":["The reason from the list","The amount","A note if needed"]}},{"caption":"Where the money comes from","say":"Before anything moves, one line says where it comes from: the deposit hold while it is valid and covers it, else the card on file, else a pay link by text or email.","visual":{"kind":"list","heading":"In this order","items":["The deposit hold","The card on file","A pay link"]}},{"caption":"The reasons","say":"Mileage overage, fuel, cleaning, smoking, late return, tolls, tickets, damage, missing items, or Other with a note. The renter sees the reason.","visual":{"kind":"rule","heading":"A reason every time","text":"Other needs a note.","tone":"warn"}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r33-money'), 2, 'Holds and the debit deposit', '[{"caption":"Hold expired","say":"A card hold lapses after about seven days. The deposit panel then says Hold expired; use Charge the card on file instead.","visual":{"kind":"title","heading":"Hold expired","text":"Charge the card on file instead"}},{"caption":"Debit and prepaid","say":"A deposit charged on a debit or prepaid card carries a card processing fee on the same charge, apart from the deposit, so the refund is the deposit only.","visual":{"kind":"money","heading":"A debit deposit","rows":[["Deposit","$1,000.00"],["Card processing fee","2.9% plus 30 cents"]]}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r33-money'), 3, 'An owner invoice paid outside the platform', '[{"caption":"Already paid","say":"On the owner invoice page, choose how it was paid outside the platform: e-Transfer, cash, cheque, bank transfer or card, with the date, reference and amount.","visual":{"kind":"list","heading":"Already paid outside the platform","items":["How it was paid","The date and reference","The amount (empty: the balance)"]}},{"caption":"No receipt unless asked","say":"No receipt email is sent unless you tick Email the owner a receipt.","visual":{"kind":"rule","heading":"Receipt","text":"Off unless ticked.","tone":"ok"}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-money'), 1, 'After a return, how do you bill fuel?', '["Edit the booking total","Charge the renter, with the reason Fuel and the amount","Ask the renter to send money","Keep the whole deposit"]'::jsonb, 1, 'Charge the renter, with a reason from the list.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-money'), 2, 'Where does Charge the renter take the money from first?', '["The card on file","The deposit hold while it is valid and covers the amount","A pay link","The owner"]'::jsonb, 1, 'The hold first, then the card on file, then a pay link.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-money'), 3, 'The panel says Hold expired. What now?', '["Capture the hold","Charge the card on file instead","Release nothing","Cancel the booking"]'::jsonb, 1, 'A lapsed hold cannot be captured; charge the card on file.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-money'), 4, 'An owner paid an invoice by e-Transfer. Do they get a receipt email?', '["Always","Only if you tick Email the owner a receipt","Never","Only for cash"]'::jsonb, 1, 'The receipt is off unless ticked.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-money'), 5, 'A deposit is charged on a debit card. What is refunded later?', '["The deposit and the card fee","The deposit only; the card processing fee is apart","Nothing","Half the deposit"]'::jsonb, 1, 'The fee is on the same charge but apart from the deposit, so the refund is the deposit only.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_path_sections (path_code, section_id, sort) select 'finance', (select id from academy_sections where slug = 'new-r33-money'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'finance' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'admin', (select id from academy_sections where slug = 'new-r33-money'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'admin' on conflict (path_code, section_id) do nothing;
insert into academy_sections (slug, title, blurb, guide_refs) values ('new-r33-photos', 'New in release 33: listing photos from a shared folder', 'Import a car''s photos, or many cars at once, from a shared folder link, and confirm the match before anything is imported.', array['admin/fleet-and-listings', 'va/fleet']::text[]) on conflict (slug) do update set title = excluded.title, blurb = excluded.blurb, guide_refs = excluded.guide_refs, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r33-photos'), 1, 'Import photos from a folder link', '[{"caption":"One car","say":"On a car''s listing page, paste the folder link under the photos. The folder and the folders inside it are read, and every photo goes to that car.","visual":{"kind":"title","heading":"One car","text":"Paste the link on its listing"}},{"caption":"Many cars","say":"Listings, Import photos: the page walks the whole folder tree and proposes a car for each folder. Two alike cars are marked Check this one.","visual":{"kind":"steps","heading":"Many cars","items":["Paste the top folder link","Check each proposed car","Tick Import, or leave a folder out","Import"]}},{"caption":"Plates still checked","say":"Imported photos go through the same review: a readable plate is covered before a photo is published.","visual":{"kind":"rule","heading":"Plates","text":"Never publish a readable plate.","tone":"warn"}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-photos'), 1, 'Two folders look like the same model. What does the import page do?', '["Imports both to one car","Marks them Check this one so you confirm the car","Skips them","Deletes one"]'::jsonb, 1, 'Confirm the car before anything is imported.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-photos'), 2, 'Do imported photos skip the plate check?', '["Yes","No: a readable plate is covered before publishing","Only for one car","Only for partners"]'::jsonb, 1, 'The same review applies to imported photos.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-photos'), 3, 'Where do you import the photos of one car?', '["On the owner page","On the car''s listing page, under the photos","In Settings","By email"]'::jsonb, 1, 'Paste the folder link on that car''s listing page.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-photos'), 4, 'You import many cars at once. When is anything imported?', '["As soon as you paste the link","Only after you check the proposed cars and press Import","The next day","Never"]'::jsonb, 1, 'The table is confirmed or changed before anything is imported.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r33-photos'), 5, 'A folder should not be imported. What do you do?', '["Delete it from the link","Leave it out: untick Import for that folder","Import it and delete later","Ask the owner"]'::jsonb, 1, 'Leave a folder out by not ticking Import.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_path_sections (path_code, section_id, sort) select 'fleet', (select id from academy_sections where slug = 'new-r33-photos'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'fleet' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'cs', (select id from academy_sections where slug = 'new-r33-photos'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'cs' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'admin', (select id from academy_sections where slug = 'new-r33-photos'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'admin' on conflict (path_code, section_id) do nothing;
insert into academy_sections (slug, title, blurb, guide_refs) values ('new-r34-caller-notes', 'New in release 34: who is calling, and renter notes', 'The caller panel when a renter calls the CarmaCars number, notes on every renter, and opening a record from a call.', array['admin/texts-and-calls-the-quo-phone-line', 'va/texts-and-calls']::text[]) on conflict (slug) do update set title = excluded.title, blurb = excluded.blurb, guide_refs = excluded.guide_refs, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r34-caller-notes'), 1, 'Who is calling', '[{"caption":"The panel opens","say":"When someone calls the CarmaCars number, a panel opens in your portal while it rings, and stays for three minutes after the call. Customer service and Admins get it.","visual":{"kind":"title","heading":"Who is calling","text":"While it rings, and 3 minutes after"}},{"caption":"What it shows","say":"For a renter: the booking on rent or coming next, the balance owed, the deposit, what they are waiting on and the last notes.","visual":{"kind":"list","heading":"A renter","items":["The booking","The balance owed","The deposit","What they wait on","The last notes"]}},{"caption":"An unknown number","say":"An unknown number shows Unknown caller. Press Create lead to keep it.","visual":{"kind":"rule","heading":"Unknown caller","text":"Create lead in one tap.","tone":"ok"}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_lessons (section_id, sort, title, scenes) values ((select id from academy_sections where slug = 'new-r34-caller-notes'), 2, 'Renter notes', '[{"caption":"One note for each situation","say":"Write a note for every situation: what they asked, what you told them, what happens next. It keeps the time, your name and the booking.","visual":{"kind":"chat","lines":[{"who":"you","text":"Asked to return a day early; told them Fleet confirms by text today."}]}},{"caption":"Never changed","say":"Nobody changes a note. To correct one, write a new note. Only an Admin removes a note, with a reason kept in the audit log.","visual":{"kind":"rule","heading":"Notes","text":"Add, never edit. An Admin removes with a reason.","tone":"warn"}},{"caption":"Opening a record from a call","say":"A record outside your window opens from the panel of that renter''s call, logged for 24 hours as an incoming call.","visual":{"kind":"title","heading":"Open the renter''s page","text":"Logged as an incoming call"}}]'::jsonb) on conflict (section_id, sort) do update set title = excluded.title, scenes = excluded.scenes, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r34-caller-notes'), 1, 'A renter calls. Where do you see their deposit and what they owe?', '["Nowhere until you search","In the caller panel that opens while it rings","In an email","Only an Admin sees it"]'::jsonb, 1, 'The caller panel shows the booking, balance, deposit, requests and notes.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r34-caller-notes'), 2, 'You wrote a note with a mistake. What do you do?', '["Edit it","Write a new note that corrects it","Delete it","Ask the renter"]'::jsonb, 1, 'Notes are never changed; only an Admin removes one, with a reason.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r34-caller-notes'), 3, 'An unknown number calls. What is the one tap?', '["Block it","Create lead","Call back later","Nothing"]'::jsonb, 1, 'Unknown caller has Create lead.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r34-caller-notes'), 4, 'How long does the panel stay after the call ends?', '["It closes at once","Three minutes, so you can write the note","A whole day","Until the next call"]'::jsonb, 1, 'It stays three minutes after the end.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_questions (section_id, sort, prompt, options, answer, explain) values ((select id from academy_sections where slug = 'new-r34-caller-notes'), 5, 'The renter is outside your window. How do you open their record during their call?', '["You cannot","Open the renter''s page from the panel: it is logged as an incoming call for 24 hours","Ask the renter for their password","Search for them by email"]'::jsonb, 1, 'Opening from the call is logged, as Open with a reason is.') on conflict (section_id, sort) do update set prompt = excluded.prompt, options = excluded.options, answer = excluded.answer, explain = excluded.explain, updated_at = now();
insert into academy_path_sections (path_code, section_id, sort) select 'cs', (select id from academy_sections where slug = 'new-r34-caller-notes'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'cs' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'sales_in_person', (select id from academy_sections where slug = 'new-r34-caller-notes'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'sales_in_person' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'sales_remote', (select id from academy_sections where slug = 'new-r34-caller-notes'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'sales_remote' on conflict (path_code, section_id) do nothing;
insert into academy_path_sections (path_code, section_id, sort) select 'admin', (select id from academy_sections where slug = 'new-r34-caller-notes'), coalesce(max(sort), 0) + 1 from academy_path_sections where path_code = 'admin' on conflict (path_code, section_id) do nothing;
update academy_sections set guide_refs = array['admin/requests-offers-and-bookings', 'va/customer-service']::text[] where slug = 'prices-and-deposits' and guide_refs = '{}';
update academy_sections set guide_refs = array['va/customer-service']::text[] where slug = 'cs-requests' and guide_refs = '{}';
update academy_sections set guide_refs = array['va/customer-service', 'admin/requests-offers-and-bookings']::text[] where slug = 'documents-and-signing' and guide_refs = '{}';
update academy_sections set guide_refs = array['field/a-handover']::text[] where slug = 'field-handover' and guide_refs = '{}';
update academy_sections set guide_refs = array['field/a-return']::text[] where slug = 'field-return-and-cash' and guide_refs = '{}';
update academy_sections set guide_refs = array['va/fleet', 'admin/fleet-and-listings']::text[] where slug = 'fleet-cars' and guide_refs = '{}';
update academy_sections set guide_refs = array['va/fleet']::text[] where slug = 'fleet-field-jobs' and guide_refs = '{}';
update academy_sections set guide_refs = array['va/finance']::text[] where slug = 'finance-deposits-refunds' and guide_refs = '{}';
update academy_sections set guide_refs = array['va/finance', 'admin/owner-money']::text[] where slug = 'finance-tolls-owners' and guide_refs = '{}';
update academy_sections set guide_refs = array['va/sales']::text[] where slug = 'sales-requests-and-quotes' and guide_refs = '{}';
update academy_sections set guide_refs = array['admin/insurance-replacements-rates-and-billing']::text[] where slug = 'insurer-billed-rentals' and guide_refs = '{}';
update academy_sections set guide_refs = array['admin/owners-and-onboarding']::text[] where slug = 'owner-recruitment' and guide_refs = '{}';
update academy_sections set guide_refs = array['admin/requests-offers-and-bookings']::text[] where slug = 'new-bookings-r28-r32' and guide_refs = '{}';
update academy_sections set guide_refs = array['va/finance']::text[] where slug = 'new-money-r28-r32' and guide_refs = '{}';
update academy_sections set guide_refs = array['admin/fleet-and-listings']::text[] where slug = 'new-cars-r28-r32' and guide_refs = '{}';
-- ACADEMY 0802 END

insert into academy_enrollments (user_id, path_code, gate, lock_from, source)
select d.user_id, c, true, now() + interval '7 days', 'existing'
  from r34n_done d cross join lateral unnest(app.academy_paths_of(d.user_id)) c
 where c <> 'admin'
on conflict (user_id, path_code) do update set lock_from = greatest(academy_enrollments.lock_from, excluded.lock_from);

-- ================================================================ 6. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['academy_flag_guides', 'academy_waived', 'academy_gate_state', 'academy_waive', 'academy_reviews',
             'academy_review_done', 'staff_welcome', 'staff_welcome_task', 'door_pre0802'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
-- academy_locked keeps its grants (create or replace); the trigger function runs as its owner
