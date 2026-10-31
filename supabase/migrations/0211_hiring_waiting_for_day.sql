-- 0211: no interview invitation without an open call time (Release 21b, extra item). SCHEMA_MARKER 0211.
-- docs/changes/2026-11-01-hiring-waiting-for-day.md.
--   A Field staff applicant got "Let's talk, book a call" at 12:01 am and the booking page had no times: no future interview
--   day was open for the role. Now:
--   1. The invitation (applicant_invited) is sent only while the role has an open call time. Otherwise the applicant is
--      invited and waiting for a day (job_applications.waiting_for_day), and the invitation goes when an Admin adds or opens
--      a day covering the role.
--   2. The booking link with no open time says so, and records the visit (no_slots_seen_at, no_slots_since).
--   3. Admin > Hiring: per role, "N applicants invited but no interview day is open for <role>" (admin_read 'hiring', waiting).
--   4. A day added or opened: the applicants already emailed while no time was open get "New times are open"
--      (applicant_new_times); those still waiting get their invitation.
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

alter table job_applications add column if not exists waiting_for_day boolean not null default false;
alter table job_applications add column if not exists no_slots_since timestamptz;
alter table job_applications add column if not exists no_slots_seen_at timestamptz;
comment on column job_applications.waiting_for_day is 'Invited while no call time was open for the role (0211): the invitation email waits for an interview day.';
comment on column job_applications.no_slots_since is 'Invited (emailed) while no call time was open, or found none on the booking link (0211): "New times are open" goes when a day opens.';
comment on column job_applications.no_slots_seen_at is 'The last visit to the booking link that found no open call time (0211).';

-- an open call time for the role: a future slot of an active day for the role, with a place left
create function app.hiring_open_slots(p_role uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select exists (select 1 from interview_slots x join interview_days y on y.id = x.day_id
                  where y.active and (y.role_ids is null or p_role = any (y.role_ids)) and x.starts_at > now() + interval '30 minutes'
                    and (select count(*) from job_applications z where z.slot_id = x.id and z.status = 'booked') < x.capacity)
$$;

-- 1. the invitation waits for a day
alter function app.hiring_emit(text, job_applications, jsonb, text) rename to hiring_emit_pre0211;
create function app.hiring_emit(p_code text, a job_applications, p_extra jsonb default '{}'::jsonb, p_dedupe text default null) returns bigint
language plpgsql security definer set search_path = public, app as $$
begin
  if p_code = 'applicant_invited' then
    if not app.hiring_open_slots(a.role_id) then
      update job_applications set waiting_for_day = true, updated_at = now() where id = a.id;
      return null;
    end if;
    update job_applications set waiting_for_day = false, no_slots_since = null where id = a.id and (waiting_for_day or no_slots_since is not null);
  end if;
  return app.hiring_emit_pre0211(p_code, a, p_extra, p_dedupe);
end $$;
select pg_temp.copy_grants('app.hiring_emit(text, job_applications, jsonb, text)'::regprocedure, 'app.hiring_emit_pre0211(text, job_applications, jsonb, text)'::regprocedure);

-- 4. a day opens: invitations that waited go, and those emailed with no time get "New times are open"
create function app.hiring_release_waiting() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  a job_applications;
  n integer := 0;
begin
  for a in select * from job_applications j where j.status = 'invited' and j.purged_at is null and (j.waiting_for_day or j.no_slots_since is not null)
             and app.hiring_open_slots(j.role_id) for update loop
    if a.waiting_for_day then
      perform app.hiring_emit('applicant_invited', a, app.hiring_invite_vars(a), 'applicant_invited:' || a.id || ':day:' || extract(epoch from clock_timestamp())::text);
    else
      update job_applications set no_slots_since = null, updated_at = now() where id = a.id;
      perform app.hiring_emit_pre0211('applicant_new_times', a, app.hiring_invite_vars(a), 'applicant_new_times:' || a.id || ':' || extract(epoch from clock_timestamp())::text);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

alter function app.hiring_day_save(uuid, jsonb) rename to hiring_day_save_pre0211;
create function app.hiring_day_save(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.hiring_day_save_pre0211(p_by, p);
begin
  return v || jsonb_build_object('released', app.hiring_release_waiting());
end $$;
select pg_temp.copy_grants('app.hiring_day_save(uuid, jsonb)'::regprocedure, 'app.hiring_day_save_pre0211(uuid, jsonb)'::regprocedure);

-- 2. the booking link with no open time records the visit
alter function public.server_hiring_booking(text) rename to server_hiring_booking_pre0211;
create function public.server_hiring_booking(p_token text) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := public.server_hiring_booking_pre0211(p_token);
begin
  if coalesce((v ->> 'ok')::boolean, false) and v ->> 'status' = 'invited' and jsonb_array_length(coalesce(v -> 'slots', '[]'::jsonb)) = 0 then
    update job_applications set no_slots_seen_at = now(), no_slots_since = coalesce(no_slots_since, now()) where token = p_token and purged_at is null and not waiting_for_day;
    update job_applications set no_slots_seen_at = now() where token = p_token and purged_at is null and waiting_for_day;
    return v || jsonb_build_object('no_slots', true);
  end if;
  return v || jsonb_build_object('no_slots', false);
end $$;
select pg_temp.copy_grants('public.server_hiring_booking(text)'::regprocedure, 'public.server_hiring_booking_pre0211(text)'::regprocedure);
revoke all on function public.server_hiring_booking_pre0211(text) from public, anon, authenticated;

-- 3. Admin > Hiring: per role, the applicants invited with no open interview day
create function app.hiring_waiting_by_role() returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object('slug', r.slug, 'title', r.title, 'short_title', r.short_title, 'count', x.n) order by r.sort_order, r.title), '[]'::jsonb)
    from hiring_roles r
    join lateral (select count(*)::int n from job_applications j where j.role_id = r.id and j.status = 'invited' and j.purged_at is null) x on x.n > 0
   where not app.hiring_open_slots(r.id)
