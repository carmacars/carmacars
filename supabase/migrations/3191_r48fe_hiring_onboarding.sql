-- 3191 (release 48, part FE; docs/changes/2026-11-20-r48-fees-evidence-hiring.md): the hiring and onboarding funnel.
--
-- Live data (Nov 20): 109 applicants of other roles were "referred" to Sales and 3 applied: the referral (0226) was an email
-- with a link to a whole new application. 12 Sales applicants were invited and never finished the AI interview. Sales
-- applicants scoring 79 to 87 were declined.
-- 1. "Yes, put me in Sales": the referral email's button opens /careers/sales-yes/<token>; one press makes the Sales
--    application from the one they sent (name, email, phone, answers, place) and sends the AI interview link at once
--    (public.server_hiring_sales_offer, public.server_hiring_sales_yes). The email says so.
-- 2. A one-time re-send (hiring_resends): every applicant referred to Sales who has no Sales application, and every Sales
--    applicant invited who never finished the AI interview, once per email address, 3 minutes apart, through the hiring
--    job (email; the applicants have no staff account, so no push).
-- 3. The audit of the declines: the AI interview "passes" (2590, 2695) also needed the AI's recommendation not "decline"
--    (a Sales applicant recommended "sales" or "decline" with a score of 87 was declined) and every answer averaging 7
--    with none under 5, on top of the score at the bar (hiring_auto_hire_mark 80). For Sales the score at the bar
--    decides: the recommendation and the 7-average are advisory; a passed interview is still required: scored, at or
--    over the bar, no knock-out answer, English not basic, no answer under 4. Other roles keep the 2695 rule. Sales
--    applicants declined by the AI in the last 30 days who pass now are decided again (hired, with the onboarding email).
-- 4. Academy nudges: a hired staff member at the academy step with no academy progress gets a nudge (push and email,
--    staff alert academy_nudge, to the person) on day 1, 2 and 4 of no progress; the 5-day suspension (r48 CM) follows.
--    app.sales_academy_progress: the Sales path's passed and total per person; Admin > Hiring and the connector's
--    staff_onboarding_status show the counts.
-- 5. WhatsApp: a staff member who passed the Sales academy path sees the Sales group (CARMA Closers) link even when Sales
--    is not their main role. Each group shows the person's member tag pre-written ("Darren - Sales") with copy and the
--    steps; "I joined" needs "I set my member tag" (staff_profiles.whatsapp_tag_set_at). While whatsapp_team_group_url
--    or whatsapp_sales_group_url is empty an Admin To do (whatsapp_links_missing) stays open and Admin > Hiring warns.
-- No applied migration is edited: app.ai_interview_passes is replaced (one body, patched in 2695); app.hiring_decision_apply
-- is patched; app.staff_group_list is replaced; app.staff_whatsapp_confirm, app.staff_onboarding_list, app.api_read and
-- app.job_hiring are wrapped or patched (_pre3191).
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
declare d text := pg_get_functiondef(p_sig);
begin
  if position(p_old in d) = 0 then raise exception '3191: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 3. the bar (Sales: the score decides)
