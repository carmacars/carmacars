-- 2870 (release 46): an Admin shows a lead's phone to a salesperson, lead by lead.
-- Since 0970 a person working as Sales is shown customer numbers masked ("(647) •••-••00") and calls through the
-- platform (the business line, the browser call of 2790). An Admin can now unlock the full number of one lead for one
-- salesperson (the lead's owner by default, or a Sales person chosen), with an optional reason, and hide it again.
--   lead_phone_unlocks        one row per unlock: the lead, the salesperson, the number at that moment, who and when,
--                             and when, by whom and why it was hidden again
--   app.phone_unlocked_for    the one rule: this person may see this number in full (an unlock still on, for a lead
--                             whose phone is still that number). The masking of 0970 (app.mask_phone_text: every
--                             read through the door, the Sales alerts) and the caller names of 2790 (a call to the
--                             business line, a call placed in the browser) skip such a number, so the lead page, the
--                             lists, the pop-ups and anything else read from the lead show it in full to that person
--                             only. Every other number stays masked.
--   reassignment              when the lead goes to someone else (assigned_to changes, or another salesperson claims
--                             it) the unlocks of everybody else are hidden by themselves: an unlock never carries to
--                             the new person
--   ops_do lead_phone_unlock  Admin only: {lead, to?, reason?, from_ask?}; audited (audit_log lead_phone_unlock)
--   ops_do lead_phone_hide    Admin only: {lead, to?}; audited (lead_phone_hide)
--   ops_do lead_phone_ask     Sales: "Ask an Admin to show the number": one Admin To do per lead (lead_phone_ask);
--                             done by itself when an Admin shows the number
--   the lead rows (sl_row)    phone_unlocks (for an Admin: who sees it, since when, by whom, why), phone_unlocked (the
--                             viewer sees it in full by an unlock), phone_ask_open (an ask is waiting)
--   sales_lead                phone_people (for an Admin: the Sales people it can be shown to)
--   admin_read lead_phone_state  {leads: [ids]}: the same row facts for Admin lead views that list leads straight from
--                             the table (the expired offers of People > Renters > Leads)
--   the alert                 the salesperson gets a bell alert (staff alert lead_phone_shown, to them only) that opens
--                             the lead; their ask To do closes
-- The masking itself now runs once, on the outermost door: the lead's whole person (lead_context, 2411) and the other
-- reads wrapped after 0970 were returned to Sales unmasked; they are masked like every other read now.
-- No applied migration is edited: the door, sl_row and sales_lead are wrapped (_pre2870); mask_phone_text, the 0970
-- door, server_voice_ring and server_twilio_browser_call_start are patched where they mask.

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
  if position(p_old in d) = 0 then raise exception '2870: the text to change was not found in %: %', p_sig, left(p_old, 160); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the unlocks
create table if not exists lead_phone_unlocks (
  id           uuid primary key default gen_random_uuid(),
  lead_id      uuid not null references leads (id) on delete cascade,
  user_id      uuid not null references users (id) on delete cascade,
  number       text not null check (number ~ '^\+[1-9][0-9]{7,14}$'),
  reason       text check (reason is null or length(reason) <= 300),
  unlocked_by  uuid references users (id) on delete set null,
  unlocked_at  timestamptz not null default now(),
  hidden_at    timestamptz,
  hidden_by    uuid references users (id) on delete set null,
  hidden_why   text check (hidden_why is null or hidden_why in ('admin', 'reassigned'))
);
create unique index if not exists lead_phone_unlocks_one_on on lead_phone_unlocks (lead_id, user_id) where hidden_at is null;
create index if not exists lead_phone_unlocks_user_on on lead_phone_unlocks (user_id, number) where hidden_at is null;
comment on table lead_phone_unlocks is 'r46 (2870): an Admin showed a lead''s phone to one salesperson (numbers are masked for Sales, 0970). On while hidden_at is null and the lead''s phone is still that number; hidden by an Admin or by itself when the lead goes to someone else. Never read by a browser.';
alter table lead_phone_unlocks enable row level security;
create policy admin_all on lead_phone_unlocks for select to authenticated using (app.is_admin());
revoke all on lead_phone_unlocks from anon, authenticated;
grant all on lead_phone_unlocks to service_role;
create trigger audit_lead_phone_unlocks after insert or update or delete on lead_phone_unlocks for each row execute function app.audit_row();

-- the one rule: this person sees this number in full
create function app.phone_unlocked_for(p_user uuid, p_number text) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and p_number is not null and exists (
    select 1 from lead_phone_unlocks u join leads l on l.id = u.lead_id
     where u.user_id = p_user and u.hidden_at is null and u.number = app.phone_e164(p_number) and app.phone_e164(l.phone) = u.number)
$$;

-- the masking of 0970 skips such a number (every read through the door, and the Sales alerts)
select pg_temp.patch_fn('app.mask_phone_text(uuid, text, text)'::regprocedure,
  'continue when v_n is null or v_n is not distinct from p_keep;',
  'continue when v_n is null or v_n is not distinct from p_keep or app.phone_unlocked_for(p_user, v_n);  -- 2870: shown by an Admin');
-- the caller's name on a call to the business line, and the person called from the browser (2790)
select pg_temp.patch_fn('app.server_voice_ring(jsonb)'::regprocedure,
  'when app.user_sales_only(v.user_id) then app.phone_mask_display(v_from)',
  'when app.user_sales_only(v.user_id) and not app.phone_unlocked_for(v.user_id, v_from) then app.phone_mask_display(v_from)');
select pg_temp.patch_fn('app.server_twilio_browser_call_start(jsonb)'::regprocedure,
  'case when app.user_sales_only(v_user) then app.phone_mask_display(v_to)',
  'case when app.user_sales_only(v_user) and not app.phone_unlocked_for(v_user, v_to) then app.phone_mask_display(v_to)');

-- ================================================================ 2. show, hide, ask
insert into task_rules (task_type, queue, title, priority, due_kind, due_amount, description) values
  ('lead_phone_ask', 'admin', 'A salesperson asks to see a lead''s phone', 'normal', 'none', null,
   'A salesperson pressed Ask an Admin to show the number on a lead (2870). Open the lead and press Show the phone, or leave it hidden. Done by itself when the phone is shown to them.')
on conflict (task_type) do nothing;

insert into staff_alert_rules (rule, label, grp, who, tier, topic, wired, fixed, hint, sort) values
  ('lead_phone_shown', 'An Admin showed you a lead''s phone number', 'Sales', '{assigned}', 'normal', 'leads', true, false,
   'To the salesperson only (2870): an Admin pressed Show the phone on a lead; the alert opens the lead.', 118)
on conflict (rule) do nothing;

-- a person the number is masked for: works in Sales, not an Admin, active
create function app.lead_phone_target_ok(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and exists (select 1 from users u where u.id = p_user and u.status = 'active')
     and app.user_va_has(p_user, 'sales') and not coalesce(app.user_is_admin(p_user), false)
$$;

-- p: {lead, to?, reason?, from_ask?}. To: the person chosen, else (from_ask) the salesperson who asked, else the lead's
-- assigned salesperson, else the person holding its claim.
create function app.lead_phone_unlock(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_to uuid := nullif(p ->> 'to', '')::uuid;
  v_n text;
  v_reason text := nullif(left(btrim(coalesce(p ->> 'reason', '')), 300), '');
  u lead_phone_unlocks;
  v_new boolean := false;
begin
  if p_by is null or not coalesce(app.user_is_admin(p_by), false) then
    raise exception 'Only an Admin shows a lead''s phone to a salesperson' using errcode = '42501';
  end if;
  select * into l from leads where id = nullif(p ->> 'lead', '')::uuid for update;
  if l.id is null then raise exception 'Lead not found' using errcode = 'P0002'; end if;
  if v_to is null and coalesce((p ->> 'from_ask')::boolean, false) then
    select t.created_by into v_to from tasks t
     where t.task_type = 'lead_phone_ask' and t.related_table = 'leads' and t.related_id = l.id and t.status in ('open', 'in_progress', 'waiting')
     order by t.created_at desc limit 1;
  end if;
  v_to := coalesce(v_to, l.assigned_to, (select c.claimed_by from lead_claims c where c.lead_id = l.id and c.expires_at > now()));
  if v_to is null then raise exception 'Nobody has this lead yet: choose the salesperson to show the phone to' using errcode = '22023'; end if;
  if not app.lead_phone_target_ok(v_to) then
    raise exception 'Choose a person who works in Sales: everyone else sees phone numbers in full already' using errcode = '22023';
  end if;
  v_n := app.phone_e164(l.phone);
  if v_n is null then raise exception 'This lead has no phone number to show' using errcode = '22023'; end if;
  select * into u from lead_phone_unlocks x where x.lead_id = l.id and x.user_id = v_to and x.hidden_at is null;
  if u.id is not null and u.number <> v_n then
    update lead_phone_unlocks set hidden_at = now(), hidden_by = p_by, hidden_why = 'admin' where id = u.id;
    u := null;
  end if;
  if u.id is null then
    insert into lead_phone_unlocks (lead_id, user_id, number, reason, unlocked_by) values (l.id, v_to, v_n, v_reason, p_by) returning * into u;
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    values (p_by, 'lead_phone_unlock', 'leads', l.id::text, jsonb_build_object('to', v_to, 'reason', v_reason, 'unlock', u.id));
    v_new := true;
    -- the salesperson is told, and the alert opens the lead (never the number itself)
    begin
      perform app.staff_alert('lead_phone_shown', 'lead', l.id, v_to::text || ':' || u.id::text,
        left(format('Phone shown to you: %s', coalesce(nullif(btrim(l.name), ''), 'a lead')), 140),
        'An Admin showed you the full phone number of this lead, for this lead only. Open the lead to call or copy it.',
        jsonb_build_object('assigned_to', v_to, 'path_staff', '/staff/sales-leads/' || l.id, 'path_admin', '/admin/sales-leads/' || l.id));
    exception when others then
      raise warning 'lead phone alert not made: %', sqlerrm;
    end;
  end if;
  update tasks set status = 'done', completed_at = now(), completed_by = p_by, completion_note = 'The phone was shown to ' || app.sl_name(v_to)
   where task_type = 'lead_phone_ask' and related_table = 'leads' and related_id = l.id and status in ('open', 'in_progress', 'waiting');
  return jsonb_build_object('ok', true, 'lead', l.id, 'to', v_to, 'name', app.sl_name(v_to), 'already', not v_new);
end $$;

-- p: {lead, to?}. Hides the number again (for that person, or for everybody it is shown to).
create function app.lead_phone_hide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_lead uuid := nullif(p ->> 'lead', '')::uuid;
  v_to uuid := nullif(p ->> 'to', '')::uuid;
  n integer;
begin
  if p_by is null or not coalesce(app.user_is_admin(p_by), false) then
    raise exception 'Only an Admin hides a lead''s phone again' using errcode = '42501';
  end if;
  with h as (
    update lead_phone_unlocks set hidden_at = now(), hidden_by = p_by, hidden_why = 'admin'
     where lead_id = v_lead and hidden_at is null and (v_to is null or user_id = v_to)
    returning id, user_id
  ), a as (
    insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
    select p_by, 'lead_phone_hide', 'leads', v_lead::text, jsonb_build_object('to', h.user_id, 'unlock', h.id, 'why', 'admin') from h
    returning 1
  )
  select count(*) into n from a;
  if n = 0 then raise exception 'The phone of this lead is not shown to anyone' using errcode = 'P0002'; end if;
  return jsonb_build_object('ok', true, 'lead', v_lead, 'hidden', n);
end $$;

-- p: {lead, note?}. A salesperson asks an Admin to show the number: one Admin To do per lead.
create function app.lead_phone_ask(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  l leads;
  v_note text := nullif(left(btrim(coalesce(p ->> 'note', '')), 300), '');
  v_open uuid;
  v_task uuid;
begin
  if not app.lead_phone_target_ok(p_by) then raise exception 'Only Sales asks for a lead''s number: you see it in full already' using errcode = '42501'; end if;
  l := app.sl_lead_for(p_by, nullif(p ->> 'lead', '')::uuid);
  if app.phone_e164(l.phone) is null then raise exception 'This lead has no phone number' using errcode = '22023'; end if;
  if app.phone_unlocked_for(p_by, l.phone) then return jsonb_build_object('ok', true, 'lead', l.id, 'unlocked', true); end if;
  select t.id into v_open from tasks t
   where t.task_type = 'lead_phone_ask' and t.related_table = 'leads' and t.related_id = l.id and t.status in ('open', 'in_progress', 'waiting') limit 1;
  if v_open is not null then return jsonb_build_object('ok', true, 'lead', l.id, 'asked', true, 'already', true); end if;
  v_task := app.raise_task(p_type => 'lead_phone_ask', p_queue => 'admin', p_priority => 'normal',
    p_title => left(format('Show a lead''s phone to %s: %s', app.sl_name(p_by), coalesce(nullif(btrim(l.name), ''), 'lead with no name')), 200),
    p_detail => format('%s asks to see the full phone number of this lead.%s Open the lead and press Show the phone, or leave it hidden.',
      app.sl_name(p_by), coalesce(' Why: ' || v_note || '.', '')),
    p_related_table => 'leads', p_related_id => l.id, p_dedupe => 'lead-phone-ask:' || l.id, p_created_by => p_by);
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (p_by, 'lead_phone_ask', 'leads', l.id::text, jsonb_build_object('task', v_task, 'note', v_note));
  return jsonb_build_object('ok', true, 'lead', l.id, 'asked', true, 'already', false);
end $$;

-- p: {leads: [ids]}. For an Admin's lead views that list leads from the table: each lead's owner, claim and phone facts.
create function app.lead_phone_state(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
begin
  if p_by is null or not coalesce(app.user_is_admin(p_by), false) then raise exception 'Only an Admin may do this' using errcode = '42501'; end if;
  return coalesce((select jsonb_object_agg(l.id, app.sl_row(l, p_by)) from leads l
    where l.id in (select x::uuid from jsonb_array_elements_text(coalesce(p -> 'leads', '[]'::jsonb)) x where x ~* '^[0-9a-f-]{36}$' limit 200)), '{}'::jsonb);
end $$;

-- ================================================================ 3. reassignment hides it
create function app.lead_phone_unlocks_follow() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_keep uuid;
  v_lead uuid;
begin
  if tg_table_name = 'leads' then
    if new.assigned_to is not distinct from old.assigned_to then return null; end if;
    v_keep := new.assigned_to;
    v_lead := new.id;
  else
    -- a claim by another salesperson (customer service's call hold and an Admin's claim leave it)
    if not app.lead_phone_target_ok(new.claimed_by) then return null; end if;
    v_keep := new.claimed_by;
    v_lead := new.lead_id;
  end if;
  with h as (
    update lead_phone_unlocks set hidden_at = now(), hidden_why = 'reassigned'
     where lead_id = v_lead and hidden_at is null and user_id is distinct from v_keep
    returning id, lead_id, user_id
  )
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  select app.uid(), 'lead_phone_hide', 'leads', h.lead_id::text, jsonb_build_object('to', h.user_id, 'unlock', h.id, 'why', 'reassigned') from h;
  return null;
end $$;
drop trigger if exists leads_z_phone_unlocks on leads;
create trigger leads_z_phone_unlocks after update of assigned_to on leads for each row execute function app.lead_phone_unlocks_follow();
drop trigger if exists lead_claims_z_phone_unlocks on lead_claims;
create trigger lead_claims_z_phone_unlocks after insert on lead_claims for each row execute function app.lead_phone_unlocks_follow();

-- ================================================================ 4. what the lead rows say
alter function app.sl_row(leads, uuid) rename to sl_row_pre2870;
create function app.sl_row(l leads, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.sl_row_pre2870(l, p_by) || jsonb_build_object(
    'phone_unlocks', case when coalesce(app.user_is_admin(p_by), false) then coalesce((
        select jsonb_agg(jsonb_build_object('to', u.user_id, 'name', app.sl_name(u.user_id), 'at', u.unlocked_at, 'by', app.sl_name(u.unlocked_by), 'reason', u.reason) order by u.unlocked_at)
          from lead_phone_unlocks u where u.lead_id = l.id and u.hidden_at is null), '[]'::jsonb) else '[]'::jsonb end,
    'phone_unlocked', exists (select 1 from lead_phone_unlocks u where u.lead_id = l.id and u.user_id = p_by and u.hidden_at is null and u.number = app.phone_e164(l.phone)),
    'phone_ask_open', exists (select 1 from tasks t where t.task_type = 'lead_phone_ask' and t.related_table = 'leads' and t.related_id = l.id and t.status in ('open', 'in_progress', 'waiting')))
$$;
select pg_temp.copy_grants('app.sl_row(leads, uuid)'::regprocedure, 'app.sl_row_pre2870(leads, uuid)'::regprocedure);

alter function app.sales_lead(uuid, jsonb) rename to sales_lead_pre2870;
create function app.sales_lead(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare v jsonb := app.sales_lead_pre2870(p_by, p);
begin
  return v || jsonb_build_object('phone_people', case when coalesce(app.user_is_admin(p_by), false) then coalesce((
    select jsonb_agg(jsonb_build_object('id', u.id, 'name', app.sl_name(u.id)) order by app.sl_name(u.id))
      from users u where u.status = 'active' and not app.staff_is_test(u.id) and app.lead_phone_target_ok(u.id)), '[]'::jsonb) else '[]'::jsonb end);
end $$;
select pg_temp.copy_grants('app.sales_lead(uuid, jsonb)'::regprocedure, 'app.sales_lead_pre2870(uuid, jsonb)'::regprocedure);

-- ================================================================ 5. the door: the actions, and the masking once, outermost
do $$
declare f regprocedure;
begin
  select p.oid::regprocedure into f from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'app' and p.proname like 'door\_pre%' and p.prosrc like '%Sales sees customer numbers masked (0970)%';
  if f is null then raise exception '2870: the masking door of 0970 was not found'; end if;
  perform pg_temp.patch_fn(f,
    $o$if p_call in ('va_read', 'va_list', 'ops_read') and app.viewer_masks_phones(p_user) then$o$,
    $n$if p_call in ('va_read', 'va_list', 'ops_read') and app.viewer_masks_phones(p_user) and coalesce(current_setting('app.mask_outer', true), '') <> 'on' then$n$);
end $$;

alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2870;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  p_ jsonb := coalesce(p, '{}'::jsonb) - '_va';
  v jsonb;
begin
  if p_call in ('ops_do', 'admin_do', 'va_do') and p_name in ('lead_phone_unlock', 'lead_phone_hide', 'lead_phone_ask') then
    if coalesce(p, '{}'::jsonb) ? '_va' then perform set_config('app.va_active', coalesce(p ->> '_va', ''), true); end if;
    perform app.door_begin(p_user, p_aal);
    return case p_name when 'lead_phone_unlock' then app.lead_phone_unlock(p_user, p_)
                       when 'lead_phone_hide' then app.lead_phone_hide(p_user, p_)
                       else app.lead_phone_ask(p_user, p_) end;
  end if;
  if p_call in ('admin_read', 'ops_read') and p_name = 'lead_phone_state' then
    perform app.door_begin(p_user, p_aal);
    return app.lead_phone_state(p_user, p_);
  end if;
  if p_call in ('va_read', 'va_list', 'ops_read') then
    -- Sales sees customer numbers masked (0970), on every read, whichever wrapper answers it
    perform set_config('app.mask_outer', 'on', true);
    v := app.door_pre2870(p_user, p_aal, p_call, p_name, p);
    perform set_config('app.mask_outer', '', true);
    if app.viewer_masks_phones(p_user) then return app.mask_phones_in(p_user, v, app.phone_our_number()); end if;
    return v;
  end if;
  return app.door_pre2870(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2870(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ 6. privileges
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'app' and p.proname = any (array['phone_unlocked_for', 'lead_phone_target_ok', 'lead_phone_unlock', 'lead_phone_hide', 'lead_phone_ask',
             'lead_phone_state', 'lead_phone_unlocks_follow', 'sl_row_pre2870', 'sales_lead_pre2870', 'door_pre2870'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
