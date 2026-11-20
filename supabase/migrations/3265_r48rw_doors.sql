-- 3265_r48rw_doors.sql
-- Release 48, part RW: the doors of 3260 to 3264 (docs/changes/2026-11-20-r48-rewards-calendar-notify.md), in one
-- wrapper of app.door (staff, Admins and the app reach the database through it; the functions check who may).
--   reads   my_rewards (any staff member's own card), social_calendar and social_calendar_facts (Marketing: Admin,
--           Fleet, customer service, Sales), staff_perks, owner_rewards, notify_prefs, tracker_places (Admins)
--   actions my_rewards_code, my_rewards_code_cancel (a staff member's own free-day code); social_cal_decide,
--           social_cal_save, social_cal_put, social_stats_save (Marketing); staff_perk_set, staff_perk_adjust,
--           owner_reward_ship, owner_reward_upgrade_decide, owner_reward_credit, notify_pref_set, notify_type_save,
--           tracker_place_save, tracker_place_remove (Admins)
-- The owner portal's and every person's own notification preferences are public.server_* / owner_portal_* functions
-- (service role only), as the rest of those portals.
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

-- what the calendar writer needs (src/features/social/calendar.ts): the fleet's facts and the plan
create function app.social_cal_facts(p_by uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if not app.marketing_may(p_by) then raise exception 'Not permitted' using errcode = '42501'; end if;
  return jsonb_build_object('facts', app.ads_facts(), 'job', app.social_cal_job());
end $$;
create function app.social_cal_put(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if not app.marketing_may(p_by) then raise exception 'An Admin, Fleet, customer service or Sales writes the content calendar' using errcode = '42501'; end if;
  return jsonb_build_object('added', app.social_cal_store(p, p_by));
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre3265;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v_read boolean := p_call in ('ops_read', 'admin_read', 'va_read', 'field_read');
  v_do boolean := p_call in ('ops_do', 'admin_do', 'va_do', 'field_do');
begin
  if v_read and p_name in ('my_rewards', 'social_calendar', 'social_calendar_facts', 'staff_perks', 'owner_rewards', 'notify_prefs', 'tracker_places') then
    perform app.door_begin(p_user, p_aal);
    return case p_name
      when 'my_rewards' then app.staff_perk_state(p_user)
      when 'social_calendar' then app.social_cal_read(p_user, v)
      when 'social_calendar_facts' then app.social_cal_facts(p_user)
      when 'staff_perks' then app.staff_perks_admin(p_user, v)
      when 'owner_rewards' then app.owner_rewards_admin(p_user, v)
      when 'notify_prefs' then app.notify_prefs_admin(p_user, v)
      else app.tracker_places_read(p_user) end;
  end if;
  if v_do and p_name in ('my_rewards_code', 'my_rewards_code_cancel', 'social_cal_decide', 'social_cal_save', 'social_cal_put', 'social_stats_save', 'staff_perk_set', 'staff_perk_adjust',
                         'owner_reward_ship', 'owner_reward_upgrade_decide', 'owner_reward_credit', 'notify_pref_set', 'notify_type_save', 'tracker_place_save', 'tracker_place_remove') then
    perform app.door_begin(p_user, p_aal);
    return case
      when p_name = 'my_rewards_code' then app.staff_perk_code_issue(p_user, v)
      when p_name = 'my_rewards_code_cancel' then app.staff_perk_code_cancel(p_user, v)
      when p_name = 'social_cal_decide' then app.social_cal_decide(p_user, v)
      when p_name = 'social_cal_save' then app.social_cal_save(p_user, v)
      when p_name = 'social_cal_put' then app.social_cal_put(p_user, v)
      when p_name = 'social_stats_save' then app.social_stats_save(p_user, v, 'hand')
      when p_name in ('staff_perk_set', 'staff_perk_adjust') then app.staff_perks_admin_do(p_user, p_name, v)
      when p_name in ('owner_reward_ship', 'owner_reward_upgrade_decide', 'owner_reward_credit') then app.owner_rewards_admin_do(p_user, p_name, v)
      when p_name in ('notify_pref_set', 'notify_type_save') then app.notify_prefs_admin_do(p_user, p_name, v)
      else app.tracker_places_do(p_user, p_name, v) end;
  end if;
  return app.door_pre3265(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre3265(uuid, text, text, text, jsonb)'::regprocedure);

revoke all on function app.social_cal_facts(uuid), app.social_cal_put(uuid, jsonb), app.door_pre3265(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function app.social_cal_facts(uuid), app.social_cal_put(uuid, jsonb), app.door_pre3265(uuid, text, text, text, jsonb) to service_role;
