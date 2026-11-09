-- 1152_r35g_leads_open_list.sql
-- Release 35, part G (helper G), task C. The owner: "another lead was just sent to roman, why is it automatically being sent
-- to staff accounts? shouldnt it just be open for any sales person to take? and they should only be able to take like one
-- lead every 5 mins or something and if they have too many theyve taken without closing, it should limit them from taking
-- more until the leads get released back to the lead list".
--   1. No lead is given to anyone by itself. app.lead_real_assignee (0343: the Sales person with the fewest open leads, so a
--      new hire with none got every new lead) now names nobody, so its callers (0344 unfinished owner applications, 0741
--      expired offers, 0780, the test-staff fence) leave the lead unassigned; and a new lead arrives unassigned whatever path
--      inserts it (app.submit_lead picked its own Sales person), except a salesperson's own lead (assigned to the person who
--      brought or added it) or an assignment an Admin makes. Leads wait on the Sales lead list (0950) for any fully onboarded
--      salesperson to claim. An Admin's Reassign and Return lead to previous owner (1151) stay. Field jobs and the phone
--      routing are not leads and are unchanged.
--   2. Pacing: one new claim every claim_cooldown_minutes (Settings > Sales, 5 by default) per person.
--   3. The cap, per person (the owner: "3 open leads per person but it should increase as they close more leads"): 3
--      (lead_cap_base), plus 1 for every 5 leads they won in the last 30 days (lead_cap_per_wins; a won lead is a lead with
--      the outcome won credited to them, which a confirmed booking of the lead's contact also sets, 0950), up to 10
--      (lead_cap_max); all three in Settings > Sales (app.sl_cap; max_active is no longer read for the cap). A claim ends when the lead is won, lost or handled, when it is unclaimed or released, or when its window runs out
--      (back to the list, logged as expire). At the cap a claim is refused until one ends. Admins are not paced or capped,
--      and an Admin's reassign or return is not a claim of the person's own.
--   4. Once, now: a lead given by itself (assigned, and the assignee never claimed, was given it by an Admin, logged a
--      contact or set an outcome on it, and it is not their own lead) goes back to the open list, logged as a lead event
--      (release, "Auto-assigned"). Leads with real work by the assignee stay. Then 1151's rule again: anything held by a
--      person not fully onboarded goes back to the previous salesperson or the list.
-- No applied migration is edited: lead_real_assignee is replaced (same signature and grants), lead_claim, lead_reassign and
-- sales_lead_settings_read/save are patched in place, sales_leads is wrapped.
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
  if position(p_old in d) = 0 then raise exception '1152: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ settings
alter table sales_lead_settings add column if not exists claim_cooldown_minutes integer not null default 5 check (claim_cooldown_minutes between 0 and 120);
comment on column sales_lead_settings.claim_cooldown_minutes is 'Sales lead list (1152): a person claims at most one new lead every this many minutes (0: no pacing). Admins are not paced.';
alter table sales_lead_settings
  add column if not exists lead_cap_base integer not null default 3 check (lead_cap_base between 1 and 500),
  add column if not exists lead_cap_per_wins integer not null default 5 check (lead_cap_per_wins between 1 and 500),
  add column if not exists lead_cap_max integer not null default 10 check (lead_cap_max between 1 and 500);
comment on column sales_lead_settings.lead_cap_base is 'Sales lead list (1152): the open leads (live claims) every salesperson may hold.';
comment on column sales_lead_settings.lead_cap_per_wins is 'Sales lead list (1152): one more open lead for every this many leads won in the last 30 days.';
comment on column sales_lead_settings.lead_cap_max is 'Sales lead list (1152): the most open leads anyone may hold, whatever they won.';
comment on column sales_lead_settings.max_active is 'Sales lead list (0950). Since 1152 the cap of a person is app.sl_cap (lead_cap_base, lead_cap_per_wins, lead_cap_max); this column is no longer read for it.';

-- a person's cap: the base, plus one for every lead_cap_per_wins won in the last 30 days, up to lead_cap_max
create function app.sl_cap(p_user uuid, p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with s as (select * from sales_lead_settings where id),
       w as (select count(*)::integer n from leads l where l.sales_outcome = 'won' and l.sales_outcome_by = p_user
               and l.sales_outcome_at > p_now - interval '30 days' and l.sales_outcome_at <= p_now)
  select jsonb_build_object('cap', least(s.lead_cap_max, s.lead_cap_base + w.n / s.lead_cap_per_wins), 'wins', w.n,
    'base', s.lead_cap_base, 'per_wins', s.lead_cap_per_wins, 'max', s.lead_cap_max,
    'wins_to_next', case when s.lead_cap_base + w.n / s.lead_cap_per_wins >= s.lead_cap_max then null else s.lead_cap_per_wins - w.n % s.lead_cap_per_wins end)
    from s, w
$$;
create function app.sl_cap_n(p_user uuid) returns integer
language sql stable security definer set search_path = public, app as $$ select (app.sl_cap(p_user) ->> 'cap')::integer $$;

-- ================================================================ 1. nobody by itself
create or replace function app.lead_real_assignee() returns uuid
language sql stable security definer set search_path = public, app as $$ select null::uuid $$;
comment on function app.lead_real_assignee() is 'Names nobody since 1152 (it picked the Sales person with the fewest open leads): leads wait on the Sales lead list for a salesperson to claim.';

-- a new lead is unassigned, unless it is a salesperson's own (brought or added by the assignee) or an Admin's assignment
create function app.leads_open_on_insert() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.assigned_to is not null and coalesce(current_setting('app.lead_admin_move', true), '') <> 'on'
     and new.assigned_to is distinct from new.sourced_by and coalesce(new.payload ->> 'added_by', '') <> new.assigned_to::text
     and not app.user_is_admin(app.uid()) then
    new.assigned_to := null;
  end if;
  return new;
end $$;
create trigger leads_a_open_on_insert before insert on leads for each row execute function app.leads_open_on_insert();

-- ================================================================ 2 and 3. pacing and the cap, on every claim
create function app.sl_next_claim_at(p_user uuid) returns timestamptz
language sql stable security definer set search_path = public, app as $$
  select case when coalesce((app.sl_settings()).claim_cooldown_minutes, 0) = 0 then null else
    (select max(h.at) + make_interval(mins => (app.sl_settings()).claim_cooldown_minutes) from lead_claim_log h
      where h.user_id = p_user and h.by_user = p_user and h.action = 'claim') end
$$;

create function app.lead_claims_paced() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  s sales_lead_settings := app.sl_settings();
  v_next timestamptz;
  n integer;
  v_left integer;
begin
  if coalesce(current_setting('app.lead_admin_move', true), '') = 'on' or app.user_is_admin(new.claimed_by) then return new; end if;
  if TG_OP = 'UPDATE' and new.claimed_by = old.claimed_by then return new; end if;
  select count(*) into n from lead_claims x where x.claimed_by = new.claimed_by and x.expires_at > now() and x.lead_id <> new.lead_id;
  if n >= app.sl_cap_n(new.claimed_by) then
    raise exception 'You hold % leads already (the most is % for you now: win more to hold more): close one (won, lost or handled) or unclaim it first', n, app.sl_cap_n(new.claimed_by) using errcode = '23514';
  end if;
  v_next := app.sl_next_claim_at(new.claimed_by);
  if v_next is not null and v_next > now() then
    v_left := ceil(extract(epoch from v_next - now()))::integer;
    raise exception 'One new lead every % minutes: you can claim the next one in %:%', s.claim_cooldown_minutes, v_left / 60, lpad((v_left % 60)::text, 2, '0') using errcode = '55000';
  end if;
  return new;
end $$;
create trigger lead_claims_paced before insert or update of claimed_by on lead_claims for each row execute function app.lead_claims_paced();

-- an Admin's reassign is the Admin's move, not the person's own claim (1151's return sets the same switch)
select pg_temp.patch_fn('app.lead_reassign(uuid, jsonb)'::regprocedure,
  'v_win := app.sl_window(app.sl_type(l));',
  'v_win := app.sl_window(app.sl_type(l));
  perform set_config(''app.lead_admin_move'', ''on'', true);');
select pg_temp.patch_fn('app.lead_reassign(uuid, jsonb)'::regprocedure,
  'update leads set assigned_to = v_to, updated_at = now() where id = l.id;',
  'update leads set assigned_to = v_to, updated_at = now() where id = l.id;
  perform set_config(''app.lead_admin_move'', '''', true);');
select pg_temp.patch_fn('app.lead_return_do(uuid, uuid, text)'::regprocedure,
  'perform set_config(''app.lead_return'', ''on'', true);',
  'perform set_config(''app.lead_return'', ''on'', true);
  perform set_config(''app.lead_admin_move'', ''on'', true);');
select pg_temp.patch_fn('app.lead_return_do(uuid, uuid, text)'::regprocedure,
  'perform set_config(''app.lead_return'', '''', true);',
  'perform set_config(''app.lead_return'', '''', true);
  perform set_config(''app.lead_admin_move'', '''', true);');
-- the claim in lead_return_do is inserted before the switch above: set it first there too
select pg_temp.patch_fn('app.lead_return_do(uuid, uuid, text)'::regprocedure,
  'delete from lead_claims where lead_id = l.id;',
  'delete from lead_claims where lead_id = l.id;
  perform set_config(''app.lead_admin_move'', ''on'', true);');

-- lead_claim and Next lead read the person's cap (app.sl_cap) instead of the one number for everyone
select pg_temp.patch_fn('app.lead_claim(uuid, jsonb)'::regprocedure,
  'if n >= s.max_active then raise exception ''You hold % leads already (the most is %): finish or unclaim one first'', n, s.max_active',
  'if n >= app.sl_cap_n(p_by) then raise exception ''You hold % leads already (the most is % for you now: win more to hold more): close one (won, lost or handled) or unclaim it first'', n, app.sl_cap_n(p_by)');
select pg_temp.patch_fn('app.lead_next(uuid, jsonb)'::regprocedure,
  '>= (app.sl_settings()).max_active then raise;', '>= app.sl_cap_n(p_by) then raise;');

-- Settings > Sales: the pacing
select pg_temp.patch_fn('app.sales_lead_settings_read(uuid, jsonb)'::regprocedure,
  '''max_active'', s.max_active,', '''max_active'', s.max_active, ''claim_cooldown_minutes'', s.claim_cooldown_minutes, ''lead_cap_base'', s.lead_cap_base, ''lead_cap_per_wins'', s.lead_cap_per_wins, ''lead_cap_max'', s.lead_cap_max,');
select pg_temp.patch_fn('app.sales_lead_settings_save(uuid, jsonb)'::regprocedure,
  'hot_hours = coalesce(nullif(p ->> ''hot_hours'', '''')::integer, hot_hours),',
  'hot_hours = coalesce(nullif(p ->> ''hot_hours'', '''')::integer, hot_hours),
         claim_cooldown_minutes = coalesce(nullif(p ->> ''claim_cooldown_minutes'', '''')::integer, claim_cooldown_minutes),
         lead_cap_base = coalesce(nullif(p ->> ''lead_cap_base'', '''')::integer, lead_cap_base),
         lead_cap_per_wins = coalesce(nullif(p ->> ''lead_cap_per_wins'', '''')::integer, lead_cap_per_wins),
         lead_cap_max = coalesce(nullif(p ->> ''lead_cap_max'', '''')::integer, lead_cap_max),');

-- the lead list: when the person may claim next and how many they hold
alter function app.sales_leads(uuid, jsonb) rename to sales_leads_pre1152;
create function app.sales_leads(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v jsonb := app.sales_leads_pre1152(p_by, p);
  v_next timestamptz := case when app.user_is_admin(p_by) then null else app.sl_next_claim_at(p_by) end;
begin
  return v || jsonb_build_object('next_claim_at', case when v_next > now() then v_next end, 'claim_cooldown_minutes', (app.sl_settings()).claim_cooldown_minutes,
    'paced', not app.user_is_admin(p_by), 'max_active', app.sl_cap_n(p_by), 'cap', app.sl_cap(p_by));
end $$;
select pg_temp.copy_grants('app.sales_leads(uuid, jsonb)'::regprocedure, 'app.sales_leads_pre1152(uuid, jsonb)'::regprocedure);

-- the Sales dashboard: the person's own cap, and each person's on the Admin's team table
alter function app.sales_dashboard(uuid, jsonb) rename to sales_dashboard_pre1152;
create function app.sales_dashboard(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare v jsonb := app.sales_dashboard_pre1152(p_by, p);
begin
  return v || jsonb_build_object('max_active', app.sl_cap_n(p_by), 'cap', app.sl_cap(p_by),
    'team', case when jsonb_typeof(v -> 'team') = 'array' then (select coalesce(jsonb_agg(t || jsonb_build_object('cap', app.sl_cap((t ->> 'id')::uuid)) order by o), '[]'::jsonb)
                                                                 from jsonb_array_elements(v -> 'team') with ordinality x(t, o)) else v -> 'team' end);
end $$;
select pg_temp.copy_grants('app.sales_dashboard(uuid, jsonb)'::regprocedure, 'app.sales_dashboard_pre1152(uuid, jsonb)'::regprocedure);

-- ================================================================ 4. once: the leads given by themselves go back to the list
create function app.leads_unassign_auto() returns integer
language plpgsql security definer set search_path = public, app as $$
declare r record; n integer := 0;
begin
  for r in
    select l.id, l.assigned_to from leads l
     where l.assigned_to is not null and l.handled_at is null and l.status not in ('converted', 'closed', 'spam') and app.sl_listed(l)
       and l.assigned_to is distinct from l.sourced_by and coalesce(l.payload ->> 'added_by', '') <> l.assigned_to::text
       and not exists (select 1 from lead_claim_log h where h.lead_id = l.id and h.user_id = l.assigned_to and h.action in ('claim', 'reassign', 'extend', 'return'))
       and not exists (select 1 from lead_contacts c where c.lead_id = l.id and c.by_user = l.assigned_to)
       and l.sales_outcome_by is distinct from l.assigned_to
       and not exists (select 1 from lead_claims c where c.lead_id = l.id and c.claimed_by = l.assigned_to and c.expires_at > now())
  loop
    update leads set assigned_to = null, updated_at = now() where id = r.id;
    insert into lead_claim_log (lead_id, user_id, action, note) values (r.id, r.assigned_to, 'release', 'Auto-assigned: back to the open lead list');
    n := n + 1;
  end loop;
  return n;
end $$;
select app.leads_unassign_auto();
select app.leads_return_unonboarded(null, null);

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['leads_open_on_insert', 'sl_next_claim_at', 'lead_claims_paced', 'sales_leads_pre1152', 'leads_unassign_auto', 'sl_cap', 'sl_cap_n', 'sales_dashboard_pre1152'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