create or replace function app.ai_interview_passes(i ai_interviews, a job_applications, r hiring_roles) returns boolean
language sql stable security definer set search_path = public, app as $$
  select i.state = 'scored' and coalesce(i.interview_score, 0) >= app.hire_auto_mark(r) and cardinality(coalesce(a.knockouts, '{}')) = 0
     and jsonb_array_length(app.ai_interview_knockouts(i)) = 0
     and case when r.va_function = 'sales' and r.staff_kind is distinct from 'field' then
           -- Sales (3191): a passed interview is the score at the bar; English not basic and no answer under 4
           coalesce(i.result #>> '{english,level}', 'good') <> 'basic'
           and (jsonb_typeof(i.result -> 'answers') is distinct from 'array' or jsonb_array_length(i.result -> 'answers') = 0
                or coalesce((select min((e ->> 'score')::int) from jsonb_array_elements(i.result -> 'answers') e where (e ->> 'score') ~ '^\d+$'), 10) >= 4)
         else
           coalesce(i.recommendation, '') <> 'decline'
           and coalesce(i.result #>> '{english,level}', 'good') in ('good', 'fluent')
           and (jsonb_typeof(i.result -> 'answers') is distinct from 'array' or jsonb_array_length(i.result -> 'answers') = 0
                or ((select avg((e ->> 'score')::numeric) from jsonb_array_elements(i.result -> 'answers') e) >= 7
                    and (select min((e ->> 'score')::int) from jsonb_array_elements(i.result -> 'answers') e) >= 5))
         end
$$;

-- why an interview did not pass, in words (the Admin's audit and the alert)
create function app.ai_interview_fail_reasons(i ai_interviews, a job_applications, r hiring_roles) returns text[]
language sql stable security definer set search_path = public, app as $$
  select array_remove(array[
    case when i.state is distinct from 'scored' then 'not scored' end,
    case when coalesce(i.interview_score, 0) < app.hire_auto_mark(r) then format('score %s under the bar of %s', coalesce(i.interview_score, 0), app.hire_auto_mark(r)) end,
    case when cardinality(coalesce(a.knockouts, '{}')) > 0 or jsonb_array_length(app.ai_interview_knockouts(i)) > 0 then 'a knock-out answer' end,
    case when coalesce(i.result #>> '{english,level}', 'good') = 'basic' then 'basic English' end,
    case when not (r.va_function = 'sales' and r.staff_kind is distinct from 'field') and coalesce(i.recommendation, '') = 'decline' then 'the AI recommended declining' end,
    case when jsonb_typeof(i.result -> 'answers') = 'array' and jsonb_array_length(i.result -> 'answers') > 0
              and (select min((e ->> 'score')::int) from jsonb_array_elements(i.result -> 'answers') e where (e ->> 'score') ~ '^\d+$')
                  < case when r.va_function = 'sales' then 4 else 5 end then 'an answer scored too low' end], null)
$$;

-- ================================================================ 1. "Yes, put me in Sales"
select pg_temp.patch_fn('app.hiring_decision_apply(uuid, uuid)'::regprocedure,
  $o$app.hiring_url('/careers/' || s.slug || '/apply?ref=' || a.token || '&src=referral')$o$,
  $n$app.hiring_url('/careers/sales-yes/' || a.token)$n$);

-- the Sales role an applicant was referred to (or would be)
create function app.hiring_sales_target(a job_applications) returns hiring_roles
language sql stable security definer set search_path = public, app as $$
  select r.* from hiring_roles r where r.id = coalesce(a.referred_role_id, (app.hiring_sales_role_for(a)).id)
$$;

-- the page: who, from which role, to which Sales role, and whether it is done already
create function public.server_hiring_sales_offer(p_token text) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  a job_applications;
  s hiring_roles;
  x job_applications;
  iv ai_interviews;
begin
  select * into a from job_applications where token = btrim(coalesce(p_token, '')) and purged_at is null;
  if a.id is null then return null; end if;
  s := app.hiring_sales_target(a);
  if s.id is null then return null; end if;
  select * into x from job_applications j where j.role_id = s.id and lower(j.email) = lower(a.email) and j.purged_at is null and j.id <> a.id order by j.created_at desc limit 1;
  if x.id is not null then select * into iv from ai_interviews where application_id = x.id; end if;
  return jsonb_build_object('first_name', split_part(btrim(a.full_name), ' ', 1), 'from_role', (select coalesce(r.short_title, r.title) from hiring_roles r where r.id = a.role_id),
    'sales_role', s.title, 'sales_summary', s.summary, 'eligible', a.status in ('referred', 'declined', 'rejected', 'below_bar') or a.referred_role_id is not null,
    'done', x.id is not null, 'interview_state', iv.state, 'interview_url', case when x.id is not null and iv.state in ('sent', 'started') then app.hiring_url('/careers/interview/' || x.token) end);
end $$;

-- one press: the Sales application from the one they sent, and the AI interview link straight away
create function public.server_hiring_sales_yes(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  s hiring_roles;
  x job_applications;
  iv ai_interviews;
begin
  select * into a from job_applications where token = btrim(coalesce(p_token, '')) and purged_at is null for update;
  if a.id is null then raise exception 'This link is not valid any more' using errcode = 'P0002'; end if;
  if a.hired_user_id is not null then raise exception 'You are already on the team: sign in to the staff portal' using errcode = '23514'; end if;
  s := app.hiring_sales_target(a);
  if s.id is null or not s.active then raise exception 'The Sales role is not open right now' using errcode = '23514'; end if;
  if nullif(btrim(coalesce(a.email, '')), '') is null then raise exception 'We need your email for the interview link: apply on the Sales page' using errcode = '22023'; end if;
  select * into x from job_applications j where j.role_id = s.id and lower(j.email) = lower(a.email) and j.purged_at is null and j.id <> a.id order by j.created_at desc limit 1 for update;
  if x.id is null then
    insert into job_applications (role_id, status, full_name, email, phone, profile_name, source, utm, answers, referred_from, work_mode, screened_at, invited_at, note,
                                  location_city, location_region, location_country, phone_country, ip_country, location_area)
    values (s.id, 'invited', a.full_name, a.email, a.phone, a.profile_name, 'referral', a.utm || jsonb_build_object('sales_yes', true), a.answers, a.id,
            coalesce(s.work_mode, case when s.remote then 'remote' else 'in_person' end), now(), now(),
            format('Sales referral (Yes, put me in Sales) from the %s application', (select coalesce(r.short_title, r.title) from hiring_roles r where r.id = a.role_id)),
            a.location_city, a.location_region, a.location_country, a.phone_country, a.ip_country, a.location_area)
    returning * into x;
    update job_applications set note = concat_ws(E'\n', note, 'Said yes to Sales: ' || to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI')), updated_at = now() where id = a.id;
    perform app.ai_interview_send(x);
  else
    select * into iv from ai_interviews where application_id = x.id;
    if iv.id is null or iv.state in ('sent', 'started', 'expired') then
      update job_applications set status = 'invited', invited_at = coalesce(invited_at, now()), updated_at = now() where id = x.id and status in ('new', 'invited', 'referred') returning * into x;
      if x.id is null then select * into x from job_applications j where j.role_id = s.id and lower(j.email) = lower(a.email) and j.purged_at is null and j.id <> a.id order by j.created_at desc limit 1; end if;
      perform app.ai_interview_send(x);
    end if;
  end if;
  select * into iv from ai_interviews where application_id = x.id;
  return jsonb_build_object('ok', true, 'application_id', x.id, 'interview_state', iv.state,
    'interview_url', case when iv.state in ('sent', 'started') then app.hiring_url('/careers/interview/' || x.token) end, 'expires_at', iv.expires_at);
end $$;

-- ================================================================ 2. the one-time re-send
create table if not exists hiring_resends (
  id             uuid primary key default gen_random_uuid(),
  application_id uuid not null references job_applications (id) on delete cascade,
  kind           text not null check (kind in ('sales_referral', 'ai_interview', 'reconsider')),
  email          text not null,
  due_at         timestamptz not null,
  sent_at        timestamptz,
  result         text,
  created_at     timestamptz not null default now(),
  unique (application_id, kind)
);
create unique index if not exists hiring_resends_email_once on hiring_resends (lower(email)) where kind <> 'reconsider';
comment on table hiring_resends is 'The one-time re-send of release 48 (3191): the Sales referral as one click (sales_referral), the AI interview link again (ai_interview), a Sales applicant decided again on the corrected bar (reconsider). One per email address, spaced out, sent by the hiring job.';
alter table hiring_resends enable row level security;
revoke all on hiring_resends from anon, authenticated;
grant all on hiring_resends to service_role;
create policy admin_all on hiring_resends for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_hiring_resends after insert or update or delete on hiring_resends for each row execute function app.audit_row();

alter table program_settings add column if not exists hiring_resend_per_run integer not null default 6 check (hiring_resend_per_run between 0 and 100);
comment on column program_settings.hiring_resend_per_run is 'Hiring (3191): how many re-sent referrals or interview links go out per run of the hiring job (they are also spaced 3 minutes apart).';

create function app.hiring_resends_run(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  q hiring_resends;
  a job_applications;
  n integer := 0;
  v_res text;
begin
  for q in select * from hiring_resends where sent_at is null and due_at <= p_now order by due_at limit greatest((app.settings()).hiring_resend_per_run, 0) for update skip locked loop
    select * into a from job_applications where id = q.application_id;
    v_res := null;
    begin
      if a.id is null or a.purged_at is not null or a.hired_user_id is not null then
        v_res := 'skipped: gone or hired';
      elsif q.kind = 'sales_referral' then
        if exists (select 1 from job_applications j join hiring_roles r on r.id = j.role_id where r.va_function = 'sales' and lower(j.email) = lower(a.email) and j.purged_at is null and j.id <> a.id) then
          v_res := 'skipped: already applied to Sales';
        else
          perform app.hiring_emit('applicant_referred', a, jsonb_build_object('reason_text', 'We have chosen another candidate for the role you applied for',
            'other_role_title', (app.hiring_sales_target(a)).title, 'other_role_summary', (app.hiring_sales_target(a)).summary,
            'apply_url', app.hiring_url('/careers/sales-yes/' || a.token), 'alt_role_title', '', 'alt_apply_url', ''), 'applicant_referred:r48:' || a.id);
          v_res := 'sent';
        end if;
      elsif q.kind = 'ai_interview' then
        if exists (select 1 from ai_interviews i where i.application_id = a.id and i.state in ('submitted', 'scored')) then
          v_res := 'skipped: finished';
        else
          perform app.ai_interview_send(a);
          v_res := 'sent';
        end if;
      else
        -- reconsider: the AI decides again on the corrected bar
        delete from hiring_ai_outcomes where application_id = a.id;
        delete from hiring_decisions where application_id = a.id;
        update job_applications set status = 'interviewed', decided_at = null, decided_by = null, updated_at = now() where id = a.id;
        v_res := 'reopened';
      end if;
    exception when others then
      v_res := 'failed: ' || left(sqlerrm, 200);
    end;
    update hiring_resends set sent_at = p_now, result = v_res where id = q.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- the list (once): referred with no Sales application; Sales invited and never finished; each email address once
with referred as (
  select distinct on (lower(a.email)) a.id, a.email from job_applications a
   where a.status = 'referred' and a.purged_at is null and a.hired_user_id is null and nullif(btrim(coalesce(a.email, '')), '') is not null and not app.email_is_test(a.email)
     and not exists (select 1 from job_applications j join hiring_roles r on r.id = j.role_id where r.va_function = 'sales' and lower(j.email) = lower(a.email) and j.purged_at is null)
   order by lower(a.email), a.created_at desc),
unfinished as (
  select distinct on (lower(a.email)) a.id, a.email from job_applications a join hiring_roles r on r.id = a.role_id join ai_interviews i on i.application_id = a.id
   where r.va_function = 'sales' and a.status = 'invited' and a.purged_at is null and a.hired_user_id is null and i.state in ('sent', 'started', 'expired')
     and nullif(btrim(coalesce(a.email, '')), '') is not null and not app.email_is_test(a.email)
   order by lower(a.email), a.created_at desc),
listed as (
  select id, email, 'ai_interview' kind from unfinished
  union all
  select id, email, 'sales_referral' from referred r where not exists (select 1 from unfinished u where lower(u.email) = lower(r.email)))
insert into hiring_resends (application_id, kind, email, due_at)
select id, kind, email, now() + make_interval(mins => 3 * (row_number() over (order by kind, email))::int) from listed
on conflict do nothing;

-- Sales applicants the AI declined in the last 30 days who pass on the corrected bar
insert into hiring_resends (application_id, kind, email, due_at)
select a.id, 'reconsider', a.email, now()
  from job_applications a join hiring_roles r on r.id = a.role_id join ai_interviews i on i.application_id = a.id
  join hiring_ai_outcomes o on o.application_id = a.id and o.outcome = 'decline'
 where r.va_function = 'sales' and r.staff_kind is distinct from 'field' and a.status in ('declined', 'rejected') and a.purged_at is null and a.hired_user_id is null
   and o.decided_at > now() - interval '30 days' and app.ai_interview_passes(i, a, r) and nullif(btrim(coalesce(a.email, '')), '') is not null
on conflict do nothing;

-- ================================================================ 4. academy progress and nudges
-- the Sales path of a person (remote unless they sell in person): passed and total sections
create function app.sales_academy_progress(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('path', p.code, 'passed', count(*) filter (where app.academy_passed(p_user, ps.section_id)), 'total', count(*),
           'last_activity', app.academy_last_activity(p_user))
    from (select case when coalesce(sp.sales_work_mode, 'remote') = 'in_person' then 'sales_in_person' else 'sales_remote' end code
            from staff_profiles sp where sp.user_id = p_user) p
    join academy_path_sections ps on ps.path_code = p.code
   group by p.code
$$;

create function app.academy_last_activity(p_user uuid) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select greatest((select max(e.enrolled_at) from academy_enrollments e where e.user_id = p_user),
                  (select max(t.created_at) from academy_attempts t where t.user_id = p_user),
                  (select max(v.viewed_at) from academy_lesson_views v where v.user_id = p_user),
                  (select max(o.opened_at) from academy_section_opens o where o.user_id = p_user),
                  (select sp.created_at from staff_profiles sp where sp.user_id = p_user))
$$;

-- passed every section of a Sales path (the cross-role case: they see the Sales group too)
create function app.academy_sales_passed(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from academy_paths p where p.code in ('sales_remote', 'sales_in_person')
                    and exists (select 1 from academy_path_sections ps where ps.path_code = p.code)
                    and not exists (select 1 from academy_path_sections ps where ps.path_code = p.code and not app.academy_passed(p_user, ps.section_id)))
$$;

-- counts for Admin: every active Sales staff member by academy progress
create function app.sales_academy_counts() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select jsonb_build_object('people', count(*), 'not_started', count(*) filter (where (x.p ->> 'passed')::int = 0),
           'in_progress', count(*) filter (where (x.p ->> 'passed')::int between 1 and (x.p ->> 'total')::int - 1),
           'done', count(*) filter (where (x.p ->> 'passed')::int >= (x.p ->> 'total')::int and (x.p ->> 'total')::int > 0),
           'stalled_2_days', count(*) filter (where (x.p ->> 'passed')::int < (x.p ->> 'total')::int and (x.p ->> 'last_activity')::timestamptz < now() - interval '2 days'))
    from (select app.sales_academy_progress(sp.user_id) p from staff_profiles sp
           where sp.is_active and 'sales' = any (sp.functions) and app.staff_is_member(sp.user_id) and not app.staff_is_test(sp.user_id)) x
$$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, enabled, wired, fixed, hint, sort)
values ('academy_nudge', 'Academy: no progress (day 1, 2 and 4)', 'Hiring', '{assigned}', 'normal', 'alerts', true, true, false,
        'To the person: a nudge on day 1, 2 and 4 with no academy progress (3191). The 5-day suspension follows.', 117)
on conflict (rule) do nothing;

create table if not exists academy_nudges (
  user_id  uuid not null references users (id) on delete cascade,
  since    timestamptz not null,
  day      integer not null check (day in (1, 2, 4)),
  sent_at  timestamptz not null default now(),
  primary key (user_id, since, day)
);
comment on table academy_nudges is 'Academy nudges sent (3191): one per person, idle stretch (since: their last academy activity) and day (1, 2, 4).';
alter table academy_nudges enable row level security;
revoke all on academy_nudges from anon, authenticated;
grant all on academy_nudges to service_role;
create policy admin_all on academy_nudges for all to authenticated using (app.is_admin()) with check (app.is_admin());
create trigger audit_academy_nudges after insert or update or delete on academy_nudges for each row execute function app.audit_row();

create function app.academy_nudges_run(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  v_day integer;
  n integer := 0;
  v_p jsonb;
begin
  for r in select sp.user_id, app.academy_last_activity(sp.user_id) as last_at, coalesce(nullif(split_part(btrim(u.full_name), ' ', 1), ''), 'there') as first_name
             from staff_profiles sp join users u on u.id = sp.user_id
            where sp.is_active and not sp.onboarding_exempt and sp.inactive_locked_at is null and app.staff_is_member(sp.user_id) and not app.staff_is_test(sp.user_id)
              and coalesce(app.staff_onboarding_state(sp.user_id) ->> 'step', 'done') = 'academy' loop
    if r.last_at is null then continue; end if;
    v_day := case when r.last_at <= p_now - interval '4 days' then 4 when r.last_at <= p_now - interval '2 days' then 2 when r.last_at <= p_now - interval '1 day' then 1 end;
    if v_day is null or exists (select 1 from academy_nudges x where x.user_id = r.user_id and x.since = r.last_at and x.day >= v_day) then continue; end if;
    insert into academy_nudges (user_id, since, day, sent_at) values (r.user_id, r.last_at, v_day, p_now) on conflict do nothing;
    v_p := app.staff_academy_count(r.user_id);
    perform app.staff_alert('academy_nudge', 'user', r.user_id, v_day || ':' || to_char(r.last_at, 'YYYYMMDDHH24MI'),
      case v_day when 4 then format('%s, your staff access locks tomorrow without academy progress', r.first_name)
                 when 2 then format('%s, two days without academy progress', r.first_name)
                 else format('%s, finish your academy to start work', r.first_name) end,
      format('%s of %s sections passed. Open the academy and pass the next section today; staff access is suspended after 5 days without using the portal.',
             coalesce(v_p ->> 'passed', '0'), coalesce(v_p ->> 'total', '?')),
      jsonb_build_object('assigned_to', r.user_id, 'path_staff', '/staff/academy'));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ================================================================ 5. WhatsApp: the Sales group for who passed the Sales path, member tags
alter table staff_profiles add column if not exists whatsapp_tag_set_at timestamptz;
comment on column staff_profiles.whatsapp_tag_set_at is 'When the person ticked "I set my member tag" ("Name - Position") in their WhatsApp groups (3191); "I joined" needs it.';

create function app.staff_position(p_functions text[]) returns text
language sql immutable as $$
  select coalesce((select string_agg(case f when 'sales' then 'Sales' when 'cs' then 'Customer Service' when 'fleet' then 'Fleet' when 'finance' then 'Finance'
                                             when 'field' then 'Field' when 'admin' then 'Admin' else initcap(f) end, ' & ' order by array_position(p_functions, f))
                     from unnest(p_functions) f), 'Staff')
$$;

create function app.staff_member_tag(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select coalesce(nullif(btrim(u.greeting_name), ''), nullif(split_part(btrim(u.full_name), ' ', 1), ''), 'Name') || ' - ' || app.staff_position(sp.functions)
    from users u join staff_profiles sp on sp.user_id = u.id where u.id = p_user
$$;

create or replace function app.staff_group_list(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', g.g, 'name', case g.g when 'sales' then 'CARMA Closers' else 'CarmaCars Team' end,
           'url', case g.g when 'sales' then (app.settings()).whatsapp_sales_group_url else (app.settings()).whatsapp_team_group_url end,
           'joined', g.g = any (sp.whatsapp_joined), 'required', g.required, 'member_tag', app.staff_member_tag(p_user),
           'tag_set', sp.whatsapp_tag_set_at is not null) order by g.g), '[]'::jsonb)
    from staff_profiles sp
    cross join lateral (select x g, true required from unnest(app.staff_required_groups(sp.functions)) x
                        union all
                        select 'sales', false where not 'sales' = any (app.staff_required_groups(sp.functions)) and app.academy_sales_passed(sp.user_id)) g
   where sp.user_id = p_user
$$;

alter function app.staff_whatsapp_confirm(uuid, jsonb) rename to staff_whatsapp_confirm_pre3191;
create function app.staff_whatsapp_confirm(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not coalesce((p ->> 'tag_set')::boolean, false) and not exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.whatsapp_tag_set_at is not null) then
    raise exception 'Set your member tag in each group first (%), then tick "I set my member tag"', coalesce(app.staff_member_tag(p_user), 'Name - Position') using errcode = '22023';
  end if;
  update staff_profiles set whatsapp_tag_set_at = coalesce(whatsapp_tag_set_at, now()) where user_id = p_user;
  -- the Sales group of a person who passed the Sales path without Sales as a role: kept as joined, never required
  if (coalesce((p ->> 'sales')::boolean, false) or coalesce(p -> 'groups', '[]'::jsonb) ? 'sales') and app.academy_sales_passed(p_user) then
    update staff_profiles set whatsapp_joined = array(select distinct x from unnest(whatsapp_joined || 'sales'::text) x order by x)
     where user_id = p_user and not 'sales' = any (whatsapp_joined) and not 'sales' = any (app.staff_required_groups(functions));
    if not exists (select 1 from staff_profiles sp where sp.user_id = p_user and not (app.staff_required_groups(sp.functions) <@ sp.whatsapp_joined)) then
      return jsonb_build_object('joined', (select to_jsonb(whatsapp_joined) from staff_profiles where user_id = p_user), 'done', true,
                                'onboarded', app.staff_fully_onboarded(p_user), 'member_tag', app.staff_member_tag(p_user));
    end if;
  end if;
  return app.staff_whatsapp_confirm_pre3191(p_user, p - 'tag_set') || jsonb_build_object('member_tag', app.staff_member_tag(p_user));
end $$;

-- the portal home's card (1064): the groups to join with the member tag, and the Sales group once the Sales path is passed
create or replace function app.staff_team_groups(p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when app.staff_is_member(p_user) and not app.academy_locked(p_user)
                   and (app.staff_agreement_signed(p_user) or exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.agreement_waived_at is not null))
              then coalesce((select jsonb_agg(g || jsonb_build_object('member_tag', app.staff_member_tag(p_user)) order by g ->> 'key')
                               from jsonb_array_elements(
                                 case when exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.team_group_joined_at is not null) then '[]'::jsonb else app.staff_groups(p_user) end
                                 || coalesce((select jsonb_build_array(jsonb_build_object('key', 'sales', 'name', 'CARMA Closers', 'url', (app.settings()).whatsapp_sales_group_url))
                                                from staff_profiles sp where sp.user_id = p_user and not 'sales' = any (sp.functions) and not 'sales' = any (sp.whatsapp_joined)
                                                 and (app.settings()).whatsapp_sales_group_url <> '' and app.academy_sales_passed(p_user)), '[]'::jsonb)) g), '[]'::jsonb)
              else '[]'::jsonb end
$$;
select pg_temp.copy_grants('app.staff_whatsapp_confirm(uuid, jsonb)'::regprocedure, 'app.staff_whatsapp_confirm_pre3191(uuid, jsonb)'::regprocedure);

-- 1060's "I joined" passes the tag on
create or replace function app.staff_team_joined(p_user uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.staff_whatsapp_confirm(p_user, jsonb_build_object('groups', to_jsonb(app.staff_required_groups((select sp.functions from staff_profiles sp where sp.user_id = p_user))
                                                                         || case when app.academy_sales_passed(p_user) then array['sales'] else '{}'::text[] end),
                                                               'tag_set', coalesce((p ->> 'tag_set')::boolean, false)));
end $$;

-- the links Admin must set
create function app.whatsapp_links_missing() returns text[]
language sql stable security definer set search_path = public, app as $$
  select array_remove(array[case when coalesce((app.settings()).whatsapp_team_group_url, '') = '' then 'whatsapp_team_group_url' end,
                            case when coalesce((app.settings()).whatsapp_sales_group_url, '') = '' then 'whatsapp_sales_group_url' end], null)
$$;

insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, procedure_no, completion_rule, description) values
  ('whatsapp_links_missing', 'admin', 'Set the WhatsApp group links: new staff cannot join', 'urgent', 'business_days', 1, 1, null,
   'Program settings whatsapp_team_group_url or whatsapp_sales_group_url is empty, so the onboarding WhatsApp step shows no link. In WhatsApp: the group > Invite via link > Reset link (keep "Add other members" for admins only and "Approve new participants" on), then paste the new links in Admin > Settings > Program (Staff onboarding).')
on conflict (task_type) do update set title = excluded.title, description = excluded.description, priority = excluded.priority;

create function app.whatsapp_links_check() returns integer
language plpgsql security definer set search_path = public, app as $$
declare v text[] := app.whatsapp_links_missing();
begin
  if cardinality(v) > 0 then
    perform app.raise_task(p_type => 'whatsapp_links_missing', p_queue => 'admin', p_priority => 'urgent',
      p_detail => 'Empty: ' || array_to_string(v, ', ') || '. In WhatsApp: the group > Invite via link > Reset link; paste it in Admin > Settings > Program (Staff onboarding).',
      p_dedupe => 'whatsapp_links_missing');
    return cardinality(v);
  end if;
  update tasks set status = 'done', completed_at = now(), completion_note = 'Both links are set'
   where dedupe_key = 'whatsapp_links_missing' and status in ('open', 'in_progress', 'waiting');
  return 0;
end $$;

-- Admin > Hiring: each person's Sales path progress beside the onboarding state
alter function app.staff_onboarding_list(uuid, jsonb) rename to staff_onboarding_list_pre3191;
create function app.staff_onboarding_list(p_by uuid, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.staff_onboarding_list_pre3191(p_by, p);
begin
  return coalesce((select jsonb_agg(x || jsonb_build_object('member_tag', app.staff_member_tag((x ->> 'user_id')::uuid), 'academy', app.staff_academy_count((x ->> 'user_id')::uuid),
                                       'sales_academy', case when x -> 'functions' ? 'sales' then app.sales_academy_progress((x ->> 'user_id')::uuid) end) order by o)
                     from jsonb_array_elements(v) with ordinality t(x, o)), '[]'::jsonb);
end $$;
select pg_temp.copy_grants('app.staff_onboarding_list(uuid, jsonb)'::regprocedure, 'app.staff_onboarding_list_pre3191(uuid, jsonb)'::regprocedure);

-- the connector's staff_onboarding_status: the counts and the links that are missing
select pg_temp.patch_fn('app.api_read(uuid, text, jsonb)'::regprocedure,
  $o$return jsonb_build_object('people', app.staff_onboarding_list(p_by, '{}'::jsonb),$o$,
  $n$return jsonb_build_object('sales_academy', app.sales_academy_counts(), 'whatsapp_links_missing', to_jsonb(app.whatsapp_links_missing()), 'people', app.staff_onboarding_list(p_by, '{}'::jsonb),$n$);

-- Admin > Hiring header
create function app.hiring_funnel_state(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  perform app.assert_admin(p_by);
  return jsonb_build_object('sales_academy', app.sales_academy_counts(), 'whatsapp_links_missing', to_jsonb(app.whatsapp_links_missing()),
    'resends', (select jsonb_build_object('waiting', count(*) filter (where sent_at is null), 'sent', count(*) filter (where result = 'sent'),
                                          'reopened', count(*) filter (where result = 'reopened'), 'skipped', count(*) filter (where result like 'skipped%'))
                  from hiring_resends));
end $$;

-- ================================================================ the hiring job: the re-send, the nudges, the links
alter function app.job_hiring(timestamptz) rename to job_hiring_pre3191;
create function app.job_hiring(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.job_hiring_pre3191(p_now);
  n_resend integer := 0;
  n_nudge integer := 0;
begin
  begin n_resend := app.hiring_resends_run(p_now); exception when others then raise warning 'hiring resends: %', sqlerrm; end;
  begin n_nudge := app.academy_nudges_run(p_now); exception when others then raise warning 'academy nudges: %', sqlerrm; end;
  begin perform app.whatsapp_links_check(); exception when others then raise warning 'whatsapp links: %', sqlerrm; end;
  return coalesce(v, '{}'::jsonb) || jsonb_build_object('resent', n_resend, 'academy_nudges', n_nudge);
end $$;
select pg_temp.copy_grants('app.job_hiring(timestamptz)'::regprocedure, 'app.job_hiring_pre3191(timestamptz)'::regprocedure);

-- ================================================================ the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3191;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call = 'admin_read' and p_name = 'hiring_funnel' then
    perform app.door_begin(p_user, p_aal);
    return app.hiring_funnel_state(p_user);
  end if;
  return app.door_pre3191(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3191(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.ai_interview_fail_reasons(ai_interviews, job_applications, hiring_roles), app.hiring_sales_target(job_applications), public.server_hiring_sales_offer(text),
  public.server_hiring_sales_yes(text), app.hiring_resends_run(timestamptz), app.sales_academy_progress(uuid), app.academy_last_activity(uuid), app.academy_sales_passed(uuid),
  app.sales_academy_counts(), app.academy_nudges_run(timestamptz), app.staff_position(text[]), app.staff_member_tag(uuid), app.staff_whatsapp_confirm_pre3191(uuid, jsonb),
  app.whatsapp_links_missing(), app.whatsapp_links_check(), app.staff_onboarding_list_pre3191(uuid, jsonb), app.hiring_funnel_state(uuid), app.job_hiring_pre3191(timestamptz),
  app.door_pre3191(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.ai_interview_fail_reasons(ai_interviews, job_applications, hiring_roles), app.hiring_sales_target(job_applications), public.server_hiring_sales_offer(text),
  public.server_hiring_sales_yes(text), app.hiring_resends_run(timestamptz), app.sales_academy_progress(uuid), app.academy_last_activity(uuid), app.academy_sales_passed(uuid),
  app.sales_academy_counts(), app.academy_nudges_run(timestamptz), app.staff_position(text[]), app.staff_member_tag(uuid), app.staff_whatsapp_confirm_pre3191(uuid, jsonb),
  app.whatsapp_links_missing(), app.whatsapp_links_check(), app.staff_onboarding_list_pre3191(uuid, jsonb), app.hiring_funnel_state(uuid), app.job_hiring_pre3191(timestamptz),
  app.door_pre3191(uuid, text, text, text, jsonb) to service_role;
