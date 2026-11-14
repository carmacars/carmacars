-- 2897 (release 47, part B): the Admin's To do list keeps what needs the Admin. One Hire (0730) opened a To do per hire
-- ("First day for ...") and per pay details entered ("Verify new pay details: ..."): 39 and 19 open at once. Now one
-- standing To do each, written again whenever a hire, their agreement or their pay details change, and every hour:
--   "New staff this week: N still onboarding" (task type first_day_admin): one line per hire of the last 60 days with
--     what their onboarding still waits on (signing in, the staff agreement, their pay details or an Admin's check of
--     them, the academy) and the hire's page; a hire drops off by themselves once nothing waits; the To do closes by
--     itself when nobody is left.
--   "Pay details to verify: N" (verify_staff_payout): one line per person whose current pay details are not verified,
--     with the Verify link; a person drops off once verified; closes by itself when nobody is left.
-- The per-hire and per-payout To do's are no longer opened (their raise is answered by the digest), and the open ones
-- are closed into the digests here, with a note. docs/changes/2026-11-14-r47b-crash-alerts-photo-standard.md.

-- ================================================================ 1. what one hire still waits on (empty: done)
create or replace function app.staff_onboarding_waits(p_app uuid) returns text[]
language sql stable security definer set search_path = public, app as $$
  select array_remove(array[
      case when u.last_sign_in_at is null then 'signing in' end,
      case when not exists (select 1 from sign_requests s where s.staff_user_id = o.user_id and s.doc_type = 'staff_agreement' and s.status = 'signed') then
        case when exists (select 1 from sign_requests s where s.staff_user_id = o.user_id and s.doc_type = 'staff_agreement' and s.status = 'sent') then 'their signature on the staff agreement'
             when cardinality(o.agreement_missing) > 0 then 'their details for the agreement (' || array_to_string(o.agreement_missing, ', ') || ')'
             else 'the staff agreement to be sent' end end,
      case when pa.id is null then 'their pay details' when pa.verified_at is null then 'an Admin to verify their pay details' end,
      case when exists (select 1 from academy_enrollments e join academy_path_sections ps on ps.path_code = e.path_code
                         where e.user_id = o.user_id and not app.academy_passed(o.user_id, ps.section_id)) then 'the academy' end
    ]::text[], null)
  from staff_onboarding o join users u on u.id = o.user_id
  left join staff_payout_accounts pa on pa.user_id = o.user_id and pa.is_current
  where o.application_id = p_app
$$;

-- ================================================================ 2. one standing To do, written again or closed
create or replace function app.digest_task_put(p_type text, p_key text, p_n integer, p_title text, p_detail text) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare v_id uuid;
begin
  select id into v_id from tasks where dedupe_key = p_key and status in ('open', 'in_progress', 'waiting') order by created_at desc limit 1;
  if p_n = 0 then
    update tasks set status = 'done', completed_at = now(), completion_note = 'Nothing left: closed by itself (2897)' where id = v_id;
    return null;
  end if;
  if v_id is null then
    return app.raise_task(p_type => p_type, p_title => left(p_title, 200), p_detail => left(p_detail, 4000), p_queue => 'admin', p_priority => 'normal', p_dedupe => p_key);
  end if;
  update tasks set title = left(p_title, 200), detail = left(p_detail, 4000) where id = v_id and (title is distinct from left(p_title, 200) or detail is distinct from left(p_detail, 4000));
  return v_id;
end $$;

create or replace function app.staff_admin_digests_refresh() returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v_n integer;
  v_lines text;
