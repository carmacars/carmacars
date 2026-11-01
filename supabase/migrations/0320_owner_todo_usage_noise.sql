-- 0320_owner_todo_usage_noise.sql
-- What the owner hit on November 1, 2026 (docs/changes/2026-11-06-owner-todo-usage-noise.md): "To do: 380 things need
-- you", red usage banners over cents, 98 emails by noon on a Sunday and the backup bucket over 10 GB.
--
-- 1. Admin > To do counts what needs the Admin, not records. The headline added the raw number of every count line to the
--    number of prompts: each unfinished form's follow-up (one task per visitor who typed a name and left, open until
--    the person sends the form, up to 24 months) counted twice (its prompt and the "Unfinished requests" line), every
--    task of customer service, sales, fleet and finance came to the Admin as a prompt of its own while no real assistant
--    held the function, and a line such as "Cars with no service record yet" added one per car.
--    Now (app.admin_todo):
--    - the follow-ups of unfinished forms are Sales' work (their queue), and close by themselves after
--      capture_followup_days (7; the person and what they typed stay on Admin > Leads);
--    - each line of the list belongs to the Admin or to a team; a team's lines and its open tasks show as one quiet line
--      per team ("Customer service has 42 open"), never in "need you";
--    - the tasks of a staff queue no longer come to the Admin as prompts (they are in the team line, unstaffed or not);
--    - "need" counts lines, not records: work of one kind that repeats is one line (the page's grouping,
--      web/src/features/admin/todo/group.ts, mirrored in app.todo_need), and a count line is one line whatever its count.
--    Every queue stays where it was: Staff tasks, Leads, Maintenance, Tolls, each linked from its line.
-- 2. Usage banners in money. A service that is never paused and billed by use (Worker CPU, requests, R2 storage, texts)
--    is red only when this month's projected cost above the allowance reaches usage_banner_red_usd (Program settings,
--    US$5); under it, a quiet note; nothing before the allowance is used up. Its alert email and text follow the same
--    rule. Hard stops (Workers AI, images, Claude) and the email holds (Resend's 100 a day) are unchanged and stay visible.
-- 3. Email: whether Cloudflare Email Service really sends (app.cf_email_setup, read on Settings > Usage and in the email
--    banner), and less internal noise: while no real assistant holds a function, its staff emails still reach the Admin,
--    but in the Admin's digest, not one email each (urgent ones, a live chat waiting, a late return, a breakdown or an
--    incident, stay immediate). Renter, owner, applicant, investor and legal emails are untouched.
-- 4. Write churn (WAL, the backup bucket): the search snapshots no longer lock and stamp every landing page every ten
--    minutes when nothing changed, and the place roots and the sitemap shape are rewritten only when they change.
-- No applied migration is edited.

create function pg_temp.copy_grants(p_new regprocedure, p_old regprocedure) returns void
language plpgsql as $$
declare g text;
begin
  execute format('revoke all on function %s from public, anon, authenticated', p_new);
  foreach g in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(g, p_old, 'execute') then execute format('grant execute on function %s to %I', p_new, g); end if;
  end loop;
end $$;

-- ================================================================ 0. settings
alter table program_settings
  add column capture_followup_days integer not null default 7 check (capture_followup_days between 1 and 90),
  add column usage_banner_red_usd numeric(10, 2) not null default 5 check (usage_banner_red_usd >= 0);
comment on column program_settings.capture_followup_days is 'Unfinished forms (0320): the Sales follow-up of a form left with a name closes by itself after this many days; the person stays on Admin > Leads.';
comment on column program_settings.usage_banner_red_usd is 'Usage (0320): a service billed by use turns the Admin banner red, and emails or texts, only when this month''s projected cost above the allowance reaches this many US dollars.';

-- ================================================================ 1. unfinished forms: Sales' follow-up, closed after a week
update task_rules set queue = 'sales' where task_type = 'capture_follow_up';

-- job_capture raises the follow-up in the Admin's queue (0090); it goes to Sales instead
create or replace function app.capture_task_to_sales() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.task_type = 'capture_follow_up' and new.queue = 'admin' then new.queue := 'sales'; end if;
  return new;
