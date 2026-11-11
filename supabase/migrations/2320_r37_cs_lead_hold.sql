-- 2320: a lead being worked on a phone call by customer service or fleet is held for them for a while (release 37).
-- The owner, November 11: "When customer service or fleet are handling a lead that came in through a phone call, then they
-- should be assigned that lead. But just like for sales, it should only be for a certain amount of time. This should be done
-- this way so that sales don't try to contact the lead that customer service is already working."
--   1. The hold (lead_holds, next to the Sales claims of 0950): taken when a fully onboarded customer service or fleet person
--      answers or places a call with the lead (a Quo call by their Quo user, the site's Call button), adds a note from the
--      caller pop-up or the lead, or creates the lead from a call. It lasts lead_cs_hold_minutes (Settings > Sales; empty:
--      the Sales claim window of the lead's type); every new handled call extends it. Logged in lead_claim_log (hold,
--      hold_extend, hold_end) with the role. An Admin never takes a hold; someone not fully onboarded (1151) never does.
--   2. While it lasts: Sales cannot claim the lead, log a call, text or email on it, mark an outcome, or call or text it from
--      the site (a clear "Being handled by <first name> (Customer service) until <time>"); Next lead leaves it out. Other
--      customer service and fleet staff may still work it (their call or note takes the hold over). An Admin releases it early.
--   3. When it ends (runs out, released, the holder stops being onboarded): the lead returns to who held a Sales claim on it
--      before, else to the salesperson who brought or last had it (1151), else the pool; logged as return. A lead won, lost
--      or handled ends it. A booking made from the lead keeps 0950's credit rules: the hold is not a claim, so customer
--      service is never credited.
-- No applied migration is edited: functions are patched in place or wrapped (their grants copied).
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
  if position(p_old in d) = 0 then raise exception '2320: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. settings, the table, the log
alter table sales_lead_settings add column if not exists lead_cs_hold_minutes integer check (lead_cs_hold_minutes is null or lead_cs_hold_minutes between 1 and 1440);
comment on column sales_lead_settings.lead_cs_hold_minutes is 'Sales lead list (2320): how long a customer service or fleet call, note or Call press holds the lead for them; every new handled call extends it. Empty: the Sales claim window of the lead''s type.';

alter table lead_claim_log add column if not exists hold_role text check (hold_role in ('cs', 'fleet'));
alter table lead_claim_log drop constraint if exists lead_claim_log_action_check;
alter table lead_claim_log add constraint lead_claim_log_action_check
  check (action in ('claim', 'extend', 'unclaim', 'expire', 'reassign', 'release', 'return', 'hold', 'hold_extend', 'hold_end'));
comment on column lead_claim_log.action is 'claim, extend, unclaim, expire, reassign, release; return (1151); hold, hold_extend, hold_end (2320): a customer service or fleet person (user_id, hold_role) handling the lead on a call.';

create table if not exists lead_holds (
  lead_id         uuid primary key references leads (id) on delete cascade,
  held_by         uuid not null references users (id),
  role            text not null check (role in ('cs', 'fleet')),
  held_at         timestamptz not null default now(),
  last_call_at    timestamptz not null default now(),
  expires_at      timestamptz not null,
  prev_claimed_by uuid references users (id) on delete set null
);
comment on table lead_holds is 'Sales lead list (2320): the customer service or fleet person handling a lead on a call, for a while. Live while expires_at is in the future; each handled call extends it. prev_claimed_by: the Sales claim it replaced.';
create index if not exists lead_holds_by_idx on lead_holds (held_by, expires_at);
alter table lead_holds enable row level security;
create policy admin_all on lead_holds for select to authenticated using (app.is_admin());
revoke all on lead_holds from anon, authenticated;
grant select, insert, update, delete on lead_holds to service_role;
create trigger audit_lead_holds after insert or update or delete on lead_holds for each row execute function app.audit_row();

create function app.lead_holds_onboarded() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if app.staff_is_member(new.held_by) and not app.staff_fully_onboarded(new.held_by) then
    raise exception '% has not finished onboarding (academy, agreement and WhatsApp): leads cannot go to them yet', app.sl_name(new.held_by) using errcode = '23514';
  end if;
  return new;
end $$;
create trigger lead_holds_onboarded before insert or update of held_by on lead_holds for each row execute function app.lead_holds_onboarded();

-- ================================================================ 2. who, which lead, the words
-- the function a person holds with: cs or fleet, fully onboarded; null for an Admin, Sales only, or someone not onboarded
create function app.lead_hold_role(p_user uuid) returns text
language sql stable security definer set search_path = public, app as $$
  select case when p_user is null or coalesce(app.user_is_admin(p_user), false) then null
              when not app.staff_fully_onboarded(p_user) then null
              when app.user_va_has(p_user, 'cs') then 'cs'
              when app.user_va_has(p_user, 'fleet') then 'fleet' end
$$;

-- the open lead of a call: the lead the call is linked to, else the newest open lead with the number or with the renter's email or mobile
create function app.lead_hold_target(p_lead uuid, p_number text, p_renter uuid) returns uuid
language sql stable security definer set search_path = public, app as $$
  select l.id from leads l
   where l.handled_at is null and l.status in ('new', 'contacted', 'qualified') and coalesce(l.sales_outcome, '') not in ('won', 'lost') and app.sl_listed(l)
     and (l.id = p_lead
          or (p_lead is null and app.phone_e164(p_number) is not null and app.phone_e164(l.phone) = app.phone_e164(p_number))
          or (p_lead is null and p_renter is not null and exists (
                select 1 from renters r where r.id = p_renter
                   and ((nullif(r.email, '') is not null and lower(l.email) = lower(r.email))
                        or (app.phone_e164(r.mobile) is not null and app.phone_e164(l.phone) = app.phone_e164(r.mobile))))))
   order by (l.id = p_lead) desc, l.created_at desc
   limit 1
$$;

create function app.lead_hold_json(p_lead uuid, p_user uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select case when h.lead_id is null then null else jsonb_build_object('by', h.held_by, 'name', app.sl_name(h.held_by),
    'first_name', split_part(split_part(app.sl_name(h.held_by), ' ', 1), '@', 1), 'role', h.role,
    'role_label', case h.role when 'fleet' then 'Fleet' else 'Customer service' end, 'since', h.held_at, 'until', h.expires_at,
    'mine', h.held_by = p_user,
    'locked', h.held_by <> p_user and not coalesce(app.user_is_admin(p_user), false) and app.lead_hold_role(p_user) is null) end
    from (select 1) one left join lead_holds h on h.lead_id = p_lead and h.expires_at > now()
$$;

-- refuses the person who may not work a held lead: not the holder, not customer service or fleet (they may join), not an Admin.
-- strict: nobody but the holder (a claim, which an Admin must release first).
create function app.lead_hold_guard(p_by uuid, p_lead uuid, p_strict boolean default false) returns void
language plpgsql stable security definer set search_path = public, app as $$
declare h lead_holds;
begin
  if p_lead is null then return; end if;
  select * into h from lead_holds where lead_id = p_lead and expires_at > now();
  if h.lead_id is null or h.held_by = p_by then return; end if;
  if not p_strict and (app.lead_hold_role(p_by) is not null or coalesce(app.user_is_admin(p_by), false)) then return; end if;
  raise exception 'Being handled by % (%) until %.%', split_part(split_part(app.sl_name(h.held_by), ' ', 1), '@', 1),
    case h.role when 'fleet' then 'Fleet' else 'Customer service' end, app.fmt_time(h.expires_at),
    case when coalesce(app.user_is_admin(p_by), false) then ' Release the hold first.' else ' It comes back to the list when they are done.' end using errcode = '23514';
end $$;

-- ================================================================ 3. take, end
-- the hold of a lead for this person (a new one, an extension, or a take-over from another customer service / fleet person);
-- null when they may not hold or the lead is not open
create function app.lead_hold_take(p_by uuid, p_lead uuid) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_role text := app.lead_hold_role(p_by);
  l leads;
  h lead_holds;
  c lead_claims;
  s sales_lead_settings := app.sl_settings();
  v_win integer;
  v_prev uuid;
begin
  if v_role is null or p_lead is null then return null; end if;
  select * into l from leads where id = p_lead for update;
  if l.id is null or l.handled_at is not null or l.status not in ('new', 'contacted', 'qualified') or coalesce(l.sales_outcome, '') in ('won', 'lost') or not app.sl_listed(l) then return null; end if;
  perform app.sl_expire();
  v_win := coalesce(s.lead_cs_hold_minutes, app.sl_window(app.sl_type(l)));
  select * into h from lead_holds where lead_id = l.id;
  if h.lead_id is not null and h.held_by = p_by then
    update lead_holds set expires_at = now() + make_interval(mins => v_win), last_call_at = now(), role = v_role where lead_id = l.id;
    insert into lead_claim_log (lead_id, user_id, action, by_user, hold_role, note) values (l.id, p_by, 'hold_extend', p_by, v_role, 'Another call handled');
  else
    if h.lead_id is not null then
      v_prev := h.prev_claimed_by;
      delete from lead_holds where lead_id = l.id;
      insert into lead_claim_log (lead_id, user_id, action, by_user, hold_role, note)
      values (l.id, h.held_by, 'hold_end', p_by, h.role, left('Taken over by ' || app.sl_name(p_by), 300));
    else
      select * into c from lead_claims where lead_id = l.id and expires_at > now();
      if c.lead_id is not null then
        v_prev := c.claimed_by;
        delete from lead_claims where lead_id = l.id;
        insert into lead_claim_log (lead_id, user_id, action, by_user, note)
        values (l.id, c.claimed_by, 'release', p_by, 'Handled on a call by ' || case v_role when 'fleet' then 'fleet' else 'customer service' end || ': held until they are done');
      end if;
    end if;
    insert into lead_holds (lead_id, held_by, role, held_at, last_call_at, expires_at, prev_claimed_by)
    values (l.id, p_by, v_role, now(), now(), now() + make_interval(mins => v_win), v_prev);
    insert into lead_claim_log (lead_id, user_id, action, by_user, hold_role) values (l.id, p_by, 'hold', p_by, v_role);
  end if;
  return app.lead_hold_json(l.id, p_by);
end $$;

-- the hold ends; the lead returns (p_restore): to who held a Sales claim on it before, else to who brought or last had it, else the pool
create function app.lead_hold_end(p_lead uuid, p_by uuid, p_note text, p_restore boolean default true, p_at timestamptz default now()) returns uuid
language plpgsql security definer set search_path = public, app as $$
declare
  h lead_holds;
  l leads;
  s sales_lead_settings := app.sl_settings();
  v_to uuid;
  v_win integer;
begin
  delete from lead_holds where lead_id = p_lead returning * into h;
  if h.lead_id is null then return null; end if;
  insert into lead_claim_log (lead_id, user_id, action, by_user, at, note, hold_role) values (p_lead, h.held_by, 'hold_end', p_by, p_at, left(p_note, 300), h.role);
  if not p_restore then return null; end if;
  select * into l from leads where id = p_lead;
  if l.id is null or l.handled_at is not null or l.status not in ('new', 'contacted', 'qualified')
     or exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now()) then return null; end if;
  v_to := h.prev_claimed_by;
  if v_to is not null and not (app.sl_may(v_to) and app.staff_fully_onboarded(v_to)) then v_to := null; end if;
  if v_to is null then v_to := app.lead_previous_owner(l.id, h.held_by); end if;
  if v_to is null then return null; end if;
  begin
    perform set_config('app.lead_admin_move', 'on', true);
    v_win := app.sl_window(app.sl_type(l));
    insert into lead_claims (lead_id, claimed_by, claimed_at, expires_at, cap_at)
    values (l.id, v_to, now(), now() + make_interval(mins => v_win), now() + make_interval(mins => greatest(v_win, coalesce(s.extend_max_minutes, 60))));
    perform set_config('app.lead_admin_move', '', true);
    insert into lead_claim_log (lead_id, user_id, action, by_user, note) values (l.id, v_to, 'return', p_by, left('Back from ' || app.sl_name(h.held_by) || '''s hold', 300));
  exception when others then
    perform set_config('app.lead_admin_move', '', true);
    return null;
  end;
  return v_to;
end $$;

-- holds that ran out (or whose holder is no longer onboarded) end first; then the claims as before
alter function app.sl_expire(timestamptz) rename to sl_expire_pre2320;
create function app.sl_expire(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = public, app as $$
declare
  r record;
  n integer := 0;
begin
  for r in select h.lead_id, h.expires_at, h.held_by from lead_holds h where h.expires_at <= p_now or not app.staff_fully_onboarded(h.held_by) loop
    perform app.lead_hold_end(r.lead_id, null, case when r.expires_at <= p_now then 'The hold ran out' else 'No longer onboarded' end, true,
                              case when r.expires_at <= p_now then r.expires_at else p_now end);
    n := n + 1;
  end loop;
  return n + app.sl_expire_pre2320(p_now);
end $$;
select pg_temp.copy_grants('app.sl_expire(timestamptz)'::regprocedure, 'app.sl_expire_pre2320(timestamptz)'::regprocedure);

-- a lead won, lost or handled ends its hold
create function app.lead_hold_close() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if exists (select 1 from lead_holds where lead_id = new.id) then perform app.lead_hold_end(new.id, null, 'The lead was closed', false); end if;
  return null;
end $$;
create trigger leads_hold_close after update of handled_at, status, sales_outcome on leads for each row
  when (new.handled_at is not null or new.status in ('converted', 'closed', 'spam') or new.sales_outcome in ('won', 'lost')) execute function app.lead_hold_close();

-- an Admin (or the holder) ends it early: p {lead}
create function app.lead_hold_release(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_lead uuid := nullif(p ->> 'lead', '')::uuid;
  h lead_holds;
  v_to uuid;
begin
  perform app.sl_expire();
  select * into h from lead_holds where lead_id = v_lead for update;
  if h.lead_id is null then return jsonb_build_object('lead', v_lead, 'hold', null); end if;
  if h.held_by <> p_by and not coalesce(app.user_is_admin(p_by), false) then
    raise exception 'Only % or an Admin can release this hold', app.sl_name(h.held_by) using errcode = '42501';
  end if;
  v_to := app.lead_hold_end(v_lead, p_by, case when h.held_by = p_by then 'Released by the holder' else 'Released early by an Admin' end, true);
  return jsonb_build_object('lead', v_lead, 'hold', null, 'returned_to', v_to, 'returned_name', case when v_to is not null then app.sl_name(v_to) end);
end $$;

-- ================================================================ 4. the phone: calls, notes, the Call button, texts
-- a Quo call answered (or placed) by a Quo user who is a person with a hold role
create function app.lead_hold_on_activity() returns trigger
language plpgsql security definer set search_path = public, app as $$
declare
  v_user uuid;
  t phone_threads;
begin
  begin
    if new.kind <> 'call' or new.quo_user_id is null then return null; end if;
    if new.direction = 'in' and new.answered_at is null then return null; end if;
    if tg_op = 'UPDATE' and new.answered_at is not distinct from old.answered_at and new.quo_user_id is not distinct from old.quo_user_id then return null; end if;
    select sp.user_id into v_user from staff_profiles sp where sp.quo_user_id = new.quo_user_id;
    if v_user is null or app.lead_hold_role(v_user) is null then return null; end if;
    select * into t from phone_threads where id = new.thread_id;
    perform app.lead_hold_take(v_user, app.lead_hold_target(coalesce(new.lead_id, t.lead_id), t.number, coalesce(new.renter_id, t.renter_id)));
  exception when others then
    raise warning 'lead hold from a call not taken: %', sqlerrm;
  end;
  return null;
end $$;
create trigger phone_activity_lead_hold after insert or update of answered_at, quo_user_id on phone_activity for each row execute function app.lead_hold_on_activity();

-- the site's Call button pressed by a person with a hold role
create function app.lead_hold_on_outbound() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  begin
    if app.lead_hold_role(new.staff_user_id) is not null then
      perform app.lead_hold_take(new.staff_user_id, app.lead_hold_target(new.lead_id, new.to_number, new.renter_id));
    end if;
  exception when others then
    raise warning 'lead hold from a call not taken: %', sqlerrm;
  end;
  return null;
end $$;
create trigger outbound_calls_lead_hold after insert on outbound_calls for each row execute function app.lead_hold_on_outbound();

-- a note on a renter (the caller pop-up, the renter's page) by customer service or fleet: the renter's open lead is held
alter function app.renter_note_add(uuid, jsonb) rename to renter_note_add_pre2320;
create function app.renter_note_add(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  r jsonb := app.renter_note_add_pre2320(p_by, p);
  v_renter uuid := nullif(coalesce(p ->> 'renter_id', p ->> 'renter', ''), '')::uuid;
begin
  begin
    if app.lead_hold_role(p_by) is not null then
      perform app.lead_hold_take(p_by, app.lead_hold_target(null, (select rn.mobile from renters rn where rn.id = v_renter), v_renter));
    end if;
  exception when others then
    raise warning 'lead hold from a note not taken: %', sqlerrm;
  end;
  return r;
end $$;
select pg_temp.copy_grants('app.renter_note_add(uuid, jsonb)'::regprocedure, 'app.renter_note_add_pre2320(uuid, jsonb)'::regprocedure);

-- Sales cannot call or text a held lead from the site
select pg_temp.patch_fn('app.server_twilio_call_start(jsonb)'::regprocedure,
  't := app.phone_thread_for(v_to);',
  't := app.phone_thread_for(v_to);
  perform app.lead_hold_guard(v_user, app.lead_hold_target(t.lead_id, v_to, t.renter_id));');
select pg_temp.patch_fn('app.phone_staff_do(uuid, text, jsonb)'::regprocedure,
  'o := app.phone_outbox_put(t.number, v_body, ''staff'',',
  'perform app.lead_hold_guard(p_by, app.lead_hold_target(t.lead_id, t.number, t.renter_id));
    o := app.phone_outbox_put(t.number, v_body, ''staff'',');
-- a lead created from a call is held by the person who created it
select pg_temp.patch_fn('app.phone_staff_do(uuid, text, jsonb)'::regprocedure,
  'update phone_activity set lead_id = v_lead where thread_id = t.id;',
  'update phone_activity set lead_id = v_lead where thread_id = t.id;
    perform app.lead_hold_take(p_by, v_lead);');

-- ================================================================ 5. the lead list and the Sales actions
-- claim: not on a held lead (the holder gets the hold back); contact, outcome and handled: the guard; a call or note by customer service / fleet takes the hold
select pg_temp.patch_fn('app.lead_claim(uuid, jsonb)'::regprocedure,
  'l := app.sl_lead_for(p_by, (p ->> ''lead'')::uuid, true);',
  'l := app.sl_lead_for(p_by, (p ->> ''lead'')::uuid, true);
  if exists (select 1 from lead_holds where lead_id = l.id and held_by = p_by and expires_at > now()) then
    return jsonb_build_object(''lead'', l.id, ''claim'', null, ''hold'', app.lead_hold_json(l.id, p_by));
  end if;
  perform app.lead_hold_guard(p_by, l.id, true);');
select pg_temp.patch_fn('app.lead_contact(uuid, jsonb)'::regprocedure,
  'select * into c from lead_claims where lead_id = l.id and expires_at > now();',
  'perform app.lead_hold_guard(p_by, l.id);
  select * into c from lead_claims where lead_id = l.id and expires_at > now();');
select pg_temp.patch_fn('app.lead_contact(uuid, jsonb)'::regprocedure,
  'if c.lead_id is not null and c.claimed_by <> p_by and not app.user_is_admin(p_by) then',
  'if c.lead_id is not null and c.claimed_by <> p_by and not app.user_is_admin(p_by) and not (v_ch in (''call'', ''note'') and app.lead_hold_role(p_by) is not null) then');
select pg_temp.patch_fn('app.lead_contact(uuid, jsonb)'::regprocedure,
  'insert into lead_contacts (lead_id, by_user, channel, note) values (l.id, p_by, v_ch, v_note);',
  'insert into lead_contacts (lead_id, by_user, channel, note) values (l.id, p_by, v_ch, v_note);
  if v_ch in (''call'', ''note'') then
    perform app.lead_hold_take(p_by, l.id);
    select * into c from lead_claims where lead_id = l.id and expires_at > now();
  end if;');
select pg_temp.patch_fn('app.lead_contact(uuid, jsonb)'::regprocedure,
  'elsif c.lead_id is null and l.handled_at is null and l.status not in (''converted'', ''closed'') then',
  'elsif c.lead_id is null and l.handled_at is null and l.status not in (''converted'', ''closed'')
        and not (v_ch in (''call'', ''note'') and app.lead_hold_role(p_by) is not null) then');
select pg_temp.patch_fn('app.lead_outcome(uuid, jsonb)'::regprocedure,
  'select * into c from lead_claims where lead_id = l.id and expires_at > now();',
  'perform app.lead_hold_guard(p_by, l.id);
  select * into c from lead_claims where lead_id = l.id and expires_at > now();');
select pg_temp.patch_fn('app.lead_handled(uuid, jsonb)'::regprocedure,
  'select * into c from lead_claims where lead_id = l.id and expires_at > now();',
  'perform app.lead_hold_guard(p_by, l.id);
  select * into c from lead_claims where lead_id = l.id and expires_at > now();');
-- an Admin's reassign or return supersedes the hold
select pg_temp.patch_fn('app.lead_reassign(uuid, jsonb)'::regprocedure,
  'l := app.sl_lead_for(p_by, (p ->> ''lead'')::uuid, true);',
  'l := app.sl_lead_for(p_by, (p ->> ''lead'')::uuid, true);
  perform app.lead_hold_end(l.id, p_by, ''Reassigned by an Admin'', false);');
select pg_temp.patch_fn('app.lead_return_do(uuid, uuid, text)'::regprocedure,
  'select * into c from lead_claims where lead_id = l.id and expires_at > now();',
  'if p_by is not null then perform app.lead_hold_end(l.id, p_by, ''Returned by an Admin'', false); end if;
  select * into c from lead_claims where lead_id = l.id and expires_at > now();');
-- Next lead leaves a held lead out
select pg_temp.patch_fn('app.sl_open_pool(uuid, text, timestamptz)'::regprocedure,
  'and not exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > p_now)',
  'and not exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > p_now)
     and not exists (select 1 from lead_holds h where h.lead_id = l.id and h.expires_at > p_now)');
-- the list: Claimed includes held, Not claimed leaves held out, Mine includes what the person holds
select pg_temp.patch_fn('app.sales_leads_pre1152(uuid, jsonb)'::regprocedure,
  'when ''claimed'' then exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now())',
  'when ''claimed'' then exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now()) or exists (select 1 from lead_holds h where h.lead_id = l.id and h.expires_at > now())');
select pg_temp.patch_fn('app.sales_leads_pre1152(uuid, jsonb)'::regprocedure,
  'l.status in (''new'', ''contacted'', ''qualified'') and not exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now())',
  'l.status in (''new'', ''contacted'', ''qualified'') and not exists (select 1 from lead_claims c where c.lead_id = l.id and c.expires_at > now())
                                  and not exists (select 1 from lead_holds h where h.lead_id = l.id and h.expires_at > now())');
select pg_temp.patch_fn('app.sales_leads_pre1152(uuid, jsonb)'::regprocedure,
  'or exists (select 1 from lead_claims c where c.lead_id = l.id and c.claimed_by = p_by and c.expires_at > now()))',
  'or exists (select 1 from lead_claims c where c.lead_id = l.id and c.claimed_by = p_by and c.expires_at > now())
                                      or exists (select 1 from lead_holds h where h.lead_id = l.id and h.held_by = p_by and h.expires_at > now()))');
-- every lead row (the list and the lead page, Admin and staff) carries the hold
alter function app.sl_row(leads, uuid) rename to sl_row_pre2320;
create function app.sl_row(l leads, p_by uuid) returns jsonb
language sql stable security definer set search_path = public, app as $$
  select app.sl_row_pre2320(l, p_by) || jsonb_build_object('hold', app.lead_hold_json(l.id, p_by))
$$;
select pg_temp.copy_grants('app.sl_row(leads, uuid)'::regprocedure, 'app.sl_row_pre2320(leads, uuid)'::regprocedure);

-- Settings > Sales
select pg_temp.patch_fn('app.sales_lead_settings_read(uuid, jsonb)'::regprocedure,
  '''claim_cooldown_minutes'', s.claim_cooldown_minutes,',
  '''claim_cooldown_minutes'', s.claim_cooldown_minutes, ''lead_cs_hold_minutes'', s.lead_cs_hold_minutes,');
select pg_temp.patch_fn('app.sales_lead_settings_save(uuid, jsonb)'::regprocedure,
  'claim_cooldown_minutes = coalesce(nullif(p ->> ''claim_cooldown_minutes'', '''')::integer, claim_cooldown_minutes),',
  'claim_cooldown_minutes = coalesce(nullif(p ->> ''claim_cooldown_minutes'', '''')::integer, claim_cooldown_minutes),
         lead_cs_hold_minutes = case when p ? ''lead_cs_hold_minutes'' then nullif(p ->> ''lead_cs_hold_minutes'', '''')::integer else lead_cs_hold_minutes end,');

-- ================================================================ 6. the door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2320;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
begin
  if p_call in ('ops_do', 'va_do', 'admin_do') and p_name = 'lead_hold_release' then
    perform app.door_begin(p_user, p_aal);
    return app.lead_hold_release(p_user, coalesce(p, '{}'::jsonb) - '_va');
  end if;
  return app.door_pre2320(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2320(uuid, text, text, text, jsonb)'::regprocedure);

-- ================================================================ privileges: the server only
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname = any (array['lead_holds_onboarded', 'lead_hold_role', 'lead_hold_target', 'lead_hold_json', 'lead_hold_guard', 'lead_hold_take',
                     'lead_hold_end', 'sl_expire_pre2320', 'lead_hold_close', 'lead_hold_release', 'lead_hold_on_activity', 'lead_hold_on_outbound', 'renter_note_add_pre2320',
                     'sl_row_pre2320', 'door_pre2320'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
