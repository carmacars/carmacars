-- 2330: customer service, Fleet and Finance get no sales credit or commission, ever; their help is acknowledged instead (release 37).
-- The owner, November 11, 16:18: "Customer service and fleet and finance gets no sales credit or commission ever. But they get
-- 'credit' like acknowledgement."
--   1. The rule, in the database (app.credit_blocked): a person whose functions are only customer service, Fleet and/or Finance (no
--      Sales, no field, not an Admin) is never the credited or commissioned person, by any path: a booking's sales credit and
--      "sourced" flag (bookings.sales_staff_id, sales_sourced, sales_claim_by: a quote, a rental added by hand, the first offer, a
--      referral, an Admin's reassignment, an accepted claim), the commission (staff_commissions) and its rate, the lead's sourced-by,
--      an owner's recruited-by and application credit, an owner commission request, a Sales lead claim, and the rebooking claim.
--      Automatic paths simply leave the credit empty (the next Sales person to send an offer is credited); a person picking
--      someone (the Admin's Credit it to / Reassign, Accept a claim, a commission rate, Sourced by) is told no. A person with both
--      Sales and customer service keeps credit for their work as Sales (app.sales_as_cs, the window of customer service work done by
--      a Sales person, credits nobody). Credit already on file is reported (NOTICE, audit_log), never rewritten: no payout changes.
--   2. Acknowledgement: "Helped by" on every booking and lead (Admin and every staff portal), read from the logs that already exist
--      (an offer sent, a licence checked, questions answered, an extension, a task done, a field job done, a call held, a contact
--      logged): app.help_rows / app.helped_by. A "Helped" count on each person's KPIs (their scorecard, and the team's KPI board),
--      no money.
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
  if position(p_old in d) = 0 then raise exception '2330: the text to change was not found in %: %', p_sig, left(p_old, 120); end if;
  execute replace(d, p_old, p_new);
end $$;

-- ================================================================ 1. the rule
-- True for a person who may never be credited or paid commission: staff whose functions are only customer service, Fleet and/or
-- Finance. Admins, Sales and field staff are not blocked; neither is someone with no function yet.
create function app.credit_blocked(p_user uuid) returns boolean
language sql stable security definer set search_path = public, app as $$
  select p_user is not null and not app.user_is_admin(p_user) and (
    exists (select 1 from staff_profiles sp
             where sp.user_id = p_user and sp.functions && array['cs', 'fleet', 'finance'] and not (sp.functions && array['sales', 'field']))
    or coalesce(current_setting('app.sales_as_cs', true), '') = p_user::text)
$$;
comment on function app.credit_blocked(uuid) is 'The owner''s rule of November 11 (2330): customer service, Fleet and Finance get no sales credit or commission, ever. Their help is acknowledged as "Helped by" and on their KPIs.';

-- For the pickers (Credit it to, Reassign, a commission rate, Sourced by, accepting a claim): says no in words.
create function app.credit_check(p_user uuid) returns boolean
language plpgsql stable security definer set search_path = public, app as $$
begin
  if app.credit_blocked(p_user) then
    raise exception 'Customer service, Fleet and Finance staff get no sales credit or commission. Their help is credited as "Helped by" on the booking and on their scorecard.' using errcode = '23514';
  end if;
  return app.user_is_sales_staff(p_user);
end $$;

-- a booking: nobody blocked is ever its sales credit, "sourced" person or claimant (whoever set it: a quote, a rental added by hand,
-- an offer, a referral, an Admin). It fires after the credit triggers of 0057 and 0058 (by name).
create function app.bookings_credit_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  -- an insert leaves the credit empty; an update that would hand it to a blocked person changes nothing
  if new.sales_claim_by is not null and (tg_op = 'INSERT' or new.sales_claim_by is distinct from old.sales_claim_by) and app.credit_blocked(new.sales_claim_by) then
    if tg_op = 'INSERT' then new.sales_claim_by := null; new.sales_claim_at := null;
    else new.sales_claim_by := old.sales_claim_by; new.sales_claim_at := old.sales_claim_at; end if;
  end if;
  if new.sales_staff_id is not null and (tg_op = 'INSERT' or new.sales_staff_id is distinct from old.sales_staff_id) and app.credit_blocked(new.sales_staff_id) then
    if tg_op = 'INSERT' then
      new.sales_staff_id := null; new.sales_source := null; new.sales_attributed_at := null; new.sales_attributed_by := null;
      -- r38: "Entered for CarmaCars" is no credit: that choice stays on the booking (only "sourced" is taken away)
      new.sales_sourced := false;
      if new.sales_choice is distinct from 'for_carmacars' then new.sales_choice := null; new.sales_choice_by := null; new.sales_choice_at := null; end if;
    else
      new.sales_staff_id := old.sales_staff_id; new.sales_source := old.sales_source; new.sales_attributed_at := old.sales_attributed_at; new.sales_attributed_by := old.sales_attributed_by;
      new.sales_sourced := old.sales_sourced; new.sales_choice := old.sales_choice; new.sales_choice_by := old.sales_choice_by; new.sales_choice_at := old.sales_choice_at;
    end if;
  elsif new.sales_sourced and (tg_op = 'INSERT' or not old.sales_sourced) and new.sales_staff_id is not null and app.credit_blocked(new.sales_staff_id) then
    new.sales_sourced := false;
  end if;
  return new;
end $$;
drop trigger if exists bookings_zz_credit_guard on bookings;
create trigger bookings_zz_credit_guard before insert or update on bookings for each row execute function app.bookings_credit_guard();

-- a commission row for a blocked person is never made (the row is skipped, nothing else fails); clawbacks stay allowed
create function app.staff_commissions_credit_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if (new.kind = 'commission' or (new.kind = 'adjustment' and new.amount_cents > 0)) and app.credit_blocked(new.staff_id) then
    raise notice '2330: no commission for customer service, Fleet or Finance staff (booking %)', new.booking_id;
    return null;
  end if;
  return new;
end $$;
drop trigger if exists staff_commissions_zz_credit_guard on staff_commissions;
create trigger staff_commissions_zz_credit_guard before insert on staff_commissions for each row execute function app.staff_commissions_credit_guard();

-- the commission calculation leaves a blocked person's booking alone (a row already on file keeps being kept up to date, unpaid or paid)
alter function app.commission_sync(uuid) rename to commission_sync_pre2330;
create function app.commission_sync(p_booking uuid) returns void
language plpgsql security definer set search_path = public, app as $$
declare
  b bookings;
begin
  select * into b from bookings where id = p_booking;
  if b.id is not null and b.sales_staff_id is not null and app.credit_blocked(b.sales_staff_id)
     and not exists (select 1 from staff_commissions x where x.booking_id = b.id and x.staff_id = b.sales_staff_id and x.kind = 'commission') then
    return;
  end if;
  perform app.commission_sync_pre2330(p_booking);
end $$;
select pg_temp.copy_grants('app.commission_sync(uuid)'::regprocedure, 'app.commission_sync_pre2330(uuid)'::regprocedure);

-- leads, owners and applications: the sourced-by / recruited-by credit is left empty for a blocked person
create function app.leads_credit_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.sourced_by is not null and (tg_op = 'INSERT' or new.sourced_by is distinct from old.sourced_by) and app.credit_blocked(new.sourced_by) then
    new.sourced_by := case when tg_op = 'INSERT' then null else old.sourced_by end;
  end if;
  return new;
end $$;
drop trigger if exists leads_zz_credit_guard on leads;
create trigger leads_zz_credit_guard before insert or update of sourced_by on leads for each row execute function app.leads_credit_guard();

create function app.owners_credit_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.recruited_by is not null and (tg_op = 'INSERT' or new.recruited_by is distinct from old.recruited_by) and app.credit_blocked(new.recruited_by) then
    if tg_op = 'INSERT' then new.recruited_by := null; new.recruited_at := null; new.recruited_via := null;
    else new.recruited_by := old.recruited_by; new.recruited_at := old.recruited_at; new.recruited_via := old.recruited_via; end if;
  end if;
  return new;
end $$;
drop trigger if exists owners_zz_credit_guard on owners;
create trigger owners_zz_credit_guard before insert or update of recruited_by on owners for each row execute function app.owners_credit_guard();

create function app.owner_applications_credit_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  if new.sourced_by is not null and (tg_op = 'INSERT' or new.sourced_by is distinct from old.sourced_by) and app.credit_blocked(new.sourced_by) then
    new.sourced_by := case when tg_op = 'INSERT' then null else old.sourced_by end;
  end if;
  return new;
end $$;
drop trigger if exists owner_applications_zz_credit_guard on owner_applications;
create trigger owner_applications_zz_credit_guard before insert or update of sourced_by on owner_applications for each row execute function app.owner_applications_credit_guard();

-- an owner commission request and a Sales lead claim are a person's own act: refused in words
create function app.lead_claims_credit_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.credit_check(new.claimed_by);
  return new;
end $$;
create function app.owner_recruit_requests_credit_guard() returns trigger
language plpgsql security definer set search_path = public, app as $$
begin
  perform app.credit_check(new.staff_id);
  return new;
end $$;
drop trigger if exists lead_claims_zz_credit_guard on lead_claims;
create trigger lead_claims_zz_credit_guard before insert on lead_claims for each row execute function app.lead_claims_credit_guard();
drop trigger if exists owner_recruit_requests_zz_credit_guard on owner_recruit_requests;
create trigger owner_recruit_requests_zz_credit_guard before insert on owner_recruit_requests for each row execute function app.owner_recruit_requests_credit_guard();

-- the pickers: an Admin's Reassign (Credit it to), a commission rate, an owner's Sourced by, Accept a claim, and the list of who may be picked
select pg_temp.patch_fn('app.sales_reassign(uuid, jsonb)'::regprocedure, 'not app.user_is_sales_staff(v_staff)', 'not app.credit_check(v_staff)');
select pg_temp.patch_fn('app.staff_commission_rate_set(uuid, jsonb)'::regprocedure, 'not app.user_is_sales_staff(v_staff)', 'not app.credit_check(v_staff)');
select pg_temp.patch_fn('app.owner_sourced_set(uuid, jsonb)'::regprocedure, 'not app.user_is_sales_staff(v_staff)', 'not app.credit_check(v_staff)');
select pg_temp.patch_fn('app.sales_staff_options(uuid)'::regprocedure, 'where app.user_is_sales_staff(u.id) and not u.is_test', 'where app.user_is_sales_staff(u.id) and not app.credit_blocked(u.id) and not u.is_test');

alter function app.sales_claim_decide(uuid, jsonb) rename to sales_claim_decide_pre2330;
create function app.sales_claim_decide(p_by uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_claim uuid;
begin
  select b.sales_claim_by into v_claim from bookings b where b.id::text = p ->> 'booking' or b.booking_number = p ->> 'booking';
  if coalesce((p ->> 'accept')::boolean, false) and v_claim is not null then perform app.credit_check(v_claim); end if;
  return app.sales_claim_decide_pre2330(p_by, p);
end $$;
select pg_temp.copy_grants('app.sales_claim_decide(uuid, jsonb)'::regprocedure, 'app.sales_claim_decide_pre2330(uuid, jsonb)'::regprocedure);

-- rebooking: a returning renter's lead is claimed for the salesperson credited on their last booking, never for a blocked person
select pg_temp.patch_fn('app.lead_rebook_trg()'::regprocedure, 'not app.user_va_has(v_to, ''sales'')', 'not app.user_va_has(v_to, ''sales'') or app.credit_blocked(v_to)');

-- ================================================================ 1b. what is on file (reported, never rewritten)
do $$
declare
  v_blocked uuid[] := array(select sp.user_id from staff_profiles sp
                             where sp.functions && array['cs', 'fleet', 'finance'] and not (sp.functions && array['sales', 'field']) and not app.user_is_admin(sp.user_id));
  n_book integer; n_src integer; n_claim integer; n_comm integer; amt bigint; n_open integer; n_lead integer; n_owner integer; n_app integer; n_req integer;
begin
  select count(*), count(*) filter (where sales_sourced) into n_book, n_src from bookings where sales_staff_id = any (v_blocked);
  select count(*) into n_claim from bookings where sales_claim_by = any (v_blocked);
  select count(*), coalesce(sum(amount_cents), 0), count(*) filter (where status in ('accruing', 'pending_approval', 'approved'))
    into n_comm, amt, n_open from staff_commissions where kind = 'commission' and staff_id = any (v_blocked) and status not in ('void', 'reversed');
  select count(*) into n_lead from leads where sourced_by = any (v_blocked);
  select count(*) into n_owner from owners where recruited_by = any (v_blocked);
  select count(*) into n_app from owner_applications where sourced_by = any (v_blocked);
  select count(*) into n_req from owner_recruit_requests where staff_id = any (v_blocked);
  raise notice '2330: credit on file for customer service, Fleet or Finance staff (reported, not changed): % bookings credited (% as sourced), % claims, % commissions worth % cents (% not paid yet), % leads, % owners, % applications, % owner commission requests',
    n_book, n_src, n_claim, n_comm, amt, n_open, n_lead, n_owner, n_app, n_req;
  insert into audit_log (actor_user_id, action, entity_table, entity_id, after)
  values (null, 'credit_rule_2330_report', 'bookings', null, jsonb_build_object('bookings', n_book, 'sourced', n_src, 'claims', n_claim, 'commissions', n_comm, 'commission_cents', amt,
          'commissions_unpaid', n_open, 'leads', n_lead, 'owners', n_owner, 'applications', n_app, 'owner_requests', n_req));
end $$;

-- ================================================================ 2. Helped by
-- Everything staff did on a booking or a lead that the logs already hold, one row each: who, what, when. Filters push down to each source.
create function app.help_rows(p_booking uuid default null, p_lead uuid default null, p_user uuid default null,
                              p_from timestamptz default null, p_to timestamptz default null)
returns table (booking_id uuid, lead_id uuid, user_id uuid, what text, at timestamptz)
language sql stable security definer set search_path = public, app as $$
  select x.booking_id, x.lead_id, x.user_id, x.what, x.at from (
    select o.booking_id, null::uuid as lead_id, o.sent_by as user_id, 'sent the offer'::text as what, o.sent_at as at
      from booking_offers o where o.sent_by is not null and (p_lead is null or p_booking is not null) and (p_booking is null or o.booking_id = p_booking) and (p_user is null or o.sent_by = p_user)
    union all
    select e.booking_id, null::uuid, e.actor_user_id,
           case e.kind when 'verification' then 'checked the licence' when 'extension' then 'handled the extension'
                       when 'info_requested' then 'asked the renter for details' else 'answered the renter' end, e.created_at
      from booking_events e
     where e.actor_type = 'staff' and e.actor_user_id is not null and e.kind in ('verification', 'extension', 'info_requested', 'info_replied')
       and (p_lead is null or p_booking is not null) and (p_booking is null or e.booking_id = p_booking) and (p_user is null or e.actor_user_id = p_user)
    union all
    select t.booking_id, null::uuid, t.completed_by, 'did the task: ' || replace(t.task_type, '_', ' '), t.completed_at
      from tasks t
     where t.status = 'done' and t.completed_by is not null and t.booking_id is not null
       and (p_lead is null or p_booking is not null) and (p_booking is null or t.booking_id = p_booking) and (p_user is null or t.completed_by = p_user)
    union all
    select j.booking_id, null::uuid, j.assigned_to,
           case when j.kind in ('handover', 'delivery') then 'did the handover' when j.kind in ('return_check_in', 'pickup_from_renter') then 'did the return' else 'did a field job' end,
           coalesce(j.completed_at, j.created_at)
      from field_jobs j
     where j.status = 'done' and j.assigned_to is not null and j.booking_id is not null
       and (p_lead is null or p_booking is not null) and (p_booking is null or j.booking_id = p_booking) and (p_user is null or j.assigned_to = p_user)
    union all
    select l.won_booking_id, l.id, h.user_id, 'handled the call', h.at
      from lead_claim_log h join leads l on l.id = h.lead_id
     where h.action in ('hold', 'hold_extend') and (p_lead is null or l.id = p_lead) and (p_booking is null or l.won_booking_id = p_booking) and (p_user is null or h.user_id = p_user)
    union all
    select l.won_booking_id, l.id, c.by_user, 'logged a ' || c.channel, c.at
      from lead_contacts c join leads l on l.id = c.lead_id
     where (p_lead is null or l.id = p_lead) and (p_booking is null or l.won_booking_id = p_booking) and (p_user is null or c.by_user = p_user)
  ) x
  where (p_from is null or x.at >= p_from) and (p_to is null or x.at < p_to)
$$;

-- Who helped on one booking or lead, for the "Helped by" line: [{id, name, what: [...]}]. Not the person credited with the sale, not
-- an Admin or a test account, only people with a staff profile.
create function app.helped_by(p_booking uuid default null, p_lead uuid default null) returns jsonb
language sql stable security definer set search_path = public, app as $$
  with credit as (
    select array_remove(array[
      (select b.sales_staff_id from bookings b where b.id = p_booking),
      (select b.sales_staff_id from leads l join bookings b on b.id = l.won_booking_id where l.id = p_lead),
      (select c.claimed_by from lead_claims c where c.lead_id = p_lead),
      (select l.sourced_by from leads l where l.id = p_lead),
      (select l.sales_outcome_by from leads l where l.id = p_lead)], null) as ids
  ), r as (
    select h.user_id, h.what, min(h.at) as first_at
      from app.help_rows(p_booking, p_lead) h, credit
     where not (h.user_id = any (credit.ids))
       and exists (select 1 from staff_profiles sp where sp.user_id = h.user_id) and not app.user_is_admin(h.user_id) and not app.staff_is_test(h.user_id)
     group by h.user_id, h.what
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', g.user_id, 'name', app.sl_name(g.user_id), 'what', g.what) order by g.first_at, app.sl_name(g.user_id)), '[]'::jsonb)
    from (select r.user_id, min(r.first_at) as first_at, to_jsonb(array_agg(r.what order by r.first_at)) as what from r group by r.user_id) g
$$;

-- the lead page carries it
alter function app.sales_lead(uuid, jsonb) rename to sales_lead_pre2330;
create function app.sales_lead(p_by uuid, p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v jsonb := app.sales_lead_pre2330(p_by, p);
begin
  return v || jsonb_build_object('helped_by', app.helped_by(null, nullif(p ->> 'id', '')::uuid));
end $$;
select pg_temp.copy_grants('app.sales_lead(uuid, jsonb)'::regprocedure, 'app.sales_lead_pre2330(uuid, jsonb)'::regprocedure);

-- the booking page (Admin and every staff portal) reads it through the shared door
alter function app.door(uuid, text, text, text, jsonb) rename to door_pre2330;
create function app.door(p_user uuid, p_aal text, p_call text, p_name text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public, app as $$
declare
  v_booking uuid;
begin
  if p_call = 'ops_read' and p_name = 'booking_helped' then
    perform app.door_begin(p_user, p_aal);
    if not app.user_is_staff(p_user) then raise exception 'Staff only' using errcode = '42501'; end if;
    select b.id into v_booking from bookings b where b.id::text = coalesce(p ->> 'booking', '') or b.booking_number = coalesce(p ->> 'booking', '');
    return jsonb_build_object('helped_by', case when v_booking is null then '[]'::jsonb else app.helped_by(v_booking, null) end);
  end if;
  return app.door_pre2330(p_user, p_aal, p_call, p_name, p);
end $$;
select pg_temp.copy_grants('app.door(uuid, text, text, text, jsonb)'::regprocedure, 'app.door_pre2330(uuid, text, text, text, jsonb)'::regprocedure);

-- the KPIs (each person's scorecard, and the team's KPI board): "Helped", no money, no target
alter function app.role_kpis(uuid, date) rename to role_kpis_pre2330;
create function app.role_kpis(p_user uuid, p_week date) returns jsonb
language plpgsql stable security definer set search_path = public, app as $$
declare
  v_base jsonb := app.role_kpis_pre2330(p_user, p_week);
  a timestamptz := p_week::timestamp at time zone 'America/Toronto';
  z timestamptz := (p_week + 7)::timestamp at time zone 'America/Toronto';
  n bigint;
begin
  if not exists (select 1 from staff_profiles sp where sp.user_id = p_user and sp.functions && array['cs', 'fleet', 'finance', 'sales']) then return v_base; end if;
  select count(distinct coalesce(h.booking_id::text, h.lead_id::text)) into n
    from app.help_rows(null, null, p_user, a, z) h left join bookings b on b.id = h.booking_id
   where b.sales_staff_id is distinct from p_user;
  return v_base || jsonb_build_array(app.kpi_item('helped', 'Helped (bookings and leads)', n, null, 'count', null,
    'Your help is credited on the booking and here. No commission. Each booking or lead counts once.'));
end $$;
select pg_temp.copy_grants('app.role_kpis(uuid, date)'::regprocedure, 'app.role_kpis_pre2330(uuid, date)'::regprocedure);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'app' and p.proname in ('credit_blocked', 'credit_check', 'bookings_credit_guard', 'staff_commissions_credit_guard', 'leads_credit_guard', 'owners_credit_guard',
                                                     'owner_applications_credit_guard', 'lead_claims_credit_guard', 'owner_recruit_requests_credit_guard', 'commission_sync_pre2330', 'sales_claim_decide_pre2330',
                                                     'help_rows', 'helped_by', 'sales_lead_pre2330', 'door_pre2330', 'role_kpis_pre2330') loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- GUIDES 2330 START (generated by supabase/seed/2330_gen_guides.mjs from docs/guides/content; do not edit by hand)
-- the chapters are published by supabase/seed/2340_gen_guides.mjs (same release base)
-- GUIDES 2330 END