begin
  -- the hires still onboarding
  select count(*), string_agg(x.line, E'\n' order by x.created_at desc) into v_n, v_lines from (
    select o.created_at, format('- %s (%s, starts %s): waiting on %s. /admin/hiring/%s', coalesce(u.full_name, u.email), coalesce(app.hire_path_of(o.path) ->> 'label', o.path),
                                to_char(o.start_on, 'Mon DD'), array_to_string(w.w, ', '), o.application_id) line
      from staff_onboarding o join users u on u.id = o.user_id
      cross join lateral (select app.staff_onboarding_waits(o.application_id) w) w
     where o.created_at > now() - interval '60 days' and u.status in ('invited', 'active') and not app.user_is_admin(o.user_id)
       and cardinality(w.w) > 0) x;
  perform app.digest_task_put('first_day_admin', 'staff_onboarding_digest', v_n,
    format('New staff this week: %s still onboarding', v_n),
    'Say hello and check their setup. Each line drops off by itself once nothing waits.' || E'\n' || coalesce(v_lines, ''));

  -- pay details waiting for an Admin's check
  select count(*), string_agg(x.line, E'\n' order by x.created_at) into v_n, v_lines from (
    select pa.created_at, format('- %s: %s, entered %s. Verify: %s', coalesce(u.full_name, u.email), app.staff_payout_masked(pa),
                                 to_char(pa.created_at at time zone 'America/Toronto', 'Mon DD'),
                                 coalesce('/admin/hiring/' || (select o.application_id from staff_onboarding o where o.user_id = pa.user_id order by o.created_at desc limit 1), '/admin/staff')) line
      from staff_payout_accounts pa join users u on u.id = pa.user_id
     where pa.is_current and pa.verified_at is null and u.status in ('invited', 'active')) x;
  perform app.digest_task_put('verify_staff_payout', 'staff_payout_digest', v_n,
    format('Pay details to verify: %s', v_n),
    'Confirm each with the staff member (a call or a message they started), then press Verify on their onboarding card or staff page. A person drops off by themselves once verified.'
      || E'\n' || coalesce(v_lines, ''));
end $$;

-- written again on every change that moves a line; a failure here never stops the change itself
create or replace function app.staff_admin_digests_touch() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    perform app.staff_admin_digests_refresh();
  exception when others then
    raise warning 'staff digests: %', sqlerrm;
  end;
  return null;
end $$;
drop trigger if exists staff_onboarding_digests on staff_onboarding;
create trigger staff_onboarding_digests after insert or update or delete on staff_onboarding for each statement execute function app.staff_admin_digests_touch();
drop trigger if exists staff_payout_digests on staff_payout_accounts;
create trigger staff_payout_digests after insert or update or delete on staff_payout_accounts for each statement execute function app.staff_admin_digests_touch();
drop trigger if exists sign_requests_staff_digests on sign_requests;
create trigger sign_requests_staff_digests after insert or update of status on sign_requests for each statement execute function app.staff_admin_digests_touch();

-- ================================================================ 3. the per-hire and per-payout To do's are answered by the digests
create or replace function app.tasks_r47_route() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if (new.task_type = 'first_day_admin' and new.dedupe_key like 'first_day_admin:%')
     or (new.task_type = 'verify_staff_payout' and new.dedupe_key like 'verify_staff_payout:%') then
    return null; -- the statement triggers above write the digest
  end if;
  return new;
end $$;
drop trigger if exists tasks_r47_route on tasks;
create trigger tasks_r47_route before insert on tasks for each row execute function app.tasks_r47_route();

-- the academy moves without any of the writes above: every hour
do $$
begin
  if to_regclass('cron.job') is not null then
    perform cron.schedule('carmacars-staff-digests', '23 * * * *', 'select app.staff_admin_digests_refresh()');
  end if;
end $$;

revoke all on function app.staff_onboarding_waits(uuid), app.digest_task_put(text, text, integer, text, text), app.staff_admin_digests_refresh(),
  app.staff_admin_digests_touch(), app.tasks_r47_route() from public, anon, authenticated;
grant execute on function app.staff_onboarding_waits(uuid), app.digest_task_put(text, text, integer, text, text), app.staff_admin_digests_refresh(),
  app.staff_admin_digests_touch(), app.tasks_r47_route() to service_role;

-- ================================================================ 4. once: the open ones folded in
update tasks set status = 'done', completed_at = now(),
       completion_note = 'Folded into the To do "New staff this week" (release 47, 2897): one line per hire with what still waits.'
 where task_type = 'first_day_admin' and dedupe_key like 'first_day_admin:%' and status in ('open', 'in_progress', 'waiting');
update tasks set status = 'done', completed_at = now(),
       completion_note = 'Folded into the To do "Pay details to verify" (release 47, 2897): one line per person, gone once verified.'
 where task_type = 'verify_staff_payout' and dedupe_key like 'verify_staff_payout:%' and status in ('open', 'in_progress', 'waiting');
select app.staff_admin_digests_refresh();
