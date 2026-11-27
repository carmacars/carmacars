-- 5131 (R50 hotfix 2, Sales; docs/changes/2026-11-27-r50-sales-fixes.md). The owner, Nov 27: "duplicate leads must merge
-- automatically (same phone, email or name variants), never by hand; merge history kept", and no live work is lost.
--
-- 3230 merged by itself only a new website lead into an open one of the last 14 days, by email or phone; everything else
-- waited for someone to press Merge. Now:
--   1. The match (app.lead_merge_target): two open leads (new, contacted or qualified, no outcome, not merged, not spam, not
--      a Turo guest record, not a sample-car enquiry, 5130) of the same kind of customer (renter, owner, partner) are one
--      person when
--        - they share the email or the phone (last ten digits) AND their names fit (the same last name, or the same first
--          initial, or one of the two has no name), or
--        - their names are variants of each other (the same words in any order, or the same first and last word with a
--          middle name or not), their contacts do not disagree, they came within 30 days of each other, AND they share
--          the city or the car asked about. A name alone stays a suggestion on the lead page.
--      Two leads marked "not the same person" stay apart (3230).
--   2. Live work is never lost (app.lead_merge_auto): a lead has live work when it has a live claim or hold, a logged
--      contact, an assigned salesperson, a pipeline stage past New, a lead generator or a first contact. The lead with live
--      work is kept and the other folds into it (else the older one is kept). When both have live work they are not
--      merged: the lead page offers the merge. When the kept lead was already handled, the new enquiry reopens it (New
--      unless it was Contacted or Qualified), with the same salesperson, who is told (lead_reopened).
--   3. The merge (app.lead_merge, replaced): 3230's, and it also carries the lead generator, the first contact, the
--      pipeline stage, the assigned salesperson and who sourced it, never blanking them; a live claim or hold moves to the
--      kept lead with its holder, and two live ones held by different people stop the merge; the lead generator's credit
--      moves too. The audit log has each merge (lead_auto_merge).
--   4. When: at the end of the transaction that made a lead or changed its name, email or phone (a constraint trigger),
--      and every hour (app.job_lead_merge, pg_cron) over the open leads, so the leads already there merge too.
--      Program settings lead_auto_merge still switches it off.
-- SCHEMA_MARKER is not changed. No applied migration is edited: app.lead_merge and app.lead_auto_merge are replaced.
set local check_function_bodies = off;

-- The words of a name, for comparing variants: lower case, letters and digits only ("Lead 1" and "Lead 2" differ), one space between words.
create or replace function app.lead_name_words(p text) returns text[]
language sql immutable set search_path = public, app, pg_temp as $$
  select coalesce(array_agg(w order by n), '{}') from regexp_split_to_table(btrim(regexp_replace(lower(coalesce(p, '')), '[^a-z0-9 ]+', ' ', 'g')), '\s+') with ordinality t(w, n)
   where length(w) >= 2 or w ~ '^[0-9]+$'
$$;