end $$;
drop trigger if exists a0_capture_task_to_sales on tasks;
create trigger a0_capture_task_to_sales before insert on tasks
  for each row when (new.task_type = 'capture_follow_up') execute function app.capture_task_to_sales();

-- the follow-ups past the window close (the capture, its lead and the person's details stay: Admin > Leads)
create or replace function app.capture_followups_expire(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare n integer;
begin
  update tasks set status = 'cancelled', completed_at = p_now,
         completion_note = format('Closed by itself after %s days: the person stays on Admin > Leads', (app.settings()).capture_followup_days)
   where task_type = 'capture_follow_up' and status in ('open', 'in_progress', 'waiting')
     and created_at < p_now - make_interval(days => (app.settings()).capture_followup_days);
  get diagnostics n = row_count;
  return n;
end $$;

alter function app.job_capture(timestamptz) rename to job_capture_pre0320;
create function app.job_capture(p_now timestamptz default now()) returns text
language plpgsql security definer set search_path = public, app as $$
declare
  v text := app.job_capture_pre0320(p_now);
  n integer := app.capture_followups_expire(p_now);
begin
  return v || case when n > 0 then format(', expired %s', n) else '' end;
end $$;
select pg_temp.copy_grants('app.job_capture(timestamptz)'::regprocedure, 'app.job_capture_pre0320(timestamptz)'::regprocedure);

-- the ones open now: past the window they close, the others move to Sales
select app.capture_followups_expire();
update tasks set queue = 'sales' where task_type = 'capture_follow_up' and queue = 'admin' and status in ('open', 'in_progress', 'waiting');

-- ================================================================ 2. Admin > To do: the Admin's own work, teams on one line each
-- The team of each count line (null: the Admin's own). Keep in step with web/src/features/admin/todo/need.ts TEAM_OF.
create or replace function app.todo_team_of(p_key text) returns text
language sql immutable as $$
  select case
    when p_key in ('capture_follow_up', 'chauffeur') then 'sales'
    when p_key in ('maintenance_due', 'maintenance_unknown', 'listings', 'calendar_feeds', 'turo_emails', 'insurance') then 'fleet'
    when p_key in ('maintenance_bill', 'tolls', 'commissions_pay', 'deposits_overdue', 'payments') then 'finance'
  end
$$;

-- The headline: one per line the page shows. Prompts of one kind of work that repeats (GROUP_MIN, 3) are one line
-- unless the kind is a decision about one person, booking or owner (ALONE); a count line is one line. Mirrors
-- web/src/features/admin/todo/group.ts and need.ts.
create or replace function app.todo_need(p_prompts jsonb, p_items jsonb) returns integer
language sql immutable as $$
  with p as (
    select case when x ->> 'kind' = 'task' then 'task:' || coalesce(x ->> 'task_type', '') else x ->> 'kind' end k,
           x ->> 'kind' = any (array['chat', 'requests', 'changes', 'documents', 'applications', 'insurer', 'insurer_bulk', 'publish',
                                     'invoice_payment', 'paper', 'first_last_paid', 'terms']) alone
      from jsonb_array_elements(coalesce(p_prompts, '[]'::jsonb)) x),
  g as (select k, bool_or(alone) alone, count(*) n from p group by k)
  select (coalesce((select sum(case when not alone and n >= 3 then 1 else n end) from g), 0)
        + (select count(*) from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i
            where coalesce((i ->> 'count')::integer, 0) > 0 and i ->> 'team' is null
              and i ->> 'key' <> all (array['applications', 'requests', 'changes', 'plates', 'samples', 'first_last_decide', 'signed_copy_failed'])))::integer
$$;

alter function app.admin_todo(uuid) rename to admin_todo_pre0320;
create function app.admin_todo(p_admin uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.admin_todo_pre0320(p_admin);
  v_items jsonb;
  v_prompts jsonb;
  v_teams jsonb;
begin
  -- each count line says whose it is
  select coalesce(jsonb_agg(case when app.todo_team_of(i ->> 'key') is not null then i || jsonb_build_object('team', app.todo_team_of(i ->> 'key')) else i end order by n), '[]'::jsonb)
    into v_items from jsonb_array_elements(coalesce(v -> 'items', '[]'::jsonb)) with ordinality x(i, n);
  -- a staff queue's tasks stay in their team's line, staffed or not
  select coalesce(jsonb_agg(p order by n), '[]'::jsonb) into v_prompts
    from jsonb_array_elements(coalesce(v -> 'prompts', '[]'::jsonb)) with ordinality x(p, n)
   where not (p ->> 'kind' = 'task' and coalesce((p ->> 'from_queue')::boolean, false));
  -- one line per team: its open tasks, and its count lines
  select jsonb_agg(jsonb_build_object('key', t.key, 'label', t.label, 'href', '/admin/tasks?queue=' || t.key,
           'staffed', app.va_function_staffed(t.key),
           'open', (select count(*) from tasks k where k.queue = t.key and k.status in ('open', 'in_progress')),
           'overdue', (select count(*) from tasks k where k.queue = t.key and k.status in ('open', 'in_progress') and k.due_at < now()),
           'items', coalesce((select jsonb_agg(i order by n) from jsonb_array_elements(v_items) with ordinality y(i, n)
                               where i ->> 'team' = t.key and (i ->> 'count')::integer > 0), '[]'::jsonb)) order by t.sort)
    into v_teams
    from (values ('cs', 'Customer service', 1), ('sales', 'Sales', 2), ('fleet', 'Fleet', 3), ('finance', 'Finance', 4)) t(key, label, sort);
  return v || jsonb_build_object('items', v_items, 'prompts', v_prompts, 'teams', v_teams, 'need', app.todo_need(v_prompts, v_items));
end $$;
select pg_temp.copy_grants('app.admin_todo(uuid)'::regprocedure, 'app.admin_todo_pre0320(uuid)'::regprocedure);

-- ================================================================ 3. usage banners in money
-- This period's cost above the allowance, projected to the end of the month: a month figure by the share of the month
-- gone (at least three days, so the first morning does not multiply by thirty), a size as it stands (billed a month), a
-- day figure as if every day of the month were like today. Only for the services never paused and billed by use.
create or replace function app.usage_money(p_service text, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  st jsonb := app.usage_state(p_service, p_now);
  s usage_services;
  v_used numeric := coalesce((st ->> 'used')::numeric, 0);
  v_inc numeric := coalesce((st ->> 'included')::numeric, 0);
  v_rate numeric := (st ->> 'usd_per_unit')::numeric;
  v_m0 timestamptz := app.local_midnight(app.month_start(app.local_date(p_now)));
  v_m1 timestamptz := app.local_midnight((app.month_start(app.local_date(p_now)) + interval '1 month')::date);
  v_frac numeric;
  v_proj numeric := 0;
  v_red numeric := (app.settings()).usage_banner_red_usd;
begin
  select * into s from usage_services where service = p_service;
  if s.service is null or s.pause_mode <> 'alert' or v_rate is null or v_rate <= 0 then
    return jsonb_build_object('priced', false, 'red_usd', v_red);
  end if;
  if s.period = 'month' then
    v_frac := greatest(extract(epoch from (p_now - v_m0)) / nullif(extract(epoch from (v_m1 - v_m0)), 0), 3.0 / 30);
    v_proj := greatest(v_used / v_frac - v_inc, 0) * v_rate;
  elsif s.period = 'day' then
    v_proj := greatest(v_used - v_inc, 0) * v_rate * extract(day from (v_m1 - v_m0));
  else
    v_proj := greatest(v_used - v_inc, 0) * v_rate;
  end if;
  return jsonb_build_object('priced', true, 'projected_usd', round(v_proj, 2), 'so_far_usd', coalesce((st ->> 'overage_usd')::numeric, 0), 'red_usd', v_red,
    'tone', case when v_proj >= v_red and v_proj > 0 then 'red' when v_used > v_inc then 'note' else 'none' end);
end $$;

-- quiet: a priced service whose projected cost stays under the red line (no card, no email, no text)
create or replace function app.usage_quiet(p_service text, p_now timestamptz default now()) returns boolean
language sql stable security definer set search_path = public, app as $$
  select coalesce((m ->> 'priced')::boolean and m ->> 'tone' <> 'red', false) from app.usage_money(p_service, p_now) m
$$;

-- Cloudflare Email Service: set up and sending, refused, or never reached (no EMAIL binding on the Worker)
create or replace function app.cf_email_setup(p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  e email_provider_state;
  v_on boolean := coalesce((app.settings()).cf_email_enabled, false);
  v_state text;
begin
  select * into e from email_provider_state limit 1;
  v_state := case
    when not v_on then 'off'
    when e.cf_ok_at is not null and e.cf_ok_at > p_now - interval '1 day' and (e.cf_failed_at is null or e.cf_failed_at < e.cf_ok_at) then 'ok'
    when e.cf_error ilike '%binding%' or e.cf_ok_at is null then 'absent'
    else 'failing' end;
  return jsonb_build_object('state', v_state, 'enabled', v_on, 'ok_at', e.cf_ok_at, 'failed_at', e.cf_failed_at, 'error', e.cf_error,
    'sent_month', app.cf_emails_between(app.local_midnight(app.month_start(app.local_date(p_now))), p_now + interval '1 second'),
    'included', (app.settings()).cf_email_monthly_included);
end $$;

-- The banner (0221's) with the money: rows carry projected_usd and a tone (red, amber, note); the priced services show
-- only from the allowance used up, red from the red line; the email rows say whether Cloudflare sends.
alter function app.usage_banner(uuid, timestamptz) rename to usage_banner_pre0320;
create function app.usage_banner(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_cf jsonb := app.cf_email_setup(p_now);
begin
  return coalesce((select jsonb_agg(r order by case r ->> 'tone' when 'red' then 0 when 'amber' then 1 else 2 end, (r ->> 'share_bps')::integer desc) from (
      select b || jsonb_build_object('tone', case when (m ->> 'priced')::boolean then m ->> 'tone' when (b ->> 'level')::integer = 100 then 'red' else 'amber' end,
                                     'projected_usd', m -> 'projected_usd', 'red_usd', m -> 'red_usd')
                || case when b ->> 'service' in ('resend_day', 'resend_month') then jsonb_build_object('cf', v_cf) else '{}'::jsonb end r
        from jsonb_array_elements(app.usage_banner_pre0320(p_user, p_now)) b
        cross join lateral app.usage_money(b ->> 'service', p_now) m
       where not (m ->> 'priced')::boolean or m ->> 'tone' in ('red', 'note')) x), '[]'::jsonb);
end $$;
select pg_temp.copy_grants('app.usage_banner(uuid, timestamptz)'::regprocedure, 'app.usage_banner_pre0320(uuid, timestamptz)'::regprocedure);

-- The cards under To do: none for a priced service under the red line (the banner's quiet note says it)
alter function app.usage_cards(uuid, timestamptz) rename to usage_cards_pre0320;
create function app.usage_cards(p_user uuid, p_now timestamptz default now()) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.usage_cards_pre0320(p_user, p_now);
begin
  return v || jsonb_build_object('cards', coalesce((select jsonb_agg(c order by n) from jsonb_array_elements(v -> 'cards') with ordinality x(c, n)
                                                     where not app.usage_quiet(c ->> 'service', p_now)), '[]'::jsonb),
                                 'cf_email', app.cf_email_setup(p_now));
end $$;
select pg_temp.copy_grants('app.usage_cards(uuid, timestamptz)'::regprocedure, 'app.usage_cards_pre0320(uuid, timestamptz)'::regprocedure);

-- An alert of a priced service under the red line is kept (Settings > Usage lists it) but neither emailed nor texted.
create or replace function app.usage_alert_quiet() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare m jsonb := app.usage_money(new.service);
begin
  if (m ->> 'priced')::boolean and m ->> 'tone' <> 'red' then
    new.emailed_at := coalesce(new.emailed_at, now());
    new.email_note := coalesce(new.email_note, format('not emailed: projected about US$%s above the allowance this month, under the US$%s of Program settings',
                                                      to_char(coalesce((m ->> 'projected_usd')::numeric, 0), 'FM999990.00'), to_char((m ->> 'red_usd')::numeric, 'FM999990.00')));
    new.texted_at := coalesce(new.texted_at, now());
    new.text_note := coalesce(new.text_note, 'not texted: under the red line of Program settings');
  end if;
  return new;
end $$;
drop trigger if exists a0_usage_alert_quiet on usage_alerts;
create trigger a0_usage_alert_quiet before insert on usage_alerts for each row execute function app.usage_alert_quiet();

-- Settings > Usage and the banner read the email setup
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre0320;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_read', 'admin_read') and p_name = 'usage_email_setup' then
    perform app.door_begin(p_user, p_aal);
    perform app.assert_admin(p_user);
    return app.cf_email_setup();
  end if;
  return app.door_pre0320(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre0320(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 4. staff emails while nobody real holds a function: the digest
-- 0078 sends a customer service, sales, finance or fleet email to the Admins too while no real assistant holds the
-- function, and immediately when the assistant would have had it immediately: on a new business that is every staff
-- email, one by one. The Admins now get those in their digest; a few that cannot wait stay immediate.
create or replace function app.staff_fallback_urgent(p_code text) returns boolean
language sql immutable as $$
  select p_code in ('staff_chat_waiting', 'staff_late_return_alert', 'staff_breakdown_reported', 'staff_incident_reported', 'staff_dispute_opened',
                    'staff_approval_needed', 'staff_disable_approval_needed')
$$;
alter function app.notification_recipients(app_events, notification_catalogue) rename to notification_recipients_pre0320;
create function app.notification_recipients(p_event app_events, p_c notification_catalogue)
returns table (audience text, user_id uuid, email text, name text, renter_id uuid, owner_id uuid, immediate boolean)
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_admin_own boolean := p_c.audience = 'staff_admin' or 'staff_admin' = any (coalesce(p_c.also_sent_to, '{}'));
  v_own uuid[];
begin
  if v_admin_own or app.staff_fallback_urgent(p_c.code) then
    return query select * from app.notification_recipients_pre0320(p_event, p_c);
    return;
  end if;
  -- the Admins the email names itself (a refund that needs approval, an exit below the fleet minimum: before 0078's copy)
  select coalesce(array_agg(x.user_id), '{}') into v_own from app.notification_recipients_pre0078(p_event, p_c) x where x.audience = 'staff_admin' and x.user_id is not null;
  return query
    select r.audience, r.user_id, r.email, r.name, r.renter_id, r.owner_id,
           case when r.audience = 'staff_admin' and not (r.user_id = any (v_own)) then false else r.immediate end
      from app.notification_recipients_pre0320(p_event, p_c) r;
end $$;
select pg_temp.copy_grants('app.notification_recipients(app_events, notification_catalogue)'::regprocedure,
                           'app.notification_recipients_pre0320(app_events, notification_catalogue)'::regprocedure);

-- ================================================================ 5. write churn: nothing written when nothing changed
-- The landing pages' and rental terms' car snapshots (0095), every ten minutes: no row lock on every page (a lock is a
-- write to each row) and no stamp-only update when the fleet stamp is the same.
create or replace function app.seo_snapshot_refresh() returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  v_stamp text := app.seo_fleet_stamp();
  v_fleet jsonb;
  v_changed integer := 0;
  p seo_pages;
  t record;
  v_cars jsonb;
  v_snap jsonb;
  v_ix boolean;
begin
  select coalesce(jsonb_agg(r), '[]'::jsonb) into v_fleet from app.public_fleet('{}'::jsonb) r;
  for p in select * from seo_pages where is_active loop
    select coalesce(jsonb_agg(e.v order by (e.v ->> 'daily_rate_cents')::bigint nulls last), '[]'::jsonb) into v_cars
      from jsonb_array_elements(v_fleet) e(v) where app.seo_match(e.v, p.match);
    v_snap := jsonb_build_object('cars', (select coalesce(jsonb_agg(x.v order by x.n), '[]'::jsonb)
                                            from jsonb_array_elements(v_cars) with ordinality x(v, n) where x.n <= 24),
                                 'counts', app.seo_counts_of(v_cars));
    v_ix := app.seo_page_indexable(p);
    if p.cars_snapshot is distinct from v_snap or p.was_indexable is distinct from v_ix then
      if p.cars_snapshot is distinct from v_snap then v_changed := v_changed + 1; end if;
      update seo_pages set cars_snapshot = v_snap, snapshot_stamp = v_stamp, snapshot_at = now(), was_indexable = v_ix,
             cars_changed_at = case when p.cars_snapshot is null then coalesce(cars_changed_at, now()) when p.cars_snapshot is distinct from v_snap then now() else cars_changed_at end
       where slug = p.slug;
      if v_ix and (p.was_indexable is distinct from true or p.cars_snapshot is distinct from v_snap) and p.cars_snapshot is not null then
        perform app.indexnow_queue_path(app.seo_page_path(p.slug), 'landing page cars');
      end if;
    elsif p.snapshot_stamp is distinct from v_stamp then
      update seo_pages set snapshot_stamp = v_stamp, snapshot_at = now() where slug = p.slug;
    end if;
  end loop;
  if to_regclass('public.place_terms') is not null then
    for t in select slug, match, cars_snapshot, snapshot_stamp from place_terms where vertical = 'rental' and is_active loop
      select coalesce(jsonb_agg(e.v order by (e.v ->> 'daily_rate_cents')::bigint nulls last), '[]'::jsonb) into v_cars
        from jsonb_array_elements(v_fleet) e(v) where app.seo_match(e.v, t.match);
      v_snap := jsonb_build_object('cars', (select coalesce(jsonb_agg(x.v order by x.n), '[]'::jsonb) from jsonb_array_elements(v_cars) with ordinality x(v, n) where x.n <= 12),
                                   'counts', app.seo_counts_of(v_cars));
      if t.cars_snapshot is distinct from v_snap then
        update place_terms set cars_snapshot = v_snap, snapshot_stamp = v_stamp, cars_changed_at = now() where slug = t.slug;
        v_changed := v_changed + 1;
      elsif t.snapshot_stamp is distinct from v_stamp then
        update place_terms set snapshot_stamp = v_stamp where slug = t.slug;
      end if;
    end loop;
  end if;
  return v_changed;
end $$;

-- The place roots (0109), three times an hour: the stamp moves (readers check it is under an hour old), the roots are
-- rewritten only when they changed (an unchanged value is not written again).
create or replace function app.place_roots_refresh() returns void
language plpgsql security definer set search_path = public, app as $$
declare v app.place_roots_cache.roots%type;
begin
  perform set_config('statement_timeout', '120s', true);
  v := app.place_roots_live();
  insert into app.place_roots_cache (id, roots, refreshed_at) values (true, v, now())
    on conflict (id) do update set refreshed_at = excluded.refreshed_at;
  update app.place_roots_cache set roots = v where id and roots is distinct from v;
end $$;

-- The sitemap shape (0110, 0194), twice an hour: only when it changed.
create or replace function app.vehicle_sitemap_shape_refresh() returns void
language plpgsql security definer set search_path = public, app as $$
declare
  v app.vehicle_sitemap_files_cache_state.shape%type;
  w app.vehicle_sitemap_files_cache_state.shape_switches%type;
begin
  perform set_config('statement_timeout', '120s', true);
  v := app.vehicle_sitemap_shape_live(); w := app.vehicle_sitemap_switches();
  update app.vehicle_sitemap_files_cache_state set shape = v, shape_switches = w where true and (shape is distinct from v or shape_switches is distinct from w);
end $$;

-- ================================================================ privileges
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('capture_task_to_sales', 'capture_followups_expire', 'job_capture_pre0320', 'todo_team_of', 'todo_need',
              'admin_todo_pre0320', 'usage_money', 'usage_quiet', 'cf_email_setup', 'usage_banner_pre0320', 'usage_cards_pre0320', 'usage_alert_quiet',
              'door_pre0320', 'staff_fallback_urgent', 'notification_recipients_pre0320', 'seo_snapshot_refresh', 'place_roots_refresh',
              'vehicle_sitemap_shape_refresh') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
