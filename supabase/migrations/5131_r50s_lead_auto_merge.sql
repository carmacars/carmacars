-- 5131 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). The owner, Nov 27: "duplicate leads must merge
-- automatically (same phone, email or name variants), never by hand; merge history kept".
--
-- 3230 merged by itself only a new website lead into an open one of the last 14 days, by email or phone; everything else
-- (staff entries, calls, chats, expired offers, older leads, name variants) waited for someone to press Merge. Now:
--   1. The rule (app.lead_merge_target): two open leads (new, contacted or qualified, no outcome, not merged, not spam, not
--      a Turo guest record, not a sample-car enquiry: each of those is a request of its own, 5130) of the same kind of
--      customer (renter, owner, partner) are one person when they share the email, or the phone (last ten digits), or
--      their names are variants of each other (the same words in any order, or the same first and last word with a middle
--      name or not) while their contact details do not disagree (no two different emails, no two different phones) and
--      they came within 30 days of each other. Two leads marked "not the same person" stay apart (3230).
--   2. When: at the end of the transaction that made a lead or changed its name, email or phone (a constraint trigger),
--      and every hour over every open lead (app.job_lead_merge, pg_cron), so the leads already there merge too; this
--      migration runs it once. Program settings lead_auto_merge still switches it off.
--   3. The merge is 3230's app.lead_merge: the older lead is kept, its blanks filled; the other's message, form and when it
--      came stay under it (payload.merged), its calls, texts, chats, notes and To do's move to it, and it is closed as
--      merged (merged_into, merged_at). The audit log has each merge (lead_auto_merge). That is the merge history.
-- SCHEMA_MARKER is not changed. No applied migration is edited: app.lead_auto_merge (the trigger function) is replaced.
set local check_function_bodies = off;

-- The words of a name, for comparing variants: lower case, letters only, one space between words.
create function app.lead_name_words(p text) returns text[]
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(array_agg(w order by n), '{}') from regexp_split_to_table(btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z ]+', ' ', 'g')), '\s+') with ordinality t(w, n)
   where length(w) >= 2
$$;

-- Two names are variants of one name: at least two words each, and the same words in any order, or the same first and last
-- word (a middle name given once).
create function app.lead_names_match(a text, b text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select cardinality(x) >= 2 and cardinality(y) >= 2
     and ((select array_agg(w order by w) from unnest(x) w) = (select array_agg(w order by w) from unnest(y) w)
          or (x[1] = y[1] and x[cardinality(x)] = y[cardinality(y)])
          or (x[1] = y[cardinality(y)] and x[cardinality(x)] = y[1]))
    from (select app.lead_name_words(a) as x, app.lead_name_words(b) as y) s
$$;

create function app.lead_open_for_merge(l leads) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select app.lead_mergeable(l) and l.kind <> 'sample_car' and l.status in ('new', 'contacted', 'qualified') and l.sales_outcome is null
$$;

-- The open lead p_lead joins: the oldest open lead of the same person and kind of customer, older than it. Null: none.
create function app.lead_merge_target(p_lead uuid) returns uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  -- three indexed lookups (the email, the phone key, the open leads of the 30 days around it for a name), then the rules
  select o.id
    from leads l
    join leads o on o.id in (
           select x.id from leads x where l.email is not null and lower(x.email) = lower(l.email)
           union
           select x.id from leads x where length(coalesce(app.phone_key(l.phone), '')) = 10 and app.phone_key(x.phone) = app.phone_key(l.phone)
           union
           select x.id from leads x where x.status in ('new', 'contacted', 'qualified') and x.created_at between l.created_at - interval '30 days' and l.created_at + interval '30 days'
              and app.lead_names_match(x.name, l.name)
              and not (x.email is not null and l.email is not null and lower(x.email) <> lower(l.email))
              and not (app.phone_key(x.phone) is not null and app.phone_key(l.phone) is not null and app.phone_key(x.phone) <> app.phone_key(l.phone)))
   where l.id = p_lead and app.lead_open_for_merge(l)
     and o.id <> l.id and app.lead_open_for_merge(o) and app.sl_type(o) = app.sl_type(l)
     and (o.created_at, o.id) < (l.created_at, l.id)
     and not (o.id = any (l.not_duplicate_of)) and not (l.id = any (o.not_duplicate_of))
   order by o.created_at, o.id
   limit 1
$$;

-- Merges one lead into its target when there is one. Never fails the caller: a merge that cannot be done leaves the lead as
-- it is (the next hourly run tries again). Returns the kept lead's id, or null.
create function app.lead_merge_auto(p_lead uuid) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_keep uuid;
begin
  if not coalesce((app.settings()).lead_auto_merge, false) then return null; end if;
  v_keep := app.lead_merge_target(p_lead);
  if v_keep is null then return null; end if;
  begin
    return app.lead_merge(null, v_keep, p_lead);
  exception when others then
    return null;
  end;
end $$;

-- 3230's trigger function, with the rule above (any source, any age, name variants).
create or replace function app.lead_auto_merge() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.lead_merge_auto(new.id);
  return null;
end $$;
drop trigger if exists leads_zzz_auto_merge_upd on leads;
create constraint trigger leads_zzz_auto_merge_upd after update of name, email, phone on leads deferrable initially deferred
  for each row execute function app.lead_auto_merge();

-- Every open lead, newest first: each joins its oldest match. Returns how many were merged.
create function app.job_lead_merge(p_limit integer default 2000) returns integer
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  r record;
  n integer := 0;
begin
  for r in select l.id from leads l where app.lead_open_for_merge(l) order by l.created_at desc, l.id desc limit greatest(p_limit, 1) loop
    if app.lead_merge_auto(r.id) is not null then n := n + 1; end if;
  end loop;
  return n;
end $$;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise notice 'pg_cron is not available here: the lead merge job is not scheduled';
    return;
  end if;
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise warning 'pg_cron could not be created in this database (%): the lead merge job is not scheduled', sqlerrm;
    return;
  end;
  perform cron.schedule('carmacars-r50s-lead-merge', '23 * * * *', $q$select app.job_lead_merge()$q$);
end $$;

revoke all on function app.lead_name_words(text), app.lead_names_match(text, text), app.lead_open_for_merge(leads), app.lead_merge_target(uuid),
  app.lead_merge_auto(uuid), app.lead_auto_merge(), app.job_lead_merge(integer) from public, anon, authenticated;
grant execute on function app.lead_name_words(text), app.lead_names_match(text, text), app.lead_open_for_merge(leads), app.lead_merge_target(uuid),
  app.lead_merge_auto(uuid), app.lead_auto_merge(), app.job_lead_merge(integer) to service_role;

-- the leads already there
select app.job_lead_merge(100000);