-- Two names are variants of one name: at least two words each, and the same words in any order, or the same first and last
-- word (a middle name given once).
create or replace function app.lead_names_match(a text, b text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select cardinality(x) >= 2 and cardinality(y) >= 2
     and ((select array_agg(w order by w) from unnest(x) w) = (select array_agg(w order by w) from unnest(y) w)
          or (x[1] = y[1] and x[cardinality(x)] = y[cardinality(y)])
          or (x[1] = y[cardinality(y)] and x[cardinality(x)] = y[1]))
    from (select app.lead_name_words(a) as x, app.lead_name_words(b) as y) s
$$;

-- Index keys for the name rule (so a lead's name variants are found by an index, not by reading every open lead): the
-- first and last word in alphabetical order, and all the words in alphabetical order. Names that match share one of them.
create or replace function app.lead_name_fl(p text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when cardinality(w) >= 2 then least(w[1], w[cardinality(w)]) || ' ' || greatest(w[1], w[cardinality(w)]) end
    from (select app.lead_name_words(p) as w) s
$$;
create or replace function app.lead_name_sorted(p text) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select case when cardinality(w) >= 2 then (select string_agg(x, ' ' order by x) from unnest(w) x) end
    from (select app.lead_name_words(p) as w) s
$$;
create index if not exists leads_open_name_fl_idx on leads (app.lead_name_fl(name)) where status in ('new', 'contacted', 'qualified');
create index if not exists leads_open_name_sorted_idx on leads (app.lead_name_sorted(name)) where status in ('new', 'contacted', 'qualified');

create or replace function app.lead_open_for_merge(l leads) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select app.lead_mergeable(l) and l.kind <> 'sample_car' and l.status in ('new', 'contacted', 'qualified') and l.sales_outcome is null
$$;


-- Names that can be one person when the email or phone is the same: one of them has no name, or the same last name, or the
-- same first initial.
create or replace function app.lead_names_fit(a text, b text) returns boolean
language sql immutable set search_path = public, app, pg_temp as $$
  select cardinality(x) = 0 or cardinality(y) = 0 or x[cardinality(x)] = y[cardinality(y)] or left(x[1], 1) = left(y[1], 1)
    from (select app.lead_name_words(a) as x, app.lead_name_words(b) as y) s
$$;

-- The city and the car a lead asks about (lower case; null when not given).
create or replace function app.lead_city(l leads) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select nullif(lower(btrim(coalesce(l.payload ->> 'city', ''))), '')
$$;
create or replace function app.lead_car(l leads) returns text
language sql immutable set search_path = public, app, pg_temp as $$
  select nullif(lower(btrim(coalesce(l.vehicle_text, l.payload ->> 'vehicle', l.payload ->> 'car', ''))), '')
$$;

-- Live work on a lead: a live claim or hold, a logged contact, an assigned salesperson, a stage past New, a lead generator,
-- a first contact.
create or replace function app.lead_has_work(l leads) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select l.assigned_to is not null or l.generated_by is not null or l.first_contact_at is not null
      or coalesce(l.pipeline_stage, 'new') <> 'new'
      or exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now())
      or exists (select 1 from lead_holds h where h.lead_id = l.id and h.expires_at > now())
      or exists (select 1 from lead_contacts c where c.lead_id = l.id)
$$;

-- The open lead p_lead is one person with: the oldest such lead, older than it. Null: none.
create or replace function app.lead_merge_target(p_lead uuid) returns uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  -- four indexed lookups (the email, the phone key, the two name keys of the open leads), then the rules
  select o.id
    from leads l
    cross join lateral (
           select x.id from leads x where l.email is not null and lower(x.email) = lower(l.email) and app.lead_names_fit(x.name, l.name)
           union
           select x.id from leads x where length(coalesce(app.phone_key(l.phone), '')) = 10 and x.phone is not null and app.phone_key(x.phone) = app.phone_key(l.phone)
              and app.lead_names_fit(x.name, l.name)
           union
           select x.id from leads x where x.status in ('new', 'contacted', 'qualified') and app.lead_name_fl(x.name) = app.lead_name_fl(l.name)
              and x.created_at between l.created_at - interval '30 days' and l.created_at + interval '30 days'
              and app.lead_names_match(x.name, l.name)
              and ((app.lead_city(x) is not null and app.lead_city(x) = app.lead_city(l)) or (app.lead_car(x) is not null and app.lead_car(x) = app.lead_car(l)))
              and not (x.email is not null and l.email is not null and lower(x.email) <> lower(l.email))
              and not (app.phone_key(x.phone) is not null and app.phone_key(l.phone) is not null and app.phone_key(x.phone) <> app.phone_key(l.phone))
           union
           select x.id from leads x where x.status in ('new', 'contacted', 'qualified') and app.lead_name_sorted(x.name) = app.lead_name_sorted(l.name)
              and x.created_at between l.created_at - interval '30 days' and l.created_at + interval '30 days'
              and app.lead_names_match(x.name, l.name)
              and ((app.lead_city(x) is not null and app.lead_city(x) = app.lead_city(l)) or (app.lead_car(x) is not null and app.lead_car(x) = app.lead_car(l)))
              and not (x.email is not null and l.email is not null and lower(x.email) <> lower(l.email))
              and not (app.phone_key(x.phone) is not null and app.phone_key(l.phone) is not null and app.phone_key(x.phone) <> app.phone_key(l.phone))) c
    join leads o on o.id = c.id
   where l.id = p_lead and app.lead_open_for_merge(l)
     and o.id <> l.id and app.lead_open_for_merge(o) and app.sl_type(o) = app.sl_type(l)
     and (o.created_at, o.id) < (l.created_at, l.id)
     and not (o.id = any (l.not_duplicate_of)) and not (l.id = any (o.not_duplicate_of))
   order by o.created_at, o.id
   limit 1
$$;

-- 3230's merge, keeping live work: p_dup folds into p_keep. p_by is the person (null: the auto-merge rule).
create or replace function app.lead_merge(p_by uuid, p_keep uuid, p_dup uuid) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  k leads; d leads;
  v_entry jsonb;
begin
  if p_keep is null or p_dup is null or p_keep = p_dup then raise exception 'Choose two different leads to merge' using errcode = '22023'; end if;
  -- always lock in id order, so two merges of the same pair cannot wait on each other
  perform 1 from leads where id in (p_keep, p_dup) order by id for update;
  select * into k from leads where id = p_keep;
  select * into d from leads where id = p_dup;
  if k.id is null or d.id is null then raise exception 'That lead no longer exists' using errcode = '22023'; end if;
  if not app.lead_mergeable(k) or not app.lead_mergeable(d) then raise exception 'One of these leads was already merged or cannot be merged' using errcode = '22023'; end if;
  if app.sl_type(k) <> app.sl_type(d) then raise exception 'A % lead and a % lead stay apart: they are different kinds of customer', app.sl_type(k), app.sl_type(d) using errcode = '22023'; end if;
  if p_by is not null and not (app.sl_sees(p_by, k) and app.sl_sees(p_by, d)) then raise exception 'You can only merge leads you can open' using errcode = '42501'; end if;
  if d.won_booking_id is not null and k.won_booking_id is not null and d.won_booking_id <> k.won_booking_id then
    raise exception 'Both leads were won with different bookings: they stay apart' using errcode = '22023';
  end if;
  -- 5131: a live claim or hold is never dropped. Two live ones held by different people: the merge waits.
  if exists (select 1 from lead_claims a join lead_claims b on b.lead_id = d.id and b.expires_at > now()
              where a.lead_id = k.id and a.expires_at > now() and a.claimed_by <> b.claimed_by)
     or exists (select 1 from lead_holds a join lead_holds b on b.lead_id = d.id and b.expires_at > now()
                 where a.lead_id = k.id and a.expires_at > now() and a.held_by <> b.held_by) then
    raise exception 'Both leads are being worked on by different people (each has a live claim): one of them releases it first, then merge' using errcode = '23514';
  end if;

  v_entry := jsonb_strip_nulls(jsonb_build_object('id', d.id, 'received_at', d.created_at, 'source', app.sl_source(d), 'kind', d.kind, 'name', d.name, 'email', d.email, 'phone', d.phone,
    'message', d.message, 'form', nullif(d.payload - 'merged', '{}'::jsonb), 'source_url', d.source_url, 'merged_at', now(), 'merged_by', p_by, 'auto', p_by is null));
  update leads set
      name = coalesce(k.name, d.name), email = coalesce(k.email, d.email), phone = coalesce(k.phone, d.phone), message = coalesce(k.message, d.message),
      vehicle_text = coalesce(k.vehicle_text, d.vehicle_text), business_name = coalesce(k.business_name, d.business_name),
      referrer = coalesce(k.referrer, d.referrer), utm_source = coalesce(k.utm_source, d.utm_source), utm_medium = coalesce(k.utm_medium, d.utm_medium),
      utm_campaign = coalesce(k.utm_campaign, d.utm_campaign), utm_term = coalesce(k.utm_term, d.utm_term), utm_content = coalesce(k.utm_content, d.utm_content),
      owner_id = coalesce(k.owner_id, d.owner_id), won_booking_id = coalesce(k.won_booking_id, d.won_booking_id),
      consent_marketing = k.consent_marketing or d.consent_marketing,
      consent_text = case when k.consent_marketing then k.consent_text when d.consent_marketing then d.consent_text else k.consent_text end,
      consent_at = case when k.consent_marketing then k.consent_at when d.consent_marketing then d.consent_at else k.consent_at end,
      do_not_contact_at = coalesce(k.do_not_contact_at, d.do_not_contact_at),
      -- 5131: the live work of both, never blanked
      generated_by = coalesce(k.generated_by, d.generated_by),
      first_contact_at = least(k.first_contact_at, d.first_contact_at),
      pipeline_stage = case when coalesce(k.pipeline_stage, 'new') = 'new' then coalesce(d.pipeline_stage, k.pipeline_stage) else k.pipeline_stage end,
      pipeline_stage_at = case when coalesce(k.pipeline_stage, 'new') = 'new' and d.pipeline_stage is not null then d.pipeline_stage_at else k.pipeline_stage_at end,
      assigned_to = coalesce(k.assigned_to, d.assigned_to),
      sourced_by = coalesce(k.sourced_by, d.sourced_by),
      payload = k.payload || jsonb_build_object('merged', coalesce(k.payload -> 'merged', '[]'::jsonb) || (coalesce(d.payload -> 'merged', '[]'::jsonb)) || jsonb_build_array(v_entry))
                || case when k.payload ? 'city' or not d.payload ? 'city' then '{}'::jsonb else jsonb_build_object('city', d.payload -> 'city') end,
      not_duplicate_of = (select coalesce(array_agg(distinct x), '{}') from unnest(k.not_duplicate_of || d.not_duplicate_of) x where x not in (k.id, d.id))
   where id = k.id;

  -- everything said and done on the duplicate moves to the kept lead
  update lead_contacts set lead_id = k.id where lead_id = d.id;
  update lead_claim_log set lead_id = k.id where lead_id = d.id;
  update phone_threads set lead_id = k.id where lead_id = d.id;
  update phone_activity set lead_id = k.id where lead_id = d.id;
  update outbound_calls set lead_id = k.id where lead_id = d.id;
  update chat_conversations set lead_id = k.id where lead_id = d.id;
  update contact_captures set lead_id = k.id where lead_id = d.id;
  update chauffeur_requests set lead_id = k.id where lead_id = d.id;
  update game_claims set lead_id = k.id where lead_id = d.id;
  update phone_gate_contacts set lead_id = k.id where lead_id = d.id;
  update owner_applications set lead_id = k.id where lead_id = d.id;
  -- 5131: a live claim or hold moves to the kept lead with its holder (the same holder on both: the later end is kept);
  -- only an expired one is cleared
  insert into lead_claims as x (lead_id, claimed_by, claimed_at, extended_at, expires_at, cap_at)
  select k.id, c.claimed_by, c.claimed_at, c.extended_at, c.expires_at, c.cap_at from lead_claims c where c.lead_id = d.id and c.expires_at > now()
  on conflict (lead_id) do update set claimed_by = excluded.claimed_by, claimed_at = least(x.claimed_at, excluded.claimed_at), extended_at = excluded.extended_at,
         expires_at = greatest(x.expires_at, excluded.expires_at), cap_at = greatest(x.cap_at, excluded.cap_at)
   where x.claimed_by = excluded.claimed_by or x.expires_at <= now();
  insert into lead_holds as x (lead_id, held_by, role, held_at, last_call_at, expires_at, prev_claimed_by)
  select k.id, h.held_by, h.role, h.held_at, h.last_call_at, h.expires_at, h.prev_claimed_by from lead_holds h where h.lead_id = d.id and h.expires_at > now()
  on conflict (lead_id) do update set held_by = excluded.held_by, role = excluded.role, held_at = least(x.held_at, excluded.held_at), prev_claimed_by = coalesce(x.prev_claimed_by, excluded.prev_claimed_by),
         expires_at = greatest(x.expires_at, excluded.expires_at), last_call_at = greatest(x.last_call_at, excluded.last_call_at)
   where x.held_by = excluded.held_by or x.expires_at <= now();
  delete from lead_claims where lead_id = d.id;
  delete from lead_holds where lead_id = d.id;
  -- 5131: the lead generator's credit moves with the lead (a second live credit for the same person is voided, kept)
  update lead_gen_credits c set status = 'void', note = 'Merged: the kept lead already has this credit', decided_at = now()
   where c.lead_id = d.id and c.status not in ('void', 'paid')
     and exists (select 1 from lead_gen_credits o where o.lead_id = k.id and o.status <> 'void');
  update lead_gen_credits set lead_id = k.id where lead_id = d.id;
  if not exists (select 1 from contact_sources where lead_id = k.id) then update contact_sources set lead_id = k.id where lead_id = d.id; end if;
  update tasks set related_id = k.id, detail = left(concat_ws(' ', detail, '(Merged: the same person already had a lead.)'), 2000)
   where related_table = 'leads' and related_id = d.id and status not in ('done', 'cancelled');

  update leads set status = 'closed', closed_reason = 'Duplicate: merged into the lead of ' || to_char(k.created_at at time zone 'America/Toronto', 'Mon DD, YYYY'),
      merged_into = k.id, merged_at = now(), merged_by = p_by, handled_at = coalesce(handled_at, now()), handled_by = coalesce(handled_by, p_by),
      followup_stopped_at = coalesce(followup_stopped_at, now()), followup_stop_reason = coalesce(followup_stop_reason, 'merged'), assigned_to = null
   where id = d.id;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, before, after)
  values (p_by, case when p_by is null then 'lead_auto_merge' else 'lead_merge' end, 'leads', k.id::text, to_jsonb(d), jsonb_build_object('kept', k.id, 'merged', d.id, 'auto', p_by is null));
  return k.id;
end $$;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort, pref_type) values
  ('lead_reopened', 'Your handled lead wrote again', 'Sales', '{admin,assigned}', 'normal', 'leads', true, false,
   '5131: a new enquiry from the same person merged into a lead that was handled; it is New again and still yours.', 52, 'staff_system')
