-- 2250: every office staff member sees which field staff work today (owner, Nov 11 2026). The Schedule page's "Today"
-- view (staff_schedules, 1502) gains field_today: each field person with a taken shift today (field_shift_plans, 0880),
-- by their preferred name, with their hours, phone and whether the shift is on now, coming or done. Read by every
-- office role and the Admins; the same rows show on the staff home (Today) page.
set local check_function_bodies = off;

create function app.field_on_today(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', u.id, 'name', coalesce(nullif(btrim(u.greeting_name), ''), u.full_name), 'phone', u.phone,
           'starts_at', p.first_start, 'ends_at', p.last_end, 'shifts', p.n,
           'state', case when p_now < p.first_start then 'later' when p_now >= p.last_end then 'done' else 'on' end)
         order by p.first_start, u.full_name), '[]'::jsonb)
    from (select fp.staff_id, min(fp.starts_at) first_start, max(fp.ends_at) last_end, count(*)::int n
            from field_shift_plans fp
           where fp.cancelled_at is null
             and fp.starts_at < app.local_midnight(app.local_date(p_now) + 1) and fp.ends_at > app.local_midnight(app.local_date(p_now))
           group by fp.staff_id) p
    join users u on u.id = p.staff_id
$$;
revoke all on function app.field_on_today(timestamptz) from public, anon, authenticated;

alter function app.staff_schedules_read(uuid, jsonb) rename to staff_schedules_read_pre2250;
create function app.staff_schedules_read(p_by uuid, p jsonb) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.staff_schedules_read_pre2250(p_by, p) || jsonb_build_object('field_today', app.field_on_today(now()))
$$;
revoke all on function app.staff_schedules_read(uuid, jsonb) from public, anon, authenticated;
revoke all on function app.staff_schedules_read_pre2250(uuid, jsonb) from public, anon, authenticated;
grant execute on function app.field_on_today(timestamptz) to service_role;
grant execute on function app.staff_schedules_read(uuid, jsonb) to service_role;
grant execute on function app.staff_schedules_read_pre2250(uuid, jsonb) to service_role;

-- the scheduled posts' send log (2220) holds post status: audited like every status table (03's rule)
create trigger audit_social_post_log after insert or update or delete on social_post_log for each row execute function app.audit_row();