$$;
alter function app.hiring_read(uuid, jsonb) rename to hiring_read_pre0211;
create function app.hiring_read(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  return app.hiring_read_pre0211(p_by, p) || jsonb_build_object('waiting', app.hiring_waiting_by_role());
end $$;
select pg_temp.copy_grants('app.hiring_read(uuid, jsonb)'::regprocedure, 'app.hiring_read_pre0211(uuid, jsonb)'::regprocedure);

-- the applicants invited before this release while no time was open (the Field staff applicant of October 30) get
-- "New times are open" when a day opens
update job_applications j set no_slots_since = now() where j.status = 'invited' and j.purged_at is null and j.invited_at is not null and not app.hiring_open_slots(j.role_id);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('hiring_open_slots', 'hiring_release_waiting', 'hiring_waiting_by_role', 'hiring_emit_pre0211', 'hiring_day_save_pre0211', 'hiring_read_pre0211') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- CATALOGUE 0211 START (generated by supabase/seed/0211_gen_catalogue.mjs; do not edit by hand)
insert into notification_catalogue (code, audience, also_sent_to, category, is_digest, digest_slot, from_address, reply_to,
    subject, preheader, timing, trigger_text, replaces_template, link_path, variables, template_html, template_text) values
  ('applicant_new_times', 'applicant', '{}'::text[], 'transactional', false, null, 'CarmaCars <hello@carmacars.ca>', 'contact@carmacars.ca', 'New times are open for your CarmaCars interview call', 'Pick a time on {{call_days}}.', 'Immediate', 'An Admin adds or opens an interview day for a role (Admin > People > Hiring) and a candidate invited for that role had found no open call times on their booking link (migration 0211). One email per candidate per day added.', null, null, '[{"name":"booking_url","type":"url"},{"name":"call_days","type":"string"},{"name":"call_minutes","type":"string"},{"name":"company_address","type":"string","global":true},{"name":"contact_email","type":"string","global":true},{"name":"first_name","type":"string"},{"name":"instagram_url","type":"url","global":true},{"name":"opening_hours","type":"string","global":true},{"name":"reply_time","type":"string","global":true},{"name":"role_title","type":"string"},{"name":"support_phone","type":"string","global":true},{"name":"tiktok_url","type":"url","global":true}]'::jsonb, 'templates/applicant_new_times.html', 'templates/applicant_new_times.txt')
on conflict (code) do update set
  audience = excluded.audience, also_sent_to = excluded.also_sent_to, category = excluded.category,
  is_digest = excluded.is_digest, digest_slot = excluded.digest_slot, from_address = excluded.from_address,
  reply_to = excluded.reply_to, subject = excluded.subject, preheader = excluded.preheader, timing = excluded.timing,
  trigger_text = excluded.trigger_text, replaces_template = excluded.replaces_template, link_path = excluded.link_path,
  variables = excluded.variables, template_html = excluded.template_html, template_text = excluded.template_text,
  in_catalogue = true, updated_at = now();
select app.notification_catalogue_refresh();
-- CATALOGUE 0211 END

-- the catalogue refresh above recomputes each marketing email's consent rule: keep express consent where 0161 and 0167 set it (as 0193 does)
update notification_catalogue set consent_rule = 'express' where code in ('renter_promo_expiry_3d', 'renter_promo_expiry_1d', 'owner_recruit_outreach');
update notification_catalogue set emitted_by = 'app.hiring_release_waiting, from app.hiring_day_save (0211)' where code = 'applicant_new_times';
update notification_catalogue set emitted_by = emitted_by || '; app.hiring_release_waiting (0211: an invitation that waited for an interview day)'
 where code = 'applicant_invited' and emitted_by not like '%hiring_release_waiting%';