on conflict (rule) do nothing;

-- Merges one lead with its match, keeping live work. Never fails the caller: a merge that cannot be done leaves the lead as
-- it is (the next hourly run tries again). Returns the kept lead's id, or null (no match, or both have live work).
create or replace function app.lead_merge_auto(p_lead uuid) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare
  v_other uuid;
  l leads; o leads;
  k leads; d leads;
  v_rep uuid;
begin
  if not coalesce((app.settings()).lead_auto_merge, false) then return null; end if;
  v_other := app.lead_merge_target(p_lead);
  if v_other is null then return null; end if;
  select * into l from leads where id = p_lead;
  select * into o from leads where id = v_other;
  if app.lead_has_work(l) and app.lead_has_work(o) then return null; end if;   -- both worked: the lead page offers the merge
  if app.lead_has_work(l) then k := l; d := o; else k := o; d := l; end if;
  begin
    perform app.lead_merge(null, k.id, d.id);
  exception when others then
    return null;
  end;
  -- the kept lead was handled and the person wrote again: New again, the same salesperson, who is told
  if k.handled_at is not null then
    update leads set handled_at = null, handled_by = null, status = case when status in ('contacted', 'qualified') then status else 'new' end,
           followup_stopped_at = null, followup_stop_reason = null
     where id = k.id;
    v_rep := coalesce(k.assigned_to, (select c.claimed_by from lead_claims c where c.lead_id = k.id and c.expires_at > now()));
    insert into audit_log (action, entity_table, entity_id, after) values ('lead_reopened', 'leads', k.id::text, jsonb_build_object('by_lead', d.id, 'rep', v_rep));
    begin
      perform app.staff_alert('lead_reopened', 'lead', k.id, 'reopen:' || d.id,
        left(format('%s wrote again: the lead is New again', coalesce(nullif(btrim(k.name), ''), 'A lead you handled')), 140),
        left(coalesce(d.message, 'A new enquiry from the same person.'), 240),
        jsonb_strip_nulls(jsonb_build_object('assigned_to', v_rep, 'path_staff', '/staff/sales-leads/' || k.id, 'path_admin', '/admin/sales-leads/' || k.id)));
    exception when others then raise warning 'lead reopened alert not sent for %: %', k.id, sqlerrm;
    end;
  end if;
  return k.id;
end $$;

-- 3230's trigger function, with the rule above.
create or replace function app.lead_auto_merge() returns trigger
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.lead_merge_auto(new.id);
  return null;
end $$;
drop trigger if exists leads_zzz_auto_merge_upd on leads;
create constraint trigger leads_zzz_auto_merge_upd after update of name, email, phone on leads deferrable initially deferred
  for each row execute function app.lead_auto_merge();

-- The open leads, newest first: each joins its match. Returns how many were merged.
create or replace function app.job_lead_merge(p_limit integer default 2000) returns integer
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

-- hourly (the leads already there merge on the first runs; nothing heavy runs inside this migration)
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

revoke all on function app.lead_name_words(text), app.lead_name_fl(text), app.lead_name_sorted(text), app.lead_names_match(text, text), app.lead_names_fit(text, text),
  app.lead_city(leads), app.lead_car(leads), app.lead_has_work(leads), app.lead_open_for_merge(leads), app.lead_merge_target(uuid),
  app.lead_merge(uuid, uuid, uuid), app.lead_merge_auto(uuid), app.lead_auto_merge(), app.job_lead_merge(integer) from public, anon, authenticated;
grant execute on function app.lead_name_words(text), app.lead_name_fl(text), app.lead_name_sorted(text), app.lead_names_match(text, text), app.lead_names_fit(text, text),
  app.lead_city(leads), app.lead_car(leads), app.lead_has_work(leads), app.lead_open_for_merge(leads), app.lead_merge_target(uuid),
  app.lead_merge(uuid, uuid, uuid), app.lead_merge_auto(uuid), app.lead_auto_merge(), app.job_lead_merge(integer) to service_role;
-- the name index (leads_open_name_fl_idx and the like) is computed by whoever writes a lead (staff from the portal): its
-- plain SQL name functions, with no privileges of their own, are granted to authenticated (11_owners_forms_listings)
grant execute on function app.lead_name_words(text), app.lead_name_fl(text), app.lead_name_sorted(text) to authenticated;
